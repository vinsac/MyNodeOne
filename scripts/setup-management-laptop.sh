#!/bin/bash

###############################################################################
# MyNodeOne Management Laptop Setup
# 
# This script configures a laptop/desktop for managing the MyNodeOne cluster
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Load configuration
CONFIG_FILE="$HOME/.mynodeone/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    log_error "Please run the interactive setup first: sudo ./scripts/mynodeone"
    exit 1
fi

source "$CONFIG_FILE"

print_header "Management Laptop Setup"

log_info "Cluster: $CLUSTER_NAME"
log_info "Domain: ${CLUSTER_DOMAIN}.local"
echo

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    log_info "Installing kubectl..."
    
    # Detect OS
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    else
        log_warn "Please install kubectl manually for your OS"
        log_info "Visit: https://kubernetes.io/docs/tasks/tools/"
    fi
    
    log_success "kubectl installed"
else
    log_info "kubectl already installed"
fi

# Check if we can access the cluster
if kubectl cluster-info &> /dev/null; then
    log_success "Connected to Kubernetes cluster"
    kubectl cluster-info
else
    log_warn "Cannot connect to Kubernetes cluster"
    log_info "You need to copy the kubeconfig from your control plane:"
    echo
    echo "  On control plane, run:"
    echo "    sudo cat /etc/rancher/k3s/k3s.yaml"
    echo
    echo "  On this laptop, create ~/.kube/config with that content"
    echo "  Replace 'server: https://127.0.0.1:6443' with your control plane IP"
    echo
fi

# Setup local DNS for .local domains
print_header "Local DNS Setup"

log_info "Setting up .local domain names for easy access..."

# Get service IPs from cluster (if connected)
if kubectl cluster-info &> /dev/null; then
    DASHBOARD_IP=$(kubectl get svc -n mynodeone-dashboard dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    LONGHORN_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$DASHBOARD_IP" ]; then
        log_success "Retrieved service IPs from cluster"
        
        # Update /etc/hosts
        log_info "Updating /etc/hosts..."
        
        # Backup hosts file
        sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
        
        # Remove old entries
        sudo sed -i.tmp '/# MyNodeOne services/,/# End MyNodeOne services/d' /etc/hosts
        
        # Add new entries
        {
            echo ""
            echo "# MyNodeOne services"
            [ -n "$DASHBOARD_IP" ] && echo "${DASHBOARD_IP}      ${CLUSTER_DOMAIN}.local"
            [ -n "$GRAFANA_IP" ] && echo "${GRAFANA_IP}        grafana.${CLUSTER_DOMAIN}.local"
            [ -n "$ARGOCD_IP" ] && echo "${ARGOCD_IP}         argocd.${CLUSTER_DOMAIN}.local"
            [ -n "$MINIO_CONSOLE_IP" ] && echo "${MINIO_CONSOLE_IP}  minio.${CLUSTER_DOMAIN}.local"
            [ -n "$LONGHORN_IP" ] && echo "${LONGHORN_IP}       longhorn.${CLUSTER_DOMAIN}.local"
            echo "# End MyNodeOne services"
        } | sudo tee -a /etc/hosts > /dev/null
        
        log_success "Local DNS configured!"
        echo
        log_info "You can now access services at:"
        echo "  • Dashboard: http://${CLUSTER_DOMAIN}.local"
        echo "  • Grafana:   http://grafana.${CLUSTER_DOMAIN}.local"
        echo "  • ArgoCD:    https://argocd.${CLUSTER_DOMAIN}.local"
        echo "  • MinIO:     http://minio.${CLUSTER_DOMAIN}.local:9001"
        echo "  • Longhorn:  http://longhorn.${CLUSTER_DOMAIN}.local"
    else
        log_warn "Could not retrieve service IPs from cluster"
        log_info "Make sure services are deployed and have LoadBalancer IPs assigned"
    fi
else
    log_warn "Skipping DNS setup - not connected to cluster yet"
    log_info "Set up kubectl connection first, then re-run this script"
fi

echo
print_header "Setup Complete!"

log_success "Management laptop configured for cluster: $CLUSTER_NAME"
echo
log_info "Next steps:"
echo "  1. Ensure Tailscale is connected: tailscale status"
echo "  2. Check cluster connection: kubectl get nodes"
echo "  3. View running pods: kubectl get pods -A"
echo "  4. Access web UIs using .local domains"
echo

