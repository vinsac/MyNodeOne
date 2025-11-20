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
    echo
    
    # =========================================================================
    # Register VPS in Cluster Registries (Control Plane Side)
    # =========================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Registering VPS in Cluster"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    REGISTRATION_FAILED=false
    MAX_RETRIES=3
    RETRY_DELAY=2
    
    # Helper function for retrying commands
    retry_command() {
        local description="$1"
        shift
        local cmd=("$@")
        local attempt=1
        
        while [ $attempt -le $MAX_RETRIES ]; do
            echo "ℹ $description (attempt $attempt/$MAX_RETRIES)..."
            
            if "${cmd[@]}" 2>&1; then
                echo "✅ $description succeeded"
                return 0
            else
                if [ $attempt -lt $MAX_RETRIES ]; then
                    echo "⚠ $description failed, retrying in ${RETRY_DELAY}s..."
                    sleep $RETRY_DELAY
                else
                    echo "❌ $description failed after $MAX_RETRIES attempts"
                    return 1
                fi
            fi
            
            attempt=$((attempt + 1))
        done
        
        return 1
    }
    
    # 1. Register in Sync Controller Registry
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 1: Sync Controller Registration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Registering in sync controller" \
        sudo SKIP_SSH_VALIDATION=true "$SCRIPT_DIR/lib/sync-controller.sh" register vps_nodes \
        "$VPS_TAILSCALE_IP" "$VPS_NODE_NAME" "$VPS_SSH_USER"; then
        REGISTRATION_FAILED=true
        echo "❌ Failed to register in sync controller"
        echo "   Manual registration: sudo $SCRIPT_DIR/lib/sync-controller.sh register vps_nodes $VPS_TAILSCALE_IP $VPS_NODE_NAME $VPS_SSH_USER"
    fi
    echo
    
    # 2. Register VPS in Domain Registry
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2: Domain Registry - VPS Node"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Registering VPS in domain registry" \
        sudo "$SCRIPT_DIR/lib/multi-domain-registry.sh" register-vps \
        "$VPS_TAILSCALE_IP" "$VPS_PUBLIC_IP" "$VPS_LOCATION" "unknown"; then
        REGISTRATION_FAILED=true
        echo "❌ Failed to register VPS in domain registry"
        echo "   Manual registration: sudo $SCRIPT_DIR/lib/multi-domain-registry.sh register-vps $VPS_TAILSCALE_IP $VPS_PUBLIC_IP $VPS_LOCATION unknown"
    fi
    echo
    
    # 3. Register Domain
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 3: Domain Registry - Domain"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Registering domain" \
        sudo "$SCRIPT_DIR/lib/multi-domain-registry.sh" register-domain \
        "$VPS_DOMAIN" "VPS edge node domain"; then
        REGISTRATION_FAILED=true
        echo "❌ Failed to register domain"
        echo "   Manual registration: sudo $SCRIPT_DIR/lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'VPS edge node domain'"
    fi
    echo
    
    # 4. Verify Registration
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 4: Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    VERIFICATION_PASSED=true
    
    # Verify sync controller registry
    echo "ℹ Verifying sync controller registry..."
    if kubectl get configmap -n kube-system sync-controller-registry -o json 2>/dev/null | \
        jq -e ".data.\"registry.json\" | fromjson | .vps_nodes[] | select(.ip==\"$VPS_TAILSCALE_IP\")" &>/dev/null; then
        echo "✅ VPS found in sync controller registry"
    else
        echo "❌ VPS NOT found in sync controller registry"
        VERIFICATION_PASSED=false
    fi
    
    # Verify domain registry - VPS
    echo "ℹ Verifying domain registry (VPS)..."
    if kubectl get configmap -n kube-system domain-registry -o json 2>/dev/null | \
        jq -e ".data.\"domains.json\" | fromjson | .vps_nodes[] | select(.tailscale_ip==\"$VPS_TAILSCALE_IP\")" &>/dev/null; then
        echo "✅ VPS found in domain registry"
    else
        echo "❌ VPS NOT found in domain registry"
        VERIFICATION_PASSED=false
    fi
    
    # Verify domain registry - Domain
    echo "ℹ Verifying domain registry (domain)..."
    if kubectl get configmap -n kube-system domain-registry -o json 2>/dev/null | \
        jq -e ".data.\"domains.json\" | fromjson | .domains[\"$VPS_DOMAIN\"]" &>/dev/null; then
        echo "✅ Domain found in registry"
    else
        echo "❌ Domain NOT found in registry"
        VERIFICATION_PASSED=false
    fi
    echo
    
    # 5. Trigger Initial Sync
    if [ "$VERIFICATION_PASSED" = true ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Step 5: Initial Sync"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if retry_command "Triggering initial sync" \
            sudo "$SCRIPT_DIR/lib/sync-controller.sh" push; then
            echo "✅ Initial sync completed"
        else
            echo "⚠ Initial sync failed (will retry automatically via sync controller)"
        fi
        echo
    fi
    
    # Final Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$VERIFICATION_PASSED" = true ] && [ "$REGISTRATION_FAILED" = false ]; then
        echo "✅ VPS registration completed successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "✅ VPS Edge Node: $VPS_NODE_NAME"
        echo "   Tailscale IP:  $VPS_TAILSCALE_IP"
        echo "   Public IP:     $VPS_PUBLIC_IP"
        echo "   Domain:        $VPS_DOMAIN"
        echo
        echo "Next steps:"
        echo "  1. Make apps public: sudo ./scripts/manage-app-visibility.sh"
        echo "  2. Check VPS status: sudo ./scripts/lib/sync-controller.sh list"
        echo "  3. View Traefik dashboard: https://traefik.$VPS_DOMAIN"
        echo
    else
        echo "⚠ VPS registration completed with warnings"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "⚠ Some registration steps failed. VPS is installed but may not be fully integrated."
        echo
        echo "To complete registration manually, run:"
        echo "  cd ~/MyNodeOne"
        echo "  sudo ./scripts/lib/sync-controller.sh register vps_nodes $VPS_TAILSCALE_IP $VPS_NODE_NAME $VPS_SSH_USER"
        echo "  sudo ./scripts/lib/multi-domain-registry.sh register-vps $VPS_TAILSCALE_IP $VPS_PUBLIC_IP $VPS_LOCATION unknown"
        echo "  sudo ./scripts/lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'VPS domain'"
        echo
        echo "Then verify with:"
        echo "  kubectl get configmap -n kube-system sync-controller-registry -o yaml"
        echo "  kubectl get configmap -n kube-system domain-registry -o yaml"
        echo
    fi
else
    echo
    echo "❌ VPS installation failed!"
    exit 1
fi
