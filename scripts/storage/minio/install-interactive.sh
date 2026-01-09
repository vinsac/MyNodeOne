#!/bin/bash

###############################################################################
# Interactive MinIO Installation Script (Systemd Service)
#
# Features:
# - S3-compatible object storage for the cluster
# - Simple systemd service (no Kubernetes dependencies)
# - Node-specific credentials (independent per node)
# - Interactive disk selection
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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get actual user (when run with sudo)
if [ -n "${SUDO_USER:-}" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(eval echo ~"$SUDO_USER")
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

# MinIO configuration
MINIO_DATA_PATH="/mnt/minio"
CREDENTIALS_FILE="$ACTUAL_HOME/minio-credentials.txt"
SELECTED_DISK=""

# Get OS disk
get_os_disk() {
    local root_partition=$(df / | tail -1 | awk '{print $1}')
    local os_disk=$(lsblk -no PKNAME "$root_partition" 2>/dev/null | head -1)
    
    if [ -z "$os_disk" ]; then
        os_disk=$(echo "$root_partition" | sed 's/[0-9]*$//' | sed 's|/dev/||')
    fi
    
    echo "/dev/$os_disk"
}

# Detect available disks
detect_available_disks() {
    local os_disk=$(get_os_disk)
    
    # Get Longhorn disks
    local longhorn_disks=$(mount | grep '/mnt/longhorn-disks' | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//' | sort -u)
    
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
        # Use grep to ensure we only get the disk line (type=disk), not partitions or other entries
        local disk_info=$(lsblk -d -n -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | grep -w disk | head -1 | awk '{print $1":"$3":"$4":"$5}')
        if [ -n "$disk_info" ]; then
            all_disks+="$disk_info"$'\n'
        fi
    done
    
    local available_disks=()
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local disk_info="$line"
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        local disk_fstype=$(echo "$disk_info" | cut -d: -f3)
        local disk_mount=$(echo "$disk_info" | cut -d: -f4)
        
        # Skip OS disk (compare base device names)
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
        
        # Skip if already mounted (unless it's the MinIO mount)
        if [[ -n "$disk_mount" ]] && [[ "$disk_mount" != "/mnt/minio" ]]; then
            continue
        fi
        
        # Add /dev/ prefix to disk path (no model info to avoid duplicates)
        available_disks+=("/dev/$disk_name:$disk_size:$disk_fstype")
    done <<< "$all_disks"
    
    echo "${available_disks[@]}"
}

# Format and mount disk
format_and_mount_disk() {
    local disk="$1"
    
    log_info "Formatting and mounting $disk..."
    
    # Unmount if already mounted
    umount "$disk"* 2>/dev/null || true
    
    # Create new partition table and partition
    log_info "Creating partition on $disk..."
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart primary ext4 0% 100%
    sleep 2
    
    # Determine partition name
    local partition
    if [[ "$disk" =~ nvme ]]; then
        partition="${disk}p1"
    else
        partition="${disk}1"
    fi
    
    # Format partition
    log_info "Formatting $partition..."
    mkfs.ext4 -F "$partition"
    
    # Create mount point
    mkdir -p "$MINIO_DATA_PATH"
    
    # Mount partition
    log_info "Mounting $partition to $MINIO_DATA_PATH..."
    mount "$partition" "$MINIO_DATA_PATH"
    
    # Add to fstab for persistence
    local uuid=$(blkid -s UUID -o value "$partition")
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid $MINIO_DATA_PATH ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    log_success "Disk mounted at $MINIO_DATA_PATH"
}

# Generate MinIO credentials
get_minio_credentials() {
    log_info "Configuring MinIO credentials..."
    
    # Generate unique credentials for this MinIO instance
    MINIO_ROOT_USER="admin"
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    
    log_success "Generated MinIO credentials for this node"
    log_info "Each MinIO instance has independent credentials (like any other service)"
    
    # Get Tailscale IP (100.x.x.x range)
    local node_ip=$(ip addr show tailscale0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -z "$node_ip" ]; then
        # Fallback to first IP if Tailscale not found
        node_ip=$(hostname -I | awk '{print $1}')
    fi
    
    # Save to local file
    cat > "$CREDENTIALS_FILE" <<EOF
MinIO Credentials
=================

Node: $(hostname)
Endpoint: http://${node_ip}:9000
Console: http://${node_ip}:9001

Admin Credentials (unique to this node):
  Username: $MINIO_ROOT_USER
  Password: $MINIO_ROOT_PASSWORD

Generated: $(date)

IMPORTANT: Each node has its own unique credentials.
MinIO runs as a systemd service (like PostgreSQL, Redis, etc.).
EOF
    
    # Fix ownership
    if [ "$ACTUAL_USER" != "root" ] && [ "$(whoami)" = "root" ]; then
        chown "$ACTUAL_USER:$ACTUAL_USER" "$CREDENTIALS_FILE"
    fi
    
    log_success "Credentials saved to: $CREDENTIALS_FILE"
    
    # Display credentials in terminal
    echo
    log_info "MinIO Access Credentials:"
    echo "  Username: $MINIO_ROOT_USER"
    echo "  Password: $MINIO_ROOT_PASSWORD"
    echo "  Endpoint: http://${node_ip}:9000"
    echo "  Console:  http://${node_ip}:9001"
    echo
}

# Install MinIO as systemd service
install_minio_service() {
    log_info "Installing MinIO as systemd service..."
    
    # Download MinIO binary
    log_info "Downloading MinIO binary..."
    wget -q https://dl.min.io/server/minio/release/linux-amd64/minio -O /usr/local/bin/minio
    chmod +x /usr/local/bin/minio
    
    # Create minio user
    if ! id -u minio &>/dev/null; then
        useradd -r -s /sbin/nologin minio
    fi
    
    # Set ownership
    chown -R minio:minio "$MINIO_DATA_PATH"
    
    # Create systemd service
    cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs/minio/linux/index.html
After=network.target

[Service]
Type=simple
User=minio
Group=minio
Environment="MINIO_ROOT_USER=${MINIO_ROOT_USER}"
Environment="MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
ExecStart=/usr/local/bin/minio server ${MINIO_DATA_PATH} --console-address ":9001" --address ":9000"
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    # Start service
    systemctl daemon-reload
    systemctl enable minio
    systemctl start minio
    
    # Wait for startup
    log_info "Waiting for MinIO to start..."
    sleep 5
    
    if systemctl is-active --quiet minio; then
        log_success "MinIO service started successfully"
        
        # Get Tailscale IP
        local node_ip=$(ip addr show tailscale0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        if [ -z "$node_ip" ]; then
            node_ip=$(hostname -I | awk '{print $1}')
        fi
        
        log_info "  API: http://${node_ip}:9000"
        log_info "  Console: http://${node_ip}:9001"
    else
        log_error "MinIO service failed to start"
        journalctl -u minio --no-pager -n 20
        return 1
    fi
}

# Main installation
main() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Interactive Installation${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "MinIO provides S3-compatible object storage for the cluster"
    log_info "Each node has independent credentials (like PostgreSQL, Redis)"
    log_info "Useful for backups, model storage, and general S3 storage needs"
    echo
    
    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Ask if user wants MinIO
    read -p "Do you want to install MinIO on this node? [y/N]: " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    # Disk selection
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  MinIO Disk Selection${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_info "Detecting available disks for MinIO..."
    
    echo
    echo "💡 Option 1: Use OS disk (no additional drive needed)"
    echo "  0) Use OS disk - /mnt/minio (no formatting)"
    echo
    echo "💡 Option 2: Use dedicated physical disk"
    log_info "Available physical disks (excluding OS disk and Longhorn disks):"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local available_disks=($(detect_available_disks))
    local disk_count=0
    
    for disk_info in "${available_disks[@]}"; do
        disk_count=$((disk_count + 1))
        local disk_name=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        
        local disk_display=$(basename "$disk_name")
        echo "  $disk_count) $disk_display ($disk_size)"
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_info "Your choice:"
    echo "  • Enter 0 for OS disk (no formatting)"
    echo "  • Enter 1,2,3... for specific physical disk (will be formatted)"
    echo
    
    read -p "Your choice: " choice
    echo
    
    if [ "$choice" = "0" ]; then
        log_info "Using OS disk at /mnt/minio"
        mkdir -p "$MINIO_DATA_PATH"
        SELECTED_DISK="OS"
    elif [ "$choice" -ge 1 ] && [ "$choice" -le "$disk_count" ]; then
        local selected_index=$((choice - 1))
        local disk_info="${available_disks[$selected_index]}"
        SELECTED_DISK=$(echo "$disk_info" | cut -d: -f1)
        local disk_size=$(echo "$disk_info" | cut -d: -f2)
        
        log_info "Selected disk: $SELECTED_DISK ($disk_size)"
        echo
        log_warn "⚠️  WARNING: This disk will be FORMATTED (all data will be lost)"
        echo
        read -p "Continue with formatting? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        
        format_and_mount_disk "$SELECTED_DISK"
    else
        log_error "Invalid choice"
        exit 1
    fi
    
    # Generate credentials
    get_minio_credentials
    
    # Install MinIO
    install_minio_service
    
    echo
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  MinIO Installation Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    log_success "MinIO is running and ready to serve S3 storage"
    echo
    log_info "Credentials saved to: $CREDENTIALS_FILE"
    echo
}

main "$@"
