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
# Method 2: Check if data provided via stdin
elif [[ ! -t 0 ]]; then
    log_info "Loading service registry from stdin..."
    SERVICES=$(cat)
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

ROUTE_FILE="/etc/traefik/dynamic/mynodeone-routes.yml"
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

    echo "$PUBLIC_SERVICES" | jq -r --arg cp_ip "$CONTROL_PLANE_IP" '
        .subdomain as $sub |
        .port as $port |
        "    \($sub)-service:",
        "      loadBalancer:",
        "        servers:",
        "          - url: \"http://\($cp_ip):\($port)\"",
        ""
    ' >> "$TEMP_FILE"

    echo "  middlewares:" >> "$TEMP_FILE"
    echo "    https-redirect:" >> "$TEMP_FILE"
    echo "      redirectScheme:" >> "$TEMP_FILE"
    echo "        scheme: https" >> "$TEMP_FILE"
    echo "        permanent: true" >> "$TEMP_FILE"
fi

# Backup existing routes
if [[ -f "$ROUTE_FILE" ]]; then
    log_info "Backing up existing routes..."
    sudo cp "$ROUTE_FILE" "$ROUTE_FILE.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Install new routes
log_info "Installing new routes..."
sudo mkdir -p /etc/traefik/dynamic
sudo cp "$TEMP_FILE" "$ROUTE_FILE"
sudo chmod 644 "$ROUTE_FILE"
rm -f "$TEMP_FILE"

# Restart Traefik
log_info "Restarting Traefik..."
if cd /etc/traefik && sudo docker compose restart &>/dev/null; then
    log_success "Traefik restarted"
else
    log_error "Failed to restart Traefik"
    echo "  Manually restart: cd /etc/traefik && sudo docker compose restart"
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
