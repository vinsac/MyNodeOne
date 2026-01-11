#!/bin/bash

###############################################################################
# Configure Service Routing for Existing Domain
# 
# Add or remove services from an existing domain
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

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-}"

clear
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔧 Configure Domain Routing"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check kubectl access
if ! kubectl get nodes &>/dev/null; then
    log_error "This script must be run on the control plane"
    exit 1
fi

# Get domain if not provided
if [ -z "$DOMAIN" ]; then
    # Show available domains
    DOMAINS=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r 'keys[]' || echo "")
    
    if [ -z "$DOMAINS" ]; then
        log_error "No domains registered"
        echo "Add a domain first: sudo ./scripts/add-domain.sh"
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
    read -p "Select domain number: " domain_num
    
    DOMAIN="${domain_array[$domain_num]:-}"
    
    if [ -z "$DOMAIN" ]; then
        log_error "Invalid selection"
        exit 1
    fi
fi

echo "Configuring routing for: $DOMAIN"
echo ""

# Get all services
SERVICES=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' 2>/dev/null | \
    jq -r 'to_entries[] | "\(.key)|\(.value.subdomain)"' || echo "")

if [ -z "$SERVICES" ]; then
    log_error "No services found"
    exit 1
fi

# Show services currently on this domain
CURRENT_SERVICES=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.routing\.json}' 2>/dev/null | \
    jq -r "to_entries[] | select(.value.domains | index(\"$DOMAIN\")) | .key" || echo "")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Currently Exposed on $DOMAIN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -n "$CURRENT_SERVICES" ]; then
    while read -r service; do
        subdomain=$(echo "$SERVICES" | grep "^$service|" | cut -d'|' -f2)
        echo "  ✓ $service → https://${subdomain}.${DOMAIN}"
    done <<< "$CURRENT_SERVICES"
else
    echo "  (none)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Available Services"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

declare -a service_array
declare -a subdomain_array
i=1
while IFS='|' read -r service subdomain; do
    # Mark if already on this domain
    marker=""
    if echo "$CURRENT_SERVICES" | grep -q "^$service$"; then
        marker=" [currently on $DOMAIN]"
    fi
    echo "  $i. $service ($subdomain)$marker"
    service_array[$i]="$service"
    subdomain_array[$i]="$subdomain"
    ((i++))
done <<< "$SERVICES"

echo ""
echo "Select action:"
echo "  1. Add services to $DOMAIN"
echo "  2. Remove services from $DOMAIN"
echo "  3. Exit"
echo ""
read -p "Choice: " action_choice

case "$action_choice" in
    1)
        # Add services
        echo ""
        echo "Select services to ADD (comma-separated numbers):"
        read -p "Selection: " service_selection
        
        declare -a selected_services
        IFS=',' read -ra SELECTIONS <<< "$service_selection"
        for num in "${SELECTIONS[@]}"; do
            num=$(echo "$num" | xargs)
            if [ -n "${service_array[$num]:-}" ]; then
                selected_services+=("${service_array[$num]}")
            fi
        done
        
        if [ ${#selected_services[@]} -eq 0 ]; then
            log_error "No services selected"
            exit 1
        fi
        
        # Get VPS nodes for this domain
        VPS_NODES=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.vps-nodes\.json}' 2>/dev/null | \
            jq -r 'keys[]' | tr '\n' ',' | sed 's/,$//' || echo "")
        
        echo ""
        log_info "Adding services to $DOMAIN..."
        
        for service in "${selected_services[@]}"; do
            # Get existing domains for this service
            existing_domains=$(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
                jq -r ".[\"$service\"].domains[]?" 2>/dev/null | tr '\n' ',' || echo "")
            
            # Add this domain if not already there
            if ! echo "$existing_domains" | grep -q "$DOMAIN"; then
                all_domains="${existing_domains}${DOMAIN}"
                all_domains=$(echo "$all_domains" | sed 's/,$//')
                
                bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" configure-routing \
                    "$service" "$all_domains" "$VPS_NODES" "round-robin" 2>/dev/null || true
                
                log_success "✓ Added $service"
            else
                log_info "○ $service already on $DOMAIN"
            fi
        done
        
        echo ""
        log_success "Services added to $DOMAIN"
        ;;
        
    2)
        # Remove services
        if [ -z "$CURRENT_SERVICES" ]; then
            log_error "No services currently on $DOMAIN"
            exit 0
        fi
        
        echo ""
        echo "Services on $DOMAIN:"
        declare -a current_array
        i=1
        while read -r service; do
            subdomain=$(echo "$SERVICES" | grep "^$service|" | cut -d'|' -f2)
            echo "  $i. $service ($subdomain)"
            current_array[$i]="$service"
            ((i++))
        done <<< "$CURRENT_SERVICES"
        
        echo ""
        echo "Select services to REMOVE (comma-separated numbers):"
        read -p "Selection: " remove_selection
        
        declare -a remove_services
        IFS=',' read -ra SELECTIONS <<< "$remove_selection"
        for num in "${SELECTIONS[@]}"; do
            num=$(echo "$num" | xargs)
            if [ -n "${current_array[$num]:-}" ]; then
                remove_services+=("${current_array[$num]}")
            fi
        done
        
        if [ ${#remove_services[@]} -eq 0 ]; then
            log_error "No services selected"
            exit 1
        fi
        
        echo ""
        log_info "Removing services from $DOMAIN..."
        
        for service in "${remove_services[@]}"; do
            # Get existing domains for this service
            existing_domains=$(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
                jq -r ".[\"$service\"].domains[]?" 2>/dev/null | grep -v "^$DOMAIN$" | tr '\n' ',' || echo "")
            
            existing_domains=$(echo "$existing_domains" | sed 's/,$//')
            
            # Get VPS nodes
            vps_nodes=$(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
                jq -r ".[\"$service\"].vps_nodes[]?" 2>/dev/null | tr '\n' ',' || echo "")
            
            if [ -n "$existing_domains" ]; then
                # Still has other domains
                bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" configure-routing \
                    "$service" "$existing_domains" "$vps_nodes" "round-robin" 2>/dev/null || true
            else
                # No domains left, keep service but clear domain list
                bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" configure-routing \
                    "$service" "" "$vps_nodes" "round-robin" 2>/dev/null || true
            fi
            
            log_success "✓ Removed $service from $DOMAIN"
        done
        
        echo ""
        log_success "Services removed from $DOMAIN"
        ;;
        
    *)
        log_info "No changes made"
        exit 0
        ;;
esac

# Push updates
echo ""
log_info "Pushing updates to VPS nodes..."
bash "$SCRIPT_DIR/lib/sync-controller.sh" push || true

echo ""
log_success "Configuration complete! 🎉"
echo ""
