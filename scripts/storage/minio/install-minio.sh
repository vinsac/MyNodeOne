#!/bin/bash

###############################################################################
# MinIO Installation Script
# 
# Installs MinIO object storage on selected node (control plane or worker)
# - Runs from control plane
# - User selects target node
# - Supports both local and remote installation
# - Uses local disks with interactive selection
###############################################################################

# Ensure KUBECONFIG is set for kubectl and helm
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# MinIO configuration
MINIO_VERSION="RELEASE.2024-01-01T16-36-33Z"
MINIO_USER="minio"
MINIO_GROUP="minio"
MINIO_UID=1000
MINIO_GID=1000

# Execution context
REMOTE_EXEC=false
TARGET_NODE=""  # Will be set to IP for SSH in remote mode
TARGET_NODE_NAME=""  # Preserves original node name for K8s operations
TARGET_USER=""
SSH_OPTS=""

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

retry_command() {
    local max_attempts=$1
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 3
    done
    
    return 1
}

# Execute command locally or remotely
exec_cmd() {
    local cmd="$1"
    
    if [ "$REMOTE_EXEC" = true ]; then
        ssh $SSH_OPTS "$TARGET_USER@$TARGET_NODE" "$cmd"
    else
        eval "$cmd"
    fi
}

# Copy file to remote node (no-op if local)
copy_to_target() {
    local src="$1"
    local dest="$2"
    
    if [ "$REMOTE_EXEC" = true ]; then
        scp $SSH_OPTS "$src" "$TARGET_USER@$TARGET_NODE:$dest"
    else
        cp "$src" "$dest"
    fi
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root or with sudo
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        return 1
    fi
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install Kubernetes first."
        return 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    # Check if helm is available
    if ! command -v helm &> /dev/null; then
        log_error "helm not found. Please install Helm first."
        return 1
    fi
    
    log_success "Prerequisites check passed"
    return 0
}

select_target_node() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Node Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "Available nodes in cluster:"
    echo
    kubectl get nodes -o wide
    echo
    
    # Get list of nodes
    local nodes=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    
    if [ ${#nodes[@]} -eq 0 ]; then
        log_error "No nodes found in cluster"
        return 1
    fi
    
    echo "Select target node for MinIO installation:"
    echo
    for i in "${!nodes[@]}"; do
        local node="${nodes[$i]}"
        local roles=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/master}' 2>/dev/null)
        local node_type="worker"
        if [ -n "$roles" ]; then
            node_type="control-plane"
        fi
        echo "  $((i+1))) $node ($node_type)"
    done
    echo
    echo -n "Your choice (1-${#nodes[@]}): "
    read -r choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#nodes[@]} ]; then
        log_error "Invalid selection"
        return 1
    fi
    
    TARGET_NODE="${nodes[$((choice-1))]}"
    
    # Preserve node name for Kubernetes operations (namespace, labels, etc.)
    TARGET_NODE_NAME="$TARGET_NODE"
    export TARGET_NODE_NAME
    
    # Determine if remote execution is needed
    local current_node=$(hostname)
    if [ "$TARGET_NODE" = "$current_node" ]; then
        log_info "Installing MinIO locally on this node: $TARGET_NODE"
        REMOTE_EXEC=false
    else
        log_info "Installing MinIO remotely on node: $TARGET_NODE"
        REMOTE_EXEC=true
        
        # Get node IP from Kubernetes
        local node_ip=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        
        if [ -z "$node_ip" ]; then
            log_error "Could not determine IP address for node $TARGET_NODE"
            return 1
        fi
        
        # Get SSH username from node label (set during worker node join)
        TARGET_USER=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
        
        # If label not found, prompt user to set it or provide username
        if [ -z "$TARGET_USER" ]; then
            log_warn "mynodeone.io/ssh-user label not found on node $TARGET_NODE"
            echo ""
            log_info "To fix this, you can either:"
            log_info "  1. Update the node label (recommended):"
            log_info "     kubectl label node $TARGET_NODE mynodeone.io/ssh-user=<username> --overwrite"
            log_info ""
            log_info "  2. Enter the SSH username now (temporary - label won't be updated)"
            echo ""
            echo -n "Enter SSH username for $TARGET_NODE: "
            read TARGET_USER
            
            if [ -z "$TARGET_USER" ]; then
                log_error "SSH username is required"
                return 1
            fi
            
            log_info "Using SSH username: $TARGET_USER"
        fi
        
        log_info "Target: $TARGET_USER@$node_ip"
        
        # Setup SSH connection
        log_info "Testing SSH connection to $TARGET_NODE..."
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET_USER@$node_ip" "exit" 2>/dev/null; then
            log_warn "Passwordless SSH not configured, you may be prompted for password"
            echo -n "Press Enter to continue..."
            read
        fi
        
        # Setup SSH control master for connection reuse
        SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-mux-minio-%r@%h:%p -o ControlPersist=600"
        
        # Test connection
        if ! ssh $SSH_OPTS -o ConnectTimeout=10 "$TARGET_USER@$node_ip" "exit" 2>/dev/null; then
            log_error "Cannot establish SSH connection to $TARGET_NODE"
            return 1
        fi
        
        # Update TARGET_NODE to use IP for SSH (TARGET_NODE_NAME preserves original)
        TARGET_NODE="$node_ip"
        
        log_success "SSH connection established"
    fi
    
    echo
    echo -n "Install MinIO on $TARGET_NODE? [Y/n]: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "Installation cancelled"
        exit 0
    fi
    
    return 0
}

detect_available_disks() {
    local disk_script='
#!/bin/bash
# Get OS disk
os_disk=$(df / | tail -1 | awk "{print \$1}" | sed "s/[0-9]*$//" | sed "s/p$//")

# Find real block devices
real_devices=""
for dev in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z]; do
    if [ -b "$dev" ]; then
        real_devices+="$dev "
    fi
done

# Get disk info
for dev in $real_devices; do
    disk_name=$(basename "$dev")
    disk_size=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null | xargs)
    disk_fstype=$(lsblk -d -n -o FSTYPE "$dev" 2>/dev/null | xargs)
    disk_mount=$(lsblk -d -n -o MOUNTPOINT "$dev" 2>/dev/null | xargs)
    disk_model=$(lsblk -d -n -o MODEL "$dev" 2>/dev/null | xargs)
    
    # Skip OS disk
    os_disk_base=$(basename "$os_disk")
    if [[ "$disk_name" == "$os_disk_base" ]] || [[ "/dev/$disk_name" == "$os_disk" ]]; then
        continue
    fi
    
    # Skip already mounted disks (unless /mnt/minio)
    if [[ -n "$disk_mount" ]]; then
        if [[ "$disk_mount" == "/mnt/minio"* ]]; then
            :
        elif [[ "$disk_mount" == "/mnt/longhorn-disks"* ]]; then
            continue
        else
            continue
        fi
    fi
    
    # Skip loop/nbd/ram
    if [[ "$disk_name" =~ ^loop[0-9]+ ]] || [[ "$disk_name" =~ ^nbd[0-9]+ ]] || [[ "$disk_name" =~ ^ram[0-9]+ ]]; then
        continue
    fi
    
    # Skip virtual disks
    if [[ "$disk_model" == "VIRTUAL-DISK" ]] || [[ "$disk_model" == *"Virtual"* ]]; then
        continue
    fi
    
    # Skip small disks (< 10GB)
    size_gb=$(echo "$disk_size" | sed "s/G//" | sed "s/T/*1024/" | bc 2>/dev/null || echo "0")
    if (( $(echo "$size_gb < 10" | bc -l 2>/dev/null || echo "0") )); then
        continue
    fi
    
    echo "$disk_name:$disk_size:$disk_fstype:$disk_model"
done
'
    
    exec_cmd "$disk_script"
}

select_disks_for_minio() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Disk Selection on $TARGET_NODE${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "Detecting available disks on $TARGET_NODE..."
    
    local available_disks_raw=$(detect_available_disks)
    local available_disks=()
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        available_disks+=("$line")
    done <<< "$available_disks_raw"
    
    echo
    echo -e "${BLUE}💡 Option 1: Use OS disk (no additional drives needed)${NC}"
    echo -e "  ${BLUE}0)${NC} Use OS disk only - /var/lib/minio ${YELLOW}(no formatting)${NC}"
    echo
    
    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log_warn "No additional dedicated disks detected"
        echo -n "Continue with OS disk? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_warn "Installation cancelled"
            exit 0
        fi
        export MINIO_DISKS="/var/lib/minio"
        return 0
    fi
    
    echo -e "${BLUE}💡 Option 2: Use dedicated physical disk(s)${NC}"
    log_info "Available physical disks:"
    echo
    
    for i in "${!available_disks[@]}"; do
        local disk_info="${available_disks[$i]}"
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_model=$(echo "$disk_info" | cut -d: -f4)
        
        echo "  $((i+1))) /dev/$disk_name ($disk_size) - $disk_model"
    done
    
    echo
    log_info "Your choice:"
    echo -e "  • Enter ${BLUE}0${NC} for OS disk (no formatting)"
    echo -e "  • Enter ${BLUE}1,2,3${NC} for specific physical disks (will be FORMATTED)"
    echo -e "  • Enter ${BLUE}all${NC} for all physical disks above (will be FORMATTED)"
    echo
    echo -n "Your choice: "
    read -r choice
    
    local selected_indices=()
    
    # Handle OS disk selection
    if [[ "$choice" == "0" ]]; then
        log_info "Using OS disk only (no formatting required)"
        export MINIO_DISKS="/var/lib/minio"
        return 0
    fi
    
    if [[ "$choice" == "all" ]]; then
        for i in "${!available_disks[@]}"; do
            selected_indices+=($i)
        done
    else
        IFS=',' read -ra ADDR <<< "$choice"
        for i in "${ADDR[@]}"; do
            if ! [[ "$i" =~ ^[0-9]+$ ]]; then
                log_error "Invalid selection: $i"
                return 1
            fi
            
            local index=$((i-1))
            
            if [ $index -ge 0 ] && [ $index -lt ${#available_disks[@]} ]; then
                selected_indices+=($index)
            else
                log_error "Invalid disk number: $i"
                return 1
            fi
        done
    fi
    
    if [[ ${#selected_indices[@]} -eq 0 ]]; then
        log_error "No disks selected"
        return 1
    fi
    
    # Confirm formatting
    echo
    log_warn "⚠️  WARNING: Selected disks will be FORMATTED (all data lost)"
    echo -n "Continue with formatting? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        log_warn "Installation cancelled"
        exit 0
    fi
    
    local mounted_disks=()
    
    for index in "${selected_indices[@]}"; do
        local disk_info="${available_disks[$index]}"
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local device="/dev/$disk_name"
        local mount_point="/mnt/minio/disk-${disk_name}"
        
        log_info "Formatting $device on $TARGET_NODE..."
        
        # Create format script in temp file to avoid shell escaping issues
        local temp_script="/tmp/minio-format-${disk_name}.sh"
        
        cat > "$temp_script" <<'EOFSCRIPT'
#!/bin/bash
set -e

DEVICE="$1"
MOUNT_POINT="$2"

echo "Cleaning up $DEVICE..."

# Kill any processes using the disk
fuser -km ${DEVICE}* 2>/dev/null || true
sleep 1

# Disable swap if disk is used for swap
swapoff ${DEVICE}* 2>/dev/null || true

# Remove any device mapper mappings
for dm in $(ls /dev/mapper/ 2>/dev/null | grep -E "$(basename ${DEVICE})"); do
    dmsetup remove $dm 2>/dev/null || true
done

# Force unmount all partitions
for part in ${DEVICE}*; do
    [ -b "$part" ] && umount -f $part 2>/dev/null || true
done
sleep 1

# Wipe filesystem signatures
echo "Wiping $DEVICE..."
wipefs -a -f ${DEVICE} 2>/dev/null || wipefs -a ${DEVICE}

# Use parted with GPT for large disks (>2TB)
echo "Creating partition on $DEVICE..."
parted -s ${DEVICE} mklabel gpt
parted -s ${DEVICE} mkpart primary ext4 0% 100%
partprobe ${DEVICE} 2>/dev/null || true
sleep 2

# Determine partition name
partition="${DEVICE}1"
if [ ! -b "$partition" ]; then
    partition="${DEVICE}"
fi

echo "Formatting $partition..."
mkfs.ext4 -F "$partition"

# Set reserved blocks using Longhorn's strategy: >1TB: min(5%, 250GB), <1TB: 10%
partition_size=$(blockdev --getsize64 "$partition")
if [ $partition_size -gt 1099511627776 ]; then
    # >1TB: 5% or 250GB, whichever is smaller
    reserved_bytes=$(awk "BEGIN {reserved = $partition_size * 0.05; if (reserved > 268435456000) reserved = 268435456000; printf \"%.0f\", reserved}")
else
    # <1TB: 10%
    reserved_bytes=$(awk "BEGIN {printf \"%.0f\", ($partition_size * 0.10)}")
fi
reserved_blocks=$(awk "BEGIN {printf \"%.0f\", ($reserved_bytes / 4096)}")

echo "Setting reserved blocks: $reserved_blocks"
tune2fs -r $reserved_blocks "$partition"

# Mount partition
echo "Mounting $partition at $MOUNT_POINT..."
# Ensure parent directory exists with proper permissions
mkdir -p /mnt/minio
chmod 755 /mnt/minio
mkdir -p "$MOUNT_POINT"
mount "$partition" "$MOUNT_POINT"

# Set ownership on mount point so minio user can create subdirectories
chmod 755 "$MOUNT_POINT"

# Add to fstab
uuid=$(blkid -s UUID -o value "$partition")
if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid $MOUNT_POINT ext4 defaults 0 0" >> /etc/fstab
fi

echo "$MOUNT_POINT"
EOFSCRIPT
        
        chmod +x "$temp_script"
        
        # Copy script to remote node if needed
        if [ "$REMOTE_EXEC" = true ]; then
            scp $SSH_OPTS "$temp_script" "$TARGET_USER@$TARGET_NODE:$temp_script" >/dev/null
        fi
        
        # Execute format script with sudo
        local result
        if [ "$REMOTE_EXEC" = true ]; then
            result=$(ssh $SSH_OPTS "$TARGET_USER@$TARGET_NODE" "sudo bash $temp_script '$device' '$mount_point' 2>&1")
        else
            result=$(sudo bash "$temp_script" "$device" "$mount_point" 2>&1)
        fi
        
        local exit_code=$?
        
        # Cleanup temp script
        rm -f "$temp_script"
        if [ "$REMOTE_EXEC" = true ]; then
            ssh $SSH_OPTS "$TARGET_USER@$TARGET_NODE" "rm -f $temp_script" 2>/dev/null || true
        fi
        
        if [ $exit_code -ne 0 ]; then
            log_error "Failed to format $device"
            echo "$result"
            return 1
        fi
        
        mounted_disks+=("$mount_point")
        log_success "Mounted $device at $mount_point"
    done
    
    export MINIO_DISKS="${mounted_disks[@]}"
    return 0
}

ensure_minio_user() {
    log_info "Ensuring MinIO user and group exist on $TARGET_NODE..."
    
    local user_script="
if ! getent group $MINIO_GROUP &>/dev/null; then
    groupadd -g $MINIO_GID $MINIO_GROUP 2>/dev/null || true
fi
if ! getent passwd $MINIO_USER &>/dev/null; then
    useradd -u $MINIO_UID -g $MINIO_GID -s /bin/false -d /nonexistent -M $MINIO_USER 2>/dev/null || true
fi
"
    
    if ! exec_cmd "$user_script"; then
        log_error "Failed to create MinIO user/group"
        return 1
    fi
    
    log_success "MinIO user and group configured"
    return 0
}

prepare_minio_directories() {
    log_info "Preparing MinIO data directories on $TARGET_NODE..."
    
    local disks=($MINIO_DISKS)
    
    for disk in "${disks[@]}"; do
        local MINIO_DATA_DIR="$disk/minio-data"
        
        log_info "Creating directory: $MINIO_DATA_DIR"
        
        local dir_script="
set -x  # Enable debug output
echo '=== Directory Preparation Debug ==='
echo 'Target directory: $MINIO_DATA_DIR'
echo 'MinIO user: ${MINIO_USER}:${MINIO_GROUP}'
echo ''
echo 'Before creation:'
ls -la \$(dirname $MINIO_DATA_DIR) || true
echo ''
mkdir -p $MINIO_DATA_DIR
echo 'After mkdir:'
ls -la \$(dirname $MINIO_DATA_DIR) || true
ls -la $MINIO_DATA_DIR || true
echo ''
chown -R ${MINIO_USER}:${MINIO_GROUP} $MINIO_DATA_DIR
chmod -R 755 $MINIO_DATA_DIR
echo 'After chown/chmod:'
ls -la $MINIO_DATA_DIR || true
echo '=== End Debug ==='
"
        
        # Execute with sudo (required for directory creation on mounted disk)
        if [ "$REMOTE_EXEC" = true ]; then
            if ! ssh $SSH_OPTS "$TARGET_USER@$TARGET_NODE" "sudo bash -c '$dir_script'"; then
                log_error "Failed to prepare directory: $MINIO_DATA_DIR"
                log_error "Check permissions on mount point: $disk"
                return 1
            fi
        else
            if ! sudo bash -c "$dir_script"; then
                log_error "Failed to prepare directory: $MINIO_DATA_DIR"
                log_error "Check permissions on mount point: $disk"
                return 1
            fi
        fi
        
        log_success "Prepared: $MINIO_DATA_DIR"
    done
    
    return 0
}

generate_minio_credentials() {
    log_info "Generating MinIO credentials..."
    
    export MINIO_ROOT_USER="admin"
    export MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)
    
    if [ -z "$MINIO_ROOT_PASSWORD" ]; then
        log_error "Failed to generate MinIO password"
        return 1
    fi
    
    log_success "MinIO credentials generated"
    return 0
}

create_minio_secret() {
    log_info "Creating MinIO Kubernetes secret..."
    
    # Use preserved node name (TARGET_NODE may be IP in remote mode)
    local NODE_NAME="$TARGET_NODE_NAME"
    
    # Sanitize namespace name: Kubernetes doesn't allow dots, uppercase, or special chars
    # Replace dots with hyphens, convert to lowercase
    local SANITIZED_NAME=$(echo "$NODE_NAME" | tr '.' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    
    export MINIO_NAMESPACE="minio-$SANITIZED_NAME"
    
    log_info "Node name: $NODE_NAME"
    log_info "Sanitized namespace: $MINIO_NAMESPACE"
    
    # Validate namespace name (must be DNS-1123 label)
    if [[ ! "$MINIO_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        log_error "Invalid namespace name: $MINIO_NAMESPACE"
        log_error "Namespace must contain only lowercase alphanumeric characters or '-'"
        return 1
    fi
    
    log_info "Creating namespace: $MINIO_NAMESPACE"
    kubectl create namespace "$MINIO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Set pod-security label to allow hostPath volumes
    kubectl label namespace "$MINIO_NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
    
    if kubectl create secret generic minio-credentials \
        --from-literal=rootUser="$MINIO_ROOT_USER" \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
        --namespace "$MINIO_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        log_success "MinIO secret created"
        return 0
    else
        log_error "Failed to create MinIO secret"
        return 1
    fi
}

install_minio_helm() {
    log_info "Installing MinIO via Helm..."
    
    if retry_command 3 "helm repo add minio https://charts.min.io/ 2>&1"; then
        log_success "MinIO helm repo added"
    else
        log_error "Failed to add MinIO helm repo"
        return 1
    fi
    
    if ! timeout 60 helm repo update 2>&1; then
        log_warn "Helm repo update timed out, but continuing..."
    fi
    
    # Use preserved node name (TARGET_NODE may be IP in remote mode)
    local NODE_NAME="$TARGET_NODE_NAME"
    
    if [ -z "$NODE_NAME" ]; then
        log_error "Node name not set - this should not happen"
        return 1
    fi
    
    log_info "MinIO will be scheduled on node: $NODE_NAME"
    
    # Check if MinIO is already installed in this namespace
    if helm list -n "$MINIO_NAMESPACE" 2>/dev/null | grep -q "^minio"; then
        log_warn "MinIO is already installed in namespace $MINIO_NAMESPACE"
        echo
        echo "Existing installation detected. Options:"
        echo "  1) Uninstall and reinstall (recommended for clean setup)"
        echo "  2) Skip installation (keep existing)"
        echo "  3) Cancel"
        echo
        echo -n "Your choice (1-3): "
        read -r reinstall_choice
        
        case "$reinstall_choice" in
            1)
                log_info "Uninstalling existing MinIO..."
                if helm uninstall minio -n "$MINIO_NAMESPACE" --wait --timeout=2m; then
                    log_success "Existing MinIO uninstalled"
                    sleep 5  # Wait for cleanup
                else
                    log_error "Failed to uninstall existing MinIO"
                    return 1
                fi
                ;;
            2)
                log_info "Keeping existing MinIO installation"
                return 0
                ;;
            *)
                log_warn "Installation cancelled"
                exit 0
                ;;
        esac
    fi
    
    local disks=($MINIO_DISKS)
    local VOLUME_COUNT=${#disks[@]}
    
    local MINIO_MODE="standalone"
    local MINIO_VOLUMES=""
    
    if [ $VOLUME_COUNT -eq 1 ]; then
        MINIO_MODE="standalone"
        MINIO_VOLUMES="${disks[0]}/minio-data"
    else
        MINIO_MODE="distributed"
        for disk in "${disks[@]}"; do
            if [ -z "$MINIO_VOLUMES" ]; then
                MINIO_VOLUMES="${disk}/minio-data"
            else
                MINIO_VOLUMES="$MINIO_VOLUMES,${disk}/minio-data"
            fi
        done
    fi
    
    log_info "MinIO mode: $MINIO_MODE"
    log_info "MinIO volumes: $MINIO_VOLUMES"
    
    local PRIORITY_CLASS=""
    if kubectl get priorityclass mynodeone-infrastructure &>/dev/null; then
        PRIORITY_CLASS="priorityClassName: mynodeone-infrastructure"
    fi

    log_info "Installing MinIO (this may take 2-3 minutes)..."
    
    local VALUES_FILE=$(mktemp)
    cat > "$VALUES_FILE" <<EOF
mode: $MINIO_MODE
replicas: 1
persistence:
  enabled: false
drivesPerNode: $VOLUME_COUNT
rootUser: "$MINIO_ROOT_USER"
rootPassword: "$MINIO_ROOT_PASSWORD"
service:
  type: LoadBalancer
consoleService:
  type: LoadBalancer
resources:
  requests:
    memory: 2Gi
    cpu: 500m
  limits:
    memory: 32Gi
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
$PRIORITY_CLASS
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - $NODE_NAME
EOF
    
    if helm upgrade --install minio minio/minio \
        --namespace "$MINIO_NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait --timeout=5m; then
        
        rm -f "$VALUES_FILE"
        log_success "MinIO helm chart installed in namespace $MINIO_NAMESPACE"
    else
        rm -f "$VALUES_FILE"
        log_error "MinIO helm installation failed"
        kubectl get pods -n "$MINIO_NAMESPACE" || true
        kubectl get svc -n "$MINIO_NAMESPACE" || true
        return 1
    fi
    
    return 0
}

patch_minio_for_hostpath() {
    log_info "Configuring MinIO to use hostPath volumes..."
    
    local max_retries=10
    local retry_count=0
    local WORKLOAD_NAME=""
    local WORKLOAD_TYPE=""
    
    while [ $retry_count -lt $max_retries ]; do
        local sts=$(kubectl get statefulset -n "$MINIO_NAMESPACE" -o name 2>/dev/null | head -1)
        if [ -n "$sts" ]; then
            WORKLOAD_NAME=$(echo "$sts" | cut -d'/' -f2)
            WORKLOAD_TYPE="statefulset"
            break
        fi
        
        local deploy=$(kubectl get deployment -n "$MINIO_NAMESPACE" -o name 2>/dev/null | head -1)
        if [ -n "$deploy" ]; then
            WORKLOAD_NAME=$(echo "$deploy" | cut -d'/' -f2)
            WORKLOAD_TYPE="deployment"
            break
        fi
        
        log_info "Waiting for MinIO workload... ($((retry_count+1))/$max_retries)"
        sleep 5
        retry_count=$((retry_count+1))
    done
    
    if [ -z "$WORKLOAD_NAME" ]; then
        log_error "MinIO workload not found in namespace $MINIO_NAMESPACE"
        return 1
    fi
    
    log_info "Found MinIO $WORKLOAD_TYPE: $WORKLOAD_NAME"
    
    local disks=($MINIO_DISKS)
    local VOLUME_MOUNTS="["
    local VOLUMES="["
    
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local vol_name="data-$i"
        local mount_path="/export"
        
        if [ ${#disks[@]} -gt 1 ]; then
            mount_path="/data$i"
        else
            vol_name="export"
        fi
        
        local host_path="${disk}/minio-data"
        
        if [ $i -gt 0 ]; then
            VOLUME_MOUNTS="$VOLUME_MOUNTS,"
            VOLUMES="$VOLUMES,"
        fi
        
        VOLUME_MOUNTS="${VOLUME_MOUNTS}{\"name\":\"${vol_name}\",\"mountPath\":\"${mount_path}\"}"
        VOLUMES="${VOLUMES}{\"name\":\"${vol_name}\",\"hostPath\":{\"path\":\"${host_path}\",\"type\":\"DirectoryOrCreate\"}}"
    done
    
    VOLUME_MOUNTS="$VOLUME_MOUNTS]"
    VOLUMES="$VOLUMES]"
    
    log_info "Patching $WORKLOAD_TYPE with hostPath volumes..."
    
    if kubectl patch $WORKLOAD_TYPE "$WORKLOAD_NAME" -n "$MINIO_NAMESPACE" --type=json -p="[
        {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":$VOLUMES},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":$VOLUME_MOUNTS}
    ]" 2>&1; then
        log_success "MinIO configured for hostPath volumes"
    else
        log_warn "First patch attempt failed, trying merge..."
        if kubectl patch $WORKLOAD_TYPE "$WORKLOAD_NAME" -n "$MINIO_NAMESPACE" --type=merge -p="{\"spec\":{\"template\":{\"spec\":{\"volumes\":$VOLUMES,\"containers\":[{\"name\":\"minio\",\"volumeMounts\":$VOLUME_MOUNTS}]}}}}" 2>&1; then
            log_success "MinIO configured for hostPath volumes (merge)"
        else
            log_error "Failed to patch MinIO workload"
            return 1
        fi
    fi
    
    return 0
}

verify_minio_installation() {
    log_info "Verifying MinIO installation..."
    
    if ! kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio &> /dev/null; then
        log_error "MinIO pods not found in namespace $MINIO_NAMESPACE"
        return 1
    fi
    
    log_info "Waiting for MinIO to be ready (up to 2 minutes)..."
    if kubectl wait --for=condition=ready --timeout=120s pod -l app=minio -n "$MINIO_NAMESPACE" 2>&1; then
        log_success "MinIO pods are ready"
    else
        log_warn "MinIO pods not ready yet, checking status..."
        kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio || true
    fi
    
    log_info "Checking MinIO services..."
    kubectl get svc -n "$MINIO_NAMESPACE" || true
    
    log_success "MinIO installation verified"
    return 0
}

register_minio_services() {
    log_info "Registering MinIO services for DNS..."
    
    local REGISTRY_SCRIPT="$SCRIPT_DIR/../../lib/service-registry.sh"
    if [ -f "$REGISTRY_SCRIPT" ]; then
        # Get actual node name from Kubernetes
        local node_name=$(kubectl get node -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$TARGET_NODE')])].metadata.name}" 2>/dev/null)
        
        if [ -z "$node_name" ]; then
            node_name="$TARGET_NODE"
        fi
        
        local cluster_domain="${CLUSTER_DOMAIN:-}"
        
        if [[ -z "$cluster_domain" ]]; then
            cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "atomcloud.local")
        fi
        
        if bash "$REGISTRY_SCRIPT" register \
            "minio-${node_name}" "minio-${node_name}" "$MINIO_NAMESPACE" "minio" "9000" "false" 2>/dev/null; then
            log_success "MinIO API registered: minio-${node_name}.${cluster_domain}.local:9000"
        else
            log_warn "Could not register MinIO API (DNS may not work)"
        fi
        
        if bash "$REGISTRY_SCRIPT" register \
            "minio-console-${node_name}" "minio-console-${node_name}" "$MINIO_NAMESPACE" "minio-console" "9001" "false" 2>/dev/null; then
            log_success "MinIO Console registered: minio-console-${node_name}.${cluster_domain}.local:9001"
        else
            log_warn "Could not register MinIO Console (DNS may not work)"
        fi
        
        local DNS_SYNC_SCRIPT="$SCRIPT_DIR/../../sync-dns.sh"
        if [[ -f "$DNS_SYNC_SCRIPT" ]]; then
            log_info "Triggering DNS sync..."
            bash "$DNS_SYNC_SCRIPT" 2>/dev/null || log_warn "DNS sync failed"
        fi
    else
        log_warn "Service registry not found, skipping DNS registration"
        log_info "MinIO will be accessible via LoadBalancer IP only"
    fi
    
    return 0
}

save_credentials() {
    log_info "Saving MinIO credentials..."
    
    # Determine actual home directory
    local ACTUAL_HOME="${HOME}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi
    
    # Get actual node name from Kubernetes
    local NODE_NAME=$(kubectl get node -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$TARGET_NODE')])].metadata.name}" 2>/dev/null)
    
    if [ -z "$NODE_NAME" ]; then
        NODE_NAME="$TARGET_NODE"
    fi
    
    local CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-atomcloud.local}"
    local MINIO_DNS="minio-${NODE_NAME}.${CLUSTER_DOMAIN}"
    local CONSOLE_DNS="minio-console-${NODE_NAME}.${CLUSTER_DOMAIN}"
    
    local MINIO_ENDPOINT=$(kubectl get svc -n "$MINIO_NAMESPACE" minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    local MINIO_CONSOLE_IP=$(kubectl get svc -n "$MINIO_NAMESPACE" minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    local S3_URL="http://${MINIO_ENDPOINT}:9000"
    local CONSOLE_URL="http://${MINIO_CONSOLE_IP}:9001"
    
    if getent hosts "$MINIO_DNS" &>/dev/null; then
        S3_URL="http://${MINIO_DNS}:9000"
    fi
    if getent hosts "$CONSOLE_DNS" &>/dev/null; then
        CONSOLE_URL="http://${CONSOLE_DNS}:9001"
    fi
    
    cat > "$ACTUAL_HOME/mynodeone-minio-credentials.txt" <<EOF
MinIO Credentials (Node: $NODE_NAME)
==============================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
S3 Endpoint: $S3_URL
Console: $CONSOLE_URL

Storage Locations:
EOF
    
    local disks=($MINIO_DISKS)
    for disk in "${disks[@]}"; do
        echo "  - ${disk}/minio-data" >> "$ACTUAL_HOME/mynodeone-minio-credentials.txt"
    done
    
    cat >> "$ACTUAL_HOME/mynodeone-minio-credentials.txt" <<EOF
    
WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    
    chmod 600 "$ACTUAL_HOME/mynodeone-minio-credentials.txt"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER:$SUDO_USER" "$ACTUAL_HOME/mynodeone-minio-credentials.txt"
    fi
    
    log_success "Credentials saved to: $ACTUAL_HOME/mynodeone-minio-credentials.txt"
}

main() {
    log_info "===== MinIO Installation ====="
    
    if ! check_requirements; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    if ! select_target_node; then
        log_error "Node selection failed"
        exit 1
    fi
    
    if ! select_disks_for_minio; then
        log_error "Disk selection failed"
        exit 1
    fi
    
    if ! ensure_minio_user; then
        log_error "MinIO user/group setup failed"
        exit 1
    fi
    
    if ! prepare_minio_directories; then
        log_error "Directory preparation failed"
        exit 1
    fi
    
    if ! generate_minio_credentials; then
        log_error "Credential generation failed"
        exit 1
    fi
    
    if ! create_minio_secret; then
        log_error "Secret creation failed"
        exit 1
    fi
    
    if ! install_minio_helm; then
        log_error "MinIO helm installation failed"
        exit 1
    fi
    
    patch_minio_for_hostpath || log_warn "HostPath patching skipped or failed"
    
    if ! verify_minio_installation; then
        log_error "MinIO verification failed"
        exit 1
    fi
    
    set +e
    register_minio_services
    set -e
    
    save_credentials
    
    # Print credentials to screen
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  MinIO Installation Successful${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local ACTUAL_HOME="${HOME}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi
    
    if [ -f "$ACTUAL_HOME/mynodeone-minio-credentials.txt" ]; then
        cat "$ACTUAL_HOME/mynodeone-minio-credentials.txt"
    else
        log_warn "Credential file not found, printing known details:"
        echo "Root User: $MINIO_ROOT_USER"
        echo "Root Password: $MINIO_ROOT_PASSWORD"
    fi
    
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Cleanup SSH control master if remote
    if [ "$REMOTE_EXEC" = true ]; then
        ssh $SSH_OPTS -O exit "$TARGET_USER@$TARGET_NODE" 2>/dev/null || true
    fi
    
    echo
    log_success "===== MinIO Installation Complete ====="
    log_info "MinIO is running on node: $(kubectl get node -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$TARGET_NODE')])].metadata.name}" 2>/dev/null || echo "$TARGET_NODE")"
}

main "$@"
