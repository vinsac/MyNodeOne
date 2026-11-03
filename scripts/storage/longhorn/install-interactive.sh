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
source "$PROJECT_ROOT/scripts/lib/versions.sh"
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

# Set KUBECONFIG appropriately
export_k8s_config

set -euo pipefail

# Every disk this script erases goes through these checks
source "$SCRIPT_DIR/../lib/disk-safety.sh"
if [ "$EUID" -eq 0 ]; then
    disk_safety_init ""
else
    disk_safety_init "sudo"
fi

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

# Longhorn replica count — can be overridden via env var or interactive prompt
# Default: 1 (single replica, recommended for home lab / Tailscale networking)
LONGHORN_REPLICA_COUNT="${LONGHORN_REPLICA_COUNT:-1}"

# Standard mount path for Longhorn disks (project-wide convention, also used by
# node-registry-manager.sh, add-disk-to-longhorn.sh, uninstall-mynodeone.sh, fix-usb-disk-boot.sh)
LONGHORN_MOUNT_BASE="/mnt/longhorn-disks"

# Global arrays for disk management
declare -a MOUNTED_DISKS=()
# Disks registered with Longhorn during this run. Longhorn hasn't written their config yet.
declare -a JUST_ADDED_DISKS=()
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

    AVAILABLE_DISKS=()

    # Lists the disks that can be offered, and explains why the others can't
    if ! disk_safety_scan; then
        log_warn "Could not inspect disks. Will use OS disk only."
        return 0
    fi

    AVAILABLE_DISKS=("${DISK_SAFETY_ELIGIBLE[@]}")

    if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
        log_warn "No disks can be safely formatted. Will use OS disk only."
    fi
    return 0
}

# Function to handle disk selection
handle_disk_selection() {
    # A run without a terminal can't confirm a wipe, so it never selects a disk
    if ! disk_safety_is_interactive; then
        log_warn "No terminal available for disk confirmation: no disk will be formatted."
        log_info "Using OS disk only - /var/lib/longhorn"
        SELECTED_DISKS=()
        return 0
    fi

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
                        local already_selected=false
                        local chosen
                        for chosen in "${SELECTED_DISKS[@]}"; do
                            if [[ "$chosen" == "$disk_path" ]]; then
                                already_selected=true
                            fi
                        done
                        if [[ "$already_selected" == false ]]; then
                            SELECTED_DISKS+=("$disk_path")
                        fi
                    else
                        log_warn "Invalid disk number: $disk_num"
                    fi
                fi
            done
            ;;
    esac
    
    if [ ${#SELECTED_DISKS[@]} -gt 0 ]; then
        echo
        log_info "Selected ${#SELECTED_DISKS[@]} disk(s). Each must be confirmed by name."
        echo -e "[⚠] ${YELLOW}⚠️  WARNING: Selected disks will be FORMATTED (all data will be lost)${NC}"
        # Confirm every disk before erasing any, so cancelling leaves all of them intact
        local disk
        for disk in "${SELECTED_DISKS[@]}"; do
            if ! disk_safety_confirm_wipe "$disk"; then
                log_error "Disk formatting cancelled. No disk was changed."
                exit 1
            fi
        done
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
        
        # Re-checks the disk and erases its signatures. Mounted disks are refused
        # rather than unmounted, and any failure stops the install.
        if ! disk_safety_wipe "$disk"; then
            log_error "Could not safely erase $disk. Stopping."
            exit 1
        fi

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
            if [ -n "$partition" ] && sudo test -b "$partition"; then
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done

        if [ -z "$partition" ] || ! sudo test -b "$partition"; then
            log_error "Partition '$partition' not found after partitioning $disk. Stopping."
            exit 1
        fi
        
        # Format with ext4
        log_info "Formatting $partition..."
        sudo mkfs.ext4 -F "$partition"
        
        # Create mount point
        sudo mkdir -p "$mount_point"
        
        # Mount the disk
        log_info "Mounting $partition to $mount_point..."
        sudo mount "$partition" "$mount_point"
        
        # Add to fstab for persistence. The disk was just formatted, so its UUID is new
        # and any entry already on this mountpoint is stale. Matching the mountpoint
        # field means disk-sda doesn't match disk-sda1.
        local uuid=""
        uuid=$(sudo blkid -s UUID -o value "$partition")
        if [ -z "$uuid" ]; then
            log_error "Could not read the UUID of $partition, so /etc/fstab was not updated. Stopping."
            exit 1
        fi
        sudo bash -s -- "$uuid" "$mount_point" <<'FSTAB_SCRIPT'
set -eu
tmp=$(mktemp /etc/fstab.XXXXXX)
trap 'rm -f "$tmp"' EXIT
awk -v mp="$2" '/^[[:space:]]*#/ || $2 != mp' /etc/fstab > "$tmp"
printf 'UUID=%s  %s  ext4  defaults,nofail  0  2\n' "$1" "$2" >> "$tmp"
chmod 644 "$tmp"
mv "$tmp" /etc/fstab
trap - EXIT
FSTAB_SCRIPT
        
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
#
# defaultDataPath only applies when Longhorn creates a node, so it can't be assumed to
# have covered a disk. The node resource is the only record of what's registered: a
# disk is added unless an entry already has its path.
add_node_disks_to_longhorn() {
    if [[ ${#MOUNTED_DISKS[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Configuring disks in Longhorn..."

    # Get actual node name
    local node_name
    node_name=$(get_k8s_node_name)
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

    # An unreadable list must not look like an empty one, or every disk gets a duplicate.
    local node_json=""
    if ! node_json=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null) ||
       ! jq -e '.spec' <<< "$node_json" >/dev/null 2>&1; then
        log_warn "Could not read Longhorn node $node_name, so no disks were added. Configure them via the Longhorn UI, or run this again."
        return 0
    fi

    # Configure each mounted disk
    local disk_path disk_name existing_entry key_path
    for disk_path in "${MOUNTED_DISKS[@]}"; do
        disk_name=$(basename "$disk_path")

        # Longhorn names the entry it makes for defaultDataPath default-disk-*, so
        # compare paths, not names. Exact match, ignoring a trailing slash.
        existing_entry=$(jq -r --arg path "${disk_path%/}" \
            '.spec.disks // {} | to_entries[] | select((.value.path | sub("/+$"; "")) == $path) | .key' \
            <<< "$node_json" | head -1)
        if [[ -n "$existing_entry" ]]; then
            log_info "Disk at $disk_path already registered as '$existing_entry' — skipping"
            continue
        fi

        key_path=$(jq -r --arg key "$disk_name" '.spec.disks[$key].path // ""' <<< "$node_json")
        if [[ -n "$key_path" ]]; then
            log_warn "Longhorn already has a disk named '$disk_name' at $key_path, so $disk_path was not added. Configure it via the Longhorn UI."
            continue
        fi

        log_info "Adding disk $disk_name to Longhorn node $node_name..."

        # Add disk via Longhorn node spec (spec.disks is an object/map, not array)
        if kubectl_longhorn_retry 3 "Longhorn syncing, adding disk $disk_name" \
            kubectl patch nodes.longhorn.io "$node_name" -n longhorn-system --type merge \
            -p "{\"spec\":{\"disks\":{\"$disk_name\":{\"path\":\"$disk_path\",\"allowScheduling\":true}}}}"; then
            JUST_ADDED_DISKS+=("$disk_path")
        else
            log_warn "Failed to add disk $disk_name after retries — configure via Longhorn UI"
        fi
    done

    log_success "Longhorn disk configuration complete"
}

# How to replace one disk's stale Longhorn record by hand. Longhorn's webhook only
# allows removing a disk with scheduling off and nothing scheduled on it.
print_disk_recovery_steps() {
    local node_name="$1" disk_name="$2" disk_path="$3" replicas="$4"
    local ns="longhorn-system"

    log_warn "Replicas recorded on this disk: $replicas"
    echo "  This script changes nothing here. To replace this disk's record, once you've"
    echo "  confirmed that the disk really was replaced or reformatted:"
    echo
    echo "  1. Stop new replicas landing on it:"
    echo "     kubectl patch nodes.longhorn.io $node_name -n $ns --type merge \\"
    echo "       -p '{\"spec\":{\"disks\":{\"$disk_name\":{\"allowScheduling\":false}}}}'"
    echo "  2. List its replicas. Check in the Longhorn UI that each of their volumes has a"
    echo "     healthy replica on another disk, then delete the listed ones:"
    echo "     kubectl get replicas.longhorn.io -n $ns -o json | jq -r --arg n $node_name --arg p $disk_path \\"
    echo "       '.items[] | select(.spec.nodeID == \$n and .spec.diskPath == \$p) | .metadata.name'"
    echo "  3. Remove the record, once step 2 lists nothing:"
    echo "     kubectl patch nodes.longhorn.io $node_name -n $ns --type merge \\"
    echo "       -p '{\"spec\":{\"disks\":{\"$disk_name\":null}}}'"
    echo "  4. When it has gone from status.diskStatus, add the disk back:"
    echo "     kubectl patch nodes.longhorn.io $node_name -n $ns --type merge \\"
    echo "       -p '{\"spec\":{\"disks\":{\"$disk_name\":{\"path\":\"$disk_path\",\"allowScheduling\":true}}}}'"
    echo
    echo "  Do not delete the nodes.longhorn.io resource. Longhorn recreates it with only the"
    echo "  default data path, so every other disk leaves spec.disks, and any volume whose"
    echo "  replicas are on those disks can drop to a single replica."
    echo
}

# Reports disks whose Longhorn record no longer matches what's on the machine. It's
# report-only and always returns 0, whatever it finds.
#
# Things that look like a reformat but aren't, which are not reported as mismatches:
#   - a disk added seconds ago: Longhorn writes longhorn-disk.cfg within about 30s
#   - a disk with no UUID in status yet: Longhorn hasn't taken it on
#   - a disk in fstab that isn't mounted: a nofail disk that failed to mount has no
#     cfg on the empty directory underneath, and Longhorn reports the same condition
#
# A mismatch is a cfg holding a different UUID, or Longhorn's own DiskFilesystemChanged
# or UUID mismatch condition, on a disk that's mounted.
check_disk_uuid_mismatches() {
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_info "kubectl not available - UUID mismatch check skipped"
        return 0
    fi

    local node_name
    node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping UUID mismatch check"
        return 0
    fi

    # Check if Longhorn node exists
    if ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
        log_info "Longhorn node not yet created, skipping UUID check"
        return 0
    fi

    local node_json=""
    if ! node_json=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null); then
        log_warn "Could not read Longhorn node $node_name, skipping UUID check"
        return 0
    fi

    local replicas_json=""
    replicas_json=$(kubectl get replicas.longhorn.io -n longhorn-system -o json 2>/dev/null) || replicas_json=""

    local mismatches=0 disk_name disk_path stored_uuid condition added cfg_file disk_uuid replicas reason
    while IFS='|' read -r disk_name disk_path stored_uuid condition; do
        if [[ -z "$disk_name" || -z "$disk_path" ]]; then
            continue
        fi

        for added in "${JUST_ADDED_DISKS[@]}"; do
            if [[ "$added" == "$disk_path" ]]; then
                log_info "  $disk_path: added just now, not checked yet"
                continue 2
            fi
        done

        if [[ -z "$stored_uuid" ]]; then
            log_info "  $disk_path: Longhorn hasn't recorded a UUID for it yet"
            continue
        fi

        if ! mountpoint -q "$disk_path" 2>/dev/null &&
           awk -v mp="${disk_path%/}" '!/^[[:space:]]*#/ && $2 == mp { found = 1 } END { exit !found }' /etc/fstab 2>/dev/null; then
            log_warn "  $disk_path is in /etc/fstab but isn't mounted, so Longhorn can't use it. Nothing was changed."
            log_warn "  Find out why: sudo mount $disk_path; journalctl -b | grep -i '$(basename "$disk_path")'"
            continue
        fi

        reason=""
        cfg_file="$disk_path/longhorn-disk.cfg"
        if [[ -f "$cfg_file" ]]; then
            disk_uuid=$(jq -r '.diskUUID // ""' "$cfg_file" 2>/dev/null) || disk_uuid=""
            if [[ -n "$disk_uuid" && "$disk_uuid" != "$stored_uuid" ]]; then
                reason="UUID on disk ($disk_uuid) != Longhorn record ($stored_uuid)"
            fi
        fi
        if [[ -z "$reason" && "$condition" == "true" ]]; then
            reason="Longhorn reports DiskFilesystemChanged or a UUID mismatch"
        fi

        if [[ -z "$reason" ]]; then
            if [[ ! -f "$cfg_file" ]]; then
                log_warn "  $disk_path: no longhorn-disk.cfg, but Longhorn has a UUID on record. That's not proof of a reformat, so nothing was changed."
                log_warn "  If this disk was just reformatted, Longhorn reports DiskFilesystemChanged within a minute, and re-running this script prints the steps."
            fi
            continue
        fi

        mismatches=$((mismatches + 1))
        replicas="unknown (could not read replicas)"
        if [[ -n "$replicas_json" ]]; then
            replicas=$(jq -r --arg node "$node_name" --arg path "$disk_path" \
                '[.items[] | select(.spec.nodeID == $node and .spec.diskPath == $path)] | length' \
                <<< "$replicas_json" 2>/dev/null) || replicas="unknown (could not read replicas)"
        fi
        log_warn "Disk UUID mismatch on '$disk_name' ($disk_path): $reason"
        print_disk_recovery_steps "$node_name" "$disk_name" "$disk_path" "$replicas"
    done < <(jq -r '
        (.status.diskStatus // {}) as $status |
        .spec.disks // {} | to_entries[] |
        ($status[.key].conditions // []) as $conditions |
        [
            .key,
            .value.path,
            ($status[.key].diskUUID // ""),
            (any($conditions[];
                .reason == "DiskFilesystemChanged" or
                (.type == "Ready" and .status == "False" and ((.message // "") | test("diskUUID.*match|UUID.*mismatch"; "i"))))
             | tostring)
        ] | join("|")
    ' <<< "$node_json" 2>/dev/null)

    if [[ "$mismatches" -eq 0 ]]; then
        log_success "No disk UUID mismatches detected"
    else
        log_warn "$mismatches disk(s) need the manual steps above. Longhorn was not changed."
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
        "longhorn-frontend" \
        "longhorn" \
        "longhorn-system" \
        "longhorn-frontend" \
        "80" \
        "false" || {
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
    add_node_disks_to_longhorn

    # Report any disk UUID mismatches. This never changes anything.
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
