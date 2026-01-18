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

# Set KUBECONFIG appropriately based on node type and available configs
# This ensures kubectl works on both control plane and worker nodes
if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
    # Control plane - use K3s server config (root has direct access)
    export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
elif [ -n "${SUDO_USER:-}" ] && [ -f "/home/$SUDO_USER/.kube/config" ]; then
    # Running with sudo - use actual user's config (common on workers)
    export KUBECONFIG="/home/$SUDO_USER/.kube/config"
elif [ -f "$HOME/.kube/config" ]; then
    # Use current user's config
    export KUBECONFIG="$HOME/.kube/config"
fi
# If none of the above exist, kubectl commands will fail gracefully with helpful error messages

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

# Get current Kubernetes node name robustly
get_k8s_node_name() {
    # 1. Use NODE_NAME from config if set and valid
    if [[ -n "${NODE_NAME:-}" ]]; then
        if kubectl get node "$NODE_NAME" &>/dev/null; then
            echo "$NODE_NAME"
            return 0
        fi
    fi

    # 2. Try to match by local Tailscale IP (most reliable in our architecture)
    local my_ip=$(tailscale ip -4 2>/dev/null | head -n1)
    if [[ -n "$my_ip" ]]; then
        local node=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[] | select(.type==\"InternalIP\" and .address==\"$my_ip\")) | .metadata.name" 2>/dev/null)
        if [[ -n "$node" ]]; then
            echo "$node"
            return 0
        fi
    fi

    # 3. Try to match by hostname
    local host_name=$(hostname)
    if kubectl get node "$host_name" &>/dev/null; then
        echo "$host_name"
        return 0
    fi

    # 4. Fallback to first non-control-plane node if we are a worker
    local fallback=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$fallback" ]]; then
        echo "$fallback"
        return 0
    fi

    # 5. Last resort: Just first node
    kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname
}

log_error() {
    echo -e "${RED}[✗]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Detect script directory
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null
LIB_DIR="$PROJECT_ROOT/scripts/lib"

# Source user detection library (defensive programming)
if [[ -f "$PROJECT_ROOT/scripts/lib/detect-actual-home.sh" ]]; then
    source "$PROJECT_ROOT/scripts/lib/detect-actual-home.sh"
else
    # Fallback: manual detection
    ACTUAL_USER="${SUDO_USER:-$(whoami)}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_HOME="$HOME"
    fi
    CONFIG_DIR="$ACTUAL_HOME/.mynodeone"
fi

# Source node registry manager
if [[ -f "$LIB_DIR/node-registry-manager.sh" ]]; then
    source "$LIB_DIR/node-registry-manager.sh"
else
    log_warn "Node registry manager not found, skipping registry updates"
fi

# Detect available disks (excluding OS disk)
detect_available_disks() {
    # Log to stderr to not pollute stdout (which is captured)
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') Detecting available disks..." >&2
    
    # Get OS disk using df (reliable across all device types)
    local os_disk=$(df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    
    # Fallback to /boot if root detection fails
    if [ -z "$os_disk" ] || [ "$os_disk" = "/dev/" ]; then
        os_disk=$(df /boot 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    fi
    
    # Final safety check
    if [ -z "$os_disk" ] || [ "$os_disk" = "/dev/" ]; then
        echo -e "${RED}[ERROR]${NC} Could not detect OS disk" >&2
        return 1
    fi
    
    # Find real block devices by scanning /dev directly (avoid lsblk weirdness with symlinks)
    local real_devices=""
    for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
        if [ -b "$dev" ]; then
            real_devices+="$dev "
        fi
    done
    
    # Get disk info for real devices only
    local all_disks=""
    for dev in $real_devices; do
        local disk_info=$(lsblk -d -n -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | awk '{print $1":"$3":"$4":"$5}')
        if [ -n "$disk_info" ]; then
            all_disks+="$disk_info"$'\n'
        fi
    done
    
    local available_disks=()
    
    while IFS= read -r disk_info; do
        [[ -z "$disk_info" ]] && continue
        
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_mount=$(echo "$disk_info" | cut -d: -f4)
        
        # Skip OS disk (compare base device names)
        local os_disk_base=$(basename "$os_disk")
        if [[ "$disk_name" == "$os_disk_base" ]] || [[ "/dev/$disk_name" == "$os_disk" ]]; then
            continue
        fi
        
        # Skip already mounted disks (except /mnt/longhorn-disks)
        if [[ -n "$disk_mount" ]] && [[ "$disk_mount" != "/mnt/longhorn-disks/"* ]]; then
            continue
        fi
        
        # Skip loop devices, NBD, RAM disks
        local disk_basename=$(basename "$disk_name")
        if [[ "$disk_basename" =~ ^loop[0-9]+ ]] || [[ "$disk_basename" =~ ^nbd[0-9]+ ]] || [[ "$disk_basename" =~ ^ram[0-9]+ ]]; then
            continue
        fi
        
        # Skip virtual disks
        local model=$(lsblk -n -o MODEL "$disk_name" 2>/dev/null | head -1 | xargs)
        if [[ "$model" == "VIRTUAL-DISK" ]] || [[ "$model" == *"Virtual"* ]]; then
            continue
        fi
        
        # Skip disks smaller than 10GB
        local size_gb=$(echo "$disk_size" | sed 's/G//' | sed 's/T/*1024/' | bc 2>/dev/null || echo "0")
        if (( $(echo "$size_gb < 10" | bc -l 2>/dev/null || echo "0") )); then
            continue
        fi
        
        # Get disk model for display
        available_disks+=("$disk_name:$disk_size:$disk_fstype:$model")
    done <<< "$all_disks"
    
    echo "${available_disks[@]}"
}

# Interactive disk selection
select_disks_for_longhorn() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Longhorn Disk Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local available_disks=($(detect_available_disks))
    
    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log_warn "No additional disks detected"
        log_info "Longhorn will use OS disk: /var/lib/longhorn"
        echo
        read -p "Continue with OS disk? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled"
            exit 1
        fi
        SELECTED_DISKS=()
        return 0
    fi
    
    echo
    echo -e "${BLUE}💡 Option 1: Use OS disk (no additional drives needed)${NC}"
    echo -e "  ${BLUE}0)${NC} Use OS disk only - /var/lib/longhorn ${YELLOW}(no formatting)${NC}"
    echo
    echo -e "${BLUE}💡 Option 2: Use dedicated physical disk(s)${NC}"
    log_info "Available physical disks:"
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    local disk_count=0
    for disk_info in "${available_disks[@]}"; do
        disk_count=$((disk_count + 1))
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_model=$(echo "$disk_info" | cut -d: -f4)
        
        # Build display string
        local display="  $disk_count) $disk_name ($disk_size)"
        
        if [[ -n "$disk_model" ]]; then
            display="$display - $disk_model"
        fi
        
        if [[ -n "$disk_fstype" ]]; then
            display="$display ${YELLOW}[has filesystem: $disk_fstype]${NC}"
        fi
        
        echo -e "$display"
    done
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo
    log_info "Your choice:"
    echo -e "  • Enter ${BLUE}0${NC} for OS disk (no formatting)"
    echo -e "  • Enter ${BLUE}1,2,3${NC} for specific physical disks (will be formatted)"
    echo -e "  • Enter ${BLUE}all${NC} for all physical disks above (will be formatted)"
    echo
    echo
    read -p "Your choice: " selection
    
    SELECTED_DISKS=()
    
    if [[ "$selection" == "none" ]] || [[ "$selection" == "0" ]]; then
        log_info "Using OS disk only (no formatting required)"
        return 0
    fi
    
    if [[ "$selection" == "all" ]]; then
        for disk_info in "${available_disks[@]}"; do
            local disk_name=$(echo "$disk_info" | cut -d: -f1)
            SELECTED_DISKS+=("/dev/$disk_name")
        done
    else
        IFS=',' read -ra DISK_INDICES <<< "$selection"
        for idx in "${DISK_INDICES[@]}"; do
            idx=$(echo "$idx" | xargs)  # trim whitespace
            if [[ "$idx" =~ ^[0-9]+$ ]] && [[ $idx -ge 1 ]] && [[ $idx -le ${#available_disks[@]} ]]; then
                local disk_info="${available_disks[$((idx-1))]}"
                local disk_name=$(echo "$disk_info" | cut -d: -f1)
                SELECTED_DISKS+=("/dev/$disk_name")
            else
                log_warn "Invalid selection: $idx"
            fi
        done
    fi
    
    if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
        echo
        log_info "Selected ${#SELECTED_DISKS[@]} disk(s):"
        for disk in "${SELECTED_DISKS[@]}"; do
            local disk_size=$(lsblk -d -n -o SIZE "$disk" 2>/dev/null || echo "Unknown")
            echo "  • $disk ($disk_size)"
        done
        echo
        log_warn "⚠️  WARNING: Selected disks will be FORMATTED (all data will be lost)"
        echo
        read -p "Continue with formatting? [y/N]: " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled"
            exit 1
        fi
    fi
}

# Format and mount disks
format_and_mount_disks() {
    if [[ ${#SELECTED_DISKS[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Formatting and mounting disks..."
    
    MOUNTED_DISKS=()
    
    for disk in "${SELECTED_DISKS[@]}"; do
        log_info "Processing $disk..."
        
        # Unmount if already mounted
        umount "$disk"* 2>/dev/null || true
        
        # Wipe existing filesystem signatures
        wipefs -a "$disk" &>/dev/null || true
        
        # Create new partition
        log_info "Creating partition on $disk..."
        parted -s "$disk" mklabel gpt
        parted -s "$disk" mkpart primary ext4 0% 100%
        
        # Wait for partition to appear
        sleep 2
        partprobe "$disk"
        sleep 1
        
        # Determine partition device name
        local partition="${disk}1"
        if [[ "$disk" =~ nvme ]] || [[ "$disk" =~ mmcblk ]]; then
            partition="${disk}p1"
        fi
        
        # Format partition
        log_info "Formatting $partition..."
        mkfs.ext4 -F "$partition"
        
        # Create mount point
        local disk_basename=$(basename "$disk")
        local mount_point="/mnt/longhorn-disks/disk-${disk_basename}"
        mkdir -p "$mount_point"
        
        # Mount partition
        log_info "Mounting $partition to $mount_point..."
        mount "$partition" "$mount_point"
        
        # Add to fstab
        local uuid=$(blkid -s UUID -o value "$partition")
        if ! grep -q "$uuid" /etc/fstab; then
            echo "UUID=$uuid $mount_point ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
        
        MOUNTED_DISKS+=("$mount_point")
        log_success "Mounted $disk at $mount_point"
    done
    
    log_success "All disks formatted and mounted"
}

# Install Longhorn via Helm
install_longhorn_helm() {
    log_info "Installing Longhorn..."
    
    # Install dependencies
    log_info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y open-iscsi util-linux nfs-common
    systemctl enable --now iscsid
    
    # Check if kubectl is available
    # Root has access via KUBECONFIG=/etc/rancher/k3s/k3s.yaml on control plane
    if ! kubectl get nodes &>/dev/null 2>&1; then
        log_warn "kubectl not available (worker node) - Longhorn installation via control plane only"
        log_info "Disks are mounted and ready. Longhorn will be installed from control plane."
        log_info "Mounted disks: ${MOUNTED_DISKS[@]}"
        return 0
    fi
    
    # Create namespace
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Add Helm repo
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
    
    # Install Longhorn
    log_info "Installing Longhorn via Helm (this may take a few minutes)..."
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version 1.5.3 \
        --set defaultSettings.defaultReplicaCount=1 \
        --set defaultSettings.defaultDataPath="${default_path}" \
        --set defaultSettings.replicaAutoBalance="best-effort" \
        --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
        --set defaultSettings.fastReplicaRebuildEnabled=true \
        --set defaultSettings.storageOverProvisioningPercentage=200 \
        --set defaultSettings.storageMinimalAvailablePercentage=10 \
        --wait \
        --timeout 10m
    
    # Set as default storage class
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    # Expose UI via LoadBalancer
    kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"LoadBalancer"}}'
    
    log_success "Longhorn installed successfully"
}

# Add additional disks to Longhorn
add_additional_disks() {
    if [[ ${#MOUNTED_DISKS[@]} -le 1 ]]; then
        return 0
    fi
    
    log_info "Configuring additional disks in Longhorn..."
    
    # Wait for Longhorn to initialize
    sleep 10
    
    # Check if kubectl is available and working
    if ! kubectl get nodes &>/dev/null; then
        log_warn "kubectl not available (worker node) - disk configuration will be handled by control plane"
        log_info "Disks mounted at: ${MOUNTED_DISKS[@]}"
        log_info "Configure disks via Longhorn UI after node joins cluster"
        return 0
    fi
    
    # Get actual node name
    local node_name=$(get_k8s_node_name)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect node name, skipping additional disk configuration"
        return 1
    fi
    
    # Wait for Longhorn node CRD
    local max_wait=30
    local waited=0
    while ! kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [[ $waited -ge $max_wait ]]; then
            log_warn "Longhorn node CRD not ready, skipping additional disks"
            return 1
        fi
    done
    
    # Add each additional disk
    for i in "${!MOUNTED_DISKS[@]}"; do
        if [[ $i -eq 0 ]]; then
            continue  # Skip first disk (already configured)
        fi
        
        local disk_path="${MOUNTED_DISKS[$i]}"
        local disk_name="disk-$(basename "$disk_path")"
        
        log_info "Adding disk: $disk_path"
        
        if kubectl -n longhorn-system patch nodes.longhorn.io "$node_name" --type=merge \
            -p "{\"spec\":{\"disks\":{\"$disk_name\":{\"allowScheduling\":true,\"diskType\":\"filesystem\",\"evictionRequested\":false,\"path\":\"$disk_path\",\"storageReserved\":0,\"tags\":[]}}}}" 2>&1; then
            log_success "Added: $disk_path"
        else
            log_warn "Could not add $disk_path automatically (can be added via UI)"
        fi
    done
    
    log_success "Additional disks configured"
}

# Fix disk UUID mismatches (when disks are reformatted)
fix_disk_uuid_mismatches() {
    log_info "Checking for disk UUID mismatches..."
    
    # Wait for Longhorn to detect disks
    sleep 5
    
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
    local has_mismatch=$(kubectl get nodes.longhorn.io "$node_name" -n longhorn-system -o json 2>/dev/null | \
        jq -r '.status.diskStatus // {} | to_entries[] | select(.value.conditions[]?.reason == "DiskFilesystemChanged") | .key' | head -1)
    
    if [[ -n "$has_mismatch" ]]; then
        log_warn "Detected disk UUID mismatch (disk was reformatted)"
        log_info "Recreating Longhorn node resource to fix UUID mismatch..."
        
        # Delete the Longhorn node resource (it will be auto-recreated)
        kubectl delete nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null || true
        
        # Wait for Longhorn to recreate the node
        log_info "Waiting for Longhorn to recreate node resource..."
        local max_wait=30
        local waited=0
        while [ $waited -lt $max_wait ]; do
            if kubectl get nodes.longhorn.io "$node_name" -n longhorn-system &>/dev/null; then
                log_success "Longhorn node recreated successfully"
                sleep 5  # Give it time to initialize
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done
        
        log_warn "Longhorn node not recreated within ${max_wait}s, continuing anyway"
    else
        log_success "No disk UUID mismatches detected"
    fi
    
    return 0
}

# Fix disk reservations (reduce from default 30% to optimal 5-10%)
fix_disk_reservations() {
    log_info "Optimizing disk reservations..."
    
    # Wait for Longhorn to initialize disk status
    sleep 5
    
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
    echo "$disks_json" | jq -r '.spec.disks // {} | to_entries[] | @json' 2>/dev/null | while read -r disk_json; do
        local disk_name=$(echo "$disk_json" | jq -r '.key')
        local disk_path=$(echo "$disk_json" | jq -r '.value.path')
        
        # Get disk status
        local disk_status=$(echo "$disks_json" | jq -r ".status.diskStatus.\"$disk_name\" // {}")
        local storage_max=$(echo "$disk_status" | jq -r '.storageMaximum // 0')
        
        if [[ "$storage_max" -eq 0 ]]; then
            continue
        fi
        
        # Calculate optimal reservation: 5% for >1TB disks, 10% for smaller
        local optimal_reserved=0
        if [[ $storage_max -gt 1099511627776 ]]; then
            # >1TB: 5% reservation (max 250GB or 5%)
            optimal_reserved=$(awk "BEGIN {reserved = $storage_max * 0.05; if (reserved > 268435456000) reserved = 268435456000; printf \"%.0f\", reserved}")
        else
            # <1TB: 10% reservation
            optimal_reserved=$(awk "BEGIN {printf \"%.0f\", ($storage_max * 0.10)}")
        fi
        
        # Update reservation
        kubectl -n longhorn-system patch nodes.longhorn.io "$node_name" --type=merge \
            -p "{\"spec\":{\"disks\":{\"$disk_name\":{\"storageReserved\":$optimal_reserved}}}}" &>/dev/null || true
        
        local reserved_gb=$(awk "BEGIN {printf \"%.1f\", ($optimal_reserved / 1073741824)}")
        log_info "  $disk_path: Reserved ${reserved_gb}GB"
    done
    
    log_success "Disk reservations optimized"
}

# Register configuration in node registry
register_in_node_registry() {
    if ! command -v register_cluster_node &>/dev/null; then
        log_warn "Node registry functions not available, skipping registration"
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
    
    # Build disk list CSV
    local disks_csv=""
    if [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        disks_csv=$(IFS=,; echo "${MOUNTED_DISKS[*]}")
    else
        disks_csv="/var/lib/longhorn"
    fi
    
    # Calculate total capacity
    local total_capacity="0"
    if [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        total_capacity=$(df -h "${MOUNTED_DISKS[@]}" 2>/dev/null | tail -${#MOUNTED_DISKS[@]} | awk '{sum+=$2} END {print sum"G"}')
    else
        total_capacity=$(df -h /var/lib/longhorn 2>/dev/null | tail -1 | awk '{print $2}')
    fi
    
    # Update node registry
    update_cluster_node_longhorn \
        --name "$node_name" \
        --disks "$disks_csv" \
        --capacity "$total_capacity" || log_warn "Could not update node registry"
    
    log_success "Node registry updated"
}

# Main installation flow
main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Longhorn Interactive Installation${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "Longhorn provides distributed block storage for Kubernetes"
    log_info "Default replica count: 1 (data stored on single node)"
    echo
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Check kubectl
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        exit 1
    fi
    
    # Check if Longhorn already installed on cluster
    local longhorn_installed=false
    if kubectl get namespace longhorn-system &>/dev/null; then
        log_info "Longhorn detected on cluster (namespace exists)"
        longhorn_installed=true
    fi
    
    # Interactive disk selection
    select_disks_for_longhorn
    
    # Format and mount disks
    format_and_mount_disks
    
    # Install/Upgrade Longhorn ONLY if not already present or if forced
    if [[ "$longhorn_installed" == "false" ]]; then
        install_longhorn_helm
    else
        log_info "Skipping global Longhorn Helm installation (already present on cluster)"
    fi
    
    # Add additional disks (this is node-local)
    add_additional_disks
    
    # Fix disk UUID mismatches (if disks were reformatted)
    fix_disk_uuid_mismatches
    
    # Fix disk reservations (reduce from default 30% to 5% for large disks)
    fix_disk_reservations
    
    # Register in node registry
    register_in_node_registry
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Longhorn Installation Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_success "Longhorn is now the default storage class"
    
    # Detect cluster domain - prefer environment variable (set by bootstrap), fallback to ConfigMap
    local cluster_domain="${CLUSTER_DOMAIN:-}"
    if [[ -z "$cluster_domain" ]]; then
        cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null)
    fi
    
    if [[ -z "$cluster_domain" ]]; then
        log_error "Could not detect cluster domain"
        echo -n "Please enter cluster domain (e.g., mynodeone): "
        read cluster_domain
        if [[ -z "$cluster_domain" ]]; then
            log_error "Cluster domain is required"
            return 1
        fi
    fi
    
    # Register Longhorn service in service registry
    log_info "Registering Longhorn UI in service registry..."
    if [[ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]]; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "longhorn" \
            "longhorn" \
            "longhorn-system" \
            "longhorn-frontend" \
            "80" \
            "false" || log_warn "Failed to register Longhorn in service registry"
    fi
    
    # Trigger DNS sync
    if [[ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]]; then
        log_info "Syncing DNS entries..."
        bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" || log_warn "DNS sync failed"
    fi
    
    log_info "UI will be accessible at: http://longhorn.${cluster_domain}.local"
    echo
    
    if [[ ${#MOUNTED_DISKS[@]} -gt 0 ]]; then
        log_info "Configured disks:"
        for disk in "${MOUNTED_DISKS[@]}"; do
            local disk_size=$(df -h "$disk" | tail -1 | awk '{print $2}')
            echo "  • $disk ($disk_size)"
        done
    else
        log_info "Using OS disk: /var/lib/longhorn"
    fi
    
    echo
}

# Only run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
