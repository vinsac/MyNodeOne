#!/bin/bash

###############################################################################
# Add Additional Disk to Longhorn
# 
# This script helps you add extra disks to Longhorn storage
# Useful if you add new drives after initial installation
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Is Kubernetes installed?"
    exit 1
fi

# Check if Longhorn is installed
if ! kubectl get namespace longhorn-system &> /dev/null; then
    log_error "Longhorn is not installed. Install it first with ./scripts/bootstrap-control-plane.sh"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Add Disk to Longhorn Storage${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Get node name
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
log_info "Node: $NODE_NAME"
echo

# Show currently configured Longhorn disks
log_info "Currently configured Longhorn disks:"
kubectl -n longhorn-system get node "$NODE_NAME" -o jsonpath='{.spec.disks}' | jq -r 'to_entries | .[] | "  • \(.key): \(.value.path)"' 2>/dev/null || echo "  (none)"
echo

# Show available mounted disks
log_info "Available mounted disks at /mnt/longhorn-disks:"
if [ -d "/mnt/longhorn-disks" ]; then
    find /mnt/longhorn-disks -maxdepth 1 -type d -name "disk-*" | while read -r disk_path; do
        if mountpoint -q "$disk_path" 2>/dev/null; then
            DISK_SIZE=$(df -h "$disk_path" | tail -1 | awk '{print $2}')
            DISK_USED=$(df -h "$disk_path" | tail -1 | awk '{print $3}')
            DISK_AVAIL=$(df -h "$disk_path" | tail -1 | awk '{print $4}')
            echo "  • $disk_path (Total: $DISK_SIZE, Used: $DISK_USED, Available: $DISK_AVAIL)"
        fi
    done
else
    echo "  (none found)"
fi
echo

# Ask user which disk to add
read -p "Enter the full path of the disk to add (e.g., /mnt/longhorn-disks/disk-sdb): " DISK_PATH

# Validate path
if [ ! -d "$DISK_PATH" ]; then
    log_error "Directory does not exist: $DISK_PATH"
    exit 1
fi

if ! mountpoint -q "$DISK_PATH"; then
    log_error "Not a mount point: $DISK_PATH"
    log_error "Make sure the disk is mounted before adding it to Longhorn"
    exit 1
fi

# Generate disk name from path
DISK_NAME="disk-$(basename "$DISK_PATH")"

# Check if already added
if kubectl -n longhorn-system get node "$NODE_NAME" -o json | jq -e ".spec.disks.\"$DISK_NAME\"" &> /dev/null; then
    log_warn "Disk $DISK_NAME is already configured in Longhorn"
    read -p "Do you want to update it? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi
fi

# Show disk info
DISK_SIZE=$(df -h "$DISK_PATH" | tail -1 | awk '{print $2}')
log_info "Adding disk:"
log_info "  Path: $DISK_PATH"
log_info "  Name: $DISK_NAME"
log_info "  Size: $DISK_SIZE"
echo

# Confirm
read -p "Add this disk to Longhorn? [Y/n]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]] && [ -n "$REPLY" ]; then
    log_info "Cancelled."
    exit 0
fi

# Add disk to Longhorn
log_info "Adding disk to Longhorn..."

kubectl -n longhorn-system patch node "$NODE_NAME" --type='json' -p="[
    {
        \"op\": \"add\",
        \"path\": \"/spec/disks/$DISK_NAME\",
        \"value\": {
            \"path\": \"$DISK_PATH\",
            \"allowScheduling\": true,
            \"evictionRequested\": false,
            \"storageReserved\": 0,
            \"tags\": []
        }
    }
]"

if [ $? -eq 0 ]; then
    log_success "Disk added successfully!"
    echo
    log_info "Longhorn will start using this disk automatically."
    log_info "You can verify in the Longhorn UI at: http://$(tailscale ip -4):30080"
else
    log_error "Failed to add disk"
    echo
    log_info "You can add it manually via the Longhorn UI:"
    log_info "  1. Open Longhorn UI: http://$(tailscale ip -4):30080"
    log_info "  2. Go to Node → $NODE_NAME"
    log_info "  3. Click 'Edit node and disks'"
    log_info "  4. Add disk with path: $DISK_PATH"
    exit 1
fi

echo
log_info "Current Longhorn disks:"
kubectl -n longhorn-system get node "$NODE_NAME" -o jsonpath='{.spec.disks}' | jq -r 'to_entries | .[] | "  • \(.key): \(.value.path)"'
echo
