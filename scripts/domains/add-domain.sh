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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

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
    echo "Please run: sudo $PROJECT_ROOT/scripts/setup/setup-enterprise-registry.sh"
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

bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" register-domain "$NEW_DOMAIN" "$DESCRIPTION"
log_success "Domain registered in cluster"
echo ""

# Step 3: Select VPS nodes
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 3: Select VPS Edge Nodes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get available VPS nodes
VPS_NODES=$(kubectl get configmap -n kube-system domain-registry \
    -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
    jq -r '.vps_nodes[]? | "\(.tailscale_ip)|\(.public_ip)|\(.location)"' || echo "")

if [ -z "$VPS_NODES" ]; then
    log_warn "No VPS nodes registered yet"
    echo ""
    echo "To add a VPS node:"
    echo "  1. Install VPS: sudo $PROJECT_ROOT/scripts/installation/install-mynodeone.sh → Option 3"
    echo "  2. Or manually: sudo $PROJECT_ROOT/scripts/setup/setup-vps-node.sh"
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

# Step 4: Expose Services
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Step 4: Expose Services"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

read -p "Do you want to expose apps on this domain now? (y/n): " expose_now
if [[ "$expose_now" =~ ^[Yy] ]]; then
    # Hand off to manage-app-visibility.sh which is the modern tool
    log_info "Handing off to manage-app-visibility.sh..."
    bash "$PROJECT_ROOT/scripts/operations/manage-app-visibility.sh"
else
    log_info "Skipping service exposure."
    echo ""
    echo "You can expose apps later with:"
    echo "  sudo manage-app-visibility.sh"
    echo ""
fi

# Step 5: DNS Instructions
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Domain Registered Successfully"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "Domain $NEW_DOMAIN is now in your registry."
echo ""

if [ -n "$SELECTED_VPS" ]; then
    echo "Next Step: Configure DNS A Records"
    echo "Point these records to your VPS IP(s):"
    echo ""
    echo "  Type: A, Name: @, Value: <VPS-IP>"
    echo "  Type: A, Name: *, Value: <VPS-IP>"
    echo ""
fi
