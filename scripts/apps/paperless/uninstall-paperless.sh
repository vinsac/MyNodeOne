#!/bin/bash

###############################################################################
# Paperless-ngx Uninstallation Script
# 
# Removes Paperless-ngx and optionally its data
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="paperless"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Uninstalling Paperless-ngx${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}Paperless namespace not found. Nothing to uninstall.${NC}"
    exit 0
fi

echo -e "${YELLOW}⚠️  WARNING: This will remove Paperless-ngx from your cluster.${NC}"
echo ""
echo "What would you like to delete?"
echo ""
echo "1. Delete Paperless application only (keep documents and database)"
echo "2. Delete everything including all documents and database"
echo "3. Cancel"
echo ""
read -p "Enter your choice [1-3]: " choice

case $choice in
    1)
        echo ""
        echo "🗑️  Deleting Paperless application (keeping data)..."
        
        # Delete deployments and services
        kubectl delete deployment paperless paperless-postgres paperless-redis -n "$NAMESPACE" --ignore-not-found=true
        kubectl delete service paperless paperless-postgres paperless-redis -n "$NAMESPACE" --ignore-not-found=true
        kubectl delete secret paperless-db paperless-redis paperless-secret -n "$NAMESPACE" --ignore-not-found=true
        
        echo ""
        echo -e "${GREEN}✓ Paperless application deleted${NC}"
        echo ""
        echo "Your documents and database are preserved in:"
        echo "  • paperless-data PVC"
        echo "  • paperless-media PVC"
        echo "  • paperless-postgres PVC"
        echo ""
        echo "To reinstall with existing data, run:"
        echo "  sudo ./scripts/apps/paperless/install-paperless.sh"
        ;;
        
    2)
        echo ""
        echo -e "${RED}⚠️  FINAL WARNING: This will permanently delete ALL your documents!${NC}"
        echo ""
        read -p "Type 'DELETE ALL' to confirm: " confirm
        
        if [ "$confirm" = "DELETE ALL" ]; then
            echo ""
            echo "🗑️  Deleting everything..."
            
            # Delete entire namespace (includes all resources)
            kubectl delete namespace "$NAMESPACE"
            
            echo ""
            echo -e "${GREEN}✓ Paperless completely removed${NC}"
            echo ""
            echo "All documents, database, and application data have been deleted."
        else
            echo ""
            echo "Deletion cancelled."
            exit 0
        fi
        ;;
        
    3)
        echo ""
        echo "Uninstallation cancelled."
        exit 0
        ;;
        
    *)
        echo ""
        echo -e "${RED}Invalid choice. Uninstallation cancelled.${NC}"
        exit 1
        ;;
esac

echo ""
echo "✅ Uninstallation complete!"
echo ""
