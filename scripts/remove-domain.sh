#!/bin/bash

###############################################################################
# Remove Domain from Cluster
# 
# Safely removes a domain and all its routing configuration
###############################################################################

set -euo pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-}"

clear
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🗑️  Remove Domain from Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check kubectl access
if ! kubectl get nodes &>/dev/null; then
    log_error "This script must be run on the control plane"
    exit 1
fi

# Get domain if not provided
if [ -z "$DOMAIN" ]; then
    DOMAINS=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r 'keys[]' || echo "")
    
    if [ -z "$DOMAINS" ]; then
        log_error "No domains registered"
        exit 1
    fi
    
    echo "Available domains:"
    echo ""
    
    declare -a domain_array
    i=1
    while read -r domain; do
        echo "  $i. $domain"
        domain_array[$i]="$domain"
        ((i++))
    done <<< "$DOMAINS"
    
    echo ""
    read -p "Select domain to remove: " domain_num
    
    DOMAIN="${domain_array[$domain_num]:-}"
fi

if [ -z "$DOMAIN" ]; then
    log_error "No domain selected"
    exit 1
fi

# Check if domain exists
if ! kubectl get configmap -n kube-system domain-registry \
    -o jsonpath="{.data.domains\.json}" 2>/dev/null | \
    jq -e ".[\"$DOMAIN\"]" &>/dev/null; then
    log_error "Domain $DOMAIN not found in registry"
    exit 1
fi

echo "Domain to remove: $DOMAIN"
echo ""

# Show services using this domain
AFFECTED_SERVICES=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.routing\.json}' 2>/dev/null | \
    jq -r "to_entries[] | select(.value.domains | index(\"$DOMAIN\")) | .key" || echo "")

if [ -n "$AFFECTED_SERVICES" ]; then
    log_warn "This domain is currently used by the following services:"
    echo ""
    
    while read -r service; do
        subdomain=$(kubectl get configmap -n kube-system service-registry \
            -o jsonpath="{.data.services\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].subdomain" 2>/dev/null || echo "")
        
        other_domains=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].domains[]" 2>/dev/null | grep -v "^$DOMAIN$" | tr '\n' ',' || echo "")
        
        if [ -n "$other_domains" ]; then
            echo "  • $service (${subdomain}) - still on: ${other_domains%,}"
        else
            echo "  • $service (${subdomain}) - ⚠️  will no longer be public"
        fi
    done <<< "$AFFECTED_SERVICES"
    echo ""
fi

log_warn "⚠️  WARNING: This action will:"
echo "  • Remove $DOMAIN from the cluster"
echo "  • Update routing for affected services"
echo "  • Push configuration to all VPS nodes"
echo ""

read -p "Are you sure you want to remove $DOMAIN? (type 'yes' to confirm): " confirm

if [ "$confirm" != "yes" ]; then
    log_info "Removal cancelled"
    exit 0
fi

echo ""
log_info "Removing domain $DOMAIN..."
echo ""

# Remove domain from affected services
if [ -n "$AFFECTED_SERVICES" ]; then
    log_info "Updating service routing..."
    
    while read -r service; do
        # Get domains without this one
        new_domains=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].domains[]" 2>/dev/null | \
            grep -v "^$DOMAIN$" | tr '\n' ',' | sed 's/,$//' || echo "")
        
        # Get VPS nodes
        vps_nodes=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].vps_nodes[]" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
        
        # Update routing
        bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" configure-routing \
            "$service" "$new_domains" "$vps_nodes" "round-robin" &>/dev/null || true
        
        log_success "✓ Updated $service"
    done <<< "$AFFECTED_SERVICES"
fi

# Remove domain from registry
log_info "Removing domain from registry..."

domains_json=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.domains\.json}' 2>/dev/null)

new_domains_json=$(echo "$domains_json" | jq "del(.[\"$DOMAIN\"])")

kubectl patch configmap domain-registry \
    -n kube-system \
    --type merge \
    -p "{\"data\":{\"domains.json\":\"$(echo "$new_domains_json" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"

log_success "Domain removed from registry"

# Push updates to VPS
echo ""
log_info "Pushing updates to VPS nodes..."
bash "$SCRIPT_DIR/lib/sync-controller.sh" push || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Domain Removed Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "Domain $DOMAIN has been removed from the cluster"
echo ""

if [ -n "$AFFECTED_SERVICES" ]; then
    log_info "Affected services have been updated"
    log_info "VPS nodes have been reconfigured"
    echo ""
    
    log_warn "Don't forget to:"
    echo "  • Remove DNS records for $DOMAIN from your registrar"
    echo "  • SSL certificates will expire naturally (no action needed)"
fi

echo ""
log_success "Removal complete! 🎉"
echo ""
