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

# Source validation library if available
if [ -f "$SCRIPT_DIR/../lib/validation.sh" ]; then
    source "$SCRIPT_DIR/../lib/validation.sh"
fi

fetch_cluster_info() {
    local control_plane_ip=""
    local ssh_user=""
    
    # Ask for control plane details
    echo "To fetch cluster configuration, I need the control plane details:"
    echo
    read -p "Control plane IP (Tailscale IP): " control_plane_ip
    read -p "SSH username on control plane [default: root]: " ssh_user
    ssh_user="${ssh_user:-root}"
    
    # Test SSH connection
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ssh_user@$control_plane_ip" "exit" 2>/dev/null; then
        return 1
    fi
    
    # Fetch kubeconfig
    mkdir -p ~/.kube
    if ssh "$ssh_user@$control_plane_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | \
       sed "s/127.0.0.1/$control_plane_ip/g" > ~/.kube/config.tmp; then
        
        # Validate it works
        if KUBECONFIG=~/.kube/config.tmp kubectl cluster-info &>/dev/null; then
            mv ~/.kube/config.tmp ~/.kube/config
            chmod 600 ~/.kube/config
            
            # Fetch cluster info from configmap
            local cluster_name=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}' 2>/dev/null || echo "")
            local cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
            
            # Save to config
            mkdir -p "$CONFIG_DIR"
            if [ -n "$cluster_name" ]; then
                echo "CLUSTER_NAME=\"$cluster_name\"" >> "$CONFIG_DIR/config.env"
            fi
            if [ -n "$cluster_domain" ]; then
                echo "CLUSTER_DOMAIN=\"$cluster_domain\"" >> "$CONFIG_DIR/config.env"
            fi
            echo "CONTROL_PLANE_IP=\"$control_plane_ip\"" >> "$CONFIG_DIR/config.env"
            echo "CONTROL_PLANE_SSH_USER=\"$ssh_user\"" >> "$CONFIG_DIR/config.env"
            
            return 0
        fi
    fi
    
    return 1
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    fetch_cluster_info
fi
