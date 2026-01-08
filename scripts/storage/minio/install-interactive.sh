#!/bin/bash

###############################################################################
# Interactive MinIO Installation Script (Standalone Mode)
#
# Features:
# - Standalone MinIO per node (NOT distributed)
# - Node-specific DNS endpoints (minio-NODENAME.minicloud.local)
# - Shared admin credentials across all nodes
# - Interactive disk selection
# - Registers configuration in node registry
###############################################################################

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
    echo -e "${YELLOW}[⚠]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

# Source user detection library (defensive programming)
if [[ -f "$LIB_DIR/detect-actual-home.sh" ]]; then
    source "$LIB_DIR/detect-actual-home.sh"
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

CREDENTIALS_FILE="$ACTUAL_HOME/mynodeone-minio-credentials.txt"

# Detect available disks (excluding OS disk and Longhorn disks)
detect_available_disks() {
    # Log to stderr to not pollute stdout (which is captured)
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') Detecting available disks for MinIO..." >&2
    
    # Get OS disk
    local os_disk=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    
    # Get Longhorn disks
    local longhorn_disks=$(mount | grep '/mnt/longhorn-disks' | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//' | sort -u)
    
    # Find all block devices
    local all_disks=$(lsblk -d -n -p -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT | grep 'disk' | awk '{print $1":"$3":"$4":"$5}')
    
    local available_disks=()
    
    while IFS= read -r disk_info; do
        [[ -z "$disk_info" ]] && continue
        
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_mount=$(echo "$disk_info" | cut -d: -f4)
        
        # Skip OS disk
        if [[ "$disk_name" == "$os_disk" ]]; then
            continue
        fi
        
        # Skip Longhorn disks
        local is_longhorn=false
        while IFS= read -r lh_disk; do
            [[ -z "$lh_disk" ]] && continue
            if [[ "$disk_name" == "$lh_disk" ]]; then
                is_longhorn=true
                break
            fi
        done <<< "$longhorn_disks"
        
        if [[ "$is_longhorn" == "true" ]]; then
            continue
        fi
        
        # Skip already mounted disks (except /mnt/minio)
        if [[ -n "$disk_mount" ]] && [[ "$disk_mount" != "/mnt/minio" ]]; then
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
select_disk_for_minio() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Disk Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local available_disks=($(detect_available_disks))
    
    if [[ ${#available_disks[@]} -eq 0 ]]; then
        log_warn "No additional disks available for MinIO"
        log_info "MinIO can use OS disk at /mnt/minio, but this is NOT recommended"
        echo
        read -p "Continue with OS disk? [y/N]: " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        SELECTED_DISK=""
        return 0
    fi
    
    echo
    echo -e "${BLUE}💡 Option 1: Use OS disk (no additional drive needed)${NC}"
    echo -e "  ${BLUE}0)${NC} Use OS disk - /mnt/minio ${YELLOW}(no formatting)${NC}"
    echo
    echo -e "${BLUE}💡 Option 2: Use dedicated physical disk${NC}"
    log_info "Available physical disks (excluding OS disk and Longhorn disks):"
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
    echo -e "  • Enter ${BLUE}1,2,3...${NC} for specific physical disk (will be formatted)"
    echo
    read -p "Your choice: " selection
    
    SELECTED_DISK=""
    
    if [[ "$selection" == "none" ]] || [[ "$selection" == "0" ]]; then
        log_info "Using OS disk at /mnt/minio (no formatting required)"
        return 0
    fi
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#available_disks[@]} ]]; then
        local disk_info="${available_disks[$((selection-1))]}"
        SELECTED_DISK=$(echo "$disk_info" | cut -d: -f1)
        
        local disk_size=$(lsblk -d -n -o SIZE "$SELECTED_DISK" 2>/dev/null || echo "Unknown")
        echo
        log_info "Selected disk: $SELECTED_DISK ($disk_size)"
        echo
        log_warn "⚠️  WARNING: This disk will be FORMATTED (all data will be lost)"
        echo
        read -p "Continue with formatting? [y/N]: " -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled"
            exit 1
        fi
    else
        log_error "Invalid selection"
        exit 1
    fi
}

# Format and mount disk
format_and_mount_disk() {
    if [[ -z "$SELECTED_DISK" ]]; then
        # Use OS disk
        MINIO_DATA_PATH="/mnt/minio"
        mkdir -p "$MINIO_DATA_PATH"
        return 0
    fi
    
    log_info "Formatting and mounting $SELECTED_DISK..."
    
    # Unmount if already mounted
    umount "$SELECTED_DISK"* 2>/dev/null || true
    
    # Wipe existing filesystem signatures
    wipefs -a "$SELECTED_DISK" &>/dev/null || true
    
    # Create new partition
    log_info "Creating partition..."
    parted -s "$SELECTED_DISK" mklabel gpt
    parted -s "$SELECTED_DISK" mkpart primary ext4 0% 100%
    
    # Wait for partition to appear
    sleep 2
    partprobe "$SELECTED_DISK"
    sleep 1
    
    # Determine partition device name
    local partition="${SELECTED_DISK}1"
    if [[ "$SELECTED_DISK" =~ nvme ]] || [[ "$SELECTED_DISK" =~ mmcblk ]]; then
        partition="${SELECTED_DISK}p1"
    fi
    
    # Format partition
    log_info "Formatting $partition..."
    mkfs.ext4 -F "$partition"
    
    # Create mount point
    MINIO_DATA_PATH="/mnt/minio"
    mkdir -p "$MINIO_DATA_PATH"
    
    # Mount partition
    log_info "Mounting $partition to $MINIO_DATA_PATH..."
    mount "$partition" "$MINIO_DATA_PATH"
    
    # Add to fstab
    local uuid=$(blkid -s UUID -o value "$partition")
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $MINIO_DATA_PATH ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    log_success "Disk mounted at $MINIO_DATA_PATH"
}

# Get or generate MinIO credentials
get_minio_credentials() {
    log_info "Configuring MinIO credentials..."
    
    # Check if credentials already exist in Kubernetes
    if kubectl get secret minio-credentials -n minio &>/dev/null; then
        log_info "Found existing MinIO credentials in Kubernetes"
        MINIO_ROOT_USER=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' | base64 -d)
        MINIO_ROOT_PASSWORD=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' | base64 -d)
        log_success "Using shared credentials from cluster"
    else
        log_info "No existing credentials found - generating new shared credentials"
        log_warn "These credentials will be shared across ALL MinIO instances in the cluster"
        MINIO_ROOT_USER="admin"
        MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        
        # Create namespace
        kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
        
        # Store in Kubernetes secret (persists across MinIO uninstall/reinstall)
        kubectl create secret generic minio-credentials \
            -n minio \
            --from-literal=rootUser="$MINIO_ROOT_USER" \
            --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        log_success "Generated and stored new shared credentials in Kubernetes"
        log_info "Credentials persist even if MinIO is uninstalled"
        log_info "To reset credentials: kubectl delete secret minio-credentials -n minio"
    fi
    
    # Save to local file for user reference
    cat > "$CREDENTIALS_FILE" <<EOF
MinIO Credentials
=================

Node: $(hostname)
Endpoint: http://minio-$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname).minicloud.local:9000
Console: http://minio-$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname).minicloud.local:9001

Admin Credentials (shared across all nodes):
  Username: $MINIO_ROOT_USER
  Password: $MINIO_ROOT_PASSWORD

Generated: $(date)

IMPORTANT: These credentials are shared across ALL MinIO instances in the cluster.
Each node runs a standalone MinIO instance with the same admin credentials.
EOF
    
    # Fix ownership
    if [ "$ACTUAL_USER" != "root" ] && [ "$(whoami)" = "root" ]; then
        chown "$ACTUAL_USER:$ACTUAL_USER" "$CREDENTIALS_FILE"
    fi
    
    log_success "Credentials saved to: $CREDENTIALS_FILE"
}

# Install MinIO in standalone mode
install_minio_standalone() {
    log_info "Installing MinIO in standalone mode..."
    
    # Get node name for DNS
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname)
    local minio_endpoint="minio-${node_name}.minicloud.local"
    
    # Create namespace
    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
    
    # Create PersistentVolume for local disk
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-pv-${node_name}
  labels:
    type: local
    app: minio
    node: ${node_name}
spec:
  storageClassName: manual
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: ${MINIO_DATA_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - ${node_name}
EOF
    
    # Create PersistentVolumeClaim
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc-${node_name}
  namespace: minio
spec:
  storageClassName: manual
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Ti
  selector:
    matchLabels:
      node: ${node_name}
EOF
    
    # Create Deployment
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio-${node_name}
  namespace: minio
  labels:
    app: minio
    node: ${node_name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
      node: ${node_name}
  template:
    metadata:
      labels:
        app: minio
        node: ${node_name}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${node_name}
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootUser
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootPassword
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        livenessProbe:
          httpGet:
            path: /minio/health/live
            port: 9000
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 10
          periodSeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc-${node_name}
EOF
    
    # Create Service for API
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: minio-${node_name}
  namespace: minio
  labels:
    app: minio
    node: ${node_name}
spec:
  type: LoadBalancer
  ports:
  - port: 9000
    targetPort: 9000
    protocol: TCP
    name: api
  selector:
    app: minio
    node: ${node_name}
EOF
    
    # Create Service for Console
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: minio-console-${node_name}
  namespace: minio
  labels:
    app: minio
    node: ${node_name}
spec:
  type: LoadBalancer
  ports:
  - port: 9001
    targetPort: 9001
    protocol: TCP
    name: console
  selector:
    app: minio
    node: ${node_name}
EOF
    
    log_success "MinIO deployed successfully"
    
    # Wait for services to get LoadBalancer IPs
    log_info "Waiting for LoadBalancer IPs..."
    sleep 5
    
    local api_ip=""
    local console_ip=""
    
    for i in {1..30}; do
        api_ip=$(kubectl get svc minio-${node_name} -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        console_ip=$(kubectl get svc minio-console-${node_name} -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$api_ip" ]] && [[ -n "$console_ip" ]]; then
            break
        fi
        
        sleep 2
    done
    
    if [[ -n "$api_ip" ]] && [[ -n "$console_ip" ]]; then
        log_success "MinIO API IP: $api_ip"
        log_success "MinIO Console IP: $console_ip"
        
        # Register services in service registry if available
        if command -v register_service &>/dev/null; then
            register_service "minio-${node_name}" "minio-${node_name}" minio "minio-${node_name}" 9000 false || true
            register_service "minio-console-${node_name}" "minio-console-${node_name}" minio "minio-console-${node_name}" 9001 false || true
            
            log_info "Registered MinIO services for node: ${node_name}"
            log_info "  API: minio-${node_name}.minicloud.local:9000"
            log_info "  Console: minio-console-${node_name}.minicloud.local:9001"
        fi
    else
        log_warn "LoadBalancer IPs not assigned yet (may take a few minutes)"
    fi
    
    MINIO_ENDPOINT="${minio_endpoint}:9000"
    MINIO_CONSOLE="${minio_endpoint}:9001"
}

# Register in node registry
register_in_node_registry() {
    if ! command -v update_cluster_node_minio &>/dev/null; then
        log_warn "Node registry functions not available, skipping registration"
        return 0
    fi
    
    log_info "Updating node registry with MinIO configuration..."
    
    # Get node name
    local node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$node_name" ]]; then
        log_warn "Could not detect Kubernetes node name"
        return 1
    fi
    
    # Calculate capacity
    local capacity="Unknown"
    if [[ -n "$SELECTED_DISK" ]]; then
        capacity=$(lsblk -d -n -o SIZE "$SELECTED_DISK" 2>/dev/null || echo "Unknown")
    else
        capacity=$(df -h "$MINIO_DATA_PATH" 2>/dev/null | tail -1 | awk '{print $2}')
    fi
    
    # Update node registry
    update_cluster_node_minio \
        --name "$node_name" \
        --endpoint "$MINIO_ENDPOINT" \
        --console "$MINIO_CONSOLE" \
        --disk "${SELECTED_DISK:-/mnt/minio}" \
        --capacity "$capacity" || log_warn "Could not update node registry"
    
    log_success "Node registry updated"
}

# Main installation flow
main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Interactive Installation (Standalone Mode)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "MinIO provides S3-compatible object storage"
    log_info "Mode: Standalone (NOT distributed)"
    log_info "Each node runs its own independent MinIO instance"
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
    
    # Ask if user wants MinIO
    read -p "Do you want to install MinIO on this node? [y/N]: " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    # Interactive disk selection
    select_disk_for_minio
    
    # Format and mount disk
    format_and_mount_disk
    
    # Get or generate credentials
    get_minio_credentials
    
    # Install MinIO
    install_minio_standalone
    
    # Register in node registry
    register_in_node_registry
    
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  MinIO Installation Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    log_success "MinIO is running in standalone mode"
    echo
    log_info "Endpoints:"
    echo "  API:     http://$MINIO_ENDPOINT"
    echo "  Console: http://$MINIO_CONSOLE"
    echo
    log_info "Admin Credentials:"
    echo "  Username: $MINIO_ROOT_USER"
    echo "  Password: $MINIO_ROOT_PASSWORD"
    echo
    log_info "Credentials saved to: $CREDENTIALS_FILE"
    echo
    log_warn "IMPORTANT: Each node runs a standalone MinIO instance"
    log_warn "Data is NOT replicated between nodes"
    log_warn "Use node-specific endpoints for your applications"
    echo
    log_info "MinIO will appear on dashboard within 30-60 seconds (auto-refresh)"
    echo
}

# Only run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
