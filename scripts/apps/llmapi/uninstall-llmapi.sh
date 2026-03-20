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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

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
echo "Deleting PVCs and secrets..."
# Delete PVCs first to ensure proper cleanup (namespace deletion may leave them orphaned)
PVC_NAMES=$(kubectl get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$PVC_NAMES" ]; then
    printf '%s\n' "$PVC_NAMES" | xargs -r kubectl delete pvc -n "$NAMESPACE" --timeout=300s 2>/dev/null || echo "  ⚠ Some PVCs may not delete cleanly"
fi

# Delete secrets
kubectl delete secret -n "$NAMESPACE" llmapi-db llmapi-secrets llmapi-prometheus-token --ignore-not-found=true 2>/dev/null || true

if [[ "$EUID" -eq 0 ]]; then
    systemctl stop llmapi-health-monitor.timer llmapi-health-monitor.service 2>/dev/null || true
    systemctl disable llmapi-health-monitor.timer llmapi-health-monitor.service 2>/dev/null || true
    rm -f /etc/systemd/system/llmapi-health-monitor.service /etc/systemd/system/llmapi-health-monitor.timer /usr/local/bin/llmapi-health-monitor.sh
    systemctl daemon-reload 2>/dev/null || true
fi

echo "Deleting namespace $NAMESPACE..."
kubectl delete namespace "$NAMESPACE" --timeout=300s

# Clean up local files
for key_file in "$HOME/.mynodeone/llmapi-key" "$HOME/.mynodeone/llmapi-admin-key" "$HOME/.mynodeone/llmapi-prometheus-key"; do
    if [ -f "$key_file" ]; then
        rm -f "$key_file"
        echo "Removed local key file: $(basename "$key_file")"
    fi
done

# Remove from service registry
if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" unregister "llmapi" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}✓ LLM API Service uninstalled${NC}"
echo ""
