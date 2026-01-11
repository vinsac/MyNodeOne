#!/bin/bash

###############################################################################
# Setup Management Node for Enterprise Registry
# 
# Auto-registers management laptop and configures for automatic sync
# Run this on each management laptop/desktop
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source SSH utilities for ControlMaster support
source "$SCRIPT_DIR/../lib/ssh-utils.sh"

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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  💻 Management Laptop Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect actual user and home directory
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

# Load configuration
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration not found!"
    echo "Please run the management laptop setup first:"
    echo "  sudo ./scripts/installation/install-mynodeone.sh"
    echo "  (Select option 4: Management Workstation)"
    exit 1
fi

source "$CONFIG_FILE"

# Get laptop details
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
HOSTNAME=$(hostname)
USERNAME="$ACTUAL_USER"

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    echo "Please ensure Tailscale is installed and running"
    exit 1
fi

log_info "Laptop Details:"
echo "  • Tailscale IP: $TAILSCALE_IP"
echo "  • Hostname: $HOSTNAME"
echo "  • Username: $USERNAME"
echo ""

# Check required config
if [ -z "${CONTROL_PLANE_IP:-}" ]; then
    log_error "CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"
    exit 1
fi

echo ""
log_info "Registering with control plane..."
echo ""

# Register this laptop in sync controller
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

# Setup SSH ControlMaster for passwordless subsequent connections
log_info "Setting up SSH connection..."
if validate_ssh_early "$CONTROL_PLANE_SSH_USER" "$CONTROL_PLANE_IP" "control plane"; then
    setup_ssh_control_master "$CONTROL_PLANE_SSH_USER" "$CONTROL_PLANE_IP"
    log_success "SSH ControlMaster established"
    echo ""
else
    log_error "SSH connection failed"
    exit 1
fi

# Install kubectl if not present
if ! command -v kubectl &> /dev/null; then
    log_info "Installing kubectl..."
    
    # Download kubectl
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" 2>/dev/null
    
    # Install it
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    
    log_success "kubectl installed"
    echo ""
else
    log_info "kubectl already installed"
    echo ""
fi

# Check if we already have the path saved in config
CONTROL_PLANE_REPO_PATH="${CONTROL_PLANE_REPO_PATH:-}"

if [ -z "$CONTROL_PLANE_REPO_PATH" ]; then
    # Try to get authoritative path from cluster configmap first
    log_info "Fetching MyNodeOne path from cluster config..."
    
    MYNODEONE_PATH=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}' 2>/dev/null" || echo "")
    
    if [ -n "$MYNODEONE_PATH" ]; then
        log_success "Found authoritative path from cluster: $MYNODEONE_PATH"
    else
        # Fallback: search filesystem (for backwards compatibility)
        log_info "No path in cluster config, searching filesystem..."
        
        # Search common locations (user-agnostic)
        MYNODEONE_PATH=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
            "find /root /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1" 2>/dev/null)
        
        if [ -z "$MYNODEONE_PATH" ]; then
            log_warn "Could not auto-detect MyNodeOne path on control plane"
            log_info "Trying standard locations..."
            
            # Try recommended and common paths
            for path in ~/MyNodeOne /root/MyNodeOne /opt/MyNodeOne; do
                if ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "[ -d '$path' ]" 2>/dev/null; then
                    MYNODEONE_PATH="$path"
                    break
                fi
            done
        fi
        
        if [ -n "$MYNODEONE_PATH" ]; then
            log_success "Found MyNodeOne at: $MYNODEONE_PATH"
        fi
    fi
    
    if [ -n "$MYNODEONE_PATH" ]; then
        # Save the path for future use
        if ! grep -q "CONTROL_PLANE_REPO_PATH" ~/.mynodeone/config.env 2>/dev/null; then
            echo "CONTROL_PLANE_REPO_PATH=\"$MYNODEONE_PATH\"" >> ~/.mynodeone/config.env
            log_info "Saved repo path to config for future use"
        fi
        
        CONTROL_PLANE_REPO_PATH="$MYNODEONE_PATH"
    else
        log_warn "Could not find MyNodeOne on control plane"
        log_info "Skipping registry registration (can be done manually later)"
        log_info ""
        log_info "💡 Recommended: Install MyNodeOne at ~/MyNodeOne on control plane"
    fi
fi

if [ -n "$CONTROL_PLANE_REPO_PATH" ]; then
    log_info "Using MyNodeOne at: $CONTROL_PLANE_REPO_PATH"
    
    # Get laptop's repo path (where this script is running from)
    LAPTOP_REPO_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
    log_info "Laptop repo path: $LAPTOP_REPO_PATH"
    
    # Register using new registry manager (auto-detects user, validates in ConfigMap)
    # SKIP_SSH_VALIDATION=true because management laptops don't need SSH server
    # Pass laptop repo path so sync-controller knows where to run scripts
    log_info "Registering in enterprise registry..."
    ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd '$CONTROL_PLANE_REPO_PATH' && sudo SKIP_SSH_VALIDATION=true ./scripts/lib/node-registry-manager.sh register management_laptops \
        $TAILSCALE_IP $HOSTNAME $USERNAME 8080 '$LAPTOP_REPO_PATH'" 2>&1 | grep -v "Warning: Permanently added"
    
    if [ $? -eq 0 ]; then
        log_success "Laptop registered in sync controller"
        
        # VALIDATION: Verify registration in ConfigMap
        log_info "Validating registration..."
        LAPTOP_CHECK=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
            "sudo kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' 2>/dev/null | jq -r '.management_laptops[] | select(.ip==\"$TAILSCALE_IP\") | .ssh_user'" 2>/dev/null || echo "")
        
        if [ "$LAPTOP_CHECK" = "$USERNAME" ]; then
            log_success "✓ Registration verified in ConfigMap"
            log_success "✓ Registered with user: $LAPTOP_CHECK"
        else
            log_warn "⚠ Could not verify registration (expected user: $USERNAME, got: ${LAPTOP_CHECK:-none})"
        fi
    else
        log_error "Registration failed"
        log_error "Manual registration: ./scripts/lib/node-registry-manager.sh register management_laptops $TAILSCALE_IP $HOSTNAME $USERNAME"
        # Don't exit - allow manual registration later
    fi
fi

# Cleanup SSH ControlMaster
cleanup_ssh_control_master "$CONTROL_PLANE_SSH_USER" "$CONTROL_PLANE_IP"

echo ""
log_info "Running initial sync..."
sudo ./scripts/sync-dns.sh

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Management Laptop Configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's configured:"
echo "  • Registered in control plane registry"
echo "  • DNS entries configured in /etc/hosts"
echo "  • kubectl access to cluster"
echo "  • Access services via .local domains"
echo "  • Automatic DNS sync enabled"
echo ""

log_info "How auto-sync works:"
echo "  • When apps are installed, control plane pushes DNS updates"
echo "  • Your laptop receives updates automatically via SSH"
echo "  • New services become accessible within ~10 seconds"
echo ""

log_info "Manual sync (if needed):"
echo "  cd ~/MyNodeOne && sudo ./scripts/sync-dns.sh"
echo ""

# Show current services
LOCAL_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}.local"
SERVICE_COUNT=$(grep "$LOCAL_DOMAIN" /etc/hosts 2>/dev/null | wc -l)
if [ -z "$SERVICE_COUNT" ]; then
    SERVICE_COUNT=0
fi
log_info "Currently configured services: $SERVICE_COUNT"
echo ""

if [ "$SERVICE_COUNT" -gt 0 ]; then
    echo "Available services:"
    grep "$LOCAL_DOMAIN" /etc/hosts | awk '{print "  • http://" $2}' | sort
    echo ""
fi

log_success "Management laptop registration complete! 🎉"
echo ""
