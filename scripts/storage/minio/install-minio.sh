#!/bin/bash

###############################################################################
# MinIO - S3-Compatible Object Storage Installation
#
# Deploys MinIO as a Kubernetes StatefulSet with:
# - Per-node installation (can install on multiple nodes)
# - Node affinity (pinned to specific node)
# - HostPath volumes (dedicated physical disk)
# - LoadBalancer service (MetalLB)
# - Independent credentials per instance
# - .local domain via service discovery
#
# USAGE:
#   sudo ./scripts/storage/minio/install-minio.sh
#   
# The script will:
# 1. Prompt for target node selection
# 2. Detect available disks on that node
# 3. Format and mount selected disk
# 4. Generate unique credentials
# 5. Deploy MinIO to Kubernetes
# 6. Register in service discovery
###############################################################################

# Set KUBECONFIG appropriately based on node type and available configs
if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
    export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
elif [ -n "${SUDO_USER:-}" ] && [ -f "/home/$SUDO_USER/.kube/config" ]; then
    export KUBECONFIG="/home/$SUDO_USER/.kube/config"
elif [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
fi

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
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

    local my_ip=$(tailscale ip -4 2>/dev/null | head -n1)
    if [[ -n "$my_ip" ]]; then
        local node=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[] | select(.type==\"InternalIP\" and .address==\"$my_ip\")) | .metadata.name" 2>/dev/null)
        if [[ -n "$node" ]]; then
            echo "$node"
            return 0
        fi
    fi

    local host_name=$(hostname)
    if kubectl get node "$host_name" &>/dev/null; then
        echo "$host_name"
        return 0
    fi

    local fallback=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$fallback" ]]; then
        echo "$fallback"
        return 0
    fi

    kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname
}

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
LIB_DIR="$PROJECT_ROOT/scripts/lib"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# Load user detection
if [[ -f "$PROJECT_ROOT/scripts/lib/detect-actual-home.sh" ]]; then
    source "$PROJECT_ROOT/scripts/lib/detect-actual-home.sh"
else
    ACTUAL_USER="${SUDO_USER:-$(whoami)}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        ACTUAL_HOME="$HOME"
    fi
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  MinIO Installation (S3-Compatible Object Storage)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install Kubernetes first."
    echo "Run: sudo ./scripts/installation/bootstrap-control-plane.sh"
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster."
    exit 1
fi

# Get cluster domain
CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "mynodeone")

# Select target node
local current_node=$(get_k8s_node_name)
echo "Available nodes (Current: $current_node):"
echo ""
kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels.node-role\\.kubernetes\\.io/worker --no-headers | nl
echo ""
read -p "Select node number for MinIO installation: " NODE_SELECTION

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sed -n "${NODE_SELECTION}p")

if [ -z "$NODE_NAME" ]; then
    log_error "Invalid node selection"
    exit 1
fi

log_info "Selected node: $NODE_NAME"
echo ""

# Check if MinIO already installed on this node
NAMESPACE="minio-${NODE_NAME}"
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_warn "MinIO already installed on node $NODE_NAME (namespace: $NAMESPACE)"
    read -p "Reinstall? This will delete existing MinIO and data [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    log_info "Removing existing MinIO installation..."
    kubectl delete namespace "$NAMESPACE" --wait=true
    log_success "Existing installation removed"
fi

# SSH to node for disk operations (if not local)
LOCAL_NODE=$(hostname)
if [ "$NODE_NAME" = "$LOCAL_NODE" ] || [ "$NODE_NAME" = "$(hostname -s)" ]; then
    IS_LOCAL=true
    log_info "Installing on local node"
else
    IS_LOCAL=false
    log_info "Installing on remote node: $NODE_NAME"
    
    # Get SSH user from node labels
    SSH_USER=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null || echo "")
    NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.mynodeone\.io/worker-ip}' 2>/dev/null || echo "")
    
    if [ -z "$SSH_USER" ] || [ -z "$NODE_IP" ]; then
        log_error "Node labels not found. Cannot SSH to remote node."
        log_error "Required labels: mynodeone.io/ssh-user, mynodeone.io/worker-ip"
        exit 1
    fi
    
    log_info "SSH: $SSH_USER@$NODE_IP"
fi

# Disk detection and selection (interactive)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Disk Selection for MinIO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

detect_available_disks() {
    local node_cmd_prefix="$1"
    
    # Detect OS disk using df (more reliable than lsblk)
    local os_disk=$($node_cmd_prefix df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    
    # Fallback to /boot if root detection fails
    if [ -z "$os_disk" ] || [ "$os_disk" = "/dev/" ]; then
        os_disk=$($node_cmd_prefix df /boot 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    fi
    
    # Final safety check
    if [ -z "$os_disk" ] || [ "$os_disk" = "/dev/" ]; then
        echo "ERROR: Could not detect OS disk" >&2
        return 1
    fi
    
    # Get Longhorn disks - convert mount paths to device paths
    local longhorn_mount_paths=$(kubectl get nodes.longhorn.io -n longhorn-system "$NODE_NAME" -o jsonpath='{range .spec.disks[*]}{.path}{"\n"}{end}' 2>/dev/null || echo "")
    local longhorn_disks=""
    while IFS= read -r mount_path; do
        [[ -z "$mount_path" ]] && continue
        # Get the device mounted at this path
        local dev=$($node_cmd_prefix findmnt -n -o SOURCE "$mount_path" 2>/dev/null || echo "")
        if [ -n "$dev" ]; then
            # Strip partition number to get base device (e.g., /dev/sda1 -> /dev/sda)
            local base_dev=$(echo "$dev" | sed 's/[0-9]*$//' | sed 's/p$//')
            longhorn_disks+="$base_dev"$'\n'
        fi
    done <<< "$longhorn_mount_paths"
    
    # Detect physical disks
    local real_devices=$($node_cmd_prefix lsblk -d -n -o NAME,TYPE | grep disk | awk '{print "/dev/" $1}')
    
    local all_disks=""
    for dev in $real_devices; do
        local dev_name=$(basename "$dev")
        local disk_info=$($node_cmd_prefix lsblk -d -n -o NAME,SIZE,FSTYPE "$dev" 2>/dev/null | grep -w "$dev_name" | head -1 | awk '{print $1":"$2":"$3}')
        if [ -n "$disk_info" ]; then
            all_disks+="$disk_info"$'\n'
        fi
    done
    
    local available_disks=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local disk_name=$(echo "$line" | cut -d: -f1)
        local disk_size=$(echo "$line" | cut -d: -f2)
        local disk_fstype=$(echo "$line" | cut -d: -f3)
        
        # Skip OS disk
        local os_disk_base=$(basename "$os_disk")
        if [[ "$disk_name" == "$os_disk_base" ]] || [[ "/dev/$disk_name" == "$os_disk" ]]; then
            continue
        fi
        
        # Skip Longhorn disks
        local is_longhorn=false
        while IFS= read -r lh_disk; do
            [[ -z "$lh_disk" ]] && continue
            local lh_disk_base=$(basename "$lh_disk")
            if [[ "$disk_name" == "$lh_disk_base" ]] || [[ "/dev/$disk_name" == "$lh_disk" ]]; then
                is_longhorn=true
                break
            fi
        done <<< "$longhorn_disks"
        
        if [ "$is_longhorn" = true ]; then
            continue
        fi
        
        available_disks+=("/dev/$disk_name:$disk_size:$disk_fstype")
    done <<< "$all_disks"
    
    echo "${available_disks[@]}"
}

format_and_mount_disk() {
    local disk="$1"
    local mount_path="$2"
    local node_cmd_prefix="$3"
    
    log_info "Formatting and mounting $disk..."
    
    # Unmount if already mounted
    $node_cmd_prefix umount "$disk"* 2>/dev/null || true
    
    # Wipe existing filesystem signatures
    $node_cmd_prefix wipefs -a "$disk" &>/dev/null || true
    
    # Create partition
    log_info "Creating partition on $disk..."
    $node_cmd_prefix parted -s "$disk" mklabel gpt
    $node_cmd_prefix parted -s "$disk" mkpart primary ext4 0% 100%
    $node_cmd_prefix sleep 2
    
    # Determine partition name
    local partition
    if [[ "$disk" =~ nvme ]] || [[ "$disk" =~ mmcblk ]]; then
        partition="${disk}p1"
    else
        partition="${disk}1"
    fi
    
    # Format partition
    log_info "Formatting $partition..."
    $node_cmd_prefix mkfs.ext4 -F "$partition"
    
    # Create mount point
    $node_cmd_prefix mkdir -p "$mount_path"
    
    # Mount partition
    log_info "Mounting $partition to $mount_path..."
    $node_cmd_prefix mount "$partition" "$mount_path"
    
    # Add to fstab
    local uuid=$($node_cmd_prefix blkid -s UUID -o value "$partition")
    $node_cmd_prefix bash -c "grep -q '$uuid' /etc/fstab || echo 'UUID=$uuid $mount_path ext4 defaults,nofail 0 2' >> /etc/fstab"
    
    log_success "Disk mounted at $mount_path"
}

# Detect disks on target node
if [ "$IS_LOCAL" = true ]; then
    NODE_CMD_PREFIX="sudo"
else
    NODE_CMD_PREFIX="ssh $SSH_USER@$NODE_IP sudo"
fi

log_info "Detecting available disks on $NODE_NAME..."
available_disks=($(detect_available_disks "$NODE_CMD_PREFIX"))

echo ""
echo "💡 Disk options:"
echo "  0) Use OS folder: /var/lib/minio (no formatting needed)"

if [ ${#available_disks[@]} -gt 0 ]; then
    echo ""
    echo "Available physical disks:"
    echo "⚠️  Note: Some disks may have existing installations (OS, Longhorn, etc.)"
    disk_count=0
    for disk_info in "${available_disks[@]}"; do
        disk_count=$((disk_count + 1))
        disk_name=$(echo "$disk_info" | cut -d: -f1)
        disk_size=$(echo "$disk_info" | cut -d: -f2)
        echo "  $disk_count) $(basename $disk_name) ($disk_size)"
    done
else
    echo ""
    log_warn "No additional physical disks detected (only OS folder available)"
fi

echo ""
read -p "Select disk [0-${#available_disks[@]}]: " DISK_CHOICE

if [ "$DISK_CHOICE" = "0" ]; then
    MINIO_PATH="/var/lib/minio"
    STORAGE_SIZE="100Gi"
    log_info "Using OS folder: $MINIO_PATH"
    
    # Create directory on target node
    if [ "$IS_LOCAL" = true ]; then
        sudo mkdir -p "$MINIO_PATH"
        sudo chmod 755 "$MINIO_PATH"
    else
        ssh "$SSH_USER@$NODE_IP" "sudo mkdir -p $MINIO_PATH && sudo chmod 755 $MINIO_PATH"
    fi
    log_success "Created directory: $MINIO_PATH"
elif [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && [[ $DISK_CHOICE -ge 1 ]] && [[ $DISK_CHOICE -le ${#available_disks[@]} ]]; then
    SELECTED_DISK_INFO="${available_disks[$((DISK_CHOICE-1))]}"
    SELECTED_DISK=$(echo "$SELECTED_DISK_INFO" | cut -d: -f1)
    DISK_SIZE_RAW=$(echo "$SELECTED_DISK_INFO" | cut -d: -f2)
    
    log_warn "⚠️  WARNING: Disk $SELECTED_DISK will be FORMATTED (all data will be lost)"
    echo ""
    read -p "Continue with formatting? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Installation cancelled"
        exit 1
    fi
    
    MINIO_PATH="/mnt/minio"
    
    # Convert size to Kubernetes format (e.g., 18.2T -> 18Ti, 100G -> 100Gi)
    # Extract numeric value and unit, round down to avoid fractional bytes
    STORAGE_SIZE=$(echo "$DISK_SIZE_RAW" | awk '{
        val = $1;
        unit = substr(val, length(val), 1);
        num = substr(val, 1, length(val)-1);
        num = int(num);  # Round down to integer
        if (unit == "T") print num "Ti";
        else if (unit == "G") print num "Gi";
        else print val;
    }')
    
    # Format and mount on target node
    format_and_mount_disk "$SELECTED_DISK" "$MINIO_PATH" "$NODE_CMD_PREFIX"
else
    log_error "Invalid selection"
    exit 1
fi

# Generate unique credentials
log_info "Generating credentials..."
MINIO_USER="admin"
MINIO_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
log_success "Credentials generated"

# Create namespace
log_info "Creating namespace: $NAMESPACE..."
cat "$MANIFESTS_DIR/namespace.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    kubectl apply -f -
log_success "Namespace created"

# Create secret
log_info "Creating secret with credentials..."
cat "$MANIFESTS_DIR/secret.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/PASSWORD_PLACEHOLDER/${MINIO_PASSWORD}/g" | \
    kubectl apply -f -
log_success "Secret created"

# Create PV
PV_NAME="${NODE_NAME}"
log_info "Creating PersistentVolume: minio-data-${PV_NAME}..."
cat "$MANIFESTS_DIR/pv-hostpath.yaml" | \
    sed "s/PV_NAME_PLACEHOLDER/${PV_NAME}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    sed "s|STORAGE_SIZE_PLACEHOLDER|${STORAGE_SIZE}|g" | \
    kubectl apply -f -
log_success "PersistentVolume created"

# Create PVC
log_info "Creating PersistentVolumeClaim..."
cat "$MANIFESTS_DIR/pvc.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/PV_NAME_PLACEHOLDER/${PV_NAME}/g" | \
    sed "s|STORAGE_SIZE_PLACEHOLDER|${STORAGE_SIZE}|g" | \
    kubectl apply -f -
log_success "PersistentVolumeClaim created"

# Deploy StatefulSet
log_info "Deploying MinIO StatefulSet..."
cat "$MANIFESTS_DIR/statefulset.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    sed "s/CLUSTER_DOMAIN_PLACEHOLDER/${CLUSTER_DOMAIN}/g" | \
    kubectl apply -f -
log_success "StatefulSet deployed"

# Create API Service
log_info "Creating API LoadBalancer service..."
cat "$MANIFESTS_DIR/service.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    kubectl apply -f -
log_success "API service created"

# Create Console Service
log_info "Creating Console LoadBalancer service..."
cat "$MANIFESTS_DIR/service-console.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    kubectl apply -f -
log_success "Console service created"

# Wait for pod to be ready
log_info "Waiting for MinIO pod to be ready..."
kubectl wait --for=condition=ready pod -l app=minio -n "$NAMESPACE" --timeout=300s || {
    log_error "MinIO pod failed to become ready"
    log_info "Check logs with: kubectl logs -n $NAMESPACE -l app=minio"
    exit 1
}
log_success "MinIO pod is ready"

# Get LoadBalancer IPs
log_info "Waiting for LoadBalancer IPs..."
sleep 5
LB_IP=""
LB_CONSOLE_IP=""
for i in {1..30}; do
    LB_IP=$(kubectl get svc minio -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    LB_CONSOLE_IP=$(kubectl get svc minio-console -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LB_IP" ] && [ -n "$LB_CONSOLE_IP" ]; then
        break
    fi
    sleep 2
done

if [ -z "$LB_IP" ]; then
    log_warn "API LoadBalancer IP not assigned yet"
    log_info "Check status with: kubectl get svc -n $NAMESPACE"
else
    log_success "API LoadBalancer IP: $LB_IP"
fi

if [ -z "$LB_CONSOLE_IP" ]; then
    log_warn "Console LoadBalancer IP not assigned yet"
    log_info "Check status with: kubectl get svc -n $NAMESPACE"
else
    log_success "Console LoadBalancer IP: $LB_CONSOLE_IP"
fi

# Register in service discovery
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
DOMAIN_NAME="minio-${NODE_NAME}.${CLUSTER_DOMAIN}.local"
CONSOLE_DOMAIN_NAME="minio-console-${NODE_NAME}.${CLUSTER_DOMAIN}.local"
log_info "Registering in service discovery..."
if [ -f "$LIB_DIR/service-registry.sh" ]; then
    # Register API service (default to private, can be made public via manage-app-visibility.sh)
    bash "$LIB_DIR/service-registry.sh" register \
        "minio-${NODE_NAME}" \
        "minio-${NODE_NAME}" \
        "$NAMESPACE" \
        "minio" \
        9000 \
        false || log_warn "API service registration failed (non-critical)"
    
    # Register Console service (default to private)
    bash "$LIB_DIR/service-registry.sh" register \
        "minio-console-${NODE_NAME}" \
        "minio-console-${NODE_NAME}" \
        "$NAMESPACE" \
        "minio-console" \
        9001 \
        false || log_warn "Console service registration failed (non-critical)"
    
    log_success "Registered: $DOMAIN_NAME → $LB_IP"
    log_success "Registered: $CONSOLE_DOMAIN_NAME → $LB_CONSOLE_IP"
    
    # Update DNS on control plane to make domain accessible immediately
    if [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
        log_info "Updating DNS entries..."
        if bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" --quiet 2>/dev/null; then
            log_success "DNS entries updated"
        else
            log_warn "DNS update failed (run manually: sudo ./scripts/domains/sync-dns.sh)"
        fi
    fi
fi

# Save credentials to file
CREDS_FILE="$ACTUAL_HOME/minio-${NODE_NAME}-credentials.txt"
cat > "$CREDS_FILE" <<EOF
MinIO Installation on Node: $NODE_NAME
======================================

Namespace: $NAMESPACE
API Domain: $DOMAIN_NAME
Console Domain: $CONSOLE_DOMAIN_NAME
API LoadBalancer IP: ${LB_IP:-pending}
Console LoadBalancer IP: ${LB_CONSOLE_IP:-pending}

API Endpoints:
  - http://${DOMAIN_NAME}:9000
  - http://${LB_IP}:9000 (if IP assigned)

Console Endpoints:
  - http://${CONSOLE_DOMAIN_NAME}:9001
  - http://${LB_CONSOLE_IP}:9001 (if IP assigned)

Credentials:
  Username: $MINIO_USER
  Password: $MINIO_PASSWORD

Storage:
  Path: $MINIO_PATH
  Size: $STORAGE_SIZE

Kubernetes Resources:
  Namespace: $NAMESPACE
  StatefulSet: minio
  Services: minio (API), minio-console (Console)
  PVC: minio-data

Management Commands:
  # View pods
  kubectl get pods -n $NAMESPACE
  
  # View services
  kubectl get svc -n $NAMESPACE
  
  # View logs
  kubectl logs -n $NAMESPACE -l app=minio
  
  # Access console
  open http://${CONSOLE_DOMAIN_NAME}:9001
  
  # Delete MinIO (if needed)
  kubectl delete namespace $NAMESPACE

Installed: $(date)
EOF

chown "$ACTUAL_USER:$ACTUAL_USER" "$CREDS_FILE" 2>/dev/null || true
log_success "Credentials saved to: $CREDS_FILE"

# Print summary
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  MinIO Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Node: $NODE_NAME"
echo "🌐 API Domain: $DOMAIN_NAME"
echo "🌐 Console Domain: $CONSOLE_DOMAIN_NAME"
if [ -n "$LB_IP" ]; then
    echo "📡 API LoadBalancer IP: $LB_IP"
fi
if [ -n "$LB_CONSOLE_IP" ]; then
    echo "📡 Console LoadBalancer IP: $LB_CONSOLE_IP"
fi
echo ""
echo "🔐 Credentials:"
echo "   Username: $MINIO_USER"
echo "   Password: $MINIO_PASSWORD"
echo ""
echo "🌍 Access URLs:"
echo "   API:     http://${DOMAIN_NAME}:9000"
echo "   Console: http://${CONSOLE_DOMAIN_NAME}:9001"
if [ -n "$LB_IP" ]; then
    echo "   API:     http://${LB_IP}:9000"
fi
if [ -n "$LB_CONSOLE_IP" ]; then
    echo "   Console: http://${LB_CONSOLE_IP}:9001"
fi
echo ""
echo "📄 Credentials saved to: $CREDS_FILE"
echo ""
echo "💡 Test access:"
echo "   curl http://${DOMAIN_NAME}:9000/minio/health/live"
echo ""
echo "📦 Kubernetes namespace: $NAMESPACE"
echo ""
