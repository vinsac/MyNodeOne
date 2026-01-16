#!/bin/bash

###############################################################################
# Enforce Prerequisites Before VPS/Management Installation
#
# This script MUST pass before VPS or management laptop installation.
# It ensures all prerequisites are properly configured.
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

NODE_TYPE="$1"
CONTROL_PLANE_IP="${2:-}"
SSH_USER="${3:-$(whoami)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/project-root.sh"

# Source preflight checks
source "$PROJECT_ROOT/scripts/lib/preflight-checks.sh"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ⚠️  MANDATORY PREREQUISITE VERIFICATION ⚠️${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}This verification MUST pass before installation can proceed.${NC}"
echo -e "${YELLOW}If any checks fail, you MUST fix them before continuing.${NC}"
echo ""

# Run pre-flight checks
if run_preflight_checks "$NODE_TYPE" "$CONTROL_PLANE_IP" "$SSH_USER"; then
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  ✅ ALL PREREQUISITES VERIFIED ✅${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${GREEN}You may now proceed with installation.${NC}"
    echo ""
    exit 0
else
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}  ❌ PREREQUISITES NOT MET ❌${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${RED}${BOLD}INSTALLATION CANNOT PROCEED!${NC}"
    echo ""
    echo -e "${YELLOW}Common fixes:${NC}"
    echo ""
    
    if [ "$NODE_TYPE" = "vps" ]; then
        echo -e "  ${BOLD}1. Passwordless Sudo (Most Common Issue):${NC}"
        echo "     ssh $SSH_USER@$CONTROL_PLANE_IP"
        echo "     cd ~/MyNodeOne"
        echo "     sudo ./scripts/setup/setup-control-plane-sudo.sh"
        echo ""
        echo -e "  ${BOLD}2. SSH Key Setup:${NC}"
        echo "     ssh-copy-id $SSH_USER@$CONTROL_PLANE_IP"
        echo ""
        echo -e "  ${BOLD}3. Tailscale:${NC}"
        echo "     sudo tailscale up"
        echo ""
    fi
    
    echo -e "${CYAN}📖 Full prerequisite guide:${NC}"
    echo "   docs/INSTALLATION_PREREQUISITES.md"
    echo ""
    echo -e "${CYAN}🔍 Run diagnostics:${NC}"
    echo "   ./scripts/utils/check-prerequisites.sh $NODE_TYPE $CONTROL_PLANE_IP"
    echo ""
    
    exit 1
fi
