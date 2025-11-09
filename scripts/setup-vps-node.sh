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
# Prefer configured VPS_PUBLIC_IP, otherwise auto-detect IPv4
if [ -n "${VPS_PUBLIC_IP:-}" ]; then
    PUBLIC_IP="$VPS_PUBLIC_IP"
else
    # Force IPv4 with -4 flag
    PUBLIC_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -s ipv4.icanhazip.com 2>/dev/null || echo "")
fi
HOSTNAME=$(hostname)

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    echo "Please ensure Tailscale is installed and running"
    exit 1
fi

# Configure Tailscale to accept subnet routes from control plane
log_info "Configuring Tailscale to accept subnet routes..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Tailscale Subnet Routes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "The VPS needs to access services in your Kubernetes cluster."
echo "This requires accepting subnet routes from the control plane."
echo ""
echo "This will enable routing to cluster LoadBalancer IPs."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Always run tailscale up --accept-routes (it's idempotent)
if tailscale up --accept-routes; then
    log_success "Tailscale configured to accept subnet routes"
else
    log_warn "Could not configure Tailscale routes automatically"
    log_warn "You may need to manually approve routes in Tailscale admin"
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
    echo "A public domain is needed for SSL certificates and external access."
    echo "You can set this up later if you don't have one yet."
    echo ""
    read -p "Enter your public domain (or press Enter to skip): " user_domain
    
    if [ -n "$user_domain" ]; then
        echo "PUBLIC_DOMAIN=\"$user_domain\"" >> ~/.mynodeone/config.env
        PUBLIC_DOMAIN="$user_domain"
        log_success "Domain configured: $PUBLIC_DOMAIN"
    else
        log_warn "Skipping domain configuration. You can add it later to ~/.mynodeone/config.env"
        PUBLIC_DOMAIN=""
    fi
fi

echo ""
log_info "Registering with control plane..."
echo ""

# Setup SSH keys for passwordless authentication
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

log_info "Setting up SSH key authentication..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "exit" 2>/dev/null; then
    log_success "SSH key authentication already configured"
else
    log_info "Configuring passwordless SSH between VPS and control plane..."
    
    # Generate SSH key if it doesn't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "vps-$HOSTNAME"
        log_success "SSH key generated"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  SSH Key Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Setting up passwordless SSH access to control plane."
    echo "You'll be prompted for the password ONE LAST TIME."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Copy SSH key to control plane
    if ssh-copy-id -o StrictHostKeyChecking=no "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" 2>/dev/null; then
        log_success "SSH key installed on control plane"
        
        # Also setup reverse SSH access (control plane -> VPS)
        log_info "Setting up reverse SSH access (control plane → VPS)..."
        ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "
            if [ ! -f ~/.ssh/id_rsa ]; then
                ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N '' -C 'control-plane'
            fi
            cat ~/.ssh/id_rsa.pub
        " | tee -a ~/.ssh/authorized_keys > /dev/null
        
        # Ensure proper permissions
        chmod 600 ~/.ssh/authorized_keys
        
        # Verify reverse SSH works (control plane -> VPS)
        log_info "Verifying reverse SSH access..."
        if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "ssh -o BatchMode=yes -o ConnectTimeout=5 root@$TAILSCALE_IP 'echo OK' 2>/dev/null" | grep -q "OK"; then
            log_success "Bidirectional passwordless SSH verified ✓"
        else
            log_warn "Reverse SSH verification failed, but continuing..."
            log_warn "Control plane may need to add VPS to known_hosts"
        fi
    else
        log_warn "Could not install SSH key automatically"
        log_warn "You will be prompted for passwords during setup"
    fi
    echo ""
fi

# Register this VPS in the multi-domain registry
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
ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-vps \
    $TAILSCALE_IP $PUBLIC_IP $REGION $PROVIDER" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in multi-domain registry"
else
    log_warn "VPS registration may have failed, continuing..."
fi

# Register domain in cluster if PUBLIC_DOMAIN is configured
if [ -n "$PUBLIC_DOMAIN" ]; then
    log_info "Registering domain in cluster: $PUBLIC_DOMAIN"
    
    ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-domain \
        $PUBLIC_DOMAIN 'VPS edge node domain'" 2>&1 | grep -v "Warning: Permanently added"
    
    if [ $? -eq 0 ]; then
        log_success "Domain registered in cluster: $PUBLIC_DOMAIN"
    else
        log_warn "Domain registration may have failed, continuing..."
    fi
fi

# Register VPS in sync controller
ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/sync-controller.sh register vps_nodes \
    $TAILSCALE_IP $HOSTNAME root" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in sync controller"
else
    log_warn "Sync controller registration may have failed, continuing..."
fi

echo ""
log_info "Installing sync script on VPS..."

# Create scripts directory structure
mkdir -p ~/MyNodeOne/scripts/lib

# Fetch sync script from control plane
if scp "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP:~/MyNodeOne/scripts/sync-vps-routes.sh" \
    ~/MyNodeOne/scripts/sync-vps-routes.sh 2>/dev/null; then
    chmod +x ~/MyNodeOne/scripts/sync-vps-routes.sh
    log_success "Sync script installed"
else
    log_warn "Could not fetch sync script from control plane"
    log_info "Creating minimal sync script..."
    
    # Create a minimal sync script that uses SSH to control plane
    cat > ~/MyNodeOne/scripts/sync-vps-routes.sh << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

# Load configuration
source ~/.mynodeone/config.env

VPS_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)

echo "[INFO] Syncing routes from control plane..."

# Fetch routes from control plane
ssh "${CONTROL_PLANE_SSH_USER:-root}@${CONTROL_PLANE_IP}" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh export-vps-routes $VPS_TAILSCALE_IP ${CONTROL_PLANE_IP}" \
    > /tmp/mynodeone-routes.yml

# Install routes
sudo mkdir -p /etc/traefik/dynamic
sudo cp /tmp/mynodeone-routes.yml /etc/traefik/dynamic/mynodeone-routes.yml
sudo chmod 644 /etc/traefik/dynamic/mynodeone-routes.yml
rm -f /tmp/mynodeone-routes.yml

# Restart Traefik
cd /etc/traefik && sudo docker compose restart

echo "[SUCCESS] Routes synced and Traefik restarted"
EOFSCRIPT
    
    chmod +x ~/MyNodeOne/scripts/sync-vps-routes.sh
    log_success "Minimal sync script created"
fi

log_info "Running initial sync..."
if ~/MyNodeOne/scripts/sync-vps-routes.sh 2>&1 | tail -5; then
    log_success "Initial sync completed"
else
    log_info "Initial sync skipped (no routes configured yet)"
    log_info "Routes will be pushed from control plane when apps are made public"
fi

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
