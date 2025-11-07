#!/bin/bash

###############################################################################
# Setup Management Node for Enterprise Registry
# 
# Auto-registers management laptop and configures for automatic sync
# Run this on each management laptop/desktop
###############################################################################

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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  💻 Management Laptop Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Load configuration
if [ ! -f ~/.mynodeone/config.env ]; then
    log_error "Configuration not found!"
    echo "Please run the management laptop setup first:"
    echo "  sudo ./scripts/mynodeone"
    echo "  Select option: 4 (Management Workstation)"
    exit 1
fi

source ~/.mynodeone/config.env

# Get laptop details
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
HOSTNAME=$(hostname)
USERNAME=$(whoami)

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    echo "Please ensure Tailscale is installed and running"
    exit 1
fi

log_info "Laptop Details:"
echo "  • Tailscale IP: $TAILSCALE_IP"
echo "  • Hostname: $HOSTNAME"
echo "  • Username: $USERNAME"
echo ""

# Check required config
if [ -z "${CONTROL_PLANE_IP:-}" ]; then
    log_error "CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"
    exit 1
fi

echo ""
log_info "Registering with control plane..."
echo ""

# Register this laptop in sync controller
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/sync-controller.sh register management_laptops \
    $TAILSCALE_IP $HOSTNAME $USERNAME" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "Laptop registered in sync controller"
else
    log_warn "Registration may have failed, continuing..."
fi

echo ""
log_info "Running initial sync..."
sudo ./scripts/sync-dns.sh

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Management Laptop Configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's configured:"
echo "  • Registered in control plane registry"
echo "  • Auto-sync enabled for new apps"
echo "  • DNS entries configured in /etc/hosts"
echo ""

log_info "This laptop will now automatically:"
echo "  • Receive DNS updates when apps are installed"
echo "  • Access services via .local domains"
echo "  • Stay in sync with cluster state"
echo ""

# Show current services
SERVICE_COUNT=$(grep "mycloud.local" /etc/hosts 2>/dev/null | wc -l || echo "0")
log_info "Currently configured services: $SERVICE_COUNT"
echo ""

if [ $SERVICE_COUNT -gt 0 ]; then
    echo "Available services:"
    grep "mycloud.local" /etc/hosts | awk '{print "  • http://" $2}' | sort
    echo ""
fi

log_success "Management laptop registration complete! 🎉"
echo ""
