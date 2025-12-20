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

# Get configured domains from cluster
CONFIGURED_DOMAINS=""
if command -v kubectl &> /dev/null; then
    CONFIGURED_DOMAINS=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r '.domains | keys[]' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Public Access Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Would you like to make ${APP_NAME} accessible from the internet?"
echo ""
echo -e "  ${GREEN}Public access enables:${NC}"
echo "  • Access from any device on any network"
echo "  • Use from mobile devices outside your home"
echo ""

if [ -n "$CONFIGURED_DOMAINS" ]; then
    echo -e "  ${GREEN}Your configured domain(s):${NC} $CONFIGURED_DOMAINS"
    echo "  Public URL will be: ${APP_SUBDOMAIN}.${CONFIGURED_DOMAINS%%,*}"
else
    echo -e "  ${YELLOW}No public domains configured yet.${NC}"
    echo "  Run: sudo $PROJECT_ROOT/scripts/add-domain.sh"
fi
echo ""
echo "  You can change this later by running:"
echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
echo ""

read -p "Make ${APP_NAME} publicly accessible? [y/N]: " MAKE_PUBLIC

if [[ "${MAKE_PUBLIC,,}" == "y" || "${MAKE_PUBLIC,,}" == "yes" ]]; then
    echo ""
    echo "🌐 Configuring public access..."
    
    if [[ -f "$PROJECT_ROOT/scripts/manage-app-visibility.sh" ]]; then
        # Get domains and VPS nodes from cluster config
        DOMAINS=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
            jq -r '.domains | keys | join(",")' 2>/dev/null || echo "")
        
        VPS_NODES=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
            jq -r '.vps_nodes[].tailscale_ip' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
        
        if [ -z "$DOMAINS" ] || [ -z "$VPS_NODES" ]; then
            echo -e "${YELLOW}⚠️  No domains or VPS nodes configured yet.${NC}"
            echo "Run the full interactive setup:"
            echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
            echo ""
        else
            echo "  Using domain(s): $DOMAINS"
            echo "  Using VPS node(s): $VPS_NODES"
            echo ""
            
            # Run visibility manager with full config
            sudo bash "$PROJECT_ROOT/scripts/manage-app-visibility.sh" public "$APP_NAME" "$DOMAINS" "$VPS_NODES"
            
            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}✓ Public access configured!${NC}"
                echo ""
                # Show actual URLs
                FIRST_DOMAIN="${DOMAINS%%,*}"
                echo "Your app is now available at:"
                echo -e "  ${GREEN}• https://${APP_SUBDOMAIN}.${FIRST_DOMAIN}${NC}"
                echo ""
                echo "Note: SSL certificate may take 30-60 seconds to be issued."
            else
                echo -e "${YELLOW}⚠️  Could not configure public access automatically.${NC}"
                echo "Run the interactive mode to troubleshoot:"
                echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh"
            fi
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
