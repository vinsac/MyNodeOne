#!/bin/bash

###############################################################################
# Cluster Validation Script
# Run this anytime to verify your cluster health
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔍 MyNodeOne Cluster Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Cluster Domain: $CLUSTER_DOMAIN"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Please run this on the control plane."
    exit 1
fi

# Source validation library
if [ ! -f "$SCRIPT_DIR/lib/service-validation.sh" ]; then
    echo "❌ Validation library not found at: $SCRIPT_DIR/lib/service-validation.sh"
    exit 1
fi

source "$SCRIPT_DIR/lib/service-validation.sh"

# Run comprehensive validation
if verify_all_core_services "$CLUSTER_DOMAIN"; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    log_success "🎉 CLUSTER IS HEALTHY!"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "All core services are:"
    echo "  ✓ Pods running"
    echo "  ✓ Services exist with LoadBalancer IPs"
    echo "  ✓ DNS entries configured in /etc/hosts"
    echo "  ✓ DNS entries configured in dnsmasq"
    echo "  ✓ DNS resolution working"
    echo ""
    exit 0
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "❌ CLUSTER HAS ISSUES"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Review the errors above to identify the problems."
    echo ""
    echo "Common fixes:"
    echo "  • Restart failed pods: kubectl delete pod <pod-name> -n <namespace>"
    echo "  • Re-run DNS setup: sudo $SCRIPT_DIR/setup-local-dns.sh"
    echo "  • Check MetalLB: kubectl get ipaddresspool -n metallb-system"
    echo "  • View logs: kubectl logs -n <namespace> <pod-name>"
    echo ""
    exit 1
fi
