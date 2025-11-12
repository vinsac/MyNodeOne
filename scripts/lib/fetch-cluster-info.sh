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
        log_error "Passwordless SSH not configured!"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚠️  SSH Keys Not Exchanged"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "SSH keys must be exchanged BEFORE running installation."
        echo "This prevents password prompts during installation."
        echo
        echo "Exit this wizard and run these commands first:"
        echo
        echo "  # Generate SSH key:"
        echo "  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"
        echo
        echo "  # Copy key to control plane:"
        echo "  ssh-copy-id $ssh_user@$control_plane_ip"
        echo
        echo "  # Test (should NOT ask for password):"
        echo "  ssh $ssh_user@$control_plane_ip 'echo OK'"
        echo
        echo "  # Then run pre-flight checks:"
        echo "  cd ~/MyNodeOne"
        echo "  ./scripts/check-prerequisites.sh vps $control_plane_ip $ssh_user"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        read -p "Press Enter to continue anyway (NOT recommended) or Ctrl+C to exit: " -r
        echo
        
        # Try with password - MUST NOT suppress stderr so user can see password prompt
        if ! ssh -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" "exit"; then
            echo
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
    if ssh "$ssh_user@$control_plane_ip" "sudo -n true" 2>/dev/null; then
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
    
    mkdir -p ~/.kube
    
    # Run SSH command with or without password
    if [ -z "$sudo_password" ]; then
        # Passwordless sudo
        ssh "$ssh_user@$control_plane_ip" "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/config.raw 2>/dev/null
    else
        # Pass password to sudo via stdin - use printf for safer password handling
        ssh "$ssh_user@$control_plane_ip" "printf '%s\n' '$sudo_password' | sudo -S cat /etc/rancher/k3s/k3s.yaml 2>&1" | \
        grep -v "^\[sudo\]" | grep -v "^sudo:" > ~/.kube/config.raw
    fi
    
    local ssh_exit=$?
    
    if [ $ssh_exit -eq 0 ] && [ -s ~/.kube/config.raw ]; then
        # Process the file to remove connection messages and update IP
        grep -v "Connection to.*closed" ~/.kube/config.raw | \
        grep -v "^$" | \
        sed "s/127.0.0.1/$control_plane_ip/g" > ~/.kube/config.tmp
        
        rm -f ~/.kube/config.raw
        
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
        
        # Save kubeconfig (don't require local kubectl for validation)
        mv ~/.kube/config.tmp ~/.kube/config
        chmod 600 ~/.kube/config
        echo
        
        # Fetch cluster info directly from control plane (doesn't require local kubectl)
        log_info "Reading cluster configuration from control plane..."
        
        # Use SSH to run kubectl on the control plane
        local cluster_name=""
        local cluster_domain=""
        
        if [ -z "$sudo_password" ]; then
            # Passwordless sudo
            cluster_name=$(ssh "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}'" 2>/dev/null || echo "")
            cluster_domain=$(ssh "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}'" 2>/dev/null || echo "")
        else
            # With password - use printf for safer password handling
            # Note: sudo prompt and result are on same line, so use sed to strip prefix, not grep to remove line
            cluster_name=$(ssh "$ssh_user@$control_plane_ip" "printf '%s\\n' '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}' 2>&1" | sed 's/^\[sudo\] password for [^:]*: //' | grep -v "^sudo:" || echo "")
            cluster_domain=$(ssh "$ssh_user@$control_plane_ip" "printf '%s\\n' '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>&1" | sed 's/^\[sudo\] password for [^:]*: //' | grep -v "^sudo:" || echo "")
        fi
        
        if [ -n "$cluster_name" ] && [ -n "$cluster_domain" ]; then
            log_success "Cluster info retrieved:"
            echo "  • Cluster Name: $cluster_name"
            echo "  • Domain: ${cluster_domain}.local"
            echo
            
            # Fetch MyNodeOne repo path from authoritative cluster config
            log_info "Fetching MyNodeOne repository path from cluster..."
            local repo_path=""
            
            # Try to get from cluster configmap (authoritative source)
            if [ -z "$sudo_password" ]; then
                repo_path=$(ssh "$ssh_user@$control_plane_ip" "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}'" 2>/dev/null || echo "")
            else
                repo_path=$(ssh "$ssh_user@$control_plane_ip" "printf '%s\\n' '$sudo_password' | sudo -S kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}' 2>&1" | sed 's/^\[sudo\] password for [^:]*: //' | grep -v "^sudo:" || echo "")
            fi
            
            if [ -n "$repo_path" ]; then
                log_success "Found authoritative path: $repo_path"
            else
                # Fallback: search filesystem (for backwards compatibility with older clusters)
                log_info "No path in cluster config, searching filesystem..."
                repo_path=$(ssh "$ssh_user@$control_plane_ip" \
                    "find /root /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1" 2>/dev/null)
                
                if [ -z "$repo_path" ]; then
                    # Try standard locations
                    for path in ~/MyNodeOne /root/MyNodeOne /opt/MyNodeOne; do
                        if ssh "$ssh_user@$control_plane_ip" "[ -d '$path' ]" 2>/dev/null; then
                            repo_path="$path"
                            break
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
            
            # Create or update config file
            cat > "$CONFIG_DIR/config.env" <<EOF
# MyNodeOne Configuration
# Auto-generated on $(date)

CLUSTER_NAME="$cluster_name"
CLUSTER_DOMAIN="$cluster_domain"
CONTROL_PLANE_IP="$control_plane_ip"
CONTROL_PLANE_SSH_USER="$ssh_user"
EOF
            
            # Add repo path if detected
            if [ -n "$repo_path" ]; then
                echo "CONTROL_PLANE_REPO_PATH=\"$repo_path\"" >> "$CONFIG_DIR/config.env"
            fi
            
            log_success "Configuration saved to $CONFIG_DIR/config.env"
            return 0
        else
            log_warn "Could not find cluster-info configmap"
            log_info "The control plane may not have been fully initialized"
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
