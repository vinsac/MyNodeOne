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

# shellcheck source=../lib/service-registry-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/service-registry-lib.sh"

# Dependency checks
for dep in kubectl jq; do
    if ! command -v "$dep" &>/dev/null; then
        log_error "Required dependency not found: $dep"
        exit 1
    fi
done

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
    
    local routing services own='[]'
    if ! routing=$(sr_get_routing); then
        log_warn "Could not read routing to check $domain for conflicts"
        return 1
    fi

    # A bare key from before the migration is this same service, not a conflict.
    if services=$(sr_get_services); then
        own=$(sr_routing_keys_for "$services" "$current_service" "$routing" | jq -Rsc 'split("\n") | map(select(length > 0))')
    fi

    # Check if domain is used by other services
    local conflicting_service
    conflicting_service=$(jq -r --arg domain "$domain" --arg current "$current_service" --argjson own "$own" '
        to_entries[] |
        select(.key != $current and (.key as $k | $own | index($k) | not)) |
        select(any((.value.expose? // [])[]; . == $domain)) |
        .key
    ' <<<"$routing" 2>/dev/null) || conflicting_service=""

    if [[ -n "$conflicting_service" && "$conflicting_service" != "null" ]]; then
        log_warn "Domain $domain is already used by service: $conflicting_service"
        log_warn "Continuing will override the existing configuration"
        return 1  # Has conflict
    fi
    
    return 0  # No conflict
}

# Initialize multi-domain registry in Kubernetes
init_multi_domain_registry() {
    # --ignore-not-found, so a failed read can't pass for a registry that isn't there.
    local existing
    if ! existing=$(kubectl get configmap domain-registry -n "$SR_NAMESPACE" -o name --ignore-not-found 2>/dev/null); then
        log_error "Could not read the domain registry"
        return 1
    fi

    if [[ -z "$existing" ]]; then
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

DOMAINS_KEY="domains.json"

# Filters for sr_update_cm, which runs them again on a conflict. Each adds or removes
# one thing from what it reads, so another writer's change survives.
register_domain_filter() {
    jq -c --arg domain "$1" --arg desc "$2" '
        .domains = ((.domains // {}) | .[$domain] = {
            description: $desc,
            registered: (now | todate),
            status: "active"
        })
        | .vps_nodes = (.vps_nodes // [])'
}

# An old registry keeps domains at the top level, with no "domains" object.
JQ_HAS_DOMAINS='((.domains | type) == "object")'

unregister_domain_filter() {
    jq -c --arg domain "$1" "if $JQ_HAS_DOMAINS then del(.domains[\$domain]) else del(.[\$domain]) end"
}

register_vps_filter() {
    jq -c --arg ip "$1" --arg public_ip "$2" --arg region "$3" '
        .domains = (.domains // {})
        | .vps_nodes = ((.vps_nodes // []) + [{
            tailscale_ip: $ip,
            public_ip: $public_ip,
            location: $region,
            registered: (now | todate),
            status: "active"
        }] | unique_by(.tailscale_ip))'
}

unregister_vps_filter() {
    jq -c --arg ip "$1" '.vps_nodes = ((.vps_nodes // []) | map(select(.tailscale_ip != $ip)))'
}

# Register a domain
register_domain() {
    local domain="$1"
    local description="${2:-}"
    
    init_multi_domain_registry || return 1
    
    log_info "Registering domain: $domain"
    
    # Blank is fine here, as there is nothing in it to lose. A failed read is not, and
    # sr_update_cm writes nothing after one.
    if ! SR_ALLOW_BLANK=1 sr_update_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" \
        register_domain_filter "$domain" "$description"; then
        log_error "Failed to register domain: $domain"
        return 1
    fi
    
    log_success "Domain registered: $domain"
}

# Unregister a domain
unregister_domain() {
    local domain="$1" rc=0
    
    log_info "Unregistering domain: $domain"
    
    sr_read_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" || rc=$?
    case "$rc" in
        0) ;;
        2 | 3)
            log_warn "Domain not found: $domain"
            return 0
            ;;
        *)
            log_error "Could not read the domain registry; $domain not changed"
            return 1
            ;;
    esac
    
    if ! jq -e --arg domain "$domain" \
        "if $JQ_HAS_DOMAINS then .domains | has(\$domain) else has(\$domain) end" \
        <<<"$SR_READ_JSON" >/dev/null 2>&1; then
        log_warn "Domain not found: $domain"
        return 0
    fi
    
    if ! sr_update_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" unregister_domain_filter "$domain"; then
        log_error "Failed to unregister domain: $domain"
        return 1
    fi
    
    log_success "Domain unregistered: $domain"
}

# Register a VPS node
register_vps() {
    local vps_ip="$1"
    local public_ip="$2"
    local region="${3:-unknown}"
    
    init_multi_domain_registry || return 1
    
    log_info "Registering VPS: $vps_ip ($region)"
    
    if ! SR_ALLOW_BLANK=1 sr_update_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" \
        register_vps_filter "$vps_ip" "$public_ip" "$region"; then
        log_error "Failed to register VPS: $vps_ip"
        return 1
    fi
    
    log_success "VPS registered: $vps_ip → $public_ip ($region)"
}

# Unregister a VPS node
unregister_vps() {
    local vps_ip="$1" rc=0
    
    log_info "Unregistering VPS: $vps_ip"
    
    sr_read_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" || rc=$?
    case "$rc" in
        0) ;;
        2 | 3)
            log_warn "VPS not found: $vps_ip"
            return 0
            ;;
        *)
            log_error "Could not read the domain registry; VPS $vps_ip not changed"
            return 1
            ;;
    esac
    
    if ! jq -e --arg ip "$vps_ip" 'any((.vps_nodes // [])[]; .tailscale_ip == $ip)' \
        <<<"$SR_READ_JSON" >/dev/null 2>&1; then
        log_warn "VPS not found: $vps_ip"
        return 0
    fi
    
    if ! sr_update_cm "$SR_DOMAIN_CM" "$DOMAINS_KEY" unregister_vps_filter "$vps_ip"; then
        log_error "Failed to unregister VPS: $vps_ip"
        return 1
    fi
    
    log_success "VPS unregistered: $vps_ip"
}

# Filters for sr_update_cm in purge_vps. Each leaves everything else as it found it,
# so with nothing to remove there is no write.
routing_drop_vps_filter() {
    jq -c --arg ip "$1" 'map_values(
        if type == "object" and (.vps_nodes | type) == "array"
        then .vps_nodes |= map(select(. != $ip))
        else . end)'
}

# Entries can carry the address as ip, tailscale_ip or both (see register_vps_node).
sync_registry_drop_vps_filter() {
    jq -c --arg ip "$1" '
        if (.vps_nodes | type) == "array"
        then .vps_nodes |= map(select(type != "object" or (.ip != $ip and .tailscale_ip != $ip)))
        else . end'
}

SYNC_REGISTRY_CM="sync-controller-registry"
SYNC_REGISTRY_KEY="registry.json"

# A ConfigMap or key that isn't there has nothing to remove. Only a failed read fails.
registry_readable() {
    local rc=0
    sr_read_cm "$1" "$2" || rc=$?
    if [[ "$rc" -eq 1 ]]; then
        log_error "Could not read $1/$2"
        return 1
    fi
}

drop_vps_from() {
    local cm="$1" key="$2" filter="$3" vps_ip="$4" rc=0
    sr_read_cm "$cm" "$key" || rc=$?
    case "$rc" in
        0) ;;
        2 | 3)
            log_info "Nothing to clean up in $cm/$key"
            return 0
            ;;
        *)
            log_error "Could not read $cm/$key"
            return 1
            ;;
    esac
    if ! sr_update_cm "$cm" "$key" "$filter" "$vps_ip"; then
        log_error "Failed to update $cm/$key"
        return 1
    fi
    log_success "Cleaned up $cm/$key"
}

# Removes a VPS from everything that names it: the VPS list, each route's vps_nodes,
# and the sync targets. Everything is read before anything is written, so a failed read
# changes nothing. Each write is conditional and only touches its own key. If one fails
# later on, the earlier ones stand, and running this again finishes the job.
purge_vps() {
    local vps_ip="$1"

    if ! sr_valid_ip "$vps_ip"; then
        log_error "Invalid IP address: $vps_ip"
        return 1
    fi

    if ! registry_readable "$SR_DOMAIN_CM" "$DOMAINS_KEY" ||
        ! registry_readable "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" ||
        ! registry_readable "$SYNC_REGISTRY_CM" "$SYNC_REGISTRY_KEY"; then
        log_error "VPS $vps_ip not changed"
        return 1
    fi

    unregister_vps "$vps_ip" &&
        drop_vps_from "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" routing_drop_vps_filter "$vps_ip" &&
        drop_vps_from "$SYNC_REGISTRY_CM" "$SYNC_REGISTRY_KEY" sync_registry_drop_vps_filter "$vps_ip"
}

# Configure service routing
# Maps service to fully-qualified domain(s) and VPS node(s)
# Clean Separation: Uses expose array with full domains
configure_service_routing() {
    local service_name="$1"
    local expose_domains="$2"   # Comma-separated full domains: curiios.com,www.curiios.com,chat.curiios.com
    local vps_nodes="$3"        # Comma-separated: 100.68.225.92,100.70.123.45
    local strategy="${4:-round-robin}"  # round-robin, primary-backup, geo
    
    # Validate required inputs
    if [[ -z "$service_name" ]] || [[ -z "$expose_domains" ]] || [[ -z "$vps_nodes" ]]; then
        log_error "Usage: configure-routing <service> <domains> <vps_nodes> [strategy]"
        return 1
    fi
    
    init_multi_domain_registry
    
    log_info "Configuring routing for: $service_name"
    
    # Verify service exists in service-registry, and file the routing under its
    # registry key whichever name was given.
    local services rc=0 service_key
    if ! services=$(sr_get_services); then
        log_error "Cannot read service-registry; routing not changed"
        return 1
    fi
    service_key=$(sr_resolve_key "$services" "$service_name") || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        log_error "'$service_name' matches several services; use namespace/name"
        return 1
    elif [[ "$rc" -ne 0 ]]; then
        log_error "Service '$service_name' not found in service-registry"
        log_info "Run 'service-registry.sh sync' first or check the service name"
        return 1
    fi
    service_name="$service_key"

    # Validate all domains first
    IFS=',' read -ra DOMAIN_ARRAY <<< "$expose_domains"
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain=$(echo "$domain" | xargs)  # Trim whitespace
        if ! validate_domain "$domain"; then
            log_error "Aborting due to invalid domain format"
            return 1
        fi
        
        # Check for conflicts
        if ! check_domain_conflicts "$domain" "$service_name"; then
            log_warn "Domain $domain is already in use by another service"
            if [[ -t 0 ]]; then
                read -p "Continue anyway? (y/n): " continue_conflict
                [ "$continue_conflict" != "y" ] && return 1
            else
                log_warn "Non-interactive mode: skipping conflict (caller should handle)"
            fi
        fi
    done
    
    # Convert comma-separated to JSON array and trim whitespace
    local expose_array vps_array entry aliases routing
    expose_array=$(printf '%s' "$expose_domains" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    vps_array=$(printf '%s' "$vps_nodes" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; ""))')
    entry=$(jq -cn \
        --argjson expose "$expose_array" \
        --argjson vps "$vps_array" \
        --arg strategy "$strategy" \
        '{
            expose: $expose,
            vps_nodes: $vps,
            strategy: $strategy,
            updated: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
    if ! routing=$(sr_get_routing); then
        log_error "Cannot read domain-registry; routing not changed"
        return 1
    fi
    aliases=$(sr_routing_keys_for "$services" "$service_key" "$routing" | jq -Rsc 'split("\n") | map(select(length > 0))')

    # routing.json may never have been written, so blank is fine here. The write is
    # conditional on what was read, so it can't lose another writer's entry.
    if ! SR_ALLOW_BLANK=1 sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" \
        sr_routing_set_filter "$service_key" "$entry" "$aliases"; then
        log_error "Failed to update domain-registry ConfigMap"
        return 1
    fi

    log_success "Routing configured for $service_name"
    log_info "  Exposed at:"
    echo "$expose_domains" | tr ',' '\n' | sed 's/^[ \t]*//' | sed 's/^/    - https:\/\//'
    log_info "  VPS Nodes: $vps_nodes"
    log_info "  Strategy: $strategy"
}

# Prints the routing.json key holding a service, whichever name it was given by.
# Routing can be filed under the bare name or namespace/name. Falls back to the name
# as given, so callers report it as not found.
routing_key_for() {
    local name="$1" routing services key candidate
    if routing=$(sr_get_routing) && ! jq -e --arg k "$name" 'has($k)' <<<"$routing" >/dev/null &&
        services=$(sr_get_services) && key=$(sr_resolve_key "$services" "$name" 2>/dev/null); then
        while IFS= read -r candidate; do
            if jq -e --arg k "$candidate" 'has($k)' <<<"$routing" >/dev/null; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done < <(sr_routing_keys_for "$services" "$key" "$routing")
    fi
    printf '%s\n' "$name"
}

# Filters for sr_update_cm, which runs them again on a conflict. An entry that has
# gone since it was checked below is an error, so nothing is written for it.
add_domain_filter() {
    jq -c --arg service "$1" --arg domain "$2" '
        if has($service) | not then error("no routing entry for \($service)") else . end
        | .[$service].expose |= (. + [$domain] | unique)
        | .[$service].updated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

remove_domain_filter() {
    jq -c --arg service "$1" --arg domain "$2" '
        if has($service) | not then error("no routing entry for \($service)") else . end
        | .[$service].expose |= ((. // []) - [$domain])
        | .[$service].updated = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

# Add domain to existing service routing
# Appends domain to expose array instead of replacing
add_domain() {
    local service_name
    service_name=$(routing_key_for "$1")
    local new_domain="$2"  # Single domain to add

    init_multi_domain_registry

    log_info "Adding domain to $service_name: $new_domain"
    
    # Validate domain format
    if ! validate_domain "$new_domain"; then
        return 1
    fi
    
    # Check for domain conflicts
    local has_conflict=false
    if ! check_domain_conflicts "$new_domain" "$service_name"; then
        has_conflict=true
    fi
    
    # Warn about conflicts but allow continuation
    if [ "$has_conflict" = true ]; then
        if [[ -t 0 ]]; then
            read -p "Continue anyway? (y/n): " continue_conflict
            [ "$continue_conflict" != "y" ] && return 1
        else
            log_warn "Non-interactive mode: skipping conflict (caller should handle)"
        fi
    fi
    
    # A failed read is an error here, not an empty routing table.
    local routing
    if ! routing=$(sr_get_routing); then
        log_error "Could not read routing config; nothing changed"
        return 1
    fi

    # Check if service exists in routing
    if ! jq -e --arg service "$service_name" '.[$service]' <<<"$routing" >/dev/null 2>&1; then
        log_error "Service $service_name not found in routing config"
        log_info "Use 'configure-routing' to create initial routing"
        return 1
    fi

    # Add domain to expose array (check for duplicates). The write is conditional on
    # what was read, so it can't lose another writer's change.
    if ! sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" \
        add_domain_filter "$service_name" "$new_domain"; then
        log_error "Failed to add domain: $new_domain"
        return 1
    fi
    
    log_success "Domain added: $new_domain"
    
    # Show current domains
    list_domains "$service_name"
}

# Remove domain from existing service routing
remove_domain() {
    local service_name
    service_name=$(routing_key_for "$1")
    local remove_domain="$2"  # Single domain to remove
    
    init_multi_domain_registry
    
    log_info "Removing domain from $service_name: $remove_domain"
    
    # A failed read is an error here, not an empty routing table.
    local routing
    if ! routing=$(sr_get_routing); then
        log_error "Could not read routing config; nothing changed"
        return 1
    fi

    # Check if service exists
    if ! jq -e --arg service "$service_name" '.[$service]' <<<"$routing" >/dev/null 2>&1; then
        log_error "Service $service_name not found in routing config"
        return 1
    fi

    # Remove domain from expose array. The write is conditional on what was read, so
    # it can't lose another writer's change.
    if ! sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" \
        remove_domain_filter "$service_name" "$remove_domain"; then
        log_error "Failed to remove domain: $remove_domain"
        return 1
    fi
    
    log_success "Domain removed: $remove_domain"
    
    # Show remaining domains
    list_domains "$service_name"
}

# List domains for a service
list_domains() {
    local service_name
    service_name=$(routing_key_for "$1")

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
    
    # Get all routing entries. A failed read must not look like "no routes": the
    # output of this command can be installed as the VPS's route file.
    local routing services
    if ! routing=$(sr_get_routing); then
        log_error "Cannot read domain routing"
        return 1
    fi
    if ! services=$(sr_get_services); then
        log_error "Cannot read service registry"
        return 1
    fi

    if [[ "$routing" == "{}" ]]; then
        log_warn "No routing configured"
        return 1
    fi

    # Filter routes for this VPS using Clean Separation expose array
    local vps_routes
    vps_routes=$(jq -c \
        --arg vps "$vps_ip" \
        'to_entries[] |
        select((.value.vps_nodes? // []) | index($vps)) |
        .key as $service |
        (.value.expose? // [])[] as $url |
        {
            service: $service,
            url: $url
        }' <<<"$routing")

    # Work out each route first, so a route that can't be rendered safely is left out
    # whole. Route IDs match the config API's for a migrated entry and never contain
    # a slash, which Traefik names can't hold.
    local rendered_routers="" rendered_services="" seen_services=" "
    local route service url key entry route_id blocked safe_url rule
    while IFS= read -r route; do
        [[ -n "$route" ]] || continue
        service=$(jq -r '.service' <<<"$route")
        url=$(jq -r '.url' <<<"$route")

        if ! key=$(sr_resolve_key "$services" "$service" 2>/dev/null); then
            sr_warn "routing entry '$service' matches no single service; not publishing $url"
            continue
        fi
        entry=$(jq -c --arg k "$key" '.[$k]' <<<"$services")
        if [[ "$(jq -r '.public' <<<"$entry")" != "true" ]]; then
            sr_warn "$key is not public; not publishing $url"
            continue
        fi
        if ! sr_valid_fqdn "$url"; then
            sr_warn "invalid domain for $key; not publishing it"
            continue
        fi
        if ! blocked=$(sr_blocked_rule_suffix "$entry" "$key" 2>/dev/null); then
            sr_warn "$key has invalid public_blocked_paths; not publishing $url"
            continue
        fi

        # Same IDs as assignRouteIDs in cmd/config-api/main.go.
        route_id=$(jq -r --arg k "$key" '
            def base($k; $v): $v.legacy_key // ($k | split("/") | last);
            . as $all
            | base($k; $all[$k]) as $id
            | if ([to_entries[] | select((.value | type) == "object" and .value.public == true and base(.key; .value) == $id)] | length) > 1
              then $k | gsub("/"; "-")
              else $id end' <<<"$services")
        route_id=${route_id//[^A-Za-z0-9_-]/-}

        # Clean URL/Host for Traefik naming (replace dots with dashes)
        safe_url=${url//\./-}
        rule="Host(\`${url}\`)${blocked}"

        rendered_routers+="    ${route_id}-${safe_url}:
      rule: \"${rule}\"
      service: ${route_id}-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt

    ${route_id}-${safe_url}-http:
      rule: \"${rule}\"
      service: ${route_id}-service
      entryPoints:
        - web
      middlewares:
        - https-redirect

"

        # One service block per route ID
        if [[ "$seen_services" == *" $route_id "* ]]; then
            continue
        fi
        seen_services+="$route_id "

        local svc_ip port backend_url
        svc_ip=$(jq -r '.ip // ""' <<<"$entry")
        port=$(jq -r '.port // ""' <<<"$entry")
        if ! sr_valid_port "$port"; then
            sr_warn "$key has no valid port; its routes have no backend"
            continue
        fi

        # Use service LoadBalancer IP if available, otherwise fallback to control plane
        if sr_valid_ip "$svc_ip"; then
            backend_url="http://${svc_ip}:${port}"
        else
            backend_url="http://${control_plane_ip}:${port}"
        fi

        rendered_services+="    ${route_id}-service:
      loadBalancer:
        servers:
          - url: \"${backend_url}\"

"
    done <<<"$vps_routes"

    if [[ -z "$rendered_routers" ]]; then
        log_info "No routes assigned to VPS: $vps_ip"
        return 0
    fi

    # Generate Traefik configuration
    echo "# Multi-Domain Routing for VPS: $vps_ip"
    echo "# Generated on: $(date)"
    echo ""
    echo "http:"
    echo "  routers:"
    printf '%s' "$rendered_routers"
    echo "  services:"
    printf '%s' "$rendered_services"

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
    purge-vps)
        purge_vps "$2"
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

  purge-vps <tailscale_ip>                Remove a VPS node from the VPS list, all
                                          service routes and the sync targets
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
