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
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"
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

# Detect VPS Tailscale IP
VPS_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")

# Fetch service registry - support multiple methods
SERVICES=""
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

# Method 1: Check if file path provided as argument
if [[ -n "${1:-}" ]] && [[ -f "$1" ]]; then
    log_info "Loading service registry from file: $1"
    SERVICES=$(cat "$1")
# Method 2: Check if data provided via stdin (with timeout to avoid hanging)
elif [[ ! -t 0 ]]; then
    log_info "Checking for data on stdin..."
    # Try to read with 1 second timeout
    if SERVICES=$(timeout 1 cat 2>/dev/null) && [[ -n "$SERVICES" ]]; then
        log_info "Loaded service registry from stdin"
    else
        # No data on stdin, fall back to SSH
        log_info "No data on stdin, fetching from control plane via SSH..."
        SERVICES=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
            "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null" \
            2>/dev/null || echo "{}")
    fi
# Method 3: Fetch from control plane via SSH
else
    log_info "Fetching service registry from control plane..."
    SERVICES=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null" \
        2>/dev/null || echo "{}")
fi

if [[ "$SERVICES" == "{}" ]] || [[ -z "$SERVICES" ]]; then
    log_warn "No services found in registry"
    echo ""
    echo "Run this on control plane to populate registry:"
    echo "  sudo ./scripts/lib/service-registry.sh sync"
    exit 0
fi

# Check for multi-domain registry
MULTI_DOMAIN_ENABLED=false
DOMAIN_REGISTRY=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "sudo kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.routing\.json}' 2>/dev/null" \
    2>/dev/null || echo "{}")

if [[ "$DOMAIN_REGISTRY" != "{}" ]] && [[ -n "$DOMAIN_REGISTRY" ]]; then
    MULTI_DOMAIN_ENABLED=true
    log_info "Multi-domain routing enabled"
fi

# Filter for public services only
PUBLIC_SERVICES=$(echo "$SERVICES" | jq -r '
    to_entries[] |
    select(.value.public == true) |
    .value
' || echo "")

if [[ -z "$PUBLIC_SERVICES" ]]; then
    log_info "No public services configured"
    echo ""
    echo "To make a service public, register it with public=true:"
    echo "  service-registry.sh register <name> <subdomain> <namespace> <service> <port> true"
    exit 0
fi

# Generate Traefik routes
log_info "Generating Traefik routes..."

ROUTE_FILE="$TRAEFIK_CONFIG_DIR/mynodeone-routes.yml"
TEMP_FILE="/tmp/mynodeone-routes.yml"

cat > "$TEMP_FILE" << 'HEADER'
# MyNodeOne Routes - Auto-generated from service registry
# DO NOT EDIT MANUALLY - Changes will be overwritten
#
# To update routes:
#   1. Update service registry on control plane
#   2. Run: sudo ./scripts/sync-vps-routes.sh
#
HEADER

echo "Generated on: $(date)" >> "$TEMP_FILE"
echo "" >> "$TEMP_FILE"

if [[ "$MULTI_DOMAIN_ENABLED" == "true" ]] && [[ -n "$VPS_TAILSCALE_IP" ]]; then
    # Multi-domain mode: Use domain registry routing
    log_info "Generating multi-domain routes..."
    
    # Get routes for this VPS from control plane
    # Note: export-vps-routes already outputs "http:" and "routers:" headers
    ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh export-vps-routes $VPS_TAILSCALE_IP $CONTROL_PLANE_IP" >> "$TEMP_FILE" 2>/dev/null
    
else
    # Single-domain mode: Legacy behavior
    log_info "Generating single-domain routes..."
    
    # Add headers for single-domain mode
    echo "http:" >> "$TEMP_FILE"
    echo "  routers:" >> "$TEMP_FILE"
    
    echo "$PUBLIC_SERVICES" | jq -r --arg domain "$PUBLIC_DOMAIN" '
        .subdomain as $sub |
        (if $sub == "@" then "Host(`" + $domain + "`)" else "Host(`" + $sub + "." + $domain + "`)" end) as $host_rule |
        "    \($sub):",
        "      rule: \"\($host_rule)\"",
        "      service: \($sub)-service",
        "      entryPoints:",
        "        - websecure",
        "      tls:",
        "        certResolver: letsencrypt",
        "",
        "    \($sub)-http:",
        "      rule: \"\($host_rule)\"",
        "      service: \($sub)-service",
        "      entryPoints:",
        "        - web",
        "      middlewares:",
        "        - https-redirect",
        ""
    ' >> "$TEMP_FILE"

    echo "  services:" >> "$TEMP_FILE"

    echo "$PUBLIC_SERVICES" | jq -r '
        .subdomain as $sub |
        .ip as $service_ip |
        .port as $port |
        "    \($sub)-service:",
        "      loadBalancer:",
        "        servers:",
        "          - url: \"http://\($service_ip):\($port)\"",
        ""
    ' >> "$TEMP_FILE"

    echo "  middlewares:" >> "$TEMP_FILE"
    echo "    https-redirect:" >> "$TEMP_FILE"
    echo "      redirectScheme:" >> "$TEMP_FILE"
    echo "        scheme: https" >> "$TEMP_FILE"
    echo "        permanent: true" >> "$TEMP_FILE"
fi

# Validate generated routes
log_info "Validating generated routes..."

# Check if file exists
if [ ! -f "$TEMP_FILE" ]; then
    log_error "Route file was not generated!"
    exit 1
fi

# Check if file has content
if [ ! -s "$TEMP_FILE" ]; then
    log_error "Route file is empty!"
    exit 1
fi

log_success "Route file generated successfully"

# Validate YAML syntax if yq is available
if command -v yq &>/dev/null; then
    if yq eval "$TEMP_FILE" &>/dev/null; then
        log_success "YAML syntax is valid"
    else
        log_error "Generated routes have invalid YAML syntax!"
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
sudo mkdir -p "$TRAEFIK_CONFIG_DIR"
sudo cp "$TEMP_FILE" "$ROUTE_FILE"
sudo chmod 644 "$ROUTE_FILE"
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
    log_error "Traefik restart failed!"
    echo "--- Docker Compose Output ---"
    echo "$restart_output"
    echo "--- End Output ---"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check docker compose file: cat $TRAEFIK_DIR/docker-compose.yml"
    echo "  2. Check Traefik logs: docker logs traefik --tail 50"
    echo "  3. Manually restart: cd $TRAEFIK_DIR && docker compose restart"
    exit 1
fi

# Verify Traefik is running
log_info "Verifying Traefik status..."
sleep 3

if docker ps | grep -q traefik; then
    log_success "✓ Traefik container is running"
    
    # Get container status
    traefik_status=$(docker ps --filter "name=traefik" --format "{{.Status}}")
    log_info "  Status: $traefik_status"
else
    log_error "✗ Traefik container is NOT running!"
    echo ""
    echo "--- Docker PS ---"
    docker ps -a | grep traefik || echo "No Traefik container found"
    echo ""
    echo "--- Traefik Logs (last 50 lines) ---"
    docker logs traefik --tail 50 2>&1 || echo "Cannot get logs"
    echo "--- End Logs ---"
    exit 1
fi

# Verify routes were loaded (if Traefik API is accessible)
if curl -s http://localhost:8080/api/http/routers 2>/dev/null | jq -e 'length > 0' &>/dev/null; then
    route_count=$(curl -s http://localhost:8080/api/http/routers 2>/dev/null | jq 'length')
    log_success "✓ Traefik loaded $route_count routes"
else
    log_warn "⚠ Could not verify routes via Traefik API (API may not be exposed)"
    log_info "  This is normal if Traefik dashboard is not enabled"
fi

# Show configured routes
echo ""
log_success "VPS routes synced successfully!"
echo ""
echo "✅ Public services configured:"
echo "$PUBLIC_SERVICES" | jq -r --arg domain "$PUBLIC_DOMAIN" '
    "   • https://\(.subdomain).\($domain) → \(.ip):\(.port)"
'
echo ""

log_info "Next steps:"
echo "  1. Ensure DNS records point to this VPS"
echo "  2. Wait 5-10 minutes for SSL certificates"
echo "  3. Test access: curl -I https://subdomain.$PUBLIC_DOMAIN"
echo ""
