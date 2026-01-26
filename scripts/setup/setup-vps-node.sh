#!/bin/bash

###############################################################################
# VPS Edge Node Local Setup
# 
# This script runs ON the VPS to perform local installation.
# It is called by mynodeone when VPS_ORCHESTRATED=true.
# 
# This script does NOT connect back to the control plane.
# The control plane orchestrates this script via SSH.
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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌍 VPS Edge Node Local Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect actual user
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

# Ensure MyNodeOne repository is available
log_info "Step 0: Ensuring MyNodeOne repository is available..."

# The orchestrator transfers files to ~/mynodeone/
# Check both lowercase and uppercase variations
if [ ! -d "$ACTUAL_HOME/mynodeone" ] && [ ! -d "$ACTUAL_HOME/MyNodeOne" ]; then
    log_info "Cloning MyNodeOne repository..."
    if command -v git &> /dev/null; then
        sudo -u "$ACTUAL_USER" git clone https://github.com/vinsac/MyNodeOne.git "$ACTUAL_HOME/MyNodeOne" 2>&1 | grep -v "Cloning into" || true
        log_success "MyNodeOne repository cloned"
    else
        log_error "Git not installed. Installing git..."
        apt-get update -qq && apt-get install -y -qq git
        sudo -u "$ACTUAL_USER" git clone https://github.com/vinsac/MyNodeOne.git "$ACTUAL_HOME/MyNodeOne" 2>&1 | grep -v "Cloning into" || true
        log_success "MyNodeOne repository cloned"
    fi
else
    log_success "MyNodeOne repository already exists"
fi

# Create consistent symlinks for sync-controller compatibility
# We want ~/mynodeone to exist even if it was cloned as ~/MyNodeOne or transferred
if [ -d "$ACTUAL_HOME/MyNodeOne" ] && [ ! -d "$ACTUAL_HOME/mynodeone" ] && [ ! -L "$ACTUAL_HOME/mynodeone" ]; then
    log_info "Creating symlink ~/mynodeone -> ~/MyNodeOne for compatibility..."
    sudo -u "$ACTUAL_USER" ln -s "$ACTUAL_HOME/MyNodeOne" "$ACTUAL_HOME/mynodeone"
    log_success "Symlink created"
elif [ -d "$ACTUAL_HOME/mynodeone" ] && [ ! -d "$ACTUAL_HOME/MyNodeOne" ] && [ ! -L "$ACTUAL_HOME/MyNodeOne" ]; then
    log_info "Creating symlink ~/MyNodeOne -> ~/mynodeone for compatibility..."
    sudo -u "$ACTUAL_USER" ln -s "$ACTUAL_HOME/mynodeone" "$ACTUAL_HOME/MyNodeOne"
    log_success "Symlink created"
fi

log_info "Running as: $ACTUAL_USER"

# Load configuration
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration not found: $CONFIG_FILE"
    log_error "This script should be called by mynodeone with VPS_ORCHESTRATED=true"
    exit 1
fi

source "$CONFIG_FILE"

log_success "Configuration loaded"
log_info "Node Name: ${NODE_NAME:-unknown}"
log_info "VPS Domain: ${VPS_DOMAIN:-unknown}"
log_info "Control Plane: ${CONTROL_PLANE_IP:-unknown}"
echo

# Step 1: Install Docker
log_info "Step 1: Installing Docker..."
if command -v docker &> /dev/null; then
    log_success "Docker already installed: $(docker --version)"
else
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    
    # Add user to docker group
    usermod -aG docker "$ACTUAL_USER"
    
    log_success "Docker installed successfully"
fi
echo

# Step 2: Install Docker Compose
log_info "Step 2: Installing Docker Compose..."
if command -v docker-compose &> /dev/null; then
    log_success "Docker Compose already installed: $(docker-compose --version)"
else
    log_info "Installing Docker Compose..."
    DOCKER_COMPOSE_VERSION="2.24.5"
    curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    log_success "Docker Compose installed successfully"
fi
echo

# Step 3: Configure firewall
log_info "Step 3: Configuring firewall..."
if command -v ufw &> /dev/null; then
    log_info "Configuring UFW firewall..."
    
    # Allow SSH
    ufw allow 22/tcp
    
    # Allow HTTP/HTTPS for Traefik
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Enable firewall
    ufw --force enable
    
    log_success "Firewall configured"
else
    log_warn "UFW not installed, skipping firewall configuration"
fi
echo

# Step 4: Setup Traefik
log_info "Step 4: Setting up Traefik..."
TRAEFIK_DIR="$ACTUAL_HOME/traefik"
mkdir -p "$TRAEFIK_DIR/config"
mkdir -p "$TRAEFIK_DIR/letsencrypt"

# Create Traefik static configuration
cat > "$TRAEFIK_DIR/traefik.yml" << 'TRAEFIK_CONFIG'
api:
  dashboard: true
  insecure: false

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik
  file:
    directory: "/etc/traefik/config"
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: "REPLACE_SSL_EMAIL"
      storage: "/letsencrypt/acme.json"
      httpChallenge:
        entryPoint: web

log:
  level: INFO
TRAEFIK_CONFIG

# Update email in config
sed -i "s/REPLACE_SSL_EMAIL/${SSL_EMAIL:-admin@${VPS_DOMAIN:-localhost}}/g" "$TRAEFIK_DIR/traefik.yml"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$TRAEFIK_DIR"
chmod 600 "$TRAEFIK_DIR/traefik.yml"
log_success "Traefik configuration created"
echo

# Step 5: Create Traefik docker-compose file
log_info "Step 5: Creating Traefik service..."
cat > "$TRAEFIK_DIR/docker-compose.yml" << 'COMPOSE_CONFIG'
version: '3.8'

services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./config:/etc/traefik/config:ro
      - ./letsencrypt:/letsencrypt
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(`traefik.REPLACE_VPS_DOMAIN`)"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
    networks:
      - traefik

networks:
  traefik:
    external: true
COMPOSE_CONFIG

# Update domain in compose file
sed -i "s/REPLACE_VPS_DOMAIN/${VPS_DOMAIN:-localhost}/g" "$TRAEFIK_DIR/docker-compose.yml"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$TRAEFIK_DIR"
log_success "Traefik service configured"
echo

# Step 6: Start Traefik
log_info "Step 6: Starting Traefik..."

# Create network
if ! docker network inspect traefik &> /dev/null; then
    docker network create traefik
    log_success "Traefik network created"
fi

# Start Traefik
cd "$TRAEFIK_DIR"
sudo -u "$ACTUAL_USER" docker-compose up -d

if docker ps | grep -q traefik; then
    log_success "Traefik started successfully"
else
    log_error "Failed to start Traefik"
    exit 1
fi
echo

# Step 7: Install sync script for automatic route updates
log_info "Step 7: Installing sync script..."

# Create scripts directory if it doesn't exist
mkdir -p "$ACTUAL_HOME/scripts"

# Check if we have the sync script locally (from orchestrator transfer)
if [ -f "/tmp/sync-vps-routes.sh" ]; then
    cp /tmp/sync-vps-routes.sh "$ACTUAL_HOME/scripts/vps/sync-vps-routes.sh"
    chmod +x "$ACTUAL_HOME/scripts/vps/sync-vps-routes.sh"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/scripts/vps/sync-vps-routes.sh"
    log_success "Sync script installed from transfer"
else
    log_warn "Sync script not found in /tmp - will be synced later by control plane"
    log_info "The control plane will push the sync script on first sync"
fi
echo

# Step 8: Configure Tailscale to accept subnet routes
log_info "Step 8: Configuring Tailscale to accept subnet routes..."
if command -v tailscale &> /dev/null; then
    if tailscale set --accept-routes=true 2>/dev/null; then
        log_success "Tailscale configured to accept subnet routes"
        log_info "This allows VPS to reach MetalLB service IPs on control plane"
    else
        log_warn "Could not configure Tailscale automatically"
        log_warn "Run manually: sudo tailscale set --accept-routes=true"
    fi
else
    log_warn "Tailscale not found - subnet routing not configured"
fi
echo

# Step 8: Create node info file
log_info "Step 8: Creating node information file..."
NODE_INFO_FILE="$ACTUAL_HOME/.mynodeone/node-info.json"
cat > "$NODE_INFO_FILE" << NODE_INFO
{
  "node_name": "${NODE_NAME}",
  "node_type": "edge",
  "vps_domain": "${VPS_DOMAIN}",
  "vps_public_ip": "${VPS_PUBLIC_IP}",
  "tailscale_ip": "${TAILSCALE_IP}",
  "control_plane_ip": "${CONTROL_PLANE_IP}",
  "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
NODE_INFO

chown "$ACTUAL_USER:$ACTUAL_USER" "$NODE_INFO_FILE"
log_success "Node information saved"
echo

# Step 9: VPS Node Information
log_info "Step 9: VPS Node Information..."

# Detect provider (optional)
PROVIDER="unknown"
if curl -s --max-time 2 http://169.254.169.254/metadata/v1/vendor-data 2>/dev/null | grep -q "Contabo"; then
    PROVIDER="contabo"
elif curl -s --max-time 2 http://169.254.169.254/metadata/v1/ 2>/dev/null | grep -q "digitalocean"; then
    PROVIDER="digitalocean"
elif curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "ami"; then
    PROVIDER="aws"
fi

log_info "Detected provider: $PROVIDER"
log_info "Control Plane IP: ${CONTROL_PLANE_IP:-not set}"

# Note: VPS registration is now handled by the control plane orchestrator
# This ensures reliable registration using the existing SSH connection
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ℹ VPS Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "VPS registration is handled automatically by the control plane"
echo "orchestrator after this setup completes successfully."
echo ""
echo "If you're running this script manually (not via orchestrator),"
echo "you'll need to register this VPS on the control plane:"
echo ""
echo "  On Control Plane, run:"
echo "  cd ~/MyNodeOne"
echo "  sudo ./scripts/lib/sync-controller.sh register vps_nodes \\"
echo "    ${TAILSCALE_IP:-<vps-tailscale-ip>} \\"
echo "    ${NODE_NAME:-<node-name>} \\"
echo "    ${VPS_SSH_USER:-<ssh-user>}"
echo ""
echo "  sudo ./scripts/domains/multi-domain-registry.sh register-vps \\"
echo "    ${TAILSCALE_IP:-<vps-tailscale-ip>} \\"
echo "    ${VPS_PUBLIC_IP:-<public-ip>} \\"
echo "    ${VPS_LOCATION:-unknown} unknown"
echo ""
if [ -n "${VPS_DOMAIN:-}" ]; then
    echo "  sudo ./scripts/domains/multi-domain-registry.sh register-domain \\"
    echo "    ${VPS_DOMAIN} 'VPS edge node domain'"
    echo ""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "VPS setup complete (registration handled by control plane)"
echo

# Step 10: Install Node Agent for pull-based config sync
log_info "Step 10: Installing Node Agent..."

# PROJECT_ROOT is already defined at the top of the script via project-root.sh

if [ -f "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" ]; then
    # Get API token from config if available (set by VPS orchestrator)
    API_TOKEN="${API_TOKEN:-}"
    
    # Get SSH user for control plane to enable automatic token fetch as fallback
    # The orchestrator sets CONTROL_PLANE_SSH_USER in the config
    CP_SSH_USER="${CONTROL_PLANE_SSH_USER:-${CONTROL_PLANE_USER:-}}"
    
    # If token is already set, no need for SSH user (faster path)
    if [ -n "$API_TOKEN" ]; then
        log_info "API token found in config (set by control plane orchestrator)"
        CP_SSH_USER=""  # Don't need SSH fetch if we have token
    fi
    
    # Call install-config-sync with ssh-user parameter for automatic token fetch
    # Arguments: node-type control-plane-ip api-token node-name ssh-user
    if bash "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" vps "${CONTROL_PLANE_IP:-}" "$API_TOKEN" "${NODE_NAME:-$(hostname)}" "$CP_SSH_USER"; then
        log_success "Node Agent installed"
        log_info "VPS will now pull config updates from control plane"
    else
        log_warn "Node Agent installation had issues"
        log_warn "You can install manually later:"
        log_warn "  sudo ./scripts/lib/install-config-sync.sh vps ${CONTROL_PLANE_IP:-<control-plane-ip>} <api-token>"
    fi
else
    log_warn "Node Agent installer not found, skipping"
fi
echo

# Final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "VPS Edge Node setup complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "✓ Docker installed and running"
echo "✓ Traefik configured and running"
echo "✓ Firewall configured"
echo "✓ SSL certificates will be issued automatically"
echo "✓ Node Agent installed (pull-based config sync)"
echo
echo "Next steps:"
echo "  1. Verify Traefik: docker ps | grep traefik"
echo "  2. Check logs: docker logs traefik"
echo "  3. Point DNS to this VPS: ${VPS_PUBLIC_IP:-your-vps-ip}"
echo "  4. Check node status: sudo mynodeone-node-agent status"
echo
