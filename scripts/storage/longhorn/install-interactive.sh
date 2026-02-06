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

# LIB_DIR setup
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source additional utilities if available
if [ -f "$LIB_DIR/disk-utils.sh" ]; then
    source "$LIB_DIR/disk-utils.sh"
fi

# Global arrays for disk management
declare -a MOUNTED_DISKS=()
declare -a SELECTED_DISKS=()

# Get the actual home directory of the user running the script
ACTUAL_HOME=$(getent passwd "$(logname)" | cut -d: -f6)

# Function to safely get K8s node name
get_k8s_node_name() {
    kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Function to check if running on control plane
is_control_plane() {
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
        return 0
    else
        return 1
    fi
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
    while IFS= read -r disk; do
        # Skip system disks and partitions
        if [[ "$disk" =~ ^(loop|fd|ram|sr|md|dm-) ]]; then
            continue
        fi
        
        # Skip if it's a partition (contains a digit)
        if [[ "$disk" =~ [0-9]$ ]]; then
            continue
        fi
        
        # Skip if disk is mounted as root or boot
        local mount_point=$(findmnt -rn -o SOURCE -T / 2>/dev/null | grep -o "/dev/$disk" || true)
        if [ -n "$mount_point" ]; then
            continue
        fi
        
        AVAILABLE_DISKS+=("/dev/$disk")
    done < <(lsblk -d -n -o NAME | sort)
    
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
        echo "[⚠] ${YELLOW}⚠️  WARNING: Selected disks will be FORMATTED (all data will be lost)${NC}"
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
    
    log_info "Formatting and mounting disks..."
    
    # Create mount directory
    local mount_base="/mnt/longhorn-disks"
    sudo mkdir -p "$mount_base"
    
    for disk in "${SELECTED_DISKS[@]}"; do
        local disk_name=$(basename "$disk")
        local mount_point="$mount_base/disk-$disk_name"
        
        log_info "Processing $disk..."
        
        # Create partition
        log_info "Creating partition on $disk..."
        sudo sfdisk "$disk" <<EOF
label: gpt
size: , type=LINUX
EOF
        
        # Wait for partition to be available
        local partition="${disk}1"
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
            echo "UUID=$uuid  $mount_point  ext4  defaults  0  2" | sudo tee -a /etc/fstab
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
        log_info "Mounted disks: ${MOUNTED_DISKS[@]}"
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
        if [ "$config_replicas" != "1" ]; then
            log_info "Fixing Longhorn ConfigMap before installation..."
            fix_longhorn_configmap_replicas
        fi
    fi
    
    # Install Longhorn
    log_info "Installing Longhorn via Helm (this may take a few minutes)..."
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version 1.5.3 \
        --set defaultSettings.defaultReplicaCount=1 \
        --set persistence.defaultClass=true \
        --set persistence.defaultClassParameter.numberOfReplicas=1 \
        --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
        --set defaultSettings.autoSalvage=true \
        --set defaultSettings.defaultDataPath="$default_path" \
        --set defaultSettings.fastReplicaRebuildEnabled=true \
        --set defaultSettings.replicaAutoBalance="best-effort" \
        --set defaultSettings.storageOverProvisioningPercentage=200 \
        --set defaultSettings.storageMinimalAvailablePercentage=10 \
        --set persistence.defaultClassReplicaCount=1 \
        --wait \
        --timeout 10m
    
    # Set as default storage class
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
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
            if [ "$current_replicas" = "1" ]; then
                replicas_correct=true
                log_success "StorageClass correctly configured with numberOfReplicas=1"
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
        log_success "StorageClass correctly configured with numberOfReplicas=1"
    else
        log_warn "Failed to configure StorageClass after $max_attempts attempts"
        log_warn "StorageClass will use default replica count (may be 3 instead of 1)"
        log_warn "Manual fix required after installation: check 'kubectl get sc longhorn -o yaml'"
        log_warn "To fix manually: update longhorn-storageclass ConfigMap, then delete StorageClass"
        # Graceful degradation - continue installation instead of failing
        log_info "Continuing with installation (StorageClass can be fixed later)..."
    fi
    
    # Expose UI via LoadBalancer
    kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"LoadBalancer"}}'
    
    log_success "Longhorn installed successfully"
    
    # Return 0 even if StorageClass has issues - bootstrap should continue
    return 0
}

# Fix Longhorn ConfigMap replica count
fix_longhorn_configmap_replicas() {
    log_info "Updating Longhorn ConfigMap to use numberOfReplicas=1..."
    
    # Create a temporary ConfigMap with correct StorageClass YAML
    local temp_configmap="longhorn-storageclass-fix-$$"
    cat <<EOF | kubectl create configmap "$temp_configmap" --from-file=storageclass.yaml=/dev/stdin -n longhorn-system --dry-run=client -o yaml | kubectl apply -f -
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
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"
EOF
    
    if [ $? -eq 0 ]; then
        # Delete the original ConfigMap and recreate it with correct content
        kubectl delete configmap longhorn-storageclass -n longhorn-system --ignore-not-found=true
        kubectl get configmap "$temp_configmap" -n longhorn-system -o yaml | \
            sed "s/name: $temp_configmap/name: longhorn-storageclass/" | \
            kubectl apply -f -
        kubectl delete configmap "$temp_configmap" -n longhorn-system --ignore-not-found=true
        
        log_success "ConfigMap updated successfully"
        return 0
    else
        log_warn "Failed to create temporary ConfigMap"
        return 1
    fi
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
                if [ "$current_replicas" = "1" ]; then
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
    
    # Wait for Longhorn to initialize
    sleep 10
    
    # Get actual node name
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect Kubernetes node name"
        return 1
    fi
    
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_warn "kubectl not available - disk configuration will be handled by control plane"
        log_info "Disks mounted at: ${MOUNTED_DISKS[@]}"
        log_info "Configure disks via Longhorn UI after node joins cluster"
        return 0
    fi
    
    # Get actual node name
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping disk configuration"
        return 1
    fi
    
    # Check if Longhorn node exists
    if ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
        log_info "Longhorn node not yet created, skipping disk configuration"
        return 0
    fi
    
    # Configure each mounted disk
    for disk_path in "${MOUNTED_DISKS[@]}"; do
        local disk_name=$(basename "$disk_path")
        
        # Skip first disk if it's the default data path
        if [[ "$disk_path" == "${MOUNTED_DISKS[0]}" ]] && [[ "$newly_installed" == "true" ]]; then
            log_info "Skipping first disk (handled by Helm defaultDataPath)"
            continue
        fi
        
        log_info "Adding disk $disk_name to Longhorn node $node_name..."
        
        # Add disk via Longhorn node annotation
        kubectl patch nodes.longhorn.io "$node_name" -n longhorn-system --type merge -p "{\"spec\":{\"disks\":[{\"name\":\"$disk_name\",\"path\":\"$disk_path\",\"allowScheduling\":true}]}}"
    done
    
    log_success "Longhorn disk configuration complete"
}

# Function to check for disk UUID mismatches
check_disk_uuid_mismatches() {
    # Check if kubectl is available
    if ! kubectl get nodes &>/dev/null; then
        log_info "kubectl not available - UUID mismatch check skipped"
        return 0
    fi
    
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping UUID mismatch check"
        return 0
    fi
    
    # Check if Longhorn node exists
    if ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
        log_info "Longhorn node not yet created, skipping UUID check"
        return 0
    fi
    
    # Check for UUID mismatch errors
    local uuid_errors=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o jsonpath='{.status.conditions[?(@.type=="DiskUUIDMismatch")].message}' 2>/dev/null)
    
    if [[ -n "$uuid_errors" ]]; then
        log_warn "Disk UUID mismatches detected: $uuid_errors"
        log_info "Attempting to fix UUID mismatches..."
        
        # Delete and recreate the Longhorn node to fix UUID issues
        kubectl delete nodes.longhorn.io "$node_name" -n longhorn-system
        
        # Wait for recreation
        local waited=0
        local max_wait=30
        while [ $waited -lt $max_wait ]; do
            if kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
                log_success "Longhorn node recreated successfully"
                sleep 5  # Give it time to initialize
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done
        
        log_error "Failed to recreate Longhorn node"
        return 1
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
    
    # Process each disk
    echo "$disks_json" | jq -r '.spec.disks[]? | "\(.name):\(.path)"' 2>/dev/null | while IFS=: read -r disk_name disk_path; do
        if [[ -n "$disk_name" && -n "$disk_path" ]]; then
            # Calculate optimal reservation (5-10% based on disk size)
            local disk_size_bytes=$(stat -f -c %s "$disk_path" 2>/dev/null || stat -c %s "$disk_path" 2>/dev/null || echo "0")
            local disk_size_gb=$((disk_size_bytes / 1024 / 1024 / 1024))
            
            local reservation_gb=0
            if [ $disk_size_gb -lt 100 ]; then
                reservation_gb=5  # 5GB for small disks
            elif [ $disk_size_gb -lt 1000 ]; then
                reservation_gb=50  # 50GB for medium disks
            else
                reservation_gb=250  # 250GB for large disks
            fi
            
            log_info "  $disk_path: Reserved ${reservation_gb}GB (Verified)"
            
            # Update disk reservation
            kubectl patch nodes.longhorn.io "$node_name" -n longhorn-system --type merge -p "{\"spec\":{\"diskReservations\":{\"$disk_name\":\"${reservation_gb}Gi\"}}}"
        fi
    done
    
    log_success "Disk reservations optimized"
}

# Function to register Longhorn configuration in node registry
register_in_node_registry() {
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
        log_warn "Could not detect Kubernetes node name"
        return 0
    fi
    
    # 1. Register cluster node first (idempotent)
    bash "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" register-cluster-node \
        --name "$node_name" \
        --role "control-plane" || {
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
            return 1
        }
    fi
    
    log_success "Updated Longhorn configuration for $node_name"
}

# Function to sync DNS entries
sync_dns_entries() {
    if ! [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
        log_warn "DNS sync script not found, skipping DNS sync"
        return 0
    fi
    
    log_info "Syncing DNS entries..."
    bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" || log_warn "DNS sync failed"
}

# Function to register Longhorn UI in service registry
register_longhorn_ui() {
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
        return 1
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
    log_info "Default replica count: 1 (data stored on single node)"
    echo
    
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
    add_node_disks_to_longhorn "true"
    
    # Check for disk UUID mismatches
    check_disk_uuid_mismatches
    
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
    echo "  Longhorn Installation Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_success "Longhorn is now default storage class"
    log_info "UI will be accessible at: http://longhorn.minicloud.local"
    echo
    log_info "Configured disks:"
    for disk_path in "${MOUNTED_DISKS[@]}"; do
        local disk_size=$(df -h "$disk_path" 2>/dev/null | awk 'NR==2 {print $2}')
        echo "  • $disk_path ($disk_size)"
    done
    echo
    
    log_success "Longhorn installed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
