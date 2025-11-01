#!/bin/bash

###############################################################################
# Update Local DNS - Add MyNodeOne App DNS Entries
#
# This script discovers all LoadBalancer services and adds them to /etc/hosts
# Works on ANY machine connected to the cluster via Tailscale
#
# Use cases:
#   • Management laptop
#   • Developer workstation  
#   • Any Tailscale-connected device
#
# Run this after installing new apps to update DNS entries
###############################################################################

set -euo pipefail

# Parse arguments
QUIET_MODE=false
if [[ "${1:-}" == "--quiet" ]] || [[ "${1:-}" == "-q" ]]; then
    QUIET_MODE=true
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    if [ "$QUIET_MODE" = false ]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [ "$QUIET_MODE" = false ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $1"
    fi
}

log_warn() {
    if [ "$QUIET_MODE" = false ]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_quiet() {
    # Always print in quiet mode (for important messages)
    echo -e "${GREEN}✓${NC} $1"
}

print_header() {
    if [ "$QUIET_MODE" = false ]; then
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  $1"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
    fi
}

detect_machine_type() {
    # Check if this is the control plane node
    if kubectl get nodes 2>/dev/null | grep -q "$(hostname)" && kubectl get nodes 2>/dev/null | grep "$(hostname)" | grep -q "control-plane"; then
        MACHINE_TYPE="control-plane"
        log_info "Running on control plane node"
    else
        MACHINE_TYPE="remote"
        log_info "Running on remote machine (via Tailscale)"
    fi
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install it first:"
        echo ""
        echo "Options:"
        echo "  1. Run setup script: sudo ./scripts/setup-laptop.sh"
        echo "  2. Install manually: https://kubernetes.io/docs/tasks/tools/"
        echo ""
        echo "For quick install:"
        echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
        echo "  chmod +x kubectl"
        echo "  sudo mv kubectl /usr/local/bin/"
        exit 1
    fi
    
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot connect to cluster. Ensure:"
        echo "  • Tailscale is running: tailscale status"
        echo "  • kubectl is configured: ls ~/.kube/config"
        echo ""
        echo "To configure kubectl on this machine:"
        echo "  1. If management laptop: Run sudo ./scripts/setup-laptop.sh"
        echo "  2. If other machine: Copy kubeconfig from control plane"
        echo "     scp user@control-plane:~/.kube/config ~/.kube/config"
        echo "     # Update server IP in config to control plane Tailscale IP"
        exit 1
    fi
    
    detect_machine_type
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
    if [ "$QUIET_MODE" = true ]; then
        # In quiet mode, just show count of DNS entries added
        SERVICE_COUNT=$(echo "$SERVICES" | wc -l)
        log_quiet "DNS entries updated: $SERVICE_COUNT services configured for .local access"
        return
    fi
    
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
    if [ "$QUIET_MODE" = false ]; then
        print_header "MyNodeOne DNS Update"
        
        echo "This script will discover all LoadBalancer services and update /etc/hosts"
        echo "on this machine for easy .local domain access."
        echo
        echo "Works on:"
        echo "  • Management laptops"
        echo "  • Developer workstations"
        echo "  • Any Tailscale-connected device"
        echo
    fi
    
    check_kubectl
    discover_services
    generate_dns_entries
    update_hosts_file
    
    if [ "$QUIET_MODE" = false ]; then
        test_dns
    fi
    
    print_summary
}

main "$@"
