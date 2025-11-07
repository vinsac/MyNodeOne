#!/bin/bash

###############################################################################
# Add New Domain to Cluster
# 
# Interactive script to add a new public domain and configure service routing
# Use this when you purchase a new domain and want to expose apps through it
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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

clear
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Add New Domain to Your Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This script helps you add a new public domain to expose your apps."
echo ""

# Check if on control plane
if ! kubectl get nodes &>/dev/null; then
    log_error "This script must be run on the control plane"
    echo "Please SSH to your control plane node first"
    exit 1
fi

# Check if registries are initialized
if ! kubectl get configmap -n kube-system domain-registry &>/dev/null; then
    log_error "Domain registry not initialized"
    echo "Please run: sudo ./scripts/setup-enterprise-registry.sh"
    exit 1
fi

# Step 1: Get domain name
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 1: Domain Information"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "Enter your new domain (e.g., newdomain.com): " NEW_DOMAIN

if [ -z "$NEW_DOMAIN" ]; then
    log_error "Domain cannot be empty"
    exit 1
fi

# Validate domain format
if ! echo "$NEW_DOMAIN" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$'; then
    log_error "Invalid domain format"
    echo "Example: example.com, my-site.io, blog.net"
    exit 1
fi

read -p "Enter a description (optional): " DESCRIPTION
DESCRIPTION="${DESCRIPTION:-Domain added on $(date +%Y-%m-%d)}"

echo ""
log_info "Domain: $NEW_DOMAIN"
log_info "Description: $DESCRIPTION"
echo ""

# Step 2: Register domain
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 2: Registering Domain"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" register-domain "$NEW_DOMAIN" "$DESCRIPTION"
log_success "Domain registered in cluster"
echo ""

# Step 3: Select VPS nodes
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3: Select VPS Edge Nodes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get available VPS nodes
VPS_NODES=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.vps-nodes\.json}' 2>/dev/null | \
    jq -r 'to_entries[] | "\(.key)|\(.value.public_ip)|\(.value.region)"' || echo "")

if [ -z "$VPS_NODES" ]; then
    log_warn "No VPS nodes registered yet"
    echo ""
    echo "To add a VPS node:"
    echo "  1. Install VPS: sudo ./scripts/mynodeone → Option 3"
    echo "  2. Or manually: sudo ./scripts/setup-vps-node.sh"
    echo ""
    
    read -p "Do you want to continue without VPS? (y/n): " continue_choice
    if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
        exit 0
    fi
    SELECTED_VPS=""
else
    echo "Available VPS nodes:"
    echo ""
    
    declare -a vps_array
    i=1
    while IFS='|' read -r ip public_ip region; do
        echo "  $i. $ip → $public_ip ($region)"
        vps_array[$i]="$ip"
        ((i++))
    done <<< "$VPS_NODES"
    
    echo ""
    echo "Select VPS nodes for this domain (comma-separated numbers, or 'all'):"
    read -p "Selection: " vps_selection
    
    if [ "$vps_selection" = "all" ]; then
        SELECTED_VPS=$(echo "$VPS_NODES" | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')
    else
        selected_ips=()
        IFS=',' read -ra SELECTIONS <<< "$vps_selection"
        for num in "${SELECTIONS[@]}"; do
            num=$(echo "$num" | xargs)  # Trim whitespace
            if [ -n "${vps_array[$num]:-}" ]; then
                selected_ips+=("${vps_array[$num]}")
            fi
        done
        SELECTED_VPS=$(IFS=','; echo "${selected_ips[*]}")
    fi
    
    if [ -z "$SELECTED_VPS" ]; then
        log_error "No VPS nodes selected"
        exit 1
    fi
    
    echo ""
    log_success "Selected VPS: $SELECTED_VPS"
fi
echo ""

# Step 4: Select services to expose
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4: Select Services to Expose"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get available services
SERVICES=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' 2>/dev/null | \
    jq -r 'to_entries[] | "\(.key)|\(.value.subdomain)"' || echo "")

if [ -z "$SERVICES" ]; then
    log_warn "No services found in cluster"
    echo ""
    echo "Install apps first, then run this script again"
    exit 0
fi

echo "Available services:"
echo ""

declare -a service_array
declare -a subdomain_array
i=1
while IFS='|' read -r service subdomain; do
    echo "  $i. $service ($subdomain)"
    service_array[$i]="$service"
    subdomain_array[$i]="$subdomain"
    ((i++))
done <<< "$SERVICES"

echo ""
echo "Select services to expose on $NEW_DOMAIN:"
echo "(Enter numbers comma-separated, or 'all', or 'none' to configure later)"
read -p "Selection: " service_selection

if [ "$service_selection" = "none" ]; then
    log_info "Skipping service configuration"
    log_info "You can configure services later with:"
    echo "  sudo ./scripts/configure-domain-routing.sh $NEW_DOMAIN"
    echo ""
else
    declare -a selected_services
    
    if [ "$service_selection" = "all" ]; then
        for idx in "${!service_array[@]}"; do
            selected_services+=("${service_array[$idx]}")
        done
    else
        IFS=',' read -ra SELECTIONS <<< "$service_selection"
        for num in "${SELECTIONS[@]}"; do
            num=$(echo "$num" | xargs)
            if [ -n "${service_array[$num]:-}" ]; then
                selected_services+=("${service_array[$num]}")
            fi
        done
    fi
    
    if [ ${#selected_services[@]} -gt 0 ]; then
        echo ""
        log_info "Configuring routing for ${#selected_services[@]} service(s)..."
        echo ""
        
        for service in "${selected_services[@]}"; do
            log_info "Configuring: $service"
            
            # Get existing routing or create new
            existing_domains=$(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
                jq -r ".[\"$service\"].domains[]?" 2>/dev/null | tr '\n' ',' || echo "")
            
            existing_vps=$(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath="{.data.routing\.json}" 2>/dev/null | \
                jq -r ".[\"$service\"].vps_nodes[]?" 2>/dev/null | tr '\n' ',' || echo "$SELECTED_VPS")
            
            # Add new domain to existing domains
            all_domains="${existing_domains}${NEW_DOMAIN}"
            all_domains=$(echo "$all_domains" | sed 's/,$//')
            
            # Merge VPS lists
            all_vps="$existing_vps"
            if [ -z "$existing_vps" ]; then
                all_vps="$SELECTED_VPS"
            fi
            
            # Configure routing
            if [ -n "$all_vps" ]; then
                bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" configure-routing \
                    "$service" "$all_domains" "$all_vps" "round-robin" 2>/dev/null || true
                log_success "✓ $service configured"
            fi
        done
        
        echo ""
        log_success "Routing configured for all selected services"
    fi
fi

echo ""

# Step 5: Push to VPS nodes
if [ -n "$SELECTED_VPS" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Step 5: Updating VPS Nodes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "Pushing configuration to VPS nodes..."
    bash "$SCRIPT_DIR/lib/sync-controller.sh" push || true
    log_success "Configuration pushed to all VPS nodes"
    echo ""
fi

# Step 6: DNS instructions
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Domain Added Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "Domain $NEW_DOMAIN is now registered in your cluster"
echo ""

if [ -n "$SELECTED_VPS" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📋 NEXT STEP: Configure DNS Records"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "Add these DNS records to your domain registrar:"
    echo ""
    
    IFS=',' read -ra VPS_IPS <<< "$SELECTED_VPS"
    for vps_ip in "${VPS_IPS[@]}"; do
        public_ip=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath="{.data.vps-nodes\.json}" 2>/dev/null | \
            jq -r ".[\"$vps_ip\"].public_ip" 2>/dev/null || echo "")
        
        if [ -n "$public_ip" ]; then
            echo "  VPS: $vps_ip (Public IP: $public_ip)"
            echo ""
            echo "  Type: A"
            echo "  Name: * (wildcard for all subdomains)"
            echo "  Value: $public_ip"
            echo "  TTL: 300 (5 minutes)"
            echo ""
            echo "  Or for specific services:"
            if [ ${#selected_services[@]} -gt 0 ]; then
                for service in "${selected_services[@]}"; do
                    subdomain=$(echo "$SERVICES" | grep "^$service|" | cut -d'|' -f2)
                    echo "    Type: A, Name: $subdomain, Value: $public_ip, TTL: 300"
                done
            fi
            echo ""
        fi
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "After DNS propagates (5-30 minutes), your services will be accessible:"
    if [ ${#selected_services[@]} -gt 0 ]; then
        for service in "${selected_services[@]}"; do
            subdomain=$(echo "$SERVICES" | grep "^$service|" | cut -d'|' -f2)
            echo "  • https://${subdomain}.${NEW_DOMAIN}"
        done
    fi
    echo ""
    
    log_info "SSL certificates will be automatically obtained from Let's Encrypt"
    echo ""
fi

# Show how to add more services later
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔧 Managing This Domain"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "Add more services to this domain later:"
echo "  sudo ./scripts/configure-domain-routing.sh $NEW_DOMAIN"
echo ""

echo "View all domains and routing:"
echo "  sudo ./scripts/lib/multi-domain-registry.sh show"
echo ""

echo "Remove a domain:"
echo "  sudo ./scripts/remove-domain.sh $NEW_DOMAIN"
echo ""

log_success "Setup complete! 🎉"
echo ""
