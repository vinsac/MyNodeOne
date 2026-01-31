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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

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
    jq -e ".domains[\"$DOMAIN\"]" &>/dev/null; then
    log_error "Domain $DOMAIN not found in registry"
    exit 1
fi

echo "Domain to remove: $DOMAIN"
echo ""

# Show services using this domain
AFFECTED_SERVICES=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.routing\.json}' 2>/dev/null | \
    jq -r "to_entries[] | select(.value.expose[] | endswith(\"$DOMAIN\")) | .key" || echo "")

if [ -n "$AFFECTED_SERVICES" ]; then
    log_warn "This domain is currently used by the following services:"
    echo ""
    
    while read -r service; do
        local_name=$(kubectl get configmap -n kube-system service-registry \
            -o jsonpath="{.data.services\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].local_name" 2>/dev/null || echo "$service")
        
        exposed_urls=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].expose[]" 2>/dev/null | grep "$DOMAIN" | tr '\n' ',' || echo "")
        
        echo "  • $service ($local_name) - exposed at: ${exposed_urls%,}"
    done <<< "$AFFECTED_SERVICES"
    echo ""
fi

log_warn "⚠️  WARNING: This action will:"
echo "  • Remove $DOMAIN from the cluster registry"
echo "  • Remove affected URLs from service routing"
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

# Remove specific URLs from affected services
if [ -n "$AFFECTED_SERVICES" ]; then
    log_info "Cleaning up service routing..."
    
    while read -r service; do
        # Get URLs ending with this domain
        urls_to_remove=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
            jq -r ".[\"$service\"].expose[]" 2>/dev/null | grep "$DOMAIN" || echo "")
        
        while read -r url; do
            if [ -n "$url" ]; then
                bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" remove-domain "$service" "$url" &>/dev/null || true
            fi
        done <<< "$urls_to_remove"
        
        log_success "✓ Cleaned up $service"
    done <<< "$AFFECTED_SERVICES"
fi

# Remove domain from registry
log_info "Removing domain from registry..."
bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" unregister-domain "$DOMAIN"

log_success "Domain removed from registry"

# Push updates to VPS
echo ""
log_info "Pushing updates to VPS nodes..."
bash "$PROJECT_ROOT/scripts/lib/sync-controller.sh" push || true

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
