#!/bin/bash
# Helpers that let install-llmapi.sh and upgrade-llmapi.sh be re-run safely: existing
# Secrets, tuned ConfigMaps, replica counts and API keys are kept. Source this file.

# Secret values are piped to `kubectl create -f -` so they never appear in process
# arguments, and `create` leaves no last-applied annotation holding a copy.
_create_secret_from_stdin() {
    local name="$1" key="$2" encoded
    encoded=$(base64 -w0)
    kubectl create -n "${NAMESPACE:-llmapi}" -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $name
type: Opaque
data:
  $key: $encoded
EOF
}

secret_exists() {
    kubectl get secret "$1" -n "${NAMESPACE:-llmapi}" >/dev/null 2>&1
}

# Creates or updates a one-key Secret with the value on stdin. Replacing also removes the
# last-applied copy from a Secret that an older installer applied.
put_secret_from_stdin() {
    local name="$1" key="$2" encoded
    encoded=$(base64 -w0)
    replace_or_create_from_stdin secret "$name" >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: ${NAMESPACE:-llmapi}
type: Opaque
data:
  $key: $encoded
EOF
}

# Creates the Postgres Secret on a first install and never touches an existing one.
# Postgres only applies its password when the volume is first initialised, so a new
# password next to an existing volume would lock the gateway out of its database.
ensure_postgres_secret() {
    if secret_exists llmapi-db; then
        echo "   ✓ Keeping existing PostgreSQL secret"
        return 0
    fi
    if kubectl get pvc llmapi-postgres-data -n "${NAMESPACE:-llmapi}" >/dev/null 2>&1; then
        echo "ERROR: Secret llmapi-db is missing, but PVC llmapi-postgres-data still holds a database." >&2
        echo "       A newly generated password would not match it, so nothing was changed." >&2
        echo "       Restore the Secret, with the original password under key postgres-password, then re-run." >&2
        return 1
    fi
    openssl rand -base64 32 | tr -d '\n' | _create_secret_from_stdin llmapi-db postgres-password
    echo "   ✓ PostgreSQL secret created"
}

# Hex only, because the value is written into a Redis config line unquoted.
ensure_redis_secret() {
    if secret_exists llmapi-redis-auth; then
        echo "   ✓ Keeping existing Redis password secret"
        return 0
    fi
    openssl rand -hex 32 | tr -d '\n' | _create_secret_from_stdin llmapi-redis-auth password
    echo "   ✓ Redis password secret created"
}

# Prints one value from a ConfigMap, or nothing if the ConfigMap or key doesn't exist.
configmap_value() {
    kubectl get configmap "$1" -n "${NAMESPACE:-llmapi}" -o "jsonpath={.data.$2}" 2>/dev/null || true
}

_render_doc() {
    local doc="$1" ns="${NAMESPACE:-llmapi}" kind name current existing
    kind=$(sed -n 's/^kind:[[:space:]]*//p' <<<"$doc" | head -n1)
    # Comment-only documents have nothing to apply.
    [ -n "$kind" ] || return 0
    name=$(awk '/^metadata:/{m=1;next} m&&/^[^ #]/{m=0} m&&/^  name:/{print $2;exit}' <<<"$doc")

    case "$kind" in
        ConfigMap | Secret)
            # A manifest only provides first-install defaults. The live object may hold
            # the installer's choices or Admin UI tuning. An API error is treated like
            # "exists", so a brief failure can't overwrite it with the defaults.
            if ! existing=$(kubectl get "$kind" "$name" -n "$ns" --ignore-not-found -o name 2>/dev/null) || [ -n "$existing" ]; then
                echo "   Keeping existing $kind $name" >&2
                return 0
            fi
            ;;
        Deployment | StatefulSet)
            # Manifests have fixed replica counts, such as 0 for llama.cpp. Keep the current
            # count so an apply can't briefly stop a backend that is running.
            current=$(kubectl get "$kind" "$name" -n "$ns" -o 'jsonpath={.spec.replicas}' 2>/dev/null || true)
            if [[ "$current" =~ ^[0-9]+$ ]]; then
                doc=$(sed "s/^  replicas: .*/  replicas: $current/" <<<"$doc")
                doc+=$'\n'
            fi
            ;;
    esac
    printf -- '---\n%s' "$doc"
}

# Prints a manifest with the keep-what's-there rules above applied to each document.
render_manifest() {
    local file="$1" doc="" line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "---" ]; then
            _render_doc "$doc"
            doc=""
        else
            doc+="$line"$'\n'
        fi
    done <"$file"
    _render_doc "$doc"
}

apply_manifest() {
    local rendered
    rendered=$(render_manifest "$1")
    if [ -n "$rendered" ]; then
        kubectl apply -f - <<<"$rendered"
    fi
}

# Filter for a generated ConfigMap manifest. Keeps the live value of every key already
# in the cluster, except the keys named in $2, which the caller is setting on purpose.
keep_existing_configmap_values() {
    local name="$1" forced=" ${2:-} " existing
    existing=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$existing'" RETURN
    kubectl get configmap "$name" -n "${NAMESPACE:-llmapi}" \
        -o 'go-template={{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}' >"$existing" 2>/dev/null || : >"$existing"
    # Reads the live values in BEGIN because the file is empty on a first install, which
    # would make the usual NR == FNR test treat the manifest as the live values.
    awk -v forced="$forced" -v live_file="$existing" '
        BEGIN {
            while ((getline line < live_file) > 0) {
                eq = index(line, "=")
                if (eq > 1) live[substr(line, 1, eq - 1)] = substr(line, eq + 1)
            }
        }
        /^data:/ { in_data = 1; print; next }
        in_data && /^[^ #]/ { in_data = 0 }
        in_data && /^  [A-Za-z0-9_.-]+: / {
            key = $1
            sub(/:$/, "", key)
            if ((key in live) && index(forced, " " key " ") == 0) {
                value = live[key]
                gsub(/\\/, "\\\\", value)
                gsub(/"/, "\\\"", value)
                print "  " key ": \"" value "\""
                next
            }
        }
        { print }
    '
}

replace_or_create_from_stdin() {
    local manifest
    manifest=$(cat)
    if kubectl get "$1" "$2" -n "${NAMESPACE:-llmapi}" >/dev/null 2>&1; then
        kubectl replace -f - <<<"$manifest"
    else
        kubectl create -f - <<<"$manifest"
    fi
}

# True when a gateway Deployment exists whose pods don't send a Redis password. Applying
# today's Redis manifest under it would leave a gateway that hangs on every request while
# /health answers 200. upgrade-llmapi.sh is what stops it first.
gateway_predates_redis_auth() {
    local names
    names=$(kubectl get deployment gateway -n "${NAMESPACE:-llmapi}" --ignore-not-found --request-timeout=30s \
        -o 'jsonpath={.metadata.name}{" "}{.spec.template.spec.containers[*].env[*].name}' 2>/dev/null) || return 1
    [ -n "$names" ] && [[ " $names " != *" REDIS_PASSWORD "* ]]
}

# Lockfile for the vLLM init container. See manifests/vllm.yaml.
ship_model_downloader_lock() {
    local lock="$1/model-downloader/requirements.lock"
    kubectl create configmap model-downloader-lock -n "${NAMESPACE:-llmapi}" \
        --from-file=requirements.lock="$lock" --dry-run=client -o yaml |
        replace_or_create_from_stdin configmap model-downloader-lock
}

_psql_query() {
    kubectl exec -n "${NAMESPACE:-llmapi}" deploy/llmapi-postgres -- \
        psql -U llmapi -d llmapi -t -A -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

# The key id stored for a raw key, and the non-secret prefix stored beside it. These match
# hash_api_key() and api_key_display_prefix() in gateway/main.py. printf is a builtin, so
# the raw key is never in a process's arguments.
_api_key_id() {
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print "sha256:" $NF}'
}

_api_key_prefix() {
    local half=$((${#1} / 2))
    printf '%s' "${1:0:$((half < 20 ? half : 20))}"
}

# Usage: create_api_key <name> <scope> <rpm> <tokens_per_day> <tokens_per_minute>
# Prints the new key. Postgres only ever gets its id and prefix.
create_api_key() {
    local name="$1" scopes="$2" rpm="$3" tokens="$4" tpm="${5:-200000}" api_key key_id key_prefix created_at scopes_array i
    if [[ "$tpm" =~ ^[0-9]+$ ]] && [ "$tpm" -lt 200000 ]; then
        tpm=200000
    fi
    api_key="sk-mynodeone-$(openssl rand -hex 16)"
    key_id=$(_api_key_id "$api_key")
    key_prefix=$(_api_key_prefix "$api_key")
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Convert comma-separated scopes to PostgreSQL array format
    scopes_array=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/{"/;s/$/"}/')
    for i in {1..10}; do
        if _psql_query "INSERT INTO api_keys (api_key, key_prefix, name, scopes, requests_per_minute, tokens_per_day, tokens_per_minute, created_at) \
            VALUES ('${key_id}', '${key_prefix}', '${name}', '${scopes_array}', ${rpm}, ${tokens}, ${tpm}, '${created_at}') \
            ON CONFLICT (api_key) DO NOTHING;" >/dev/null; then
            echo "$api_key"
            return 0
        fi
        sleep "${API_KEY_RETRY_SLEEP:-2}"
    done
    return 1
}

# The gateway owns the schema: it creates and migrates the tables when it starts, and the
# installer creates none. On a first install they may not exist yet, so this waits for
# key_prefix, the column it adds last. About 5 minutes by default, and only once: after a
# timeout, the other keys in the same run check once and move on.
wait_for_hashed_schema() {
    local attempts="${API_KEY_SCHEMA_ATTEMPTS:-150}" i found
    [ "${_HASHED_SCHEMA_TIMED_OUT:-false}" = false ] || attempts=1
    for ((i = 1; i <= attempts; i++)); do
        found=$(_psql_query "SELECT 1 FROM information_schema.columns WHERE table_name = 'api_keys' AND column_name = 'key_prefix';" || true)
        if [ -n "$found" ]; then
            return 0
        fi
        [ "$i" -eq "$attempts" ] || sleep "${API_KEY_RETRY_SLEEP:-2}"
    done
    _HASHED_SCHEMA_TIMED_OUT=true
    return 1
}

# The ids of a role's active keys, one per line. Retries like ensure_api_key's first query.
_role_key_ids() {
    local name="$1" scope="$2" i
    for i in {1..10}; do
        if _psql_query "SELECT api_key FROM api_keys WHERE revoked = FALSE AND (name = '${name}' OR '${scope}' = ANY(scopes));"; then
            return 0
        fi
        sleep "${API_KEY_RETRY_SLEEP:-2}"
    done
    return 1
}

# Compares in the shell, so that no key value is ever in a process argument. Rows that
# the gateway hasn't migrated yet hold the raw key instead of its id.
_key_is_listed() {
    local raw_key="$1" rows="$2" key_id row
    key_id=$(_api_key_id "$raw_key")
    while IFS= read -r row; do
        if [ "$row" = "$key_id" ] || [ "$row" = "$raw_key" ]; then
            return 0
        fi
    done <<<"$rows"
    return 1
}

# Makes sure one active key exists for this role, creating one only if none does.
# Sets ENSURED_KEY to the key when known, and ENSURED_KEY_STATE to one of:
#   new        just created (shown once by the installer)
#   reused     the local file holds the value of an active key for this role
#   restored   an active key exists and its value was copied back to the local file
#   elsewhere  an active key with this scope exists but its value isn't available here
#   stale      as elsewhere, but the local file holds some other key: revoked, or from an
#              earlier install. Its value is not used, and the file is left for the admin.
#   unknown    the database could not be queried, or the gateway hasn't created its
#              schema yet, so nothing was created
# A role counts as covered by any active key with its scope, so a key that was rotated
# under a new name does not cause another one to be created.
#
# Usage: ensure_api_key <name> <scope> <rpm> <tokens_per_day> <tokens_per_minute> <key_file>
ensure_api_key() {
    local name="$1" scope="$2" rpm="$3" tokens="$4" tpm="$5" key_file="$6" count="" i stored="" file_key role_keys
    ENSURED_KEY=""
    ENSURED_KEY_STATE="unknown"

    if ! wait_for_hashed_schema; then
        return 1
    fi

    for i in {1..10}; do
        if count=$(_psql_query "SELECT count(*) FROM api_keys WHERE revoked = FALSE AND (name = '${name}' OR '${scope}' = ANY(scopes));"); then
            break
        fi
        count=""
        sleep "${API_KEY_RETRY_SLEEP:-2}"
    done
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [ "$count" -gt 0 ]; then
        if [ -s "$key_file" ]; then
            file_key=$(cat "$key_file")
            if ! role_keys=$(_role_key_ids "$name" "$scope"); then
                return 1
            fi
            if _key_is_listed "$file_key" "$role_keys"; then
                ENSURED_KEY="$file_key"
                ENSURED_KEY_STATE="reused"
                return 0
            fi
        fi
        # Only a row the gateway hasn't migrated yet can still hold a raw key. A key id can't
        # be turned back into a key, which is the "elsewhere" and "stale" cases below.
        stored=$(_psql_query "SELECT api_key FROM api_keys WHERE revoked = FALSE AND name = '${name}' ORDER BY created_at LIMIT 1;" || true)
        if [[ "$stored" == sk-mynodeone-* ]]; then
            ENSURED_KEY="$stored"
            ENSURED_KEY_STATE="restored"
            _write_key_file "$key_file" "$stored"
            return 0
        fi
        if [ -s "$key_file" ]; then
            ENSURED_KEY_STATE="stale"
        else
            ENSURED_KEY_STATE="elsewhere"
        fi
        return 0
    fi

    if ENSURED_KEY=$(create_api_key "$name" "$scope" "$rpm" "$tokens" "$tpm"); then
        ENSURED_KEY_STATE="new"
        _write_key_file "$key_file" "$ENSURED_KEY"
        return 0
    fi
    ENSURED_KEY=""
    return 1
}

_write_key_file() {
    mkdir -p "$(dirname "$1")"
    (umask 077 && printf '%s\n' "$2" >"$1")
    chmod 600 "$1"
}
