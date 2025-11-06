#!/bin/bash

###############################################################################
# VPS Route Sync Script
# 
# Fetches service registry from control plane and updates Traefik routes
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

# Load configuration
if [[ -f ~/.mynodeone/config.env ]]; then
    source ~/.mynodeone/config.env
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

# Fetch service registry from control plane
log_info "Fetching service registry from control plane..."

CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

SERVICES=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null" \
    2>/dev/null || echo "{}")

if [[ "$SERVICES" == "{}" ]] || [[ -z "$SERVICES" ]]; then
    log_warn "No services found in registry"
    echo ""
    echo "Run this on control plane to populate registry:"
    echo "  sudo ./scripts/lib/service-registry.sh sync"
    exit 0
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

# Generate HTTP routers and services
echo "http:" >> "$TEMP_FILE"
echo "  routers:" >> "$TEMP_FILE"

echo "$PUBLIC_SERVICES" | jq -r --arg domain "$PUBLIC_DOMAIN" '
    .subdomain as $sub |
    "    \($sub):",
    "      rule: \"Host(`\($sub).\($domain)`)\"",
    "      service: \($sub)-service",
    "      entryPoints:",
    "        - websecure",
    "      tls:",
    "        certResolver: letsencrypt",
    "",
    "    \($sub)-http:",
    "      rule: \"Host(`\($sub).\($domain)`)\"",
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
