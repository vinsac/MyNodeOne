#!/bin/bash

###############################################################################
# Post-Installation Routing Helper
# 
# Automatically configures VPS routes and DNS after app installation
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

if [[ -z "$APP_NAME" ]] || [[ -z "$APP_PORT" ]] || [[ -z "$SUBDOMAIN" ]]; then
    echo "Usage: source post-install-routing.sh <app-name> <port> <subdomain> [namespace] [service-name]"
    return 1
fi

# Load configuration
if [[ -f ~/.mynodeone/config.env ]]; then
    source ~/.mynodeone/config.env
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Configuring Access for $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check if VPS edge node exists and has domain configured
VPS_CONFIGURED=false
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"

if [[ -n "${VPS_EDGE_IP:-}" ]] && [[ -n "$PUBLIC_DOMAIN" ]]; then
    VPS_CONFIGURED=true
    log_info "VPS edge node detected with domain: $PUBLIC_DOMAIN"
fi

# 2. If VPS is configured, auto-setup routing
if [[ "$VPS_CONFIGURED" == "true" ]]; then
    echo ""
    log_info "Automatically configuring public access..."
    log_info "  Public URL: https://${SUBDOMAIN}.${PUBLIC_DOMAIN}"
    echo ""
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    if [[ -x "$SCRIPT_DIR/../configure-vps-route.sh" ]]; then
        # Call configure-vps-route.sh with proper parameters
        if bash "$SCRIPT_DIR/../configure-vps-route.sh" "$APP_NAME" "$APP_PORT" "$SUBDOMAIN" "$PUBLIC_DOMAIN" "$NAMESPACE/$SERVICE_NAME" 2>&1; then
            log_success "Public access configured!"
            echo ""
            echo "✅ $APP_NAME is now accessible at:"
            echo "   • Public: https://${SUBDOMAIN}.${PUBLIC_DOMAIN}"
            echo "   • Local: http://${SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
            echo ""
        else
            log_warn "Auto-configuration failed"
            echo ""
            echo "To configure manually:"
            echo "  sudo ./scripts/configure-vps-route.sh $APP_NAME $APP_PORT $SUBDOMAIN $PUBLIC_DOMAIN"
            echo ""
        fi
    else
        log_warn "VPS route script not found"
    fi
else
    # VPS not configured or no domain
    if [[ -n "${VPS_EDGE_IP:-}" ]]; then
        # VPS exists but no domain configured
        echo ""
        log_info "VPS edge node detected but no public domain configured"
        echo ""
        echo "To enable public access:"
        echo "  1. Add PUBLIC_DOMAIN=\"yourdomain.com\" to ~/.mynodeone/config.env"
        echo "  2. Run: sudo ./scripts/configure-vps-route.sh $APP_NAME $APP_PORT $SUBDOMAIN yourdomain.com"
        echo ""
    else
        # No VPS
        echo ""
        log_info "No VPS edge node configured - local access only"
        echo ""
        echo "To enable public access:"
        echo "  1. Set up VPS edge node: sudo ./scripts/mynodeone"
        echo "  2. Configure domain in ~/.mynodeone/config.env"
        echo "  3. Run: sudo ./scripts/configure-vps-route.sh $APP_NAME $APP_PORT $SUBDOMAIN yourdomain.com"
        echo ""
    fi
fi

# 3. Auto-update management laptops DNS (if script exists)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -x "$SCRIPT_DIR/../update-laptop-dns.sh" ]]; then
    echo ""
    log_info "Updating local DNS entries..."
    
    if bash "$SCRIPT_DIR/../update-laptop-dns.sh" &>/dev/null; then
        log_success "Local DNS updated"
        echo "   Access locally at: http://${SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
    else
        log_warn "Could not auto-update local DNS"
        echo "   Run manually: sudo ./scripts/update-laptop-dns.sh"
    fi
fi

echo ""
log_success "Configuration complete!"
echo ""
