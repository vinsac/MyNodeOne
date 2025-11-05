#!/bin/bash

###############################################################################
# Fetch Cluster Info from Control Plane
# 
# This script fetches kubeconfig and cluster information from the control plane
# Used during management laptop setup to auto-detect cluster configuration
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.mynodeone"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
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

fetch_cluster_info() {
    local control_plane_ip=""
    local ssh_user=""
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📡 Fetching Cluster Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "To auto-detect your cluster settings, I need your control plane details"
    echo
    
    # Prompt for control plane IP
    while [ -z "$control_plane_ip" ]; do
        read -p "? Control plane Tailscale IP (e.g., 100.x.x.x): " control_plane_ip
        
        if [ -z "$control_plane_ip" ]; then
            log_warn "IP address is required"
        elif ! [[ "$control_plane_ip" =~ ^100\. ]]; then
            log_warn "Expected a Tailscale IP starting with 100."
            control_plane_ip=""
        fi
    done
    
    # Prompt for SSH username
    read -p "? SSH username on control plane [root]: " ssh_user
    ssh_user="${ssh_user:-root}"
    echo
    
    # Test SSH connection
    log_info "Testing SSH connection to $ssh_user@$control_plane_ip..."
    
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" "exit" 2>/dev/null; then
        log_warn "Passwordless SSH failed, you may be prompted for password"
        
        # Try with password
        if ! ssh -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" "exit" 2>/dev/null; then
            log_error "Cannot connect to control plane"
            log_info "Please ensure:"
            echo "  1. Control plane is running and accessible"
            echo "  2. Tailscale is connected on both machines"
            echo "  3. SSH is enabled on control plane"
            echo "  4. You have SSH access to the control plane"
            return 1
        fi
    fi
    
    log_success "SSH connection successful"
    echo
    
    # Fetch kubeconfig
    log_info "Fetching Kubernetes configuration from control plane..."
    log_info "Note: You may be prompted for sudo password on the control plane"
    echo
    
    mkdir -p ~/.kube
    
    # Try to fetch with sudo - may prompt for password
    if ssh -t "$ssh_user@$control_plane_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | \
       sed "s/127.0.0.1/$control_plane_ip/g" > ~/.kube/config.tmp 2>/dev/null; then
        
        # Check if we actually got content
        if [ ! -s ~/.kube/config.tmp ]; then
            log_error "Retrieved empty kubeconfig"
            log_info "Possible reasons:"
            echo "  • k3s is not installed on control plane"
            echo "  • k3s is not running"
            echo "  • Insufficient permissions"
            rm -f ~/.kube/config.tmp
            return 1
        fi
        
        log_success "Kubeconfig retrieved"
        
        # Validate it works
        log_info "Validating cluster connection..."
        
        if KUBECONFIG=~/.kube/config.tmp kubectl cluster-info &>/dev/null; then
            mv ~/.kube/config.tmp ~/.kube/config
            chmod 600 ~/.kube/config
            
            log_success "Cluster connection validated"
            echo
            
            # Fetch cluster info from configmap
            log_info "Reading cluster configuration..."
            
            local cluster_name=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}' 2>/dev/null || echo "")
            local cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
            
            if [ -n "$cluster_name" ] && [ -n "$cluster_domain" ]; then
                log_success "Cluster info retrieved:"
                echo "  • Cluster Name: $cluster_name"
                echo "  • Domain: ${cluster_domain}.local"
                echo
                
                # Save to config
                mkdir -p "$CONFIG_DIR"
                
                # Create or update config file
                cat > "$CONFIG_DIR/config.env" <<EOF
# MyNodeOne Configuration
# Auto-generated on $(date)

CLUSTER_NAME="$cluster_name"
CLUSTER_DOMAIN="$cluster_domain"
CONTROL_PLANE_IP="$control_plane_ip"
CONTROL_PLANE_SSH_USER="$ssh_user"
EOF
                
                log_success "Configuration saved to $CONFIG_DIR/config.env"
                return 0
            else
                log_warn "Could not find cluster-info configmap"
                log_info "The control plane may not have been fully initialized"
                return 1
            fi
        else
            log_error "Kubeconfig validation failed"
            rm -f ~/.kube/config.tmp
            return 1
        fi
    else
        log_error "Failed to fetch kubeconfig from control plane"
        log_info "Make sure k3s is installed and running on the control plane"
        return 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    fetch_cluster_info
fi
