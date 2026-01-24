#!/bin/bash

###############################################################################
# Quick Install: VPS Edge Node
#
# This script automates the addition of a VPS Edge Node from the Control Plane.
#
# Usage:
#   sudo ./scripts/installation/install-vps-edge-node.sh \
#     --name <node-name> \
#     --tailscale-ip <tailscale-ip> \
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
        --tailscale-ip)
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
            echo "Usage: sudo $0 --name <name> --tailscale-ip <tailscale-ip> --user <ssh-user> --public-ip <public-ip> --domain <domain>"
            exit 1
            ;;
    esac
done

# Validate required arguments
REQUIRED_MISSING=false
if [ -z "$VPS_NODE_NAME" ]; then echo "Missing required argument: --name"; REQUIRED_MISSING=true; fi
if [ -z "$VPS_TAILSCALE_IP" ]; then echo "Missing required argument: --tailscale-ip"; REQUIRED_MISSING=true; fi
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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Export for use by orchestrator
export PROJECT_ROOT
export SCRIPT_DIR

# Detect user
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

# Load cluster configuration
CLUSTER_CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [ -f "$CLUSTER_CONFIG_FILE" ]; then
    source "$CLUSTER_CONFIG_FILE"
else
    echo "Cluster configuration not found at $CLUSTER_CONFIG_FILE"
    exit 1
fi

# Get control plane IP from Tailscale
CONTROL_PLANE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -z "$CONTROL_PLANE_IP" ]; then
    echo "Failed to get control plane IP from Tailscale"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VPS Edge Node Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "VPS Node Name:  $VPS_NODE_NAME"
echo "VPS IP:         $VPS_TAILSCALE_IP"
echo "Public IP:      $VPS_PUBLIC_IP"
echo "Domain:         $VPS_DOMAIN"
echo "Location:       $VPS_LOCATION"
echo "Control Plane:  $CONTROL_PLANE_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Source the VPS orchestrator
source "$SCRIPT_DIR/../lib/vps-orchestrator.sh"

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
    echo "✅ VPS installation successful"
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
            ((attempt++))
        done
    }
    
    echo "Step 1: Collecting VPS Metadata"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo "ℹ Collecting comprehensive metadata from VPS..."
    VPS_METADATA_JSON=""
    
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$VPS_SSH_USER@$VPS_TAILSCALE_IP" \
        "test -f ~/mynodeone/scripts/lib/collect-vps-metadata.sh" 2>/dev/null; then
        
        VPS_METADATA_JSON=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$VPS_SSH_USER@$VPS_TAILSCALE_IP" \
            "sudo -E bash ~/mynodeone/scripts/lib/collect-vps-metadata.sh json" 2>/dev/null || echo "")
        
        if [ -n "$VPS_METADATA_JSON" ]; then
            echo "✅ Metadata collected successfully"
            echo ""
            echo "Collected metadata:"
            echo "$VPS_METADATA_JSON" | jq -C '.' || echo "$VPS_METADATA_JSON"
        else
            echo "⚠ Failed to collect metadata, will use basic registration"
        fi
    else
        echo "⚠ Metadata collector not found on VPS, will use basic registration"
    fi
    echo
    
    # 2. Register in Sync Controller Registry with Enhanced Metadata
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2: Enhanced VPS Registration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Source the registry manager to use enhanced registration
    source "$SCRIPT_DIR/../lib/node-registry-manager.sh"
    
    if [ -n "$VPS_METADATA_JSON" ]; then
        # Use enhanced registration with metadata
        echo "ℹ Registering VPS with comprehensive metadata..."
        if register_vps_node \
            --name "$VPS_NODE_NAME" \
            --tailscale-ip "$VPS_TAILSCALE_IP" \
            --public-ip "$VPS_PUBLIC_IP" \
            --ssh-user "$VPS_SSH_USER" \
            --location "$VPS_LOCATION" \
            --provider "unknown" \
            --metadata-json "$VPS_METADATA_JSON"; then
            echo "✅ VPS registered with comprehensive metadata"
        else
            REGISTRATION_FAILED=true
            echo "❌ Failed to register VPS with metadata"
            echo "   Falling back to basic registration..."
            
            # Fallback to basic registration
            if retry_command "Basic VPS registration" \
                sudo "$SCRIPT_DIR/../lib/sync-controller.sh" register vps_nodes \
                "$VPS_TAILSCALE_IP" "$VPS_NODE_NAME" "$VPS_SSH_USER"; then
                echo "✅ VPS registered with basic configuration"
            else
                REGISTRATION_FAILED=true
                echo "❌ Failed to register VPS"
            fi
        fi
    else
        # Basic registration without metadata
        if retry_command "Basic VPS registration" \
            sudo "$SCRIPT_DIR/../lib/sync-controller.sh" register vps_nodes \
            "$VPS_TAILSCALE_IP" "$VPS_NODE_NAME" "$VPS_SSH_USER"; then
            echo "✅ VPS registered with basic configuration"
        else
            REGISTRATION_FAILED=true
            echo "❌ Failed to register VPS"
        fi
    fi
    echo
    
    # 3. Register in Domain Registry
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2: Domain Registry - VPS Node"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Registering VPS in domain registry" \
        sudo "$SCRIPT_DIR/../lib/multi-domain-registry.sh" register-vps \
        "$VPS_TAILSCALE_IP" "$VPS_PUBLIC_IP" "$VPS_LOCATION" "unknown"; then
        REGISTRATION_FAILED=true
        echo "❌ Failed to register VPS in domain registry"
        echo "   Manual registration: sudo $SCRIPT_DIR/../lib/multi-domain-registry.sh register-vps $VPS_TAILSCALE_IP $VPS_PUBLIC_IP $VPS_LOCATION unknown"
    fi
    echo
    
    # 4. Register Domain
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 3: Domain Registry - Domain"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Registering domain" \
        sudo "$SCRIPT_DIR/../lib/multi-domain-registry.sh" register-domain \
        "$VPS_DOMAIN" 'VPS edge node domain'; then
        REGISTRATION_FAILED=true
        echo "❌ Failed to register domain"
        echo "   Manual registration: sudo $SCRIPT_DIR/../lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'VPS domain'"
    fi
    echo
    
    # 5. Initial Sync
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 4: Initial Sync and Verification"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! retry_command "Initial sync" \
        sudo "$SCRIPT_DIR/../lib/sync-controller.sh" push; then
        echo "⚠ Initial sync failed, VPS may need manual sync"
    fi
    
    # 6. Verification
    echo "ℹ Verifying registration..."
    echo
    
    # Check sync controller registry
    if sudo "$SCRIPT_DIR/../lib/sync-controller.sh" health | grep -q "$VPS_TAILSCALE_IP"; then
        echo "✅ VPS found in sync controller registry"
    else
        echo "❌ VPS not found in sync controller registry"
    fi
    
    # Check domain registry
    if sudo kubectl get configmap domain-registry -n kube-system -o jsonpath='{.data.vps\.json}' 2>/dev/null | jq -e ".\"$VPS_TAILSCALE_IP\"" >/dev/null; then
        echo "✅ VPS found in domain registry"
    else
        echo "❌ VPS not found in domain registry"
    fi
    
    # Check domain registration
    if sudo kubectl get configmap domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' 2>/dev/null | jq -e ".\"$VPS_DOMAIN\"" >/dev/null; then
        echo "✅ Domain found in registry"
    else
        echo "❌ Domain not found in registry"
    fi
    
    echo
    
    # 7. Final Status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$REGISTRATION_FAILED" = true ]; then
        echo "⚠ VPS installation completed with some issues"
        echo ""
        echo "Manual steps may be required:"
        echo "  1. Check VPS connectivity: ssh $VPS_SSH_USER@$VPS_TAILSCALE_IP"
        echo "  2. Verify VPS setup: ssh $VPS_SSH_USER@$VPS_TAILSCALE_IP 'sudo systemctl status mynodeone-node-agent'"
        echo "  3. Manual registration if needed"
    else
        echo "✅ VPS registration completed successfully"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "✅ VPS Edge Node: $VPS_NODE_NAME"
    echo "   Tailscale IP:  $VPS_TAILSCALE_IP"
    echo "   Public IP:     $VPS_PUBLIC_IP"
    echo "   Domain:        $VPS_DOMAIN"
    echo
    echo "Next steps:"
    echo "  1. Make apps public: sudo ./scripts/operations/manage-app-visibility.sh"
    echo "  2. Check cluster nodes: sudo ./scripts/nodes/nodes-status.sh"
    
else
    echo
    echo "❌ VPS installation failed"
    echo
    echo "Troubleshooting:"
    echo "  1. SSH into VPS: ssh $VPS_SSH_USER@$VPS_TAILSCALE_IP"
    echo "  2. Check installation logs: ssh $VPS_SSH_USER@$VPS_TAILSCALE_IP 'cat ~/mynodeone-install.log'"
    echo "  3. Verify prerequisites: ssh $VPS_SSH_USER@$VPS_TAILSCALE_IP 'docker --version'"
    echo
    echo "To complete registration manually, run:"
    echo "  cd ~/MyNodeOne"
    echo "  sudo ./scripts/lib/sync-controller.sh register vps_nodes $VPS_TAILSCALE_IP $VPS_NODE_NAME $VPS_SSH_USER"
    echo "  sudo ./scripts/lib/multi-domain-registry.sh register-vps $VPS_TAILSCALE_IP $VPS_PUBLIC_IP $VPS_LOCATION unknown"
    echo "  sudo ./scripts/lib/multi-domain-registry.sh register-domain $VPS_DOMAIN 'VPS domain'"
    echo
    echo "Then verify with:"
    echo "  sudo ./scripts/nodes/nodes-status.sh"
    exit 1
fi
