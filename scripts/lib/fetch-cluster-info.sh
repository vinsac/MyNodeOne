#!/bin/bash

###############################################################################
# Fetch Cluster Info from Control Plane
# 
# This script fetches kubeconfig and cluster information from the control plane
# Used during management laptop setup to auto-detect cluster configuration
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect actual user and their home directory (even when run with sudo)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory and SSH keys
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    SSH_CMD="sudo -u $SUDO_USER ssh"
else
    # Running normally
    ACTUAL_HOME="$HOME"
    SSH_CMD="ssh"
fi

CONFIG_DIR="$ACTUAL_HOME/.mynodeone"

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
    if ! $SSH_CMD -o BatchMode=yes -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" "exit" 2>/dev/null; then
        log_error "Passwordless SSH connection failed."
        log_info "Please ensure you have exchanged SSH keys and can connect without a password."
        return 1
    fi
    log_success "SSH connection successful"

    # Check for passwordless sudo
    log_info "Checking for passwordless sudo on control plane..."
    if ! $SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo -n true" 2>/dev/null; then
        log_error "Passwordless sudo is not configured on the control plane."
        log_info "Please run 'setup-control-plane-sudo.sh' on the control plane and try again."
        return 1
    fi
    log_success "Passwordless sudo detected"
    echo

    # Fetch kubeconfig
    log_info "Fetching Kubernetes configuration from control plane..."
    mkdir -p "$ACTUAL_HOME/.kube"
    if ! $SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" > "$ACTUAL_HOME/.kube/config.raw" 2>/dev/null; then
        log_error "Failed to fetch kubeconfig."
        return 1
    fi

    if [ -s "$ACTUAL_HOME/.kube/config.raw" ]; then
        # Process the file to remove connection messages and update IP
        grep -v "Connection to.*closed" "$ACTUAL_HOME/.kube/config.raw" | \
        sed "s/127.0.0.1/$control_plane_ip/g" > "$ACTUAL_HOME/.kube/config"
        rm -f "$ACTUAL_HOME/.kube/config.raw"
        chmod 600 "$ACTUAL_HOME/.kube/config"
        log_success "Kubeconfig retrieved"

        # Fetch cluster info directly from control plane
        log_info "Reading cluster configuration from control plane..."
        cluster_name=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}'" 2>/dev/null || echo "")
        cluster_domain=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}'" 2>/dev/null || echo "")

        if [ -n "$cluster_name" ] && [ -n "$cluster_domain" ]; then
            log_success "Cluster info retrieved:"
            echo "  • Cluster Name: $cluster_name"
            echo "  • Domain: ${cluster_domain}.local"

            # Fetch MyNodeOne repo path
            log_info "Fetching MyNodeOne repository path from cluster..."
            repo_path=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}'" 2>/dev/null || echo "")

            if [ -n "$repo_path" ]; then
                log_success "Found authoritative path: $repo_path"
            else
                log_warn "Could not detect MyNodeOne repo path. You may need to specify it manually."
            fi

            # Save to config
            mkdir -p "$CONFIG_DIR"
            cat > "$CONFIG_DIR/config.env" <<EOF
# MyNodeOne Configuration
# Auto-generated on $(date)

CLUSTER_NAME="$cluster_name"
CLUSTER_DOMAIN="$cluster_domain"
CONTROL_PLANE_IP="$control_plane_ip"
CONTROL_PLANE_SSH_USER="$ssh_user"
EOF
            if [ -n "$repo_path" ]; then
                echo "CONTROL_PLANE_REPO_PATH=\"$repo_path\"" >> "$CONFIG_DIR/config.env"
            fi
            log_success "Configuration saved to $CONFIG_DIR/config.env"
            return 0
        else
            log_warn "Could not find cluster-info configmap on control plane."
            return 1
        fi
    else
        log_error "Failed to retrieve a valid kubeconfig from the control plane."
        return 1
    fi
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    fetch_cluster_info
fi
