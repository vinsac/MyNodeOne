#!/bin/bash

###############################################################################
# MinIO Worker Installation Script
# 
# Installs MinIO object storage on worker node using local disks
# Uses same disk detection pattern as Longhorn installation
# Called during worker node addition (add-worker-node.sh)
###############################################################################

# Ensure KUBECONFIG is set for kubectl and helm when running as root
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

# Detect actual user on THIS machine (not remote caller)
detect_actual_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        # Check if SUDO_USER exists on THIS system
        if getent passwd "$SUDO_USER" &>/dev/null; then
            ACTUAL_USER="$SUDO_USER"
            ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        else
            # SUDO_USER doesn't exist here (remote caller), use current system user
            ACTUAL_USER=$(whoami)
            ACTUAL_HOME="$HOME"
        fi
    else
        ACTUAL_USER=$(whoami)
        ACTUAL_HOME="$HOME"
    fi
    export ACTUAL_USER
    export ACTUAL_HOME
}

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

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
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

detect_available_disks() {
    # Log to stderr to not pollute stdout (which is captured)
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') Detecting available disks..." >&2
    
    # Get OS disk
    local os_disk=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    
    # Find real block devices by scanning /dev directly
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
        
        # Skip OS disk
        local os_disk_base=$(basename "$os_disk")
        if [[ "$disk_name" == "$os_disk_base" ]] || [[ "/dev/$disk_name" == "$os_disk" ]]; then
            continue
        fi
        
        # Skip already mounted disks (unless mounted at /mnt/minio)
        if [[ -n "$disk_mount" ]]; then
             if [[ "$disk_mount" == "/mnt/minio"* ]]; then
                 # Already our disk, include it
                 :
             elif [[ "$disk_mount" == "/mnt/longhorn-disks"* ]]; then
                 # Longhorn disk, SKIP
                 continue
             else
                 # Other mount, skip
                 continue
             fi
        fi
        
        # Skip loop/nbd/ram
        local disk_basename=$(basename "$disk_name")
        if [[ "$disk_basename" =~ ^loop[0-9]+ ]] || [[ "$disk_basename" =~ ^nbd[0-9]+ ]] || [[ "$disk_basename" =~ ^ram[0-9]+ ]]; then
            continue
        fi
        
        # Skip virtual disks
        local model=$(lsblk -n -o MODEL "/dev/$disk_name" 2>/dev/null | head -1 | xargs)
        if [[ "$model" == "VIRTUAL-DISK" ]] || [[ "$model" == *"Virtual"* ]]; then
            continue
        fi
        
        # Skip disks smaller than 10GB
        local size_gb=$(echo "$disk_size" | sed 's/G//' | sed 's/T/*1024/' | bc 2>/dev/null || echo "0")
        if (( $(echo "$size_gb < 10" | bc -l 2>/dev/null || echo "0") )); then
            continue
        fi
        
        available_disks+=("$disk_name:$disk_size:$disk_fstype:$model")
    done <<< "$all_disks"
    
    echo "${available_disks[@]}"
}

select_disks_for_minio() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Disk Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local available_disks=($(detect_available_disks))
    
    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log_warn "No additional dedicated disks detected"
        log_info "MinIO will use /var/lib/minio (OS disk) as fallback"
        echo -n "Continue with OS disk? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_warn "Installation cancelled"
            exit 0
        fi
        export MINIO_DISKS="/var/lib/minio"
        return 0
    fi
    
    log_info "Available physical disks:"
    echo
    
    for i in "${!available_disks[@]}"; do
        local disk_info="${available_disks[$i]}"
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_model=$(echo "$disk_info" | cut -d: -f4)
        
        echo "  $((i+1))) /dev/$disk_name ($disk_size) - $disk_model"
    done
    
    echo
    echo -e "  • Enter ${BLUE}1,2,3${NC} for specific disks (will be FORMATTED)"
    echo -e "  • Enter ${BLUE}all${NC} for all available disks"
    echo
    echo -n "Your choice: "
    read -r choice
    
    local selected_indices=()
    if [[ "$choice" == "all" ]]; then
        for i in "${!available_disks[@]}"; do
            selected_indices+=($i)
        done
    else
        IFS=',' read -ra ADDR <<< "$choice"
        for i in "${ADDR[@]}"; do
            # Validate input is a number
            if ! [[ "$i" =~ ^[0-9]+$ ]]; then
                log_error "Invalid selection: $i"
                return 1
            fi
            
            # Adjust for 0-based array index
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
        
        # Standardize on /mnt/minio/disk-X
        
        log_info "Formatting $device..."
        
        # Unmount if mounted
        umount "$device"* 2>/dev/null || true
        
        # Wipe filesystem signatures
        wipefs -a "$device"
        
        # Create partition
        echo -e "n\np\n1\n\n\n\nw" | fdisk "$device" 2>/dev/null || true
        partprobe "$device" 2>/dev/null || true
        sleep 2
        
        local partition="${device}1"
        if [ ! -b "$partition" ]; then
            partition="$device" # Fallback to whole disk if partition fail
        fi
        
        # Format ext4
        mkfs.ext4 -F "$partition"
        
        # Mount
        mkdir -p "$mount_point"
        mount "$partition" "$mount_point"
        
        # Add to fstab
        local uuid=$(blkid -s UUID -o value "$partition")
        if ! grep -q "$uuid" /etc/fstab; then
            echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
        fi
        
        mounted_disks+=("$mount_point")
        log_success "Mounted $device at $mount_point"
    done
    
    export MINIO_DISKS="${mounted_disks[@]}"
    return 0
}

ensure_minio_user() {
    log_info "Ensuring MinIO user and group exist..."
    
    # Check/create group
    if ! getent group "$MINIO_GROUP" &>/dev/null; then
        log_info "Creating minio group (GID: $MINIO_GID)..."
        if groupadd -g $MINIO_GID "$MINIO_GROUP" 2>/dev/null; then
            log_success "MinIO group created"
        else
            log_warn "Could not create group with GID $MINIO_GID, using existing GID"
            # Group might exist with different GID, that's OK
        fi
    else
        log_info "MinIO group already exists"
    fi
    
    # Check/create user
    if ! getent passwd "$MINIO_USER" &>/dev/null; then
        log_info "Creating minio user (UID: $MINIO_UID)..."
        if useradd -u $MINIO_UID -g $MINIO_GID -s /bin/false -d /nonexistent -M "$MINIO_USER" 2>/dev/null; then
            log_success "MinIO user created"
        else
            log_warn "Could not create user with UID $MINIO_UID, using existing UID"
            # User might exist with different UID, that's OK
        fi
    else
        log_info "MinIO user already exists"
    fi
    
    return 0
}

prepare_minio_directories() {
    log_info "Preparing MinIO data directories..."
    
    local disks=($MINIO_DISKS)
    
    for disk in "${disks[@]}"; do
        local MINIO_DATA_DIR="$disk/minio-data"
        
        log_info "Creating directory: $MINIO_DATA_DIR"
        
        # Create directory
        if ! mkdir -p "$MINIO_DATA_DIR"; then
            log_error "Failed to create directory: $MINIO_DATA_DIR"
            return 1
        fi
        
        # Set ownership (use user:group names, not UID:GID)
        if ! chown -R ${MINIO_USER}:${MINIO_GROUP} "$MINIO_DATA_DIR"; then
            log_error "Failed to set ownership on: $MINIO_DATA_DIR"
            return 1
        fi
        
        # Set permissions
        if ! chmod -R 755 "$MINIO_DATA_DIR"; then
            log_error "Failed to set permissions on: $MINIO_DATA_DIR"
            return 1
        fi
        
        log_success "Prepared: $MINIO_DATA_DIR"
    done
    
    return 0
}

generate_minio_credentials() {
    log_info "Generating MinIO credentials..."
    
    # Generate strong random credentials
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
    
    # Create namespace (unique per node to support multiple MinIO instances)
    # Using minio-<hostname> to allow each node to have its own isolated MinIO instance
    local NODE_NAME=$(hostname)
    export MINIO_NAMESPACE="minio-$NODE_NAME"
    
    log_info "Using namespace: $MINIO_NAMESPACE"
    kubectl create namespace "$MINIO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Create secret
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
    
    # Add MinIO helm repository
    if retry_command 3 "helm repo add minio https://charts.min.io/ 2>&1"; then
        log_success "MinIO helm repo added"
    else
        log_error "Failed to add MinIO helm repo"
        return 1
    fi
    
    # Update helm repos
    if ! timeout 60 helm repo update 2>&1; then
        log_warn "Helm repo update timed out, but continuing..."
    fi
    
    # Get current node name for affinity (works on control plane or worker)
    local NODE_NAME=$(hostname)
    
    if [ -z "$NODE_NAME" ]; then
        log_warn "Could not detect node name, MinIO may schedule on any node"
        NODE_NAME=""
    else
        log_info "MinIO will be scheduled on node: $NODE_NAME"
    fi
    
    # Build volume paths for MinIO
    local disks=($MINIO_DISKS)
    local VOLUME_COUNT=${#disks[@]}
    
    # For multiple disks, use erasure coding format
    # For single disk, use standalone mode
    local MINIO_MODE="standalone"
    local MINIO_VOLUMES=""
    
    if [ $VOLUME_COUNT -eq 1 ]; then
        MINIO_MODE="standalone"
        MINIO_VOLUMES="${disks[0]}/minio-data"
    else
        # Multiple disks - MinIO will use distributed mode
        MINIO_MODE="distributed"
        # Format: /disk1/minio-data,/disk2/minio-data,...
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
    
    # Calculate total storage size
    local TOTAL_SIZE=$(df -h "${disks[@]}" | tail -${#disks[@]} | awk '{sum+=$2} END {print sum"Gi"}')
    
    # Install MinIO with hostPath volumes
    log_info "Installing MinIO (this may take 2-3 minutes)..."
    
    # Create values file for hostPath configuration
    local VALUES_FILE=$(mktemp)
    cat > "$VALUES_FILE" <<EOF
mode: $MINIO_MODE
replicas: 1
persistence:
  enabled: false  # We use hostPath directly
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
priorityClassName: mynodeone-infrastructure
EOF

    # Add node affinity if worker node detected
    if [ -n "$NODE_NAME" ]; then
        cat >> "$VALUES_FILE" <<EOF
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
    fi
    
    # Install MinIO
    if helm upgrade --install minio minio/minio \
        --namespace "$MINIO_NAMESPACE" \
        --values "$VALUES_FILE" \
        --wait --timeout=5m; then
        
        rm -f "$VALUES_FILE"
        log_success "MinIO helm chart installed in namespace $MINIO_NAMESPACE"
    else
        rm -f "$VALUES_FILE"
        log_error "MinIO helm installation failed"
        log_info "Checking MinIO status..."
        kubectl get pods -n "$MINIO_NAMESPACE" || true
        kubectl get svc -n "$MINIO_NAMESPACE" || true
        return 1
    fi
    
    return 0
}

patch_minio_for_hostpath() {
    log_info "Configuring MinIO to use hostPath volumes..."
    
    # Wait for Workload (StatefulSet or Deployment) to be created
    local max_retries=10
    local retry_count=0
    local WORKLOAD_NAME=""
    local WORKLOAD_TYPE=""
    
    while [ $retry_count -lt $max_retries ]; do
        # Check for StatefulSet first
        local sts=$(kubectl get statefulset -n "$MINIO_NAMESPACE" -o name 2>/dev/null | head -1)
        if [ -n "$sts" ]; then
            WORKLOAD_NAME=$(echo "$sts" | cut -d'/' -f2)
            WORKLOAD_TYPE="statefulset"
            break
        fi
        
        # Check for Deployment
        local deploy=$(kubectl get deployment -n "$MINIO_NAMESPACE" -o name 2>/dev/null | head -1)
        if [ -n "$deploy" ]; then
            WORKLOAD_NAME=$(echo "$deploy" | cut -d'/' -f2)
            WORKLOAD_TYPE="deployment"
            break
        fi
        
        log_info "Waiting for MinIO workload to appear... ($((retry_count+1))/$max_retries)"
        sleep 5
        retry_count=$((retry_count+1))
    done
    
    if [ -z "$WORKLOAD_NAME" ]; then
        log_error "MinIO workload (StatefulSet or Deployment) not found in namespace $MINIO_NAMESPACE"
        return 1
    fi
    
    log_info "Found MinIO $WORKLOAD_TYPE: $WORKLOAD_NAME"
    
    # Build hostPath volumes configuration
    local disks=($MINIO_DISKS)
    local VOLUME_MOUNTS="["
    local VOLUMES="["
    
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local vol_name="data-$i"
        
        # In deployment mode, the volume name in the chart might be different
        # Usually it's 'export' or 'data'. We'll try to add a new one and mount it.
        # But for standalone mode with 1 drive, we usually replace the existing mount.
        
        # NOTE: For MinIO chart in standalone mode, it usually mounts 'export' to /export
        # We need to ensure we mount our hostPath to the same location MinIO expects data.
        # Standard MinIO docker image uses /data or /export. 
        # The Helm chart often uses /export for standalone.
        
        local mount_path="/export"
        if [ ${#disks[@]} -gt 1 ]; then
             mount_path="/data$i" # Distributed mode usually /data{0...n}
        fi
        
        # However, we configured `drivesPerNode: $VOLUME_COUNT`.
        # If VOLUME_COUNT > 1, it's distributed.
        
        local host_path="${disk}/minio-data"
        
        # Add volume mount
        if [ $i -gt 0 ]; then
            VOLUME_MOUNTS="$VOLUME_MOUNTS,"
            VOLUMES="$VOLUMES,"
        fi
        
        # If checking existing mounts is hard, we can just overwrite/append.
        # But we need to know the target mount path in the container.
        # In standalone (1 drive), it's usually /export.
        
        if [ ${#disks[@]} -eq 1 ]; then
             mount_path="/export"
             vol_name="export" # Match chart's likely volume name to overwrite or just add new
        else
             mount_path="/data$i"
        fi
        
        VOLUME_MOUNTS="${VOLUME_MOUNTS}{\"name\":\"${vol_name}\",\"mountPath\":\"${mount_path}\"}"
        VOLUMES="${VOLUMES}{\"name\":\"${vol_name}\",\"hostPath\":{\"path\":\"${host_path}\",\"type\":\"DirectoryOrCreate\"}}"
    done
    
    VOLUME_MOUNTS="$VOLUME_MOUNTS]"
    VOLUMES="$VOLUMES]"
    
    # Patch Workload to use hostPath
    log_info "Patching $WORKLOAD_TYPE with hostPath volumes..."
    
    # We remove 'persistence' volume claim templates if STS, or emptyDir volumes if Deployment
    # And replace/add our hostPath volumes.
    # We also update the container mounts.
    
    # Construct patch based on type
    # Using 'json' patch is precise but requires knowing the array indices.
    # 'strategic' merge patch is easier for lists if we have keys, but replacing list is safer.
    
    # Let's try to overwrite volumes and volumeMounts completely for the first container.
    
    if kubectl patch $WORKLOAD_TYPE "$WORKLOAD_NAME" -n "$MINIO_NAMESPACE" --type=json -p="[
        {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":$VOLUMES},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":$VOLUME_MOUNTS}
    ]" 2>&1; then
        log_success "MinIO configured for hostPath volumes"
    else
        log_warn "First patch attempt failed, trying to merge..."
        # Fallback: try merge patch if replace failed (e.g. path didn't exist)
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
    
    # Check if MinIO pods exist
    if ! kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio &> /dev/null; then
        log_error "MinIO pods not found in namespace $MINIO_NAMESPACE"
        return 1
    fi
    
    # Wait for MinIO to be ready
    log_info "Waiting for MinIO to be ready (up to 2 minutes)..."
    if kubectl wait --for=condition=ready --timeout=120s pod -l app=minio -n "$MINIO_NAMESPACE" 2>&1; then
        log_success "MinIO pods are ready"
    else
        log_warn "MinIO pods not ready yet, checking status..."
        kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio || true
    fi
    
    # Check services
    log_info "Checking MinIO services..."
    kubectl get svc -n "$MINIO_NAMESPACE" || true
    
    # Verify data directories
    log_info "Verifying MinIO data directories..."
    local disks=($MINIO_DISKS)
    for disk in "${disks[@]}"; do
        local DATA_DIR="$disk/minio-data"
        if [ -d "$DATA_DIR" ]; then
            log_success "✓ $DATA_DIR exists"
        else
            log_warn "✗ $DATA_DIR not found"
        fi
    done
    
    log_success "MinIO installation verified"
    return 0
}

register_minio_services() {
    log_info "Registering MinIO services for DNS..."
    
    # Check if service registry script exists
    local REGISTRY_SCRIPT="$SCRIPT_DIR/../../lib/service-registry.sh"
    if [ -f "$REGISTRY_SCRIPT" ]; then
        # Get node name from hostname
        local node_name=$(hostname)
        
        # Get cluster domain - prefer env var (set by bootstrap), fallback to /etc/resolv.conf, then ConfigMap
        local cluster_domain="${CLUSTER_DOMAIN:-}"
        
        if [[ -z "$cluster_domain" ]]; then
             # Try to guess from /etc/resolv.conf (look for search svc.cluster.local)
             cluster_domain=$(grep '^search' /etc/resolv.conf | grep -o 'svc\.[^ ]*' | sed 's/^svc\.//' | head -1)
        fi
        
        if [[ -z "$cluster_domain" ]]; then
            cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "atomcloud.local")
        fi
        
        # Register ONLY node-specific services (no generic aliases)
        # Use CLI syntax: bash service-registry.sh register <name> <subdomain> <namespace> <service> <port> <public>
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
        
        # Trigger DNS sync if available
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
    
    # Detect actual user on this machine
    detect_actual_user
    
    # Get MinIO endpoint (prefer DNS if registered)
    local NODE_NAME=$(hostname)
    local CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-atomcloud.local}" # Fallback
    local MINIO_DNS="minio-${NODE_NAME}.${CLUSTER_DOMAIN}"
    local CONSOLE_DNS="minio-console-${NODE_NAME}.${CLUSTER_DOMAIN}"
    
    local MINIO_ENDPOINT=$(kubectl get svc -n "$MINIO_NAMESPACE" minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    local MINIO_CONSOLE_IP=$(kubectl get svc -n "$MINIO_NAMESPACE" minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    # Check if DNS is resolvable (simple check)
    local S3_URL="http://${MINIO_ENDPOINT}:9000"
    local CONSOLE_URL="http://${MINIO_CONSOLE_IP}:9001"
    
    if getent hosts "$MINIO_DNS" &>/dev/null; then
        S3_URL="http://${MINIO_DNS}:9000"
    fi
    if getent hosts "$CONSOLE_DNS" &>/dev/null; then
        CONSOLE_URL="http://${CONSOLE_DNS}:9001"
    fi
    
    cat > "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt" <<EOF
MinIO Worker Node Credentials
==============================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
S3 Endpoint: $S3_URL
Console: $CONSOLE_URL

Storage Locations:
EOF
    
    local disks=($MINIO_DISKS)
    for disk in "${disks[@]}"; do
        echo "  - ${disk}/minio-data" >> "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt"
    done
    
    cat >> "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt" <<EOF
    
WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    
    chmod 600 "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt"
    
    log_success "Credentials saved to: $ACTUAL_HOME/mynodeone-minio-worker-credentials.txt"
}

detect_available_disks() {
    # Log to stderr to not pollute stdout (which is captured)
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') Detecting available disks..." >&2
    
    # Get OS disk
    local os_disk=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    
    # Find real block devices by scanning /dev directly
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
        
        # Skip OS disk
        local os_disk_base=$(basename "$os_disk")
        if [[ "$disk_name" == "$os_disk_base" ]] || [[ "/dev/$disk_name" == "$os_disk" ]]; then
            continue
        fi
        
        # Skip already mounted disks (unless mounted at /mnt/minio)
        if [[ -n "$disk_mount" ]]; then
             if [[ "$disk_mount" == "/mnt/minio"* ]]; then
                 # Already our disk, include it
                 :
             elif [[ "$disk_mount" == "/mnt/longhorn-disks"* ]]; then
                 # Longhorn disk, SKIP
                 continue
             else
                 # Other mount, skip
                 continue
             fi
        fi
        
        # Skip loop/nbd/ram
        local disk_basename=$(basename "$disk_name")
        if [[ "$disk_basename" =~ ^loop[0-9]+ ]] || [[ "$disk_basename" =~ ^nbd[0-9]+ ]] || [[ "$disk_basename" =~ ^ram[0-9]+ ]]; then
            continue
        fi
        
        # Skip virtual disks
        local model=$(lsblk -n -o MODEL "/dev/$disk_name" 2>/dev/null | head -1 | xargs)
        if [[ "$model" == "VIRTUAL-DISK" ]] || [[ "$model" == *"Virtual"* ]]; then
            continue
        fi
        
        # Skip disks smaller than 10GB
        local size_gb=$(echo "$disk_size" | sed 's/G//' | sed 's/T/*1024/' | bc 2>/dev/null || echo "0")
        if (( $(echo "$size_gb < 10" | bc -l 2>/dev/null || echo "0") )); then
            continue
        fi
        
        available_disks+=("$disk_name:$disk_size:$disk_fstype:$model")
    done <<< "$all_disks"
    
    echo "${available_disks[@]}"
}

select_disks_for_minio() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Disk Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local available_disks=($(detect_available_disks))
    
    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log_warn "No additional dedicated disks detected"
        log_info "MinIO will use /var/lib/minio (OS disk) as fallback"
        echo -n "Continue with OS disk? [y/N]: "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_warn "Installation cancelled"
            exit 0
        fi
        export MINIO_DISKS="/var/lib/minio"
        return 0
    fi
    
    log_info "Available physical disks:"
    echo
    
    for i in "${!available_disks[@]}"; do
        local disk_info="${available_disks[$i]}"
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_model=$(echo "$disk_info" | cut -d: -f4)
        
        echo "  $((i+1))) /dev/$disk_name ($disk_size) - $disk_model"
    done
    
    echo
    echo -e "  • Enter ${BLUE}1,2,3${NC} for specific disks (will be FORMATTED)"
    echo -e "  • Enter ${BLUE}all${NC} for all available disks"
    echo
    echo -n "Your choice: "
    read -r choice
    
    local selected_indices=()
    if [[ "$choice" == "all" ]]; then
        for i in "${!available_disks[@]}"; do
            selected_indices+=($i)
        done
    else
        IFS=',' read -ra ADDR <<< "$choice"
        for i in "${ADDR[@]}"; do
            # Validate input is a number
            if ! [[ "$i" =~ ^[0-9]+$ ]]; then
                log_error "Invalid selection: $i"
                return 1
            fi
            
            # Adjust for 0-based array index
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
        
        # Standardize on /mnt/minio/disk-X
        
        log_info "Formatting $device..."
        
        # Unmount if mounted
        umount "$device"* 2>/dev/null || true
        
        # Wipe filesystem signatures
        wipefs -a "$device"
        
        # Create partition
        echo -e "n\np\n1\n\n\n\nw" | fdisk "$device" 2>/dev/null || true
        partprobe "$device" 2>/dev/null || true
        sleep 2
        
        local partition="${device}1"
        if [ ! -b "$partition" ]; then
            partition="$device" # Fallback to whole disk if partition fail
        fi
        
        # Format ext4
        mkfs.ext4 -F "$partition"
        
        # Mount
        mkdir -p "$mount_point"
        mount "$partition" "$mount_point"
        
        # Add to fstab
        local uuid=$(blkid -s UUID -o value "$partition")
        if ! grep -q "$uuid" /etc/fstab; then
            echo "UUID=$uuid $mount_point ext4 defaults 0 0" >> /etc/fstab
        fi
        
        mounted_disks+=("$mount_point")
        log_success "Mounted $device at $mount_point"
    done
    
    export MINIO_DISKS="${mounted_disks[@]}"
    return 0
}

main() {
    log_info "===== MinIO Worker Installation ====="
    
    if ! check_requirements; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    # Get current node name for affinity (works on control plane or worker)
    local NODE_NAME=$(hostname)
    
    # Confirm installation node
    echo
    log_info "MinIO will be installed LOCALLY on this node: $NODE_NAME"
    echo -n "Is this correct? [Y/n]: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        log_warn "Installation cancelled by user"
        exit 0
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
    
    # Note: Patching for hostPath may not be needed depending on helm chart version
    # Keeping as optional step
    patch_minio_for_hostpath || log_warn "HostPath patching skipped or failed"
    
    if ! verify_minio_installation; then
        log_error "MinIO verification failed"
        exit 1
    fi
    
    # Register MinIO services for DNS (Do this BEFORE saving credentials so we can use the DNS names)
    register_minio_services
    
    save_credentials
    
    echo
    log_success "===== MinIO Worker Installation Complete ====="
    log_info "MinIO is running on worker node with local disk storage"
    log_info "Credentials saved to: ~/mynodeone-minio-worker-credentials.txt"
}

main "$@"
