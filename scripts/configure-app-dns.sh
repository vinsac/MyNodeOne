#!/bin/bash

###############################################################################
# Configure DNS for Installed Apps
# 
# ⚠️  DEPRECATED: This script is replaced by the enterprise registry system
# 
# Please use instead:
#   sudo ./scripts/lib/service-registry.sh sync
#   sudo ./scripts/sync-dns.sh
# 
# This script may create duplicate DNS entries if you're using the
# enterprise registry (setup-enterprise-registry.sh)
###############################################################################

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  DEPRECATION WARNING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This script is DEPRECATED and may cause duplicate DNS entries."
echo ""
echo "If you have enterprise registry installed, use instead:"
echo "  sudo ./scripts/lib/service-registry.sh sync"
echo "  sudo ./scripts/sync-dns.sh"
echo ""
echo "If you already have duplicate DNS entries, run:"
echo "  sudo ./scripts/fix-duplicate-dns.sh"
echo ""
echo "NOTE: Fresh installations (Nov 2024+) don't need this script."
echo "      It's only for legacy systems."
echo ""
read -p "Continue with old script anyway? [y/N]: " continue_old
if [[ "$continue_old" != "y" ]] && [[ "$continue_old" != "Y" ]]; then
    echo "Exiting. Use the new enterprise registry commands instead."
    exit 0
fi
echo ""

set -euo pipefail

# Load cluster configuration
CONFIG_FILE="$HOME/.mynodeone/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Use configured domain or fallback to mynodeone
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Configure Local DNS for Installed Apps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please run this on the control plane."
    exit 1
fi

# List of potential app namespaces to check
APP_NAMESPACES=(
    "jellyfin"
    "immich"
    "vaultwarden"
    "minecraft"
    "homepage"
    "plex"
    "nextcloud"
    "mattermost"
    "gitea"
    "uptime-kuma"
    "paperless"
    "audiobookshelf"
    "demo-apps"
    "llm-chat"
)

# Friendly DNS names for services (override namespace name)
declare -A FRIENDLY_NAMES
FRIENDLY_NAMES["demo-apps"]="demoapp"
FRIENDLY_NAMES["llm-chat"]="chat"

# Core services to exclude (already configured in setup-local-dns.sh)
EXCLUDE_NAMESPACES=(
    "kube-system"
    "metallb-system"
    "traefik"
    "longhorn-system"
    "monitoring"
    "argocd"
    "minio"
    "mynodeone-dashboard"
)

log_info "Detecting installed applications..."
echo

# Array to store found apps
declare -A FOUND_APPS

# Check each namespace
for ns in "${APP_NAMESPACES[@]}"; do
    # Skip excluded namespaces
    skip=false
    for exclude in "${EXCLUDE_NAMESPACES[@]}"; do
        if [ "$ns" = "$exclude" ]; then
            skip=true
            break
        fi
    done
    
    if [ "$skip" = true ]; then
        continue
    fi
    
    if kubectl get namespace "$ns" &>/dev/null; then
        # Get the LoadBalancer service IP
        SERVICE_NAME=$(kubectl get svc -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$SERVICE_NAME" ]; then
            SERVICE_IP=$(kubectl get svc -n "$ns" "$SERVICE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            
            if [ -n "$SERVICE_IP" ]; then
                # Use friendly name if available, otherwise use namespace
                dns_name="${FRIENDLY_NAMES[$ns]:-$ns}"
                FOUND_APPS["$dns_name"]="$SERVICE_IP"
                log_success "Found: $ns -> $dns_name.$CLUSTER_DOMAIN.local at $SERVICE_IP"
            fi
        fi
    fi
done

if [ ${#FOUND_APPS[@]} -eq 0 ]; then
    log_warn "No apps found. Install some apps first!"
    echo
    echo "Try: sudo ./scripts/app-store.sh"
    exit 0
fi

echo
log_info "Updating DNS configuration..."

# Backup hosts file
sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)

# Remove old app entries
sudo sed -i '/# MyNodeOne Apps/,/# End MyNodeOne Apps/d' /etc/hosts

# Add new entries
echo "" | sudo tee -a /etc/hosts > /dev/null
echo "# MyNodeOne Apps" | sudo tee -a /etc/hosts > /dev/null

for app in "${!FOUND_APPS[@]}"; do
    ip="${FOUND_APPS[$app]}"
    echo "${ip}        ${app}.${CLUSTER_DOMAIN}.local" | sudo tee -a /etc/hosts > /dev/null
done

echo "# End MyNodeOne Apps" | sudo tee -a /etc/hosts > /dev/null

# Update dnsmasq if it's running
if systemctl is-active --quiet dnsmasq; then
    log_info "Updating dnsmasq configuration..."
    
    # Backup dnsmasq config
    if [ ! -f /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf.bak ]; then
        sudo cp /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf.bak 2>/dev/null || true
    fi
    
    # Clear old app entries
    sudo rm -f /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf
    
    # Add new entries
    sudo touch /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf
    
    for app in "${!FOUND_APPS[@]}"; do
        ip="${FOUND_APPS[$app]}"
        echo "address=/${app}.${CLUSTER_DOMAIN}.local/${ip}" | sudo tee -a /etc/dnsmasq.d/${CLUSTER_DOMAIN}-apps.conf > /dev/null
    done
    
    # Restart dnsmasq
    sudo systemctl restart dnsmasq
    log_success "dnsmasq updated and restarted"
fi

# Create client setup script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log_info "Creating client DNS setup script..."

cat > "$PROJECT_ROOT/setup-app-dns-client.sh" <<'SCRIPT_EOF'
#!/bin/bash

# MyNodeOne App DNS Setup for Client Devices
# Run this on your laptop/desktop to access apps via .local domains

set -e

echo "Setting up app DNS entries..."
echo

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOSTS_FILE="/etc/hosts"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    HOSTS_FILE="C:\Windows\System32\drivers\etc\hosts"
else
    HOSTS_FILE="/etc/hosts"
fi

# Backup hosts file
sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Remove old app entries
sudo sed -i.tmp '/# MyNodeOne Apps/,/# End MyNodeOne Apps/d' "$HOSTS_FILE"

# Add new entries
echo "" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# MyNodeOne Apps" | sudo tee -a "$HOSTS_FILE" > /dev/null
SCRIPT_EOF

# Add each app to the client script
for app in "${!FOUND_APPS[@]}"; do
    ip="${FOUND_APPS[$app]}"
    echo "echo \"${ip}        ${app}.${CLUSTER_DOMAIN}.local\" | sudo tee -a \"\$HOSTS_FILE\" > /dev/null" >> "$PROJECT_ROOT/setup-app-dns-client.sh"
done

cat >> "$PROJECT_ROOT/setup-app-dns-client.sh" <<'SCRIPT_EOF'
echo "# End MyNodeOne Apps" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "✅ DNS configured!"
echo ""
echo "You can now access:"
SCRIPT_EOF

# Add access info for each app
for app in "${!FOUND_APPS[@]}"; do
    echo "echo \"  • ${app}: http://${app}.${CLUSTER_DOMAIN}.local\"" >> "$PROJECT_ROOT/setup-app-dns-client.sh"
done

echo "echo \"\"" >> "$PROJECT_ROOT/setup-app-dns-client.sh"

chmod +x "$PROJECT_ROOT/setup-app-dns-client.sh"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ DNS Configuration Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "📍 On this control plane, you can now access:"
echo

for app in "${!FOUND_APPS[@]}"; do
    echo "  • ${app}: http://${app}.${CLUSTER_DOMAIN}.local"
done

echo
echo "💻 On other devices (laptop, phone):"
echo "  1. Ensure Tailscale is installed and connected"
echo "  2. Copy setup-app-dns-client.sh to that device"
echo "  3. Run: sudo bash setup-app-dns-client.sh"
echo
echo "📄 Client setup script location:"
echo "  $PROJECT_ROOT/setup-app-dns-client.sh"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
