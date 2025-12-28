#!/bin/bash

###############################################################################
# MyNodeOne App Undeploy Script
# 
# Remove an app from MyNodeOne cluster
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${BLUE}▶${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

APP_NAME="${1:-}"

if [[ -z "$APP_NAME" ]]; then
    error "Usage: $0 <app-name>"
    echo ""
    echo "Available apps:"
    kubectl get namespaces -l app.kubernetes.io/managed-by=mynodeone-deploy \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || \
        kubectl get namespaces --no-headers | awk '{print $1}' | grep -v -E '^(kube-|default|metallb|longhorn)'
    exit 1
fi

echo ""
log "Undeploying app: $APP_NAME"
echo ""

# Check if namespace exists
if ! kubectl get namespace "$APP_NAME" &>/dev/null; then
    error "App '$APP_NAME' not found"
    exit 1
fi

# Show what will be deleted
log "The following resources will be deleted:"
echo ""
kubectl get all -n "$APP_NAME" 2>/dev/null || true
echo ""

warn "This will permanently delete the app and all its data!"
read -p "Are you sure? [y/N]: " confirm

if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
log "Removing app from MyNodeOne..."

# Delete namespace (deletes everything in it)
kubectl delete namespace "$APP_NAME" --wait=true

echo ""
success "App '$APP_NAME' removed successfully!"
echo ""

log "Cleanup tasks:"
echo "  • Namespace deleted"
echo "  • All pods stopped"
echo "  • Services removed"
echo "  • Storage volumes retained (can be manually deleted)"
echo ""

log "To delete storage volumes:"
echo "  kubectl delete pvc -n $APP_NAME --all"
echo ""
