#!/bin/bash

###############################################################################
# Setup SSH Access from Control Plane to Management Laptop
# 
# This script automates SSH key generation and exchange between control plane
# and management laptop, enabling passwordless DNS sync.
#
# Run this FROM THE LAPTOP after:
# 1. Tailscale is installed on laptop
# 2. You have SSH access to control plane
#
# Usage:
#   ./setup-management-laptop-ssh.sh <control-plane-user> <control-plane-ip> <laptop-user> <laptop-ip>
#
# Example:
#   ./setup-management-laptop-ssh.sh vinaysachdeva 100.101.4.2 vinay 100.101.4.3
###############################################################################

set -euo pipefail

# Colors
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

# Check arguments
if [ $# -ne 4 ]; then
    echo "Usage: $0 <control-plane-user> <control-plane-ip> <laptop-user> <laptop-ip>"
    echo ""
    echo "Example:"
    echo "  $0 vinaysachdeva 100.101.4.2 vinay 100.101.4.3"
    echo ""
    echo "Get IPs with: tailscale ip -4"
    exit 1
fi

CONTROL_PLANE_USER="$1"
CONTROL_PLANE_IP="$2"
LAPTOP_USER="$3"
LAPTOP_IP="$4"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 SSH Setup: Control Plane → Management Laptop"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Control Plane: $CONTROL_PLANE_USER@$CONTROL_PLANE_IP"
echo "Laptop:        $LAPTOP_USER@$LAPTOP_IP"
echo ""

# Source SSH utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/ssh-utils.sh" ]; then
    source "$SCRIPT_DIR/lib/ssh-utils.sh"
else
    log_error "Cannot find lib/ssh-utils.sh"
    exit 1
fi

# Step 1: Setup SSH ControlMaster to reduce password prompts
log_info "Step 1: Setting up SSH connection to control plane..."
if ! setup_ssh_control_master "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP"; then
    log_error "Failed to connect to control plane"
    exit 1
fi

# Step 2: Setup reverse SSH (control plane → laptop)
log_info "Step 2: Setting up SSH keys on control plane..."
if ! setup_management_laptop_ssh "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP" "$LAPTOP_USER" "$LAPTOP_IP"; then
    log_error "Failed to setup SSH keys"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "SSH Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "What was configured:"
echo "  ✅ Generated mynodeone SSH keys on control plane (if needed)"
echo "  ✅ Copied root's SSH key to laptop (for sync service)"
echo "  ✅ Copied user's SSH key to laptop (for manual operations)"
echo "  ✅ Verified SSH access works"
echo ""
echo "Next steps:"
echo "  1. Run management laptop installation:"
echo "     cd ~/MyNodeOne && sudo ./scripts/mynodeone"
echo "     Select Option 4: Management Workstation"
echo ""
