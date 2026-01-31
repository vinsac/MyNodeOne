#!/bin/bash

###############################################################################
# Multi-Domain, Multi-VPS Registry
# 
# Multi-domain routing with:
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

# Validate domain format
validate_domain() {
    local domain="$1"
    
    # Basic domain validation regex
    # Allows: subdomain.domain.com, www.domain.com, domain.com
    # Disallows: invalid..domain, .domain.com, domain.com.
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        log_error "Domain must follow standard format (e.g., example.com, www.example.com, app.example.com)"
        return 1
    fi
    
    # Check for consecutive dots
    if [[ "$domain" =~ \.\. ]]; then
        log_error "Invalid domain format: $domain (consecutive dots not allowed)"
        return 1
    fi
    
    # Check for empty labels
    if [[ "$domain" =~ ^\. ]] || [[ "$domain" =~ \.$ ]]; then
        log_error "Invalid domain format: $domain (cannot start or end with dot)"
        return 1
    fi
    
    # Check length (max 253 characters)
    if [[ ${#domain} -gt 253 ]]; then
        log_error "Invalid domain format: $domain (too long, max 253 characters)"
        return 1
    fi
    
    return 0
}

# Check for domain conflicts across services
check_domain_conflicts() {
    local domain="$1"
    local current_service="$2"
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    [ -z "$routing" ] && routing='{}'
    
    # Check if domain is used by other services
    local conflicting_service=$(echo "$routing" | jq -r --arg domain "$domain" --arg current "$current_service" '
        to_entries[] |
        select(.key != $current) |
        select(.value.expose[] == $domain) |
        .key
    ' 2>/dev/null || echo "")
    
    if [[ -n "$conflicting_service" && "$conflicting_service" != "null" ]]; then
        log_warn "Domain $domain is already used by service: $conflicting_service"
        log_warn "Continuing will override the existing configuration"
        return 1  # Has conflict
    fi
    
    return 0  # No conflict
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
        log_info "Domain registry already exists"
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
# Maps service to fully-qualified domain(s) and VPS node(s)
# Clean Separation: Uses expose array with full domains
configure_service_routing() {
    local service_name="$1"
    local expose_domains="$2"   # Comma-separated full domains: curiios.com,www.curiios.com,chat.curiios.com
    local vps_nodes="$3"        # Comma-separated: 100.68.225.92,100.70.123.45
    local strategy="${4:-round-robin}"  # round-robin, primary-backup, geo
    
    init_multi_domain_registry
    
    log_info "Configuring routing for: $service_name"
    
    # Validate all domains first
    IFS=',' read -ra DOMAIN_ARRAY <<< "$expose_domains"
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain=$(echo "$domain" | xargs)  # Trim whitespace
        if ! validate_domain "$domain"; then
            log_error "Aborting due to invalid domain format"
            return 1
        fi
        
        # Check for conflicts
        if check_domain_conflicts "$domain" "$service_name"; then
            log_warn "Domain $domain is already in use by another service"
            read -p "Continue anyway? (y/n): " continue_conflict
            [ "$continue_conflict" != "y" ] && return 1
        fi
    done
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    # Convert comma-separated to JSON array and trim whitespace
    local expose_array=$(echo "$expose_domains" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    local vps_array=$(echo "$vps_nodes" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    
    # Handle empty string from ConfigMap
    [ -z "$routing" ] && routing='{}'
    
    routing=$(echo "$routing" | jq \
        --arg service "$service_name" \
        --argjson expose "$expose_array" \
        --argjson vps "$vps_array" \
        --arg strategy "$strategy" \
        '.[$service] = {
            expose: $expose,
            vps_nodes: $vps,
            strategy: $strategy,
            updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
    
    # Use kubectl patch to preserve other fields
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"routing.json\":\"$(echo "$routing" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Routing configured for $service_name"
    log_info "  Exposed at:"
    echo "$expose_domains" | tr ',' '\n' | sed 's/^[ \t]*//' | sed 's/^/    - https:\/\//'
    log_info "  VPS Nodes: $vps_nodes"
    log_info "  Strategy: $strategy"
}

# Add domain to existing service routing
# Appends domain to expose array instead of replacing
add_domain() {
    local service_name="$1"
    local new_domain="$2"  # Single domain to add
    
    init_multi_domain_registry
    
    log_info "Adding domain to $service_name: $new_domain"
    
    # Validate domain format
    if ! validate_domain "$new_domain"; then
        return 1
    fi
    
    # Check for domain conflicts
    local has_conflict=false
    if check_domain_conflicts "$new_domain" "$service_name"; then
        has_conflict=true
    fi
    
    # Warn about conflicts but allow continuation
    if [ "$has_conflict" = true ]; then
        read -p "Continue anyway? (y/n): " continue_conflict
        [ "$continue_conflict" != "y" ] && return 1
    fi
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    [ -z "$routing" ] && routing='{}'
    
    # Check if service exists in routing
    if ! echo "$routing" | jq -e --arg service "$service_name" '.[$service]' >/dev/null 2>&1; then
        log_error "Service $service_name not found in routing config"
        log_info "Use 'configure-routing' to create initial routing"
        return 1
    fi
    
    # Add domain to expose array (check for duplicates)
    routing=$(echo "$routing" | jq \
        --arg service "$service_name" \
        --arg domain "$new_domain" \
        '.[$service].expose |= (. + [$domain] | unique) |
         .[$service].updated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))')
    
    # Update configmap
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"routing.json\":\"$(echo "$routing" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Domain added: $new_domain"
    
    # Show current domains
    list_domains "$service_name"
}

# Remove domain from existing service routing
remove_domain() {
    local service_name="$1"
    local remove_domain="$2"  # Single domain to remove
    
    init_multi_domain_registry
    
    log_info "Removing domain from $service_name: $remove_domain"
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    [ -z "$routing" ] && routing='{}'
    
    # Check if service exists
    if ! echo "$routing" | jq -e --arg service "$service_name" '.[$service]' >/dev/null 2>&1; then
        log_error "Service $service_name not found in routing config"
        return 1
    fi
    
    # Remove domain from expose array
    routing=$(echo "$routing" | jq \
        --arg service "$service_name" \
        --arg domain "$remove_domain" \
        '.[$service].expose |= (. - [$domain]) |
         .[$service].updated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))')
    
    # Update configmap
    kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"routing.json\":\"$(echo "$routing" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Domain removed: $remove_domain"
    
    # Show remaining domains
    list_domains "$service_name"
}

# List domains for a service
list_domains() {
    local service_name="$1"
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo '{}')
    
    if ! echo "$routing" | jq -e --arg service "$service_name" '.[$service]' >/dev/null 2>&1; then
        log_error "Service $service_name not found in routing config"
        return 1
    fi
    
    log_info "Current domains for $service_name:"
    echo "$routing" | jq -r --arg service "$service_name" \
        '.[$service].expose[] | "  - https://\(.)"'
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
    
    # Filter routes for this VPS using Clean Separation expose array
    local vps_routes=$(echo "$routing" | jq -r \
        --arg vps "$vps_ip" \
        'to_entries[] |
        select(.value.vps_nodes | index($vps)) |
        .key as $service |
        .value.expose[] as $url |
        {
            service: $service,
            url: $url
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
        local url=$(echo "$route" | jq -r '.url')
        
        # Clean URL/Host for Traefik naming (replace dots with dashes)
        local safe_url=${url//\./-}
        
        echo "    ${service}-${safe_url}:"
        echo "      rule: \"Host(\`${url}\`)\"" 
        echo "      service: ${service}-service"
        echo "      entryPoints:"
        echo "        - websecure"
        echo "      tls:"
        echo "        certResolver: letsencrypt"
        echo ""
        
        echo "    ${service}-${safe_url}-http:"
        echo "      rule: \"Host(\`${url}\`)\"" 
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
        jq -r '.domains | to_entries[] | "  • \(.key): \(.value.description)"'
    echo ""
    
    # Show VPS nodes
    echo "Registered VPS Nodes:"
    kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r '.vps_nodes[] | "  • \(.tailscale_ip) → \(.public_ip) (\(.location))"'
    echo ""
    
    # Show routing
    echo "Service Routing:"
    kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null | \
        jq -r 'to_entries[] |
        "  • \(.key):\n    Expose: \(.value.expose | join(", "))\n    VPS: \(.value.vps_nodes | join(", "))\n    Strategy: \(.value.strategy)"'
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
    add-domain)
        add_domain "$2" "$3"
        ;;
    remove-domain)
        remove_domain "$2" "$3"
        ;;
    list-domains)
        list_domains "$2"
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
                                          Example: example.com "Main site"

  unregister-domain <domain>              Unregister a domain
                                          Example: example.com

  register-vps <tailscale_ip> <public_ip> <region> <provider>
                                          Register a VPS edge node
                                          Example: 100.68.225.92 192.0.2.100 eu contabo

  unregister-vps <tailscale_ip>           Unregister a VPS node
                                          Example: 100.68.225.92

  configure-routing <service> <domains> <vps_nodes> [strategy]
                                          Configure service routing (replaces all domains)
                                          Example: immich "example.com,www.example.com" \
                                                   "100.68.225.92,100.70.123.45"

  add-domain <service> <domain>           Add single domain to existing service
                                          Example: add-domain immich "photos.example.com"

  remove-domain <service> <domain>        Remove single domain from service
                                          Example: remove-domain immich "old-domain.com"

  list-domains <service>                  List all domains for a service
                                          Example: list-domains immich

  export-vps-routes <vps_ip> <control_plane_ip>
                                          Export Traefik routes for specific VPS

  show                                    Show current configuration

VPS Deployment Notes:
  - vps_nodes: List of VPS intended for this service (documentation/future-proofing)
  - Note: Currently all VPS nodes receive all routes by default
  - In future, this will enable selective deployment (only specific VPS get specific routes)
  - Load balancing happens at DNS level (A records), not application level
  - Each VPS forwards traffic to control plane service

Examples:
  # Initial setup
  multi-domain-registry.sh init
  multi-domain-registry.sh register-domain example.com "Main site"
  multi-domain-registry.sh register-vps 100.68.225.92 192.0.2.100 eu contabo

  # Configure routing (creates/replaces all domains)
  multi-domain-registry.sh configure-routing immich \
    "photos.example.com,example.com,www.example.com" \
    "100.68.225.92"

  # Add more domains later (appends)
  multi-domain-registry.sh add-domain immich "pics.example.com"
  multi-domain-registry.sh add-domain immich "images.example.com"

  # View current domains
  multi-domain-registry.sh list-domains immich

  # Remove a domain
  multi-domain-registry.sh remove-domain immich "old-domain.com"

  # Export to VPS
  multi-domain-registry.sh export-vps-routes 100.68.225.92 100.122.68.75 > /tmp/routes.yml

EOF
        exit 1
        ;;
esac
