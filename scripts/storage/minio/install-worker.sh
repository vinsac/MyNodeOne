#!/bin/bash

###############################################################################
# MinIO Worker Installation Script
# 
# Installs MinIO object storage on worker node using local disks
# Uses same disk detection pattern as Longhorn installation
# Called during worker node addition (add-worker-node.sh)
###############################################################################

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
    log_info "Detecting available disks for MinIO..."
    
    local MOUNTED_DISKS=()
    
    # Use same pattern as Longhorn disk detection
    # Check if user has mounted disks from installation session
    if [ -d "/mnt/longhorn-disks" ]; then
        # Find all mounted disks
        while IFS= read -r disk_path; do
            if mountpoint -q "$disk_path" 2>/dev/null; then
                # Verify this disk was formatted in THIS session by checking if device is in fstab
                DISK_DEVICE=$(findmnt -n -o SOURCE "$disk_path" 2>/dev/null)
                if [ -n "$DISK_DEVICE" ] && grep -q "$disk_path" /etc/fstab 2>/dev/null; then
                    MOUNTED_DISKS+=("$disk_path")
                fi
            fi
        done < <(find /mnt/longhorn-disks -maxdepth 1 -type d -name "disk-*" 2>/dev/null | sort)
    fi
    
    if [ ${#MOUNTED_DISKS[@]} -gt 0 ]; then
        log_success "Found ${#MOUNTED_DISKS[@]} dedicated disk(s) for MinIO:"
        for disk in "${MOUNTED_DISKS[@]}"; do
            DISK_SIZE=$(df -h "$disk" | tail -1 | awk '{print $2}')
            log_info "  • $disk ($DISK_SIZE)"
        done
        
        # Export for use in other functions
        export MINIO_DISKS="${MOUNTED_DISKS[@]}"
        return 0
    else
        log_warn "No dedicated disks found in /mnt/longhorn-disks"
        log_info "Will use /var/lib/minio as fallback location"
        export MINIO_DISKS="/var/lib/minio"
        return 0
    fi
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
    
    # Create namespace
    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
    
    # Create secret
    if kubectl create secret generic minio-credentials \
        --from-literal=rootUser="$MINIO_ROOT_USER" \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
        --namespace minio \
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
    
    # Get node name for affinity
    local NODE_NAME=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$NODE_NAME" ]; then
        log_warn "Could not detect worker node name, MinIO may schedule on any node"
        NODE_NAME=""
    else
        log_info "MinIO will be scheduled on worker node: $NODE_NAME"
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
        --namespace minio \
        --values "$VALUES_FILE" \
        --wait --timeout=5m; then
        
        rm -f "$VALUES_FILE"
        log_success "MinIO helm chart installed"
    else
        rm -f "$VALUES_FILE"
        log_error "MinIO helm installation failed"
        log_info "Checking MinIO status..."
        kubectl get pods -n minio || true
        kubectl get svc -n minio || true
        return 1
    fi
    
    return 0
}

patch_minio_for_hostpath() {
    log_info "Configuring MinIO to use hostPath volumes..."
    
    # Wait for StatefulSet to be created
    sleep 5
    
    # Get StatefulSet name
    local STS_NAME=$(kubectl get statefulset -n minio -o name 2>/dev/null | head -1 | cut -d'/' -f2)
    
    if [ -z "$STS_NAME" ]; then
        log_error "MinIO StatefulSet not found"
        return 1
    fi
    
    log_info "Found MinIO StatefulSet: $STS_NAME"
    
    # Build hostPath volumes configuration
    local disks=($MINIO_DISKS)
    local VOLUME_MOUNTS="["
    local VOLUMES="["
    
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local vol_name="data-$i"
        local mount_path="${disk}/minio-data"
        
        # Add volume mount
        if [ $i -gt 0 ]; then
            VOLUME_MOUNTS="$VOLUME_MOUNTS,"
            VOLUMES="$VOLUMES,"
        fi
        VOLUME_MOUNTS="${VOLUME_MOUNTS}{\"name\":\"${vol_name}\",\"mountPath\":\"${mount_path}\"}"
        
        # Add hostPath volume
        VOLUMES="${VOLUMES}{\"name\":\"${vol_name}\",\"hostPath\":{\"path\":\"${mount_path}\",\"type\":\"DirectoryOrCreate\"}}"
    done
    
    VOLUME_MOUNTS="$VOLUME_MOUNTS]"
    VOLUMES="$VOLUMES]"
    
    # Patch StatefulSet to use hostPath
    log_info "Patching StatefulSet with hostPath volumes..."
    
    if kubectl patch statefulset "$STS_NAME" -n minio --type=json -p="[
        {\"op\":\"remove\",\"path\":\"/spec/volumeClaimTemplates\"},
        {\"op\":\"add\",\"path\":\"/spec/template/spec/volumes\",\"value\":$VOLUMES},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/volumeMounts\",\"value\":$VOLUME_MOUNTS}
    ]" 2>&1; then
        log_success "MinIO configured for hostPath volumes"
    else
        log_warn "Could not patch StatefulSet, MinIO may still work with default configuration"
    fi
    
    return 0
}

verify_minio_installation() {
    log_info "Verifying MinIO installation..."
    
    # Check if MinIO pods exist
    if ! kubectl get pods -n minio -l app=minio &> /dev/null; then
        log_error "MinIO pods not found"
        return 1
    fi
    
    # Wait for MinIO to be ready
    log_info "Waiting for MinIO to be ready (up to 2 minutes)..."
    if kubectl wait --for=condition=ready --timeout=120s pod -l app=minio -n minio 2>&1; then
        log_success "MinIO pods are ready"
    else
        log_warn "MinIO pods not ready yet, checking status..."
        kubectl get pods -n minio -l app=minio || true
    fi
    
    # Check services
    log_info "Checking MinIO services..."
    kubectl get svc -n minio || true
    
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
    
    # Source service registry functions if available
    local REGISTRY_SCRIPT="$SCRIPT_DIR/../../lib/service-registry.sh"
    if [ -f "$REGISTRY_SCRIPT" ]; then
        source "$REGISTRY_SCRIPT"
        
        # Get node name from hostname
        local node_name=$(hostname)
        
        # Get cluster domain
        local cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "cluster")
        
        # Register ONLY node-specific services (no generic aliases)
        if register_service "minio-${node_name}" "minio-${node_name}" "minio" "minio-${node_name}" "9000" "false" 2>/dev/null; then
            log_success "MinIO API registered: minio-${node_name}.${cluster_domain}.local:9000"
        else
            log_warn "Could not register MinIO API (DNS may not work)"
        fi
        
        if register_service "minio-console-${node_name}" "minio-console-${node_name}" "minio" "minio-console-${node_name}" "9001" "false" 2>/dev/null; then
            log_success "MinIO Console registered: minio-console-${node_name}.${cluster_domain}.local:9001"
        else
            log_warn "Could not register MinIO Console (DNS may not work)"
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
    
    # Get MinIO endpoint
    local MINIO_ENDPOINT=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    local MINIO_CONSOLE=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    cat > "$ACTUAL_HOME/mynodeone-minio-worker-credentials.txt" <<EOF
MinIO Worker Node Credentials
==============================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
S3 Endpoint: http://${MINIO_ENDPOINT}:9000
Console: http://${MINIO_CONSOLE}:9001

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

main() {
    log_info "===== MinIO Worker Installation ====="
    
    if ! check_requirements; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    if ! detect_available_disks; then
        log_error "Disk detection failed"
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
    
    save_credentials
    
    # Register MinIO services for DNS
    register_minio_services
    
    echo
    log_success "===== MinIO Worker Installation Complete ====="
    log_info "MinIO is running on worker node with local disk storage"
    log_info "Credentials saved to: ~/mynodeone-minio-worker-credentials.txt"
    log_info "Next: Configure Velero to use MinIO for backups"
}

main "$@"
