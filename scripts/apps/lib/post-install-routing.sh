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

echo "" >&2
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
echo -e "${BLUE}  Public Access Configuration${NC}" >&2
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
echo "" >&2
echo "Would you like to make ${APP_NAME} accessible from the internet?" >&2
echo "" >&2
echo -e "  ${GREEN}Public access enables:${NC}" >&2
echo "  • Access from any device on any network" >&2
echo "  • Use from mobile devices outside your home" >&2
echo "" >&2

if [ -n "$CONFIGURED_DOMAINS" ]; then
    echo -e "  ${GREEN}Your configured domain(s):${NC} $CONFIGURED_DOMAINS" >&2
    echo "  Public URL will be: ${APP_SUBDOMAIN}.${CONFIGURED_DOMAINS%%,*}" >&2
else
    echo -e "  ${YELLOW}No public domains configured yet.${NC}" >&2
    echo "  Run: sudo $PROJECT_ROOT/scripts/add-domain.sh" >&2
fi
echo "" >&2
echo "  You can change this later by running:" >&2
echo "  sudo $PROJECT_ROOT/scripts/manage-app-visibility.sh" >&2
echo "" >&2

read -p "Make ${APP_NAME} publicly accessible? [y/N]: " MAKE_PUBLIC < /dev/tty

if [[ "${MAKE_PUBLIC,,}" == "y" || "${MAKE_PUBLIC,,}" == "yes" ]]; then
    echo ""
    
    if [[ -f "$PROJECT_ROOT/scripts/manage-app-visibility.sh" ]]; then
        echo "Launching interactive public access configuration..."
        echo "You'll be able to select which domains and VPS nodes to use."
        echo ""
        
        # Run in full interactive mode so user can choose domains and VPS nodes
        # This handles multiple domains/VPS gracefully
        sudo bash "$PROJECT_ROOT/scripts/manage-app-visibility.sh"
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
