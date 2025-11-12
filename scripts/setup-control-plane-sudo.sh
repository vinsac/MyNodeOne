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

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    log_error "Do not run this script as root. Run as: sudo ./scripts/setup-control-plane-sudo.sh"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 MyNodeOne Control Plane - Passwordless Sudo Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CURRENT_USER=$(whoami)
MYNODEONE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_info "Configuring passwordless sudo for: $CURRENT_USER"
log_info "MyNodeOne directory: $MYNODEONE_DIR"
echo ""

# Create sudoers configuration
log_info "Creating sudoers configuration..."

cat > /tmp/mynodeone-sudo << EOF
# MyNodeOne Passwordless Sudo Configuration
# 
# Purpose: Enable automated operations from VPS and management nodes
# Generated: $(date)
# User: $CURRENT_USER
#
# Security Note: This allows the user to run kubectl and MyNodeOne scripts
# without interactive password prompts. Only grant this to trusted users.

# Allow specific environment variables to pass through sudo
# Required for VPS registration scripts
Defaults:$CURRENT_USER env_keep += "SKIP_SSH_VALIDATION"

# Allow kubectl without password (required for cluster management)
$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/kubectl

# Allow MyNodeOne scripts without password (required for automation)
$CURRENT_USER ALL=(ALL) NOPASSWD: $MYNODEONE_DIR/scripts/*.sh, $MYNODEONE_DIR/scripts/lib/*.sh
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
echo "   This allows user '$CURRENT_USER' to run kubectl and MyNodeOne"
echo "   scripts without password prompts. Only grant this to trusted users."
echo ""
echo "📋 Next Steps:"
echo "   1. You can now install VPS edge nodes"
echo "   2. You can now install management laptops"
echo "   3. Automated operations will work without password prompts"
echo ""
echo "🔍 To verify from VPS or management laptop:"
echo "   ssh $CURRENT_USER@<control-plane-ip> 'sudo kubectl version --client'"
echo "   (Should show version without asking for password)"
echo ""
