#!/bin/bash

###############################################################################
# Enable Periodic Local DNS Sync on Control Plane
#
# Creates a systemd timer that syncs /etc/hosts with service registry
# every 1 minute to keep local DNS entries up-to-date.
#
# This ensures control plane can access services via .local domains even
# without other devices connected.
#
# USAGE:
#   sudo ./scripts/setup/enable-local-dns-sync.sh
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

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# Get project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Enable Periodic Local DNS Sync"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if sync-dns.sh exists
if [ ! -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
    log_error "sync-dns.sh not found at $PROJECT_ROOT/scripts/domains/sync-dns.sh"
    exit 1
fi

log_info "Creating systemd service..."

# Create systemd service unit
cat > /etc/systemd/system/mynodeone-local-dns-sync.service << EOF
[Unit]
Description=MyNodeOne Local DNS Sync
Documentation=https://github.com/vinsac/MyNodeOne
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$PROJECT_ROOT/scripts/domains/sync-dns.sh --quiet
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mynodeone-dns-sync

# Restart on failure
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF

log_success "Service unit created"

log_info "Creating systemd timer..."

# Create systemd timer
cat > /etc/systemd/system/mynodeone-local-dns-sync.timer << 'EOF'
[Unit]
Description=Sync local DNS every 1 minute
Documentation=https://github.com/vinsac/MyNodeOne
Requires=mynodeone-local-dns-sync.service

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

log_success "Timer unit created"

log_info "Enabling and starting timer..."

# Reload systemd
systemctl daemon-reload

# Enable timer (auto-start on boot)
systemctl enable mynodeone-local-dns-sync.timer

# Start timer now
systemctl start mynodeone-local-dns-sync.timer

# Verify timer is active
if systemctl is-active --quiet mynodeone-local-dns-sync.timer; then
    log_success "Timer is active"
else
    log_error "Timer failed to start"
    systemctl status mynodeone-local-dns-sync.timer
    exit 1
fi

echo ""
log_success "Periodic local DNS sync enabled"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Sync Interval: Every 1 minute"
echo "Service:       mynodeone-local-dns-sync.service"
echo "Timer:         mynodeone-local-dns-sync.timer"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Management Commands"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Status:"
echo "  systemctl status mynodeone-local-dns-sync.timer"
echo "  systemctl list-timers mynodeone-local-dns-sync.timer"
echo ""
echo "View Logs:"
echo "  journalctl -u mynodeone-local-dns-sync.service -f"
echo ""
echo "Disable:"
echo "  sudo systemctl stop mynodeone-local-dns-sync.timer"
echo "  sudo systemctl disable mynodeone-local-dns-sync.timer"
echo ""
echo "Re-enable:"
echo "  sudo systemctl enable mynodeone-local-dns-sync.timer"
echo "  sudo systemctl start mynodeone-local-dns-sync.timer"
echo ""
echo "💡 Local DNS entries will now auto-update every minute"
echo ""
