#!/bin/bash

###############################################################################
# Quick Install: VPS Edge Node
#
# This script automates the addition of a VPS Edge Node from the Control Plane.
#
# Usage:
#   sudo ./scripts/install-vps-edge-node.sh \
#     --name <node-name> \
#     --ip <tailscale-ip> \
#     --user <ssh-user> \
#     --public-ip <public-ip> \
#     --domain <domain> \
#     [--email <email>] \
#     [--location <location>]
###############################################################################

set -euo pipefail

# Default values
VPS_NODE_NAME=""
VPS_TAILSCALE_IP=""
VPS_SSH_USER=""
VPS_PUBLIC_IP=""
VPS_DOMAIN=""
SSL_EMAIL=""
VPS_LOCATION="unknown"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            VPS_NODE_NAME="$2"
            shift 2
            ;;
        --ip)
            VPS_TAILSCALE_IP="$2"
            shift 2
            ;;
        --user)
            VPS_SSH_USER="$2"
            shift 2
            ;;
        --public-ip)
            VPS_PUBLIC_IP="$2"
            shift 2
            ;;
        --domain)
            VPS_DOMAIN="$2"
            shift 2
            ;;
        --email)
            SSL_EMAIL="$2"
            shift 2
            ;;
        --location)
            VPS_LOCATION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo $0 --name <name> --ip <tailscale-ip> --user <ssh-user> --public-ip <public-ip> --domain <domain>"
            exit 1
            ;;
    esac
done

# Validate required arguments
REQUIRED_MISSING=false
if [ -z "$VPS_NODE_NAME" ]; then echo "Missing required argument: --name"; REQUIRED_MISSING=true; fi
if [ -z "$VPS_TAILSCALE_IP" ]; then echo "Missing required argument: --ip"; REQUIRED_MISSING=true; fi
if [ -z "$VPS_SSH_USER" ]; then echo "Missing required argument: --user"; REQUIRED_MISSING=true; fi
if [ -z "$VPS_PUBLIC_IP" ]; then echo "Missing required argument: --public-ip"; REQUIRED_MISSING=true; fi
if [ -z "$VPS_DOMAIN" ]; then echo "Missing required argument: --domain"; REQUIRED_MISSING=true; fi

if [ "$REQUIRED_MISSING" = true ]; then
    exit 1
fi

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Export for use by orchestrator
export PROJECT_ROOT
export SCRIPT_DIR

# Detect user
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Load Control Plane Config
if [ ! -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    echo "Error: Control Plane configuration not found at $ACTUAL_HOME/.mynodeone/config.env"
    exit 1
fi
source "$ACTUAL_HOME/.mynodeone/config.env"

# Verify Control Plane
if [ "${NODE_TYPE:-}" != "control-plane" ]; then
    echo "Error: This script must be run on the Control Plane"
    exit 1
fi

# Get Control Plane IP
CONTROL_PLANE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "Error: Could not detect Control Plane Tailscale IP"
    exit 1
fi

# Use configured email if not provided
if [ -z "$SSL_EMAIL" ] && [ -n "${SSL_EMAIL:-}" ]; then
    SSL_EMAIL="${SSL_EMAIL}" # From config.env
fi
if [ -z "$SSL_EMAIL" ]; then
    echo "Warning: No SSL email provided. Let's Encrypt registration might fail."
    SSL_EMAIL="admin@$VPS_DOMAIN"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Adding VPS Edge Node (Orchestrated)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Node Name:      $VPS_NODE_NAME"
echo "VPS IP:         $VPS_TAILSCALE_IP"
echo "Public IP:      $VPS_PUBLIC_IP"
echo "Domain:         $VPS_DOMAIN"
echo "Location:       $VPS_LOCATION"
echo "Control Plane:  $CONTROL_PLANE_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Source orchestrator
source "$SCRIPT_DIR/lib/vps-orchestrator.sh"

# Run orchestration
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
    "${CLUSTER_DOMAIN:-mynodeone}"

if [ $? -eq 0 ]; then
    echo
    echo "✅ VPS installation successful!"
else
    echo
    echo "❌ VPS installation failed!"
    exit 1
fi
