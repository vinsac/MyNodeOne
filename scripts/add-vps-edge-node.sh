#!/bin/bash

###############################################################################
# Add VPS Edge Node from Control Plane
#
# This is a simplified, dedicated script to set up a VPS Edge Node.
# Run this FROM the Control Plane.
#
# Usage:
#   sudo ./scripts/add-vps-edge-node.sh
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Detect actual user
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER="$(whoami)"
    ACTUAL_HOME="$HOME"
fi

export ACTUAL_USER
export ACTUAL_HOME
export PROJECT_ROOT

# Source the VPS orchestrator library
source "$SCRIPT_DIR/lib/vps-orchestrator.sh"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

# Welcome
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Add VPS Edge Node to MyNodeOne Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This script will set up a VPS Edge Node from your Control Plane."
echo ""
echo "Prerequisites:"
echo "  ✓ VPS must have Ubuntu 24.04 LTS"
echo "  ✓ VPS must have Tailscale installed and running"
echo "  ✓ VPS must have a sudo user (not root) with passwordless sudo"
echo "  ✓ VPS must be reachable from Control Plane via Tailscale"
echo ""
read -p "Continue? [y/N]: " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Verify we're on Control Plane
echo ""
print_info "Verifying Control Plane..."

if [ ! -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    print_error "Control Plane configuration not found"
    print_error "This script must be run from a fully installed Control Plane"
    exit 1
fi

source "$ACTUAL_HOME/.mynodeone/config.env"

if [ "${NODE_TYPE:-}" != "control-plane" ]; then
    print_error "This script must be run from the Control Plane"
    print_error "Current node type: ${NODE_TYPE:-unknown}"
    exit 1
fi

print_success "Running on Control Plane: ${CLUSTER_NAME:-unknown}"

# Get Control Plane Tailscale IP
CONTROL_PLANE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -z "$CONTROL_PLANE_IP" ]; then
    print_error "Could not detect Control Plane Tailscale IP"
    read -p "Enter Control Plane Tailscale IP: " CONTROL_PLANE_IP
fi
print_info "Control Plane Tailscale IP: $CONTROL_PLANE_IP"

# Gather VPS information
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VPS Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "VPS Node Name (e.g., vps-edge-01): " VPS_NODE_NAME
read -p "VPS Tailscale IP (from 'tailscale ip -4' on VPS): " VPS_TAILSCALE_IP
read -p "VPS SSH Username (sudo user, NOT root): " VPS_SSH_USER
read -p "VPS Public IPv4 Address: " VPS_PUBLIC_IP
read -p "VPS Primary Domain (e.g., mydomain.com): " VPS_DOMAIN
read -p "SSL Email (for Let's Encrypt): " SSL_EMAIL
read -p "VPS Location (optional, e.g., NYC): " VPS_LOCATION

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configuration Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Control Plane:"
echo "  Cluster Name:        ${CLUSTER_NAME:-unknown}"
echo "  Tailscale IP:        $CONTROL_PLANE_IP"
echo ""
echo "VPS Edge Node:"
echo "  Node Name:           $VPS_NODE_NAME"
echo "  Tailscale IP:        $VPS_TAILSCALE_IP"
echo "  Public IP:           $VPS_PUBLIC_IP"
echo "  Domain:              $VPS_DOMAIN"
echo "  SSL Email:           $SSL_EMAIL"
[ -n "$VPS_LOCATION" ] && echo "  Location:            $VPS_LOCATION"
echo ""
echo "SSH Configuration:"
echo "  SSH User:            $VPS_SSH_USER"
echo "  SSH Target:          $VPS_SSH_USER@$VPS_TAILSCALE_IP (via Tailscale)"
echo ""

read -p "Proceed with installation? [y/N]: " response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Run orchestration
echo ""
orchestrate_vps_installation \
    "$VPS_NODE_NAME" \
    "$VPS_TAILSCALE_IP" \
    "$VPS_SSH_USER" \
    "$VPS_PUBLIC_IP" \
    "$VPS_DOMAIN" \
    "$SSL_EMAIL" \
    "$VPS_LOCATION" \
    "$CONTROL_PLANE_IP" \
    "$ACTUAL_USER" \
    "${CLUSTER_NAME:-mynodeone}" \
    "${CLUSTER_DOMAIN:-cluster.local}"

if [ $? -eq 0 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ VPS Edge Node Added Successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Next Steps:"
    echo "  1. Point your DNS A record for '$VPS_DOMAIN' to $VPS_PUBLIC_IP"
    echo "  2. Wait for DNS propagation (5 minutes to 48 hours)"
    echo "  3. Deploy your first app with public access"
    echo ""
    echo "Configuration saved to:"
    echo "  $ACTUAL_HOME/.mynodeone/vps-nodes/$VPS_NODE_NAME/"
    echo ""
else
    echo ""
    print_error "VPS installation failed. See errors above."
    exit 1
fi