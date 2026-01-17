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
    # Get script directory and project root using standardized utility
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Bootstrap with fallback pattern (auto-discovers if path is wrong)
    source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
    source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
    source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
    export ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
fi

# Load configuration
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Syncing DNS Entries from Control Plane"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Fetch cluster domain from cluster (authoritative source)
if command -v kubectl &>/dev/null; then
    CLUSTER_DOMAIN=$(kubectl get cm cluster-info -n kube-system -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
    if [[ -n "$CLUSTER_DOMAIN" ]]; then
        log_info "Using cluster domain from cluster: $CLUSTER_DOMAIN"
    fi
fi

# Fallback to config file or default
if [[ -z "$CLUSTER_DOMAIN" ]]; then
    CLUSTER_DOMAIN="mynodeone"
    log_warn "Could not fetch cluster domain from cluster, using: $CLUSTER_DOMAIN"
fi

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
    
    # Fetch DNS entries via SSH and deduplicate
    DNS_ENTRIES=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null" | \
        jq -r --arg domain "${CLUSTER_DOMAIN}.local" '
            # Group by subdomain and IP to deduplicate
            [to_entries[] | select(.value.ip != null) | .value] |
            group_by(.subdomain + "|" + .ip) |
            map(.[0]) |
            .[] |
            if .subdomain == "" then
                "\(.ip)\t\($domain)"
            elif .subdomain == "dashboard" then
                # Dashboard gets both subdomain AND bare domain entries
                "\(.ip)\t\(.subdomain).\($domain)\n\(.ip)\t\($domain)"
            else
                "\(.ip)\t\(.subdomain).\($domain)"
            end
        ' 2>/dev/null || echo "")
else
    # Use kubectl directly
    log_info "Fetching DNS entries from cluster..."
    
    # Get service registry and deduplicate by subdomain+IP
    DNS_ENTRIES=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null | \
        jq -r --arg domain "${CLUSTER_DOMAIN}.local" '
            # Group by subdomain and IP to deduplicate
            [to_entries[] | select(.value.ip != null) | .value] |
            group_by(.subdomain + "|" + .ip) |
            map(.[0]) |
            .[] |
            if .subdomain == "" then
                "\(.ip)\t\($domain)"
            elif .subdomain == "dashboard" then
                # Dashboard gets both subdomain AND bare domain entries
                "\(.ip)\t\(.subdomain).\($domain)\n\(.ip)\t\($domain)"
            else
                "\(.ip)\t\(.subdomain).\($domain)"
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
    echo "  sudo $PROJECT_ROOT/scripts/lib/service-registry.sh sync"
    exit 0
fi

# Backup existing /etc/hosts
log_info "Backing up /etc/hosts..."
sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S)

# Remove ALL old MyNodeOne entries (more aggressive cleanup)
log_info "Removing old DNS entries..."

# Capture what we're removing for reporting
# Use grep -E for extended regex and handle output robustly
OLD_ENTRIES=$(grep -cE "\.(${CLUSTER_DOMAIN}|mynodeone|mynodeone)\.local" /etc/hosts 2>/dev/null | head -1 | tr -d '[:space:]' || echo "0")
# Ensure it's a valid integer (strip any non-numeric characters)
OLD_ENTRIES="${OLD_ENTRIES//[!0-9]/}"
OLD_ENTRIES="${OLD_ENTRIES:-0}"

# Method 1: Remove entries within MyNodeOne markers
sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts

# Method 2: Remove ANY entries ending with cluster domain (catches unmarked entries)
# This handles entries like: 100.x.x.x something.mynodeone.local
sudo sed -i "/\.${CLUSTER_DOMAIN}\.local/d" /etc/hosts

# Method 3: Also clean up common variations and old domain names
# This catches cases where the domain changed (e.g., mynodeone -> mynodeone)
for old_domain in "mynodeone" "mynodeone"; do
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
    echo -e "$DNS_ENTRIES"  # Use -e to interpret \n from jq output
    echo ""
} | sudo tee -a /etc/hosts > /dev/null

# Count services
SERVICE_COUNT=$(echo "$DNS_ENTRIES" | grep -v '^$' | wc -l)

# Defensive check: Ensure /etc/hosts has correct permissions
HOSTS_PERMS=$(stat -c "%a" /etc/hosts 2>/dev/null || echo "unknown")
if [ "$HOSTS_PERMS" != "644" ]; then
    log_warn "/etc/hosts has permissions $HOSTS_PERMS, fixing to 644..."
    sudo chmod 644 /etc/hosts
fi

log_success "DNS sync complete!"
echo ""
echo "✅ Updated $SERVICE_COUNT service entries:"
echo -e "$DNS_ENTRIES" | sed 's/^/   /'
echo ""

# Verify DNS resolution works
# Note: getent may use cached DNS, so we verify /etc/hosts directly
if grep -q "dashboard.${CLUSTER_DOMAIN}.local" /etc/hosts 2>/dev/null; then
    log_success "DNS entries verified in /etc/hosts ✓"
    # Test actual resolution (may fail due to DNS caching)
    if getent hosts dashboard.${CLUSTER_DOMAIN}.local >/dev/null 2>&1; then
        log_success "DNS resolution verified ✓"
    else
        log_info "DNS entries added successfully (resolution may take a moment due to caching)"
    fi
else
    log_warn "DNS entries not found in /etc/hosts"
    HOSTS_PERMS=$(stat -c "%a" /etc/hosts 2>/dev/null || echo "unknown")
    log_warn "Current /etc/hosts permissions: $HOSTS_PERMS"
fi

log_info "You can now access services via .local domains"
echo ""
