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

    # Test SSH connection (allow password authentication)
    log_info "Testing SSH connection to $ssh_user@$control_plane_ip..."
    log_info "You may be prompted for your SSH password..."
    echo
    if ! $SSH_CMD -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" "exit"; then
        log_error "SSH connection failed."
        log_info "Please check your credentials and network connectivity."
        return 1
    fi
    log_success "SSH connection successful"

    # Ask for sudo password upfront (if needed)
    local sudo_password=""
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔑 Sudo Password Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "To fetch the kubeconfig, we need sudo access on the control plane"
    echo
    
    # Check if passwordless sudo works first
    if $SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo -n true" 2>/dev/null; then
        log_success "Passwordless sudo detected"
    else
        log_info "Passwordless sudo not available - password required"
        echo
        read -s -p "Enter sudo password for $ssh_user on control plane: " sudo_password
        echo
        echo
    fi

    # Fetch kubeconfig
    log_info "Fetching Kubernetes configuration from control plane..."
    
    mkdir -p "$ACTUAL_HOME/.kube"
    
    # Run SSH command with or without password
    if [ -z "$sudo_password" ]; then
        # Passwordless sudo
        $SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" > "$ACTUAL_HOME/.kube/config.raw" 2>/dev/null
    else
        # Use password with sudo - need to use -tt for pseudo-terminal
        $SSH_CMD -tt "$ssh_user@$control_plane_ip" "echo '$sudo_password' | sudo -S cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | grep -v "^\[sudo\]" > "$ACTUAL_HOME/.kube/config.raw"
    fi
    
    local ssh_exit=$?

    if [ $ssh_exit -eq 0 ] && [ -s "$ACTUAL_HOME/.kube/config.raw" ]; then
        # Process the file to remove connection messages and update IP
        grep -v "Connection to.*closed" "$ACTUAL_HOME/.kube/config.raw" | \
        sed "s/127.0.0.1/$control_plane_ip/g" > "$ACTUAL_HOME/.kube/config"
        rm -f "$ACTUAL_HOME/.kube/config.raw"
        chmod 600 "$ACTUAL_HOME/.kube/config"
        log_success "Kubeconfig retrieved"

        # Fetch cluster info directly from control plane (doesn't require local kubectl)
        log_info "Reading cluster configuration from control plane..."
        
        # Use SSH to run kubectl on the control plane
        local cluster_name=""
        local cluster_domain=""
        
        if [ -z "$sudo_password" ]; then
            # Passwordless sudo
            cluster_name=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}'" 2>/dev/null || echo "")
            cluster_domain=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}'" 2>/dev/null || echo "")
        else
            # With password - use -tt for pseudo-terminal
            cluster_name=$($SSH_CMD -tt "$ssh_user@$control_plane_ip" "echo '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}' 2>&1" 2>/dev/null | grep -v "^\[sudo\]" | tr -d '\r')
            cluster_domain=$($SSH_CMD -tt "$ssh_user@$control_plane_ip" "echo '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>&1" 2>/dev/null | grep -v "^\[sudo\]" | tr -d '\r')
        fi

        if [ -n "$cluster_name" ] && [ -n "$cluster_domain" ]; then
            log_success "Cluster info retrieved:"
            echo "  • Cluster Name: $cluster_name"
            echo "  • Domain: ${cluster_domain}.local"

            # Fetch MyNodeOne repo path from authoritative cluster config
            log_info "Fetching MyNodeOne repository path from cluster..."
            local repo_path=""
            
            # Try to get from cluster configmap (authoritative source)
            if [ -z "$sudo_password" ]; then
                repo_path=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}'" 2>/dev/null || echo "")
            else
                repo_path=$($SSH_CMD -tt "$ssh_user@$control_plane_ip" "echo '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}' 2>&1" 2>/dev/null | grep -v "^\[sudo\]" | tr -d '\r')
            fi

            if [ -n "$repo_path" ]; then
                log_success "Found authoritative path: $repo_path"
            else
                # Fallback: search filesystem (for backwards compatibility with older clusters)
                log_info "No path in cluster config, searching filesystem..."
                if [ -z "$sudo_password" ]; then
                    repo_path=$($SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" \
                        "find $ACTUAL_HOME /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1" 2>/dev/null)
                else
                    repo_path=$($SSH_CMD -tt "$ssh_user@$control_plane_ip" \
                        "find $ACTUAL_HOME /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1" 2>/dev/null | tr -d '\r')
                fi
                
                if [ -z "$repo_path" ]; then
                    # Try standard locations
                    for path in "$ACTUAL_HOME/MyNodeOne" /opt/MyNodeOne; do
                        if [ -z "$sudo_password" ]; then
                            if $SSH_CMD -o BatchMode=yes "$ssh_user@$control_plane_ip" "[ -d '$path' ]" 2>/dev/null; then
                                repo_path="$path"
                                break
                            fi
                        else
                            if $SSH_CMD -tt "$ssh_user@$control_plane_ip" "[ -d '$path' ]" 2>/dev/null; then
                                repo_path="$path"
                                break
                            fi
                        fi
                    done
                fi
                
                if [ -n "$repo_path" ]; then
                    log_success "Found MyNodeOne at: $repo_path"
                else
                    log_warn "Could not detect MyNodeOne path (will auto-detect later)"
                fi
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
