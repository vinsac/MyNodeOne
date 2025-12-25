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
echo "Deleting Nextcloud namespace..."
kubectl delete namespace nextcloud --ignore-not-found=true

echo ""
echo -e "${YELLOW}✓ Nextcloud uninstalled${NC}"
echo ""
echo "Note: PersistentVolumes may still exist in Longhorn."
echo "To completely remove storage, delete them manually from Longhorn UI."
echo ""
