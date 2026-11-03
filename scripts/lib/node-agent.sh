#!/bin/bash

###############################################################################
# MyNodeOne Node Agent
#
# A lightweight agent that runs on each node (laptop, VPS, worker) to:
# 1. Poll the control plane for config updates
# 2. Send heartbeat to report node status
# 3. Apply config changes locally
#
# This replaces the SSH-based push model with a pull-based approach.
#
# It is installed on its own as /usr/local/bin/mynodeone-node-agent, so it must
# not depend on any other file in this repository.
#
# What the server's answer means:
#   routes / dns_entries is a list   The server read its data. Apply the list,
#                                    even an empty one (that removes things).
#   the field is missing             Keep what is installed. Older config APIs
#                                    leave it out on empty AND on read failures,
#                                    so a missing field proves nothing.
#   an error or non-JSON answer      Keep what is installed and try again.
###############################################################################

set -euo pipefail

# Colors for logging
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Logs go to stderr: fetch_config's stdout is the data its callers capture.
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

# apply_* return codes.
APPLY_OK=0
APPLY_FAILED=1
APPLY_KEPT=2 # nothing to do yet; don't record the version as applied
APPLY_DETACHED=3 # /etc/hosts was renamed over; only a restart makes it writable again

# Reads CLUSTER_DOMAIN out of a user's config.env. These files belong to
# ordinary users and the agent runs as root, so they are parsed, never sourced.
detect_cluster_domain() {
    local user_config value candidates=()
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        candidates+=("/home/$SUDO_USER/.mynodeone/config.env")
    fi
    candidates+=(/home/*/.mynodeone/config.env /root/.mynodeone/config.env)
    for user_config in "${candidates[@]}"; do
        [[ -f "$user_config" ]] || continue
        value=$(grep '^CLUSTER_DOMAIN=' "$user_config" 2>/dev/null | head -n1 | cut -d'=' -f2 | tr -d "\"'") || value=""
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 0
}

# Load configuration
load_config() {
    local config_file="${AGENT_CONFIG_FILE:-/etc/mynodeone/agent.env}"

    if [[ -f "$config_file" ]]; then
        # shellcheck disable=SC1090
        source "$config_file"
        log_info "Loaded config from $config_file"
    else
        log_warn "Config file not found: $config_file"
    fi

    # Set defaults
    CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
    NODE_NAME="${NODE_NAME:-$(hostname)}"
    NODE_TYPE="${NODE_TYPE:-laptop}"
    POLL_INTERVAL="${POLL_INTERVAL:-60}"
    HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"
    API_PORT="${API_PORT:-8443}"
    API_TOKEN="${API_TOKEN:-}"
    FETCH_RETRY_DELAY="${FETCH_RETRY_DELAY:-5}"

    # Defensive: Try to load CLUSTER_DOMAIN from user config if not set in agent.env
    if [[ -z "${CLUSTER_DOMAIN:-}" ]]; then
        local detected_domain
        detected_domain=$(detect_cluster_domain)
        if [[ -n "$detected_domain" ]]; then
            CLUSTER_DOMAIN="$detected_domain"
            log_info "Loaded CLUSTER_DOMAIN from user config: $CLUSTER_DOMAIN"
        fi
    fi

    # Final fallback
    CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}" # Used for DNS entries (e.g., dashboard.{domain}.local)
    if [[ ! "$CLUSTER_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
        log_error "CLUSTER_DOMAIN is not a valid domain name"
        exit 1
    fi

    # Paths are overridable so tests never touch the real ones.
    HOSTS_FILE="${AGENT_HOSTS_FILE:-/etc/hosts}"
    HOSTS_BACKUP="${AGENT_HOSTS_BACKUP:-/etc/mynodeone/hosts.bak}"

    # Load state (last applied version)
    STATE_FILE="${AGENT_STATE_FILE:-/etc/mynodeone/.agent.state}"
    if [[ -f "$STATE_FILE" ]]; then
        CURRENT_CONFIG_VERSION=$(grep "^VERSION=" "$STATE_FILE" | cut -d'=' -f2 || echo "")
        export CURRENT_CONFIG_VERSION
    fi

    # Validate required config
    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        log_error "CONTROL_PLANE_IP is required"
        exit 1
    fi
}

# Run a command as root, using sudo only when not already root.
as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Build API URL
get_api_url() {
    local endpoint="$1"
    echo "http://${CONTROL_PLANE_IP}:${API_PORT}${endpoint}"
}

# curl with the API token, which goes through a config stream instead of argv so
# it does not show up in `ps`. printf is a builtin, so it isn't exposed there.
api_curl() {
    if [[ -n "$API_TOKEN" ]]; then
        local escaped="${API_TOKEN//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        curl -K <(printf 'header = "X-API-Token: %s"\n' "$escaped") "$@"
    else
        curl "$@"
    fi
}

# Fetch config from control plane (with retry and backoff)
fetch_config() {
    local url
    url=$(get_api_url "/api/v1/config/${NODE_TYPE}")

    local max_attempts=3
    local attempt=1
    local delay="$FETCH_RETRY_DELAY"

    while [ "$attempt" -le "$max_attempts" ]; do
        local response="" http_code=""

        response=$(api_curl -s -w "\n%{http_code}" \
            --connect-timeout 10 --max-time 30 \
            -H "X-Node-Name: $NODE_NAME" \
            "$url" 2>/dev/null) || true

        # Extract HTTP code (last line)
        http_code=$(tail -n1 <<<"$response")
        response=$(sed '$d' <<<"$response")

        if [[ "$http_code" == "200" ]]; then
            # A 200 only counts if it really is a config document.
            if jq -e 'type == "object" and (.version | type) == "string"' <<<"$response" &>/dev/null; then
                printf '%s\n' "$response"
                return 0
            fi
            log_warn "Invalid response from API (attempt $attempt/$max_attempts)"
        else
            log_warn "Failed to fetch config: HTTP ${http_code:-none} (attempt $attempt/$max_attempts)"
            if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
                log_warn "Check API_TOKEN in ${AGENT_CONFIG_FILE:-/etc/mynodeone/agent.env}"
            fi
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "Failed to fetch config after $max_attempts attempts"
    return 1
}

# Get Tailscale IP
get_tailscale_ip() {
    local ip
    ip=$(tailscale ip -4 2>/dev/null | head -n1) || ip=""
    printf '%s\n' "${ip:-unknown}"
}

# Send heartbeat to control plane
send_heartbeat() {
    local url
    url=$(get_api_url "/api/v1/heartbeat")

    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")

    local payload
    payload=$(jq -cn \
        --arg node_name "$NODE_NAME" \
        --arg node_type "$NODE_TYPE" \
        --arg node_ip "$(get_tailscale_ip)" \
        --arg config_version "${CURRENT_CONFIG_VERSION:-unknown}" \
        --argjson uptime_seconds "${uptime_seconds:-0}" \
        '{node_name: $node_name, node_type: $node_type, node_ip: $node_ip,
          config_version: $config_version, uptime_seconds: $uptime_seconds}')

    local http_code
    http_code=$(api_curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 30 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url" 2>/dev/null) || true

    if [[ "$http_code" == "200" ]]; then
        log_success "Heartbeat sent"
        return 0
    fi
    log_warn "Heartbeat failed: HTTP ${http_code:-none}"
    return 1
}

# Hostnames and addresses come from cluster data that ends up in /etc/hosts. Only
# single DNS labels and real addresses get through, so a value cannot add a line
# of its own or claim a name like localhost. The Go side and sync-dns.sh apply
# the same rules; this copy is here because the agent stands alone.
JQ_HOSTS_VALIDATORS='
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
'

# The timer's sync-dns.sh owns /etc/hosts where it runs (the control plane, which
# has kubectl). Two writers would keep replacing each other's blocks. An enabled timer
# that is stopped, say for maintenance, still owns it. Same rule as sr_hosts_writer.
dns_owned_by_timer() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet mynodeone-local-dns-sync.timer 2>/dev/null ||
        systemctl is-active --quiet mynodeone-local-dns-sync.timer 2>/dev/null
}

# The unit's ProtectSystem=strict makes /etc read-only and ReadWritePaths bind-mounts
# /etc/hosts into this service's mount namespace. If anything outside renames another
# file over /etc/hosts (sed -i, many editors), that mount goes away here, and every
# write fails with EROFS until the service gets a new namespace. Only checked after a
# write fails, and only under systemd, where the file is always a mount point otherwise.
hosts_mount_detached() {
    [[ -n "${INVOCATION_ID:-}" ]] || return 1
    command -v mountpoint >/dev/null 2>&1 || return 1
    ! mountpoint -q "$HOSTS_FILE"
}

# Writes a file over the hosts file in place. Under ProtectSystem=strict
# /etc/hosts is a bind mount, so rename or unlink over it fails with EBUSY while
# writing to the open file works. Nothing that replaces the inode can be used here.
write_hosts_in_place() {
    local new_file="$1"
    if [[ "$(id -u)" -eq 0 ]]; then
        cat "$new_file" >"$HOSTS_FILE"
    else
        sudo tee "$HOSTS_FILE" <"$new_file" >/dev/null
    fi
}

# Apply DNS config (for laptops and workers)
apply_dns_config() {
    local config="$1"

    if dns_owned_by_timer; then
        log_info "mynodeone-local-dns-sync.timer manages $HOSTS_FILE on this node; leaving it alone"
        return "$APPLY_OK"
    fi

    if ! jq -e '(.dns_entries | type) == "array"' <<<"$config" &>/dev/null; then
        log_info "Response has no dns_entries list; keeping current DNS entries"
        return "$APPLY_KEPT"
    fi

    local domain="${CLUSTER_DOMAIN}.local"
    local entries sent_count
    log_info "Extracting DNS entries for domain: $domain"
    sent_count=$(jq -r '.dns_entries | length' <<<"$config")
    if ! entries=$(jq -r --arg domain "$domain" "$JQ_HOSTS_VALIDATORS"'
        .dns_entries[]
        | select(type == "object" and (.ip | valid_ip))
        | if .name == "" then
            "\(.ip) \($domain)"
          elif (.name | valid_name) then
            "\(.ip) \(.name).\($domain) \(.name)"
          else
            empty
          end' <<<"$config"); then
        log_error "Could not parse DNS entries; keeping current ones"
        return "$APPLY_FAILED"
    fi

    local count=0
    if [[ -n "$entries" ]]; then
        count=$(grep -c '' <<<"$entries")
    fi
    if ((count < sent_count)); then
        log_warn "Ignored $((sent_count - count)) invalid DNS entries from the server"
    fi
    # Something was sent but none of it was usable. That isn't "there are none".
    if ((sent_count > 0 && count == 0)); then
        log_error "No usable DNS entries in the response; keeping current ones"
        return "$APPLY_FAILED"
    fi

    local temp_file old_copy
    temp_file=$(mktemp) || return "$APPLY_FAILED"
    old_copy=$(mktemp) || {
        rm -f "$temp_file"
        return "$APPLY_FAILED"
    }
    # shellcheck disable=SC2064  # expand now: the locals are gone when RETURN fires
    trap "rm -f '$temp_file' '$old_copy'; trap - RETURN" RETURN

    if ! cp "$HOSTS_FILE" "$old_copy"; then
        log_error "Could not read $HOSTS_FILE"
        return "$APPLY_FAILED"
    fi

    # Keep every line except our own markers and names under the cluster domain. A
    # marker is a whole comment line, so one quoted at the end of another line is not
    # one. Our own block goes whole, since its lines also carry the short name. Anywhere
    # else only the matching name goes, and a comment after the names is not a name.
    # awk compares strings so the domain is never read as a regex. Trailing blank
    # lines are dropped so repeated runs don't grow the file.
    if ! CLUSTER_HOSTS_DOMAIN="$domain" awk '
        function managed(name) {
            return name == domain ||
                (length(name) > length(suffix) && substr(name, length(name) - length(suffix) + 1) == suffix)
        }
        BEGIN { domain = ENVIRON["CLUSTER_HOSTS_DOMAIN"]; suffix = "." domain; blanks = 0; in_block = 0 }
        /^[[:space:]]*# MyNodeOne (Services|services|Apps|DNS entries)([[:space:]]+[-(].*)?[[:space:]]*$/ {
            in_block = ($0 ~ /DNS entries/)
            next
        }
        in_block {
            if (NF >= 2 && $1 !~ /^#/ && managed($2)) next
            in_block = 0
        }
        !/^[[:space:]]*(#|$)/ {
            kept = ""; removed = 0; stop = NF + 1
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^#/) { stop = i; break }
                if (managed($i)) removed = 1
                else kept = kept " " $i
            }
            if (removed) {
                if (kept == "") next
                note = ""
                for (i = stop; i <= NF; i++) note = note " " $i
                $0 = $1 kept note
            }
        }
        /^[[:space:]]*$/ { blanks++; next }
        { for (; blanks > 0; blanks--) print ""; print }
    ' "$old_copy" >"$temp_file"; then
        log_error "Could not process $HOSTS_FILE"
        return "$APPLY_FAILED"
    fi

    if ((count > 0)); then
        {
            echo ""
            echo "# MyNodeOne DNS entries (managed by node-agent)"
            printf '%s\n' "$entries"
        } >>"$temp_file"
    fi

    if cmp -s "$temp_file" "$old_copy"; then
        log_info "$HOSTS_FILE is already up to date ($count DNS entries)"
        return "$APPLY_OK"
    fi

    # One pristine backup. A failure here is not worth skipping the update for.
    if [[ ! -f "$HOSTS_BACKUP" ]]; then
        if as_root cp "$old_copy" "$HOSTS_BACKUP" 2>/dev/null; then
            log_info "Created backup: $HOSTS_BACKUP"
        else
            log_warn "Could not create backup: $HOSTS_BACKUP"
        fi
    fi

    log_info "Writing updated $HOSTS_FILE"
    if ! write_hosts_in_place "$temp_file" 2>/dev/null; then
        log_error "Could not write $HOSTS_FILE"
        # The write may have truncated the file before it failed.
        if ! cmp -s "$HOSTS_FILE" "$old_copy"; then
            write_hosts_in_place "$old_copy" 2>/dev/null ||
                log_error "Could not restore $HOSTS_FILE; a copy is in $HOSTS_BACKUP"
        fi
        if hosts_mount_detached; then
            log_error "$HOSTS_FILE was replaced by a rename and is no longer writable from this service"
            return "$APPLY_DETACHED"
        fi
        return "$APPLY_FAILED"
    fi

    if ! cmp -s "$temp_file" "$HOSTS_FILE"; then
        log_error "$HOSTS_FILE does not contain what was written"
        return "$APPLY_FAILED"
    fi

    # In-place writes keep the existing mode, so this only repairs a bad one.
    local perms
    perms=$(stat -c "%a" "$HOSTS_FILE" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "644" ]]; then
        log_warn "$HOSTS_FILE has permissions $perms, forcing to 644"
        as_root chmod 644 "$HOSTS_FILE" || log_warn "Could not change permissions on $HOSTS_FILE"
    fi

    log_success "Applied $count DNS entries to $HOSTS_FILE"
    return "$APPLY_OK"
}

# Find the Traefik config directory: TRAEFIK_CONFIG_DIR from agent.env (written by
# the installer), otherwise the conventional location already holding the routes file,
# otherwise the first that exists.
find_traefik_config_dir() {
    if [[ -n "${TRAEFIK_CONFIG_DIR:-}" ]]; then
        printf '%s\n' "$TRAEFIK_CONFIG_DIR"
        return 0
    fi

    local dir search_dirs=()
    [[ -n "${SUDO_USER:-}" ]] && search_dirs+=("/home/$SUDO_USER/traefik/config")
    [[ -n "${HOME:-}" ]] && search_dirs+=("$HOME/traefik/config")
    search_dirs+=(/home/*/traefik/config /root/traefik/config /etc/traefik/config)

    for dir in "${search_dirs[@]}"; do
        if [[ -f "$dir/mynodeone-routes.yml" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    printf '%s\n' /etc/traefik/config
}

# Does every router in this file point at a service that is defined in it with a
# backend? A body cut off part way can still be good YAML with a top-level http key,
# and Traefik answers 404 for routers whose service is missing. Written in awk, going by
# indentation alone, because the agent can't count on a YAML parser being installed.
routers_have_services() {
    awk '
        function indent_of(text) { match(text, /^ */); return RLENGTH }
        function bare(text) { gsub(/["'"'"':]/, "", text); return text }
        /^[[:space:]]*(#|$)/ { next }
        /^[^ ]/ { in_http = ($1 == "http:"); section = ""; next }
        !in_http { next }
        {
            indent = indent_of($0)
            if (!section_indent) section_indent = indent
            if (indent == section_indent) {
                section = bare($1); name_indent = 0; field_indent = 0; current = ""
                next
            }
            if (section != "routers" && section != "services") next
            if (!name_indent) name_indent = indent
            if (indent == name_indent) {
                current = bare($1); field_indent = 0
                if (section == "routers") routers[current] = ""
                else services[current] = 0
                next
            }
            if (section == "routers") {
                if (!field_indent) field_indent = indent
                if (indent == field_indent && $1 == "service:") routers[current] = bare($2)
            } else if ($1 == "url:" || ($1 == "-" && $2 == "url:")) {
                services[current] = 1
            }
        }
        END {
            for (name in routers) {
                target = routers[name]
                if (target == "") exit 1
                if (index(target, "@") > 0) continue
                if (!(target in services) || !services[target]) exit 1
            }
        }
    ' "$1"
}

# Could this file be what the Traefik file provider expects?
valid_traefik_yaml() {
    local file="$1"
    if ! grep -q '^http:' "$file"; then
        return 1
    fi
    if ! routers_have_services "$file"; then
        return 1
    fi
    if command -v python3 &>/dev/null && python3 -c 'import yaml' &>/dev/null; then
        python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$file" &>/dev/null
        return
    fi
    log_warn "No YAML parser available (python3-yaml), only checked the file's structure"
    return 0
}

# Apply Traefik routes (for VPS nodes)
# Fetches pre-rendered YAML from Config API
apply_vps_config() {
    local config="$1"

    if ! jq -e '(.routes | type) == "array"' <<<"$config" &>/dev/null; then
        log_info "Response has no routes list; keeping current routes"
        return "$APPLY_KEPT"
    fi

    local route_count
    route_count=$(jq -r '.routes | length' <<<"$config")

    local traefik_config_dir
    traefik_config_dir=$(find_traefik_config_dir)
    local routes_file="$traefik_config_dir/mynodeone-routes.yml"

    # Ensure directory exists
    if [[ ! -d "$traefik_config_dir" ]]; then
        mkdir -p "$traefik_config_dir" 2>/dev/null || true
        chmod 755 "$traefik_config_dir" 2>/dev/null || true
    fi

    if [[ ! -d "$traefik_config_dir" || ! -w "$traefik_config_dir" ]]; then
        log_error "Directory not writable: $traefik_config_dir. Current routes were kept."
        log_error "If the systemd sandbox is the cause, add it with: sudo systemctl edit mynodeone-node-agent, then [Service] ReadWritePaths=$traefik_config_dir"
        return "$APPLY_FAILED"
    fi

    # Traefik only loads .yml, .yaml and .toml, so it ignores this name.
    local routes_file_tmp
    if ! routes_file_tmp=$(mktemp "${routes_file}.tmp.XXXXXX"); then
        log_error "Could not create a temporary file in $traefik_config_dir"
        return "$APPLY_FAILED"
    fi
    # shellcheck disable=SC2064  # expand now: the local is gone when RETURN fires
    trap "rm -f '$routes_file_tmp'; trap - RETURN" RETURN

    # Fetch pre-rendered YAML from Config API
    log_info "Fetching Traefik config from API..."
    local url fetch_status="" fetch_rc=0
    url=$(get_api_url "/api/v1/config/vps/traefik-config")
    fetch_status=$(api_curl -s -w "%{http_code}" -o "$routes_file_tmp" \
        --connect-timeout 10 --max-time 30 \
        -H "X-Node-Name: $NODE_NAME" \
        "$url" 2>/dev/null) || fetch_rc=$?

    # A status of 200 only says how the response started. If the connection drops
    # part way curl still reports it, with a non-zero exit.
    if ((fetch_rc != 0)); then
        log_error "Fetching Traefik config did not complete (curl exit $fetch_rc, HTTP ${fetch_status:-none}). Current routes were kept."
        return "$APPLY_FAILED"
    fi

    if [[ "$fetch_status" != "200" ]]; then
        log_error "Failed to fetch Traefik config: HTTP ${fetch_status:-none}. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    if [[ ! -s "$routes_file_tmp" ]]; then
        log_error "Fetched routes file is empty. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    # Validate before applying (defensive: don't clobber good config with bad)
    if ! valid_traefik_yaml "$routes_file_tmp"; then
        log_error "Fetched routes file is not valid. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    # The two responses are separate requests, but if the JSON listed routes and
    # this YAML has none, something is wrong on the server.
    if ((route_count > 0)) && ! grep -qF 'Host(`' "$routes_file_tmp"; then
        log_error "Server listed $route_count routes but rendered none. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    # Nothing changed except the "Generated" stamp: leave Traefik's watcher alone.
    if [[ -f "$routes_file" ]] &&
        cmp -s <(grep -v '^# Generated:' "$routes_file") <(grep -v '^# Generated:' "$routes_file_tmp"); then
        log_info "Traefik routes already up to date: $routes_file ($route_count routes)"
        return "$APPLY_OK"
    fi

    # Backup existing routes before overwriting. Traefik ignores the .bak name.
    if [[ -f "$routes_file" ]]; then
        cp -p "$routes_file" "${routes_file}.bak" 2>/dev/null || log_warn "Could not back up $routes_file"
    fi

    # mktemp creates 600. Traefik may run as another user and must never see a
    # file it can't read, so fix this before the rename makes it visible.
    if ! chmod 644 "$routes_file_tmp"; then
        log_error "Could not set permissions on the routes file. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    local dir_owner dir_group
    dir_owner=$(stat -c '%U' "$traefik_config_dir" 2>/dev/null || echo "root")
    dir_group=$(stat -c '%G' "$traefik_config_dir" 2>/dev/null || echo "root")
    if [[ "$dir_owner" != "root" ]]; then
        chown "${dir_owner}:${dir_group}" "$routes_file_tmp" 2>/dev/null || true
    fi

    # Atomic move
    if ! mv -f "$routes_file_tmp" "$routes_file"; then
        log_error "Failed to write routes file: $routes_file. Current routes were kept."
        return "$APPLY_FAILED"
    fi

    if ((route_count == 0)); then
        log_success "Removed all public routes from $routes_file (server confirmed none)"
    else
        log_success "Updated Traefik routes: $routes_file ($route_count routes)"
    fi
    return "$APPLY_OK"
}

# Apply config based on node type
apply_config() {
    local config="$1"

    case "$NODE_TYPE" in
        laptop | worker)
            apply_dns_config "$config"
            ;;
        vps)
            apply_vps_config "$config"
            ;;
        *)
            log_error "Unknown node type: $NODE_TYPE"
            return "$APPLY_FAILED"
            ;;
    esac
}

# Record the applied version. The agent has done its work if this fails, so it
# warns and carries on; the file is only informational and is rewritten next time.
persist_state() {
    CURRENT_CONFIG_VERSION="$1"
    export CURRENT_CONFIG_VERSION
    if ! printf 'VERSION=%s\n' "$CURRENT_CONFIG_VERSION" >"$STATE_FILE" 2>/dev/null; then
        log_warn "Could not write state file: $STATE_FILE"
    fi
}

# Main agent loop
run_agent() {
    log_info "Starting MyNodeOne Node Agent"
    log_info "Node: $NODE_NAME ($NODE_TYPE)"
    log_info "Control Plane: $CONTROL_PLANE_IP:$API_PORT"
    log_info "Poll interval: ${POLL_INTERVAL}s"

    # Starting blank means each start re-applies the current config.
    local last_config_version=""
    local heartbeat_counter=0

    while true; do
        # Fetch config
        local config
        if config=$(fetch_config); then
            # Extract version
            local new_version
            new_version=$(jq -r '.version' <<<"$config")

            # Apply if changed. The version only moves on once it has been
            # applied, so a failed apply is retried on the next poll.
            if [[ -n "$new_version" && "$new_version" != "$last_config_version" ]]; then
                log_info "Config changed: ${last_config_version:-none} -> $new_version"
                local rc=0
                apply_config "$config" || rc=$?
                if [[ "$rc" -eq "$APPLY_OK" ]]; then
                    last_config_version="$new_version"
                    persist_state "$new_version"
                elif [[ "$rc" -eq "$APPLY_DETACHED" ]]; then
                    # Restart=always brings the service back in a new mount namespace.
                    log_error "Exiting so that systemd restarts the agent with $HOSTS_FILE writable again"
                    exit 1
                elif [[ "$rc" -ne "$APPLY_KEPT" ]]; then
                    log_error "Failed to apply config $new_version; will retry"
                fi
            fi
        fi

        # Send heartbeat
        heartbeat_counter=$((heartbeat_counter + POLL_INTERVAL))
        if [[ $heartbeat_counter -ge $HEARTBEAT_INTERVAL ]]; then
            send_heartbeat || true
            heartbeat_counter=0
        fi

        sleep "$POLL_INTERVAL"
    done
}

# One-time sync (for manual testing)
sync_once() {
    log_info "Running one-time sync"

    local config
    if ! config=$(fetch_config); then
        log_error "Sync failed"
        exit 1
    fi

    local new_version rc=0
    new_version=$(jq -r '.version' <<<"$config")
    apply_config "$config" || rc=$?

    if [[ "$rc" -eq "$APPLY_OK" ]]; then
        persist_state "$new_version"
    elif [[ "$rc" -ne "$APPLY_KEPT" ]]; then
        log_error "Sync failed: could not apply config $new_version"
        exit 1
    fi

    send_heartbeat || true

    if [[ "$rc" -eq "$APPLY_KEPT" ]]; then
        log_warn "Sync complete, nothing applied (server version: $new_version)"
    else
        log_success "Sync complete (Version: $new_version)"
    fi
}

# Show status
show_status() {
    echo "MyNodeOne Node Agent Status"
    echo "==========================="
    echo "Node Name:       $NODE_NAME"
    echo "Node Type:       $NODE_TYPE"
    echo "Control Plane:   $CONTROL_PLANE_IP:$API_PORT"
    echo "Tailscale IP:    $(get_tailscale_ip)"
    echo "Config Version:  ${CURRENT_CONFIG_VERSION:-unknown}"
    echo ""

    # Try to fetch current config
    local config
    if config=$(fetch_config 2>/dev/null); then
        echo "Connection:      OK"
        echo "Server Version:  $(jq -r '.version' <<<"$config")"
    else
        echo "Connection:      FAILED"
    fi
}

# Print usage
usage() {
    cat <<EOF
MyNodeOne Node Agent

Usage:
  node-agent.sh <command>

Commands:
  run         Start the agent daemon (continuous polling)
  sync        One-time sync (fetch and apply config)
  heartbeat   Send a single heartbeat
  status      Show agent status
  help        Show this help

Environment Variables:
  CONTROL_PLANE_IP    IP of the control plane (required)
  NODE_NAME           Name of this node (default: hostname)
  NODE_TYPE           Type: laptop, vps, worker (default: laptop)
  POLL_INTERVAL       Seconds between config polls (default: 60)
  HEARTBEAT_INTERVAL  Seconds between heartbeats (default: 60)
  API_PORT            Control plane API port (default: 8443)
  API_TOKEN           API token for authentication
  TRAEFIK_CONFIG_DIR  Traefik dynamic config directory (VPS only)

Config File:
  /etc/mynodeone/agent.env

Examples:
  # Start agent daemon
  sudo node-agent.sh run

  # One-time sync
  sudo node-agent.sh sync

  # Check status
  node-agent.sh status
EOF
}

# Main entry point
main() {
    case "${1:-}" in
        help | --help | -h)
            usage
            return 0
            ;;
    esac

    load_config

    case "${1:-}" in
        run)
            run_agent
            ;;
        sync)
            sync_once
            ;;
        heartbeat)
            send_heartbeat
            ;;
        status)
            show_status
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
