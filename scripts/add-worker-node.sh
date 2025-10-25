#!/bin/bash

###############################################################################
# NodeZero Worker Node Addition Script
# 
# This script adds a new worker node to the NodeZero cluster
# Run this on the NEW worker node (e.g., node-002, node-003, etc.)
#
# IMPORTANT: Run ./scripts/interactive-setup.sh first!
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration
CONFIG_FILE="$HOME/.nodezero/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# K3s version
K3S_VERSION="v1.28.5+k3s1"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Verify configuration
    if [ -z "$TAILSCALE_IP" ] || [ -z "$CONTROL_PLANE_IP" ] || [ -z "$NODE_NAME" ]; then
        log_error "Configuration incomplete. Please run: ./scripts/interactive-setup.sh"
        exit 1
    fi
    
    log_success "Node Name: $NODE_NAME"
    log_success "Tailscale IP: $TAILSCALE_IP"
    log_success "Control Plane: $CONTROL_PLANE_IP"
    log_success "Prerequisites check passed"
}

verify_control_plane() {
    log_info "Verifying control plane connectivity..."
    
    # Verify we can reach control plane
    if nc -z -w5 "$CONTROL_PLANE_IP" 6443 2>/dev/null; then
        log_success "Control plane reachable at: $CONTROL_PLANE_IP"
    else
        log_warn "Cannot reach control plane at $CONTROL_PLANE_IP:6443"
        log_warn "Make sure:"
        log_warn "  1. Control plane is running and bootstrapped"
        log_warn "  2. Tailscale is connected on both machines"
        log_warn "  3. K3s is installed and running on control plane"
        log_error "Cannot proceed without control plane connectivity"
        exit 1
    fi
}

get_join_token() {
    log_info "Getting cluster join token..."
    
    echo
    log_info "Please obtain the K3s token from the control plane node ($CONTROL_PLANE_IP)"
    log_info "On the control plane, run: sudo cat /var/lib/rancher/k3s/server/node-token"
    log_info "Or check: /root/nodezero-join-token.txt"
    echo
    read -p "Enter K3s token: " K3S_TOKEN
    
    if [ -z "$K3S_TOKEN" ]; then
        log_error "Token cannot be empty"
        exit 1
    fi
    
    log_success "Token received"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        open-iscsi \
        nfs-common \
        util-linux \
        netcat-openbsd
    
    # Enable and start iSCSI (required for Longhorn)
    systemctl enable --now iscsid
    
    log_success "Dependencies installed"
}

join_cluster() {
    log_info "Joining NodeZero cluster..."
    
    # Prepare K3s configuration
    mkdir -p /etc/rancher/k3s
    
    cat > /etc/rancher/k3s/config.yaml <<EOF
node-name: "$NODE_NAME"
node-ip: "$TAILSCALE_IP"
flannel-iface: tailscale0
kubelet-arg:
  - "max-pods=250"
EOF
    
    # Install K3s agent
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" \
        K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -
    
    # Wait for node to be registered
    log_info "Waiting for node to register with cluster..."
    sleep 10
    
    log_success "Successfully joined NodeZero cluster!"
}

label_node() {
    log_info "Labeling node..."
    
    # This requires kubectl access from control plane
    # We'll save the labels in a file for the admin to apply
    
    cat > /root/nodezero-node-labels.txt <<EOF
# Apply these labels on the control plane node:
kubectl label node $NODE_NAME node-role.kubernetes.io/worker=true --overwrite
kubectl label node $NODE_NAME nodezero.io/location=${NODE_LOCATION} --overwrite
kubectl label node $NODE_NAME nodezero.io/storage=true --overwrite
EOF
    
    log_info "Node labels saved to /root/nodezero-node-labels.txt"
    log_info "Run these commands on the control plane to complete setup"
}

print_summary() {
    log_success "Worker node successfully added to NodeZero! 🎉"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Worker Node Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Node Information:"
    echo "  Name: $NODE_NAME"
    echo "  IP: $TAILSCALE_IP"
    echo "  Control Plane: $CONTROL_PLANE_IP"
    echo
    echo "Next Steps:"
    echo "  1. On the control plane node, apply node labels:"
    echo "     See: /root/nodezero-node-labels.txt on this machine"
    echo
    echo "  2. Verify node status on control plane:"
    echo "     kubectl get nodes"
    echo
    echo "  3. This node will now receive workloads automatically!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NodeZero Worker Node Addition"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    verify_control_plane
    get_join_token
    install_dependencies
    join_cluster
    label_node
    
    echo
    print_summary
}

# Run main function
main "$@"
