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
# OPTIONS (environment variables):
#   MINIO_IMAGE          Image to deploy. Default: the digest pinned below.
#   MINIO_RUN_AS_UID     UID the container runs as, and owner of the data
#                        directory. Must match the image. Default: 65532.
#   MINIO_EXISTING_PATH  Use a directory that's already mounted on the node
#                        instead of offering disks. Nothing is formatted. On a
#                        reinstall, the existing root credentials are kept.
#
# The script will:
# 1. Prompt for target node selection
# 2. Detect available disks on that node
# 3. Format and mount selected disk
# 4. Generate unique credentials
# 5. Deploy MinIO to Kubernetes
# 6. Register in service discovery
###############################################################################

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/project-root.sh"
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

# Set KUBECONFIG appropriately
export_k8s_config

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

# LIB_DIR, MANIFESTS_DIR, etc. setup
LIB_DIR="$PROJECT_ROOT/scripts/lib"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# Every disk this script erases goes through these checks
source "$SCRIPT_DIR/../lib/disk-safety.sh"

# MinIO stopped publishing images: minio/minio is gone from Docker Hub and
# quay.io/minio/minio refuses anonymous pulls. This is PGSTY Silo, the maintained
# MinIO server fork that keeps the full admin console (users, groups, policies),
# pinned by tag + multi-arch index digest (amd64/arm64). It works as UID 65532 with
# all capabilities dropped. See README.md for why, and how to update or replace it.
MINIO_IMAGE_DEFAULT="pgsty/silo:RELEASE.2026-11-09T00-00-00Z@sha256:08ce1505b5eacefbad1ca07159b242b9ce045a11c2817e3bc257b25f77bbc02d"
MINIO_IMAGE="${MINIO_IMAGE:-$MINIO_IMAGE_DEFAULT}"
MINIO_RUN_AS_UID="${MINIO_RUN_AS_UID:-65532}"

if ! [[ "$MINIO_IMAGE" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
    log_error "MINIO_IMAGE is not a valid image reference: $MINIO_IMAGE"
    exit 1
fi
if ! [[ "$MINIO_RUN_AS_UID" =~ ^[0-9]+$ ]]; then
    log_error "MINIO_RUN_AS_UID must be a number: $MINIO_RUN_AS_UID"
    exit 1
fi

# Writes the credentials file with stdin as its contents. A temp file is created
# with mode 600 and renamed into place, so the secret is never readable by others,
# even when an older file with looser permissions already exists.
write_credentials_file() {
    local dest="$1"
    local owner="$2"
    (
        umask 077
        tmp=$(mktemp "${dest}.XXXXXX") || exit 1
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp" || exit 1
        if ! chown "$owner:" "$tmp" 2>/dev/null; then
            log_warn "Could not give $dest to $owner. It stays owned by $(id -un)."
        fi
        mv -f "$tmp" "$dest" || exit 1
    )
}

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
current_node=$(get_k8s_node_name)
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

# Whether MinIO is already on this node. Nothing happens to it until the target path has
# been chosen and checked against it, further down.
NAMESPACE="minio-${NODE_NAME}"
EXISTING_INSTALL=false
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    EXISTING_INSTALL=true
    log_warn "MinIO already installed on node $NODE_NAME (namespace: $NAMESPACE)"
fi

# SSH to node for disk operations (if not local)
current_local_node=$(get_k8s_node_name)
if [ "$NODE_NAME" = "$current_local_node" ]; then
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

format_and_mount_disk() {
    local disk="$1"
    local mount_path="$2"
    local node_cmd_prefix="$3"
    
    log_info "Formatting and mounting $disk..."

    # Re-checks the disk and erases its signatures. Mounted disks are refused
    # rather than unmounted, and any failure stops the install.
    if ! disk_safety_wipe "$disk"; then
        log_error "Could not safely erase $disk. Stopping."
        exit 1
    fi

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

    # STRUCTURAL FIX: Prevent writing to root filesystem if mount fails
    # We make the underlying directory immutable. Data can only be written if a disk is mounted over it.
    log_info "Applying safety lock to mount point..."
    # Check if chattr exists (it should on standard linux)
    if $node_cmd_prefix command -v chattr &> /dev/null; then
        # Ensure it is currently unmounted before locking
        if ! $node_cmd_prefix mountpoint -q "$mount_path"; then
             $node_cmd_prefix chattr +i "$mount_path" || log_warn "Failed to set immutable flag (non-critical)"
        fi
    fi
    
    # Mount partition
    log_info "Mounting $partition to $mount_path..."
    $node_cmd_prefix mount "$partition" "$mount_path"
    
    # Add to fstab
    local uuid=""
    uuid=$($node_cmd_prefix blkid -s UUID -o value "$partition")
    if ! [[ "$uuid" =~ ^[A-Fa-f0-9-]+$ ]]; then
        log_error "Could not read the UUID of $partition, so /etc/fstab was not updated. Stopping."
        exit 1
    fi

    # Replace any existing entry for this mount point to prevent duplicates. The
    # script goes over stdin because a bash -c string would be split by ssh and run
    # partly as the unprivileged user on remote nodes.
    log_info "Updating /etc/fstab..."
    $node_cmd_prefix bash -s -- "$uuid" "$mount_path" <<'FSTAB_SCRIPT'
set -eu
tmp=$(mktemp /etc/fstab.XXXXXX)
trap 'rm -f "$tmp"' EXIT
awk -v mp="$2" '$2 != mp' /etc/fstab > "$tmp"
printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$1" "$2" >> "$tmp"
chmod 644 "$tmp"
mv "$tmp" /etc/fstab
trap - EXIT
FSTAB_SCRIPT

    log_success "Disk mounted at $mount_path"
}

# Detect disks on target node
if [ "$IS_LOCAL" = true ]; then
    NODE_CMD_PREFIX="sudo"
else
    NODE_CMD_PREFIX="ssh $SSH_USER@$NODE_IP sudo"
fi

# Disk checks run on the target node through the same prefix
disk_safety_init "$NODE_CMD_PREFIX"

if [ -n "${MINIO_EXISTING_PATH:-}" ]; then
    # Keep what's already there: an existing mount is used as is
    if ! disk_safety_check_data_path "$MINIO_EXISTING_PATH"; then
        log_error "MINIO_EXISTING_PATH can't be used on $NODE_NAME: $MINIO_EXISTING_PATH"
        exit 1
    fi
    MINIO_PATH="$MINIO_EXISTING_PATH"
    EXISTING_SIZE_GB=$($NODE_CMD_PREFIX df -BG --output=size "$MINIO_PATH" | tail -1 | tr -dc '0-9')
    if [ -z "$EXISTING_SIZE_GB" ]; then
        log_error "Could not read the size of $MINIO_PATH on $NODE_NAME."
        exit 1
    fi
    STORAGE_SIZE="${EXISTING_SIZE_GB}Gi"
    log_info "Using existing mount: $MINIO_PATH ($STORAGE_SIZE). Nothing will be formatted."
else
    log_info "Detecting available disks on $NODE_NAME..."
    echo ""
    echo "💡 Disk options:"
    echo "  0) Use OS folder: /var/lib/minio (no formatting needed)"
    echo ""

    available_disks=()
    if disk_safety_scan; then
        available_disks=("${DISK_SAFETY_ELIGIBLE[@]}")
    fi
    if [ ${#available_disks[@]} -eq 0 ]; then
        log_warn "No disks can be safely formatted (only the OS folder is available)"
    fi

    echo ""
    read -r -p "Select disk [0-${#available_disks[@]}]: " DISK_CHOICE

    if [ "$DISK_CHOICE" = "0" ]; then
        MINIO_PATH="/var/lib/minio"
        STORAGE_SIZE="100Gi"
        log_info "Using OS folder: $MINIO_PATH"
    elif [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && [[ $DISK_CHOICE -ge 1 ]] && [[ $DISK_CHOICE -le ${#available_disks[@]} ]]; then
        SELECTED_DISK="${available_disks[$((DISK_CHOICE-1))]}"

        if ! disk_safety_confirm_wipe "$SELECTED_DISK"; then
            log_error "Installation cancelled. $SELECTED_DISK was not changed."
            exit 1
        fi

        MINIO_PATH="/mnt/minio"

        DISK_SIZE_RAW=$($NODE_CMD_PREFIX lsblk -d -n -o SIZE "$SELECTED_DISK" | tr -d ' ')

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
    else
        log_error "Invalid selection"
        exit 1
    fi
fi

# A PV's hostPath can't be changed, and it outlives the namespace because it's Retain. A
# different path would fail at the PV, after everything else was gone. So this comes first.
EXISTING_PV_PATH=""
if ! EXISTING_PV_PATH=$(kubectl get pv "minio-data-${NODE_NAME}" -o jsonpath='{.spec.hostPath.path}' --ignore-not-found); then
    log_error "Could not read PersistentVolume minio-data-${NODE_NAME}. Nothing was changed."
    exit 1
fi
if [ -n "$EXISTING_PV_PATH" ] && [ "${EXISTING_PV_PATH%/}" != "${MINIO_PATH%/}" ]; then
    log_error "PersistentVolume minio-data-${NODE_NAME} points at $EXISTING_PV_PATH, not $MINIO_PATH, and a PV's path can't be changed. Nothing was changed."
    log_error "To keep using the data there, run again with: MINIO_EXISTING_PATH=$EXISTING_PV_PATH"
    log_error "To really move to $MINIO_PATH (the PV is Retain, so this doesn't touch the data on the node):"
    log_error "  kubectl delete namespace $NAMESPACE   # also deletes the root credentials"
    log_error "  kubectl delete pv minio-data-${NODE_NAME}"
    log_error "  then run this again, and re-run scripts/storage/velero/configure-backup.sh if Velero uses this MinIO"
    exit 1
fi

# With an existing path the data stays, so the credentials it was written with have to
# stay too. Read before anything is deleted: if they can't be read, nothing is changed.
MINIO_USER="admin"
MINIO_PASSWORD=""
if [ "$EXISTING_INSTALL" = true ] && [ -n "${MINIO_EXISTING_PATH:-}" ]; then
    EXISTING_USER_B64=$(kubectl get secret minio-credentials -n "$NAMESPACE" -o jsonpath='{.data.rootUser}' 2>/dev/null || true)
    EXISTING_PASSWORD_B64=$(kubectl get secret minio-credentials -n "$NAMESPACE" -o jsonpath='{.data.rootPassword}' 2>/dev/null || true)
    if [ -z "$EXISTING_USER_B64" ] || [ -z "$EXISTING_PASSWORD_B64" ]; then
        log_error "Could not read the existing credentials from Secret minio-credentials in $NAMESPACE. Nothing was changed."
        exit 1
    fi
    if ! MINIO_USER=$(printf '%s' "$EXISTING_USER_B64" | base64 -d) || [ -z "$MINIO_USER" ] ||
       ! MINIO_PASSWORD=$(printf '%s' "$EXISTING_PASSWORD_B64" | base64 -d) || [ -z "$MINIO_PASSWORD" ]; then
        log_error "The existing credentials in Secret minio-credentials in $NAMESPACE are not valid. Nothing was changed."
        exit 1
    fi
    log_info "Keeping the existing root credentials"
fi

if [ "$EXISTING_INSTALL" = true ]; then
    if [ -n "${MINIO_EXISTING_PATH:-}" ]; then
        log_warn "Reinstalling deletes the namespace, then recreates it using the same data ($MINIO_PATH) and the same root credentials."
    else
        log_warn "Reinstalling deletes the namespace and its credentials, and creates new ones."
        log_warn "Velero keeps a copy of the old ones: re-run scripts/storage/velero/configure-backup.sh afterwards if it uses this MinIO."
        log_warn "A disk that's still mounted can't be selected above. To keep using the data"
        log_warn "on it, cancel and run again with MINIO_EXISTING_PATH set to its mountpoint."
    fi
    if ! disk_safety_is_interactive; then
        log_error "Reinstalling needs a terminal to confirm. Nothing was changed."
        exit 1
    fi
    read -r -p "Type the namespace name ($NAMESPACE) to reinstall, or anything else to cancel: " REPLY
    if [[ "$REPLY" != "$NAMESPACE" ]]; then
        log_info "Installation cancelled"
        exit 0
    fi

    log_info "Removing existing MinIO installation..."
    kubectl delete namespace "$NAMESPACE" --wait=true
    log_success "Existing installation removed"
fi

# Nothing above writes to the node. Set up the chosen path now.
if [ -z "${MINIO_EXISTING_PATH:-}" ]; then
    if [ -n "${SELECTED_DISK:-}" ]; then
        # Format and mount on target node
        format_and_mount_disk "$SELECTED_DISK" "$MINIO_PATH" "$NODE_CMD_PREFIX"
    else
        # Create directory on target node
        $NODE_CMD_PREFIX mkdir -p "$MINIO_PATH"
        $NODE_CMD_PREFIX chmod 755 "$MINIO_PATH"
        log_success "Created directory: $MINIO_PATH"
    fi
fi

# hostPath volumes ignore fsGroup, so the directory has to be owned by the
# container's user up front
log_info "Setting owner of $MINIO_PATH to UID $MINIO_RUN_AS_UID..."
$NODE_CMD_PREFIX chown -R "$MINIO_RUN_AS_UID:$MINIO_RUN_AS_UID" "$MINIO_PATH"

# Generate unique credentials, unless the existing ones were kept above
if [ -z "$MINIO_PASSWORD" ]; then
    log_info "Generating credentials..."
    MINIO_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    log_success "Credentials generated"
fi

# Create namespace
log_info "Creating namespace: $NAMESPACE..."
cat "$MANIFESTS_DIR/namespace.yaml" | \
    sed "s/NAMESPACE_PLACEHOLDER/${NAMESPACE}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    kubectl apply -f -
log_success "Namespace created"

# Create StorageClass (Idempotent)
log_info "Creating StorageClass: minio-local..."
kubectl apply -f "$MANIFESTS_DIR/storageclass.yaml" || log_warn "StorageClass creation failed (might already exist)"
log_success "StorageClass verified"

# Create secret
log_info "Creating secret with credentials..."
# Built in the shell and sent over stdin, so the password never appears in a process list.
SECRET_MANIFEST=$(<"$MANIFESTS_DIR/secret.yaml")
SECRET_MANIFEST="${SECRET_MANIFEST//NAMESPACE_PLACEHOLDER/$NAMESPACE}"
SECRET_MANIFEST="${SECRET_MANIFEST//ROOT_USER_B64_PLACEHOLDER/$(printf '%s' "$MINIO_USER" | base64 -w0)}"
SECRET_MANIFEST="${SECRET_MANIFEST//ROOT_PASSWORD_B64_PLACEHOLDER/$(printf '%s' "$MINIO_PASSWORD" | base64 -w0)}"
printf '%s\n' "$SECRET_MANIFEST" | kubectl apply -f -
unset SECRET_MANIFEST
log_success "Secret created"

# Create PV
PV_NAME="${NODE_NAME}"
# After a reinstall the retained PV still points at the deleted PVC, and a new PVC
# can't bind until that reference is removed. The data on the node isn't affected.
if [ "$(kubectl get pv "minio-data-${PV_NAME}" -o jsonpath='{.status.phase}' --ignore-not-found)" = "Released" ]; then
    log_info "Releasing retained PersistentVolume minio-data-${PV_NAME} for reuse..."
    kubectl patch pv "minio-data-${PV_NAME}" --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
fi
log_info "Creating PersistentVolume: minio-data-${PV_NAME}..."
cat "$MANIFESTS_DIR/pv-hostpath.yaml" | \
    sed "s/PV_NAME_PLACEHOLDER/${PV_NAME}/g" | \
    sed "s/NODE_PLACEHOLDER/${NODE_NAME}/g" | \
    sed "s|STORAGE_SIZE_PLACEHOLDER|${STORAGE_SIZE}|g" | \
    sed "s|HOST_PATH_PLACEHOLDER|${MINIO_PATH}|g" | \
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
log_info "Deploying MinIO StatefulSet (image: $MINIO_IMAGE)..."
cat "$MANIFESTS_DIR/statefulset.yaml" | \
    sed "s|MINIO_IMAGE_PLACEHOLDER|${MINIO_IMAGE}|g" | \
    sed "s/MINIO_UID_PLACEHOLDER/${MINIO_RUN_AS_UID}/g" | \
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
if ! write_credentials_file "$CREDS_FILE" "$ACTUAL_USER" <<EOF
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
then
    log_error "Could not save credentials to $CREDS_FILE. They are printed below and stored in the minio-credentials Secret."
else
    log_success "Credentials saved to: $CREDS_FILE"
fi

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
