#!/bin/bash

###############################################################################
# Manage App Public Visibility
# 
# Make apps publicly accessible or private (local-only)
# Handles edge cases, retries, and verification
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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
# shellcheck source=../lib/service-registry-lib.sh
source "$PROJECT_ROOT/scripts/lib/service-registry-lib.sh"
MAX_RETRIES=3

# `private` exits with this when the registry changed but the public route could
# not be confirmed gone from a VPS, so callers can tell it from a plain failure.
EXIT_NOT_VERIFIED=3

# Node Agents poll every 60s, so a change normally lands within 90s.
VPS_MAX_WAIT="${VISIBILITY_MAX_WAIT:-120}"
VPS_POLL_INTERVAL="${VISIBILITY_POLL_INTERVAL:-10}"

# Set to 1 by --allow-infrastructure.
ALLOW_INFRASTRUCTURE="${MYNODEONE_ALLOW_INFRASTRUCTURE_PUBLIC:-0}"

# Load cluster config
ACTUAL_HOME="${HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
if [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    source "$ACTUAL_HOME/.mynodeone/config.env"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Retry function with exponential backoff. Takes a command and its arguments, not
# a string, so nothing it's given is ever parsed by a shell.
retry_command() {
    local max_attempts="$1"
    shift
    local attempt=1
    local delay=2

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

cluster_reachable() {
    kubectl get nodes >/dev/null 2>&1
}

# Verify kubectl access
verify_cluster_access() {
    if ! retry_command 3 cluster_reachable; then
        log_error "Cannot access cluster"
        echo "Please ensure:"
        echo "  1. You're on the control plane OR"
        echo "  2. kubectl is configured to access the cluster"
        return 1
    fi
    return 0
}

# Verify service exists and turn what was typed (llmapi or llmapi/llmapi) into the
# registry key. Sets RESOLVED_SERVICE.
RESOLVED_SERVICE=""
verify_service_exists() {
    local service_name="$1" services rc=0

    if ! services=$(sr_get_services); then
        log_error "Cannot read the service registry"
        return 1
    fi
    RESOLVED_SERVICE=$(sr_resolve_key "$services" "$service_name") || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) log_error "'$service_name' matches several services; use namespace/name" ;;
        *) log_error "Service '$service_name' not found in registry" ;;
    esac
    return 1
}

# Services that manage the cluster or its data. They commonly have no login of
# their own and rely on being reachable only from the tailnet.
is_infrastructure_service() {
    local key="${1,,}" local_name="${2,,}" part
    for part in "$key" "${key##*/}" "$local_name"; do
        case "$part" in
            *longhorn* | *minio* | *dashboard* | *grafana* | *argocd* | *traefik* | *prometheus* | *alertmanager* | kube-*)
                return 0
                ;;
        esac
    done
    return 1
}

# Publishing one of those takes a deliberate step: typing its name, or the flag
# when there is no terminal to type at.
confirm_infrastructure_publish() {
    local key="$1" local_name="$2" typed=""
    is_infrastructure_service "$key" "$local_name" || return 0

    log_warn "'$key' looks like an infrastructure service (storage, dashboards, cluster admin)."
    log_warn "Publishing it can hand the internet control of the cluster or its data."
    if [[ "$ALLOW_INFRASTRUCTURE" == "1" ]]; then
        log_warn "Continuing because --allow-infrastructure was given"
        return 0
    fi
    if [[ -t 0 ]]; then
        read -r -p "Type the service name ($key) to publish it anyway: " typed
        [[ "$typed" == "$key" ]] && return 0
        log_error "Not confirmed; nothing was changed"
        return 1
    fi
    log_error "Refusing to publish '$key' without --allow-infrastructure; nothing was changed"
    return 1
}

# Verify domain registry exists
verify_domain_registry() {
    if ! kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        log_warn "Domain registry not initialized"
        log_info "Initializing now..."
        
        if bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" init; then
            log_success "Domain registry initialized"
            return 0
        else
            log_error "Failed to initialize domain registry"
            return 1
        fi
    fi
    return 0
}

# Check if VPS nodes are available
check_vps_availability() {
    local vps_count=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq '.vps_nodes | length' 2>/dev/null || echo "0")
    
    if [ "${vps_count:-0}" -eq 0 ]; then
        log_warn "No VPS nodes registered"
        echo ""
        echo "To make apps publicly accessible, you need a VPS edge node."
        echo "Install one with: sudo ./scripts/installation/install-mynodeone.sh → Option 3 (VPS Edge Node)"
        echo ""
        return 1
    fi
    return 0
}

# Check if domains are configured
check_domain_availability() {
    local domain_count=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq '.domains | length' 2>/dev/null || echo "0")
    
    if [ "${domain_count:-0}" -eq 0 ]; then
        log_warn "No domains registered"
        echo ""
        echo "To make apps publicly accessible, you need a domain."
        echo "Add one with: multi-domain-registry.sh register-domain <domain>"
        echo ""
        return 1
    fi
    return 0
}

###############################################################################
# Checking what a VPS actually serves
###############################################################################

vps_ssh() {
    local timeout="$1" user="$2" ip="$3" command="$4"
    ssh -o BatchMode=yes -o ConnectTimeout="$timeout" -o StrictHostKeyChecking=no \
        "$user@$ip" "$command" </dev/null 2>/dev/null
}

vps_ssh_user() {
    local ip="$1" user=""
    user=$(kubectl get configmap -n kube-system sync-controller-registry \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null |
        jq -r --arg ip "$ip" '[.vps_nodes[]? | select(.ip == $ip) | .ssh_user] | first // ""' 2>/dev/null) || user=""
    if [[ ! "$user" =~ ^[a-z_][a-z0-9_.-]*$ ]]; then
        user="root"
    fi
    printf '%s\n' "$user"
}

# Every VPS the registries know about, comma-separated.
known_vps_nodes() {
    {
        kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.domains\.json}' 2>/dev/null |
            jq -r '.vps_nodes[]?.tailscale_ip // empty' 2>/dev/null || true
        kubectl get configmap -n kube-system sync-controller-registry \
            -o jsonpath='{.data.registry\.json}' 2>/dev/null |
            jq -r '.vps_nodes[]?.ip // empty' 2>/dev/null || true
    } | sort -u | paste -sd, -
}

# The script run on the VPS. It looks in every file Traefik could be loading routes
# from, so a route left by the older per-app generator counts too. Exits 0 if the
# route is there, 10 if it isn't, anything else if it can't tell. The domain has
# been validated, so it can't break out of the quotes.
route_check_script() {
    local domain="$1"
    cat <<EOF
pat='Host(\`${domain}\`)'; rc=10; seen=0
for d in "\$HOME/traefik/config" /root/traefik/config /etc/traefik/config /etc/traefik/dynamic /home/*/traefik/config; do
    [ -d "\$d" ] || continue
    for f in "\$d"/*.yml "\$d"/*.yaml; do
        [ -f "\$f" ] || continue
        seen=1
        grep -qF -- "\$pat" "\$f"; s=\$?
        [ "\$s" -eq 0 ] && exit 0
        [ "\$s" -eq 1 ] || rc=11
    done
done
[ "\$seen" -eq 1 ] || exit 11
exit "\$rc"
EOF
}

# Returns 0 route present, 1 route absent, 2 can't tell.
vps_route_state() {
    local ip="$1" domain="$2" user rc=0
    if ! sr_valid_ip "$ip" || ! sr_valid_fqdn "$domain"; then
        return 2
    fi
    user=$(vps_ssh_user "$ip")
    vps_ssh 5 "$user" "$ip" "$(route_check_script "$domain")" || rc=$?
    case "$rc" in
        0) return 0 ;;
        10) return 1 ;;
        *) return 2 ;;
    esac
}

# Is every domain in the wanted state ("present" or "absent") on this VPS?
vps_routes_match() {
    local ip="$1" domains_csv="$2" want="$3" domain state domain_list
    IFS=',' read -ra domain_list <<<"$domains_csv"
    for domain in "${domain_list[@]}"; do
        domain=$(echo "$domain" | xargs)
        state=0
        vps_route_state "$ip" "$domain" || state=$?
        case "$want:$state" in
            present:0 | absent:1) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Polls until all VPS nodes match, or the wait runs out.
wait_for_routes() {
    local vps_csv="$1" domains_csv="$2" want="$3" elapsed=0 all_synced vps_ip vps_list
    IFS=',' read -ra vps_list <<<"$vps_csv"
    while true; do
        all_synced=true
        for vps_ip in "${vps_list[@]}"; do
            vps_ip=$(echo "$vps_ip" | xargs)
            if ! vps_routes_match "$vps_ip" "$domains_csv" "$want"; then
                all_synced=false
                break
            fi
        done
        if [ "$all_synced" = true ]; then
            return 0
        fi
        if [ "$elapsed" -ge "$VPS_MAX_WAIT" ]; then
            return 1
        fi
        echo "  Waiting for sync... (${elapsed}s/${VPS_MAX_WAIT}s)"
        sleep "$VPS_POLL_INTERVAL"
        elapsed=$((elapsed + VPS_POLL_INTERVAL))
    done
}

# Push the sync over SSH for a VPS whose agent hasn't caught up, then look again.
# The push succeeding isn't evidence on its own; only the routes file is.
force_vps_sync() {
    local vps_ip="$1" domains_csv="$2" want="$3" user
    if ! sr_valid_ip "$vps_ip"; then
        return 1
    fi
    if sr_vps_push_loses_routes; then
        log_error "  ✗ Not syncing $vps_ip over SSH: it could replace its routes with an empty file"
        return 1
    fi
    user=$(vps_ssh_user "$vps_ip")
    log_warn "  ⚠ Node Agent sync pending on $vps_ip - falling back to SSH sync..."
    if ! vps_ssh 10 "$user" "$vps_ip" "cd ~/mynodeone && sudo ./scripts/vps/sync-vps-routes.sh" >/dev/null; then
        log_error "  ✗ SSH sync failed on $vps_ip"
        return 1
    fi
    vps_routes_match "$vps_ip" "$domains_csv" "$want"
}

###############################################################################
# Make app public
###############################################################################

make_public() {
    local service_name="$1"
    local domains="${2:-}"
    local vps_nodes="${3:-}"
    local services routing

    if ! services=$(sr_get_services); then
        log_error "Cannot read the service registry; nothing was changed"
        return 1
    fi
    if ! routing=$(sr_get_routing); then
        log_error "Cannot read the domain routing; nothing was changed"
        return 1
    fi

    local local_name
    local_name=$(jq -r --arg svc "$service_name" '.[$svc].local_name // ""' <<<"$services")

    if ! confirm_infrastructure_publish "$service_name" "$local_name"; then
        return 1
    fi

    log_info "Making '$service_name' publicly accessible..."
    log_warn "Public access adds no login or other protection. Anyone on the internet"
    log_warn "reaches whatever this app itself exposes, so check that it has its own authentication."

    # A record under a bare name another entry also goes by could be that entry's, so
    # this service must not pick it up by going public. With domains given it gets a
    # record of its own below; without any there is nothing to tell them apart.
    local inherited
    inherited=$(sr_routing_inherited_by "$services" "$service_name" "$routing")
    if [[ -n "$inherited" && ( -z "$domains" || -z "$vps_nodes" ) ]]; then
        log_error "Not making '$service_name' public: it would take over the routing filed under: ${inherited//$'\n'/, }"
        log_error "Another service goes by that name. Give the domains and VPS nodes to use, or remove that record first."
        return 1
    fi

    # A bare record stays with the public service using it today. Going public next to
    # that service would otherwise make the record ambiguous and drop its live route.
    if [[ "$routing" != "{}" ]] &&
        ! sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" sr_routing_promote_filter "$services" "$service_name"; then
        log_error "Could not update the domain routing; nothing was changed"
        return 1
    fi

    # Routing goes first. The API renders a public entry as soon as it sees one, and
    # until this entry has its own record it could resolve to a bare one.
    if [ -n "$domains" ] && [ -n "$vps_nodes" ]; then
        log_info "Configuring routing..."

        if retry_command "$MAX_RETRIES" bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" configure-routing "$service_name" "$domains" "$vps_nodes"; then
            log_success "Routing configured"
        else
            log_error "Failed to configure routing after $MAX_RETRIES attempts"
            log_warn "The service was not marked public"
            log_info "You can retry: sudo bash scripts/operations/manage-app-visibility.sh public '$service_name' '$domains' '$vps_nodes'"
            return 1
        fi
    fi

    # Update service registry to mark as public
    if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" sr_set_public_filter "$service_name" true; then
        log_error "Failed to update service registry"
        return 1
    fi

    log_success "Service marked as public in registry"

    if [ -n "$domains" ] && [ -n "$vps_nodes" ]; then
        # Call app-specific post-public hook if it exists. Hooks live under the bare
        # app name and look the service up in the registry by the key they're given.
        local app_dir
        app_dir=$(sr_bare_name "$services" "$service_name")
        if sr_valid_k8s_name "$app_dir" && [ -f "$PROJECT_ROOT/scripts/apps/$app_dir/post-public-hook.sh" ]; then
            log_info "Running app-specific configuration hook..."
            if ! bash "$PROJECT_ROOT/scripts/apps/$app_dir/post-public-hook.sh" "$service_name" "$domains"; then
                log_warn "App-specific configuration had issues (check above)"
            fi
        fi
    fi

    # Verify configuration in ConfigMap
    sleep 1
    local is_public=""
    if services=$(sr_get_services); then
        is_public=$(jq -r --arg svc "$service_name" '.[$svc].public' <<<"$services")
    fi

    if [ "$is_public" != "true" ]; then
        log_error "✗ Service not marked as public in ConfigMap"
        return 1
    fi

    log_success "✓ Service marked as public in ConfigMap"

    if [ -z "$domains" ] || [ -z "$vps_nodes" ]; then
        log_warn "No domains and VPS nodes were given, so no public route was configured or checked."
        log_warn "The service is only marked public in the registry."
        return 0
    fi

    # Wait for Node Agent to sync routes to VPS nodes
    # Node Agents poll every 60s, Config API updates every 30s
    # Total max wait: ~90s, but usually faster
    log_info "Waiting for Node Agent to sync routes to VPS nodes..."
    echo "  (Node Agents poll every 60s - this may take up to 90 seconds)"
    echo ""

    wait_for_routes "$vps_nodes" "$domains" present || true

    # Verify final state
    log_info "Verifying routes on VPS nodes..."
    local verification_failed=false vps_ip vps_user="root"
    local vps_array
    IFS=',' read -ra vps_array <<<"$vps_nodes"

    for vps_ip in "${vps_array[@]}"; do
        vps_ip=$(echo "$vps_ip" | xargs)
        if ! sr_valid_ip "$vps_ip"; then
            log_error "  ✗ Not a valid VPS address: $vps_ip"
            verification_failed=true
            continue
        fi

        vps_user=$(vps_ssh_user "$vps_ip")
        log_info "Checking VPS: $vps_ip (user: $vps_user)..."

        if vps_routes_match "$vps_ip" "$domains" present; then
            log_success "  ✓ Routes synced for $service_name"
        elif force_vps_sync "$vps_ip" "$domains" present; then
            log_success "  ✓ Routes synced for $service_name over SSH"
        else
            log_error "  ✗ Routes for $service_name are not on $vps_ip"
            verification_failed=true
        fi

        # Check if Traefik is running
        if vps_ssh 5 "$vps_user" "$vps_ip" "docker ps | grep -q traefik"; then
            log_success "  ✓ Traefik is running"
        else
            log_error "  ✗ Traefik is NOT running"
            verification_failed=true
        fi
    done

    if [ "$verification_failed" = true ]; then
        log_error "VPS verification failed - routes may not be accessible"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check Node Agent status: ssh <user>@<vps-ip> 'systemctl status mynodeone-node-agent'"
        echo "  2. Check Traefik logs: ssh <user>@<vps-ip> 'docker logs traefik --tail 50'"
        echo "  3. Verify routes file: ssh <user>@<vps-ip> 'cat ~/traefik/config/mynodeone-routes.yml'"
        echo ""
        return 1
    fi

    log_success "✓ All VPS nodes verified"

    # Test HTTP endpoint accessibility
    log_info "Testing endpoint accessibility..."
    echo "  This may take 30-60 seconds for SSL certificate issuance..."

    local domain_array
    IFS=',' read -ra domain_array <<<"$domains"
    local first_domain
    first_domain=$(echo "${domain_array[0]}" | xargs)
    local test_url="https://${first_domain}"   # Use full domain directly

    local max_attempts=12
    local attempt=1
    local endpoint_accessible=false

    while [ $attempt -le $max_attempts ]; do
        if curl -I -k -m 10 "$test_url" 2>/dev/null | grep -q "HTTP.*[23]0[0-9]"; then
            log_success "✓ Endpoint is accessible: $test_url"
            endpoint_accessible=true
            break
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo "  Waiting for SSL certificate... ($attempt/$max_attempts)"
            sleep 5
        fi
        attempt=$((attempt + 1))
    done

    if [ "$endpoint_accessible" = false ]; then
        log_warn "⚠ Endpoint not accessible after ${max_attempts} attempts"
        echo ""
        echo "This is normal if:"
        echo "  • DNS records are not yet propagated (can take 5-10 minutes)"
        echo "  • SSL certificate is still being issued (first time only)"
        echo ""
        echo "Check:"
        echo "  1. DNS: dig ${first_domain}"
        echo "  2. Traefik logs: ssh $vps_user@$vps_ip 'docker logs traefik --tail 50'"
        echo "  3. Try again in 5 minutes: curl -I $test_url"
        echo ""
        # Don't fail here - DNS propagation can take time
    fi

    return 0
}

###############################################################################
# Make app private
###############################################################################

# Returns 0 only once the route is confirmed gone from every VPS it was on, and
# EXIT_NOT_VERIFIED if the registry is updated but that couldn't be confirmed.
make_private() {
    local service_name="$1"
    local services routing routing_keys contested domains vps_nodes

    log_info "Making '$service_name' private (local-only)..."

    if ! services=$(sr_get_services); then
        log_error "Cannot read the service registry; nothing was changed"
        return 1
    fi
    if ! routing=$(sr_get_routing); then
        log_error "Cannot read the domain routing; nothing was changed"
        return 1
    fi

    # Read what has to disappear from the VPS before deleting the record of it. An
    # unmigrated routing.json can still file this service under its bare name.
    routing_keys=$(sr_routing_keys_for "$services" "$service_name" "$routing" | jq -Rsc 'split("\n") | map(select(length > 0))')

    # A record this service shares a claim on has no route today. Left in place it would
    # go live for the other service as soon as this one stops claiming it, and nothing
    # says the domain was meant for that one. It goes too, and the operator is told.
    contested=$(sr_routing_contested_by "$services" "$service_name" "$routing")
    if [[ -n "$contested" ]]; then
        log_warn "Routing filed under '${contested//$'\n'/, }' also matches another public service, so it published no route."
        log_warn "Removing it so that service doesn't inherit the domains. To give them to it, run configure-routing for it."
        routing_keys=$(jq -c --arg more "$contested" '. + ($more | split("\n")) | unique' <<<"$routing_keys")
    fi

    domains=$(jq -r --argjson keys "$routing_keys" '
        . as $all | [$keys[] as $k | ($all[$k].expose? // [])
                     | if type == "array" then .[] else empty end | select(type == "string")]
        | unique | join(",")' <<<"$routing")
    vps_nodes=$(jq -r --argjson keys "$routing_keys" '
        . as $all | [$keys[] as $k | ($all[$k].vps_nodes? // [])
                     | if type == "array" then .[] else empty end | select(type == "string")]
        | unique | join(",")' <<<"$routing")

    # Update service registry to mark as private. The API stops rendering the route
    # as soon as this lands, so it goes first.
    if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" sr_set_public_filter "$service_name" false; then
        log_error "Failed to update service registry"
        return 1
    fi
    log_success "Service marked as private in registry"

    # Remove from domain routing
    log_info "Removing from public routing..."
    if jq -e --argjson keys "$routing_keys" '. as $all | any($keys[]; . as $k | $all | has($k))' <<<"$routing" >/dev/null; then
        if ! SR_ALLOW_BLANK=1 sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" sr_routing_del_filter "$routing_keys"; then
            log_error "Could not remove its routing entry from domain-registry"
            log_warn "The service is marked private, but routing for it is still on record: ${domains:-none}"
            return 1
        fi
        log_success "Removed from routing"
    else
        log_info "It had no routing entry"
    fi

    # Verify
    local is_public="unknown"
    if services=$(sr_get_services); then
        is_public=$(jq -r --arg svc "$service_name" '.[$svc].public' <<<"$services")
    fi
    if [ "$is_public" != "false" ]; then
        log_error "✗ Verification failed: Service still marked as public"
        return 1
    fi
    log_success "✓ Registry says the service is private"

    if [[ -z "$domains" ]]; then
        log_info "No public domain was on record for it, so there is no VPS route to check"
        return 0
    fi

    [[ -n "$vps_nodes" ]] || vps_nodes=$(known_vps_nodes)

    # Node Agents poll every 60s and old ones ignore an empty route list, so look at
    # the VPS rather than assuming.
    local vps_list vps_ip all_clean=true
    if [[ -n "$vps_nodes" ]]; then
        log_info "Waiting for the public route to disappear from VPS nodes..."
        echo "  (Node Agents poll every 60s - this may take up to ${VPS_MAX_WAIT} seconds)"
        if ! wait_for_routes "$vps_nodes" "$domains" absent; then
            IFS=',' read -ra vps_list <<<"$vps_nodes"
            for vps_ip in "${vps_list[@]}"; do
                vps_ip=$(echo "$vps_ip" | xargs)
                if ! vps_routes_match "$vps_ip" "$domains" absent &&
                    ! force_vps_sync "$vps_ip" "$domains" absent; then
                    all_clean=false
                    log_error "  ✗ Could not confirm the route is gone from $vps_ip"
                fi
            done
        fi
    else
        all_clean=false
        log_error "  ✗ No VPS nodes on record to check"
    fi

    if [[ "$all_clean" == true ]]; then
        log_success "✓ Verified on VPS nodes: no route for $domains"
        return 0
    fi

    echo ""
    log_warn "NOT VERIFIED: the registry is updated, but the public route may STILL BE LIVE."
    echo "  Domains: $domains"
    echo "  VPS nodes: ${vps_nodes:-unknown}"
    echo "  Check on the VPS: grep -l 'Host(' ~/traefik/config/*.yml"
    echo "  Force an update:  cd ~/mynodeone && sudo ./scripts/vps/sync-vps-routes.sh"
    echo "  Check an agent:   systemctl status mynodeone-node-agent"
    echo ""
    return "$EXIT_NOT_VERIFIED"
}

# Main interactive mode
main() {
    clear 2>/dev/null || true
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Manage App Public Visibility"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Verify cluster access
    if ! verify_cluster_access; then
        exit 1
    fi
    
    log_success "Cluster access verified"
    echo ""
    
    # Get all services
    local services
    if ! services=$(sr_get_services); then
        log_error "Cannot read the service registry"
        exit 1
    fi

    if [ "$services" = "{}" ]; then
        log_error "No services found in registry"
        echo "Install apps first, then run this script"
        exit 1
    fi

    # Display services
    echo "Available services:"
    echo ""

    declare -a service_array
    declare -a local_name_array
    declare -a public_array
    i=1

    # Values come from annotations, so anything outside this set is masked before it
    # reaches the terminal or the field separator.
    while IFS='|' read -r service local_name is_public; do
        local status_marker="🔒 Private"
        [ "$is_public" = "true" ] && status_marker="🌍 Public"
        local infra_marker=""
        is_infrastructure_service "$service" "$local_name" && infra_marker=" [infrastructure]"

        echo "  $i. $service (local: $local_name) - $status_marker$infra_marker"
        service_array[$i]="$service"
        local_name_array[$i]="$local_name"
        public_array[$i]="$is_public"
        ((i++))
    done < <(jq -r 'to_entries[]
        | [.key, (.value.local_name // "" | tostring), (.value.public // false | tostring)]
        | map(gsub("[^A-Za-z0-9._/-]"; "?")) | join("|")' <<<"$services")

    echo ""
    read -p "Select service number: " service_num
    
    local selected_service="${service_array[$service_num]:-}"
    if [ -z "$selected_service" ]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    local current_status="${public_array[$service_num]:-false}"
    local local_name="${local_name_array[$service_num]:-}"
    
    echo ""
    echo "Selected: $selected_service (local: $local_name)"
    echo "Current status: $([ "$current_status" = "true" ] && echo "🌍 Public" || echo "🔒 Private (local-only)")"
    echo ""
    
    echo "What do you want to do?"
    echo "  1. Make public (accessible from internet)"
    echo "  2. Make private (local access only)"
    echo "  3. Cancel"
    echo ""
    read -p "Choice: " action_choice
    
    case "$action_choice" in
        1)
            # Make public
            if [ "$current_status" = "true" ]; then
                log_info "Service is already public"
                echo ""
                read -p "Reconfigure routing? (y/n): " reconfig
                [ "$reconfig" != "y" ] && exit 0
            fi
            
            echo ""
            
            # Verify prerequisites
            if ! verify_domain_registry; then
                exit 1
            fi
            
            if ! check_vps_availability; then
                exit 1
            fi
            
            if ! check_domain_availability; then
                exit 1
            fi
            
            # Input full domains
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Configure Public URLs"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "Registered domains available:"
            kubectl get configmap -n kube-system domain-registry \
                -o jsonpath='{.data.domains\.json}' 2>/dev/null | jq -r '.domains | keys[]' | sed 's/^/  - /'
            echo ""
            echo "Enter full URLs (comma-separated):"
            echo "Examples:"
            echo "  • Root:      curiios.com"
            echo "  • WWW:       www.curiios.com"
            echo "  • Subdomain: $local_name.curiios.com"
            echo ""
            read -p "URLs: " selected_domains
            
            if [ -z "$selected_domains" ]; then
                log_error "At least one URL is required"
                exit 1
            fi
            
            # Validate domain formats
            echo ""
            echo "Validating domain formats..."
            local invalid_domains=false
            IFS=',' read -ra DOMAIN_ARRAY <<< "$selected_domains"
            for domain in "${DOMAIN_ARRAY[@]}"; do
                domain=$(echo "$domain" | xargs)  # Trim whitespace
                
                # Basic domain validation
                if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
                    log_error "Invalid domain format: $domain"
                    log_error "Domain must follow standard format (e.g., example.com, www.example.com, app.example.com)"
                    invalid_domains=true
                elif [[ "$domain" =~ \.\. ]]; then
                    log_error "Invalid domain format: $domain (consecutive dots not allowed)"
                    invalid_domains=true
                elif [[ "$domain" =~ ^\. ]] || [[ "$domain" =~ \.$ ]]; then
                    log_error "Invalid domain format: $domain (cannot start or end with dot)"
                    invalid_domains=true
                elif [[ ${#domain} -gt 253 ]]; then
                    log_error "Invalid domain format: $domain (too long, max 253 characters)"
                    invalid_domains=true
                fi
            done
            
            if [ "$invalid_domains" = true ]; then
                log_error "Please fix the invalid domains and try again"
                exit 1
            fi
            
            # Check for domain conflicts
            echo ""
            echo "Checking for domain conflicts..."
            local has_conflicts=false routing own_keys
            if ! routing=$(sr_get_routing); then
                log_error "Cannot read the domain routing"
                exit 1
            fi
            # A bare key from before the migration is this same service, not a conflict.
            own_keys=$(sr_routing_keys_for "$services" "$selected_service" "$routing" | jq -Rsc 'split("\n") | map(select(length > 0))')
            for domain in "${DOMAIN_ARRAY[@]}"; do
                domain=$(echo "$domain" | xargs)
                
                local conflicting_service
                conflicting_service=$(jq -r --arg domain "$domain" --argjson own "$own_keys" '
                        to_entries[] |
                        select(.key as $k | $own | index($k) | not) |
                        select(any((.value.expose? // [])[]; . == $domain)) |
                        .key
                    ' <<<"$routing")

                if [[ -n "$conflicting_service" && "$conflicting_service" != "null" ]]; then
                    log_warn "Domain $domain is already used by service: $conflicting_service"
                    has_conflicts=true
                fi
            done
            
            if [ "$has_conflicts" = true ]; then
                echo ""
                read -p "Continue anyway? This will override existing configurations (y/n): " continue_conflict
                [ "$continue_conflict" != "y" ] && exit 1
            fi
            
            # Select VPS nodes
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Select VPS Nodes"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            declare -a vps_array
            i=1
            while IFS='|' read -r ip public_ip region; do
                echo "  $i. $ip → $public_ip ($region)"
                vps_array[$i]="$ip"
                ((i++))
            done < <(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
                jq -r '.vps_nodes[] | "\(.tailscale_ip)|\(.public_ip)|\(.location)"')
            
            echo ""
            echo "Select VPS nodes (comma-separated numbers or 'all'):"
            read -p "Selection: " vps_selection
            
            local selected_vps=""
            if [ "$vps_selection" = "all" ]; then
                selected_vps=$(kubectl get configmap -n kube-system domain-registry \
                    -o jsonpath='{.data.domains\.json}' | jq -r '.vps_nodes[].tailscale_ip' | tr '\n' ',' | sed 's/,$//')
            else
                declare -a vps_list
                IFS=',' read -ra NUMS <<< "$vps_selection"
                for num in "${NUMS[@]}"; do
                    num=$(echo "$num" | xargs)
                    [ -n "${vps_array[$num]:-}" ] && vps_list+=("${vps_array[$num]}")
                done
                selected_vps=$(IFS=','; echo "${vps_list[*]}")
            fi
            
            echo ""
            if make_public "$selected_service" "$selected_domains" "$selected_vps"; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ Service is Now Public"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                
                IFS=',' read -ra DOMAINS <<< "$selected_domains"
                for domain in "${DOMAINS[@]}"; do
                    domain=$(echo "$domain" | xargs)
                    echo "  • https://$domain"
                done
                echo ""
                
                log_info "SSL certificates will be automatically obtained"
            else
                log_error "Failed to make service public"
                exit 1
            fi
            ;;
            
        2)
            # Make private
            if [ "$current_status" = "false" ]; then
                log_info "Service is already private"
                exit 0
            fi
            
            echo ""
            log_warn "This will make '$selected_service' accessible only via local network"
            read -p "Continue? (y/n): " confirm
            [ "$confirm" != "y" ] && exit 0
            
            echo ""
            local private_rc=0
            make_private "$selected_service" || private_rc=$?
            if [ "$private_rc" -eq 0 ]; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ Service is Now Private"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  • http://$local_name.${CLUSTER_DOMAIN}.local (local access only)"
                echo ""
            elif [ "$private_rc" -eq "$EXIT_NOT_VERIFIED" ]; then
                log_error "Marked private, but removal from the VPS is not verified (see above)"
                exit "$EXIT_NOT_VERIFIED"
            else
                log_error "Failed to make service private"
                exit 1
            fi
            ;;

        *)
            log_info "Cancelled"
            exit 0
            ;;
    esac
}

# Run main if no arguments, otherwise support command-line mode
CLI_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--allow-infrastructure" ]]; then
        ALLOW_INFRASTRUCTURE=1
    else
        CLI_ARGS+=("$arg")
    fi
done
set -- ${CLI_ARGS[@]+"${CLI_ARGS[@]}"}

if [ $# -eq 0 ]; then
    main
else
    case "${1:-}" in
        public)
            verify_cluster_access || exit 1
            verify_service_exists "${2:-}" || exit 1
            make_public "$RESOLVED_SERVICE" "${3:-}" "${4:-}"
            ;;
        private)
            verify_cluster_access || exit 1
            verify_service_exists "${2:-}" || exit 1
            private_rc=0
            make_private "$RESOLVED_SERVICE" || private_rc=$?
            exit "$private_rc"
            ;;
        *)
            echo "Usage: $0 [public|private] <service-name> [domains] [vps-nodes]"
            echo ""
            echo "Interactive mode:"
            echo "  $0"
            echo ""
            echo "Command-line mode:"
            echo "  $0 public immich"
            echo "  $0 public immich 'example.com,test.org' '100.68.225.92'"
            echo "  $0 public grafana 'grafana.example.com' '100.68.225.92' --allow-infrastructure"
            echo "  $0 private immich"
            echo ""
            echo "  'private' exits $EXIT_NOT_VERIFIED if the registry changed but the route could not"
            echo "  be confirmed gone from a VPS."
            exit 1
            ;;
    esac
fi
