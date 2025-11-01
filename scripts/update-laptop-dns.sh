#!/bin/bash

###############################################################################
# Update Laptop DNS - Add MyNodeOne App DNS Entries
#
# This script discovers all LoadBalancer services and adds them to /etc/hosts
# Run this after installing new apps to update DNS entries
###############################################################################

set -euo pipefail

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

print_header() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install it first:"
        echo "  Run: sudo ./scripts/setup-laptop.sh"
        exit 1
    fi
    
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot connect to cluster. Ensure:"
        echo "  • Tailscale is running"
        echo "  • kubectl is configured (~/.kube/config exists)"
        echo "  • You've run: sudo ./scripts/setup-laptop.sh"
        exit 1
    fi
}

discover_services() {
    log_info "Discovering LoadBalancer services..."
    
    # Get all LoadBalancer services with IPs
    SERVICES=$(kubectl get svc -A -o json | jq -r '
        .items[] | 
        select(.spec.type == "LoadBalancer") | 
        select(.status.loadBalancer.ingress != null) |
        select(.status.loadBalancer.ingress[0].ip != null) |
        {
            namespace: .metadata.namespace,
            name: .metadata.name,
            ip: .status.loadBalancer.ingress[0].ip
        } |
        "\(.ip)|\(.name)|\(.namespace)"
    ')
    
    if [ -z "$SERVICES" ]; then
        log_warn "No LoadBalancer services with IPs found"
        echo
        echo "Possible reasons:"
        echo "  • Apps not yet deployed"
        echo "  • MetalLB not configured"
        echo "  • Services still pending IP assignment"
        echo
        echo "Run this after deploying apps:"
        echo "  kubectl get svc -A | grep LoadBalancer"
        exit 0
    fi
    
    log_success "Found $(echo "$SERVICES" | wc -l) LoadBalancer services"
}

generate_dns_entries() {
    log_info "Generating DNS entries..."
    
    DNS_ENTRIES=""
    
    while IFS='|' read -r ip name namespace; do
        # Skip if empty
        [ -z "$ip" ] && continue
        
        # Generate hostname based on service name and namespace
        case "$name" in
            *-server)
                # App servers (e.g., immich-server, jellyfin-server)
                APP_NAME="${name%-server}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            *-frontend)
                # Frontends (e.g., longhorn-frontend)
                APP_NAME="${name%-frontend}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            kube-prometheus-stack-grafana)
                HOSTNAME="grafana.mynodeone.local"
                ;;
            argocd-server)
                HOSTNAME="argocd.mynodeone.local"
                ;;
            minio-console)
                HOSTNAME="minio.mynodeone.local"
                ;;
            minio)
                HOSTNAME="minio-api.mynodeone.local"
                ;;
            *)
                # Default: use service name
                HOSTNAME="${name}.mynodeone.local"
                ;;
        esac
        
        DNS_ENTRIES="${DNS_ENTRIES}${ip}    ${HOSTNAME}    # ${namespace}/${name}\n"
        
        echo "  • ${HOSTNAME} → ${ip} (${namespace}/${name})"
        
    done <<< "$SERVICES"
    
    echo
}

update_hosts_file() {
    print_header "Updating /etc/hosts"
    
    log_info "Backing up current /etc/hosts..."
    sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
    log_success "Backup created"
    
    log_info "Removing old MyNodeOne entries..."
    sudo sed -i '/# MyNodeOne services/,/# End MyNodeOne services/d' /etc/hosts
    
    log_info "Adding new MyNodeOne entries..."
    {
        echo ""
        echo "# MyNodeOne services"
        echo -e "$DNS_ENTRIES"
        echo "# End MyNodeOne services"
    } | sudo tee -a /etc/hosts > /dev/null
    
    log_success "/etc/hosts updated"
}

test_dns() {
    print_header "Testing DNS Resolution"
    
    log_info "Testing DNS lookups..."
    echo
    
    # Extract hostnames and test them
    while IFS='|' read -r ip name namespace; do
        [ -z "$ip" ] && continue
        
        case "$name" in
            *-server)
                APP_NAME="${name%-server}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            *-frontend)
                APP_NAME="${name%-frontend}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            kube-prometheus-stack-grafana)
                HOSTNAME="grafana.mynodeone.local"
                ;;
            argocd-server)
                HOSTNAME="argocd.mynodeone.local"
                ;;
            minio-console)
                HOSTNAME="minio.mynodeone.local"
                ;;
            minio)
                HOSTNAME="minio-api.mynodeone.local"
                ;;
            *)
                HOSTNAME="${name}.mynodeone.local"
                ;;
        esac
        
        RESOLVED_IP=$(getent hosts "$HOSTNAME" 2>/dev/null | awk '{print $1}' || echo "")
        
        if [ "$RESOLVED_IP" = "$ip" ]; then
            echo "  ✅ ${HOSTNAME} → ${ip}"
        else
            echo "  ❌ ${HOSTNAME} → ${RESOLVED_IP:-FAILED} (expected: ${ip})"
        fi
        
    done <<< "$SERVICES"
    
    echo
    log_success "DNS testing complete"
}

print_summary() {
    print_header "Summary"
    
    echo "✅ DNS entries updated in /etc/hosts"
    echo "✅ All LoadBalancer services discovered"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Access Your Apps"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Print accessible URLs
    while IFS='|' read -r ip name namespace; do
        [ -z "$ip" ] && continue
        
        case "$name" in
            *-server)
                APP_NAME="${name%-server}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            *-frontend)
                APP_NAME="${name%-frontend}"
                HOSTNAME="${APP_NAME}.mynodeone.local"
                ;;
            kube-prometheus-stack-grafana)
                HOSTNAME="grafana.mynodeone.local"
                ;;
            argocd-server)
                HOSTNAME="argocd.mynodeone.local"
                ;;
            minio-console)
                HOSTNAME="minio.mynodeone.local"
                ;;
            minio)
                HOSTNAME="minio-api.mynodeone.local"
                ;;
            *)
                HOSTNAME="${name}.mynodeone.local"
                ;;
        esac
        
        # Determine protocol
        if [[ "$name" == "argocd"* ]]; then
            PROTOCOL="https"
        else
            PROTOCOL="http"
        fi
        
        echo "  • ${PROTOCOL}://${HOSTNAME}"
        
    done <<< "$SERVICES"
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "💡 Tip: Run this script after installing new apps to update DNS"
    echo
}

main() {
    print_header "MyNodeOne DNS Update"
    
    echo "This script will discover all LoadBalancer services and update /etc/hosts"
    echo "on your laptop for easy .local domain access."
    echo
    
    check_kubectl
    discover_services
    generate_dns_entries
    update_hosts_file
    test_dns
    print_summary
}

main "$@"
