#!/bin/bash

###############################################################################
# Nextcloud - Storage Expansion Script
# 
# Safely expand file storage and database storage for Nextcloud
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="nextcloud"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Nextcloud Storage Expansion${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: Nextcloud namespace not found${NC}"
    echo "Please install Nextcloud first:"
    echo "  sudo ./scripts/apps/nextcloud/install-nextcloud.sh"
    exit 1
fi

echo "Which storage would you like to expand?"
echo ""
echo "  1) File storage (nextcloud-data)"
echo "  2) Database storage (nextcloud-postgres)"
echo "  3) Both"
echo ""
read -p "Choose [1-3]: " STORAGE_CHOICE

expand_file_storage() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Expanding File Storage${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Get current size
    CURRENT_SIZE=$(kubectl get pvc nextcloud-data -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "unknown")
    
    echo "📊 Current file storage: $CURRENT_SIZE"
    echo ""
    
    # Calculate suggested size (add 500Gi)
    if [[ "$CURRENT_SIZE" =~ ^([0-9]+)Gi$ ]]; then
        CURRENT_NUM="${BASH_REMATCH[1]}"
        SUGGESTED_NUM=$((CURRENT_NUM + 500))
        SUGGESTED_SIZE="${SUGGESTED_NUM}Gi"
    elif [[ "$CURRENT_SIZE" =~ ^([0-9]+)Ti$ ]]; then
        CURRENT_NUM="${BASH_REMATCH[1]}"
        SUGGESTED_NUM=$((CURRENT_NUM + 1))
        SUGGESTED_SIZE="${SUGGESTED_NUM}Ti"
    else
        SUGGESTED_SIZE="500Gi"
    fi
    
    echo "Recommended sizes:"
    echo "  • 500Gi  - Good for small family"
    echo "  • 1Ti    - Good for large family or small team"
    echo "  • 2Ti    - Good for teams"
    echo "  • 5Ti+   - Good for extensive media libraries"
    echo ""
    echo "Suggested: $SUGGESTED_SIZE (current + 500Gi)"
    echo ""
    
    read -p "Enter new storage size [default: $SUGGESTED_SIZE]: " NEW_SIZE
    NEW_SIZE="${NEW_SIZE:-$SUGGESTED_SIZE}"
    
    echo ""
    echo "🚀 Expanding file storage to $NEW_SIZE..."
    echo ""
    
    # Patch the PVC
    kubectl patch pvc nextcloud-data -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_SIZE\"}}}}"
    
    echo ""
    echo "⏳ Waiting for expansion to complete..."
    sleep 5
    
    # Check new size
    NEW_ACTUAL_SIZE=$(kubectl get pvc nextcloud-data -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "checking...")
    
    echo ""
    echo -e "${GREEN}✓ File storage expanded!${NC}"
    echo "  Requested: $NEW_SIZE"
    echo "  Actual: $NEW_ACTUAL_SIZE"
    echo ""
}

expand_database_storage() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Expanding Database Storage${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Get current size
    CURRENT_SIZE=$(kubectl get pvc nextcloud-postgres -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "unknown")
    
    echo "📊 Current database storage: $CURRENT_SIZE"
    echo ""
    
    # Calculate suggested size (add 20Gi)
    if [[ "$CURRENT_SIZE" =~ ^([0-9]+)Gi$ ]]; then
        CURRENT_NUM="${BASH_REMATCH[1]}"
        SUGGESTED_NUM=$((CURRENT_NUM + 20))
        SUGGESTED_SIZE="${SUGGESTED_NUM}Gi"
    else
        SUGGESTED_SIZE="30Gi"
    fi
    
    echo "Recommended sizes:"
    echo "  • 20Gi   - Good for families or small teams"
    echo "  • 50Gi   - Good for large teams"
    echo "  • 100Gi  - Good for extensive app usage"
    echo ""
    echo "Suggested: $SUGGESTED_SIZE (current + 20Gi)"
    echo ""
    
    read -p "Enter new storage size [default: $SUGGESTED_SIZE]: " NEW_SIZE
    NEW_SIZE="${NEW_SIZE:-$SUGGESTED_SIZE}"
    
    echo ""
    echo "🚀 Expanding database storage to $NEW_SIZE..."
    echo ""
    
    # Patch the PVC
    kubectl patch pvc nextcloud-postgres -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_SIZE\"}}}}"
    
    echo ""
    echo "⏳ Waiting for expansion to complete..."
    sleep 5
    
    # Check new size
    NEW_ACTUAL_SIZE=$(kubectl get pvc nextcloud-postgres -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "checking...")
    
    echo ""
    echo -e "${GREEN}✓ Database storage expanded!${NC}"
    echo "  Requested: $NEW_SIZE"
    echo "  Actual: $NEW_ACTUAL_SIZE"
    echo ""
}

# Execute based on choice
case $STORAGE_CHOICE in
    1)
        expand_file_storage
        ;;
    2)
        expand_database_storage
        ;;
    3)
        expand_file_storage
        expand_database_storage
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

echo ""
echo "📊 Current storage status:"
kubectl get pvc -n "$NAMESPACE"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Storage Expansion Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "💡 Note: Longhorn automatically expands the underlying volume."
echo "   No pod restart required - changes take effect immediately."
echo ""
