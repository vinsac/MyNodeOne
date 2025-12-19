#!/bin/bash
###############################################################################
# Post-Install Routing Configuration
# 
# This script is sourced at the end of app installation scripts to:
# 1. Prompt user about making the app publicly accessible
# 2. Call manage-app-visibility.sh to configure routing
#
# Usage: source post-install-routing.sh <app_name> <port> <subdomain> <namespace> <service>
###############################################################################

APP_NAME="${1:-unknown}"
APP_PORT="${2:-80}"
APP_SUBDOMAIN="${3:-$APP_NAME}"
APP_NAMESPACE="${4:-default}"
APP_SERVICE="${5:-$APP_NAME}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Get script directory
POST_INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "$POST_INSTALL_DIR")")")"

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Public Access Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Would you like to make ${APP_NAME} accessible from the internet?"
echo ""
echo "  ${GREEN}Public access enables:${NC}"
echo "  • Access from any device on any network"
echo "  • Share with friends and family"
echo "  • Use from mobile devices outside your home"
echo ""
echo "  ${YELLOW}Requirements for public access:${NC}"
echo "  • A domain name configured with Cloudflare"
echo "  • Cloudflare tunnel or similar ingress configured"
echo ""
echo "  You can change this later by running:"
echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
echo ""

read -p "Make ${APP_NAME} publicly accessible? [y/N]: " MAKE_PUBLIC

if [[ "${MAKE_PUBLIC,,}" == "y" || "${MAKE_PUBLIC,,}" == "yes" ]]; then
    echo ""
    echo "🌐 Configuring public access..."
    
    if [[ -f "$PROJECT_ROOT/scripts/manage-app-visibility.sh" ]]; then
        # Run the visibility manager in public mode
        sudo bash "$PROJECT_ROOT/scripts/manage-app-visibility.sh" \
            --app "$APP_NAME" \
            --namespace "$APP_NAMESPACE" \
            --service "$APP_SERVICE" \
            --port "$APP_PORT" \
            --public 2>/dev/null
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Public access configured!${NC}"
            echo ""
            echo "Your app will be available at your configured domain."
            echo "Check your Cloudflare dashboard for the public URL."
        else
            echo -e "${YELLOW}⚠️  Could not configure public access automatically.${NC}"
            echo "Run this command later to configure:"
            echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
        fi
    else
        echo -e "${YELLOW}⚠️  manage-app-visibility.sh not found${NC}"
        echo "Public access will need to be configured manually."
    fi
else
    echo ""
    echo "ℹ️  App will be accessible only on your local network."
    echo "   To enable public access later, run:"
    echo "   sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
fi

echo ""
