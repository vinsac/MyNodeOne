#!/bin/bash

###############################################################################
# Central Service Registry
#
# Manages a centralized registry of all services in Kubernetes.
# Single source of truth for DNS and routing configuration.
#
# Entries are keyed on namespace/service, the identity Kubernetes guarantees to
# be unique. A registry with the old bare-name keys keeps working: sync and register
# update those entries where they are. It is rewritten by the `migrate` command, run
# once after the config API has been upgraded; see sr_migrate_registry.
#
# An entry can set public_blocked_paths to a list of path prefixes the public
# route must not serve. See resolveBlockedPaths in cmd/config-api/main.go.
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=project-root.sh
source "$SCRIPT_DIR/project-root.sh" 2>/dev/null || source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null

# Source K8s utilities for robust KUBECONFIG detection
# shellcheck source=k8s-utils.sh
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"
# shellcheck source=service-registry-lib.sh
source "$SCRIPT_DIR/service-registry-lib.sh"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
}

SCHEMA_UPGRADE_HINT="Upgrade the config API first: sudo scripts/installation/install-config-api.sh"

# The control plane address lets a host without a local config API ask the real
# one whether it is ready for the migration.
load_user_config_value() {
    local actual_home="${HOME}" name="$1" line
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        actual_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    fi
    [[ -f "$actual_home/.mynodeone/config.env" ]] || return 0
    line=$(grep -E "^${name}=" "$actual_home/.mynodeone/config.env" | tail -n1) || true
    line="${line#*=}"
    line="${line%\"}"
    line="${line#\"}"
    line="${line%\'}"
    line="${line#\'}"
    printf '%s' "$line"
}

prepare_schema_gate() {
    if [[ -z "${CONTROL_PLANE_IP:-}" ]]; then
        CONTROL_PLANE_IP=$(load_user_config_value CONTROL_PLANE_IP)
    fi
    if [[ -n "${MYNODEONE_REGISTRY_ALLOW_BLANK:-}" ]]; then
        export SR_ALLOW_BLANK="$MYNODEONE_REGISTRY_ALLOW_BLANK"
    fi
}

# Initialize registry configmap if it doesn't exist
init_registry() {
    local rc=0
    sr_read_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" || rc=$?
    case "$rc" in
        2)
            log_info "Creating service registry..."
            kubectl create configmap "$SR_SERVICE_CM" \
                -n "$SR_NAMESPACE" \
                --from-literal="$SR_SERVICE_KEY={}"
            log_success "Service registry created"
            ;;
        1)
            log_error "Could not read $SR_SERVICE_CM"
            return 1
            ;;
    esac
    return 0
}

# Merge into the entry so fields this function does not manage survive, such as
# public_blocked_paths. Public is sticky: installers re-register with "false"
# and that must not unpublish a live route. make_private is the way to do that.
# An existing legacy_key stays: routing.json can be filed under it. A registry that is
# not migrated yet has the entry under its bare key, so that is the one to update.
register_filter() {
    jq -c \
        --arg key "$1" \
        --arg legacy "$2" \
        --arg local_name "$3" \
        --arg namespace "$4" \
        --arg service "$5" \
        --arg ip "$6" \
        --arg port "$7" \
        --arg public "$8" \
        "$SR_JQ_TARGET"'
        def apply: . + {
                local_name: $local_name,
                namespace: $namespace,
                service: $service,
                ip: $ip,
                port: ($port | tonumber),
                updated: (now | todate)
            } | .public = ((.public == true) or ($public == "true"));
        . as $all
        | [keys[] | select((is_namespaced | not) and (($all[.] | type) == "object") and target(.; $all[.]) == $key)] as $bare
        | if ($bare | length) > 0 then
              reduce ($bare[]) as $b (.; .[$b] |= apply)
              | if has($key) then .[$key] |= apply else . end
          else
              .[$key] = ((.[$key] // {}) | apply | .legacy_key = (.legacy_key // $legacy))
          end'
}

# Register a new service in the registry
# Usage: register_service <name> <local_name> <namespace> <service> <port> <public>
register_service() {
    if [[ $# -lt 5 ]]; then
        log_error "Usage: register <name> <local_name> <namespace> <service> <port> [public]"
        return 1
    fi
    local name="$1"
    local local_name="$2"
    local namespace="$3"
    local service="$4"
    local port="$5"
    local public="${6:-false}"

    if ! sr_valid_k8s_name "$namespace" || ! sr_valid_k8s_name "$service"; then
        log_error "Invalid namespace or service name: $namespace/$service"
        return 1
    fi
    if ! sr_valid_port "$port"; then
        log_error "Invalid port for $namespace/$service: $port"
        return 1
    fi
    # Blank means the bare cluster domain.
    if [[ -n "$local_name" ]] && ! sr_valid_local_name "$local_name"; then
        log_error "Invalid local name for $namespace/$service: $local_name"
        return 1
    fi

    init_registry

    local rc=0
    sr_ensure_schema || rc=$?
    if [[ "$rc" -eq 3 ]]; then
        log_error "Cannot register $name yet. $SCHEMA_UPGRADE_HINT"
        return 1
    elif [[ "$rc" -ne 0 && "$rc" -ne 4 ]]; then
        log_error "Cannot register $name: registry unavailable"
        return 1
    fi

    log_info "Registering service: $namespace/$service"

    # Get LoadBalancer IP
    local ip
    ip=$(kubectl get svc -n "$namespace" "$service" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

    if [[ -z "$ip" ]]; then
        log_error "Could not get LoadBalancer IP for $service"
        return 1
    fi
    if ! sr_valid_ip "$ip"; then
        log_error "LoadBalancer IP for $service is not a valid address"
        return 1
    fi

    local key="$namespace/$service"
    if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" \
        register_filter "$key" "$name" "$local_name" "$namespace" "$service" "$ip" "$port" "$public"; then
        log_error "Failed to update service registry"
        return 1
    fi

    if [[ "$public" != "true" ]] && [[ "$(sr_get_services | jq -r --arg ns "$namespace" --arg svc "$service" \
        'any(.[]; type == "object" and .namespace == $ns and .service == $svc and .public == true)')" == "true" ]]; then
        log_warn "$key stays public. Use manage-app-visibility.sh private to change that"
    fi

    log_success "Registered: $local_name → $ip"
    return 0
}

# Get all services from registry
get_all_services() {
    sr_get_services
}

# Get specific service from registry by key or bare name
get_service() {
    local name="${1:-}" services key
    services=$(sr_get_services) || return 1
    key=$(sr_resolve_key "$services" "$name") || return 1
    jq --arg k "$key" '.[$k]' <<<"$services"
}

# Print the registry key for a bare name or key
resolve_service() {
    local services
    services=$(sr_get_services) || return 1
    sr_resolve_key "$services" "${1:-}"
}

show_registry() {
    sr_get_services | jq .
}

unregister_filter() {
    jq -c --arg k "$1" 'del(.[$k])'
}

# Remove an entry. Removing one that is not there is not an error.
unregister_service() {
    local name="${1:-}" services key rc=0
    if [[ -z "$name" ]]; then
        log_error "Usage: unregister <name-or-namespace/name>"
        return 1
    fi
    services=$(sr_get_services) || return 1
    key=$(sr_resolve_key "$services" "$name") || rc=$?
    case "$rc" in
        0) ;;
        1)
            log_info "$name is not registered"
            return 0
            ;;
        *) return 1 ;;
    esac
    if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" unregister_filter "$key"; then
        log_error "Failed to update service registry"
        return 1
    fi
    log_success "Unregistered: $key"
}

# The one-time rewrite to namespace/name keys, for after the config API upgrade. It also
# opts in to a later sync migrating entries an old client writes back in the old format.
migrate_registry() {
    local rc=0
    sr_migrate_registry || rc=$?
    case "$rc" in
        0)
            log_success "Registry uses namespace/name keys"
            ;;
        3)
            log_error "$SCHEMA_UPGRADE_HINT"
            return 1
            ;;
        *)
            log_error "Migration failed; the registry was not changed"
            return 1
            ;;
    esac
}

# The friendly DNS label for a Service with no usable annotation.
default_local_name() {
    local name="$1"
    case "$name" in
        dashboard) echo "dashboard" ;;
        open-webui) echo "chat" ;;
        demo) echo "demo" ;;
        demo-chat-app) echo "demo-chat" ;;
        argocd-server) echo "argocd" ;;
        kube-prometheus-stack-grafana) echo "grafana" ;;
        minio-console-* | minio-*) echo "$name" ;;
        longhorn-frontend) echo "longhorn" ;;
        # Manager API; distinct so it does not collide with longhorn-frontend
        longhorn) echo "longhorn-api" ;;
        traefik) echo "traefik" ;;
        *-server) echo "${name%-server}" ;;
        *-frontend) echo "${name%-frontend}" ;;
        *) echo "$name" ;;
    esac
}

# Applies a discovery result to the registry. An entry whose Service is gone from
# a successful cluster-wide list is removed; anything else is kept. An existing
# legacy_key stays: routing.json can be filed under it. An entry still under its bare
# key is updated there, because only the `migrate` command changes keys.
sync_filter() {
    jq -c --argjson found "$1" --argjson existing "$2" "$SR_JQ_TARGET"'
        (to_entries | map(
            select(.key as $k | .value as $v
                | ($found | has($k))
                  or (($v | type) != "object")
                  or (($v.namespace // "") == "")
                  or (($v.service // "") == "")
                  or (($existing | index("\($v.namespace)/\($v.service)")) != null))
        ) | from_entries) as $kept
        | reduce ($found | to_entries[]) as $e ($kept;
            . as $reg
            | [$reg | keys[] | select((is_namespaced | not) and (($reg[.] | type) == "object")
                                      and target(.; $reg[.]) == $e.key)] as $bare
            | (if ($bare | length) == 0 or has($e.key) then $bare + [$e.key] else $bare end) as $targets
            | reduce ($targets[]) as $t (.;
                (.[$t] // {}) as $prev
                | .[$t] = ($prev + ($e.value | del(.legacy_key))
                           | .public = (.public == true)
                           | .updated = (now | todate))
                | if $prev.legacy_key == null and ($t == $e.key) and ($e.value | has("legacy_key"))
                  then .[$t].legacy_key = $e.value.legacy_key else . end))'
}

# Sync registry with actual cluster state
# Discovers all LoadBalancer services and updates registry
sync_registry() {
    log_info "Syncing service registry with cluster state..."

    init_registry

    local rc=0
    sr_ensure_schema || rc=$?
    if [[ "$rc" -eq 3 ]]; then
        log_warn "Skipping registry sync until the config API is upgraded. $SCHEMA_UPGRADE_HINT"
        return 0
    elif [[ "$rc" -eq 4 ]]; then
        log_warn "Registry still has bare keys; updating them in place. Once the config API is upgraded, run: service-registry.sh migrate"
    elif [[ "$rc" -ne 0 ]]; then
        log_error "Registry unavailable; sync aborted and nothing changed"
        return 1
    fi

    # A failed list must never look like "no services", or every entry would be
    # treated as stale. A working cluster always has at least one Service.
    local svc_json
    if ! svc_json=$(kubectl get svc --all-namespaces -o json 2>/dev/null); then
        log_error "Could not list Services; sync aborted and nothing changed"
        return 1
    fi
    if ! jq -e '(.items | type) == "array" and (.items | length) > 0' <<<"$svc_json" >/dev/null 2>&1; then
        log_error "Service list was empty or malformed; sync aborted and nothing changed"
        return 1
    fi

    local cluster_domain
    cluster_domain=$(kubectl get configmap -n kube-system cluster-info \
        -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
    if ! sr_valid_cluster_domain "$cluster_domain"; then
        cluster_domain="mynodeone"
    fi

    local found='{}' count=0 skipped=0
    local namespace name ip port annotation entry_b64 entry
    while IFS= read -r entry_b64; do
        [[ -n "$entry_b64" ]] || continue
        entry=$(base64 -d <<<"$entry_b64")
        namespace=$(jq -r '.namespace' <<<"$entry")
        name=$(jq -r '.name' <<<"$entry")
        ip=$(jq -r '.ip' <<<"$entry")
        port=$(jq -r '.port' <<<"$entry")
        annotation=$(jq -r '.annotation' <<<"$entry")

        if ! sr_valid_k8s_name "$namespace" || ! sr_valid_k8s_name "$name"; then
            log_warn "Skipping Service with an unexpected name"
            skipped=$((skipped + 1))
            continue
        fi
        if ! sr_valid_ip "$ip" || ! sr_valid_port "$port"; then
            log_warn "Skipping $namespace/$name: invalid IP or port"
            skipped=$((skipped + 1))
            continue
        fi

        # MinIO Services were renamed after their namespace, so legacy_key keeps the
        # name older tooling knew them by. Any other Service already goes by its own
        # name, and legacy_key is otherwise only set by migrate and register.
        local legacy="$name"
        case "$name" in
            minio-console) legacy="minio-console-${namespace#minio-}" ;;
            minio) legacy="minio-${namespace#minio-}" ;;
        esac

        local local_name=""
        if [[ -n "$annotation" ]]; then
            if sr_valid_local_name "$annotation"; then
                local_name="$annotation"
            else
                # Annotations are data written by whoever can edit the Service.
                log_warn "Ignoring invalid subdomain annotation on $namespace/$name"
            fi
        fi
        if [[ -z "$local_name" ]]; then
            local_name=$(default_local_name "$legacy")
        fi
        if ! sr_valid_local_name "$local_name"; then
            log_warn "Skipping $namespace/$name: no valid DNS name"
            skipped=$((skipped + 1))
            continue
        fi

        found=$(jq -c \
            --arg key "$namespace/$name" \
            --arg local_name "$local_name" \
            --arg namespace "$namespace" \
            --arg service "$name" \
            --arg ip "$ip" \
            --arg port "$port" \
            --arg legacy "$legacy" \
            '.[$key] = ({
                local_name: $local_name,
                namespace: $namespace,
                service: $service,
                ip: $ip,
                port: ($port | tonumber)
            } + (if $legacy != $service then {legacy_key: $legacy} else {} end))' <<<"$found")
        count=$((count + 1))
    done < <(jq -r --arg ann "${cluster_domain}.local/subdomain" '
        .items[]
        | select(.spec.type == "LoadBalancer")
        | select(.status.loadBalancer.ingress[0].ip? != null)
        | {
            name: .metadata.name,
            namespace: .metadata.namespace,
            ip: .status.loadBalancer.ingress[0].ip,
            port: .spec.ports[0].port,
            annotation: (.metadata.annotations[$ann]? // .metadata.annotations["mynodeone.io/subdomain"]? // "")
          }
        | @base64' <<<"$svc_json")

    log_info "Found $count LoadBalancer services"

    local existing
    existing=$(jq -c '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"]' <<<"$svc_json")

    local before="" after=""
    before=$(sr_get_services) || return 1
    if ! sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" sync_filter "$found" "$existing"; then
        log_error "Failed to update service registry"
        return 1
    fi
    after=$(sr_get_services) || return 1

    local removed
    removed=$(jq -nr --argjson before "$before" --argjson after "$after" \
        '$before | to_entries[] | select(.key as $k | $after | has($k) | not)
         | "\(.key)\(if .value.public == true then " (was public)" else "" end)"')
    if [[ -n "$removed" ]]; then
        while IFS= read -r line; do
            log_warn "Removed stale entry, its Service no longer exists: $line"
        done <<<"$removed"
    fi

    log_success "Synced $count services"
    if [[ $skipped -gt 0 ]]; then
        log_info "Skipped: $skipped services"
    fi
    return 0
}

# Export registry to DNS format for /etc/hosts
export_dns() {
    # Try to get domain from config if not provided
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        local cluster_domain
        cluster_domain=$(load_user_config_value CLUSTER_DOMAIN)
        domain="${cluster_domain:-mynodeone}.local"
    fi
    if ! sr_valid_cluster_domain "$domain"; then
        log_error "Invalid domain: $domain"
        return 1
    fi

    local services
    services=$(get_all_services) || return 1

    if [[ "$services" == "{}" ]]; then
        return 0
    fi

    echo "# MyNodeOne Services - Auto-generated on $(date)"
    # Only validated names and addresses reach the output, which ends up in
    # /etc/hosts. A bad value could otherwise add lines of its own.
    jq -r --arg domain "$domain" '
        def valid_ip:
            type == "string" and (
                test("\\A((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\z")
                or (test("\\A[0-9A-Fa-f:.]{2,45}\\z") and contains(":")));
        def valid_name:
            type == "string"
            and test("\\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\z")
            and ((ascii_downcase | IN("localhost", "localhost4", "localhost6", "broadcasthost",
                 "ip6-localhost", "ip6-loopback", "ip6-allnodes", "ip6-allrouters",
                 "ip6-localnet", "ip6-mcastprefix")) | not);
        to_entries | sort_by(.key)[]
        | select(.value | type == "object")
        | select(.value.ip | valid_ip)
        | if .value.local_name == "" then
            "\(.value.ip)\t\($domain)"
          elif (.value.local_name | valid_name) | not then
            empty
          elif .value.local_name == "dashboard" then
            "\(.value.ip)\t\(.value.local_name).\($domain)\n\(.value.ip)\t\($domain)"
          else
            "\(.value.ip)\t\(.value.local_name).\($domain)"
          end
    ' <<<"$services"
}

usage() {
    cat << 'EOF'
Service Registry - Clean Separation Architecture

Usage:
  service-registry.sh <command> [options]

Commands:
  init                          Initialize service registry ConfigMap
  register <name> <local_name> <namespace> <service> <port> <public>
                               Register a new service (key: namespace/service)
  unregister <name-or-key>     Remove a service
  sync                         Sync registry with cluster state (discovers LoadBalancer services)
  export-dns [domain]          Export DNS entries for /etc/hosts (uses local_name)
  show                         Show all registered services
  get <name-or-key>            Show one service
  resolve <name-or-key>        Print the namespace/name key for a bare name
  migrate                      Convert bare keys to namespace/name now

Notes:
  - local_name drives .local DNS only (e.g., chat -> chat.mynodeone.local)
  - Public routing is managed separately via domain-registry / manage-app-visibility.sh
  - Dashboard service gets both dashboard.DOMAIN and bare DOMAIN entries
  - A public flag is only cleared by manage-app-visibility.sh private

Environment:
  MYNODEONE_REGISTRY_FORCE_MIGRATE=1  Migrate without checking the config API version
  MYNODEONE_REGISTRY_ALLOW_BLANK=1    Treat a blank services.json as empty (repair only)

Examples:
  service-registry.sh sync                          # Discover and register all services
  service-registry.sh export-dns                    # Uses CLUSTER_DOMAIN from config
  service-registry.sh export-dns mynodeone.local    # Explicit domain
  service-registry.sh show                          # Display registry contents

EOF
}

main() {
    export_k8s_config || true
    prepare_schema_gate

    case "${1:-}" in
        init)
            init_registry
            ;;
        register)
            shift
            register_service "$@"
            ;;
        unregister)
            unregister_service "${2:-}"
            ;;
        sync)
            sync_registry
            ;;
        export-dns)
            export_dns "${2:-}"
            ;;
        show)
            show_registry
            ;;
        get)
            get_service "${2:-}"
            ;;
        resolve)
            resolve_service "${2:-}"
            ;;
        migrate)
            migrate_registry
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
