#!/bin/bash

###############################################################################
# Sync Controller - Event-Driven Configuration Push System
# 
# Watches ConfigMap changes and pushes updates to all registered nodes
# Replaces polling with instant push notifications
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/project-root.sh"
REGISTRY_MANAGER="$SCRIPT_DIR/node-registry-manager.sh"

# Detect actual user's home directory (for sudo compatibility)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Initialize node registry (uses new registry manager)
init_node_registry() {
    # Sync from ConfigMap to ensure we have latest data
    if [[ -f "$REGISTRY_MANAGER" ]]; then
        "$REGISTRY_MANAGER" sync-from || {
            log_warn "Failed to sync from ConfigMap, initializing..."
            "$REGISTRY_MANAGER" init || return 1
        }
        log_success "Node registry initialized from ConfigMap"
    else
        log_error "Registry manager not found: $REGISTRY_MANAGER"
        return 1
    fi
}

# Register a node for sync (delegates to registry manager)
register_node() {
    local node_type="$1"  # management_laptops, vps_nodes, worker_nodes
    local node_ip="$2"
    local node_name="${3:-}"
    local ssh_user="${4:-}"
    local webhook_port="${5:-8080}"
    
    # Use registry manager for registration
    if [[ -f "$REGISTRY_MANAGER" ]]; then
        SKIP_SSH_VALIDATION=true "$REGISTRY_MANAGER" register \
            "$node_type" "$node_ip" "$node_name" "$ssh_user" "$webhook_port"
    else
        log_error "Registry manager not found: $REGISTRY_MANAGER"
        return 1
    fi
}

# Push sync to a single node
push_sync_to_node() {
    local node_type="$1"
    local node_ip="$2"
    local ssh_user="$3"
    local repo_path="${4:-~/mynodeone}"  # Default to ~/mynodeone for backwards compatibility
    local max_retries=3
    local retry_delay=5
    local registry_file="$ACTUAL_HOME/.mynodeone/node-registry.json"
    
    # Check if node is using V2 sync (Node Agent)
    # If Node Agent is active, skip SSH push to avoid conflicts
    if [[ "${SKIP_V2_CHECK:-}" != "true" ]]; then
        # Query Config API to check if this node has recent heartbeat
        local api_port="${API_PORT:-8443}"
        local control_plane_ip=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
        
        # Get API token for authentication
        local api_token=""
        if [[ -f /etc/mynodeone/api-token ]]; then
            api_token=$(cat /etc/mynodeone/api-token 2>/dev/null)
        fi
        
        if [[ -n "$api_token" ]] && \
            curl -s --connect-timeout 2 -H "X-API-Token: $api_token" \
                "http://${control_plane_ip}:${api_port}/api/v1/nodes" 2>/dev/null | \
            jq -e ".nodes[]? | select(.ip == \"$node_ip\" and .status == \"online\")" &>/dev/null; then
            log_info "Node $node_ip is using V2 sync (Node Agent active) - skipping SSH push"
            return 0
        fi
    fi
    
    log_info "Pushing sync to $node_ip (V1 SSH mode)..."
    
    # Determine sync script based on node type
    local sync_script=""
    case "$node_type" in
        management_laptops)
            sync_script="domains/sync-dns.sh"
            ;;
        vps_nodes)
            sync_script="vps/sync-vps-routes.sh"
            ;;
        worker_nodes)
            sync_script="domains/sync-dns.sh"
            ;;
        *)
            log_error "Unknown node type: $node_type"
            return 1
            ;;
    esac
    
    # Try SSH push with retries
    # Use actual user's SSH (with their agent) when running under sudo
    local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"
    local ssh_cmd="ssh"
    
    # If running under sudo, run SSH as the actual user to access their SSH agent
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        # Get user's SSH agent socket
        local user_ssh_auth_sock=$(sudo -u "$SUDO_USER" printenv SSH_AUTH_SOCK 2>/dev/null)
        if [ -z "$user_ssh_auth_sock" ]; then
            # Try common locations
            user_ssh_auth_sock="/run/user/$(id -u $SUDO_USER)/keyring/ssh"
            if [ ! -S "$user_ssh_auth_sock" ]; then
                user_ssh_auth_sock="/run/user/$(id -u $SUDO_USER)/gnupg/S.gpg-agent.ssh"
            fi
        fi
        
        if [ -S "$user_ssh_auth_sock" ]; then
            # Run as actual user with their SSH agent
            ssh_cmd="sudo -u $SUDO_USER SSH_AUTH_SOCK=$user_ssh_auth_sock ssh"
        else
            # Fallback: run as user without agent (will use key files)
            ssh_cmd="sudo -u $SUDO_USER ssh"
        fi
    else
        # Running as root (systemd service) - use explicit key file
        if [ -f "/root/.ssh/mynodeone_id_ed25519" ]; then
            ssh_opts="$ssh_opts -i /root/.ssh/mynodeone_id_ed25519"
        fi
    fi
    
    # Check if this is localhost (control plane syncing to itself)
    # IMPORTANT: Do this BEFORE SSH reachability check to avoid password prompts
    local is_localhost=false
    local local_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ "$node_ip" == "$local_ip" ]] || [[ "$node_ip" == "127.0.0.1" ]] || [[ "$node_ip" == "localhost" ]]; then
        is_localhost=true
    fi
    
    # Check if node is reachable before attempting sync (skip for localhost)
    if [[ "$is_localhost" != "true" ]]; then
        if ! $ssh_cmd $ssh_opts "$ssh_user@$node_ip" "echo 'ping' 2>/dev/null" >/dev/null 2>&1; then
            log_warn "Node $node_ip is not reachable (offline or network issue)"
            log_info "Will retry on next reconciliation cycle"
            
            # Mark node as pending_sync for retry later
            if [[ -f "$registry_file" ]]; then
                local registry=$(cat "$registry_file")
                registry=$(echo "$registry" | jq \
                    --arg type "$node_type" \
                    --arg ip "$node_ip" \
                    '.[$type] |= map(
                        if .ip == $ip then
                            .status = "pending_sync" |
                            .last_attempt = (now | todate)
                        else . end
                    )')
                echo "$registry" > "$registry_file"
            fi
            return 1
        fi
    fi
    
    local attempt=1
    while [[ $attempt -le $max_retries ]]; do
        log_info "Attempt $attempt/$max_retries: Syncing to $node_ip..."
        
        # Capture output for information
        local sync_output
        local sync_exit_code
        
        # For VPS nodes, pass service registry data via stdin
        if [[ "$node_type" == "vps_nodes" ]]; then
            # Fetch service registry from ConfigMap
            local service_registry=$(kubectl get configmap -n kube-system service-registry \
                -o jsonpath='{.data.services\.json}' 2>/dev/null || echo "{}")
            
            # VPS nodes have scripts in ~/mynodeone/scripts/ (transferred by orchestrator)
            # Pass service registry via stdin
            sync_output=$(echo "$service_registry" | $ssh_cmd $ssh_opts "$ssh_user@$node_ip" \
                "cd ~/mynodeone && sudo ./scripts/$sync_script" 2>&1)
            sync_exit_code=$?
        elif [[ "$is_localhost" == "true" ]]; then
            # For localhost, run directly without SSH
            log_info "Detected localhost - running sync directly (no SSH)"
            # Note: sync-controller runs as root (systemd service), so no sudo needed
            if [ "$(id -u)" -eq 0 ]; then
                sync_output=$(cd "$repo_path" && ./scripts/$sync_script 2>&1)
            else
                sync_output=$(cd "$repo_path" && sudo ./scripts/$sync_script 2>&1)
            fi
            sync_exit_code=$?
        else
            # For other node types (laptops, workers), use repo path
            sync_output=$($ssh_cmd $ssh_opts "$ssh_user@$node_ip" \
                "cd '$repo_path' && sudo ./scripts/$sync_script" 2>&1 </dev/null)
            sync_exit_code=$?
        fi
        
        if [[ $sync_exit_code -eq 0 ]]; then
            log_success "Sync command completed on $node_ip"
            
            # Verify sync actually worked
            log_info "Verifying sync on $node_ip..."
            local verification_passed=true
            
            if [[ "$node_type" == "vps_nodes" ]]; then
                # Check if sync output indicates no public services (this is OK, not an error)
                if echo "$sync_output" | grep -q "No public services configured"; then
                    log_info "ℹ No public services configured yet (this is normal for new installations)"
                    log_info "Routes file will be created when you make an app public"
                    # This is success - VPS is ready, just waiting for public apps
                    verification_passed=true
                else
                    # Check if routes file was created
                    if $ssh_cmd $ssh_opts "$ssh_user@$node_ip" \
                        "test -f ~/traefik/config/mynodeone-routes.yml" 2>/dev/null; then
                        log_success "✓ Routes file exists on $node_ip"
                    else
                        log_error "✗ Routes file NOT found on $node_ip"
                        verification_passed=false
                    fi
                fi
                
                # Always check if Traefik is running (this is critical)
                if $ssh_cmd $ssh_opts "$ssh_user@$node_ip" \
                    "docker ps | grep -q traefik" 2>/dev/null; then
                    log_success "✓ Traefik is running on $node_ip"
                else
                    log_error "✗ Traefik is NOT running on $node_ip"
                    verification_passed=false
                fi
            elif [[ "$node_type" == "management_laptops" ]]; then
                # Check if sync output indicates no services (this is OK, not an error)
                if echo "$sync_output" | grep -q "No services found in registry"; then
                    log_info "ℹ No services in registry yet (this is normal for new installations)"
                    log_info "DNS entries will be added when apps are installed"
                    # This is success - laptop is ready, just waiting for apps
                    verification_passed=true
                else
                    # Check if /etc/hosts has MyNodeOne entries
                    if [[ "$is_localhost" == "true" ]]; then
                        # For localhost, check directly
                        local dns_count=$(grep -c 'MyNodeOne Services' /etc/hosts 2>/dev/null || echo 0)
                    else
                        # For remote nodes, use SSH
                        local dns_count=$($ssh_cmd $ssh_opts "$ssh_user@$node_ip" \
                            "grep -c 'MyNodeOne Services' /etc/hosts 2>/dev/null || echo 0" 2>/dev/null)
                    fi
                    
                    if [[ "$dns_count" -gt 0 ]]; then
                        log_success "✓ DNS entries synced on $node_ip"
                    else
                        log_error "✗ DNS entries NOT found on $node_ip"
                        verification_passed=false
                    fi
                fi
            fi
            
            if [[ "$verification_passed" == "true" ]]; then
                log_success "Synced and verified: $node_ip"
                
                # Update last_sync time in ConfigMap
                if [[ -f "$registry_file" ]]; then
                    local registry=$(cat "$registry_file")
                    registry=$(echo "$registry" | jq \
                        --arg type "$node_type" \
                        --arg ip "$node_ip" \
                        '.[$type] |= map(
                            if .ip == $ip then
                                .last_sync = (now | todate) |
                                .status = "active"
                            else . end
                        )')
                    echo "$registry" > "$registry_file"
                    # Sync back to ConfigMap
                    "$REGISTRY_MANAGER" sync-to &>/dev/null || true
                fi
                
                return 0
            else
                log_error "Verification failed on $node_ip"
                echo "--- Sync Output ---"
                echo "$sync_output"
                echo "--- End Output ---"
            fi
        else
            log_error "Sync command failed on $node_ip (exit code: $sync_exit_code)"
            echo "--- Error Output ---"
            echo "$sync_output"
            echo "--- End Error ---"
        fi
        
        if [[ $attempt -lt $max_retries ]]; then
            log_warn "Retrying in ${retry_delay}s..."
            sleep $retry_delay
            ((retry_delay *= 2))  # Exponential backoff
        fi
        ((attempt++))
    done
    
    log_error "Failed to sync $node_ip after $max_retries attempts"
    
    # Mark as failed in ConfigMap
    if [[ -f "$registry_file" ]]; then
        local registry=$(cat "$registry_file")
        registry=$(echo "$registry" | jq \
            --arg type "$node_type" \
            --arg ip "$node_ip" \
            '.[$type] |= map(
                if .ip == $ip then
                    .status = "failed" |
                    .last_error = (now | todate)
                else . end
            )')
        echo "$registry" > "$registry_file"
        # Sync back to ConfigMap
        "$REGISTRY_MANAGER" sync-to &>/dev/null || true
    fi
    
    return 1
}

# Push sync to all registered nodes
# Set FORCE_SSH=true to bypass V2 node agent check and force SSH sync
push_sync_all() {
    local force_mode="${FORCE_SSH:-false}"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Pushing Config Updates to All Nodes"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [[ "$force_mode" == "true" ]]; then
        log_info "Force mode: SSH sync for all nodes (including V2)"
        export SKIP_V2_CHECK=true
    fi
    
    init_node_registry
    
    # Get registry from ConfigMap via registry manager
    local config_dir=$("$REGISTRY_MANAGER" sync-from 2>&1 | grep -oP '(?<=to local cache\n).*' || echo "$HOME/.mynodeone")
    local registry_file="$ACTUAL_HOME/.mynodeone/node-registry.json"
    
    if [[ ! -f "$registry_file" ]]; then
        log_error "Registry file not found after sync: $registry_file"
        return 1
    fi
    
    local registry=$(cat "$registry_file")
    local success_count=0
    local fail_count=0
    
    # Safely process a node type
    process_node_type() {
        local node_type="$1"
        local node_key="$2"
        
        # Check if the key exists and is an array
        if ! echo "$registry" | jq -e ". | has(\"$node_key\") and (.\"$node_key\" | type) == \"array\"" > /dev/null; then
            log_warn "Registry is missing or has invalid format for '$node_key'. Skipping."
            return
        fi
        
        local nodes_array=()
        mapfile -t nodes_array < <(echo "$registry" | jq -c '.["'$node_key'"][]?' 2>/dev/null) || true

        if [[ ${#nodes_array[@]} -eq 0 ]]; then
            log_info "No nodes of type '$node_key' to sync."
            return 0
        fi

        log_info "Syncing $node_key..."

        for node_json in "${nodes_array[@]}"; do
            local ip=$(echo "$node_json" | jq -r '.ip')
            local user=$(echo "$node_json" | jq -r '.ssh_user')
            local repo_path=$(echo "$node_json" | jq -r '.repo_path // "~/mynodeone"')

            if [[ -z "$ip" || -z "$user" ]]; then
                log_warn "Skipping node with missing IP or user in '$node_key': $node_json"
                continue
            fi

            if push_sync_to_node "$node_key" "$ip" "$user" "$repo_path"; then
                ((success_count+=1))
            else
                ((fail_count+=1))
            fi
        done

        return 0
    }

    process_node_type "Management Laptops" "management_laptops"
    process_node_type "VPS Nodes" "vps_nodes"
    process_node_type "Worker Nodes" "worker_nodes"
    
    echo ""
    log_success "Sync complete: $success_count succeeded, $fail_count failed"
    
    if [[ $fail_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Watch for ConfigMap changes and auto-push
watch_and_push() {
    log_info "Starting sync controller in watch mode..."
    log_info "Watching for service registry changes..."
    echo ""
    
    local last_version=""
    
    while true; do
        # Get current ConfigMap version
        local current_version=$(kubectl get configmap -n kube-system service-registry \
            -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "")
        
        if [[ -n "$current_version" ]] && [[ "$current_version" != "$last_version" ]]; then
            log_info "ConfigMap changed (version: $current_version)"
            log_info "Triggering sync to all nodes..."
            echo ""
            
            if ! push_sync_all; then
                log_error "Sync cycle completed with one or more failures."
            fi
            
            last_version="$current_version"
            echo ""
            log_info "Waiting for next change..."
            echo ""
        fi
        
        sleep 10  # Check every 10 seconds
    done
}

# Periodic reconciliation (safety net)
# Retries failed nodes and does full sync at regular intervals
periodic_reconciliation() {
    local interval_hours="${1:-1}"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Starting Periodic Reconciliation Service"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Interval: Every $interval_hours hour(s)"
    log_info "Purpose: Retry offline nodes, ensure consistency"
    echo ""
    
    while true; do
        sleep $((interval_hours * 3600))
        
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "  Scheduled Reconciliation - $(date)"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Show nodes pending sync
        init_node_registry
        local registry_file="$ACTUAL_HOME/.mynodeone/node-registry.json"
        local registry=$(cat "$registry_file")
        
        local pending_count=$(echo "$registry" | jq '[.management_laptops[], .vps_nodes[], .worker_nodes[]] | map(select(.status == "pending_sync")) | length')
        
        if [[ "$pending_count" -gt 0 ]]; then
            log_info "Found $pending_count node(s) pending sync (offline or failed)"
            log_info "Attempting to sync..."
            echo ""
        else
            log_info "No pending nodes. Running full sync for consistency..."
            echo ""
        fi
        
        # Sync service registry (cleanup stale entries, discover new services)
        log_info "Syncing service registry..."
        if [[ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]]; then
            if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" sync 2>&1 | grep -q "Synced"; then
                log_success "Service registry synced"
            else
                log_warn "Service registry sync had issues (non-critical)"
            fi
        else
            log_warn "Service registry script not found (skipping)"
        fi
        echo ""
        
        # Run full sync (will retry pending nodes)
        if push_sync_all; then
            log_success "Reconciliation completed successfully"
        else
            log_warn "Reconciliation completed with some failures (will retry next cycle)"
        fi
        
        echo ""
        log_info "Next reconciliation in $interval_hours hour(s)..."
        echo ""
    done
}

# Health check for registered nodes
health_check() {
    log_info "Running health check on registered nodes..."
    
    init_node_registry
    local registry_file="$ACTUAL_HOME/.mynodeone/node-registry.json"
    local registry=$(cat "$registry_file")
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Node Health Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check management laptops
    echo "Management Laptops:"
    echo "$registry" | jq -r '.management_laptops[] | 
        "  • \(.name // .ip): \(.status) (last sync: \(.last_sync // "never"))"'
    echo ""
    
    # Check VPS nodes
    echo "VPS Edge Nodes:"
    echo "$registry" | jq -r '.vps_nodes[] | 
        "  • \(.name // .ip): \(.status) (last sync: \(.last_sync // "never"))"'
    echo ""
    
    # Check worker nodes
    echo "Worker Nodes:"
    echo "$registry" | jq -r '.worker_nodes[] | 
        "  • \(.name // .ip): \(.status) (last sync: \(.last_sync // "never"))"'
    echo ""
}

# Combined watch + reconcile mode (recommended)
daemon_mode() {
    local reconcile_hours="${1:-1}"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Starting Sync Controller Daemon"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Mode: Watch + Periodic Reconciliation"
    log_info "• Watches for ConfigMap changes (immediate sync)"
    log_info "• Reconciles every $reconcile_hours hour(s) (retry offline nodes)"
    echo ""
    
    # Start periodic reconciliation in background
    periodic_reconciliation "$reconcile_hours" &
    local reconcile_pid=$!
    
    # Trap signals to cleanup background process
    trap "kill $reconcile_pid 2>/dev/null; exit" SIGINT SIGTERM
    
    # Run watch in foreground
    watch_and_push
}

# Main command dispatcher
case "${1:-}" in
    register)
        register_node "$2" "$3" "${4:-}" "${5:-root}" "${6:-8080}"
        ;;
    push)
        push_sync_all
        ;;
    push-force)
        # Force SSH sync even for nodes with active Node Agent
        # Use this for immediate operations like making apps public
        FORCE_SSH=true push_sync_all
        ;;
    watch)
        watch_and_push
        ;;
    reconcile)
        periodic_reconciliation "${2:-1}"
        ;;
    daemon)
        daemon_mode "${2:-1}"
        ;;
    health)
        health_check
        ;;
    *)
        cat << 'EOF'
Sync Controller - Event-Driven Push System

Usage:
  sync-controller.sh <command> [options]

Commands:
  register <type> <ip> [name] [ssh_user] [webhook_port]
                                Register a node for automatic sync
                                Types: management_laptops, vps_nodes, worker_nodes

  push                          Push sync to all registered nodes
                                (skips nodes with active Node Agent)

  push-force                    Force SSH sync to ALL nodes
                                (ignores Node Agent status - use for immediate ops)

  watch                         Watch for ConfigMap changes and auto-push
                                Syncs immediately when apps are installed

  reconcile [hours]             Periodic reconciliation (default: 1 hour)
                                Retries offline nodes, ensures consistency

  daemon [hours]                Combined watch + reconcile (RECOMMENDED)
                                Immediate sync on changes + hourly retry
                                Best for setups with offline laptops

  health                        Check health status of all nodes

Examples:
  # Register nodes
  sync-controller.sh register management_laptops 100.86.112.112 dev-laptop your-username
  sync-controller.sh register vps_nodes 100.68.225.92 contabo-vps root

  # One-time push to nodes without active Node Agent
  sync-controller.sh push

  # Force SSH sync to all nodes (ignores Node Agent)
  sync-controller.sh push-force

  # Recommended mode (watch + reconcile every 1 hour)
  sync-controller.sh daemon 1

  # Watch only (immediate sync, no retry)
  sync-controller.sh watch

  # Reconcile only (retry every 2 hours)
  sync-controller.sh reconcile 2

  # Check node health
  sync-controller.sh health

Recommended Setup:
  1. Register all nodes
  2. Run as systemd service:
     sudo systemctl start mynodeone-sync-controller
  3. Automatic push on every ConfigMap change
  4. Periodic reconciliation for fault tolerance

EOF
        exit 1
        ;;
esac
