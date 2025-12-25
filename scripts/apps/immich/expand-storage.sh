#!/bin/bash

###############################################################################
# Immich - Storage Expansion Script
# 
# Safely expand photo or database storage for Immich
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="immich"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Immich Storage Expansion${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Immich namespace not found. Is Immich installed?${NC}"
    exit 1
fi

# Get current storage sizes
echo "📊 Current Storage Allocation:"
echo ""

PHOTO_PVC_EXISTS=$(kubectl get pvc immich-photos -n "$NAMESPACE" &>/dev/null && echo "true" || echo "false")
DB_PVC_EXISTS=$(kubectl get pvc immich-postgres -n "$NAMESPACE" &>/dev/null && echo "true" || echo "false")

if [ "$PHOTO_PVC_EXISTS" = "true" ]; then
    CURRENT_PHOTO_SIZE=$(kubectl get pvc immich-photos -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
    ACTUAL_PHOTO_SIZE=$(kubectl get pvc immich-photos -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "$CURRENT_PHOTO_SIZE")
    echo "  Photos/Videos: $ACTUAL_PHOTO_SIZE (requested: $CURRENT_PHOTO_SIZE)"
else
    echo -e "  ${RED}Photos PVC not found${NC}"
    exit 1
fi

if [ "$DB_PVC_EXISTS" = "true" ]; then
    CURRENT_DB_SIZE=$(kubectl get pvc immich-postgres -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
    ACTUAL_DB_SIZE=$(kubectl get pvc immich-postgres -n "$NAMESPACE" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "$CURRENT_DB_SIZE")
    echo "  Database: $ACTUAL_DB_SIZE (requested: $CURRENT_DB_SIZE)"
else
    echo -e "  ${RED}Database PVC not found${NC}"
    exit 1
fi

echo ""
echo "Which storage would you like to expand?"
echo "  1) Photos/Videos storage"
echo "  2) Database storage"
echo "  3) Both"
echo ""
read -p "Enter choice [1-3]: " CHOICE

case $CHOICE in
    1)
        EXPAND_PHOTOS=true
        EXPAND_DB=false
        ;;
    2)
        EXPAND_PHOTOS=false
        EXPAND_DB=true
        ;;
    3)
        EXPAND_PHOTOS=true
        EXPAND_DB=true
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

# Expand photo storage
if [ "$EXPAND_PHOTOS" = "true" ]; then
    echo ""
    echo "📸 Expanding Photo Storage"
    echo ""
    echo "Current size: $CURRENT_PHOTO_SIZE"
    echo ""
    echo "Recommended sizes:"
    echo "  • 1Ti    - Good for ~100,000 photos"
    echo "  • 2Ti    - Good for ~200,000 photos"
    echo "  • 5Ti    - Good for large families or multiple users"
    echo "  • 10Ti   - Good for professional photographers"
    echo ""
    read -p "Enter new photo storage size: " NEW_PHOTO_SIZE
    
    if [ -z "$NEW_PHOTO_SIZE" ]; then
        echo -e "${RED}Error: Size cannot be empty${NC}"
        exit 1
    fi
    
    echo ""
    echo "🚀 Expanding photo storage to $NEW_PHOTO_SIZE..."
    
    # Patch PVC
    kubectl patch pvc immich-photos -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_PHOTO_SIZE\"}}}}"
    
    echo "✓ Photo storage expansion initiated"
    echo ""
    echo "⚠️  Note: Longhorn will automatically resize the volume."
    echo "   The Immich server pod may restart during this process."
    echo ""
fi

# Expand database storage
if [ "$EXPAND_DB" = "true" ]; then
    echo ""
    echo "🗄️ Expanding Database Storage"
    echo ""
    echo "Current size: $CURRENT_DB_SIZE"
    echo ""
    echo "Recommended sizes:"
    echo "  • 20Gi   - Good for ~50,000 photos"
    echo "  • 50Gi   - Good for ~100,000+ photos"
    echo "  • 100Gi  - Good for very large libraries"
    echo "  • 200Gi  - Good for professional use"
    echo ""
    read -p "Enter new database storage size: " NEW_DB_SIZE
    
    if [ -z "$NEW_DB_SIZE" ]; then
        echo -e "${RED}Error: Size cannot be empty${NC}"
        exit 1
    fi
    
    echo ""
    echo "🚀 Expanding database storage to $NEW_DB_SIZE..."
    
    # Patch PVC
    kubectl patch pvc immich-postgres -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_DB_SIZE\"}}}}"
    
    echo "✓ Database storage expansion initiated"
    echo ""
    echo "⚠️  Note: The database pod may need to restart for the change to take effect."
    echo ""
    
    read -p "Restart database pod now? [y/N]: " RESTART_DB
    if [[ "${RESTART_DB,,}" == "y" ]]; then
        echo "🔄 Restarting database pod..."
        kubectl rollout restart deployment/immich-postgres -n "$NAMESPACE"
        echo "⏳ Waiting for database to be ready..."
        kubectl wait --for=condition=available --timeout=120s deployment/immich-postgres -n "$NAMESPACE" || true
        echo "✓ Database restarted"
    fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Storage Expansion Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📊 Verify new sizes:"
echo "   kubectl get pvc -n $NAMESPACE"
echo ""
echo "📝 Monitor expansion progress:"
echo "   kubectl describe pvc immich-photos -n $NAMESPACE"
echo "   kubectl describe pvc immich-postgres -n $NAMESPACE"
echo ""
