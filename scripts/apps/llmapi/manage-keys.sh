#!/bin/bash

###############################################################################
# LLM API Key Management
# 
# Create, list, update, and revoke API keys for the LLM API service.
#
# Raw keys are never stored. The api_key column holds the key id ("sha256:" plus
# the SHA-256 of the raw key) and key_prefix a non-secret prefix for display, so a
# key can only be shown once, when it is created. Commands that take a key accept
# the raw key, its key id, or its prefix as printed by 'list'.
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="llmapi"

# Default quotas
DEFAULT_TOKENS_PER_DAY=100000
DEFAULT_REQUESTS_PER_MINUTE=60
DEFAULT_TOKENS_PER_MINUTE=200000
DEFAULT_ADMIN_TOKENS_PER_MINUTE=200000
DEFAULT_SCOPES="inference"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create         Create a new API key"
    echo "  list [--full]  List all API keys (--full shows key ids; raw keys can't be retrieved)"
echo "  show           Show details for an API key"
    echo "  update         Update quotas for an API key"
    echo "  revoke         Revoke an API key"
    echo "  usage          Show usage statistics for an API key"
    echo ""
    echo "Options for 'create':"
    echo "  --name <name>           Name/description for the key"
    echo "  --scopes <scopes>       Comma-separated scopes: inference,metrics,admin (default: inference)"
    echo "  --tokens <number>       Daily token quota (default: $DEFAULT_TOKENS_PER_DAY)"
    echo "  --rpm <number>          Requests per minute limit (default: $DEFAULT_REQUESTS_PER_MINUTE)"
    echo "  --tpm <number>          Tokens per minute limit (default: $DEFAULT_TOKENS_PER_MINUTE; admin default: $DEFAULT_ADMIN_TOKENS_PER_MINUTE)"
    echo ""
    echo "Examples:"
    echo "  $0 create --name \"my-app\" --scopes \"inference\""
    echo "  $0 create --name \"prometheus\" --scopes \"metrics\""
    echo "  $0 create --name \"admin-ui\" --scopes \"admin\""
    echo "  $0 create --name \"power-user\" --scopes \"inference,metrics\""
    echo "  $0 list"
    echo "  $0 show sk-mynodeone-xxxxxxx..."
echo "  $0 update sk-mynodeone-xxxx --tokens 1000000"
    echo "  $0 revoke sk-mynodeone-xxxx"
    echo "  $0 usage sk-mynodeone-xxxx"
}

# Check prerequisites
check_prereqs() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found${NC}"
        exit 1
    fi
    
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo -e "${RED}Error: LLM API not installed. Run install-llmapi.sh first.${NC}"
        exit 1
    fi
}

# Execute PostgreSQL command with retries
psql_cmd() {
    local max_retries=3
    local retry_delay=2
    local attempt=1
    local result
    
    while [ $attempt -le $max_retries ]; do
        if result=$(kubectl exec -n "$NAMESPACE" deploy/llmapi-postgres -- psql -U llmapi -d llmapi -t -A "$@" 2>/dev/null); then
            echo "$result"
            return 0
        fi

        if [ $attempt -lt $max_retries ]; then
            echo "⚠ PostgreSQL command failed (attempt $attempt/$max_retries), retrying..." >&2
            sleep $retry_delay
        fi
        attempt=$((attempt + 1))
    done
    
    # Return empty on final failure (matches original behavior)
    echo ""
    return 1
}

# The key id stored for a raw key. Matches hash_api_key() in gateway/main.py.
hash_key() {
    printf '%s' "$1" | openssl dgst -sha256 | awk '{print "sha256:" $NF}'
}

# The non-secret prefix stored for a raw key. Matches api_key_display_prefix() in gateway/main.py.
display_prefix() {
    local half=$(( ${#1} / 2 ))
    echo "${1:0:$(( half < 20 ? half : 20 ))}"
}

sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# The hashed schema is created by the gateway, which must be upgraded before this
# script: an older gateway can't authenticate the hashed keys this script creates.
check_schema() {
    local has_column
    if ! has_column=$(psql_cmd -c "SELECT 1 FROM information_schema.columns WHERE table_name = 'api_keys' AND column_name = 'key_prefix';"); then
        echo -e "${RED}Error: could not query PostgreSQL${NC}"
        exit 1
    fi
    if [ -z "$has_column" ]; then
        echo -e "${RED}Error: api_keys has no key_prefix column. Deploy the updated gateway first; it migrates the table.${NC}"
        exit 1
    fi
}

# Set RESOLVED_KEY to the api_key column value for a raw key, key id or display
# prefix. A row the gateway hasn't migrated yet still holds the raw key there.
resolve_key() {
    local ref="${1%"..."}"
    if ! [[ "$ref" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        echo -e "${RED}Error: invalid API key format${NC}"
        exit 1
    fi

    local matches
    if ! matches=$(psql_cmd -c "SELECT api_key FROM api_keys WHERE api_key IN ('${ref}', '$(hash_key "$ref")') \
        OR key_prefix = '${ref}' OR (key_prefix IS NULL AND left(api_key, 20) = '${ref}');"); then
        echo -e "${RED}Error: could not query PostgreSQL${NC}"
        exit 1
    fi

    if [ -z "$matches" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    if [ "$(echo "$matches" | wc -l)" -gt 1 ]; then
        echo -e "${RED}Error: more than one key matches that prefix. Use the key id from 'list --full'.${NC}"
        exit 1
    fi
    RESOLVED_KEY="$matches"
}

# DEL keys in Redis. The password goes over stdin so it stays out of argv on both
# ends, and redis-cli reports errors like NOAUTH with exit code 0, so success means
# it printed the integer reply.
redis_del() {
    local auth="" output
    auth=$(kubectl get secret -n "$NAMESPACE" llmapi-redis-auth -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) || auth=""
    if ! output=$(printf '%s\n' "$auth" | kubectl exec -i -n "$NAMESPACE" deploy/redis -- \
        sh -c 'IFS= read -r REDISCLI_AUTH; if [ -n "$REDISCLI_AUTH" ]; then export REDISCLI_AUTH; else unset REDISCLI_AUTH; fi; exec redis-cli DEL "$@"' redis-del "$@" 2>/dev/null); then
        return 1
    fi
    [[ "$output" =~ ^[0-9]+$ ]]
}

# Remove a key from the gateway's auth cache so changes take effect immediately.
# Arguments: the stored api_key value, and the reference the user typed.
evict_cached_key() {
    local stored="$1" ref="${2%"..."}"
    local cache_keys=("apikey:${stored}")
    # Not yet migrated: the gateway may have cached it under the id already.
    [[ "$stored" == sha256:* ]] || cache_keys+=("apikey:$(hash_key "$stored")")
    # The raw key was typed: an entry from before the upgrade may still exist.
    [ "$(hash_key "$ref")" != "$stored" ] || cache_keys+=("apikey:${ref}")
    redis_del "${cache_keys[@]}"
}

# Create API key
cmd_create() {
local name=""
    local scopes=$DEFAULT_SCOPES
    local tokens=$DEFAULT_TOKENS_PER_DAY
    local rpm=$DEFAULT_REQUESTS_PER_MINUTE
    local tpm=$DEFAULT_TOKENS_PER_MINUTE
    local tpm_explicit=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name="$2"
                shift 2
                ;;
            --scopes)
                scopes="$2"
                shift 2
                ;;
            --tokens)
                tokens="$2"
                shift 2
                ;;
            --rpm)
                rpm="$2"
                shift 2
                ;;
            --tpm)
                tpm="$2"
                tpm_explicit=true
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$name" ]; then
        read -p "Enter a name for this API key: " name
    fi

    # If TPM wasn't explicitly set and key has admin scope, use higher default TPM.
    if [ "$tpm_explicit" = false ] && [[ ",${scopes}," == *",admin,"* ]]; then
        tpm=$DEFAULT_ADMIN_TOKENS_PER_MINUTE
    fi
    if [[ "$tpm" =~ ^[0-9]+$ ]] && [ "$tpm" -lt "$DEFAULT_TOKENS_PER_MINUTE" ]; then
        tpm=$DEFAULT_TOKENS_PER_MINUTE
    fi
    
    # Generate key
    local api_key="sk-mynodeone-$(openssl rand -hex 16)"
    local key_id
    key_id=$(hash_key "$api_key")
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Convert comma-separated scopes to PostgreSQL array
    local scopes_array=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/{"/;s/$/"}/')

    # Store in PostgreSQL. The raw key itself is never stored.
    if ! psql_cmd -c "INSERT INTO api_keys (api_key, key_prefix, name, scopes, requests_per_minute, tokens_per_day, tokens_per_minute, created_at) \
        VALUES ('${key_id}', '$(display_prefix "$api_key")', '$(sql_escape "$name")', '$(sql_escape "$scopes_array")', ${rpm}, ${tokens}, ${tpm}, '${created_at}');" >/dev/null; then
        echo -e "${RED}Error: failed to store the API key in PostgreSQL${NC}"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ API Key Created${NC}"
    echo ""
    echo "   Key:     $api_key"
    echo "   Key ID:  $key_id"
    echo "   Name:    $name"
echo "   Scopes:  $scopes"
    echo "   Quota:   $tokens tokens/day, $rpm RPM, $tpm TPM"
    echo ""
    echo "   Save this key securely - only its hash is stored, so it cannot be retrieved later"
echo ""
}

# List API keys
cmd_list() {
    local show_full=false
    
    # Check for --full flag
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                show_full=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    echo ""
    echo -e "${BLUE}API Keys${NC}"
    echo ""
    
    local query="SELECT api_key, COALESCE(key_prefix, left(api_key, 20)), name, array_to_string(scopes, ','), tokens_per_day, requests_per_minute, tokens_per_minute \
        FROM api_keys WHERE revoked = FALSE AND COALESCE(key_prefix, api_key) LIKE 'sk-mynodeone-%' ORDER BY created_at DESC;"
local results=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$results" ]; then
        echo "No API keys found"
        return
    fi
    
    local key_width=23
    [ "$show_full" = false ] || key_width=71

    printf "%-${key_width}s %-20s %-28s %-15s %-8s %-10s\n" "KEY" "NAME" "SCOPES" "TOKENS/DAY" "RPM" "TPM"
printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    echo "$results" | while IFS='|' read -r api_key prefix name scopes tokens rpm tpm; do
        if [ -n "$api_key" ]; then
            # Show the prefix or the key id. A row the gateway hasn't migrated yet
            # holds the raw key, which must not be printed.
            local display_key="${prefix}..."
            if [ "$show_full" = true ]; then
                if [[ "$api_key" == sha256:* ]]; then
                    display_key="$api_key"
                else
                    display_key="${prefix}... (pending migration)"
                fi
            fi

            printf "%-${key_width}s %-20s %-28s %-15s %-8s %-10s\n" \
"$display_key" "${name:0:20}" "${scopes:0:28}" "$tokens" "$rpm" "$tpm"
        fi
    done
    echo ""
    
    if [ "$show_full" = false ]; then
        echo -e "${YELLOW}Tip: Use 'list --full' to show key ids. Raw keys are stored only as hashes and can't be shown.${NC}"
        echo ""
    fi
}

# Show API key details
cmd_show() {
    local api_key="${1:-}"

    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi

    resolve_key "$api_key"
    api_key="$RESOLVED_KEY"

    local query="SELECT COALESCE(key_prefix, left(api_key, 20)), name, array_to_string(scopes, ','), tokens_per_day, requests_per_minute, tokens_per_minute, created_at \
        FROM api_keys WHERE api_key = '${api_key}';"
local results=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$results" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${BLUE}API Key Details${NC}"
    echo ""
    
    echo "$results" | while IFS='|' read -r prefix name scopes tokens rpm tpm created; do
        if [ -n "$name" ]; then
            echo "   Key:         ${prefix}..."
            [[ "$api_key" != sha256:* ]] || echo "   Key ID:      $api_key"
            echo "   Name:        $name"
            echo "   Scopes:      $scopes"
echo "   Tokens/Day:  $tokens"
            echo "   RPM Limit:   $rpm requests/min"
            echo "   TPM Limit:   $tpm tokens/min"
            echo "   Created:     $created"
            echo ""
        fi
    done
}

# Update API key
cmd_update() {
    local api_key="${1:-}"
    [ $# -eq 0 ] || shift

if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi
    
    local name=""
    local scopes=""
    local tokens=""
    local rpm=""
    local tpm=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                name="$2"
                shift 2
                ;;
            --scopes)
                scopes="$2"
                shift 2
                ;;
            --tokens)
                tokens="$2"
                shift 2
                ;;
            --rpm)
                rpm="$2"
                shift 2
                ;;
            --tpm)
                tpm="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    # Build UPDATE query based on provided parameters
    local updates=()
    [ -n "$name" ] && updates+=("name = '$(sql_escape "$name")'")
[ -n "$tokens" ] && updates+=("tokens_per_day = ${tokens}")
    [ -n "$rpm" ] && updates+=("requests_per_minute = ${rpm}")
    if [ -n "$tpm" ]; then
        if [[ "$tpm" =~ ^[0-9]+$ ]] && [ "$tpm" -lt "$DEFAULT_TOKENS_PER_MINUTE" ]; then
            tpm=$DEFAULT_TOKENS_PER_MINUTE
        fi
        updates+=("tokens_per_minute = ${tpm}")
    fi
    
    if [ -n "$scopes" ]; then
        local scopes_array=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/{"/;s/$/"}/')
        updates+=("scopes = '$(sql_escape "$scopes_array")'")
fi
    
    if [ ${#updates[@]} -eq 0 ]; then
        echo -e "${RED}Error: No fields to update${NC}"
        usage
        exit 1
    fi
    
    # Join updates with commas
    local update_clause=$(IFS=,; echo "${updates[*]}")
    
    local key_ref="$api_key"
    resolve_key "$key_ref"
    api_key="$RESOLVED_KEY"

    # Update in PostgreSQL
    if ! psql_cmd -c "UPDATE api_keys SET ${update_clause}, updated_at = NOW() WHERE api_key = '${api_key}';" >/dev/null; then
        echo -e "${RED}Error: failed to update the API key in PostgreSQL${NC}"
        exit 1
    fi

    if ! evict_cached_key "$api_key" "$key_ref"; then
        echo -e "${YELLOW}Warning: could not reach Redis. The gateway picks up this change within 5 minutes.${NC}"
    fi

    echo ""
echo -e "${GREEN}✓ API Key Updated${NC}"
    echo ""
    [ -n "$name" ] && echo "   Name:        $name"
    [ -n "$scopes" ] && echo "   Scopes:      $scopes"
    [ -n "$tokens" ] && echo "   Tokens/Day:  $tokens"
    [ -n "$rpm" ] && echo "   RPM Limit:   $rpm requests/min"
    [ -n "$tpm" ] && echo "   TPM Limit:   $tpm tokens/min"
    echo ""
}

# Revoke API key
cmd_revoke() {
    local key_ref="${1:-}"

    if [ -z "$key_ref" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi

    resolve_key "$key_ref"
    local api_key="$RESOLVED_KEY"

    # Check if exists and get name
    local query="SELECT COALESCE(key_prefix, left(api_key, 20)) || '|' || name FROM api_keys WHERE api_key = '${api_key}' AND revoked = FALSE;"
    local key_info=$(psql_cmd -c "$query" 2>/dev/null | head -1)

    if [ -z "$key_info" ]; then
        echo -e "${RED}Error: API key not found or already revoked${NC}"
        exit 1
    fi

    echo ""
    echo -e "${YELLOW}Warning: This will permanently revoke the API key.${NC}"
    echo "   Key:  ${key_info%%|*}..."
    echo "   Name: ${key_info#*|}"
echo ""
    read -p "Are you sure? [y/N]: " confirm
    
    if [ "${confirm,,}" != "y" ]; then
        echo "Cancelled."
        exit 0
    fi
    
    # Mark as revoked in PostgreSQL
    if ! psql_cmd -c "UPDATE api_keys SET revoked = TRUE, updated_at = NOW() WHERE api_key = '${api_key}';" >/dev/null; then
        echo -e "${RED}Error: failed to revoke the API key in PostgreSQL. The key still works.${NC}"
        exit 1
    fi

    # The gateway authenticates from Redis first, so the key keeps working until
    # its cache entry is gone.
    if ! evict_cached_key "$api_key" "$key_ref"; then
        echo ""
        echo -e "${RED}Error: revoked in PostgreSQL, but could not remove the key from the Redis cache.${NC}"
        echo "   The key keeps working until the gateway's next sync removes it, within 5 minutes."
        echo ""
        exit 1
    fi

    echo ""
    echo -e "${GREEN}✓ API Key Revoked${NC}"
    echo ""
}

# Show usage statistics
cmd_usage() {
    local api_key="${1:-}"

    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi

    resolve_key "$api_key"
    api_key="$RESOLVED_KEY"

    # Get key info from Postgres
    local query="SELECT name, tokens_per_day, requests_per_minute, tokens_per_minute, COALESCE(key_prefix, left(api_key, 20)) FROM api_keys WHERE api_key = '${api_key}' AND revoked = FALSE;"
local key_info=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$key_info" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    local name=$(echo "$key_info" | cut -d'|' -f1)
    local tokens_limit=$(echo "$key_info" | cut -d'|' -f2)
    local rpm_limit=$(echo "$key_info" | cut -d'|' -f3)
    local tpm_limit=$(echo "$key_info" | cut -d'|' -f4)
    local key_prefix=$(echo "$key_info" | cut -d'|' -f5)

    # Get today's usage from Postgres
    local today=$(date +%Y-%m-%d)
    local usage_query="SELECT COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0), COALESCE(SUM(requests), 0) \
        FROM usage_logs WHERE api_key = '${api_key}' AND date = '${today}';"
    local usage_data=$(psql_cmd -c "$usage_query" 2>/dev/null || echo "0|0|0")
    
    local input_tokens=$(echo "$usage_data" | cut -d'|' -f1)
    local output_tokens=$(echo "$usage_data" | cut -d'|' -f2)
    local requests_today=$(echo "$usage_data" | cut -d'|' -f3)
    
    local total_tokens=$((input_tokens + output_tokens))
    local usage_percent=0
    if [ "$tokens_limit" -gt 0 ]; then
        usage_percent=$(( (total_tokens * 100) / tokens_limit ))
    fi
    
    echo ""
    echo -e "${BLUE}Usage Statistics${NC}"
    echo ""
    echo "   Key:         ${key_prefix}..."
    echo "   Name:        $name"
    echo ""
    echo "   Today's Usage:"
echo "   - Input tokens:    $input_tokens"
    echo "   - Output tokens:   $output_tokens"
    echo "   - Total tokens:    $total_tokens / $tokens_limit (${usage_percent}%)"
    echo "   - Requests:        $requests_today"
    echo ""
    echo "   Rate Limits:"
    echo "   - RPM:             $rpm_limit requests/min"
    echo "   - TPM:             $tpm_limit tokens/min"
    echo ""
}

# Main
check_prereqs

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    create|list|show|update|revoke|usage)
        check_schema
        ;;
esac

case "$command" in
    create)
cmd_create "$@"
        ;;
    list)
        cmd_list "$@"
        ;;
    show)
        cmd_show "$@"
        ;;
    update)
        cmd_update "$@"
        ;;
    revoke)
        cmd_revoke "$@"
        ;;
    usage)
        cmd_usage "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo -e "${RED}Unknown command: $command${NC}"
        usage
        exit 1
        ;;
esac
