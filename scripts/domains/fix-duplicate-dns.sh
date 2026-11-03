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
#      Example: demo-chat-app.mynodeone.local AND demoapp.mynodeone.local
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
#   5. Asks whatever owns /etc/hosts on this host to bring it up to date
#
# Steps 2 and 3 are the only writes this script makes itself, and it makes them on
# purpose. They remove names from retired systems, including under other domains,
# which the regular writers leave alone.
#
# USAGE:
#   sudo ./scripts/domains/fix-duplicate-dns.sh
#
# EXAMPLE SCENARIO:
#   Before:
#     100.76.150.207    demo-chat-app.mynodeone.local  (from old system)
#     100.76.150.207    demoapp.mynodeone.local        (from configure-app-dns.sh)
#     100.76.150.207    demo.mynodeone.local           (from enterprise registry)
#
#   After:
#     100.76.150.207    demo.mynodeone.local           (single entry)
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
#   - docs/guides/OPERATIONS-GUIDE.md - DNS troubleshooting section
#   - scripts/lib/service-registry.sh - Enterprise registry commands
#   - scripts/domains/sync-dns.sh - Regular DNS sync (after this fix)
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
echo "  3. Result: Single consistent entry (demo.mynodeone.local)"
echo ""

# Load cluster domain - handle sudo correctly
ACTUAL_HOME="${HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}"
if [ -z "$CLUSTER_DOMAIN" ] && [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    source "$ACTUAL_HOME/.mynodeone/config.env"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Tests point this at a temp file.
HOSTS_FILE="${MYNODEONE_HOSTS_FILE:-/etc/hosts}"

log_info "Checking current DNS entries..."
echo ""
echo "Current entries in $HOSTS_FILE:"
grep -E "(demo-chat-app|demoapp|demo)\." "$HOSTS_FILE" 2>/dev/null || echo "  (none found)"
echo ""

read -p "Continue with cleanup? [y/N]: " confirm
if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Backup hosts file
log_info "Backing up $HOSTS_FILE..."
sudo cp "$HOSTS_FILE" "$HOSTS_FILE.backup.$(date +%Y%m%d_%H%M%S)"
log_success "Backup created"

# shellcheck source=../lib/hosts-block.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hosts-block.sh"

# Remove old MyNodeOne Apps entries
log_info "Removing old DNS entries..."
if ! hosts_remove_block "$HOSTS_FILE" '# MyNodeOne Apps' '# End MyNodeOne Apps'; then
    log_warn "Could not update $HOSTS_FILE"
    exit 1
fi

# Also remove any standalone demo entries that might exist
log_info "Removing any standalone demo entries..."
HOSTS_FILTERED=$(mktemp)
grep -vE '(demo-chat-app|demoapp)\..*\.local' "$HOSTS_FILE" >"$HOSTS_FILTERED" || true
if ! cmp -s "$HOSTS_FILTERED" "$HOSTS_FILE" && ! hosts_write_in_place "$HOSTS_FILTERED" "$HOSTS_FILE"; then
    rm -f "$HOSTS_FILTERED"
    log_warn "Could not update $HOSTS_FILE"
    exit 1
fi
rm -f "$HOSTS_FILTERED"

log_success "Old entries removed"

# Check if enterprise registry exists
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

if [ ! -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    log_warn "Enterprise registry not found"
    echo ""
    echo "To set up enterprise registry:"
    echo "  sudo $PROJECT_ROOT/scripts/setup/setup-enterprise-registry.sh"
    exit 1
fi

# Sync service registry
log_info "Syncing service registry..."
if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" sync 2>/dev/null; then
    log_success "Service registry synced"
else
    log_warn "Could not sync (this is OK if no apps installed yet)"
fi

# Update DNS through whatever owns /etc/hosts on this machine
log_info "Updating DNS from registry..."
# shellcheck source=../lib/service-registry-lib.sh
source "$PROJECT_ROOT/scripts/lib/service-registry-lib.sh"
DNS_RESULT=$(sr_refresh_hosts)
case "$DNS_RESULT" in
    updated) log_success "DNS updated from registry" ;;
    deferred) log_info "The node agent manages DNS here; it adds new names when the cluster config changes" ;;
    *) log_warn "Could not update DNS from the registry" ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Cleanup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "DNS entries now in $HOSTS_FILE:"
echo ""
grep -E "\.${CLUSTER_DOMAIN}\.local" "$HOSTS_FILE" | head -n 10 || true

echo ""
log_info "If you had demo app, it should now be at:"
echo "  http://demo.${CLUSTER_DOMAIN}.local"
echo ""

log_info "If you see duplicate entries for the same app, you may need to:"
echo "  1. Delete the demo app: kubectl delete namespace demo-apps"
echo "  2. Redeploy: sudo $PROJECT_ROOT/scripts/operations/deploy-demo-app.sh"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
