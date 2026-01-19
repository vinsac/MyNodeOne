#!/bin/bash

###############################################################################
# Fix cluster-info ConfigMap repo-path
#
# This script fixes the repo-path in the cluster-info ConfigMap if it has
# an incorrect /scripts suffix.
#
# Usage: sudo ./scripts/utils/fix-cluster-info-repo-path.sh
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root or with sudo"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Is this a control plane?"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Fix cluster-info ConfigMap repo-path"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get current repo-path
CURRENT_PATH=$(kubectl get configmap cluster-info -n kube-system -o jsonpath='{.data.repo-path}' 2>/dev/null || echo "")

if [ -z "$CURRENT_PATH" ]; then
    log_error "cluster-info ConfigMap not found or repo-path is empty"
    exit 1
fi

log_info "Current repo-path: $CURRENT_PATH"

# Check if it ends with /scripts
if [[ "$CURRENT_PATH" == */scripts ]]; then
    log_warn "Detected incorrect path with /scripts suffix"
    
    # Remove /scripts suffix
    CORRECT_PATH="${CURRENT_PATH%/scripts}"
    
    log_info "Correcting to: $CORRECT_PATH"
    
    # Verify the correct path exists
    if [ ! -d "$CORRECT_PATH" ]; then
        log_error "Corrected path does not exist: $CORRECT_PATH"
        exit 1
    fi
    
    # Update the ConfigMap
    kubectl patch configmap cluster-info -n kube-system \
        --type merge \
        -p "{\"data\":{\"repo-path\":\"$CORRECT_PATH\"}}"
    
    if [ $? -eq 0 ]; then
        log_success "ConfigMap updated successfully!"
        
        # Verify the change
        NEW_PATH=$(kubectl get configmap cluster-info -n kube-system -o jsonpath='{.data.repo-path}' 2>/dev/null)
        log_info "New repo-path: $NEW_PATH"
        
        echo ""
        log_success "Fix complete! Management laptop registration should now work."
    else
        log_error "Failed to update ConfigMap"
        exit 1
    fi
else
    log_success "repo-path is already correct: $CURRENT_PATH"
    log_info "No changes needed"
fi

echo ""
