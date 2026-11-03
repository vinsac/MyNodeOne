#!/bin/bash
###############################################################################
# Registry helpers shared by the scripts that read or write the
# service-registry and domain-registry ConfigMaps.
#
# Source this file; it runs nothing on its own. It keeps three promises:
#
#  * A failed or blank read is an error, never an empty registry. The old
#    `kubectl get ... || echo '{}'` pattern turned an API hiccup into a
#    write that erased every entry.
#  * Writes are compare-and-swap. The merge patch carries the resourceVersion
#    that was read, so a concurrent writer causes a retry, not a lost update.
#  * Patches are built with `jq -n --arg`, so no value reaches a shell or a
#    hand-escaped JSON string.
#
# Logs go to stderr because these functions run inside command substitutions.
###############################################################################

SR_NAMESPACE="${SR_NAMESPACE:-kube-system}"
SR_SERVICE_CM="service-registry"
SR_SERVICE_KEY="services.json"
SR_DOMAIN_CM="domain-registry"
SR_ROUTING_KEY="routing.json"

# Set by sr_read_cm.
SR_READ_JSON=""
SR_READ_RV=""

sr_warn() { printf '[service-registry] WARNING: %s\n' "$1" >&2; }
sr_err() { printf '[service-registry] ERROR: %s\n' "$1" >&2; }

###############################################################################
# Validation
###############################################################################

# A single DNS label. Dots are refused so a service cannot claim a name outside
# the cluster domain, and whitespace or newlines cannot add lines to /etc/hosts.
sr_valid_local_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    case "${1,,}" in
        localhost|localhost4|localhost6|broadcasthost) return 1 ;;
        ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters) return 1 ;;
        ip6-localnet|ip6-mcastprefix) return 1 ;;
    esac
    return 0
}

sr_valid_ip() {
    local ip="${1:-}" octet
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        local IFS=.
        # shellcheck disable=SC2086  # split on dots is the point
        for octet in $ip; do
            ((10#$octet <= 255)) || return 1
        done
        return 0
    fi
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]{2,45}$ ]]
}

# Kubernetes namespace or Service name.
sr_valid_k8s_name() {
    [[ "${1:-}" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]]
}

sr_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

sr_valid_cluster_domain() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

# A public hostname. These go into Traefik rules and remote commands.
sr_valid_fqdn() {
    ((${#1} <= 253)) &&
        [[ "${1:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

###############################################################################
# Strict reads
###############################################################################

# sr_read_cm <configmap> <data-key>
# Fills SR_READ_JSON and SR_READ_RV. Returns:
#   0 data is a JSON object
#   1 could not read, or the data is not a JSON object
#   2 the ConfigMap is confirmed absent
#   3 the ConfigMap exists but this key is missing or blank
sr_read_cm() {
    local cm="$1" key="$2" raw
    SR_READ_JSON=""
    SR_READ_RV=""

    if ! raw=$(kubectl get configmap "$cm" -n "$SR_NAMESPACE" -o json --ignore-not-found 2>/dev/null); then
        return 1
    fi
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        return 2
    fi
    if ! SR_READ_RV=$(jq -er '.metadata.resourceVersion | select(type == "string" and length > 0)' <<<"$raw" 2>/dev/null); then
        SR_READ_RV=""
        return 1
    fi

    local value
    if ! value=$(jq -r --arg k "$key" '.data[$k] // ""' <<<"$raw" 2>/dev/null); then
        return 1
    fi
    if [[ -z "${value//[[:space:]]/}" ]]; then
        return 3
    fi
    if ! SR_READ_JSON=$(jq -ce 'select(type == "object")' <<<"$value" 2>/dev/null); then
        SR_READ_JSON=""
        return 1
    fi
    return 0
}

# Prints the service registry, or fails if it cannot be read for certain.
sr_get_services() {
    local rc=0
    sr_read_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$SR_READ_JSON" ;;
        2) printf '{}\n' ;;
        3)
            sr_err "$SR_SERVICE_CM exists but $SR_SERVICE_KEY is blank; refusing to treat that as an empty registry"
            return 1
            ;;
        *)
            sr_err "could not read $SR_SERVICE_CM"
            return 1
            ;;
    esac
}

# Prints routing.json. It may legitimately never have been written, so a missing
# ConfigMap or blank key means no routes; only a failed read is an error.
sr_get_routing() {
    local rc=0
    sr_read_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" || rc=$?
    case "$rc" in
        0) printf '%s\n' "$SR_READ_JSON" ;;
        2 | 3) printf '{}\n' ;;
        *)
            sr_err "could not read $SR_DOMAIN_CM"
            return 1
            ;;
    esac
}

###############################################################################
# Compare-and-swap writes
###############################################################################

# sr_update_cm <configmap> <data-key> <command> [args...]
# Runs the command with the current JSON on stdin and writes its stdout back,
# conditional on the resourceVersion that was read. The command runs again on a
# conflict, so it must compute its result from stdin.
#
# A blank key is only treated as {} when SR_ALLOW_BLANK=1, which callers set for
# routing.json (it may legitimately never have been written) or for an explicit
# operator repair. A missing ConfigMap is never created here.
sr_update_cm() {
    local cm="$1" key="$2"
    shift 2
    local attempt=1 max="${SR_CAS_ATTEMPTS:-5}" rc new old_sorted new_sorted patch err

    while ((attempt <= max)); do
        rc=0
        sr_read_cm "$cm" "$key" || rc=$?
        case "$rc" in
            0) ;;
            3)
                if [[ "${SR_ALLOW_BLANK:-0}" != "1" ]]; then
                    sr_err "$cm exists but $key is blank; not writing. Re-run with MYNODEONE_REGISTRY_ALLOW_BLANK=1 only if you know it is really empty"
                    return 1
                fi
                SR_READ_JSON='{}'
                ;;
            2)
                sr_err "$cm does not exist"
                return 1
                ;;
            *)
                sr_err "could not read $cm; not writing"
                return 1
                ;;
        esac

        if ! new=$(printf '%s' "$SR_READ_JSON" | "$@"); then
            sr_err "update of $cm/$key failed; nothing written"
            return 1
        fi
        if ! new=$(jq -ce 'select(type == "object")' <<<"$new" 2>/dev/null); then
            sr_err "update of $cm/$key did not produce a JSON object; nothing written"
            return 1
        fi

        old_sorted=$(jq -cS . <<<"$SR_READ_JSON")
        new_sorted=$(jq -cS . <<<"$new")
        if [[ "$rc" == "0" && "$old_sorted" == "$new_sorted" ]]; then
            return 0
        fi

        patch=$(jq -n --arg k "$key" --arg v "$new" --arg rv "$SR_READ_RV" \
            '{metadata: {resourceVersion: $rv}, data: {($k): $v}}')

        if err=$(kubectl patch configmap "$cm" -n "$SR_NAMESPACE" --type merge -p "$patch" 2>&1 >/dev/null); then
            return 0
        fi
        if ! grep -qiE 'conflict|has been modified' <<<"$err"; then
            sr_err "patch of $cm failed: $err"
            return 1
        fi

        sr_warn "$cm changed while updating it, retrying ($attempt/$max)"
        sleep "${SR_CAS_RETRY_DELAY:-1}"
        attempt=$((attempt + 1))
    done

    sr_err "gave up updating $cm after $max conflicting writes"
    return 1
}

###############################################################################
# Key handling
###############################################################################

# Bare names that refer to an entry: legacy_key, the name part of the key, and
# the Kubernetes service name. Mirrors resolveRouting in cmd/config-api/main.go.
SR_JQ_ALIASES='def aliases($k; $v):
    [($v | if type == "object" then .legacy_key else null end),
     ($k | split("/") | last),
     ($v | if type == "object" then .service else null end)]
    | map(select(type == "string" and length > 0)) | unique;'

# sr_resolve_key <services-json> <name-or-key>
# Prints the registry key. Returns 1 if unknown, 2 if ambiguous (candidates are
# listed on stderr).
sr_resolve_key() {
    local services="$1" name="$2" matches count
    if jq -e --arg n "$name" 'has($n)' <<<"$services" >/dev/null 2>&1; then
        printf '%s\n' "$name"
        return 0
    fi
    # namespace/name also finds an entry still filed under its old bare key.
    matches=$(jq -r --arg n "$name" "$SR_JQ_ALIASES"'
        to_entries[]
        | select((aliases(.key; .value) | index($n))
                 or ((.value | if type == "object" then "\(.namespace)/\(.service)" else "" end) == $n))
        | .key' <<<"$services" 2>/dev/null) || return 1
    if [[ -z "$matches" ]]; then
        return 1
    fi
    count=$(grep -c '' <<<"$matches")
    if ((count > 1)); then
        sr_err "'$name' matches several services; use namespace/name:"
        sed 's/^/  /' <<<"$matches" >&2
        return 2
    fi
    printf '%s\n' "$matches"
}

# sr_lookup_entry <services-json> <name-or-key>
# Prints one entry, whichever key format the registry is in. Returns as
# sr_resolve_key does. This is how a script should find a service: `.[$name]`
# stops matching once the registry is migrated.
sr_lookup_entry() {
    local services="$1" key
    key=$(sr_resolve_key "$services" "$2") || return
    jq -c --arg k "$key" '.[$k]' <<<"$services"
}

# sr_service_field <name-or-key> <field>
# Reads the registry and prints one field of an entry. A missing field prints
# nothing, and so does a local_name of "", which means the bare cluster domain.
# Returns non-zero if the registry can't be read or the entry can't be identified.
sr_service_field() {
    local services entry
    services=$(sr_get_services) || return 1
    entry=$(sr_lookup_entry "$services" "$1") || return
    jq -r --arg f "$2" '.[$f] | if . == null then "" else . end' <<<"$entry"
}

# Who a bare routing.json key belongs to. Mirrors resolveRouting in
# cmd/config-api/main.go: a bare key goes to the one public entry with no record of
# its own that goes by that name, unless the bare key is itself a public entry's
# record. Sharing a name with a private service does not change the answer, and two
# claimants means nobody gets it.
SR_JQ_CLAIMS='def directly_held($all; $routing; $bare):
    ($all[$bare] | type) == "object" and $all[$bare].public == true and ($routing | has($bare));
def claimants($all; $routing; $bare):
    if directly_held($all; $routing; $bare) then []
    else [$all | to_entries[]
          | .key as $held
          | select((.value | type) == "object" and .value.public == true and ($routing | has($held) | not))
          | select(aliases(.key; .value) | index($bare))
          | .key]
    end;
def holders($all; $bare):
    [$all | to_entries[] | select(aliases(.key; .value) | index($bare)) | .key];
def owns_bare($all; $routing; $key; $bare):
    if directly_held($all; $routing; $bare) then false
    else claimants($all; $routing; $bare) as $claim
         | if ($claim | length) > 0 then $claim == [$key]
           else (holders($all; $bare) - [$key] | length) == 0
           end
    end;'

# sr_routing_keys_for <services-json> <key> [routing-json]
# Prints, one per line, the routing.json keys that belong to this entry: the key
# itself, plus each bare alias it owns by the rule above. An entry nobody public
# claims keeps an alias only if no other entry goes by that name. Pass the routing
# the caller read, and the registry from before any change to this entry's public flag.
sr_routing_keys_for() {
    local services="$1" key="$2" routing="${3:-}"
    [[ -n "$routing" ]] || routing='{}'
    jq -r --arg key "$key" --argjson routing "$routing" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $all
        | [$key] + [
            aliases($key; $all[$key] // {})[]
            | . as $bare
            | select($bare == $key or owns_bare($all; $routing; $key; $bare))
          ]
        | unique | .[]' <<<"$services"
}

# sr_routing_contested_by <services-json> <key> <routing-json>
# Prints bare routing keys this entry claims along with another public entry. The API
# publishes no route for those, and the other entry would inherit it the moment this
# one stopped claiming.
sr_routing_contested_by() {
    jq -r --arg key "$2" --argjson routing "$3" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $all
        | aliases($key; $all[$key] // {})[]
        | . as $bare
        | select($routing | has($bare))
        | claimants($all; $routing; $bare)
        | select((length > 1) and index($key))
        | $bare' <<<"$1"
}

# sr_routing_inherited_by <services-json> <key> <routing-json>
# Prints bare routing keys this entry would pick up by going public, although another
# entry goes by the same name and nothing says the record was ever this entry's.
sr_routing_inherited_by() {
    jq -r --arg key "$2" --argjson routing "$3" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $all
        | if $routing | has($key) then empty else
            aliases($key; $all[$key] // {})[]
            | . as $bare
            | select(($bare != $key) and ($routing | has($bare)))
            | select(directly_held($all; $routing; $bare) | not)
            | select(claimants($all; $routing; $bare) - [$key] | length == 0)
            | select(holders($all; $bare) - [$key] | length > 0)
            | $bare
          end' <<<"$1"
}

# sr_routing_promote_filter <services-json> <key>
# Filter for sr_update_cm. Run before <key> goes public: a bare record it shares a name
# with stays with the public entry using it today. Without this the two would both
# claim the record and the API would drop a live route.
sr_routing_promote_filter() {
    jq -c --arg key "$2" --argjson all "$1" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $routing
        | reduce (aliases($key; $all[$key] // {})[] | select(. != $key)) as $bare (.;
            if has($bare) then
                claimants($all; $routing; $bare) as $claim
                | if ($claim | length) == 1 and $claim[0] != $key and (has($claim[0]) | not)
                  then .[$claim[0]] = .[$bare] | del(.[$bare])
                  else . end
            else . end)'
}

# sr_blocked_rule_suffix <entry-json> <key>
# Prints the rule text excluding the entry's blocked paths from a public route.
# Mirrors resolveBlockedPaths in cmd/config-api/main.go: nothing is blocked unless the
# entry sets public_blocked_paths.
# Fails on a malformed field, so the caller can drop the route rather than publish
# it without the block.
sr_blocked_rule_suffix() {
    jq -er '
        (if has("public_blocked_paths") then .public_blocked_paths else [] end)
        | if type == "array" then . else error("public_blocked_paths is not an array") end
        | map(if type == "string" and test("\\A/[A-Za-z0-9._~/-]+\\z")
              then " && !PathPrefix(`\(.)`)"
              else error("invalid blocked path") end)
        | join("")' <<<"$1"
}

# The name a service directory and hook are stored under (scripts/apps/<name>).
sr_bare_name() {
    local services="$1" key="$2"
    jq -r --arg key "$key" '
        ($key | split("/") | last) as $name_part
        | (.[$key].legacy_key // "") as $legacy
        | if ($legacy | length) > 0 then $legacy else $name_part end' <<<"$services"
}

###############################################################################
# One-time migration from bare keys to namespace/name
###############################################################################

sr_needs_migration() {
    jq -e 'any(keys[]; test("\\A[^/]+/[^/]+\\z") | not)' <<<"$1" >/dev/null 2>&1
}

SR_JQ_TARGET='def target($k; $v):
    ((if ($v.namespace | type) == "string" and ($v.namespace | length) > 0 then $v.namespace else "default" end)
     + "/" + (if ($v.service | type) == "string" and ($v.service | length) > 0 then $v.service else $k end));
def is_namespaced: test("\\A[^/]+/[^/]+\\z");'

# sr_migrate_filter [routing-json]
# Rewrites bare keys on stdin to namespace/service, recording the old key as
# legacy_key. Every other field, including public, is kept. If two bare entries
# map to one key, public wins, and legacy_key is the name routing.json files the
# service under, or else one that differs from the service name, because the service
# name finds the entry anyway. Already-namespaced entries are left alone, so running
# this again is a no-op.
sr_migrate_filter() {
    local routing="${1:-}" input collisions
    [[ -n "$routing" ]] || routing='{}'
    input=$(cat)
    collisions=$(jq -r "$SR_JQ_TARGET"'
        [to_entries[] | select(.value | type == "object")
         | select(.key | is_namespaced | not)
         | {old: .key, new: target(.key; .value)}]
        | group_by(.new) | map(select(length > 1))[]
        | "\(.[0].new) <- \(map(.old) | join(", "))"' <<<"$input") || return 1
    if [[ -n "$collisions" ]]; then
        sr_warn "several old entries map to one key, merging them: $collisions"
    fi
    jq -c --argjson routing "$routing" "$SR_JQ_TARGET"'
        def score($name; $service):
            if ($name | type) != "string" or ($name | length) == 0 then -1
            elif $routing | has($name) then 2
            elif $name != $service then 1
            else 0 end;
        def pick($prev; $next; $service):
            if score($next; $service) > score($prev; $service) then $next else $prev end;
        . as $all
        | reduce (keys_unsorted | sort)[] as $k ({};
            ($all[$k]) as $v
            | if ($v | type) != "object" then .
              elif ($k | is_namespaced) then
                  (.[$k] // {}) as $prev
                  | .[$k] = ($prev + $v
                             | pick($prev.legacy_key; $v.legacy_key; .service) as $legacy
                             | if $legacy == null then del(.legacy_key) else .legacy_key = $legacy end
                             | .public = (($prev.public == true) or ($v.public == true)))
              else
                  target($k; $v) as $t
                  | (.[$t] // {}) as $prev
                  | .[$t] = ($prev + $v
                             | .legacy_key = pick($prev.legacy_key; ($v.legacy_key // $k); .service)
                             | .public = (($prev.public == true) or ($v.public == true)))
              end)' <<<"$input"
}

# sr_routing_migrate_filter <services-json>
# Filter for sr_update_cm, run once the registry is migrated: moves each bare
# routing.json key to the namespace/service key of the entry the API resolves it to, so
# the record no longer depends on a name. A contested record stays put; so does one no
# public entry claims, which still belongs to whoever goes public under that name.
sr_routing_migrate_filter() {
    jq -c --argjson all "$1" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $routing
        | reduce (keys_unsorted | sort | .[] | select(contains("/") | not)) as $bare (.;
            claimants($all; $routing; $bare) as $claim
            | if ($claim | length) == 1 and (has($claim[0]) | not)
              then .[$claim[0]] = .[$bare] | del(.[$bare])
              else . end)'
}

# sr_config_api_schema <host>: prints the schema the API advertises (0 if old).
sr_config_api_schema() {
    local host="$1" port="${API_PORT:-8443}" body
    body=$(curl -fsS --connect-timeout 3 --max-time 5 "http://${host}:${port}/api/v1/health" 2>/dev/null) || return 1
    jq -r '(.registry_schema // 0) | tonumber' <<<"$body" 2>/dev/null
}

# Can the bare-key registry be rewritten yet? A config API from before schema 2
# looks routing up by registry key only, so a migrated registry would make it
# render no routes. New agents keep their routes in that case, but an old
# sync-vps-routes.sh would install the empty file. So the API goes first.
sr_migration_allowed() {
    if [[ "${MYNODEONE_REGISTRY_FORCE_MIGRATE:-0}" == "1" ]]; then
        return 0
    fi

    local bin="${MYNODEONE_CONFIG_API_BIN:-/usr/local/bin/mynodeone-config-api}" schema=""
    if [[ -e "$bin" ]]; then
        schema=$(sr_config_api_schema 127.0.0.1) || schema=""
        [[ "$schema" =~ ^[0-9]+$ ]] && ((schema >= 2))
        return
    fi

    # No API on this host. If we know where the control plane is and it answers,
    # believe it. If nothing answers there may be no config API at all.
    if [[ -n "${CONTROL_PLANE_IP:-}" ]]; then
        if schema=$(sr_config_api_schema "$CONTROL_PLANE_IP"); then
            [[ "$schema" =~ ^[0-9]+$ ]] && ((schema >= 2))
            return
        fi
    fi
    return 0
}

# Set in the service-registry ConfigMap by the explicit `migrate` command. Only then
# may a routine sync or register migrate an old-format entry an old client wrote back.
SR_MIGRATION_KEY="migration.json"

sr_migration_marked() {
    local rc=0
    sr_read_cm "$SR_SERVICE_CM" "$SR_MIGRATION_KEY" || rc=$?
    [[ "$rc" -eq 0 ]] && jq -e '.opted_in == true' <<<"$SR_READ_JSON" >/dev/null 2>&1
}

sr_migration_mark_filter() {
    jq -c '.opted_in = true'
}

# Moves routing.json onto the migrated keys. Running it again changes nothing.
sr_migrate_routing() {
    local routing
    routing=$(sr_get_routing) || return 1
    [[ "$routing" != "{}" ]] || return 0
    sr_update_cm "$SR_DOMAIN_CM" "$SR_ROUTING_KEY" sr_routing_migrate_filter "$1"
}

# Registry first, then routing: the API finds a bare routing key through the entry's
# aliases, but nothing can find a namespaced routing key for a bare registry entry. So
# a failure in between leaves the routes working, and running this again finishes it.
sr_run_migration() {
    local routing services
    routing=$(sr_get_routing) || return 1
    sr_update_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" sr_migrate_filter "$routing" || return 1
    services=$(sr_get_services) || return 1
    sr_migrate_routing "$services" || return 1
    printf '[service-registry] migrated %s to namespace/name keys\n' "$SR_SERVICE_CM" >&2
}

# sr_migrate_registry: the explicit migration. Returns 0 when done or nothing is left
# to do, 3 when it has to wait for the config API upgrade, 1 on error.
sr_migrate_registry() {
    local rc=0 services
    sr_read_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" || rc=$?
    case "$rc" in
        0) ;;
        2) return 0 ;;
        3)
            sr_err "$SR_SERVICE_CM exists but $SR_SERVICE_KEY is blank; refusing to continue"
            return 1
            ;;
        *)
            sr_err "could not read $SR_SERVICE_CM"
            return 1
            ;;
    esac
    services="$SR_READ_JSON"

    if sr_needs_migration "$services"; then
        if ! sr_migration_allowed; then
            sr_warn "registry still uses bare keys and the config API does not advertise registry_schema 2 yet"
            return 3
        fi
        sr_run_migration || return 1
    else
        # An earlier run may have stopped between the registry and routing writes.
        sr_migrate_routing "$services" || return 1
    fi
    SR_ALLOW_BLANK=1 sr_update_cm "$SR_SERVICE_CM" "$SR_MIGRATION_KEY" sr_migration_mark_filter
}

# sr_ensure_schema: what a routine sync or register does about the key format.
# It migrates only after the explicit `migrate` command has opted in, or when
# MYNODEONE_REGISTRY_FORCE_MIGRATE=1 is set. Returns 0 when the registry is in the new
# format, 4 when it keeps its bare keys and the caller works with both, 3 when an
# opted-in migration has to wait for the config API upgrade, 1 on error.
sr_ensure_schema() {
    local rc=0 services
    sr_read_cm "$SR_SERVICE_CM" "$SR_SERVICE_KEY" || rc=$?
    case "$rc" in
        0) ;;
        2) return 0 ;;
        3)
            sr_err "$SR_SERVICE_CM exists but $SR_SERVICE_KEY is blank; refusing to continue"
            return 1
            ;;
        *)
            sr_err "could not read $SR_SERVICE_CM"
            return 1
            ;;
    esac
    services="$SR_READ_JSON"

    if ! sr_needs_migration "$services"; then
        return 0
    fi
    if [[ "${MYNODEONE_REGISTRY_FORCE_MIGRATE:-0}" != "1" ]] && ! sr_migration_marked; then
        return 4
    fi
    if ! sr_migration_allowed; then
        sr_warn "registry still uses bare keys and the config API does not advertise registry_schema 2 yet"
        return 3
    fi
    sr_run_migration || return 1
}

# sr_vps_push_loses_routes
# True only when it is certain that pushing a sync to a VPS now would install an empty
# route file: the registry has published routes and the config API renders none, which
# is what an API older than the registry does. sync-vps-routes.sh from before this
# check installs that file as it stands. A push is also how routes get removed, so
# nothing is refused while the registry has no routes to lose, and not knowing is not a
# reason to refuse either: with no answer from the API the remote script fails by itself.
sr_vps_push_loses_routes() {
    local services routing wanted token_file token host port body code
    services=$(sr_get_services 2>/dev/null) || return 1
    routing=$(sr_get_routing 2>/dev/null) || return 1
    wanted=$(jq --argjson routing "$routing" "$SR_JQ_ALIASES$SR_JQ_CLAIMS"'
        . as $all
        | [to_entries[]
           | select((.value | type) == "object" and .value.public == true)
           | .key as $key
           | select(($routing | has($key))
                    or any(aliases($key; .value)[]; . as $bare
                           | ($routing | has($bare)) and claimants($all; $routing; $bare) == [$key]))]
        | length' <<<"$services" 2>/dev/null) || return 1
    ((wanted > 0)) || return 1

    token_file="${MYNODEONE_API_TOKEN_FILE:-/etc/mynodeone/api-token}"
    [[ -r "$token_file" ]] || return 1
    token=$(cat "$token_file" 2>/dev/null) || return 1
    [[ -n "$token" ]] || return 1
    host=$(tailscale ip -4 2>/dev/null | head -n1) || host=""
    host="${host:-127.0.0.1}"
    port="${API_PORT:-8443}"
    body=$(mktemp) || return 1
    # The token goes through a config stream so it stays out of `ps`.
    code=$(curl -s --connect-timeout 3 --max-time 10 -o "$body" -w '%{http_code}' \
        -K <(printf 'header = "X-API-Token: %s"\n' "$token") \
        "http://${host}:${port}/api/v1/config/vps/traefik-config" 2>/dev/null) || code=""
    if [[ "$code" == "200" ]] && grep -q '^http:' "$body" && ! grep -q 'rule:' "$body"; then
        rm -f "$body"
        sr_err "the config API renders no routes but the registry has $wanted published; not pushing an empty route file"
        return 0
    fi
    rm -f "$body"
    return 1
}

###############################################################################
# /etc/hosts has one writer on each host
###############################################################################

# Prints who owns /etc/hosts here: timer on the control plane, agent on laptops and
# workers, none on a host with neither. The timer goes first because the agent stands
# down for it (dns_owned_by_timer in node-agent.sh). Ownership follows whether the
# timer is enabled, not whether it is running: stopping it for maintenance must not hand
# the file to another writer. Disabling it does.
sr_hosts_writer() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled --quiet mynodeone-local-dns-sync.timer 2>/dev/null ||
            systemctl is-active --quiet mynodeone-local-dns-sync.timer 2>/dev/null; then
            echo timer
            return 0
        fi
        if systemctl is-active --quiet mynodeone-node-agent.service 2>/dev/null; then
            echo agent
            return 0
        fi
    fi
    echo none
}

# Gets /etc/hosts brought up to date without writing it from the calling script.
# Prints one word: updated, deferred (the agent picks the change up at its next poll)
# or failed. The timer's own service runs now rather than waiting for its next tick.
# The agent is left to poll: a restart is the only way to prompt it, and that could
# kill it during a write to a file it has to overwrite in place. With neither,
# sync-dns.sh runs once, which is what the timer would have run.
sr_refresh_hosts() {
    case "$(sr_hosts_writer)" in
        timer)
            if sudo timeout 60 systemctl start mynodeone-local-dns-sync.service >/dev/null 2>&1; then
                echo updated
            else
                echo failed
            fi
            ;;
        agent)
            echo deferred
            ;;
        *)
            if sudo bash "$(dirname "${BASH_SOURCE[0]}")/../domains/sync-dns.sh" --quiet >/dev/null 2>&1; then
                echo updated
            else
                echo failed
            fi
            ;;
    esac
}

###############################################################################
# Field updates used by more than one script
###############################################################################

sr_set_public_filter() {
    jq -c --arg k "$1" --argjson v "$2" \
        'if has($k) then .[$k].public = $v else error("no such service: " + $k) end'
}

# Sets routing.json[<key>] and removes the bare aliases it replaces.
# Usage: sr_routing_set_filter <key> <entry-json> <aliases-json>
sr_routing_set_filter() {
    jq -c --arg k "$1" --argjson entry "$2" --argjson aliases "$3" \
        'reduce ($aliases[] | select(. != $k)) as $a (.; del(.[$a])) | .[$k] = $entry'
}

# Usage: sr_routing_del_filter <keys-json>
sr_routing_del_filter() {
    jq -c --argjson keys "$1" 'reduce $keys[] as $k (.; del(.[$k]))'
}
