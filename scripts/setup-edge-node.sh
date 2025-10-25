#!/bin/bash

###############################################################################
# MyNodeOne VPS Edge Node Setup Script
# 
# This script configures a VPS with public IP as an edge/ingress node
# 
# IMPORTANT: Run ./scripts/interactive-setup.sh first!
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE="$HOME/.mynodeone/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Verify configuration
    if [ -z "$TAILSCALE_IP" ] || [ -z "$VPS_PUBLIC_IP" ] || [ -z "$CONTROL_PLANE_IP" ]; then
        log_error "Configuration incomplete. Please run: ./scripts/interactive-setup.sh"
        exit 1
    fi
    
    log_success "Tailscale IP: $TAILSCALE_IP"
    log_success "Public IP: $VPS_PUBLIC_IP"
    log_success "Control Plane: $CONTROL_PLANE_IP"
    log_success "Prerequisites check passed"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        ufw \
        fail2ban \
        netcat-openbsd
    
    log_success "Dependencies installed"
}

configure_firewall() {
    log_info "Configuring firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH (be careful!)
    ufw allow 22/tcp comment 'SSH'
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    # Allow Tailscale
    ufw allow in on tailscale0
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    log_success "Firewall configured"
}

install_docker() {
    log_info "Installing Docker..."
    
    if command -v docker &> /dev/null; then
        log_warn "Docker already installed, skipping..."
        return
    fi
    
    # Install Docker
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    
    log_success "Docker installed"
}

install_traefik() {
    log_info "Installing Traefik as reverse proxy..."
    
    # Create Traefik directory
    mkdir -p /etc/traefik
    mkdir -p /etc/traefik/dynamic
    mkdir -p /var/log/traefik
    
    # Create Traefik static configuration
    cat > /etc/traefik/traefik.yml <<'EOF'
# Traefik Static Configuration
global:
  checkNewVersion: false
  sendAnonymousUsage: false

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
          permanent: true
  
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${SSL_EMAIL}
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
EOF
    
    # Create initial dynamic configuration
    cat > /etc/traefik/dynamic/config.yml <<EOF
# Traefik Dynamic Configuration
http:
  routers:
    # Example router - add your domains here
    dashboard:
      rule: "Host(\`traefik.mynodeone.local\`)"
      service: api@internal
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
      middlewares:
        - auth

  middlewares:
    auth:
      basicAuth:
        users:
          - "admin:\$apr1\$H6uskkkW\$IgXLP6ewTrSuBkTrqE8wj/"  # admin:admin (change this!)
EOF
    
    # Create acme.json with proper permissions
    touch /etc/traefik/acme.json
    chmod 600 /etc/traefik/acme.json
    
    # Create Docker Compose file
    cat > /etc/traefik/docker-compose.yml <<EOF
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    network_mode: host
    volumes:
      - /etc/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik/dynamic:/etc/traefik/dynamic:ro
      - /etc/traefik/acme.json:/etc/traefik/acme.json
      - /var/log/traefik:/var/log/traefik
    environment:
      - TZ=America/Toronto
EOF
    
    # Start Traefik
    cd /etc/traefik
    docker compose up -d
    
    log_success "Traefik installed and started"
}

save_control_plane_ip() {
    log_info "Saving control plane IP for Traefik..."
    
    # Verify we can reach control plane
    if ! nc -z -w5 "$CONTROL_PLANE_IP" 6443 2>/dev/null; then
        log_warn "Cannot reach control plane at $CONTROL_PLANE_IP:6443"
        log_warn "Make sure:"
        log_warn "  1. Control plane is running"
        log_warn "  2. Tailscale is connected on both machines"
        log_warn "  3. K3s is installed on control plane"
        echo
        if ! prompt_confirm "Continue anyway?"; then
            exit 1
        fi
    else
        log_success "Control plane reachable at: $CONTROL_PLANE_IP"
    fi
    
    echo "$CONTROL_PLANE_IP" > /etc/traefik/control-plane-ip
}

prompt_confirm() {
    local prompt="$1"
    local response
    read -p "$prompt [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]]
}

configure_routing() {
    log_info "Configuring routing to MyNodeOne cluster..."
    
    CONTROL_PLANE_IP=$(cat /etc/traefik/control-plane-ip)
    
    # This creates a sample configuration
    # Users will need to add their own routes
    cat > /etc/traefik/dynamic/mynodeone-routes.yml <<EOF
# MyNodeOne Routes Configuration
# 
# Add your application routes here
# Example:
#
# http:
#   routers:
#     curiios:
#       rule: "Host(\`curiios.com\`) || Host(\`www.curiios.com\`)"
#       service: curiios-service
#       entryPoints:
#         - websecure
#       tls:
#         certResolver: letsencrypt
#
#   services:
#     curiios-service:
#       loadBalancer:
#         servers:
#           - url: "http://${CONTROL_PLANE_IP}:<service-port>"

# Default backend (optional)
http:
  routers:
    default:
      rule: "HostRegexp(\`{host:.+}\`)"
      service: default-backend
      entryPoints:
        - websecure
      priority: 1
      tls:
        certResolver: letsencrypt

  services:
    default-backend:
      loadBalancer:
        servers:
          - url: "http://${CONTROL_PLANE_IP}:80"
EOF
    
    log_success "Routing configured"
    log_info "Edit /etc/traefik/dynamic/mynodeone-routes.yml to add your domains"
}

setup_monitoring_agent() {
    log_info "Setting up monitoring agent..."
    
    # Install node_exporter for Prometheus
    ARCH=$(dpkg --print-architecture)
    NODE_EXPORTER_VERSION="1.7.0"
    
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"*
    
    # Create systemd service
    cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now node_exporter
    
    log_success "Monitoring agent installed"
}

print_summary() {
    log_success "VPS Edge Node setup complete! 🎉"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  VPS Edge Node Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Node Information:"
    echo "  Hostname: $NODE_NAME"
    echo "  Public IP: $VPS_PUBLIC_IP"
    echo "  Tailscale IP: $TAILSCALE_IP"
    echo
    echo "Installed Components:"
    echo "  ✓ Traefik (Reverse Proxy)"
    echo "  ✓ Docker"
    echo "  ✓ UFW Firewall"
    echo "  ✓ Node Exporter (Monitoring)"
    echo
    echo "Configuration Files:"
    echo "  Traefik Config: /etc/traefik/traefik.yml"
    echo "  Dynamic Routes: /etc/traefik/dynamic/"
    echo "  Docker Compose: /etc/traefik/docker-compose.yml"
    echo
    echo "Next Steps:"
    echo "  1. Point your DNS records to this IP: $VPS_PUBLIC_IP"
    echo "     Example: A record @ -> $VPS_PUBLIC_IP"
    echo
    echo "  2. Add your application routes in:"
    echo "     /etc/traefik/dynamic/mynodeone-routes.yml"
    echo
    echo "  3. Restart Traefik to apply changes:"
    echo "     cd /etc/traefik && docker compose restart"
    echo
    echo "  4. View Traefik logs:"
    echo "     docker logs traefik -f"
    echo
    echo "SSL certificates will be automatically obtained from Let's Encrypt!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne VPS Edge Node Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    install_dependencies
    configure_firewall
    install_docker
    install_traefik
    save_control_plane_ip
    configure_routing
    setup_monitoring_agent
    
    echo
    print_summary
}

# Run main function
main "$@"
