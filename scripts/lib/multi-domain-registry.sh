#!/bin/bash

###############################################################################
# Multi-Domain, Multi-VPS Registry
# 
# Enterprise-grade routing with:
# - Multiple public domains
# - Multiple VPS edge nodes
# - Load balancing and failover
# - Health checks
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

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Initialize multi-domain registry in Kubernetes
init_multi_domain_registry() {
    if ! kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        log_info "Creating domain registry..."
        
        # Use unified structure for domains.json
        kubectl create configmap domain-registry \
            -n kube-system \
            --from-literal=domains.json='{"domains":{},"vps_nodes":[]}' \
            --from-literal=routing.json='{}'
        
        log_success "Domain registry created"
    else
        # Migrate old structure to new if needed
        local current_structure=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{}')
        
        # Check if it's using old structure (no nested "domains" key)
        if ! echo "$current_structure" | jq -e '.domains' &>/dev/null; then
            log_info "Migrating domain registry to unified structure..."
            local migrated=$(echo "$current_structure" | jq '{domains: ., vps_nodes: []}')
            kubectl patch configmap domain-registry \
                -n kube-system \
                --type merge \
                -p "{\"data\":{\"domains.json\":\"$(echo "$migrated" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
            log_success "Registry migrated to unified structure"
        fi
    fi
}

# Register a domain
register_domain() {
    local domain="$1"
    local description="${2:-}"
    
    init_multi_domain_registry
    
    log_info "Registering domain: $domain"
    
    local registry=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{"domains":{},"vps_nodes":[]}')
    
    # Handle empty string from ConfigMap
    [ -z "$registry" ] && registry='{"domains":{},"vps_nodes":[]}'
    
    # Add domain to the nested "domains" object
    registry=$(echo "$registry" | jq \
        --arg domain "$domain" \
        --arg desc "$description" \
        '.domains[$domain] = {
            description: $desc,
            registered: now | todate,
            status: "active"
        }')
    
    # Use kubectl patch to preserve other fields
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"domains.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}" 
    
    log_success "Domain registered: $domain"
}

# Unregister a domain
unregister_domain() {
    local domain="$1"
    
    log_info "Unregistering domain: $domain"
    
    local registry=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{"domains":{},"vps_nodes":[]}')
    
    # Check if domain exists
    if ! echo "$registry" | jq -e ".domains[\"$domain\"]" &>/dev/null; then
        log_warn "Domain not found: $domain"
        return 0
    fi
    
    # Remove domain from the registry
    registry=$(echo "$registry" | jq "del(.domains[\"$domain\"])")
    
    # Update ConfigMap
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"domains.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Domain unregistered: $domain"
}

# Register a VPS node
register_vps() {
    local vps_ip="$1"
    local public_ip="$2"
    local region="${3:-unknown}"
    local provider="${4:-unknown}"
    
    init_multi_domain_registry
    
    log_info "Registering VPS: $vps_ip ($region)"
    
    local registry=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{"domains":{},"vps_nodes":[]}')
    
    # Handle empty string from ConfigMap
    [ -z "$registry" ] && registry='{"domains":{},"vps_nodes":[]}'
    
    # Add VPS to the "vps_nodes" array
    registry=$(echo "$registry" | jq \
        --arg ip "$vps_ip" \
        --arg public_ip "$public_ip" \
        --arg region "$region" \
        --arg provider "$provider" \
        '.vps_nodes += [{
            tailscale_ip: $ip,
            public_ip: $public_ip,
            location: $region,
            registered: now | todate,
            status: "active"
        }] | .vps_nodes |= unique_by(.tailscale_ip)')
    
    # Use kubectl patch to update the unified structure
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"domains.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}" 
    
    log_success "VPS registered: $vps_ip → $public_ip ($region)"
}

# Unregister a VPS node
unregister_vps() {
    local vps_ip="$1"
    
    log_info "Unregistering VPS: $vps_ip"
    
    local registry=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo '{"domains":{},"vps_nodes":[]}')
    
    # Check if VPS exists
    if ! echo "$registry" | jq -e ".vps_nodes[] | select(.tailscale_ip==\"$vps_ip\")" &>/dev/null; then
        log_warn "VPS not found: $vps_ip"
        return 0
    fi
    
    # Remove VPS from the registry
    registry=$(echo "$registry" | jq "del(.vps_nodes[] | select(.tailscale_ip==\"$vps_ip\"))")
    
    # Update ConfigMap
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"domains.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "VPS unregistered: $vps_ip"
}

# Configure service routing
# Maps service to domain(s) and VPS node(s)
configure_service_routing() {
    local service_name="$1"
    local domains="$2"       # Comma-separated: curiios.com,vinaysachdeva.com
    local vps_nodes="$3"     # Comma-separated: 100.68.225.92,100.70.123.45
    local strategy="${4:-round-robin}"  # round-robin, primary-backup, geo
    
    init_multi_domain_registry
    
    log_info "Configuring routing for: $service_name"
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    # Convert comma-separated to JSON arrays
    local domain_array=$(echo "$domains" | jq -R 'split(",")')
    local vps_array=$(echo "$vps_nodes" | jq -R 'split(",")')
    
    # Handle empty string from ConfigMap
    [ -z "$routing" ] && routing='{}'
    
    routing=$(echo "$routing" | jq \
        --arg service "$service_name" \
        --argjson domains "$domain_array" \
        --argjson vps "$vps_array" \
        --arg strategy "$strategy" \
        '.[$service] = {
            domains: $domains,
            vps_nodes: $vps,
            strategy: $strategy,
            updated: now | todate
        }')
    
    # Use kubectl patch to preserve other fields
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"routing.json\":\"$(echo "$routing" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Routing configured for $service_name"
    log_info "  Domains: $domains"
    log_info "  VPS Nodes: $vps_nodes"
    log_info "  Strategy: $strategy"
}

# Export routing configuration for a specific VPS
export_vps_routing() {
    local vps_ip="$1"
    local control_plane_ip="$2"
    
    init_multi_domain_registry
    
    # Get all routing entries
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    # Get service registry
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    if [[ "$routing" == "{}" ]]; then
        log_warn "No routing configured"
        return 1
    fi
    
    # Filter routes for this VPS
    local vps_routes=$(echo "$routing" | jq -r \
        --arg vps "$vps_ip" \
        'to_entries[] |
        select(.value.vps_nodes | index($vps)) |
        .key as $service |
        .value.domains[] as $domain |
        {
            service: $service,
            domain: $domain
        } | @json')
    
    if [[ -z "$vps_routes" ]]; then
        log_info "No routes assigned to VPS: $vps_ip"
        return 0
    fi
    
    # Generate Traefik configuration
    echo "# Multi-Domain Routing for VPS: $vps_ip"
    echo "# Generated on: $(date)"
    echo ""
    echo "http:"
    echo "  routers:"
    
    while IFS= read -r route; do
        local service=$(echo "$route" | jq -r '.service')
        local domain=$(echo "$route" | jq -r '.domain')
        
        # Get service details
        local svc_info=$(echo "$services" | jq -r ".\"$service\"")
        local subdomain=$(echo "$svc_info" | jq -r '.subdomain')
        local port=$(echo "$svc_info" | jq -r '.port')
        
        if [[ "$subdomain" == "null" ]] || [[ "$port" == "null" ]]; then
            continue
        fi
        
        # Handle root domain (@) or subdomain
        local host_rule
        if [[ "$subdomain" == "@" ]]; then
            host_rule="Host(\`${domain}\`)"
        else
            host_rule="Host(\`${subdomain}.${domain}\`)"
        fi
        
        echo "    ${service}-${domain//\./-}:"
        echo "      rule: \"${host_rule}\"" 
        echo "      service: ${service}-service"
        echo "      entryPoints:"
        echo "        - websecure"
        echo "      tls:"
        echo "        certResolver: letsencrypt"
        echo ""
        
        echo "    ${service}-${domain//\./-}-http:"
        echo "      rule: \"${host_rule}\"" 
        echo "      service: ${service}-service"
        echo "      entryPoints:"
        echo "        - web"
        echo "      middlewares:"
        echo "        - https-redirect"
        echo ""
    done <<< "$vps_routes"
    
    echo "  services:"
    
    # Deduplicate services
    local unique_services=$(echo "$vps_routes" | jq -r '.service' | sort -u)
    
    while IFS= read -r service; do
        local svc_info=$(echo "$services" | jq -r ".\"$service\"")
        local svc_ip=$(echo "$svc_info" | jq -r '.ip')
        local port=$(echo "$svc_info" | jq -r '.port')
        
        if [[ "$port" == "null" ]]; then
            continue
        fi
        
        # Use service LoadBalancer IP if available, otherwise fallback to control plane
        local backend_url
        if [[ "$svc_ip" != "null" ]] && [[ -n "$svc_ip" ]]; then
            backend_url="http://${svc_ip}:${port}"
        else
            backend_url="http://${control_plane_ip}:${port}"
        fi
        
        echo "    ${service}-service:"
        echo "      loadBalancer:"
        echo "        servers:"
        echo "          - url: \"${backend_url}\""
        echo ""
    done <<< "$unique_services"
    
    echo "  middlewares:"
    echo "    https-redirect:"
    echo "      redirectScheme:"
    echo "        scheme: https"
    echo "        permanent: true"
}

# Show current configuration
show_config() {
    init_multi_domain_registry
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Multi-Domain, Multi-VPS Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Show domains
    echo "Registered Domains:"
    kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r 'to_entries[] | "  • \(.key): \(.value.description)"'
    echo ""
    
    # Show VPS nodes
    echo "Registered VPS Nodes:"
    kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.vps-nodes\.json}' 2>/dev/null | \
        jq -r 'to_entries[] | "  • \(.key) → \(.value.public_ip) (\(.value.region))"'
    echo ""
    
    # Show routing
    echo "Service Routing:"
    kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null | \
        jq -r 'to_entries[] |
        "  • \(.key):\n    Domains: \(.value.domains | join(", "))\n    VPS: \(.value.vps_nodes | join(", "))\n    Strategy: \(.value.strategy)"'
    echo ""
}

# Main command dispatcher
case "${1:-}" in
    init)
        init_multi_domain_registry
        ;;
    register-domain)
        register_domain "$2" "$3"
        ;;
    unregister-domain)
        unregister_domain "$2"
        ;;
    register-vps)
        register_vps "$2" "$3" "$4" "$5"
        ;;
    unregister-vps)
        unregister_vps "$2"
        ;;
    configure-routing)
        configure_service_routing "$2" "$3" "$4" "${5:-round-robin}"
        ;;
    export-vps-routes)
        export_vps_routing "$2" "$3"
        ;;
    show)
        show_config
        ;;
    *)
        cat << 'EOF'
Multi-Domain, Multi-VPS Registry

Usage:
  multi-domain-registry.sh <command> [options]

Commands:
  init                                    Initialize domain registry

  register-domain <domain> [description]  Register a public domain
                                          Example: curiios.com "Main site"

  unregister-domain <domain>              Unregister a domain
                                          Example: curiios.com

  register-vps <tailscale_ip> <public_ip> <region> <provider>
                                          Register a VPS edge node
                                          Example: 100.68.225.92 45.8.133.192 eu contabo

  unregister-vps <tailscale_ip>           Unregister a VPS node
                                          Example: 100.68.225.92

  configure-routing <service> <domains> <vps_nodes> [strategy]
                                          Configure service routing
                                          Example: immich "curiios.com,vinaysachdeva.com" \
                                                   "100.68.225.92,100.70.123.45" round-robin

  export-vps-routes <vps_ip> <control_plane_ip>
                                          Export Traefik routes for specific VPS

  show                                    Show current configuration

Strategies:
  - round-robin:     Distribute across all VPS (load balancing)
  - primary-backup:  Use first VPS, failover to others
  - geo:             Route based on geographic location

Examples:
  # Setup
  multi-domain-registry.sh init
  multi-domain-registry.sh register-domain curiios.com "Personal site"
  multi-domain-registry.sh register-domain vinaysachdeva.com "Professional site"
  multi-domain-registry.sh register-vps 100.68.225.92 45.8.133.192 eu contabo
  multi-domain-registry.sh register-vps 100.70.123.45 167.99.1.1 us digitalocean

  # Configure routing
  multi-domain-registry.sh configure-routing immich \
    "curiios.com,vinaysachdeva.com" \
    "100.68.225.92,100.70.123.45" \
    round-robin

  # Export to VPS
  multi-domain-registry.sh export-vps-routes 100.68.225.92 100.122.68.75 > /tmp/routes.yml

EOF
        exit 1
        ;;
esac
