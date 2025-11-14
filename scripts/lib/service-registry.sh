#!/bin/bash

###############################################################################
# Central Service Registry
# 
# Manages a centralized registry of all services in Kubernetes
# Single source of truth for DNS and routing configuration
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
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Initialize registry configmap if it doesn't exist
init_registry() {
    if ! kubectl get configmap -n kube-system service-registry &>/dev/null; then
        log_info "Creating service registry..."
        
        kubectl create configmap service-registry \
            -n kube-system \
            --from-literal=services.json='{}'
        
        log_success "Service registry created"
    fi
}

# Register a new service in the registry
# Usage: register_service <name> <subdomain> <namespace> <service> <port> <public>
register_service() {
    local name="$1"
    local subdomain="$2"
    local namespace="$3"
    local service="$4"
    local port="$5"
    local public="${6:-false}"
    
    log_info "Registering service: $name"
    
    # Get LoadBalancer IP
    local ip=$(kubectl get svc -n "$namespace" "$service" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$ip" ]]; then
        log_error "Could not get LoadBalancer IP for $service"
        return 1
    fi
    
    # Get current registry
    local registry=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    # Add/update service entry
    registry=$(echo "$registry" | jq \
        --arg name "$name" \
        --arg subdomain "$subdomain" \
        --arg namespace "$namespace" \
        --arg service "$service" \
        --arg ip "$ip" \
        --arg port "$port" \
        --arg public "$public" \
        '.[$name] = {
            subdomain: $subdomain,
            namespace: $namespace,
            service: $service,
            ip: $ip,
            port: ($port | tonumber),
            public: ($public == "true"),
            updated: now | todate
        }')
    
    # Update configmap using patch to preserve other fields
    kubectl patch configmap service-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"services.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Registered: $subdomain → $ip"
    
    return 0
}

# Get all services from registry
get_all_services() {
    kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}'
}

# Get specific service from registry
get_service() {
    local name="$1"
    
    get_all_services | jq -r ".\"$name\" // empty"
}

# Sync registry with actual cluster state
# Discovers all LoadBalancer services and updates registry
sync_registry() {
    log_info "Syncing service registry with cluster state..."
    
    init_registry
    
    # Get all LoadBalancer services
    local services=$(kubectl get svc --all-namespaces \
        -o json | jq -r '
        .items[] | 
        select(.spec.type == "LoadBalancer") |
        select(.status.loadBalancer.ingress != null) |
        {
            name: .metadata.name,
            namespace: .metadata.namespace,
            ip: .status.loadBalancer.ingress[0].ip,
            port: .spec.ports[0].port
        } | @json')
    
    if [[ -z "$services" ]]; then
        log_info "No LoadBalancer services found"
        return 0
    fi
    
    local count=0
    while IFS= read -r svc; do
        local name=$(echo "$svc" | jq -r '.name')
        local namespace=$(echo "$svc" | jq -r '.namespace')
        local ip=$(echo "$svc" | jq -r '.ip')
        local port=$(echo "$svc" | jq -r '.port')
        
        # Try to determine subdomain from common patterns
        local subdomain="$name"
        case "$name" in
            *-server) subdomain="${name%-server}" ;;
            *-frontend) subdomain="${name%-frontend}" ;;
        esac
        
        # Check if service has subdomain annotation
        # Uses standard Kubernetes annotation format: mynodeone.io/subdomain
        local annotation=$(kubectl get svc -n "$namespace" "$name" \
            -o jsonpath='{.metadata.annotations.mynodeone\.io/subdomain}' 2>/dev/null || echo "")
        
        if [[ -n "$annotation" ]]; then
            subdomain="$annotation"
        fi
        
        register_service "$name" "$subdomain" "$namespace" "$name" "$port" "false" &>/dev/null
        ((count++))
    done <<< "$services"
    
    log_success "Synced $count services"
}

# Export registry to DNS format for /etc/hosts
export_dns() {
    local domain="${1:-mycloud.local}"
    
    local services=$(get_all_services)
    
    if [[ "$services" == "{}" ]]; then
        return 0
    fi
    
    echo "# MyNodeOne Services - Auto-generated on $(date)"
    echo "$services" | jq -r --arg domain "$domain" '
        to_entries[] |
        select(.value.ip != null) |
        if .value.subdomain == "" then
            "\(.value.ip)\t\($domain)"
        else
            "\(.value.ip)\t\(.value.subdomain).\($domain)"
        end
    '
}

# Export registry to Traefik routing format
export_traefik_routes() {
    local public_domain="$1"
    local control_plane_ip="$2"
    
    local services=$(get_all_services | jq -r '
        to_entries[] |
        select(.value.public == true) |
        .value
    ')
    
    if [[ -z "$services" ]]; then
        return 0
    fi
    
    echo "# Generated from service registry on $(date)"
    echo "http:"
    echo "  routers:"
    
    echo "$services" | jq -r --arg domain "$public_domain" --arg cp_ip "$control_plane_ip" '
        (.subdomain) as $sub |
        (.port) as $port |
        "    \($sub):",
        "      rule: \"Host(`\($sub).\($domain)`)\"",
        "      service: \($sub)-service",
        "      entryPoints:",
        "        - websecure",
        "      tls:",
        "        certResolver: letsencrypt",
        ""
    '
    
    echo "  services:"
    echo "$services" | jq -r --arg cp_ip "$control_plane_ip" '
        (.subdomain) as $sub |
        (.port) as $port |
        "    \($sub)-service:",
        "      loadBalancer:",
        "        servers:",
        "          - url: \"http://\($cp_ip):\($port)\"",
        ""
    '
}

# Main command dispatcher
case "${1:-}" in
    init)
        init_registry
        ;;
    register)
        shift
        register_service "$@"
        ;;
    get)
        get_service "$2"
        ;;
    list)
        get_all_services | jq '.'
        ;;
    sync)
        sync_registry
        ;;
    export-dns)
        export_dns "${2:-mycloud.local}"
        ;;
    export-traefik)
        export_traefik_routes "$2" "$3"
        ;;
    *)
        cat << 'EOF'
Service Registry Management

Usage:
  service-registry.sh <command> [options]

Commands:
  init                          Initialize service registry
  register <name> <subdomain> <namespace> <service> <port> <public>
                               Register a new service
  get <name>                   Get service info
  list                         List all services
  sync                         Sync registry with cluster state
  export-dns [domain]          Export DNS entries for /etc/hosts
  export-traefik <domain> <ip> Export Traefik routes

Examples:
  service-registry.sh sync
  service-registry.sh register immich photos immich immich-server 80 true
  service-registry.sh export-dns mycloud.local > /tmp/dns-entries
  service-registry.sh export-traefik curiios.com 100.122.68.75 > routes.yml

EOF
        exit 1
        ;;
esac
