#!/bin/bash

###############################################################################
# Install MyNodeOne Config API Server
#
# This script installs the Config API Server on the control plane.
# The API server provides configuration to nodes via HTTP instead of SSH.
#
# Usage:
#   sudo ./scripts/installation/install-config-api.sh
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/project-root.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MyNodeOne Config API Server Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v go &>/dev/null; then
    log_info "Installing Go..."
    
    # Download and install Go
    GO_VERSION="1.21.5"
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
    
    # Add to PATH for this session
    export PATH=$PATH:/usr/local/go/bin
    
    log_success "Go $GO_VERSION installed"
fi

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl not found. Is this a control plane?"
    exit 1
fi

# Create config directory
log_info "Creating config directory..."
mkdir -p /etc/mynodeone
chmod 700 /etc/mynodeone

# Generate API token if not exists
TOKEN_FILE="/etc/mynodeone/api-token"
if [[ ! -f "$TOKEN_FILE" ]]; then
    log_info "Generating API token..."
    openssl rand -hex 32 > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    log_success "API token generated: $TOKEN_FILE"
else
    log_info "API token already exists"
fi

# Build the API server
log_info "Building Config API Server..."
cd "$PROJECT_ROOT"

# Initialize go modules if needed
if [[ ! -f "go.sum" ]]; then
    /usr/local/go/bin/go mod tidy 2>/dev/null || true
fi

# Build
/usr/local/go/bin/go build -o /usr/local/bin/mynodeone-config-api ./cmd/config-api/

chmod +x /usr/local/bin/mynodeone-config-api
log_success "Binary installed: /usr/local/bin/mynodeone-config-api"

# Install systemd service
log_info "Installing systemd service..."
cp "$PROJECT_ROOT/scripts/lib/mynodeone-config-api.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable mynodeone-config-api

# Start the service
log_info "Starting Config API Server..."
systemctl start mynodeone-config-api

# Wait for startup
sleep 2

# Verify it's running
if systemctl is-active --quiet mynodeone-config-api; then
    log_success "Config API Server is running"
else
    log_error "Failed to start Config API Server"
    journalctl -u mynodeone-config-api -n 20 --no-pager
    exit 1
fi

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")

# Test the API
log_info "Testing API..."
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8443/api/v1/health" | grep -q "200"; then
    log_success "API health check passed"
else
    log_warn "API health check failed (may need a moment to start)"
fi

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Config API Server is running on port 8443"
echo ""
echo "API Endpoints:"
echo "  GET  http://${TAILSCALE_IP}:8443/api/v1/health"
echo "  GET  http://${TAILSCALE_IP}:8443/api/v1/config/{type}"
echo "  POST http://${TAILSCALE_IP}:8443/api/v1/heartbeat"
echo "  GET  http://${TAILSCALE_IP}:8443/api/v1/nodes"
echo ""
echo "API Token: $(cat $TOKEN_FILE)"
echo ""
echo "Next Steps:"
echo "  1. Install node agent on other machines:"
echo "     sudo ./scripts/installation/install-node-agent.sh"
echo ""
echo "  2. View logs:"
echo "     journalctl -u mynodeone-config-api -f"
echo ""
echo "  3. Check node status:"
echo "     curl -H 'X-API-Token: $(cat $TOKEN_FILE)' http://${TAILSCALE_IP}:8443/api/v1/nodes"
echo ""
