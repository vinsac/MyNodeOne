#!/bin/bash

###############################################################################
# Mattermost - Uninstall Script
# 
# Removes Mattermost from your cluster
# Options to keep or delete data
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="mattermost"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Uninstalling Mattermost${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}Mattermost is not installed (namespace not found)${NC}"
    exit 0
fi

echo -e "${YELLOW}⚠️  WARNING: This will remove Mattermost from your cluster${NC}"
echo ""
echo "Choose uninstall option:"
echo "  1) Remove app only (keep data for reinstall)"
echo "  2) Remove everything (including all messages and data)"
echo ""
read -p "Enter choice [1-2]: " choice

case $choice in
    1)
        echo ""
        echo "🗑️  Removing Mattermost application..."
        kubectl delete deployment mattermost -n "$NAMESPACE" 2>/dev/null || true
        kubectl delete deployment mattermost-postgres -n "$NAMESPACE" 2>/dev/null || true
        kubectl delete service mattermost -n "$NAMESPACE" 2>/dev/null || true
        kubectl delete service mattermost-postgres -n "$NAMESPACE" 2>/dev/null || true
        kubectl delete secret mattermost-db -n "$NAMESPACE" 2>/dev/null || true
        
        echo ""
        echo -e "${GREEN}✓ Mattermost application removed${NC}"
        echo ""
        echo "📦 Preserved data:"
        echo "  • mattermost-data PVC (messages, files, uploads)"
        echo "  • mattermost-postgres PVC (database)"
        echo ""
        echo "To reinstall with existing data, run:"
        echo "  sudo ./scripts/apps/mattermost/install-mattermost.sh"
        ;;
        
    2)
        echo ""
        echo -e "${RED}⚠️  FINAL WARNING: This will permanently delete:${NC}"
        echo "  • All team messages and chat history"
        echo "  • All uploaded files and attachments"
        echo "  • All user accounts and settings"
        echo "  • All channels and teams"
        echo "  • All integrations and webhooks"
        echo ""
        read -p "Type 'DELETE' to confirm permanent deletion: " confirm
        
        if [ "$confirm" != "DELETE" ]; then
            echo "Uninstall cancelled."
            exit 0
        fi
        
        echo ""
        echo "🗑️  Removing Mattermost and all data..."
        kubectl delete namespace "$NAMESPACE"
        
        echo ""
        echo -e "${GREEN}✓ Mattermost completely removed${NC}"
        echo ""
        echo "All data has been permanently deleted."
        ;;
        
    *)
        echo "Invalid choice. Uninstall cancelled."
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Uninstall complete!${NC}"
echo ""
