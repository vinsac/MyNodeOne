#!/bin/bash

###############################################################################
# Unregister VPS Node from MyNodeOne Cluster
#
# This script removes a VPS edge node from all cluster registries:
# - domain-registry domains.json (VPS node list)
# - domain-registry routing.json (each route's vps_nodes)
# - sync-controller-registry (sync targets)
#
# The writes are in multi-domain-registry.sh purge-vps, on this machine or over SSH on
# the control plane. A failed read changes nothing and exits non-zero.
#
# Usage: ./scripts/nodes/unregister-vps.sh [vps-tailscale-ip]
#
# Examples:
#   ./scripts/nodes/unregister-vps.sh 100.65.241.25
#   ./scripts/nodes/unregister-vps.sh  # Will auto-detect if run on VPS
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🗑️  Unregister VPS Node from Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Determine VPS IP
if [ $# -eq 1 ]; then
    VPS_IP="$1"
    log_info "Unregistering VPS: $VPS_IP (from argument)"
else
    # Try to auto-detect if run on VPS
    VPS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$VPS_IP" ]; then
        log_info "Unregistering VPS: $VPS_IP (auto-detected)"
    else
        log_error "Could not determine VPS IP"
        echo ""
        echo "Usage: $0 <vps-tailscale-ip>"
        echo "Example: $0 100.65.241.25"
        exit 1
    fi
fi

# Validate IP format
if ! [[ "$VPS_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "Invalid IP address format: $VPS_IP"
    exit 1
fi

echo ""
log_warn "This will remove VPS $VPS_IP from all cluster registries."
echo ""
read -p "Continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Check if we can access kubectl (are we on control plane or management laptop?)
if kubectl version --client &>/dev/null && kubectl cluster-info &>/dev/null; then
    # We have direct kubectl access
    log_info "Using direct kubectl access..."

    if ! bash "$SCRIPT_DIR/../domains/multi-domain-registry.sh" purge-vps "$VPS_IP"; then
        log_error "VPS $VPS_IP was not fully removed. It is safe to run this again"
        exit 1
    fi
else
    # Need to use remote kubectl via SSH
    if [ -z "${CONTROL_PLANE_IP:-}" ]; then
        log_error "CONTROL_PLANE_IP not set and no direct kubectl access"
        echo ""
        echo "Either:"
        echo "  1. Run this script on control plane or management laptop (with kubectl access)"
        echo "  2. Set CONTROL_PLANE_IP in ~/.mynodeone/config.env"
        exit 1
    fi

    CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-$(whoami)}"

    log_info "Using remote kubectl via SSH to $CONTROL_PLANE_IP..."

    # -t because the control plane's sudoers rule only covers kubectl, so sudo may ask
    # for a password here. VPS_IP was checked above, so it is safe in a remote command.
    # A checkout from before purge-vps prints its usage and exits 1, which lands below.
    if ! ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd ~/MyNodeOne && sudo ./scripts/domains/multi-domain-registry.sh purge-vps $VPS_IP"; then
        log_error "Could not unregister VPS $VPS_IP via SSH"
        echo ""
        echo "Update the control plane's checkout if it is older than this one, then run:"
        echo "  ssh $CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP"
        echo "  cd ~/MyNodeOne"
        echo "  sudo ./scripts/domains/multi-domain-registry.sh purge-vps $VPS_IP"
        exit 1
    fi
    log_success "Removed from registries via control plane"
fi

# Delete local cache if exists
if [ -f "$HOME/.mynodeone/node-registry.json" ]; then
    log_info "Cleaning up local cache..."
    rm -f "$HOME/.mynodeone/node-registry.json"
    log_success "Local cache cleaned"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "VPS $VPS_IP has been unregistered"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Removed from:"
echo "   • domain-registry (VPS node list)"
echo "   • sync-controller-registry (sync targets)"
echo "   • routing configurations (service routes)"
echo ""
echo "📋 Next Steps:"
echo "   • If VPS is being decommissioned, you can now safely shut it down"
echo "   • If reinstalling, the VPS can be registered again with fresh IP"
echo "   • Routes pointing to this VPS will no longer be synced"
echo ""
