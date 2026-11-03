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
# Private to this run: a fixed name in /tmp can be pre-created by any local user.
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

# Ensure directory exists
if [[ ! -d "$TRAEFIK_CONFIG_DIR" ]]; then
    sudo mkdir -p "$TRAEFIK_CONFIG_DIR"
    sudo chmod 755 "$TRAEFIK_CONFIG_DIR"
fi

# Build URL
API_PORT="${API_PORT:-8443}"
URL="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/config/vps/traefik-config"

# Fetch config. The token goes through a config stream so it stays out of `ps`.
HTTP_CODE=$(curl -s --connect-timeout 10 --max-time 60 -w "%{http_code}" -o "$TEMP_FILE" \
    -K <(printf 'header = "X-API-Token: %s"\n' "${API_TOKEN:-}") \
    -H "X-Node-Name: $(hostname)" \
    "$URL") || HTTP_CODE="000"

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "Failed to fetch routes from $URL (HTTP $HTTP_CODE)"
    log_info "Check if Config API is running and reachable via Tailscale."
    exit 1
fi

# Validate generated routes
log_info "Validating generated routes..."

# Check if file has content
if [ ! -s "$TEMP_FILE" ]; then
    log_error "Route file is empty; keeping the current routes"
    exit 1
fi

# Every config the API renders has a top-level http: block. Anything else, such as
# an error page from a proxy, must not reach Traefik.
if ! grep -q '^http:' "$TEMP_FILE"; then
    log_error "Response is not a Traefik route file; keeping the current routes"
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
        exit 1
    fi
else
    log_warn "yq not installed, skipping YAML validation"
fi

count_routes() {
    grep -c 'Host(`' "$1" 2>/dev/null || true
}

# The timestamp header changes on every render, so ignore it when comparing.
routes_unchanged() {
    [[ -f "$ROUTE_FILE" ]] &&
        cmp -s <(grep -v '^# Generated:' "$ROUTE_FILE") <(grep -v '^# Generated:' "$TEMP_FILE")
}

NEW_ROUTES=$(count_routes "$TEMP_FILE")
OLD_ROUTES=0
if [[ -f "$ROUTE_FILE" ]]; then
    OLD_ROUTES=$(count_routes "$ROUTE_FILE")
fi

# An older config API answers 200 with an empty config when it can't read the
# registry, so from one of those an empty answer can't be told from a real one.
# Schema 2 servers answer 503 instead, which makes their empty answer trustworthy.
if ((NEW_ROUTES == 0 && OLD_ROUTES > 0)); then
    API_SCHEMA=$(curl -fsS --connect-timeout 5 --max-time 10 \
        "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/health" 2>/dev/null |
        jq -r '.registry_schema // 0' 2>/dev/null) || API_SCHEMA=""
    if ! [[ "$API_SCHEMA" =~ ^[0-9]+$ ]] || ((API_SCHEMA < 2)); then
        log_error "Config API returned no routes but this VPS has $OLD_ROUTES, and the API"
        log_error "is too old to confirm that (registry_schema '${API_SCHEMA:-unknown}'). Keeping the current routes."
        log_info "Upgrade the control plane's Config API: scripts/installation/install-config-api.sh"
        exit 1
    fi
    log_warn "Removing all $OLD_ROUTES public routes: the Config API confirms there are none"
fi

if routes_unchanged; then
    log_success "Routes unchanged, nothing to install"
else
    # Backup existing routes. Traefik's file provider only loads .yml, .yaml and
    # .toml, so these don't become live config.
    if [[ -f "$ROUTE_FILE" ]]; then
        log_info "Backing up existing routes..."
        sudo cp -p "$ROUTE_FILE" "$ROUTE_FILE.backup.$(date +%Y%m%d_%H%M%S)"
        # This runs on every change, so keep only the newest few.
        # Timestamped names contain no whitespace, so ls is safe here.
        # shellcheck disable=SC2012
        ls -1t "$ROUTE_FILE".backup.* 2>/dev/null | tail -n +6 | while read -r old_backup; do
            sudo rm -f "$old_backup"
        done
    fi

    # Install new routes
    log_info "Installing new routes..."
    # Fix ownership if needed (match directory owner)
    DIR_OWNER=$(stat -c '%U' "$TRAEFIK_CONFIG_DIR" 2>/dev/null || echo "root")
    DIR_GROUP=$(stat -c '%G' "$TRAEFIK_CONFIG_DIR" 2>/dev/null || echo "root")

    # Stage beside the target and rename, so Traefik's file watcher never sees a
    # half-written file. The name has no .yml suffix, so Traefik doesn't load it.
    STAGED=$(sudo mktemp "$TRAEFIK_CONFIG_DIR/.mynodeone-routes.XXXXXX")
    if ! sudo cp "$TEMP_FILE" "$STAGED" || ! sudo chmod 644 "$STAGED"; then
        sudo rm -f "$STAGED"
        log_error "Could not write to $TRAEFIK_CONFIG_DIR; the current routes are unchanged"
        exit 1
    fi
    if [[ "$DIR_OWNER" != "root" ]]; then
        sudo chown "${DIR_OWNER}:${DIR_GROUP}" "$STAGED" 2>/dev/null || true
    fi
    if ! sudo mv -f "$STAGED" "$ROUTE_FILE"; then
        sudo rm -f "$STAGED"
        log_error "Could not install $ROUTE_FILE; the current routes are unchanged"
        exit 1
    fi

    log_success "Routes installed to $ROUTE_FILE"
fi

if ((NEW_ROUTES == 0)); then
    log_info "No public services configured"
fi

# Traefik's file provider runs with watch: true (see setup-vps-node.sh) and picks
# the file up by itself. A restart here would drop every public connection, so only
# start Traefik if it isn't running.
log_info "Verifying Traefik status..."
TRAEFIK_DIR="$ACTUAL_HOME/traefik"

traefik_running() {
    command -v docker &>/dev/null && docker ps --filter "name=traefik" --format "{{.Names}}" | grep -q traefik
}

if ! traefik_running; then
    log_warn "Traefik is not running, starting it..."
    if (cd "$TRAEFIK_DIR" && sudo -u "$ACTUAL_USER" docker compose up -d) &>/dev/null; then
        sleep 3
    else
        log_warn "Could not start Traefik from $TRAEFIK_DIR"
    fi
fi

if traefik_running; then
    log_success "✓ Traefik container is running"

    # Get container status
    traefik_status=$(docker ps --filter "name=traefik" --format "{{.Status}}")
    log_info "  Status: $traefik_status"
else
    log_warn "Could not verify Traefik status (docker not found or container not running)"
fi

# Verify routes were loaded (if Traefik API is accessible)
if curl -s --max-time 5 http://localhost:8080/api/http/routers 2>/dev/null | jq -e 'length > 0' &>/dev/null; then
    route_count=$(curl -s --max-time 5 http://localhost:8080/api/http/routers 2>/dev/null | jq 'length')
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
