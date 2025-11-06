#!/bin/bash

###############################################################################
# Post-Installation Routing Helper
# 
# Uses centralized service registry for DNS and routing
# Called by app install scripts
###############################################################################

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

# Parameters
APP_NAME="$1"
APP_PORT="$2"
SUBDOMAIN="$3"
NAMESPACE="${4:-$APP_NAME}"
SERVICE_NAME="${5:-${APP_NAME}-server}"
MAKE_PUBLIC="${6:-false}"

if [[ -z "$APP_NAME" ]] || [[ -z "$APP_PORT" ]] || [[ -z "$SUBDOMAIN" ]]; then
    echo "Usage: source post-install-routing.sh <app-name> <port> <subdomain> [namespace] [service-name] [public]"
    return 1
fi

# Load configuration
if [[ -f ~/.mynodeone/config.env ]]; then
    source ~/.mynodeone/config.env
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Registering Service: $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Register service in central registry
log_info "Registering in service registry..."

if bash "$SCRIPT_DIR/service-registry.sh" register \
    "$APP_NAME" "$SUBDOMAIN" "$NAMESPACE" "$SERVICE_NAME" "$APP_PORT" "$MAKE_PUBLIC" 2>&1; then
    log_success "Service registered in cluster"
else
    log_warn "Could not register service (kubectl may not be configured)"
fi

# 2. Update local DNS entries on control plane
log_info "Updating local DNS on this machine..."

DNS_ENTRIES=$(bash "$SCRIPT_DIR/service-registry.sh" export-dns "${CLUSTER_DOMAIN}.local" 2>/dev/null || echo "")

if [[ -n "$DNS_ENTRIES" ]]; then
    # Backup /etc/hosts
    sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # Remove old MyNodeOne entries
    sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts 2>/dev/null || true
    
    # Add new entries
    {
        echo ""
        echo "$DNS_ENTRIES"
        echo ""
    } | sudo tee -a /etc/hosts > /dev/null
    
    log_success "Local DNS updated"
fi

# 3. Show access URLs
echo ""
echo "✅ Service registered successfully!"
echo ""
echo "Access via:"
echo "   • Local: http://${SUBDOMAIN}.${CLUSTER_DOMAIN}.local"

if [[ -n "$PUBLIC_DOMAIN" ]] && [[ "$MAKE_PUBLIC" == "true" ]]; then
    echo "   • Public: https://${SUBDOMAIN}.${PUBLIC_DOMAIN} (after sync)"
fi

echo ""

# 4. Show sync instructions
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📡 Sync to Other Machines"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "To access from management laptops:"
echo "  cd ~/MyNodeOne && sudo ./scripts/sync-dns.sh"
echo ""

if [[ -n "$PUBLIC_DOMAIN" ]] && [[ -n "${VPS_EDGE_IP:-}" ]]; then
    log_info "To enable public access via VPS:"
    echo "  SSH to VPS: ssh root@${VPS_EDGE_IP}"
    echo "  cd ~/MyNodeOne && sudo ./scripts/sync-vps-routes.sh"
    echo ""
    
    if [[ "$MAKE_PUBLIC" != "true" ]]; then
        log_warn "Service is not marked as public"
        echo "  To make public, run on control plane:"
        echo "  sudo ./scripts/lib/service-registry.sh register \\"
        echo "    $APP_NAME $SUBDOMAIN $NAMESPACE $SERVICE_NAME $APP_PORT true"
        echo ""
    fi
elif [[ -z "$PUBLIC_DOMAIN" ]]; then
    log_info "To enable public access:"
    echo "  1. Add PUBLIC_DOMAIN=\"yourdomain.com\" to ~/.mynodeone/config.env"
    echo "  2. Set up VPS edge node (if not done): sudo ./scripts/mynodeone"
    echo "  3. Run sync on VPS: sudo ./scripts/sync-vps-routes.sh"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
