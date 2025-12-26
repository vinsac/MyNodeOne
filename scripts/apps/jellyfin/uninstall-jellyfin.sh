#!/bin/bash

###############################################################################
# Jellyfin - Uninstall Script
# 
# Removes Jellyfin and optionally deletes all media and data
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="jellyfin"

echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Uninstall Jellyfin Media Server${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}Jellyfin is not installed (namespace not found)${NC}"
    exit 0
fi

echo -e "${YELLOW}⚠️  WARNING: This will remove Jellyfin Media Server${NC}"
echo ""
echo "What will be removed:"
echo "  • Jellyfin application"
echo "  • Configuration and metadata"
echo ""
echo "What can be preserved:"
echo "  • Media storage (optional)"
echo ""

read -p "Continue with uninstall? [y/N]: " confirm
if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "🗑️  Deleting Jellyfin namespace..."
kubectl delete namespace "$NAMESPACE" --timeout=60s

echo ""
read -p "Delete media storage volume? (This will delete all your media!) [y/N]: " delete_storage
if [[ "$delete_storage" == "y" ]] || [[ "$delete_storage" == "Y" ]]; then
    echo ""
    echo "🗑️  Deleting media storage..."
    kubectl delete pvc jellyfin-media -n "$NAMESPACE" 2>/dev/null || true
    echo "✓ Media storage deleted"
else
    echo ""
    echo "✓ Media storage preserved"
    echo ""
    echo "Note: The PVC 'jellyfin-media' still exists."
    echo "If you reinstall Jellyfin, it will reuse this storage."
    echo ""
    echo "To delete it later:"
    echo "  kubectl delete pvc jellyfin-media -n jellyfin"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Jellyfin Uninstalled${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "To reinstall:"
echo "  sudo ./scripts/apps/jellyfin/install-jellyfin.sh"
echo ""
