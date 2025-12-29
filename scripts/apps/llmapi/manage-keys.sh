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

# Execute Redis command
redis_cmd() {
    kubectl exec -n "$NAMESPACE" deploy/redis -- redis-cli "$@" 2>/dev/null
}

# Create API key
cmd_create() {
    local name=""
    local scopes=$DEFAULT_SCOPES
    local tokens=$DEFAULT_TOKENS_PER_DAY
    local rpm=$DEFAULT_REQUESTS_PER_MINUTE
    
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
    
    # Generate key
    local key_id=$(openssl rand -hex 16)
    local api_key="sk-mynodeone-${key_id}"
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Convert comma-separated scopes to JSON array
    local scopes_json=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/["/;s/$/"]/')
    
    # Store in Redis
    local config="{\"name\":\"$name\",\"scopes\":$scopes_json,\"requests_per_minute\":$rpm,\"tokens_per_day\":$tokens,\"created_at\":\"$created_at\"}"
    redis_cmd SET "apikey:${api_key}" "$config"
    
    echo ""
    echo -e "${GREEN}✓ API Key Created${NC}"
    echo ""
    echo "   Key:     $api_key"
    echo "   Name:    $name"
    echo "   Scopes:  $scopes"
    echo "   Quota:   $tokens tokens/day, $rpm requests/min"
    echo ""
    echo "   Save this key securely - it cannot be retrieved later!"
    echo ""
}

# List API keys
cmd_list() {
    echo ""
    echo -e "${BLUE}API Keys${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local keys=$(redis_cmd KEYS "apikey:sk-mynodeone-*" | grep -v "^$" || true)
    
    if [ -z "$keys" ]; then
        echo "No API keys found."
        echo ""
        return
    fi
    
    printf "%-30s %-20s %-25s %-12s %-8s\n" "API KEY" "NAME" "SCOPES" "TOKENS/DAY" "RPM"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    echo "$keys" | while read key; do
        local api_key="${key#apikey:}"
        local config=$(redis_cmd GET "$key")
        
        if [ -n "$config" ]; then
            local name=$(echo "$config" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            local scopes=$(echo "$config" | grep -o '"scopes":\[[^]]*\]' | sed 's/"scopes"://;s/\["//;s/"\]//;s/","/,/g')
            [ -z "$scopes" ] && scopes="inference"  # Default for old keys
            local tokens=$(echo "$config" | grep -o '"tokens_per_day":[0-9]*' | cut -d':' -f2)
            local rpm=$(echo "$config" | grep -o '"requests_per_minute":[0-9]*' | cut -d':' -f2)
            
            # Mask the key
            local masked_key="${api_key:0:20}...${api_key: -4}"
            
            printf "%-30s %-20s %-25s %-12s %-8s\n" "$masked_key" "${name:0:20}" "${scopes:0:25}" "$tokens" "$rpm"
        fi
    done
    
    echo ""
}

# Show API key details
cmd_show() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        echo -e "${RED}Error: API key required${NC}"
        usage
        exit 1
    fi
    
    local config=$(redis_cmd GET "apikey:${api_key}")
    
    if [ -z "$config" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${BLUE}API Key Details${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    local name=$(echo "$config" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    local scopes=$(echo "$config" | grep -o '"scopes":\[[^]]*\]' | sed 's/"scopes"://;s/\["//;s/"\]//;s/","/,/g')
    [ -z "$scopes" ] && scopes="inference"  # Default for old keys
    local tokens=$(echo "$config" | grep -o '"tokens_per_day":[0-9]*' | cut -d':' -f2)
    local rpm=$(echo "$config" | grep -o '"requests_per_minute":[0-9]*' | cut -d':' -f2)
    local created=$(echo "$config" | grep -o '"created_at":"[^"]*"' | cut -d'"' -f4)
    
    echo "   Key:         ${api_key:0:20}...${api_key: -4}"
    echo "   Name:        $name"
    echo "   Scopes:      $scopes"
    echo "   Tokens/Day:  $tokens"
    echo "   RPM Limit:   $rpm"
    echo "   Created:     $created"
    echo ""
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
    
    local config=$(redis_cmd GET "apikey:${api_key}")
    
    if [ -z "$config" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    # Parse existing values
    local name=$(echo "$config" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    local scopes=$(echo "$config" | grep -o '"scopes":\[[^]]*\]' | sed 's/"scopes"://;s/\["//;s/"\]//;s/","/,/g')
    [ -z "$scopes" ] && scopes="inference"  # Default for old keys
    local tokens=$(echo "$config" | grep -o '"tokens_per_day":[0-9]*' | cut -d':' -f2)
    local rpm=$(echo "$config" | grep -o '"requests_per_minute":[0-9]*' | cut -d':' -f2)
    local created=$(echo "$config" | grep -o '"created_at":"[^"]*"' | cut -d'"' -f4)
    
    # Parse new values
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
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    # Convert comma-separated scopes to JSON array
    local scopes_json=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/["/;s/$/"]/')
    
    # Update in Redis
    local new_config="{\"name\":\"$name\",\"scopes\":$scopes_json,\"requests_per_minute\":$rpm,\"tokens_per_day\":$tokens,\"created_at\":\"$created\"}"
    redis_cmd SET "apikey:${api_key}" "$new_config"
    
    echo ""
    echo -e "${GREEN}✓ API Key Updated${NC}"
    echo ""
    echo "   Name:        $name"
    echo "   Scopes:      $scopes"
    echo "   Tokens/Day:  $tokens"
    echo "   RPM Limit:   $rpm"
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
    
    # Check if exists
    local config=$(redis_cmd GET "apikey:${api_key}")
    
    if [ -z "$config" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    local name=$(echo "$config" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    
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
    
    redis_cmd DEL "apikey:${api_key}"
    
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
    
    local config=$(redis_cmd GET "apikey:${api_key}")
    
    if [ -z "$config" ]; then
        echo -e "${RED}Error: API key not found${NC}"
        exit 1
    fi
    
    local name=$(echo "$config" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    local tokens_limit=$(echo "$config" | grep -o '"tokens_per_day":[0-9]*' | cut -d':' -f2)
    local rpm_limit=$(echo "$config" | grep -o '"requests_per_minute":[0-9]*' | cut -d':' -f2)
    
    # Get today's usage
    local today=$(date -u +%Y-%m-%d)
    local usage_key="tokens:${api_key}:${today}"
    local input_tokens=$(redis_cmd HGET "$usage_key" "input" || echo "0")
    local output_tokens=$(redis_cmd HGET "$usage_key" "output" || echo "0")
    input_tokens="${input_tokens:-0}"
    output_tokens="${output_tokens:-0}"
    local total_tokens=$((input_tokens + output_tokens))
    
    # Get current RPM
    local rpm_key="ratelimit:${api_key}:rpm"
    local current_rpm=$(redis_cmd GET "$rpm_key" || echo "0")
    current_rpm="${current_rpm:-0}"
    
    echo ""
    echo -e "${BLUE}Usage Statistics${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   Key:           ${api_key:0:15}...${api_key: -4}"
    echo "   Name:          $name"
    echo ""
    echo "   Today's Tokens:"
    echo "     Input:       $input_tokens"
    echo "     Output:      $output_tokens"
    echo "     Total:       $total_tokens / $tokens_limit"
    
    # Usage bar
    local pct=$((total_tokens * 100 / tokens_limit))
    if [ $pct -gt 100 ]; then pct=100; fi
    local bar_len=30
    local filled=$((pct * bar_len / 100))
    local empty=$((bar_len - filled))
    printf "     Progress:    ["
    printf '%*s' "$filled" | tr ' ' '█'
    printf '%*s' "$empty" | tr ' ' '░'
    printf "] %d%%\n" "$pct"
    
    echo ""
    echo "   Current Minute:"
    echo "     Requests:    $current_rpm / $rpm_limit"
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
        cmd_list
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
