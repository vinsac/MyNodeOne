#!/bin/bash

###############################################################################
# Fix Duplicate DNS Entries
# 
# Removes old DNS entries and rebuilds using enterprise registry
# Fixes the issue where demo-chat-app and demoapp both exist
###############################################################################

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔧 Fix Duplicate DNS Entries"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "This script will:"
echo "  1. Remove old DNS entries (demo-chat-app, demoapp)"
echo "  2. Rebuild using enterprise registry"
echo "  3. Result: Single consistent entry (demo.minicloud.local)"
echo ""

# Load cluster domain
CLUSTER_DOMAIN="mycloud"
if [ -f "$HOME/.mynodeone/config.env" ]; then
    source "$HOME/.mynodeone/config.env"
fi

log_info "Checking current DNS entries..."
echo ""
echo "Current entries in /etc/hosts:"
grep -E "(demo-chat-app|demoapp|demo)\." /etc/hosts 2>/dev/null || echo "  (none found)"
echo ""

read -p "Continue with cleanup? [y/N]: " confirm
if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Backup hosts file
log_info "Backing up /etc/hosts..."
sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)
log_success "Backup created"

# Remove old MyNodeOne Apps entries
log_info "Removing old DNS entries..."
sudo sed -i '/# MyNodeOne Apps/,/# End MyNodeOne Apps/d' /etc/hosts 2>/dev/null || true
log_success "Old entries removed"

# Check if enterprise registry exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/lib/service-registry.sh" ]; then
    log_warn "Enterprise registry not found!"
    echo ""
    echo "To set up enterprise registry:"
    echo "  sudo ./scripts/setup-enterprise-registry.sh"
    exit 1
fi

# Sync service registry
log_info "Syncing service registry..."
if bash "$SCRIPT_DIR/lib/service-registry.sh" sync 2>/dev/null; then
    log_success "Service registry synced"
else
    log_warn "Could not sync (this is OK if no apps installed yet)"
fi

# Export and update DNS
log_info "Updating DNS from registry..."
if bash "$SCRIPT_DIR/lib/service-registry.sh" export-dns "${CLUSTER_DOMAIN}.local" 2>/dev/null > /tmp/registry-dns.txt; then
    sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts 2>/dev/null || true
    {
        echo ""
        cat /tmp/registry-dns.txt
        echo ""
    } | sudo tee -a /etc/hosts > /dev/null
    rm -f /tmp/registry-dns.txt
    log_success "DNS updated from registry"
else
    log_warn "Could not export DNS"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Cleanup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "New DNS entries:"
echo ""
grep "# MyNodeOne Services" -A 20 /etc/hosts | grep -E "\." | head -n 10

echo ""
log_info "If you had demo app, it should now be at:"
echo "  http://demo.${CLUSTER_DOMAIN}.local"
echo ""

log_info "If you see duplicate entries for the same app, you may need to:"
echo "  1. Delete the demo app: kubectl delete namespace demo-apps"
echo "  2. Redeploy: sudo ./scripts/deploy-demo-app.sh"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
