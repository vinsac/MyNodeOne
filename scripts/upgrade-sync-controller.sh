#!/bin/bash

###############################################################################
# Upgrade Sync Controller to Latest Version
#
# This script safely upgrades the sync controller on an existing installation
# without requiring reinstallation.
#
# Run on: Control Plane
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

# Check if running on control plane
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. This script must run on the control plane."
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Sync Controller Upgrade"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_info "Repository: $REPO_ROOT"
echo ""

# Check current branch and version
cd "$REPO_ROOT"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
CURRENT_COMMIT=$(git rev-parse --short HEAD)

log_info "Current branch: $CURRENT_BRANCH"
log_info "Current commit: $CURRENT_COMMIT"
echo ""

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    log_warn "You have uncommitted changes in your repository"
    echo ""
    git status --short
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Upgrade cancelled"
        exit 0
    fi
fi

# Pull latest changes
log_info "Pulling latest changes from origin/$CURRENT_BRANCH..."
if git pull origin "$CURRENT_BRANCH"; then
    NEW_COMMIT=$(git rev-parse --short HEAD)
    if [[ "$CURRENT_COMMIT" == "$NEW_COMMIT" ]]; then
        log_success "Already up to date!"
    else
        log_success "Updated from $CURRENT_COMMIT to $NEW_COMMIT"
    fi
else
    log_error "Failed to pull latest changes"
    exit 1
fi
echo ""

# Check if sync-controller service exists
log_info "Checking sync-controller service..."
if systemctl list-unit-files | grep -q mynodeone-sync-controller.service; then
    SERVICE_EXISTS=true
    log_success "Service exists"
    
    # Check if it's running
    if systemctl is-active --quiet mynodeone-sync-controller; then
        SERVICE_RUNNING=true
        log_info "Service is currently running"
    else
        SERVICE_RUNNING=false
        log_warn "Service exists but not running"
    fi
else
    SERVICE_EXISTS=false
    log_warn "Service not installed"
fi
echo ""

# Upgrade service
if [[ "$SERVICE_EXISTS" == "true" ]]; then
    log_info "Upgrading sync-controller service..."
    
    # Reinstall service with new code
    if sudo "$REPO_ROOT/scripts/enable-sync-controller-service.sh"; then
        log_success "Service upgraded successfully"
    else
        log_error "Failed to upgrade service"
        exit 1
    fi
else
    log_info "Installing sync-controller service for the first time..."
    
    if sudo "$REPO_ROOT/scripts/enable-sync-controller-service.sh"; then
        log_success "Service installed successfully"
    else
        log_error "Failed to install service"
        exit 1
    fi
fi
echo ""

# Verify service is running
log_info "Verifying service status..."
sleep 2

if systemctl is-active --quiet mynodeone-sync-controller; then
    log_success "Service is running"
else
    log_error "Service is not running"
    echo ""
    log_info "Checking service logs..."
    sudo journalctl -u mynodeone-sync-controller -n 20 --no-pager
    exit 1
fi
echo ""

# Run health check
log_info "Running health check..."
if sudo "$REPO_ROOT/scripts/lib/sync-controller.sh" health; then
    echo ""
    log_success "Health check passed"
else
    log_warn "Health check reported issues (check output above)"
fi
echo ""

# Test manual sync
log_info "Testing manual sync..."
if sudo "$REPO_ROOT/scripts/lib/sync-controller.sh" push; then
    echo ""
    log_success "Manual sync successful"
else
    log_error "Manual sync failed"
    exit 1
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Upgrade Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "Sync controller upgraded successfully"
echo ""

log_info "What's new:"
echo "  • Reachability check before sync (prevents hanging)"
echo "  • Periodic reconciliation (retries offline nodes every hour)"
echo "  • Daemon mode (watch + reconcile combined)"
echo "  • Enhanced logging and status tracking"
echo ""

log_info "Monitoring commands:"
echo "  • View logs:     sudo journalctl -u mynodeone-sync-controller -f"
echo "  • Check status:  sudo systemctl status mynodeone-sync-controller"
echo "  • Health check:  sudo ./scripts/lib/sync-controller.sh health"
echo "  • Manual sync:   sudo ./scripts/lib/sync-controller.sh push"
echo ""

log_info "Next steps:"
echo "  1. Monitor logs for the next hour"
echo "  2. Verify auto-sync works when you install a new app"
echo "  3. Test offline laptop scenario (disconnect, install app, reconnect)"
echo ""

log_success "Upgrade complete! 🎉"
echo ""
