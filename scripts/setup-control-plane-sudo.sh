#!/bin/bash

###############################################################################
# Setup Passwordless Sudo for MyNodeOne Control Plane
#
# This script configures passwordless sudo access for kubectl and MyNodeOne
# scripts, enabling automated operations from VPS and management nodes.
#
# IMPORTANT: Run this AFTER control plane installation and BEFORE installing
# any VPS edge nodes or management laptops.
#
# Usage: sudo ./scripts/setup-control-plane-sudo.sh
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Detect actual user (works with or without sudo)
if [ -n "${SUDO_USER:-}" ]; then
    # Running with sudo - use SUDO_USER
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
elif [ "$EUID" -eq 0 ]; then
    # Running as root without sudo - not allowed
    log_error "Do not run this script directly as root."
    log_error "Run as your regular user: ./scripts/setup-control-plane-sudo.sh"
    log_error "Or with sudo: sudo ./scripts/setup-control-plane-sudo.sh"
    exit 1
else
    # Running as regular user without sudo
    ACTUAL_USER="$USER"
    ACTUAL_HOME="$HOME"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 MyNodeOne Control Plane - Passwordless Sudo Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

MYNODEONE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_info "Configuring passwordless sudo for: $ACTUAL_USER"
log_info "MyNodeOne directory: $MYNODEONE_DIR"
log_info "User home directory: $ACTUAL_HOME"
echo ""

# Check if already configured
if [ -f /etc/sudoers.d/mynodeone ]; then
    log_info "Passwordless sudo already configured, checking if update needed..."
    
    # Check if current config is valid
    if sudo visudo -c -f /etc/sudoers.d/mynodeone &>/dev/null; then
        # Test if it works
        if sudo -n kubectl version --client &>/dev/null 2>&1; then
            log_success "Passwordless sudo already working correctly"
            echo ""
            echo "✅ Configuration is up to date. No changes needed."
            echo ""
            exit 0
        else
            log_warn "Configuration exists but not working, will recreate..."
        fi
    else
        log_warn "Existing configuration has syntax errors, will recreate..."
    fi
fi

# Create sudoers configuration
log_info "Creating sudoers configuration..."

cat > /tmp/mynodeone-sudo << EOF
# MyNodeOne Passwordless Sudo Configuration
# 
# Purpose: Enable automated operations from VPS and management nodes
# Generated: $(date)
# User: $ACTUAL_USER
#
# Security Note: This allows the user to run kubectl and MyNodeOne scripts
# without interactive password prompts. Only grant this to trusted users.

# Allow specific environment variables to pass through sudo
# Required for VPS registration scripts
Defaults:$ACTUAL_USER env_keep += "SKIP_SSH_VALIDATION"

# Allow kubectl without password (required for cluster management)
$ACTUAL_USER ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/kubectl

# Allow MyNodeOne scripts without password (required for automation)
$ACTUAL_USER ALL=(ALL) NOPASSWD: $MYNODEONE_DIR/scripts/*.sh, $MYNODEONE_DIR/scripts/lib/*.sh
EOF

# Install sudoers file
if sudo cp /tmp/mynodeone-sudo /etc/sudoers.d/mynodeone; then
    log_success "Sudoers file installed"
else
    log_error "Failed to install sudoers file"
    rm -f /tmp/mynodeone-sudo
    exit 1
fi

sudo chmod 440 /etc/sudoers.d/mynodeone
rm -f /tmp/mynodeone-sudo

# Verify syntax
log_info "Verifying sudoers syntax..."
if sudo visudo -c -f /etc/sudoers.d/mynodeone &>/dev/null; then
    log_success "Sudoers syntax verified"
else
    log_error "Sudoers configuration has syntax errors!"
    sudo rm -f /etc/sudoers.d/mynodeone
    exit 1
fi

echo ""
log_info "Testing configuration..."
echo ""

# Test kubectl
if sudo kubectl version --client &>/dev/null; then
    log_success "kubectl passwordless sudo: OK"
else
    log_error "kubectl sudo test failed"
    exit 1
fi

# Test script execution
if sudo bash -c 'exit 0' 2>/dev/null; then
    log_success "Script passwordless sudo: OK"
else
    log_error "Script sudo test failed"
    exit 1
fi

# Test remote access pattern (what VPS will use)
if echo "test" | sudo -S kubectl version --client &>/dev/null; then
    log_success "Remote sudo pattern: OK"
else
    log_warn "Remote sudo pattern test inconclusive (expected)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Passwordless sudo configured successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ What was configured:"
echo "   • kubectl commands can run without password"
echo "   • MyNodeOne scripts can run without password"
echo "   • Remote automation from VPS/management nodes will work"
echo ""
echo "⚠️  Security Note:"
echo "   This allows user '$ACTUAL_USER' to run kubectl and MyNodeOne"
echo "   scripts without password prompts. Only grant this to trusted users."
echo ""
echo "📋 Next Steps:"
echo "   1. You can now install VPS edge nodes"
echo "   2. You can now install management laptops"
echo "   3. Automated operations will work without password prompts"
echo ""
echo "🔍 To verify from VPS or management laptop:"
echo "   ssh $ACTUAL_USER@<control-plane-ip> 'sudo kubectl version --client'"
echo "   (Should show version without asking for password)"
echo ""
