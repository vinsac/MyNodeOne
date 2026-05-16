#!/bin/bash
#
# HuggingFace Token Management Library
# ===================================
# Centralized HF token handling for all llmapi scripts
#

# Check for HF token in this order:
# 1. Environment variable HF_TOKEN
# 2. Kubernetes secret (if kubectl available)
# 3. Local config file
# 4. Prompt user (optional)

HF_CONFIG_DIR="${HOME}/.config/llmapi"
HF_CONFIG_FILE="${HF_CONFIG_DIR}/hf-token"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

get_hf_token() {
    local prompt_if_missing="${1:-true}"
    local token=""
    
    # 1. Check environment variable
    if [[ -n "${HF_TOKEN:-}" ]]; then
        log_info "Using HuggingFace token from environment variable"
        echo "$HF_TOKEN"
        return 0
    fi
    
    # 2. Check Kubernetes secret
    if command -v kubectl &>/dev/null; then
        token=$(kubectl get secret hf-token -n llmapi -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [[ -n "$token" ]]; then
            log_info "Using HuggingFace token from Kubernetes secret"
            echo "$token"
            return 0
        fi
    fi
    
    # 3. Check local config file
    if [[ -f "$HF_CONFIG_FILE" ]]; then
        token=$(cat "$HF_CONFIG_FILE" 2>/dev/null | tr -d '\n\r' || echo "")
        if [[ -n "$token" && "$token" == hf_* ]]; then
            log_info "Using HuggingFace token from local config"
            echo "$token"
            return 0
        fi
    fi
    
    # 4. Prompt user if requested
    if [[ "$prompt_if_missing" == "true" ]]; then
        prompt_for_token
        token=$(get_hf_token false)  # Recursively check after prompting
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    fi
    
    # No token found
    log_warn "No HuggingFace token found. Downloads may be slower and gated models inaccessible."
    return 1
}

prompt_for_token() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  HuggingFace Token (Recommended)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "A HuggingFace token enables:"
    echo "  • Faster download speeds (authenticated users get priority)"
    echo "  • Access to gated models (Llama, Gemma, etc.)"
    echo "  • No rate limiting on model downloads"
    echo ""
    echo "Get your free token at: https://huggingface.co/settings/tokens"
    echo "(Create a 'Read' token - no special permissions needed)"
    echo ""
    
    local user_token
    read -p "Enter HuggingFace token (or press Enter to skip): " user_token
    
    if [[ -n "$user_token" ]]; then
        # Validate token format
        if [[ "$user_token" == hf_* ]]; then
            save_token "$user_token"
        else
            log_warn "Token doesn't look like a HuggingFace token (should start with 'hf_')"
            log_warn "Continuing without token - downloads may be slower"
        fi
    else
        log_info "Continuing without HuggingFace token"
        log_info "Downloads will work but may be slower for large models"
    fi
    echo ""
}

save_token() {
    local token="$1"
    local saved_locations=()
    
    if [[ -z "$token" ]]; then
        log_error "No token provided to save"
        return 1
    fi
    
    # Save to local config file
    mkdir -p "$HF_CONFIG_DIR"
    echo -n "$token" > "$HF_CONFIG_FILE"
    chmod 600 "$HF_CONFIG_FILE"
    saved_locations+=("local config (~/.config/llmapi/hf-token)")
    
    # Save to Kubernetes if available
    if command -v kubectl &>/dev/null; then
        # Check if namespace exists
        if kubectl get namespace llmapi &>/dev/null 2>&1; then
            if kubectl create secret generic hf-token -n llmapi \
                --from-literal=token="$token" \
                --dry-run=client -o yaml | kubectl apply -f - &>/dev/null; then
                saved_locations+=("Kubernetes secret (llmapi/hf-token)")
            else
                log_warn "Could not save to Kubernetes secret"
            fi
        else
            log_warn "Kubernetes namespace 'llmapi' not found - skipping K8s save"
        fi
    fi
    
    log_success "Token saved to: ${saved_locations[*]}"
    export HF_TOKEN="$token"  # Set for current session
}

delete_token() {
    local deleted_locations=()
    
    # Remove from local config
    if [[ -f "$HF_CONFIG_FILE" ]]; then
        rm -f "$HF_CONFIG_FILE"
        deleted_locations+=("local config")
    fi
    
    # Remove from Kubernetes
    if command -v kubectl &>/dev/null && kubectl get namespace llmapi &>/dev/null 2>&1; then
        if kubectl delete secret hf-token -n llmapi &>/dev/null; then
            deleted_locations+=("Kubernetes secret")
        fi
    fi
    
    if [[ ${#deleted_locations[@]} -gt 0 ]]; then
        log_success "Token deleted from: ${deleted_locations[*]}"
    else
        log_info "No stored tokens found to delete"
    fi
    
    unset HF_TOKEN  # Clear from current session
}

show_token_status() {
    local token
    echo "HuggingFace Token Status:"
    echo ""
    
    # Check environment
    if [[ -n "${HF_TOKEN:-}" ]]; then
        echo "  ✅ Environment variable: Set (${HF_TOKEN:0:8}...)"
    else
        echo "  ❌ Environment variable: Not set"
    fi
    
    # Check Kubernetes
    if command -v kubectl &>/dev/null; then
        token=$(kubectl get secret hf-token -n llmapi -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [[ -n "$token" ]]; then
            echo "  ✅ Kubernetes secret: Set (${token:0:8}...)"
        else
            echo "  ❌ Kubernetes secret: Not found"
        fi
    else
        echo "  ❌ Kubernetes secret: kubectl not available"
    fi
    
    # Check local config
    if [[ -f "$HF_CONFIG_FILE" ]]; then
        token=$(cat "$HF_CONFIG_FILE" 2>/dev/null | tr -d '\n\r' || echo "")
        if [[ -n "$token" && "$token" == hf_* ]]; then
            echo "  ✅ Local config: Set (${token:0:8}...)"
        else
            echo "  ❌ Local config: Invalid format"
        fi
    else
        echo "  ❌ Local config: Not found"
    fi
    
    echo ""
    
    # Get effective token
    if token=$(get_hf_token false); then
        echo "Effective token: ${token:0:8}... (${#token} chars)"
    else
        echo "Effective token: None"
    fi
}

# If called directly, provide CLI interface
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "get"|"show")
            if token=$(get_hf_token false); then
                echo "$token"
            else
                exit 1
            fi
            ;;
        "set"|"save")
            if [[ -n "${2:-}" ]]; then
                save_token "$2"
            else
                prompt_for_token
            fi
            ;;
        "delete"|"remove"|"unset")
            delete_token
            ;;
        "status")
            show_token_status
            ;;
        "help"|"-h"|"--help"|*)
            echo "HuggingFace Token Manager"
            echo ""
            echo "Usage:"
            echo "  $0 get              Get current token (quiet)"
            echo "  $0 set [token]      Set token (prompt if not provided)"
            echo "  $0 delete           Delete all stored tokens"
            echo "  $0 status           Show token status from all sources"
            echo "  $0 help             Show this help"
            echo ""
            echo "Sources (in priority order):"
            echo "  1. Environment variable: HF_TOKEN"
            echo "  2. Kubernetes secret: llmapi/hf-token"
            echo "  3. Local config: ~/.config/llmapi/hf-token"
            ;;
    esac
fi
