#!/bin/bash

# Configure VPS Edge Node Route
# Automatically adds Traefik routing for apps exposed via VPS

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. This script requires kubectl access to the cluster."
fi

# Check if we can access the cluster
if ! kubectl get nodes &> /dev/null; then
    error "Cannot access Kubernetes cluster. Ensure kubectl is configured correctly."
fi

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
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Parse arguments
APP_NAME="$1"
APP_PORT="$2"
SUBDOMAIN="$3"
DOMAIN="$4"
CUSTOM_NS_SERVICE="$5"  # Optional: "namespace/service" format

# Usage
if [[ -z "$APP_NAME" ]] || [[ -z "$APP_PORT" ]] || [[ -z "$SUBDOMAIN" ]] || [[ -z "$DOMAIN" ]]; then
    cat << 'EOF'
Usage: sudo ./scripts/configure-vps-route.sh <app-name> <port> <subdomain> <domain> [namespace/service]

Example: 
  sudo ./scripts/configure-vps-route.sh immich 3001 photos example.com
  sudo ./scripts/configure-vps-route.sh llm-chat 80 chat example.com llm-chat/open-webui
  
This will configure:
  - Traefik route on VPS for photos.example.com → http://CONTROL_PLANE_IP:3001
  - Automatic SSL certificate from Let's Encrypt
  - HTTPS redirect

Required:
  - VPS edge node must be set up
  - Domain must point to VPS IP
  - Control plane must be reachable via Tailscale

Optional:
  - Specify custom namespace/service if different from app-name

EOF
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configure VPS Route for $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Auto-detect service from Kubernetes
NAMESPACE=""
SERVICE_NAME=""

if [[ -n "$CUSTOM_NS_SERVICE" ]]; then
    # Custom namespace/service provided
    NAMESPACE="${CUSTOM_NS_SERVICE%/*}"
    SERVICE_NAME="${CUSTOM_NS_SERVICE#*/}"
    info "Using custom namespace/service: $NAMESPACE/$SERVICE_NAME"
    
    if ! kubectl get svc -n "$NAMESPACE" "$SERVICE_NAME" &>/dev/null 2>&1; then
        error "Service $SERVICE_NAME not found in namespace $NAMESPACE"
    fi
else
    # Auto-detect: try app-name as namespace first
    info "Auto-detecting service for $APP_NAME..."
    NAMESPACE="$APP_NAME"
    
    for pattern in "${APP_NAME}-server" "${APP_NAME}" "${APP_NAME}-frontend"; do
        if kubectl get svc -n "$NAMESPACE" "$pattern" &>/dev/null 2>&1; then
            SERVICE_NAME="$pattern"
            break
        fi
    done
    
    if [[ -z "$SERVICE_NAME" ]]; then
        error "Could not find service for app '$APP_NAME'. Checked: ${APP_NAME}-server, ${APP_NAME}, ${APP_NAME}-frontend
        
Hint: If your service is in a different namespace, use:
  sudo ./scripts/configure-vps-route.sh $APP_NAME $APP_PORT $SUBDOMAIN $DOMAIN <namespace>/<service-name>"
    fi
fi

info "Found service: $SERVICE_NAME"

# Auto-detect control plane Tailscale IP from Kubernetes
info "Detecting control plane node IP..."
CONTROL_PLANE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [[ -z "$CONTROL_PLANE_IP" ]]; then
    # Try to get from Tailscale if running on control plane
    if command -v tailscale &> /dev/null; then
        CONTROL_PLANE_IP=$(tailscale ip -4)
    fi
    
    # If still not found, prompt user
    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        warn "Could not automatically determine control plane IP"
        echo ""
        read -p "Enter control plane Tailscale IP: " CONTROL_PLANE_IP
        if [[ -z "$CONTROL_PLANE_IP" ]]; then
            error "Control plane IP required"
        fi
    fi
fi

success "Control plane IP: $CONTROL_PLANE_IP"

# Get NodePort (VPS needs to connect to NodePort, not LoadBalancer IP)
# LoadBalancer IPs are only accessible within the cluster network
info "Detecting service NodePort..."
NODE_PORT=$(kubectl get svc -n "$NAMESPACE" "$SERVICE_NAME" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")

if [[ -z "$NODE_PORT" ]]; then
    warn "Could not detect NodePort, using provided port: $APP_PORT"
    NODE_PORT="$APP_PORT"
else
    success "Auto-detected NodePort: $NODE_PORT"
    APP_PORT="$NODE_PORT"
fi

info "App: $APP_NAME"
info "Backend: http://${CONTROL_PLANE_IP}:${APP_PORT}"
info "Public Domain: ${SUBDOMAIN}.${DOMAIN}"

# Check if VPS edge node is configured
if [[ -z "${VPS_EDGE_IP:-}" ]]; then
    warn "VPS edge node not found in config"
    echo ""
    read -p "Enter your VPS Tailscale IP: " VPS_EDGE_IP
    if [[ -z "$VPS_EDGE_IP" ]]; then
        error "VPS Tailscale IP required"
    fi
    
    # Save to config
    mkdir -p ~/.mynodeone
    echo "VPS_EDGE_IP=$VPS_EDGE_IP" >> ~/.mynodeone/config.env
fi

# Test connectivity to VPS
info "Testing connection to VPS ($VPS_EDGE_IP)..."
if ! ping -c 1 -W 2 "$VPS_EDGE_IP" >/dev/null 2>&1; then
    error "Cannot reach VPS at $VPS_EDGE_IP. Check Tailscale connection."
fi
success "VPS is reachable"

# Create route configuration
ROUTE_FILE="/tmp/${APP_NAME}-route.yml"

cat > "$ROUTE_FILE" << EOF
http:
  routers:
    ${APP_NAME}:
      rule: "Host(\`${SUBDOMAIN}.${DOMAIN}\`)"
      service: ${APP_NAME}-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
    
    ${APP_NAME}-http:
      rule: "Host(\`${SUBDOMAIN}.${DOMAIN}\`)"
      service: ${APP_NAME}-service
      entryPoints:
        - web
      middlewares:
        - https-redirect

  services:
    ${APP_NAME}-service:
      loadBalancer:
        servers:
          - url: "http://${CONTROL_PLANE_IP}:${APP_PORT}"

  middlewares:
    https-redirect:
      redirectScheme:
        scheme: https
        permanent: true
EOF

info "Route configuration created"

# Copy to VPS
info "Copying route configuration to VPS..."

# Try to copy via SSH (if SSH keys are set up)
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$VPS_EDGE_IP" "echo test" >/dev/null 2>&1; then
    scp -o StrictHostKeyChecking=no "$ROUTE_FILE" root@"$VPS_EDGE_IP":/etc/traefik/dynamic/"${APP_NAME}.yml"
    success "Route copied to VPS via SSH"
    
    # Restart Traefik
    info "Restarting Traefik on VPS..."
    ssh root@"$VPS_EDGE_IP" "cd /etc/traefik && docker compose restart"
    success "Traefik restarted"
else
    # Manual copy instructions
    warn "Cannot SSH to VPS automatically"
    echo ""
    echo "Please manually copy the route configuration:"
    echo ""
    echo "1. Copy this file to your VPS:"
    echo "   scp $ROUTE_FILE root@\$VPS_IP:/etc/traefik/dynamic/${APP_NAME}.yml"
    echo ""
    echo "2. Or manually create /etc/traefik/dynamic/${APP_NAME}.yml on VPS with:"
    cat "$ROUTE_FILE"
    echo ""
    echo "3. Then restart Traefik on VPS:"
    echo "   ssh root@\$VPS_IP 'cd /etc/traefik && docker compose restart'"
    echo ""
    read -p "Press Enter after you've completed these steps..."
fi

# Clean up
rm -f "$ROUTE_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Route Configuration Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
success "$APP_NAME is now accessible at: https://${SUBDOMAIN}.${DOMAIN}"
echo ""
echo "Next steps:"
echo "  1. Ensure DNS A record points ${SUBDOMAIN}.${DOMAIN} → VPS IP"
echo "  2. Wait 5-10 minutes for DNS propagation"
echo "  3. Visit https://${SUBDOMAIN}.${DOMAIN}"
echo "  4. SSL certificate will be automatically issued by Let's Encrypt"
echo ""
echo "DNS Configuration:"
echo "  Type: A"
echo "  Name: ${SUBDOMAIN}"
echo "  Value: [Your VPS Public IP]"
echo "  TTL: 300"
echo ""
info "See docs/guides/DNS-SETUP-GUIDE.md for detailed DNS instructions"
echo ""
