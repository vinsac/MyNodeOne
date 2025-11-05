#!/bin/bash

# MyNodeOne Local DNS Setup Script
# Sets up .local domain names for easy service access

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load configuration
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

check_requirements() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. This script must run on the control plane after installation."
        exit 1
    fi
}

get_service_ips() {
    log_info "Retrieving service LoadBalancer IPs..."
    
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_API_IP=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    LONGHORN_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    DASHBOARD_IP=$(kubectl get svc -n mynodeone-dashboard dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    # Validate we got IPs
    if [ -z "$GRAFANA_IP" ] || [ -z "$ARGOCD_IP" ] || [ -z "$MINIO_CONSOLE_IP" ]; then
        log_error "Could not retrieve all service IPs. Ensure services are running:"
        kubectl get svc -A | grep LoadBalancer
        exit 1
    fi
    
    # Use dashboard IP for mynodeone.local if available, otherwise use Grafana
    if [ -z "$DASHBOARD_IP" ]; then
        DASHBOARD_IP="$GRAFANA_IP"
    fi
    
    log_success "Service IPs retrieved"
}

setup_avahi_local_dns() {
    log_info "Installing Avahi for .local domain support..."
    
    # Install avahi-daemon for mDNS/.local support
    apt-get update -qq
    apt-get install -y avahi-daemon avahi-utils libnss-mdns
    
    # Configure avahi
    cat > /etc/avahi/avahi-daemon.conf <<EOF
[server]
host-name=${CLUSTER_DOMAIN}
domain-name=local
use-ipv4=yes
use-ipv6=no
allow-interfaces=tailscale0,eth0,ens3,ens4,enp0s3,enp0s8
enable-dbus=yes
ratelimit-interval-usec=1000000
ratelimit-burst=1000

[wide-area]
enable-wide-area=yes

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=no
publish-domain=yes
publish-dns-servers=yes
publish-resolv-conf-dns-servers=yes

[reflector]
enable-reflector=yes
reflect-ipv=no

[rlimits]
rlimit-core=0
rlimit-data=4194304
rlimit-fsize=0
rlimit-nofile=768
rlimit-stack=4194304
rlimit-nproc=3
EOF
    
    # Enable and restart avahi
    systemctl enable avahi-daemon
    systemctl restart avahi-daemon
    
    log_success "Avahi configured for .local domain"
}

setup_dnsmasq() {
    log_info "Setting up dnsmasq for local DNS resolution..."
    
    # Install dnsmasq
    apt-get update -qq
    apt-get install -y dnsmasq
    
    # Backup original config
    if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.bak ]; then
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
    fi
    
    # Create dnsmasq config for ${CLUSTER_DOMAIN}.local
    cat > /etc/dnsmasq.d/${CLUSTER_DOMAIN}.conf <<EOF
# MyNodeOne local DNS configuration

# Listen on Tailscale interface and localhost
interface=tailscale0
interface=lo
bind-interfaces

# Domain for this cluster
domain=${CLUSTER_DOMAIN}.local
local=/${CLUSTER_DOMAIN}.local/

# Service DNS entries (explicit only - no wildcards!)
address=/${CLUSTER_DOMAIN}.local/${DASHBOARD_IP}
address=/dashboard.${CLUSTER_DOMAIN}.local/${DASHBOARD_IP}
address=/grafana.${CLUSTER_DOMAIN}.local/${GRAFANA_IP}
address=/argocd.${CLUSTER_DOMAIN}.local/${ARGOCD_IP}
address=/minio.${CLUSTER_DOMAIN}.local/${MINIO_CONSOLE_IP}
address=/minio-api.${CLUSTER_DOMAIN}.local/${MINIO_API_IP}
address=/traefik.${CLUSTER_DOMAIN}.local/${TRAEFIK_IP}
EOF
    
    # Only add Longhorn DNS entry if it has a LoadBalancer IP
    if [ -n "$LONGHORN_IP" ]; then
        echo "address=/longhorn.${CLUSTER_DOMAIN}.local/${LONGHORN_IP}" >> /etc/dnsmasq.d/${CLUSTER_DOMAIN}.conf
    fi
    
    # Note: Root domain handled in /etc/hosts only (not dnsmasq)
    # This prevents wildcard matching of undefined subdomains
    cat >> /etc/dnsmasq.d/${CLUSTER_DOMAIN}.conf <<EOF

# Upstream DNS servers
server=8.8.8.8
server=1.1.1.1

# Cache settings
cache-size=1000
EOF
    
    # Configure systemd-resolved to use dnsmasq
    if systemctl is-active --quiet systemd-resolved; then
        log_info "Configuring systemd-resolved to work with dnsmasq..."
        
        # Stop systemd-resolved from listening on port 53
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/${CLUSTER_DOMAIN}.conf <<EOF
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
Domains=~${CLUSTER_DOMAIN}.local
EOF
        
        # Restart systemd-resolved
        systemctl restart systemd-resolved
    fi
    
    # Enable and restart dnsmasq
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    
    log_success "dnsmasq configured for ${CLUSTER_DOMAIN}.local domain"
}

update_hosts_file() {
    log_info "Updating /etc/hosts for local DNS..."
    
    # Backup hosts file
    cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
    
    # Remove old mynodeone entries
    sed -i '/# MyNodeOne services/,/# End MyNodeOne services/d' /etc/hosts
    
    # Add new entries
    cat >> /etc/hosts <<EOF

# MyNodeOne services
${DASHBOARD_IP}      ${CLUSTER_DOMAIN}.local
${GRAFANA_IP}        grafana.${CLUSTER_DOMAIN}.local
${ARGOCD_IP}         argocd.${CLUSTER_DOMAIN}.local
${MINIO_CONSOLE_IP}  minio.${CLUSTER_DOMAIN}.local
${MINIO_API_IP}      minio-api.${CLUSTER_DOMAIN}.local
EOF
    
    # Only add Longhorn if it has a LoadBalancer IP (not NodePort)
    if [ -n "$LONGHORN_IP" ]; then
        echo "${LONGHORN_IP}       longhorn.${CLUSTER_DOMAIN}.local" >> /etc/hosts
    fi
    
    echo "# End MyNodeOne services" >> /etc/hosts
    
    log_success "/etc/hosts updated with .local domains"
    
    # Note about Longhorn if it uses NodePort
    if [ -z "$LONGHORN_IP" ]; then
        log_info "Note: Longhorn uses NodePort - access at http://\${TAILSCALE_IP}:30080"
    fi
}

create_client_setup_script() {
    log_info "Creating setup script for other devices..."
    
    cat > "$PROJECT_ROOT/setup-client-dns.sh" <<'SCRIPT_EOF'
#!/bin/bash

# MyNodeOne Client DNS Setup
# Run this on laptops/devices to access services via .local domains

set -e

GRAFANA_IP="GRAFANA_IP_PLACEHOLDER"
ARGOCD_IP="ARGOCD_IP_PLACEHOLDER"
MINIO_CONSOLE_IP="MINIO_CONSOLE_IP_PLACEHOLDER"
MINIO_API_IP="MINIO_API_IP_PLACEHOLDER"
LONGHORN_IP="LONGHORN_IP_PLACEHOLDER"
DASHBOARD_IP="DASHBOARD_IP_PLACEHOLDER"
CLUSTER_DOMAIN="CLUSTER_DOMAIN_PLACEHOLDER"

echo "Setting up ${CLUSTER_DOMAIN}.local domains..."

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "Detected macOS"
    HOSTS_FILE="/etc/hosts"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    # Windows
    echo "Detected Windows"
    HOSTS_FILE="C:\Windows\System32\drivers\etc\hosts"
else
    # Linux
    echo "Detected Linux"
    HOSTS_FILE="/etc/hosts"
fi

# Backup hosts file
sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Remove old mynodeone entries
sudo sed -i.tmp '/# MyNodeOne services/,/# End MyNodeOne services/d' "$HOSTS_FILE"

# Add new entries
echo "" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# MyNodeOne services" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${DASHBOARD_IP}      ${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${GRAFANA_IP}        grafana.${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${ARGOCD_IP}         argocd.${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${MINIO_CONSOLE_IP}  minio.${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${MINIO_API_IP}      minio-api.${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${LONGHORN_IP}       longhorn.${CLUSTER_DOMAIN}.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# End MyNodeOne services" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "✅ Local DNS configured!"
echo ""
echo "You can now access services at:"
echo "  • Dashboard:     http://${CLUSTER_DOMAIN}.local"
echo "  • Grafana:       http://grafana.${CLUSTER_DOMAIN}.local"
echo "  • ArgoCD:        https://argocd.${CLUSTER_DOMAIN}.local"
echo "  • MinIO Console: http://minio.${CLUSTER_DOMAIN}.local:9001"
echo "  • MinIO API:     http://minio-api.${CLUSTER_DOMAIN}.local:9000"
echo "  • Traefik:       http://traefik.${CLUSTER_DOMAIN}.local (reverse proxy - no UI)"
echo "  • Longhorn:  http://longhorn.${CLUSTER_DOMAIN}.local"
echo ""
SCRIPT_EOF
    
    # Replace placeholders with actual IPs
    sed -i "s/GRAFANA_IP_PLACEHOLDER/$GRAFANA_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/ARGOCD_IP_PLACEHOLDER/$ARGOCD_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/MINIO_CONSOLE_IP_PLACEHOLDER/$MINIO_CONSOLE_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/MINIO_API_IP_PLACEHOLDER/$MINIO_API_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/LONGHORN_IP_PLACEHOLDER/$LONGHORN_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/DASHBOARD_IP_PLACEHOLDER/$DASHBOARD_IP/g" "$PROJECT_ROOT/setup-client-dns.sh"
    sed -i "s/CLUSTER_DOMAIN_PLACEHOLDER/$CLUSTER_DOMAIN/g" "$PROJECT_ROOT/setup-client-dns.sh"
    
    chmod +x "$PROJECT_ROOT/setup-client-dns.sh"
    
    log_success "Client setup script created: $PROJECT_ROOT/setup-client-dns.sh"
}

print_summary() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Local DNS Setup Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "🎯 On this control plane, you can now access:"
    echo "  • Dashboard:     http://${CLUSTER_DOMAIN}.local"
    echo "  • Grafana:       http://grafana.${CLUSTER_DOMAIN}.local"
    echo "  • ArgoCD:        https://argocd.${CLUSTER_DOMAIN}.local"
    echo "  • MinIO Console: http://minio.${CLUSTER_DOMAIN}.local:9001"
    echo "  • MinIO API:     http://minio-api.${CLUSTER_DOMAIN}.local:9000"
    echo "  • Traefik:       http://traefik.${CLUSTER_DOMAIN}.local (routing only)"
    echo "  • Longhorn:  http://longhorn.${CLUSTER_DOMAIN}.local"
    echo
    echo "💻 On other devices (laptop, desktop):"
    echo "  1. Ensure Tailscale is installed and connected"
    echo "  2. Copy setup-client-dns.sh to that device"
    echo "  3. Run: sudo bash setup-client-dns.sh"
    echo
    echo "📄 Client setup script location:"
    echo "  $PROJECT_ROOT/setup-client-dns.sh"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne Local DNS Setup (.local domains)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    get_service_ips
    
    # Dual DNS configuration for maximum reliability and network accessibility
    # - /etc/hosts: Local resolution (instant, always works)
    # - dnsmasq: Network DNS server (other devices can use it)
    # See: docs/DNS_ARCHITECTURE.md for why we configure both
    
    # Method 1: Update /etc/hosts (simple, always works)
    update_hosts_file
    
    # Method 2: Try dnsmasq (better, advertises to network)
    if setup_dnsmasq 2>/dev/null; then
        log_success "dnsmasq setup successful"
    else
        log_warn "dnsmasq setup skipped (optional)"
    fi
    
    # Create client setup script
    create_client_setup_script
    
    print_summary
    
    # Validate DNS configuration
    echo
    log_info "Validating DNS configuration..."
    sleep 3  # Give DNS a moment to propagate

    # Test key services
    DNS_VALIDATION_OK=true
    for service in "grafana.${CLUSTER_DOMAIN}.local" "argocd.${CLUSTER_DOMAIN}.local" "minio.${CLUSTER_DOMAIN}.local"; do
        if getent hosts "$service" >/dev/null 2>&1; then
            echo "  ✓ $service"
        else
            echo "  ✗ $service - NOT RESOLVING"
            DNS_VALIDATION_OK=false
        fi
    done

    # Test for wildcard (security check)
    RANDOM_HOST="test-undefined-$(date +%s).${CLUSTER_DOMAIN}.local"
    if getent hosts "$RANDOM_HOST" >/dev/null 2>&1; then
        echo "  ✗ SECURITY WARNING: Wildcard DNS detected!"
        DNS_VALIDATION_OK=false
    else
        echo "  ✓ No wildcard DNS (secure)"
    fi

    echo
    if [ "$DNS_VALIDATION_OK" = true ]; then
        log_success "DNS validation passed! All services resolving correctly."
    else
        log_warn "DNS validation found issues. Services may not be accessible."
        log_warn "Wait a few seconds and test manually, or run this script again."
    fi
}

main "$@"
