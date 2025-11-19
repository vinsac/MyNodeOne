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

# Step 7: Create node info file
log_info "Step 7: Creating node information file..."
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

# Step 8: Register VPS with Control Plane
log_info "Step 8: Registering VPS with Control Plane..."

# Check if we have SSH access to control plane
if command -v ssh &> /dev/null && [ -n "${CONTROL_PLANE_IP:-}" ]; then
    log_info "Control Plane IP: $CONTROL_PLANE_IP"
    
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
    
    # Try to register VPS node
    log_info "Registering VPS node..."
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${ACTUAL_USER}@${CONTROL_PLANE_IP}" \
        "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-vps \
        ${TAILSCALE_IP:-unknown} \
        ${VPS_PUBLIC_IP:-unknown} \
        ${VPS_LOCATION:-unknown} \
        $PROVIDER" 2>/dev/null; then
        log_success "VPS node registered in domain-registry"
    else
        log_warn "Could not auto-register VPS (SSH may require setup)"
        echo "You can manually register later:"
        echo "  cd ~/MyNodeOne"
        echo "  sudo ./scripts/lib/multi-domain-registry.sh register-vps \\"
        echo "    ${TAILSCALE_IP:-unknown} ${VPS_PUBLIC_IP:-unknown} ${VPS_LOCATION:-unknown} $PROVIDER"
    fi
    
    # Try to register domain if configured
    if [ -n "${VPS_DOMAIN:-}" ]; then
        log_info "Registering domain: $VPS_DOMAIN..."
        if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${ACTUAL_USER}@${CONTROL_PLANE_IP}" \
            "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-domain \
            ${VPS_DOMAIN} \
            'VPS edge node domain'" 2>/dev/null; then
            log_success "Domain registered: $VPS_DOMAIN"
        else
            log_warn "Could not auto-register domain"
            echo "You can manually register later:"
            echo "  sudo ./scripts/lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'Description'"
        fi
    fi
    
    # Trigger sync controller to pick up changes
    log_info "Triggering sync controller..."
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${ACTUAL_USER}@${CONTROL_PLANE_IP}" \
        "sudo systemctl restart mynodeone-sync-controller" 2>/dev/null || true
    
    log_success "Registration complete"
else
    log_warn "Skipping auto-registration (SSH not configured or CONTROL_PLANE_IP not set)"
    echo ""
    echo "To manually register this VPS on the control plane, run:"
    echo "  cd ~/MyNodeOne"
    echo "  sudo ./scripts/lib/multi-domain-registry.sh register-vps ${TAILSCALE_IP:-unknown} ${VPS_PUBLIC_IP:-unknown} ${VPS_LOCATION:-unknown} unknown"
    if [ -n "${VPS_DOMAIN:-}" ]; then
        echo "  sudo ./scripts/lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'VPS domain'"
    fi
fi
echo

# Final summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "VPS Edge Node setup complete! 🎉"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "✓ Docker installed and running"
echo "✓ Traefik configured and running"
echo "✓ Firewall configured"
echo "✓ SSL certificates will be issued automatically"
echo
echo "Next steps:"
echo "  1. Verify Traefik: docker ps | grep traefik"
echo "  2. Check logs: docker logs traefik"
echo "  3. Point DNS to this VPS: ${VPS_PUBLIC_IP:-your-vps-ip}"
echo
if [ -n "${VPS_DOMAIN:-}" ]; then
    echo "Traefik dashboard: https://traefik.${VPS_DOMAIN}"
fi
echo
