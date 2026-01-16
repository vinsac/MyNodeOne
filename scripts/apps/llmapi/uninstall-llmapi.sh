#!/bin/bash

###############################################################################
# LLM API Service - Uninstall
# 
# Remove the LLM API service and all associated resources.
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="llmapi"

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Uninstall LLM API Service${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "LLM API is not installed."
    exit 0
fi

echo "This will delete:"
echo "  • All LLM API pods and services"
echo "  • All downloaded models (~200-500GB)"
echo "  • All API keys and usage data"
echo "  • All configuration"
echo ""
echo -e "${RED}This action cannot be undone!${NC}"
echo ""

read -p "Are you sure you want to uninstall? [y/N]: " confirm
if [ "${confirm,,}" != "y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Deleting namespace $NAMESPACE..."
kubectl delete namespace "$NAMESPACE" --timeout=300s

# Clean up local files
if [ -f "$HOME/.mynodeone/llmapi-key" ]; then
    rm -f "$HOME/.mynodeone/llmapi-key"
    echo "Removed local API key file"
fi

# Remove from service registry
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Calculate project root from apps location
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/project-root.sh"

if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" unregister "llmapi" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}✓ LLM API Service uninstalled${NC}"
echo ""
