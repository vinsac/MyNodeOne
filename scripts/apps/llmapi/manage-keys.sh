#!/bin/bash

###############################################################################
# LLM API Key Management
# 
# Create, list, update, and revoke API keys for the LLM API service.
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
DEFAULT_TOKENS_PER_MINUTE=40000
DEFAULT_ADMIN_TOKENS_PER_MINUTE=200000
DEFAULT_SCOPES="inference"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  create         Create a new API key"
    echo "  list [--full]  List all API keys (use --full to show complete keys)"
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
    echo "  $0 show sk-mynodeone-xxxx"
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
        result=$(kubectl exec -n "$NAMESPACE" deploy/llmapi-postgres -- psql -U llmapi -d llmapi -t -A "$@" 2>/dev/null)
        local exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
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
    
    # Generate key
    local key_id=$(openssl rand -hex 16)
    local api_key="sk-mynodeone-${key_id}"
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Convert comma-separated scopes to PostgreSQL array
    local scopes_array=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/{"/;s/$/"}/') 
    
    # Store in PostgreSQL
    psql_cmd -c "INSERT INTO api_keys (api_key, name, scopes, requests_per_minute, tokens_per_day, tokens_per_minute, created_at) \
        VALUES ('${api_key}', '${name}', '${scopes_array}', ${rpm}, ${tokens}, ${tpm}, '${created_at}');" >/dev/null
    
    echo ""
    echo -e "${GREEN}✓ API Key Created${NC}"
    echo ""
    echo "   Key:     $api_key"
    echo "   Name:    $name"
    echo "   Scopes:  $scopes"
    echo "   Quota:   $tokens tokens/day, $rpm RPM, $tpm TPM"
    echo ""
    echo "   Save this key securely - it cannot be retrieved later"
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
    
    local query="SELECT api_key, name, array_to_string(scopes, ','), tokens_per_day, requests_per_minute, tokens_per_minute \
        FROM api_keys WHERE revoked = FALSE AND api_key LIKE 'sk-mynodeone-%' ORDER BY created_at DESC;"
    local results=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$results" ]; then
        echo "No API keys found"
        return
    fi
    
    printf "%-22s %-20s %-28s %-15s %-8s %-10s\n" "KEY" "NAME" "SCOPES" "TOKENS/DAY" "RPM" "TPM"
    printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    echo "$results" | while IFS='|' read -r api_key name scopes tokens rpm tpm; do
        if [ -n "$api_key" ]; then
            # Show truncated or full key
            local display_key
            if [ "$show_full" = true ]; then
                display_key="$api_key"
            else
                display_key="${api_key:0:20}..."
            fi
            
            printf "%-22s %-20s %-28s %-15s %-8s %-10s\n" \
                "$display_key" "${name:0:20}" "${scopes:0:28}" "$tokens" "$rpm" "$tpm"
        fi
    done
    echo ""
    
    if [ "$show_full" = false ]; then
        echo -e "${YELLOW}Tip: Use 'list --full' to show complete API keys${NC}"
        echo ""
    fi
}

# Show API key details
cmd_show() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi
    
    local query="SELECT name, array_to_string(scopes, ','), tokens_per_day, requests_per_minute, tokens_per_minute, created_at \
        FROM api_keys WHERE api_key = '${api_key}';"
    local results=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$results" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${BLUE}API Key Details${NC}"
    echo ""
    
    echo "$results" | while IFS='|' read -r name scopes tokens rpm tpm created; do
        if [ -n "$name" ]; then
            echo "   Key:         ${api_key:0:20}...${api_key: -4}"
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
    local api_key="$1"
    shift
    
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
    [ -n "$name" ] && updates+=("name = '${name}'")
    [ -n "$tokens" ] && updates+=("tokens_per_day = ${tokens}")
    [ -n "$rpm" ] && updates+=("requests_per_minute = ${rpm}")
    [ -n "$tpm" ] && updates+=("tokens_per_minute = ${tpm}")
    
    if [ -n "$scopes" ]; then
        local scopes_array=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/{"/;s/$/"}/')
        updates+=("scopes = '${scopes_array}'")
    fi
    
    if [ ${#updates[@]} -eq 0 ]; then
        echo -e "${RED}Error: No fields to update${NC}"
        usage
        exit 1
    fi
    
    # Join updates with commas
    local update_clause=$(IFS=,; echo "${updates[*]}")
    
    # Update in PostgreSQL
    psql_cmd -c "UPDATE api_keys SET ${update_clause}, updated_at = NOW() WHERE api_key = '${api_key}';" >/dev/null
    
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
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi
    
    # Check if exists and get name
    local query="SELECT name FROM api_keys WHERE api_key = '${api_key}' AND revoked = FALSE;"
    local name=$(psql_cmd -c "$query" 2>/dev/null | head -1)
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: API key not found or already revoked${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}Warning: This will permanently revoke the API key.${NC}"
    echo "   Key:  ${api_key:0:15}...${api_key: -4}"
    echo "   Name: $name"
    echo ""
    read -p "Are you sure? [y/N]: " confirm
    
    if [ "${confirm,,}" != "y" ]; then
        echo "Cancelled."
        exit 0
    fi
    
    # Mark as revoked in PostgreSQL
    psql_cmd -c "UPDATE api_keys SET revoked = TRUE, updated_at = NOW() WHERE api_key = '${api_key}';" >/dev/null
    
    echo ""
    echo -e "${GREEN}✓ API Key Revoked${NC}"
    echo ""
}

# Show usage statistics
cmd_usage() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi
    
    # Get key info from Postgres
    local query="SELECT name, tokens_per_day, requests_per_minute, tokens_per_minute FROM api_keys WHERE api_key = '${api_key}' AND revoked = FALSE;"
    local key_info=$(psql_cmd -c "$query" 2>/dev/null || echo "")
    
    if [ -z "$key_info" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    local name=$(echo "$key_info" | cut -d'|' -f1)
    local tokens_limit=$(echo "$key_info" | cut -d'|' -f2)
    local rpm_limit=$(echo "$key_info" | cut -d'|' -f3)
    local tpm_limit=$(echo "$key_info" | cut -d'|' -f4)
    
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
    echo "   Key:         ${api_key:0:20}...${api_key: -4}"
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
