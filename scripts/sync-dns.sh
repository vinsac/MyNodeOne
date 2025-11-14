#!/bin/bash

###############################################################################
# DNS Sync Script for Management Laptops
# 
# Fetches service registry from control plane and updates /etc/hosts
# Run this on management laptops to sync DNS entries
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# Load configuration
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Syncing DNS Entries from Control Plane"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if kubectl is configured
if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl not found, attempting to fetch via SSH..."
    
    # Try SSH method
    CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
    CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"
    
    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        echo "Error: kubectl not configured and control plane IP not found"
        echo ""
        echo "Please either:"
        echo "  1. Configure kubectl access to the cluster"
        echo "  2. Set CONTROL_PLANE_IP in ~/.mynodeone/config.env"
        exit 1
    fi
    
    log_info "Fetching DNS entries from $CONTROL_PLANE_IP via SSH..."
    
    # Fetch DNS entries via SSH
    DNS_ENTRIES=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null" | \
        jq -r --arg domain "${CLUSTER_DOMAIN}.local" '
            to_entries[] |
            select(.value.ip != null) |
            if .value.subdomain == "" then
                "\(.value.ip)\t\($domain)"
            else
                "\(.value.ip)\t\(.value.subdomain).\($domain)"
            end
        ' 2>/dev/null || echo "")
else
    # Use kubectl directly
    log_info "Fetching DNS entries from cluster..."
    
    # Get service registry
    DNS_ENTRIES=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null | \
        jq -r --arg domain "${CLUSTER_DOMAIN}.local" '
            to_entries[] |
            select(.value.ip != null) |
            if .value.subdomain == "" then
                "\(.value.ip)\t\($domain)"
            else
                "\(.value.ip)\t\(.value.subdomain).\($domain)"
            end
        ' 2>/dev/null || echo "")
fi

if [[ -z "$DNS_ENTRIES" ]]; then
    log_warn "No services found in registry"
    echo ""
    echo "This might mean:"
    echo "  • Service registry is not initialized"
    echo "  • No apps are installed yet"
    echo "  • Connection to cluster failed"
    echo ""
    echo "Run this on control plane to initialize:"
    echo "  sudo ./scripts/lib/service-registry.sh sync"
    exit 0
fi

# Backup existing /etc/hosts
log_info "Backing up /etc/hosts..."
sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)

# Remove ALL old MyNodeOne entries (more aggressive cleanup)
log_info "Removing old DNS entries..."

# Capture what we're removing for reporting
OLD_ENTRIES=$(grep -c "\.${CLUSTER_DOMAIN}\.local\|\.minicloud\.local\|\.mynodeone\.local" /etc/hosts 2>/dev/null || echo "0")

# Method 1: Remove entries within MyNodeOne markers
sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts

# Method 2: Remove ANY entries ending with cluster domain (catches unmarked entries)
# This handles entries like: 100.x.x.x something.mycloud.local
sudo sed -i "/\.${CLUSTER_DOMAIN}\.local/d" /etc/hosts

# Method 3: Also clean up common variations and old domain names
# This catches cases where the domain changed (e.g., minicloud -> mycloud)
for old_domain in "minicloud" "mynodeone"; do
    if [ "$old_domain" != "$CLUSTER_DOMAIN" ]; then
        sudo sed -i "/\.${old_domain}\.local/d" /etc/hosts 2>/dev/null || true
    fi
done

if [ "$OLD_ENTRIES" -gt 0 ]; then
    log_success "Removed $OLD_ENTRIES old DNS entries"
fi

# Add new entries
log_info "Adding new DNS entries..."
{
    echo ""
    echo "# MyNodeOne Services - Auto-synced on $(date)"
    echo "$DNS_ENTRIES"
    echo ""
} | sudo tee -a /etc/hosts > /dev/null

# Count services
SERVICE_COUNT=$(echo "$DNS_ENTRIES" | grep -v '^$' | wc -l)

log_success "DNS sync complete!"
echo ""
echo "✅ Updated $SERVICE_COUNT service entries:"
echo "$DNS_ENTRIES" | sed 's/^/   /'
echo ""

log_info "You can now access services via .local domains"
echo ""
