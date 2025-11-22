#!/bin/bash

###############################################################################
# Enable Sync Controller as Systemd Service
#
# This script installs and enables the sync controller as a systemd service
# that runs continuously on the control plane.
#
# Features:
# - Watches for ConfigMap changes (immediate sync)
# - Periodic reconciliation every hour (retry offline nodes)
# - Auto-restart on failure
# - Logs to systemd journal
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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)"
   exit 1
fi

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Enable Sync Controller Service"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "Repository root: $REPO_ROOT"
echo ""

# Check if service file exists
SERVICE_FILE="$REPO_ROOT/systemd/mynodeone-sync-controller.service"
if [[ ! -f "$SERVICE_FILE" ]]; then
    log_error "Service file not found: $SERVICE_FILE"
    exit 1
fi

log_success "Service file found"

# Update service file with actual paths
log_info "Updating service file with actual paths..."
TEMP_SERVICE="/tmp/mynodeone-sync-controller.service"
sed "s|/root/MyNodeOne|$REPO_ROOT|g" "$SERVICE_FILE" > "$TEMP_SERVICE"

# Detect actual user's home and kubeconfig
ACTUAL_USER="${SUDO_USER:-root}"
if [[ "$ACTUAL_USER" != "root" ]]; then
    ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
    KUBECONFIG_PATH="$ACTUAL_HOME/.kube/config"
else
    KUBECONFIG_PATH="/root/.kube/config"
fi

# Update kubeconfig path in service
sed -i "s|KUBECONFIG=/root/.kube/config|KUBECONFIG=$KUBECONFIG_PATH|g" "$TEMP_SERVICE"

log_success "Paths updated"

# Copy service file to systemd
log_info "Installing service file..."
cp "$TEMP_SERVICE" /etc/systemd/system/mynodeone-sync-controller.service
chmod 644 /etc/systemd/system/mynodeone-sync-controller.service

log_success "Service file installed"

# Reload systemd
log_info "Reloading systemd daemon..."
systemctl daemon-reload

log_success "Systemd reloaded"

# Check if service is already running
if systemctl is-active --quiet mynodeone-sync-controller; then
    log_info "Service is already running. Restarting..."
    systemctl restart mynodeone-sync-controller
    log_success "Service restarted"
else
    log_info "Starting service..."
    systemctl start mynodeone-sync-controller
    log_success "Service started"
fi

# Enable service to start on boot
log_info "Enabling service to start on boot..."
systemctl enable mynodeone-sync-controller

log_success "Service enabled"

# Wait a moment for service to start
sleep 2

# Check service status
echo ""
log_info "Service Status:"
echo ""
systemctl status mynodeone-sync-controller --no-pager -l || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Sync Controller Service Enabled!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's running:"
echo "  • Watches for ConfigMap changes (immediate sync)"
echo "  • Reconciles every hour (retries offline nodes)"
echo "  • Auto-restarts on failure"
echo "  • Logs to systemd journal"
echo ""

log_info "Useful commands:"
echo "  • View logs:        sudo journalctl -u mynodeone-sync-controller -f"
echo "  • Check status:     sudo systemctl status mynodeone-sync-controller"
echo "  • Restart service:  sudo systemctl restart mynodeone-sync-controller"
echo "  • Stop service:     sudo systemctl stop mynodeone-sync-controller"
echo "  • Disable service:  sudo systemctl disable mynodeone-sync-controller"
echo ""

log_info "The service will now:"
echo "  1. Sync immediately when apps are installed/made public"
echo "  2. Retry offline nodes every hour"
echo "  3. Ensure all nodes stay in sync"
echo ""

log_success "Setup complete! 🎉"
echo ""
