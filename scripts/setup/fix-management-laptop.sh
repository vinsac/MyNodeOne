#!/bin/bash

###############################################################################
# Fix Management Laptop Registration
#
# This script fixes management laptops where registration failed during setup.
# It completes the registration and installs the node agent.
#
# Usage:
#   sudo ./scripts/setup/fix-management-laptop.sh
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

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Source SSH utilities
if [ -f "$PROJECT_ROOT/scripts/lib/ssh-utils.sh" ]; then
    source "$PROJECT_ROOT/scripts/lib/ssh-utils.sh"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔧 Fix Management Laptop Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect actual user
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
    log_error "Configuration not found at $CONFIG_FILE"
    echo "Please run the management laptop setup first"
    exit 1
fi

source "$CONFIG_FILE"

# Get laptop details
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
HOSTNAME=$(hostname)
USERNAME="$ACTUAL_USER"

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    exit 1
fi

log_info "Laptop Details:"
echo "  • Tailscale IP: $TAILSCALE_IP"
echo "  • Hostname: $HOSTNAME"
echo "  • Username: $USERNAME"
echo "  • Control Plane: $CONTROL_PLANE_IP"
echo ""

# Check if control plane SSH user is set
if [ -z "${CONTROL_PLANE_SSH_USER:-}" ]; then
    log_warn "Control plane SSH user not found in config"
    echo -n "Enter SSH username on control plane [$USERNAME]: "
    read -r CONTROL_PLANE_SSH_USER
    CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-$USERNAME}"
fi

# Get control plane repo path
log_info "Fetching control plane MyNodeOne path..."
setup_ssh_control_master "$CONTROL_PLANE_SSH_USER" "$CONTROL_PLANE_IP"

CONTROL_PLANE_REPO_PATH=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "grep '^MYNODEONE_REPO_PATH=' ~/.mynodeone/config.env 2>/dev/null | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null || echo "")

if [ -z "$CONTROL_PLANE_REPO_PATH" ]; then
    log_warn "Could not fetch repo path from config, trying default location..."
    CONTROL_PLANE_REPO_PATH=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "if [ -d ~/MyNodeOne ]; then echo ~/MyNodeOne; elif [ -d /opt/MyNodeOne ]; then echo /opt/MyNodeOne; fi" 2>/dev/null || echo "")
fi

if [ -z "$CONTROL_PLANE_REPO_PATH" ]; then
    log_error "Could not determine MyNodeOne path on control plane"
    exit 1
fi

# Strip /scripts suffix if present (fix for incorrect ConfigMap path)
CONTROL_PLANE_REPO_PATH="${CONTROL_PLANE_REPO_PATH%/scripts}"

log_success "Found MyNodeOne at: $CONTROL_PLANE_REPO_PATH"

# Get laptop repo path
LAPTOP_REPO_PATH="$PROJECT_ROOT"
log_info "Laptop repo path: $LAPTOP_REPO_PATH"

# Step 1: Register in ConfigMap
echo ""
log_info "Step 1: Registering laptop in control plane registry..."
ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd '$CONTROL_PLANE_REPO_PATH' && sudo SKIP_SSH_VALIDATION=true '$CONTROL_PLANE_REPO_PATH/scripts/lib/node-registry-manager.sh' register management_laptops \
    $TAILSCALE_IP $HOSTNAME $USERNAME 8080 '$LAPTOP_REPO_PATH'" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "Laptop registered in control plane"
    
    # Verify registration
    LAPTOP_CHECK=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' 2>/dev/null | jq -r '.management_laptops[] | select(.ip==\"$TAILSCALE_IP\") | .ssh_user'" 2>/dev/null || echo "")
    
    if [ "$LAPTOP_CHECK" = "$USERNAME" ]; then
        log_success "✓ Registration verified in ConfigMap"
    else
        log_warn "⚠ Could not verify registration"
    fi
else
    log_error "Registration failed"
    exit 1
fi

# Step 2: Install node agent
echo ""
log_info "Step 2: Installing node agent for cluster visibility..."

# Fetch API token from control plane
API_TOKEN=$(ssh_with_control "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "sudo cat /etc/mynodeone/api-token 2>/dev/null" 2>/dev/null || echo "")

if [ -z "$API_TOKEN" ]; then
    log_error "Could not fetch API token from control plane"
    log_error "The Config API may not be installed on the control plane"
    log_info "You can install it with:"
    log_info "  ssh $CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP 'cd $CONTROL_PLANE_REPO_PATH && sudo ./scripts/installation/install-config-api.sh'"
    exit 1
fi

log_success "API token retrieved"

# Install node agent
if [ -f "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" ]; then
    "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" \
        --control-plane-ip "$CONTROL_PLANE_IP" \
        --node-type laptop \
        --node-name "$HOSTNAME" \
        --api-token "$API_TOKEN" \
        --poll-interval 60
    
    if [ $? -eq 0 ]; then
        log_success "Node agent installed successfully"
    else
        log_error "Node agent installation failed"
        exit 1
    fi
else
    log_error "Node agent installer not found"
    exit 1
fi

# Cleanup SSH ControlMaster
cleanup_ssh_control_master "$CONTROL_PLANE_SSH_USER" "$CONTROL_PLANE_IP"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Management Laptop Fixed!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What was fixed:"
echo "  • Registered in control plane ConfigMap"
echo "  • Node agent installed and running"
echo "  • Laptop will now appear in nodes-status"
echo ""

log_info "Verify your laptop is visible:"
echo "  ssh $CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP 'cd $CONTROL_PLANE_REPO_PATH && ./scripts/nodes/nodes-status.sh'"
echo ""

log_info "Check node agent status:"
echo "  sudo systemctl status mynodeone-node-agent"
echo ""

log_success "Fix complete! 🎉"
echo ""
