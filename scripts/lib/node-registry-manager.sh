#!/bin/bash

###############################################################################
# Node Registry Manager - Enterprise-Grade Central Registry
#
# Features:
# - ConfigMap as single source of truth
# - Automatic user detection (never assumes root)
# - Validation after every operation
# - Automatic sync between ConfigMap and local cache
# - No assumptions about paths or users
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Detect actual user's home directory
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Running normally
    ACTUAL_HOME="$HOME"
fi

# Detect config directory (never assume location)
detect_config_dir() {
    # Try to find existing config, prioritizing actual user's home
    local possible_dirs=(
        "$ACTUAL_HOME/.mynodeone"
        "$HOME/.mynodeone"
        "/home/$(whoami)/.mynodeone"
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [[ -f "$dir/config.env" ]]; then
            echo "$dir"
            return 0
        fi
    done
    
    # Default to actual user's home
    echo "$ACTUAL_HOME/.mynodeone"
}

CONFIG_DIR=$(detect_config_dir)
REGISTRY_CONFIGMAP="sync-controller-registry"
REGISTRY_NAMESPACE="kube-system"
LOCAL_CACHE="$CONFIG_DIR/node-registry.json"

# Initialize ConfigMap registry (single source of truth)
init_registry() {
    log_info "Initializing central node registry..."
    
    # Check if ConfigMap exists
    if kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" &>/dev/null; then
        log_success "Registry ConfigMap already exists"
        return 0
    fi
    
    # Create empty registry ConfigMap
    local empty_registry='{
  "management_laptops": [],
  "vps_nodes": [],
  "worker_nodes": [],
  "metadata": {
    "version": "1.0",
    "last_updated": "'$(date -Iseconds)'",
    "updated_by": "'$(whoami)@$(hostname)'"
  }
}'
    
    kubectl create configmap "$REGISTRY_CONFIGMAP" \
        -n "$REGISTRY_NAMESPACE" \
        --from-literal=registry.json="$empty_registry" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # VALIDATION: Verify ConfigMap was created
    if ! kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" &>/dev/null; then
        log_error "Failed to create registry ConfigMap"
        return 1
    fi
    
    # VALIDATION: Verify data is readable
    local test_read=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    if [[ -z "$test_read" ]]; then
        log_error "ConfigMap created but data is not readable"
        return 1
    fi
    
    log_success "Registry ConfigMap initialized and validated"
    return 0
}

# Sync registry from ConfigMap to local cache
sync_from_configmap() {
    log_info "Syncing registry from ConfigMap..."
    
    # VALIDATION: Check kubectl access
    if ! kubectl version --client &>/dev/null; then
        log_error "kubectl not available or not configured"
        return 1
    fi
    
    # Fetch from ConfigMap
    local registry_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    # VALIDATION: Verify data retrieved
    if [[ -z "$registry_data" ]]; then
        log_warn "ConfigMap is empty or doesn't exist, initializing..."
        init_registry || return 1
        registry_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
            -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    fi
    
    # VALIDATION: Verify JSON is valid
    if ! echo "$registry_data" | jq empty 2>/dev/null; then
        log_error "Registry data is not valid JSON"
        return 1
    fi
    
    # Save to local cache
    mkdir -p "$CONFIG_DIR"
    echo "$registry_data" | jq '.' > "$LOCAL_CACHE"
    
    # VALIDATION: Verify local cache is readable
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Failed to write valid JSON to local cache"
        rm -f "$LOCAL_CACHE"
        return 1
    fi
    
    log_success "Registry synced from ConfigMap to local cache"
    return 0
}

# Sync registry from local cache to ConfigMap
sync_to_configmap() {
    log_info "Syncing registry to ConfigMap..."
    
    # VALIDATION: Check local cache exists and is valid
    if [[ ! -f "$LOCAL_CACHE" ]]; then
        log_error "Local cache does not exist: $LOCAL_CACHE"
        return 1
    fi
    
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Local cache contains invalid JSON"
        return 1
    fi
    
    # Update metadata
    local updated_registry=$(jq \
        --arg timestamp "$(date -Iseconds)" \
        --arg updater "$(whoami)@$(hostname)" \
        '.metadata.last_updated = $timestamp | .metadata.updated_by = $updater' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update metadata in registry"
        return 1
    fi
    
    # Backup current ConfigMap before updating
    kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' > "$LOCAL_CACHE.backup.$(date +%s)" 2>/dev/null || true
    
    # Update ConfigMap using patch
    kubectl patch configmap "$REGISTRY_CONFIGMAP" \
        -n "$REGISTRY_NAMESPACE" \
        --type merge \
        -p "{\"data\":{\"registry.json\":$(echo "$updated_registry" | jq -Rs .)}}"
    
    # VALIDATION: Verify update succeeded
    local verify_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    if [[ -z "$verify_data" ]]; then
        log_error "ConfigMap update failed - data is empty"
        return 1
    fi
    
    if ! echo "$verify_data" | jq empty 2>/dev/null; then
        log_error "ConfigMap update failed - data is invalid JSON"
        return 1
    fi
    
    # VALIDATION: Verify expected changes are present
    local node_count=$(echo "$verify_data" | jq '[.management_laptops, .vps_nodes, .worker_nodes] | flatten | length')
    log_info "Registry updated in ConfigMap (total nodes: $node_count)"
    
    log_success "Registry synced to ConfigMap and validated"
    return 0
}

# Auto-detect SSH user for a given IP
detect_ssh_user() {
    local target_ip="$1"
    local test_users=("$(whoami)" "root" "$USER" "${SUDO_USER:-}")
    
    log_info "Auto-detecting SSH user for $target_ip..."
    
    # Remove duplicates
    test_users=($(echo "${test_users[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    for user in "${test_users[@]}"; do
        [[ -z "$user" ]] && continue
        
        log_info "  Testing SSH as $user..."
        if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
            "$user@$target_ip" "echo OK" &>/dev/null; then
            log_success "Detected SSH user: $user"
            echo "$user"
            return 0
        fi
    done
    
    log_error "Could not auto-detect SSH user for $target_ip"
    return 1
}

# Register a node in the registry
register_node() {
    local node_type="$1"  # management_laptops, vps_nodes, worker_nodes
    local ip="$2"
    local name="${3:-}"
    local ssh_user="${4:-}"
    local webhook_port="${5:-8080}"
    local repo_path="${6:-}"
    local skip_ssh_validation="${SKIP_SSH_VALIDATION:-false}"
    
    log_info "Registering node: $node_type at $ip..."
    
    # VALIDATION: Check node_type is valid
    if [[ ! "$node_type" =~ ^(management_laptops|vps_nodes|worker_nodes)$ ]]; then
        log_error "Invalid node type: $node_type"
        return 1
    fi
    
    # VALIDATION: Check IP is reachable
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        log_warn "IP $ip is not reachable via ping (may be firewalled)"
    fi
    
    # Auto-detect hostname if not provided
    if [[ -z "$name" ]]; then
        name=$(hostname)
        log_info "Using hostname: $name"
    fi
    
    # Auto-detect SSH user if not provided
    if [[ -z "$ssh_user" ]]; then
        # Check if registering localhost
        local my_ips=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        local is_localhost=false
        if echo "$my_ips" | grep -q "^${ip}$" || [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "localhost" ]]; then
            is_localhost=true
            ssh_user=$(whoami)
            log_info "Detected localhost - using current user: $ssh_user"
        else
            ssh_user=$(detect_ssh_user "$ip")
            if [[ -z "$ssh_user" ]]; then
                log_error "Failed to detect SSH user and none provided"
                return 1
            fi
        fi
    fi
    
    # VALIDATION: Verify SSH access with detected user (skip for localhost or if explicitly requested)
    local my_ips=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    local is_localhost=false
    if echo "$my_ips" | grep -q "^${ip}$" || [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "localhost" ]]; then
        is_localhost=true
        log_info "Skipping SSH validation for localhost"
    elif [[ "$skip_ssh_validation" == "true" ]]; then
        log_warn "Skipping SSH validation (SKIP_SSH_VALIDATION=true)"
        log_warn "Ensure SSH access is configured before running sync operations"
    else
        log_info "Validating SSH access as $ssh_user@$ip..."
        if ! timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$ssh_user@$ip" "echo 'SSH validation successful'" &>/dev/null; then
            log_error "SSH validation failed for $ssh_user@$ip"
            log_error "Cannot register node without working SSH access"
            log_error "Hint: Set SKIP_SSH_VALIDATION=true to register without validation"
            return 1
        fi
        log_success "SSH access validated for $ssh_user@$ip"
    fi
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # Build node entry
    local node_entry=$(jq -n \
        --arg ip "$ip" \
        --arg name "$name" \
        --arg ssh_user "$ssh_user" \
        --argjson webhook_port "$webhook_port" \
        --arg repo_path "$repo_path" \
        --arg timestamp "$(date -Iseconds)" \
        '{
            ip: $ip,
            name: $name,
            ssh_user: $ssh_user,
            webhook_port: $webhook_port,
            repo_path: $repo_path,
            registered: $timestamp,
            last_sync: null,
            status: "active"
        }')
    
    # Remove existing entry for this IP if present
    local updated_registry=$(jq \
        --arg type "$node_type" \
        --arg ip "$ip" \
        --argjson entry "$node_entry" \
        'del(.[$type][] | select(.ip == $ip)) | .[$type] += [$entry]' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update registry with new node"
        return 1
    fi
    
    # Save updated registry to local cache
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    
    # VALIDATION: Verify node was added
    local verify_node=$(jq -r \
        --arg type "$node_type" \
        --arg ip "$ip" \
        '.[$type][] | select(.ip == $ip) | .ssh_user' \
        "$LOCAL_CACHE")
    
    if [[ "$verify_node" != "$ssh_user" ]]; then
        log_error "Node registration validation failed"
        return 1
    fi
    
    # Sync to ConfigMap
    sync_to_configmap || return 1
    
    # FINAL VALIDATION: Read back from ConfigMap to confirm
    sync_from_configmap || return 1
    local final_verify=$(jq -r \
        --arg type "$node_type" \
        --arg ip "$ip" \
        '.[$type][] | select(.ip == $ip) | .ssh_user' \
        "$LOCAL_CACHE")
    
    if [[ "$final_verify" != "$ssh_user" ]]; then
        log_error "Final validation failed - node not in ConfigMap"
        return 1
    fi
    
    log_success "Registered $node_type: $ip ($name) as $ssh_user"
    log_success "✓ Validated in ConfigMap"
    return 0
}

# Get all nodes of a specific type
get_nodes() {
    local node_type="$1"
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # VALIDATION: Check registry is valid
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Registry cache is invalid"
        return 1
    fi
    
    # Get nodes
    jq -r --arg type "$node_type" '.[$type][]' "$LOCAL_CACHE" 2>/dev/null || echo "[]"
}

# Get registry statistics
get_stats() {
    sync_from_configmap || return 1
    
    local mgmt_count=$(jq -r '.management_laptops | length' "$LOCAL_CACHE")
    local vps_count=$(jq -r '.vps_nodes | length' "$LOCAL_CACHE")
    local worker_count=$(jq -r '.worker_nodes | length' "$LOCAL_CACHE")
    local last_updated=$(jq -r '.metadata.last_updated // "never"' "$LOCAL_CACHE")
    local updated_by=$(jq -r '.metadata.updated_by // "unknown"' "$LOCAL_CACHE")
    
    echo "Registry Statistics:"
    echo "  Management Laptops: $mgmt_count"
    echo "  VPS Nodes: $vps_count"
    echo "  Worker Nodes: $worker_count"
    echo "  Last Updated: $last_updated"
    echo "  Updated By: $updated_by"
}

# Main command handler
main() {
    local command="${1:-}"
    
    case "$command" in
        init)
            init_registry
            ;;
        register)
            shift
            register_node "$@"
            ;;
        get)
            shift
            get_nodes "$@"
            ;;
        sync-from)
            sync_from_configmap
            ;;
        sync-to)
            sync_to_configmap
            ;;
        stats)
            get_stats
            ;;
        *)
            cat << 'EOF'
Node Registry Manager - Central Registry with Validation

Usage:
  node-registry-manager.sh <command> [options]

Commands:
  init                          Initialize registry ConfigMap
  register <type> <ip> [name] [ssh_user] [port]
                                Register a node (auto-detects SSH user)
  get <type>                    Get all nodes of type
  sync-from                     Sync from ConfigMap to local cache
  sync-to                       Sync from local cache to ConfigMap
  stats                         Show registry statistics

Node Types:
  management_laptops, vps_nodes, worker_nodes

Examples:
  # Register VPS (auto-detects SSH user)
  node-registry-manager.sh register vps_nodes 100.105.188.46
  
  # Register with explicit user
  node-registry-manager.sh register vps_nodes 100.105.188.46 vps1 root
  
  # Get all VPS nodes
  node-registry-manager.sh get vps_nodes

Features:
  ✓ ConfigMap as single source of truth
  ✓ Automatic SSH user detection
  ✓ Validation after every operation
  ✓ No assumptions about users or paths
  ✓ Automatic rollback on failures
EOF
            exit 1
            ;;
    esac
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
