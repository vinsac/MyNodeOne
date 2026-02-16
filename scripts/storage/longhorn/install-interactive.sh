#!/bin/bash

###############################################################################
# Interactive Longhorn Installation Script
#
# Features:
# - Detects available disks
# - Interactive disk selection
# - Formats and mounts disks
# - Installs Longhorn with proper configuration
# - Registers configuration in node registry
# - Follows existing MyNodeOne patterns
###############################################################################

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/project-root.sh"
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

# Set KUBECONFIG appropriately
export_k8s_config

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Retry wrapper for kubectl operations on Longhorn CRDs
# Longhorn's admission webhook rejects writes while disk status is syncing.
# This function retries with exponential backoff to handle transient sync errors.
#
# Usage: kubectl_longhorn_retry <max_attempts> <description> kubectl patch ...
# Returns: 0 on success, 1 on failure after all attempts
kubectl_longhorn_retry() {
    local max_attempts="$1"
    local description="$2"
    shift 2
    
    local attempt=0
    local wait_seconds=5
    while [ $attempt -lt $max_attempts ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            log_info "  $description — retrying in ${wait_seconds}s (attempt $((attempt+1))/$max_attempts)"
            sleep $wait_seconds
            # Exponential backoff: 5s, 10s, 20s
            wait_seconds=$((wait_seconds * 2))
        fi
    done
    return 1
}

# LIB_DIR setup
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source additional utilities if available
if [ -f "$LIB_DIR/disk-utils.sh" ]; then
    source "$LIB_DIR/disk-utils.sh"
fi

# Longhorn version — single source of truth for this script
# Also hardcoded in bootstrap-control-plane.sh fallback and LONGHORN-SETTINGS.md
LONGHORN_VERSION="${LONGHORN_VERSION:-1.7.2}"

# Longhorn replica count — can be overridden via env var or interactive prompt
# Default: 1 (single replica, recommended for home lab / Tailscale networking)
LONGHORN_REPLICA_COUNT="${LONGHORN_REPLICA_COUNT:-1}"

# Standard mount path for Longhorn disks (project-wide convention, also used by
# node-registry-manager.sh, add-disk-to-longhorn.sh, uninstall-mynodeone.sh, fix-usb-disk-boot.sh)
LONGHORN_MOUNT_BASE="/mnt/longhorn-disks"

# Global arrays for disk management
declare -a MOUNTED_DISKS=()
declare -a SELECTED_DISKS=()

# Function to safely get K8s node name
get_k8s_node_name() {
    local hostname=$(hostname)
    # Try to find node with matching hostname
    local node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.metadata.name=='$hostname')].metadata.name}" 2>/dev/null)
    
    # Fallback: try to find node by hostname label
    if [[ -z "$node_name" ]]; then
        node_name=$(kubectl get nodes -l kubernetes.io/hostname=$hostname -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi
    
    echo "$node_name"
}

# Function to check if running on control plane
is_control_plane() {
    # Check if this node has the control-plane role label
    local node_name=$(hostname)
    if command -v kubectl &>/dev/null; then
        # Check if control-plane role label exists (value is typically empty string in kubeadm)
        if kubectl get node "$node_name" --show-labels 2>/dev/null | grep -q "node-role.kubernetes.io/control-plane"; then
            return 0  # This is control plane
        fi
    fi
    return 1  # Not control plane (worker node)
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Function to display disk information
display_disk_info() {
    local disk=$1
    local size=$(lsblk -b -d -n -o SIZE "$disk" | numfmt --to=iec-i --suffix=B)
    local model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null || echo "Unknown")
    echo "  • $disk ($size) - $model"
}

# Global array to store detected disks
declare -a AVAILABLE_DISKS=()

# Function to detect available disks
detect_available_disks() {
    log_info "Detecting available disks..."
    
    # Reset available disks array
    AVAILABLE_DISKS=()
    
    # Get list of block devices that are actual disks (not partitions)
    # Use lsblk TYPE=disk to correctly identify whole disks including NVMe (nvme0n1)
    # The old [0-9]$ regex incorrectly skipped NVMe disks since they end in digits
    local os_disk_parent=""
    os_disk_parent=$(lsblk -ndo PKNAME $(findmnt -rn -o SOURCE -T / 2>/dev/null | head -1) 2>/dev/null || true)
    
    while IFS= read -r disk; do
        # Skip system/virtual devices
        if [[ "$disk" =~ ^(loop|fd|ram|sr|md|dm-) ]]; then
            continue
        fi
        
        # Skip the OS disk (the parent device of the root mount)
        if [[ -n "$os_disk_parent" && "$disk" == "$os_disk_parent" ]]; then
            continue
        fi
        
        AVAILABLE_DISKS+=("/dev/$disk")
    done < <(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}' | sort)
    
    if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
        log_warn "No additional disks found. Will use OS disk only."
        return 0
    fi
    
    echo "Available physical disks:"
    for i in "${!AVAILABLE_DISKS[@]}"; do
        local disk_path="${AVAILABLE_DISKS[$i]}"
        local disk_name=$(basename "$disk_path")
        local size=$(lsblk -b -d -n -o SIZE "$disk_path" | numfmt --to=iec-i --suffix=B)
        echo "  $((i+1))) $disk_name ($size)"
    done
}

# Function to handle disk selection
handle_disk_selection() {
    echo
    echo "💡 Option 2: Use dedicated physical disk(s)"
    detect_available_disks
    
    echo
    echo "Your choice:"
    echo "  • Enter 0 for OS disk (no formatting)"
    echo "  • Enter 1,2,3 for specific physical disks (will be formatted)"
    echo "  • Enter all for all physical disks above (will be formatted)"
    echo
    
    read -p "Your choice: " selection
    
    case "$selection" in
        "0"|"none")
            log_info "Using OS disk only - /var/lib/longhorn (no formatting)"
            SELECTED_DISKS=()
            ;;
        "all"|"ALL")
            log_info "Selected all physical disks"
            SELECTED_DISKS=("${AVAILABLE_DISKS[@]}")
            ;;
        *)
            # Parse comma-separated disk numbers
            IFS=',' read -ra DISK_NUMBERS <<< "$selection"
            for num in "${DISK_NUMBERS[@]}"; do
                local disk_num=$(echo "$num" | tr -d ' ')
                if [[ "$disk_num" =~ ^[0-9]+$ ]]; then
                    local disk_index=$((disk_num - 1))
                    
                    if [[ $disk_index -ge 0 && $disk_index -lt ${#AVAILABLE_DISKS[@]} ]]; then
                        local disk_path="${AVAILABLE_DISKS[$disk_index]}"
                        SELECTED_DISKS+=("$disk_path")
                    else
                        log_warn "Invalid disk number: $disk_num"
                    fi
                fi
            done
            ;;
    esac
    
    if [ ${#SELECTED_DISKS[@]} -gt 0 ]; then
        echo
        log_info "Selected ${#SELECTED_DISKS[@]} disk(s):"
        for disk in "${SELECTED_DISKS[@]}"; do
            local size=$(lsblk -b -d -n -o SIZE "$disk" | numfmt --to=iec-i --suffix=B)
            echo "  • $disk ($size)"
        done
        echo
        echo -e "[⚠] ${YELLOW}⚠️  WARNING: Selected disks will be FORMATTED (all data will be lost)${NC}"
        read -p "Continue with formatting? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Disk formatting cancelled"
            exit 0
        fi
    fi
}

# Function to format and mount disks
format_and_mount_disks() {
    if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Validate sudo access upfront to avoid half-formatted disks
    if ! sudo -v 2>/dev/null; then
        log_error "sudo access required for disk formatting. Run as root or configure sudo."
        return 1
    fi
    
    log_info "Formatting and mounting disks..."
    
    # Create mount directory
    local mount_base="$LONGHORN_MOUNT_BASE"
    sudo mkdir -p "$mount_base"
    
    for disk in "${SELECTED_DISKS[@]}"; do
        local disk_name=$(basename "$disk")
        local mount_point="$mount_base/disk-$disk_name"
        
        log_info "Processing $disk..."
        
        # Clean up existing state (restored from original de1af24 implementation)
        sudo umount "$disk"* 2>/dev/null || true
        sudo wipefs -a "$disk" &>/dev/null || true
        
        # Create partition
        log_info "Creating partition on $disk..."
        sudo parted -s "$disk" mklabel gpt mkpart primary ext4 0% 100%
        
        # Determine partition name dynamically
        log_info "Detecting partition on $disk..."
        local partition=""
        local max_detection_wait=5
        local detection_wait=0
        
        while [ $detection_wait -lt $max_detection_wait ]; do
            partition=$(lsblk -lnp -o NAME "$disk" | sed -n '2p')
            if [ -n "$partition" ]; then
                break
            fi
            sleep 1
            detection_wait=$((detection_wait + 1))
        done

        local max_wait=10
        local wait_count=0
        while [ $wait_count -lt $max_wait ]; do
            if [ -b "$partition" ]; then
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        
        if [ ! -b "$partition" ]; then
            log_error "Partition $partition not found after formatting"
            continue
        fi
        
        # Format with ext4
        log_info "Formatting $partition..."
        sudo mkfs.ext4 -F "$partition"
        
        # Create mount point
        sudo mkdir -p "$mount_point"
        
        # Mount the disk
        log_info "Mounting $partition to $mount_point..."
        sudo mount "$partition" "$mount_point"
        
        # Add to fstab for persistence
        if ! grep -q "$mount_point" /etc/fstab; then
            local uuid=$(sudo blkid -s UUID -o value "$partition")
            echo "UUID=$uuid  $mount_point  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
        fi
        
        # Add to mounted disks array
        MOUNTED_DISKS+=("$mount_point")
        
        log_success "Mounted $disk at $mount_point"
    done
    
    log_success "All disks formatted and mounted"
}

# Function to install Longhorn
install_longhorn() {
    if ! is_control_plane; then
        log_warn "kubectl not available (worker node) - Longhorn installation via control plane only"
        log_info "Disks are mounted and ready. Longhorn will be installed from control plane."
        log_info "Mounted disks: ${MOUNTED_DISKS[*]}"
        return 0
    fi
    
    # Create namespace
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Helm repository
    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    
    # Determine default data path
    local default_path="/var/lib/longhorn"
    if [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        default_path="${MOUNTED_DISKS[0]}"
        log_info "Using dedicated disk as default: $default_path"
    else
        log_info "Using OS disk as default: $default_path"
    fi
    
    # Pre-validate and fix ConfigMap before installation starts
    log_info "Pre-validating Longhorn ConfigMap..."
    if kubectl get configmap longhorn-storageclass -n longhorn-system &>/dev/null; then
        local config_replicas=$(kubectl get configmap longhorn-storageclass -n longhorn-system -o jsonpath='{.data.storageclass.yaml}' | grep -o 'numberOfReplicas: "[0-9]*"' | cut -d'"' -f2)
        if [ "$config_replicas" != "$LONGHORN_REPLICA_COUNT" ]; then
            log_info "Fixing Longhorn ConfigMap before installation..."
            fix_longhorn_configmap_replicas
        fi
    fi
    
    # Install/upgrade Longhorn (helm upgrade --install is idempotent: installs if missing,
    # upgrades if present). The old longhorn_installed guard from a634b62 was replaced by
    # the is_control_plane check above — workers skip entirely, control plane always applies
    # latest settings to ensure consistency.
    log_info "Installing Longhorn via Helm (this may take a few minutes)..."
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version "$LONGHORN_VERSION" \
        --set defaultSettings.defaultReplicaCount=$LONGHORN_REPLICA_COUNT \
        --set persistence.defaultClass=true \
        --set persistence.defaultClassParameter.numberOfReplicas=$LONGHORN_REPLICA_COUNT \
        --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
        --set defaultSettings.autoSalvage=true \
        --set defaultSettings.disableSchedulingOnCordonedNode=true \
        --set defaultSettings.nodeDrainPolicy='block-if-contains-last-replica' \
        --set defaultSettings.replicaSoftAntiAffinity=false \
        --set defaultSettings.replicaZoneSoftAntiAffinity=true \
        --set defaultSettings.defaultDataPath="$default_path" \
        --set defaultSettings.fastReplicaRebuildEnabled=true \
        --set defaultSettings.replicaAutoBalance="best-effort" \
        --set defaultSettings.storageOverProvisioningPercentage=200 \
        --set defaultSettings.storageMinimalAvailablePercentage=10 \
        --set persistence.defaultClassReplicaCount=$LONGHORN_REPLICA_COUNT \
        --wait \
        --timeout 10m
    
    # Set as default storage class (retry — API may be briefly unavailable after Helm install)
    if ! kubectl_longhorn_retry 3 "Setting default StorageClass" \
        kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'; then
        log_warn "Failed to set longhorn as default StorageClass — set manually: kubectl patch storageclass longhorn -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
    fi
    
    # Verify and fix StorageClass parameters (defensive programming with improved strategy)
    log_info "Verifying Longhorn StorageClass configuration..."
    local max_attempts=3
    local attempt=1
    local wait_time=5
    local replicas_correct=false
    
    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt of $max_attempts to verify StorageClass..."
        
        if kubectl get storageclass longhorn &>/dev/null; then
            local current_replicas=$(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || echo "3")
            if [ "$current_replicas" = "$LONGHORN_REPLICA_COUNT" ]; then
                replicas_correct=true
                log_success "StorageClass correctly configured with numberOfReplicas=$LONGHORN_REPLICA_COUNT"
                break
            else
                log_warn "StorageClass has wrong replica count ($current_replicas), fixing..."
                # Use the improved ConfigMap-based fix
                if fix_storageclass_replicas; then
                    replicas_correct=true
                    break
                else
                    log_warn "Fix attempt $attempt failed"
                    if [ $attempt -lt $max_attempts ]; then
                        log_info "Retrying in ${wait_time}s..."
                        sleep $wait_time
                        wait_time=$((wait_time + 2))  # Incremental backoff
                    fi
                fi
            fi
        else
            log_info "Waiting for StorageClass to be created..."
            sleep 3
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$replicas_correct" = true ]; then
        log_success "StorageClass correctly configured with numberOfReplicas=$LONGHORN_REPLICA_COUNT"
    else
        log_warn "Failed to configure StorageClass after $max_attempts attempts"
        log_warn "StorageClass replica count may not match requested value ($LONGHORN_REPLICA_COUNT)"
        log_warn "Manual fix required after installation: check 'kubectl get sc longhorn -o yaml'"
        log_warn "To fix manually: update longhorn-storageclass ConfigMap, then delete StorageClass"
        # Graceful degradation - continue installation instead of failing
        log_info "Continuing with installation (StorageClass can be fixed later)..."
    fi
    
    # Expose UI via LoadBalancer (retry — service may not be ready immediately)
    if ! kubectl_longhorn_retry 3 "Exposing Longhorn UI via LoadBalancer" \
        kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"LoadBalancer"}}'; then
        log_warn "Failed to expose Longhorn UI — run manually: kubectl patch svc longhorn-frontend -n longhorn-system -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'"
    fi
    
    # Add subdomain annotation so sync_registry picks up the correct local_name
    kubectl_longhorn_retry 3 "Adding subdomain annotation to longhorn-frontend" \
        kubectl annotate svc longhorn-frontend -n longhorn-system \
            mynodeone.io/subdomain=longhorn --overwrite || true
    
    # Ensure the bare longhorn manager service stays ClusterIP (not LoadBalancer)
    # to avoid it appearing as a public-eligible service in the registry
    local longhorn_svc_type=$(kubectl get svc longhorn -n longhorn-system \
        -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")
    if [[ "$longhorn_svc_type" == "LoadBalancer" ]]; then
        log_info "Resetting bare longhorn service to ClusterIP (internal API only)..."
        kubectl_longhorn_retry 3 "Resetting longhorn service to ClusterIP" \
            kubectl patch svc longhorn -n longhorn-system -p '{"spec":{"type":"ClusterIP"}}' || true
    fi
    
    log_success "Longhorn installed successfully"
    
    # Return 0 even if StorageClass has issues - bootstrap should continue
    return 0
}

# Fix Longhorn ConfigMap replica count
fix_longhorn_configmap_replicas() {
    log_info "Updating Longhorn ConfigMap to use numberOfReplicas=$LONGHORN_REPLICA_COUNT..."
    
    cat <<EOF | kubectl apply -n longhorn-system -f - || { log_warn "Failed to apply Longhorn ConfigMap"; return 1; }
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-storageclass
  namespace: longhorn-system
data:
  storageclass.yaml: |
    kind: StorageClass
    apiVersion: storage.k8s.io/v1
    metadata:
      name: longhorn
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: driver.longhorn.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    parameters:
      numberOfReplicas: "$LONGHORN_REPLICA_COUNT"
      staleReplicaTimeout: "30"
      fromBackup: ""
      fsType: "ext4"
      dataLocality: "disabled"
EOF
    return 0
}

# Fix StorageClass with proper ConfigMap approach
fix_storageclass_replicas() {
    log_info "Fixing StorageClass replica count using ConfigMap approach..."
    
    # First update the ConfigMap
    if fix_longhorn_configmap_replicas; then
        log_info "ConfigMap fixed, now recreating StorageClass..."
        
        # Delete the StorageClass - Longhorn will recreate it from the updated ConfigMap
        kubectl delete storageclass longhorn --ignore-not-found=true
        
        # Wait for Longhorn to recreate the StorageClass
        local max_wait=30
        local wait_count=0
        while [ $wait_count -lt $max_wait ]; do
            if kubectl get storageclass longhorn &>/dev/null; then
                local current_replicas=$(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || echo "unknown")
                if [ "$current_replicas" = "$LONGHORN_REPLICA_COUNT" ]; then
                    log_success "StorageClass recreated with correct replica count"
                    return 0
                fi
            fi
            sleep 2
            wait_count=$((wait_count + 2))
        done
        
        log_warn "StorageClass recreation timed out"
        return 1
    else
        log_warn "ConfigMap update failed, trying fallback method..."
        return 1
    fi
}

# Add disks to Longhorn node configuration
# Arguments:
#   $1: true if Longhorn was newly installed/upgraded via Helm, false if skipped
add_node_disks_to_longhorn() {
    local newly_installed="${1:-false}"
    
    if [[ ${#MOUNTED_DISKS[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Configuring disks in Longhorn..."
    
    # Get actual node name
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect Kubernetes node name, skipping Longhorn disk configuration"
        log_info "Configure disks via Longhorn UI manually if needed"
        return 0
    fi
    
    # Check if Longhorn node exists
    if ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
        log_info "Longhorn node not yet created, skipping disk configuration"
        return 0
    fi
    
    # Get existing disk entries so we don't create duplicates
    # Longhorn auto-discovers disks and creates default-disk-* entries for paths
    # set via defaultDataPath. Adding another entry for the same path causes duplicates.
    local existing_disks_json=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null | \
        jq -r '.spec.disks // {} | to_entries[] | "\(.key):\(.value.path)"' 2>/dev/null)
    
    # Configure each mounted disk
    for disk_path in "${MOUNTED_DISKS[@]}"; do
        local disk_name=$(basename "$disk_path")
        
        # Check if any existing Longhorn disk entry already points to this path
        local existing_entry=""
        existing_entry=$(echo "$existing_disks_json" | grep ":${disk_path}$" | head -1 | cut -d: -f1)
        if [[ -n "$existing_entry" ]]; then
            log_info "Disk at $disk_path already registered as '$existing_entry' — skipping"
            continue
        fi
        
        # Skip first disk if it's the default data path (Helm sets defaultDataPath)
        if [[ "$disk_path" == "${MOUNTED_DISKS[0]}" ]] && [[ "$newly_installed" == "true" ]]; then
            log_info "Skipping first disk (handled by Helm defaultDataPath)"
            continue
        fi
        
        log_info "Adding disk $disk_name to Longhorn node $node_name..."
        
        # Add disk via Longhorn node spec (spec.disks is an object/map, not array)
        if ! kubectl_longhorn_retry 3 "Longhorn syncing, adding disk $disk_name" \
            kubectl patch nodes.longhorn.io "$node_name" -n longhorn-system --type merge \
            -p "{\"spec\":{\"disks\":{\"$disk_name\":{\"path\":\"$disk_path\",\"allowScheduling\":true}}}}"; then
            log_warn "Failed to add disk $disk_name after retries — configure via Longhorn UI"
        fi
    done
    
    log_success "Longhorn disk configuration complete"
}

# Function to check for disk UUID mismatches
# When a disk is reformatted, Longhorn's stored UUID no longer matches the actual
# disk. This makes the disk show as "not ready" and "not schedulable".
#
# Two-layer detection (defensive programming):
#   Layer 1 (proactive): Compare longhorn-disk.cfg on each mounted disk against
#           Longhorn's stored diskUUID — instant, no dependency on Longhorn polling
#   Layer 2 (fallback):  Check Longhorn's diskStatus conditions for mismatch errors
#
# Recovery: Delete the Longhorn node resource → Longhorn manager recreates it with
# correct UUIDs. If manager gets stuck, restart the manager pod.
check_disk_uuid_mismatches() {
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_info "kubectl not available - UUID mismatch check skipped"
        return 0
    fi
    
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping UUID mismatch check"
        return 0
    fi
    
    # Check if Longhorn node exists
    if ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
        log_info "Longhorn node not yet created, skipping UUID check"
        return 0
    fi
    
    local node_json=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null)
    local has_mismatch=""
    
    # --- Layer 1: Proactive UUID comparison ---
    # Longhorn writes a longhorn-disk.cfg file to each disk with its UUID.
    # When a disk is reformatted, this file is destroyed. Compare the UUID
    # on disk against what Longhorn has stored in its CRD status.
    # This works immediately — no need to wait for Longhorn's condition polling.
    while IFS=: read -r disk_name disk_path stored_uuid; do
        if [[ -z "$disk_name" || -z "$disk_path" ]]; then
            continue
        fi
        
        local cfg_file="$disk_path/longhorn-disk.cfg"
        if [[ ! -f "$cfg_file" ]]; then
            # longhorn-disk.cfg missing — disk was reformatted
            log_info "  $disk_path: longhorn-disk.cfg missing (disk was reformatted)"
            has_mismatch="$disk_name"
            break
        fi
        
        if [[ -n "$stored_uuid" ]]; then
            local disk_uuid=$(jq -r '.diskUUID // ""' "$cfg_file" 2>/dev/null)
            if [[ -n "$disk_uuid" && "$disk_uuid" != "$stored_uuid" ]]; then
                log_info "  $disk_path: UUID on disk ($disk_uuid) != Longhorn record ($stored_uuid)"
                has_mismatch="$disk_name"
                break
            fi
        fi
    done < <(echo "$node_json" | jq -r '
        (.status.diskStatus // {}) as $status |
        .spec.disks // {} | to_entries[] |
        "\(.key):\(.value.path):\($status[.key].diskUUID // "")"
    ' 2>/dev/null)
    
    # --- Layer 2: Fallback — check Longhorn's own condition reporting ---
    # Longhorn eventually detects UUID mismatches and reports them in conditions.
    # This catches cases where the disk file exists but has a different UUID that
    # Layer 1 might miss (e.g., partial reformat, disk swap).
    if [[ -z "$has_mismatch" ]]; then
        has_mismatch=$(echo "$node_json" | \
            jq -r '.status.diskStatus // {} | to_entries[] | select(
                (.value.conditions[]?.reason == "DiskFilesystemChanged") or
                (.value.conditions[]? | select(.type == "Ready" and .status == "False") | .message | test("diskUUID.*match|UUID.*mismatch"; "i"))
            ) | .key' 2>/dev/null | head -1)
    fi
    
    # --- Recovery ---
    if [[ -n "$has_mismatch" ]]; then
        log_warn "Disk UUID mismatch detected on '$has_mismatch' (disk was reformatted)"
        log_info "Deleting Longhorn node to reset disk UUIDs..."
        
        # Delete the Longhorn node to force re-registration with correct UUIDs
        if ! kubectl_longhorn_retry 3 "Longhorn syncing, deleting node for UUID fix" \
            kubectl delete nodes.longhorn.io "$node_name" -n longhorn-system; then
            log_error "Failed to delete Longhorn node for UUID fix after retries"
            return 1
        fi
        
        # Wait for Longhorn manager to recreate the node resource
        # Phase 1: Wait up to 30s for auto-recreation
        local waited=0
        local recreated=false
        log_info "Waiting for Longhorn to recreate node resource..."
        while [ $waited -lt 30 ]; do
            if kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
                recreated=true
                break
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        # Phase 2: If not recreated, restart the longhorn-manager pod on this node
        # The manager sometimes gets stuck after node deletion and needs a restart
        if [ "$recreated" = false ]; then
            log_info "Node not recreated yet — restarting Longhorn manager on this node..."
            local manager_pod=$(kubectl get pods -n longhorn-system -l app=longhorn-manager \
                --field-selector spec.nodeName="$node_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [[ -n "$manager_pod" ]]; then
                kubectl delete pod "$manager_pod" -n longhorn-system --grace-period=30 2>/dev/null || true
                log_info "Waiting for manager pod to restart and recreate node..."
                sleep 15
            fi
            
            # Phase 3: Wait another 60s after manager restart
            waited=0
            while [ $waited -lt 60 ]; do
                if kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
                    recreated=true
                    break
                fi
                sleep 5
                waited=$((waited + 5))
            done
        fi
        
        if [ "$recreated" = true ]; then
            log_success "Longhorn node recreated with correct disk UUIDs"
            sleep 10  # Let disk status sync before returning
            return 0
        else
            log_error "Longhorn node was not recreated after 90s"
            log_warn "Manual fix: kubectl delete pod -n longhorn-system -l app=longhorn-manager --field-selector spec.nodeName=$node_name"
            return 1
        fi
    else
        log_success "No disk UUID mismatches detected"
    fi
    
    return 0
}

# Function to optimize disk reservations
optimize_disk_reservations() {
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_info "kubectl not available - disk reservation optimization skipped"
        return 0
    fi
    
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping reservation optimization"
        return 0
    fi
    
    # Get disk configuration
    local disks_json=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null)
    if [[ -z "$disks_json" ]]; then
        log_warn "Could not retrieve Longhorn node info, skipping reservation optimization"
        return 0
    fi
    
    # Process each disk (using process substitution to avoid subshell)
    while IFS=: read -r disk_name disk_path; do
        if [[ -n "$disk_name" && -n "$disk_path" ]]; then
            # Calculate optimal reservation (5-10% based on disk size)
            # df --output=size returns 1K blocks; multiply by 1024 for bytes
            local disk_size_bytes=$(df --output=size "$disk_path" 2>/dev/null | tail -1 | awk '{print $1 * 1024}' || echo "0")
            # Guard against empty/non-numeric values from df failure
            if ! [[ "$disk_size_bytes" =~ ^[0-9]+$ ]]; then
                disk_size_bytes=0
            fi
            local disk_size_gb=$((disk_size_bytes / 1024 / 1024 / 1024))
            
            local reservation_gb=0
            if [ $disk_size_gb -lt 100 ]; then
                reservation_gb=5  # 5GB for small disks
            elif [ $disk_size_gb -lt 1000 ]; then
                reservation_gb=50  # 50GB for medium disks
            else
                reservation_gb=250  # 250GB for large disks
            fi
            
            # Update disk reservation (storageReserved in bytes, within disk spec)
            local reservation_bytes=$((reservation_gb * 1024 * 1024 * 1024))
            if kubectl_longhorn_retry 3 "Longhorn syncing, setting reservation for $disk_name" \
                kubectl patch nodes.longhorn.io "$node_name" -n longhorn-system --type merge \
                -p "{\"spec\":{\"disks\":{\"$disk_name\":{\"storageReserved\":$reservation_bytes}}}}"; then
                log_info "  $disk_path: Reserved ${reservation_gb}GB (Applied)"
            else
                log_warn "  $disk_path: Failed to set ${reservation_gb}GB reservation after 3 attempts"
                log_warn "  Set via Longhorn UI: Node → $node_name → $disk_name → Storage Reserved"
            fi
        fi
    done < <(echo "$disks_json" | jq -r '.spec.disks | to_entries[] | "\(.key):\(.value.path)"' 2>/dev/null)
    
    log_success "Disk reservations optimized"
}

# Function to register Longhorn configuration in node registry
register_in_node_registry() {
    if ! is_control_plane; then
        log_info "Node registry update skipped (worker node - managed by control plane)"
        return 0
    fi
    
    if ! [ -f "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" ]; then
        log_warn "Node registry script not found, skipping registration"
        return 0
    fi
    
    log_info "Updating node registry with Longhorn configuration..."
    
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_info "kubectl not available - node registry update skipped"
        return 0
    fi
    
    # Get node name from Kubernetes
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect Kubernetes node name, skipping node registration"
        return 0
    fi
    
    # 1. Register cluster node first (idempotent)
    local node_role="worker"
    if is_control_plane; then
        node_role="control-plane"
    fi
    bash "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" register-cluster-node \
        --name "$node_name" \
        --role "$node_role" \
        --location "${NODE_LOCATION:-home}" || {
        log_warn "Failed to register cluster node"
        return 1
    }
    
    # Build disk list CSV
    local disk_list=""
    for disk_path in "${MOUNTED_DISKS[@]}"; do
        if [[ -n "$disk_list" ]]; then
            disk_list="$disk_list,"
        fi
        disk_list="$disk_list$disk_path"
    done
    
    # 2. Update Longhorn configuration
    if [[ -n "$disk_list" ]]; then
        bash "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" update-longhorn \
            --name "$node_name" \
            --disks "$disk_list" || {
            log_warn "Failed to update node registry Longhorn config"
            return 0
        }
    fi
    
    log_success "Updated Longhorn configuration for $node_name"
}

# Function to sync DNS entries
sync_dns_entries() {
    if ! is_control_plane; then
        log_info "DNS sync skipped (worker node - DNS managed by control plane)"
        return 0
    fi
    
    if ! [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
        log_warn "DNS sync script not found, skipping DNS sync"
        return 0
    fi
    
    log_info "Syncing DNS entries..."
    bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" || log_warn "DNS sync failed"
}

# Function to register Longhorn UI in service registry
register_longhorn_ui() {
    if ! is_control_plane; then
        log_info "Longhorn UI registration skipped (worker node - UI managed by control plane)"
        return 0
    fi
    
    if ! [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
        log_warn "Service registry script not found, skipping UI registration"
        return 0
    fi
    
    log_info "Registering Longhorn UI in service registry..."
    
    # Initialize registry if needed
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" init || true
    
    # Register Longhorn service
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "longhorn" \
        "longhorn" \
        "longhorn-system" \
        "longhorn-frontend" \
        "80" \
        "true" || {
        log_warn "Failed to register Longhorn UI in service registry"
        return 0
    }
    
    log_success "Longhorn UI registered in service registry"
}

# Main installation function
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Longhorn Interactive Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_info "Longhorn provides distributed block storage for Kubernetes"
    echo
    
    # Replica count selection — only on control plane (cluster-wide setting)
    # Workers just add disks to the existing Longhorn service
    if is_control_plane; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Longhorn Replica Count"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "How many copies of each volume should Longhorn maintain?"
        echo
        echo "  1) 1 replica (recommended for home lab)"
        echo "     • Data stored on a single node — no cross-node replication"
        echo "     • No network overhead over Tailscale"
        echo "     • 1x storage usage — use backups for data safety"
        echo
        echo "  2) 2 replicas"
        echo "     • Data copied to 2 nodes — survives 1 node failure"
        echo "     • Requires 2+ nodes with Longhorn disks"
        echo "     • 2x storage usage + network sync traffic"
        echo
        echo "  3) 3 replicas"
        echo "     • Data copied to 3 nodes — survives 2 node failures"
        echo "     • Requires 3+ nodes with Longhorn disks"
        echo "     • 3x storage usage + significant network sync traffic"
        echo
        
        local replica_choice=""
        while true; do
            read -p "Select replica count [1/2/3] (default: ${LONGHORN_REPLICA_COUNT}): " replica_choice
            replica_choice="${replica_choice:-$LONGHORN_REPLICA_COUNT}"
            if [[ "$replica_choice" =~ ^[123]$ ]]; then
                LONGHORN_REPLICA_COUNT="$replica_choice"
                break
            else
                echo "  Invalid choice. Please enter 1, 2, or 3."
            fi
        done
        
        log_info "Replica count set to: $LONGHORN_REPLICA_COUNT"
        if [[ "$LONGHORN_REPLICA_COUNT" -gt 1 ]]; then
            log_warn "Multi-replica mode: ensure you have $LONGHORN_REPLICA_COUNT+ nodes with Longhorn storage"
            log_info "Drain protection is enabled (block-if-contains-last-replica)"
        fi
        echo
    else
        log_info "Worker node — replica count is managed by the control plane"
        echo
    fi
    
    # Disk selection section
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Longhorn Disk Selection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_info "Detecting available disks..."
    
    echo "Option 1: Use OS disk (no additional drives needed)"
    echo "  0) Use OS disk only - /var/lib/longhorn (no formatting)"
    echo
    
    handle_disk_selection
    
    # Format and mount selected disks
    format_and_mount_disks
    
    # Install Longhorn
    install_longhorn
    
    # Add disks to Longhorn configuration
    # On control plane: "true" = Helm installed Longhorn with defaultDataPath
    # On worker: "false" = Helm skipped, need to manually configure all disks
    if is_control_plane; then
        add_node_disks_to_longhorn "true"
    else
        add_node_disks_to_longhorn "false"
    fi
    
    # Check for disk UUID mismatches
    check_disk_uuid_mismatches
    
    # Wait for Longhorn to finish syncing disk status before patching reservations
    # On worker nodes, Longhorn auto-discovers disks and needs time to sync
    if ! is_control_plane && [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        log_info "Waiting for Longhorn to sync disk status..."
        sleep 10
    fi
    
    # Optimize disk reservations
    optimize_disk_reservations
    
    # Register in node registry
    register_in_node_registry
    
    # Register Longhorn UI
    register_longhorn_ui
    
    # Sync DNS entries
    sync_dns_entries
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if is_control_plane; then
        echo "  Longhorn Installation Complete"
    else
        echo "  Longhorn Disk Setup Complete"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    if is_control_plane; then
        log_success "Longhorn is now default storage class (replicas: $LONGHORN_REPLICA_COUNT)"
        # Detect cluster domain: prefer env var (set by bootstrap), then ConfigMap, then fallback
        local cluster_domain="${CLUSTER_DOMAIN:-}"
        if [[ -z "$cluster_domain" ]]; then
            cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
        fi
        if [[ -z "$cluster_domain" ]]; then
            cluster_domain="mynodeone"
        fi
        log_info "UI will be accessible at: http://longhorn.${cluster_domain}.local"
    else
        log_success "Disks added to Longhorn storage pool"
        log_info "Replica count and storage class are managed by the control plane"
    fi
    echo
    if [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        log_info "Configured disks:"
        for disk_path in "${MOUNTED_DISKS[@]}"; do
            local disk_size=$(df -h "$disk_path" 2>/dev/null | awk 'NR==2 {print $2}')
            echo "  • $disk_path ($disk_size)"
        done
    else
        log_info "Using OS disk: /var/lib/longhorn"
    fi
    echo
    
    log_success "Longhorn $(is_control_plane && echo 'installed' || echo 'configured') successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
