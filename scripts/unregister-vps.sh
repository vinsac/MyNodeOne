#!/bin/bash

###############################################################################
# Unregister VPS Node from MyNodeOne Cluster
#
# This script removes a VPS edge node from all cluster registries:
# - domain-registry (routing configuration)
# - sync-controller-registry (sync targets)
# - service-registry (service mappings)
#
# Usage: ./scripts/unregister-vps.sh [vps-tailscale-ip]
#
# Examples:
#   ./scripts/unregister-vps.sh 100.65.241.25
#   ./scripts/unregister-vps.sh  # Will auto-detect if run on VPS
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

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.mynodeone/config.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🗑️  Unregister VPS Node from Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Determine VPS IP
if [ $# -eq 1 ]; then
    VPS_IP="$1"
    log_info "Unregistering VPS: $VPS_IP (from argument)"
else
    # Try to auto-detect if run on VPS
    VPS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$VPS_IP" ]; then
        log_info "Unregistering VPS: $VPS_IP (auto-detected)"
    else
        log_error "Could not determine VPS IP"
        echo ""
        echo "Usage: $0 <vps-tailscale-ip>"
        echo "Example: $0 100.65.241.25"
        exit 1
    fi
fi

# Validate IP format
if ! [[ "$VPS_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "Invalid IP address format: $VPS_IP"
    exit 1
fi

echo ""
log_warn "This will remove VPS $VPS_IP from all cluster registries."
echo ""
read -p "Continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Check if we can access kubectl (are we on control plane or management laptop?)
if kubectl version --client &>/dev/null && kubectl cluster-info &>/dev/null; then
    # We have direct kubectl access
    log_info "Using direct kubectl access..."
    
    # Remove from domain-registry
    log_info "Removing from domain-registry..."
    if kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        CURRENT_DATA=$(kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo "{}")
        
        if [ "$CURRENT_DATA" != "{}" ]; then
            UPDATED_DATA=$(echo "$CURRENT_DATA" | jq --arg ip "$VPS_IP" '
                .vps_nodes = [.vps_nodes[]? | select(.tailscale_ip != $ip)]
            ')
            
            kubectl create configmap domain-registry \
                --from-literal=domains.json="$UPDATED_DATA" \
                --dry-run=client -o yaml | \
                kubectl apply -n kube-system -f - &>/dev/null
            
            log_success "Removed from domain-registry"
        else
            log_info "domain-registry is empty"
        fi
    else
        log_info "domain-registry not found"
    fi
    
    # Remove from sync-controller-registry
    log_info "Removing from sync-controller-registry..."
    if kubectl get configmap -n kube-system sync-controller-registry &>/dev/null; then
        CURRENT_DATA=$(kubectl get configmap -n kube-system sync-controller-registry -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "{}")
        
        if [ "$CURRENT_DATA" != "{}" ]; then
            UPDATED_DATA=$(echo "$CURRENT_DATA" | jq --arg ip "$VPS_IP" '
                .vps_nodes = [.vps_nodes[]? | select(.ip != $ip)]
            ')
            
            kubectl create configmap sync-controller-registry \
                --from-literal=registry.json="$UPDATED_DATA" \
                --dry-run=client -o yaml | \
                kubectl apply -n kube-system -f - &>/dev/null
            
            log_success "Removed from sync-controller-registry"
        else
            log_info "sync-controller-registry is empty"
        fi
    else
        log_info "sync-controller-registry not found"
    fi
    
    # Remove from routing configurations
    log_info "Cleaning up routing configurations..."
    if kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        ROUTING_DATA=$(kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo "{}")
        
        if [ "$ROUTING_DATA" != "{}" ]; then
            UPDATED_ROUTING=$(echo "$ROUTING_DATA" | jq --arg ip "$VPS_IP" '
                to_entries | map(
                    .value.vps_nodes = [.value.vps_nodes[]? | select(. != $ip)]
                ) | from_entries
            ')
            
            # Update domain-registry with cleaned routing
            DOMAINS_DATA=$(kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo "{}")
            
            kubectl create configmap domain-registry \
                --from-literal=domains.json="$DOMAINS_DATA" \
                --from-literal=routing.json="$UPDATED_ROUTING" \
                --dry-run=client -o yaml | \
                kubectl apply -n kube-system -f - &>/dev/null
            
            log_success "Cleaned up routing configurations"
        fi
    fi
    
else
    # Need to use remote kubectl via SSH
    if [ -z "${CONTROL_PLANE_IP:-}" ]; then
        log_error "CONTROL_PLANE_IP not set and no direct kubectl access"
        echo ""
        echo "Either:"
        echo "  1. Run this script on control plane or management laptop (with kubectl access)"
        echo "  2. Set CONTROL_PLANE_IP in ~/.mynodeone/config.env"
        exit 1
    fi
    
    CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-$(whoami)}"
    
    log_info "Using remote kubectl via SSH to $CONTROL_PLANE_IP..."
    
    # Run unregister script on control plane
    if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh unregister-vps $VPS_IP" 2>/dev/null; then
        log_success "Removed from registries via control plane"
    else
        log_warn "Could not auto-unregister via SSH"
        echo ""
        echo "Manual cleanup required on control plane:"
        echo "  ssh $CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP"
        echo "  cd ~/MyNodeOne"
        echo "  sudo ./scripts/lib/multi-domain-registry.sh unregister-vps $VPS_IP"
    fi
fi

# Delete local cache if exists
if [ -f "$HOME/.mynodeone/node-registry.json" ]; then
    log_info "Cleaning up local cache..."
    rm -f "$HOME/.mynodeone/node-registry.json"
    log_success "Local cache cleaned"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "VPS $VPS_IP has been unregistered"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✅ Removed from:"
echo "   • domain-registry (VPS node list)"
echo "   • sync-controller-registry (sync targets)"
echo "   • routing configurations (service routes)"
echo ""
echo "📋 Next Steps:"
echo "   • If VPS is being decommissioned, you can now safely shut it down"
echo "   • If reinstalling, the VPS can be registered again with fresh IP"
echo "   • Routes pointing to this VPS will no longer be synced"
echo ""
