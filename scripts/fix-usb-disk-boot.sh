#!/bin/bash

###############################################################################
# Fix USB Disk Boot Order for MyNodeOne
# 
# Problem: K3s may start before external USB disks are mounted
# Solution: Create systemd override to wait for disk mounts
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Fixing USB Disk Boot Order for MyNodeOne${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

echo -e "${YELLOW}Current Issue:${NC}"
echo "  K3s may start before USB disks are mounted"
echo "  This causes Longhorn to fail on boot"
echo
echo -e "${GREEN}Solution:${NC}"
echo "  Create systemd override to make K3s wait for disk mounts"
echo

# Get the mount units for Longhorn disks
DISK_MOUNTS=$(systemctl list-units --type=mount | grep "mnt-longhorn-disks" | awk '{print $1}')

if [ -z "$DISK_MOUNTS" ]; then
    echo -e "${YELLOW}Warning: No Longhorn disk mounts found${NC}"
    echo "Looking for mounts manually..."
    
    # Check fstab
    if grep -q "longhorn-disks" /etc/fstab; then
        echo -e "${GREEN}Found Longhorn disks in /etc/fstab${NC}"
        grep "longhorn-disks" /etc/fstab
        
        # Get mount points
        MOUNT_POINTS=$(grep "longhorn-disks" /etc/fstab | awk '{print $2}')
        echo
        echo "Mount points:"
        echo "$MOUNT_POINTS"
        
        # Convert to systemd unit names
        DISK_MOUNTS=""
        for mount in $MOUNT_POINTS; do
            # Convert /mnt/longhorn-disks/disk-sda to mnt-longhorn\x2ddisks-disk\x2dsda.mount
            unit=$(systemd-escape --path --suffix=mount "$mount")
            DISK_MOUNTS="$DISK_MOUNTS $unit"
        done
    else
        echo -e "${RED}Error: No Longhorn disks configured${NC}"
        exit 1
    fi
fi

echo
echo -e "${BLUE}Disk mount units:${NC}"
for mount in $DISK_MOUNTS; do
    echo "  - $mount"
done
echo

# Create K3s service override directory
mkdir -p /etc/systemd/system/k3s.service.d

# Create the override configuration
echo -e "${BLUE}Creating K3s service override...${NC}"
cat > /etc/systemd/system/k3s.service.d/wait-for-disks.conf <<EOF
[Unit]
# Wait for Longhorn disks to be mounted before starting K3s
# This prevents Longhorn from failing when disks aren't ready
After=local-fs.target remote-fs.target
$(for mount in $DISK_MOUNTS; do echo "After=$mount"; done)
$(for mount in $DISK_MOUNTS; do echo "Requires=$mount"; done)

# Also wait for network (for Tailscale)
After=network-online.target
Wants=network-online.target

[Service]
# Give services time to stabilize
ExecStartPre=/bin/sleep 5
EOF

echo -e "${GREEN}✓ Override created: /etc/systemd/system/k3s.service.d/wait-for-disks.conf${NC}"
echo

# Show the configuration
echo -e "${BLUE}Configuration:${NC}"
cat /etc/systemd/system/k3s.service.d/wait-for-disks.conf
echo

# Reload systemd
echo -e "${BLUE}Reloading systemd...${NC}"
systemctl daemon-reload
echo -e "${GREEN}✓ Systemd reloaded${NC}"
echo

# Verify the configuration
echo -e "${BLUE}Verifying K3s dependencies:${NC}"
echo
systemctl show k3s | grep -E "After|Requires" | grep -E "(longhorn|mount)"
echo

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Boot Order Fixed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${BLUE}What Changed:${NC}"
echo "  • K3s now waits for disk mounts before starting"
echo "  • K3s waits for network (Tailscale) before starting"
echo "  • 5-second delay added for stability"
echo
echo -e "${BLUE}Testing:${NC}"
echo "  1. Test the fix: sudo reboot"
echo "  2. After reboot, check: sudo systemctl status k3s"
echo "  3. Verify disks: df -h | grep longhorn"
echo "  4. Check cluster: sudo kubectl get nodes"
echo
echo -e "${YELLOW}Rollback (if needed):${NC}"
echo "  sudo rm /etc/systemd/system/k3s.service.d/wait-for-disks.conf"
echo "  sudo systemctl daemon-reload"
echo

echo -e "${GREEN}Safe to reboot now! Your cluster will start automatically.${NC}"
