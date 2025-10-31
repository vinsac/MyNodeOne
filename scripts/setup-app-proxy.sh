#!/bin/bash

###############################################################################
# MyNodeOne App Proxy Setup
# 
# Automatically creates socat proxy on control plane for hybrid setups
# Bridges Tailscale network to Kubernetes ClusterIP services
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helper functions
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check if running with kubectl access
if ! command -v kubectl &> /dev/null; then
    error "kubectl not found. This script requires kubectl access to the cluster."
fi

if ! kubectl get nodes &> /dev/null; then
    error "Cannot access Kubernetes cluster. Ensure kubectl is configured correctly."
fi

# Usage
show_usage() {
    cat << 'EOF'
Usage: sudo ./scripts/setup-app-proxy.sh <app-name> <namespace> [options]

Creates a persistent socat proxy on the control plane for an app service.

Arguments:
  app-name      Name of the app (e.g., immich, jellyfin)
  namespace     Kubernetes namespace (e.g., immich, media)

Options:
  --proxy-port PORT     Port for socat to listen on (default: auto-assign)
  --service-name NAME   K8s service name (default: <app-name>-server)
  --control-plane HOST  Control plane hostname/IP (default: auto-detect)
  --skip-systemd        Don't create systemd service
  --help               Show this help message

Examples:
  # Basic usage (auto-detect everything):
  sudo ./scripts/setup-app-proxy.sh immich immich

  # Specify custom port:
  sudo ./scripts/setup-app-proxy.sh jellyfin media --proxy-port 8081

  # Custom service name:
  sudo ./scripts/setup-app-proxy.sh vault vault --service-name vaultwarden

How it works:
  1. Detects Kubernetes service ClusterIP and port
  2. Finds available proxy port (or uses specified)
  3. Gets control plane Tailscale IP
  4. Creates socat systemd service
  5. Starts and enables service
  6. Updates firewall rules

EOF
    exit 0
}

# Parse arguments
APP_NAME="${1:-}"
NAMESPACE="${2:-}"
PROXY_PORT=""
SERVICE_NAME=""
CONTROL_PLANE=""
SKIP_SYSTEMD=false

if [[ -z "$APP_NAME" ]] || [[ -z "$NAMESPACE" ]]; then
    show_usage
fi

# Parse options
shift 2
while [[ $# -gt 0 ]]; do
    case $1 in
        --proxy-port)
            PROXY_PORT="$2"
            shift 2
            ;;
        --service-name)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --control-plane)
            CONTROL_PLANE="$2"
            shift 2
            ;;
        --skip-systemd)
            SKIP_SYSTEMD=true
            shift
            ;;
        --help)
            show_usage
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setting Up App Proxy for $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Default service name
if [[ -z "$SERVICE_NAME" ]]; then
    SERVICE_NAME="${APP_NAME}-server"
fi

# Get Kubernetes service details
info "Looking up Kubernetes service: $SERVICE_NAME in namespace $NAMESPACE..."

SERVICE_CLUSTERIP=$(kubectl get svc -n "$NAMESPACE" "$SERVICE_NAME" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
SERVICE_PORT=$(kubectl get svc -n "$NAMESPACE" "$SERVICE_NAME" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "")

if [[ -z "$SERVICE_CLUSTERIP" ]] || [[ -z "$SERVICE_PORT" ]]; then
    error "Service $SERVICE_NAME not found in namespace $NAMESPACE. Is the app installed?"
fi

success "Found service: $SERVICE_CLUSTERIP:$SERVICE_PORT"

# Get control plane Tailscale IP
if [[ -z "$CONTROL_PLANE" ]]; then
    info "Detecting control plane Tailscale IP..."
    
    # Try to get from kubectl context (if running on control plane)
    if command -v tailscale &> /dev/null; then
        CONTROL_PLANE=$(tailscale ip -4 2>/dev/null || echo "")
    fi
    
    # If still not found, try to detect from node
    if [[ -z "$CONTROL_PLANE" ]]; then
        # Get control plane node name
        CONTROL_NODE=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$CONTROL_NODE" ]]; then
            # Try to get Tailscale IP from node
            CONTROL_PLANE=$(kubectl get node "$CONTROL_NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
        fi
    fi
    
    # If still not found, ask user
    if [[ -z "$CONTROL_PLANE" ]]; then
        warn "Could not auto-detect control plane IP"
        read -p "Enter control plane Tailscale IP (e.g., 100.118.5.68): " CONTROL_PLANE
        if [[ -z "$CONTROL_PLANE" ]]; then
            error "Control plane IP required"
        fi
    fi
fi

success "Control plane IP: $CONTROL_PLANE"

# Find available proxy port
if [[ -z "$PROXY_PORT" ]]; then
    info "Finding available proxy port..."
    
    # Start from 8080 and find first available
    PROXY_PORT=8080
    while netstat -tuln 2>/dev/null | grep -q ":$PROXY_PORT " || ss -tuln 2>/dev/null | grep -q ":$PROXY_PORT "; do
        PROXY_PORT=$((PROXY_PORT + 1))
        if [[ $PROXY_PORT -gt 8100 ]]; then
            error "No available ports found in range 8080-8100"
        fi
    done
    
    success "Using proxy port: $PROXY_PORT"
else
    info "Using specified proxy port: $PROXY_PORT"
    
    # Check if port is already in use
    if netstat -tuln 2>/dev/null | grep -q ":$PROXY_PORT " || ss -tuln 2>/dev/null | grep -q ":$PROXY_PORT "; then
        error "Port $PROXY_PORT is already in use"
    fi
fi

# Check if socat is installed
if ! command -v socat &> /dev/null; then
    warn "socat not found, installing..."
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y socat
    elif command -v yum &> /dev/null; then
        sudo yum install -y socat
    else
        error "Could not install socat. Please install it manually."
    fi
    
    success "socat installed"
fi

# Create systemd service
if [[ "$SKIP_SYSTEMD" == false ]]; then
    info "Creating systemd service..."
    
    SERVICE_FILE="/etc/systemd/system/${APP_NAME}-proxy.service"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=${APP_NAME^} App Proxy (socat)
After=network.target k3s.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:${PROXY_PORT},bind=${CONTROL_PLANE},fork TCP:${SERVICE_CLUSTERIP}:${SERVICE_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    success "Service file created: $SERVICE_FILE"
    
    # Reload systemd
    info "Reloading systemd..."
    sudo systemctl daemon-reload
    
    # Enable service
    info "Enabling ${APP_NAME}-proxy service..."
    sudo systemctl enable "${APP_NAME}-proxy.service"
    
    # Start service
    info "Starting ${APP_NAME}-proxy service..."
    sudo systemctl start "${APP_NAME}-proxy.service"
    
    # Wait a moment and check status
    sleep 2
    
    if sudo systemctl is-active --quiet "${APP_NAME}-proxy.service"; then
        success "Service ${APP_NAME}-proxy is running"
    else
        error "Service failed to start. Check logs: journalctl -u ${APP_NAME}-proxy -n 50"
    fi
else
    info "Skipping systemd service creation"
    
    # Start socat manually
    info "Starting socat proxy..."
    nohup socat TCP-LISTEN:${PROXY_PORT},bind=${CONTROL_PLANE},fork TCP:${SERVICE_CLUSTERIP}:${SERVICE_PORT} > /tmp/${APP_NAME}-proxy.log 2>&1 &
    
    success "Socat started (PID: $!)"
    warn "This will not survive reboots. Use systemd for persistence."
fi

# Update firewall if UFW is installed
if command -v ufw &> /dev/null; then
    info "Updating firewall rules..."
    
    # Load VPS IP from config if available
    VPS_IP=""
    if [[ -f ~/.mynodeone/config.env ]]; then
        source ~/.mynodeone/config.env
        VPS_IP="${VPS_EDGE_IP:-}"
    fi
    
    if [[ -n "$VPS_IP" ]]; then
        # Allow VPS to access this port
        sudo ufw allow from "$VPS_IP" to any port "$PROXY_PORT" proto tcp comment "${APP_NAME} proxy from VPS"
        sudo ufw reload
        success "Firewall rule added for $VPS_IP:$PROXY_PORT"
    else
        warn "VPS IP not found. Add firewall rule manually:"
        echo "  sudo ufw allow from <VPS_TAILSCALE_IP> to any port $PROXY_PORT proto tcp"
    fi
else
    warn "UFW not found. Ensure firewall allows port $PROXY_PORT from VPS."
fi

# Save configuration
CONFIG_DIR="$HOME/.mynodeone"
mkdir -p "$CONFIG_DIR"

echo "${APP_NAME}_PROXY_PORT=${PROXY_PORT}" >> "$CONFIG_DIR/proxy-ports.env"
echo "${APP_NAME}_PROXY_URL=http://${CONTROL_PLANE}:${PROXY_PORT}" >> "$CONFIG_DIR/proxy-urls.env"

success "Configuration saved to $CONFIG_DIR"

# Test connectivity
info "Testing proxy connectivity..."

if curl -s -o /dev/null -w "%{http_code}" "http://${CONTROL_PLANE}:${PROXY_PORT}" --connect-timeout 5 | grep -qE "200|301|302|404"; then
    success "Proxy is accessible at http://${CONTROL_PLANE}:${PROXY_PORT}"
else
    warn "Proxy connectivity test inconclusive. App might still be starting."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Proxy Setup Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  App: $APP_NAME"
echo "  Proxy: http://${CONTROL_PLANE}:${PROXY_PORT}"
echo "  Backend: http://${SERVICE_CLUSTERIP}:${SERVICE_PORT}"
echo ""

if [[ "$SKIP_SYSTEMD" == false ]]; then
    echo "  Service: ${APP_NAME}-proxy.service"
    echo "  Status: sudo systemctl status ${APP_NAME}-proxy"
    echo "  Logs: sudo journalctl -u ${APP_NAME}-proxy -f"
    echo "  Restart: sudo systemctl restart ${APP_NAME}-proxy"
    echo ""
fi

echo "  Next steps:"
echo "  1. Configure Traefik route on VPS to point to: http://${CONTROL_PLANE}:${PROXY_PORT}"
echo "  2. Or run: sudo ./scripts/configure-vps-route.sh $APP_NAME 80 <subdomain> <domain>"
echo ""

# Auto-update VPS route if configure-vps-route.sh exists and user wants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/configure-vps-route.sh" ]]; then
    read -p "Configure VPS route now? [y/N]: " configure_vps
    if [[ "$configure_vps" =~ ^[Yy]$ ]]; then
        read -p "Enter subdomain for $APP_NAME (e.g., photos): " subdomain
        read -p "Enter your domain (e.g., example.com): " domain
        
        if [[ -n "$subdomain" ]] && [[ -n "$domain" ]]; then
            info "Configuring VPS route..."
            bash "$SCRIPT_DIR/configure-vps-route.sh" "$APP_NAME" "$PROXY_PORT" "$subdomain" "$domain"
        fi
    fi
fi

exit 0
