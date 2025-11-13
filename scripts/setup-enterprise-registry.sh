#!/bin/bash

###############################################################################
# Setup Enterprise Registry on Existing Cluster
# 
# One-command setup for existing MyNodeOne clusters
# Migrates from legacy system to enterprise event-driven architecture
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀 Enterprise Registry Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This will set up the enterprise-grade service registry system on your existing cluster."
echo ""

# Check if kubectl works
if ! kubectl get nodes &>/dev/null; then
    echo "Error: Cannot access Kubernetes cluster."
    echo "Make sure kubectl is configured and you're on the control plane."
    exit 1
fi

log_success "Cluster access confirmed"
echo ""

# Step 1: Initialize registries
log_info "Step 1/5: Initializing service registries..."
bash "$SCRIPT_DIR/lib/service-registry.sh" init
bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" init
log_success "Registries initialized"
echo ""

# Step 2: Sync existing services
log_info "Step 2/5: Discovering existing services..."
bash "$SCRIPT_DIR/lib/service-registry.sh" sync
SERVICE_COUNT=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | jq 'length' 2>/dev/null || echo "0")
log_success "Found $SERVICE_COUNT existing services"
echo ""

# Step 3: Install sync controller
log_info "Step 3/5: Installing sync controller service..."

if [ -f /etc/systemd/system/mynodeone-sync-controller.service ]; then
    log_warn "Sync controller already installed, restarting..."
    sudo systemctl restart mynodeone-sync-controller
else
    # Update service file with correct path
    sed "s|/path/to/MyNodeOne|$PROJECT_ROOT|g" \
        "$PROJECT_ROOT/systemd/mynodeone-sync-controller.service" | \
        sudo tee /etc/systemd/system/mynodeone-sync-controller.service > /dev/null
    
    sudo systemctl daemon-reload
    sudo systemctl enable mynodeone-sync-controller
    sudo systemctl start mynodeone-sync-controller
    
    log_success "Sync controller installed and started"
fi

# Check if service is running
sleep 2
if sudo systemctl is-active --quiet mynodeone-sync-controller; then
    log_success "Sync controller is running"
else
    log_warn "Sync controller failed to start, check logs with: sudo journalctl -u mynodeone-sync-controller"
fi
echo ""

# Step 4: Setup configuration
log_info "Step 4/5: Configuration setup..."
echo ""

# Load existing config if present
if [ -f ~/.mynodeone/config.env ]; then
    source ~/.mynodeone/config.env
    log_info "Loaded existing configuration"
else
    log_warn "No existing configuration found"
fi

# Ask for public domain if not set
if [ -z "${PUBLIC_DOMAIN:-}" ]; then
    echo "Do you have a public domain for accessing services from the internet?"
    read -p "Enter domain (or press Enter to skip): " user_domain
    
    if [ -n "$user_domain" ]; then
        echo "PUBLIC_DOMAIN=\"$user_domain\"" >> ~/.mynodeone/config.env
        bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" register-domain "$user_domain" "Primary domain"
        log_success "Domain registered: $user_domain"
    else
        log_info "Skipping domain configuration (local access only)"
    fi
else
    log_info "Using existing domain: $PUBLIC_DOMAIN"
    bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" register-domain "$PUBLIC_DOMAIN" "Primary domain" 2>/dev/null || true
fi
echo ""

# Step 5: Register this machine as a node
log_info "Step 5/5: Registering control plane for sync..."

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -n "$TAILSCALE_IP" ]; then
    bash "$SCRIPT_DIR/lib/sync-controller.sh" register management_laptops \
        "$TAILSCALE_IP" "control-plane" "$(whoami)" 2>/dev/null || true
    log_success "Control plane registered"
else
    log_warn "Tailscale not detected, skipping registration"
fi
echo ""

# Display summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Enterprise Registry Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's configured:"
echo "  • Service registry: $SERVICE_COUNT services discovered"
echo "  • Sync controller: Running as systemd service"
echo "  • Event-driven push: Automatic config propagation"

if [ -n "${PUBLIC_DOMAIN:-}" ]; then
    echo "  • Public domain: $PUBLIC_DOMAIN"
fi
echo ""

log_info "Next steps:"
echo ""

echo "1. Register your VPS edge nodes:"
echo "   SSH to each VPS and run:"
echo "   cd ~/MyNodeOne && git pull origin main"
echo "   sudo ./scripts/setup-vps-node.sh"
echo ""

echo "2. Register your management laptops:"
echo "   On each laptop, run:"
echo "   cd ~/MyNodeOne && git pull origin main"
echo "   sudo ./scripts/setup-management-node.sh"
echo ""

echo "3. Verify everything works:"
echo "   sudo ./scripts/lib/sync-controller.sh health"
echo "   sudo ./scripts/lib/multi-domain-registry.sh show"
echo ""

echo "4. Install apps - they'll auto-register and sync everywhere:"
echo "   sudo ./scripts/apps/install-immich.sh"
echo ""

log_info "View sync controller logs:"
echo "  sudo journalctl -u mynodeone-sync-controller -f"
echo ""

log_success "Your cluster is now enterprise-ready! 🎉"
echo ""
