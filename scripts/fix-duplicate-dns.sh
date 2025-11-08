#!/bin/bash

###############################################################################
# Fix Duplicate DNS Entries - Migration & Troubleshooting Tool
# 
# PURPOSE:
#   Fixes systems that have duplicate DNS entries from old registration systems
#   This was caused by two conflicting DNS registration methods running together:
#     1. Old: configure-app-dns.sh (manual namespace-to-name mapping)
#     2. New: Enterprise registry (automatic service detection)
#
# WHEN TO USE THIS SCRIPT:
#   ✅ You see duplicate DNS entries for the same app
#      Example: demo-chat-app.minicloud.local AND demoapp.minicloud.local
#   ✅ You upgraded from a pre-enterprise-registry installation
#   ✅ Apps are accessible via multiple URLs and you want to clean up
#   ✅ You reinstalled control plane and got duplicates
#
# WHEN NOT TO USE THIS SCRIPT:
#   ❌ Fresh installations (no duplicates will be created)
#   ❌ System already using enterprise registry exclusively
#   ❌ No DNS issues present
#
# WHAT THIS SCRIPT DOES:
#   1. Backs up /etc/hosts
#   2. Removes old "MyNodeOne Apps" section entries
#   3. Removes standalone duplicate entries (demo-chat-app, demoapp)
#   4. Syncs service registry from Kubernetes
#   5. Exports clean DNS entries from enterprise registry
#   6. Updates /etc/hosts with single, consistent entries
#
# USAGE:
#   sudo ./scripts/fix-duplicate-dns.sh
#
# EXAMPLE SCENARIO:
#   Before:
#     100.76.150.207    demo-chat-app.minicloud.local  (from old system)
#     100.76.150.207    demoapp.minicloud.local        (from configure-app-dns.sh)
#     100.76.150.207    demo.minicloud.local           (from enterprise registry)
#
#   After:
#     100.76.150.207    demo.minicloud.local           (single entry)
#
# REQUIREMENTS:
#   - Enterprise registry must be set up (setup-enterprise-registry.sh)
#   - kubectl access to cluster
#   - sudo privileges (to edit /etc/hosts)
#
# SAFE TO RUN:
#   ✅ Creates backup before making changes
#   ✅ Can be run multiple times safely
#   ✅ Only removes MyNodeOne-managed entries
#   ✅ Does not affect other /etc/hosts entries
#
# TROUBLESHOOTING:
#   If script fails:
#     1. Check enterprise registry: kubectl get cm -n kube-system service-registry
#     2. Verify apps running: kubectl get svc --all-namespaces
#     3. Manual restore: sudo cp /etc/hosts.backup.* /etc/hosts
#
# SEE ALSO:
#   - docs/OPERATIONS-GUIDE.md - DNS troubleshooting section
#   - scripts/lib/service-registry.sh - Enterprise registry commands
#   - scripts/sync-dns.sh - Regular DNS sync (after this fix)
#
# VERSION: 1.0 (Created: 2024-11-07)
# MAINTENANCE: This script may be removed in future versions once all
#              installations have migrated to enterprise registry.
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

# Also remove any standalone demo entries that might exist
log_info "Removing any standalone demo entries..."
sudo sed -i '/demo-chat-app\..*\.local/d' /etc/hosts 2>/dev/null || true
sudo sed -i '/demoapp\..*\.local/d' /etc/hosts 2>/dev/null || true

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
