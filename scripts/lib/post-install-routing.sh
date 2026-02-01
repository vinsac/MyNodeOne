#!/bin/bash

###############################################################################
# Post-Installation Routing Helper - Clean Separation Architecture
# 
# Simplified version that only handles local DNS registration.
# Public routing is handled exclusively through manage-app-visibility.sh
#
# Usage: source post-install-routing.sh <app-name> <port> <local-name> [namespace] [service-name] [public]
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
LOCAL_NAME="$3"  # Local DNS name for clean separation
NAMESPACE="${4:-$APP_NAME}"
SERVICE_NAME="${5:-${APP_NAME}-server}"
MAKE_PUBLIC="${6:-false}"

if [[ -z "$APP_NAME" ]] || [[ -z "$APP_PORT" ]] || [[ -z "$LOCAL_NAME" ]]; then
    echo "Usage: source post-install-routing.sh <app-name> <port> <local-name> [namespace] [service-name] [public]"
    return 1
fi

if [[ "$BASH_SOURCE" == "$0" ]]; then
    echo "This is a library script. Please source it or call specific functions."
    exit 1
fi

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

# Load project root and environment
POST_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$POST_INSTALL_DIR/../lib/project-root.sh" 2>/dev/null || source "$POST_INSTALL_DIR/../../scripts/lib/project-root.sh" 2>/dev/null

# Load cluster domain
if [ -z "${CLUSTER_DOMAIN:-}" ]; then
    # Try to find user's config.env
    for user_config in ~/.mynodeone/config.env /home/*/.mynodeone/config.env /root/.mynodeone/config.env; do
        if [[ -f "$user_config" ]]; then
            DETECTED_DOMAIN=$(grep '^CLUSTER_DOMAIN=' "$user_config" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
            if [[ -n "$DETECTED_DOMAIN" ]]; then
                CLUSTER_DOMAIN="$DETECTED_DOMAIN"
                break
            fi
        fi
    done
fi

# Final fallback
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Registering Service: $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Register in service registry
echo ""
log_info "Registering in service registry..."

if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
    "$APP_NAME" "$LOCAL_NAME" "$NAMESPACE" "$SERVICE_NAME" "$APP_PORT" "$MAKE_PUBLIC" 2>&1; then
    log_success "Service registered in cluster"
else
    log_warn "Could not register service (kubectl may not be configured)"
fi

# 2. Update local DNS entries on control plane
log_info "Updating local DNS on this machine..."

DNS_ENTRIES=$(bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" export-dns "${CLUSTER_DOMAIN}.local" 2>/dev/null || echo "")

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
    log_info "Access your app locally: http://${LOCAL_NAME}.${CLUSTER_DOMAIN}.local"
else
    log_warn "Could not update local DNS (kubectl may not be configured)"
fi

# 3. Show access information
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Service Registered Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Local Access:"
echo "  • http://${LOCAL_NAME}.${CLUSTER_DOMAIN}.local"
echo ""
echo "Public Access:"
echo "  • To make this app publicly accessible, run:"
echo "    sudo ./scripts/operations/manage-app-visibility.sh"
echo ""
echo "This supports:"
echo "  • Root domains (e.g., curiios.com)"
echo "  • WWW domains (e.g., www.curiios.com)"  
echo "  • Subdomains (e.g., app.curiios.com)"
echo ""
echo "Clean Separation Architecture:"
echo "  • Local DNS: Uses local_name field only"
echo "  • Public Routing: Configured separately via manage-app-visibility.sh"
echo "  • No Cross-Contamination: Independent systems"
echo ""
