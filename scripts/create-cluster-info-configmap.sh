#!/bin/bash

###############################################################################
# Create cluster-info ConfigMap
# 
# This script creates the cluster-info ConfigMap in kube-system namespace.
# Run this on the control plane if the ConfigMap is missing.
#
# Usage: sudo ./scripts/create-cluster-info-configmap.sh
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
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

# Check if K3s is running
if ! systemctl is-active --quiet k3s; then
    log_error "K3s is not running. Is this a control plane?"
    exit 1
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Detect actual user and their home directory (even when run with sudo)
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"

log_info "Checking for existing cluster-info ConfigMap..."

# Check if ConfigMap already exists
if kubectl get configmap cluster-info -n kube-system &>/dev/null; then
    log_warn "cluster-info ConfigMap already exists in kube-system"
    echo
    echo "Current values:"
    kubectl get configmap cluster-info -n kube-system -o yaml | grep -A 10 "^data:"
    echo
    read -p "Recreate it? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping creation"
        exit 0
    fi
    kubectl delete configmap cluster-info -n kube-system
    log_success "Deleted existing ConfigMap"
fi

# Load config if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    log_success "Loaded config from $CONFIG_FILE"
else
    log_warn "No config file found, will ask for values"
fi

# Get cluster name
if [ -z "${CLUSTER_NAME:-}" ]; then
    read -p "Cluster name [mynodeone]: " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-mynodeone}
fi

# Get cluster domain
if [ -z "${CLUSTER_DOMAIN:-}" ]; then
    read -p "Cluster domain [cluster.local]: " CLUSTER_DOMAIN
    CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-cluster.local}
fi

# Remove .local suffix if present (we add it back later)
CLUSTER_DOMAIN=${CLUSTER_DOMAIN%.local}

# Get Tailscale IP
if [ -z "${TAILSCALE_IP:-}" ]; then
    TAILSCALE_IP=$(ip addr show tailscale0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "")
    if [ -z "$TAILSCALE_IP" ]; then
        read -p "Control plane Tailscale IP: " TAILSCALE_IP
    else
        log_info "Detected Tailscale IP: $TAILSCALE_IP"
    fi
fi

# Get repo path
if [ -z "${MYNODEONE_PATH:-}" ]; then
    # Try to find MyNodeOne directory
    MYNODEONE_PATH=$(find "$ACTUAL_HOME" /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1 || echo "")
    if [ -z "$MYNODEONE_PATH" ]; then
        read -p "MyNodeOne repository path: " MYNODEONE_PATH
    else
        log_info "Detected MyNodeOne path: $MYNODEONE_PATH"
    fi
fi

echo
log_info "Creating cluster-info ConfigMap with:"
echo "  • Cluster Name: $CLUSTER_NAME"
echo "  • Domain: ${CLUSTER_DOMAIN}.local"
echo "  • Control Plane IP: $TAILSCALE_IP"
echo "  • Repo Path: $MYNODEONE_PATH"
echo

# Create the ConfigMap
kubectl create configmap cluster-info \
    --from-literal=cluster-name="$CLUSTER_NAME" \
    --from-literal=cluster-domain="$CLUSTER_DOMAIN" \
    --from-literal=control-plane-ip="$TAILSCALE_IP" \
    --from-literal=repo-path="$MYNODEONE_PATH" \
    --namespace=kube-system \
    --dry-run=client -o yaml | kubectl apply -f -

if [ $? -eq 0 ]; then
    log_success "cluster-info ConfigMap created successfully!"
    echo
    log_info "Verify with: kubectl get configmap cluster-info -n kube-system -o yaml"
    echo
    log_success "VPS installations can now auto-detect cluster settings!"
else
    log_error "Failed to create ConfigMap"
    exit 1
fi
