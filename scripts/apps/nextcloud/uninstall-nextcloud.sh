#!/bin/bash

###############################################################################
# Nextcloud - Uninstallation Script
# 
# Removes Nextcloud from the cluster
###############################################################################

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Uninstalling Nextcloud${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${RED}WARNING: This will delete all files and data stored in Nextcloud!${NC}"
echo ""
read -p "Are you sure you want to uninstall? [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "Deleting PVCs..."
# Delete PVCs first to ensure proper cleanup (namespace deletion may leave them orphaned)
kubectl delete pvc -n nextcloud \
    nextcloud-data \
    nextcloud-postgres \
    --timeout=300s 2>/dev/null || echo "  ⚠ Some PVCs may not exist"

echo "Deleting Nextcloud namespace..."
kubectl delete namespace nextcloud --ignore-not-found=true --timeout=300s

echo ""
echo -e "${YELLOW}✓ Nextcloud uninstalled${NC}"
echo ""
