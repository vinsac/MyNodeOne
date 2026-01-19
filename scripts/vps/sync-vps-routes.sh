#!/bin/bash

###############################################################################
# VPS Route Sync Script - Enterprise Multi-Domain Support
# 
# Fetches service registry and domain routing from control plane
# Supports multiple domains and VPS nodes with load balancing
# Run this on VPS edge nodes to sync routing configuration
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

# Detect actual user and home directory (even when run with sudo)
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

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
TRAEFIK_CONFIG_DIR="${TRAEFIK_CONFIG_DIR:-$ACTUAL_HOME/traefik/config}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌍 Syncing VPS Routes from Control Plane"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Validate configuration
if [[ -z "$CONTROL_PLANE_IP" ]]; then
    log_error "CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"
    exit 1
fi

if [[ -z "$PUBLIC_DOMAIN" ]]; then
    log_warn "PUBLIC_DOMAIN not set in ~/.mynodeone/config.env"
    echo ""
    echo "Add this to ~/.mynodeone/config.env:"
    echo "  PUBLIC_DOMAIN=\"yourdomain.com\""
    echo ""
    exit 1
fi

log_info "Control Plane: $CONTROL_PLANE_IP"
log_info "Public Domain: $PUBLIC_DOMAIN"
echo ""

# Read API Token from standard location if not set
if [[ -z "${API_TOKEN:-}" ]] && [[ -f "/etc/mynodeone/api-token" ]]; then
    API_TOKEN=$(cat /etc/mynodeone/api-token)
fi

# Detect VPS Tailscale IP
VPS_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

log_info "Control Plane: $CONTROL_PLANE_IP"
log_info "Public Domain: $PUBLIC_DOMAIN"
log_info "VPS IP: $VPS_TAILSCALE_IP"
echo ""

# Ignore stdin input (legacy push)
if [[ ! -t 0 ]]; then
    # consume stdin to avoid broken pipe issues
    cat >/dev/null
fi

# Generate Traefik routes
log_info "Fetching Traefik routes from Config API..."

ROUTE_FILE="$TRAEFIK_CONFIG_DIR/mynodeone-routes.yml"
TEMP_FILE="/tmp/mynodeone-routes.yml"

# Ensure directory exists
if [[ ! -d "$TRAEFIK_CONFIG_DIR" ]]; then
    sudo mkdir -p "$TRAEFIK_CONFIG_DIR"
    sudo chmod 755 "$TRAEFIK_CONFIG_DIR"
fi

# Build URL
API_PORT="${API_PORT:-8443}"
URL="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/config/vps/traefik-config"

# Fetch config
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TEMP_FILE" \
    -H "X-API-Token: ${API_TOKEN:-}" \
    -H "X-Node-Name: $(hostname)" \
    "$URL" || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "Failed to fetch routes from $URL (HTTP $HTTP_CODE)"
    log_info "Check if Config API is running and reachable via Tailscale."
    rm -f "$TEMP_FILE"
    exit 1
fi

# Validate generated routes
log_info "Validating generated routes..."

# Check if file has content
if [ ! -s "$TEMP_FILE" ]; then
    log_error "Route file is empty"
    exit 1
fi

log_success "Route file downloaded successfully"

# Validate YAML syntax if yq is available
if command -v yq &>/dev/null; then
    if yq eval "$TEMP_FILE" &>/dev/null; then
        log_success "YAML syntax is valid"
    else
        log_error "Generated routes have invalid YAML syntax"
        echo "--- Invalid YAML ---"
        cat "$TEMP_FILE"
        echo "--- End ---"
        rm -f "$TEMP_FILE"
        exit 1
    fi
else
    log_warn "yq not installed, skipping YAML validation"
fi

# Backup existing routes
if [[ -f "$ROUTE_FILE" ]]; then
    log_info "Backing up existing routes..."
    sudo cp "$ROUTE_FILE" "$ROUTE_FILE.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Install new routes
log_info "Installing new routes..."
# Fix ownership if needed (match directory owner)
DIR_OWNER=$(stat -c '%U' "$TRAEFIK_CONFIG_DIR" 2>/dev/null || echo "root")
DIR_GROUP=$(stat -c '%G' "$TRAEFIK_CONFIG_DIR" 2>/dev/null || echo "root")

sudo cp "$TEMP_FILE" "$ROUTE_FILE"
sudo chmod 644 "$ROUTE_FILE"

if [[ "$DIR_OWNER" != "root" ]]; then
    sudo chown "${DIR_OWNER}:${DIR_GROUP}" "$ROUTE_FILE" 2>/dev/null || true
fi

rm -f "$TEMP_FILE"

log_success "Routes installed to $ROUTE_FILE"

# Restart Traefik
log_info "Restarting Traefik..."
TRAEFIK_DIR="$ACTUAL_HOME/traefik"

# Capture docker compose output
restart_output=""
if restart_output=$(cd "$TRAEFIK_DIR" && sudo -u "$ACTUAL_USER" docker compose restart 2>&1); then
    log_success "Traefik restart command succeeded"
else
    # Check if Traefik is running first, maybe docker compose is not needed if it's strictly a reload
    # But this script claims to restart.
    log_warn "Traefik restart failed or docker compose not found. Assuming auto-reload or manual restart needed."
fi

# Verify Traefik is running
log_info "Verifying Traefik status..."
sleep 3

if command -v docker &>/dev/null && docker ps | grep -q traefik; then
    log_success "✓ Traefik container is running"
    
    # Get container status
    traefik_status=$(docker ps --filter "name=traefik" --format "{{.Status}}")
    log_info "  Status: $traefik_status"
else
    log_warn "Could not verify Traefik status (docker not found or container not running)"
fi

# Verify routes were loaded (if Traefik API is accessible)
if curl -s http://localhost:8080/api/http/routers 2>/dev/null | jq -e 'length > 0' &>/dev/null; then
    route_count=$(curl -s http://localhost:8080/api/http/routers 2>/dev/null | jq 'length')
    log_success "✓ Traefik loaded $route_count routes"
else
    log_warn "⚠ Could not verify routes via Traefik API (API may not be exposed)"
    log_info "  This is normal if Traefik dashboard is not enabled"
fi

echo ""
log_success "VPS routes synced successfully"
log_info "Routes are now managed by Config API (Go)"
echo ""

log_info "Next steps:"
echo "  1. Test access: curl -I https://subdomain.$PUBLIC_DOMAIN"
echo ""
