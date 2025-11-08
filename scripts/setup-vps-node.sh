#!/bin/bash

###############################################################################
# Setup VPS Node for Enterprise Registry
# 
# Auto-registers VPS and configures for automatic sync
# Run this on each VPS edge node
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
echo "  🌍 VPS Node Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Load configuration
if [ ! -f ~/.mynodeone/config.env ]; then
    log_error "Configuration not found!"
    echo "Please run the VPS edge node installation first:"
    echo "  sudo ./scripts/mynodeone"
    echo "  Select option: 3 (VPS Edge Node)"
    exit 1
fi

source ~/.mynodeone/config.env

# Get VPS details
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "")
HOSTNAME=$(hostname)

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    echo "Please ensure Tailscale is installed and running"
    exit 1
fi

log_info "VPS Details:"
echo "  • Tailscale IP: $TAILSCALE_IP"
echo "  • Public IP: $PUBLIC_IP"
echo "  • Hostname: $HOSTNAME"
echo ""

# Check required config
if [ -z "${CONTROL_PLANE_IP:-}" ]; then
    log_error "CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"
    exit 1
fi

if [ -z "${PUBLIC_DOMAIN:-}" ]; then
    log_warn "PUBLIC_DOMAIN not set in ~/.mynodeone/config.env"
    echo ""
    read -p "Enter your public domain (e.g., curiios.com): " user_domain
    
    if [ -n "$user_domain" ]; then
        echo "PUBLIC_DOMAIN=\"$user_domain\"" >> ~/.mynodeone/config.env
        PUBLIC_DOMAIN="$user_domain"
        log_success "Domain configured"
    else
        log_error "Public domain required for VPS nodes"
        exit 1
    fi
fi

echo ""
log_info "Registering with control plane..."
echo ""

# Register this VPS in the multi-domain registry
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"
REGION="${NODE_LOCATION:-unknown}"
PROVIDER="unknown"

# Try to detect provider
if curl -s --max-time 2 http://169.254.169.254/metadata/v1/vendor-data | grep -q "Contabo"; then
    PROVIDER="contabo"
elif curl -s --max-time 2 http://169.254.169.254/metadata/v1/ 2>/dev/null | grep -q "digitalocean"; then
    PROVIDER="digitalocean"
elif curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "ami"; then
    PROVIDER="aws"
fi

log_info "Detected provider: $PROVIDER, region: $REGION"

# Register VPS in multi-domain registry
ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-vps \
    $TAILSCALE_IP $PUBLIC_IP $REGION $PROVIDER" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in multi-domain registry"
else
    log_warn "VPS registration may have failed, continuing..."
fi

# Register VPS in sync controller
ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/sync-controller.sh register vps_nodes \
    $TAILSCALE_IP $HOSTNAME root" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in sync controller"
else
    log_warn "Sync controller registration may have failed, continuing..."
fi

echo ""
log_info "Running initial sync..."
sudo ./scripts/sync-vps-routes.sh

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ VPS Node Configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's configured:"
echo "  • Registered in control plane registry"
echo "  • Auto-sync enabled for new apps"
echo "  • Traefik routes configured"
echo "  • Domain: $PUBLIC_DOMAIN"
echo ""

log_info "This VPS will now automatically:"
echo "  • Receive route updates when apps are installed"
echo "  • Update Traefik configuration"
echo "  • Obtain SSL certificates from Let's Encrypt"
echo ""

log_info "Point your DNS records to this VPS:"
echo "  Type: A"
echo "  Name: * (wildcard) or specific subdomains"
echo "  Value: $PUBLIC_IP"
echo "  TTL: 300"
echo ""

# Run validation tests
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔍 Validating VPS Edge Node Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/validate-installation.sh" ]; then
    if bash "$SCRIPT_DIR/lib/validate-installation.sh" vps-edge; then
        log_success "✅ VPS validation passed!"
    else
        log_warn "⚠️  Some validation tests failed (see above)"
    fi
else
    log_warn "Validation script not found, skipping tests"
fi
echo ""

log_success "VPS node registration complete! 🎉"
echo ""
