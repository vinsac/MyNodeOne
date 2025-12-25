#!/bin/bash

###############################################################################
# Immich - Uninstall Script
# 
# Removes Immich and all associated resources
###############################################################################

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="immich"

echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Uninstalling Immich${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}WARNING: This will delete all photos and data!${NC}"
echo ""
read -p "Are you sure you want to uninstall Immich? [y/N]: " confirm

if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "🗑️  Removing Immich namespace and all resources..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

echo ""
echo "✓ Immich uninstalled successfully"
echo ""
