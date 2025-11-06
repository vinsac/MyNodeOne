#!/bin/bash

###############################################################################
# Sync Controller - Enterprise-Grade Event-Driven Push System
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.mynodeone"
NODE_REGISTRY="$CONFIG_DIR/node-registry.json"

# Initialize node registry
init_node_registry() {
    mkdir -p "$CONFIG_DIR"
    
    if [[ ! -f "$NODE_REGISTRY" ]]; then
        cat > "$NODE_REGISTRY" << 'EOF'
{
  "management_laptops": [],
  "vps_nodes": [],
  "worker_nodes": []
}
EOF
        log_success "Node registry initialized"
    fi
}

# Register a node for sync
register_node() {
    local node_type="$1"  # management_laptops, vps_nodes, worker_nodes
    local node_ip="$2"
    local node_name="${3:-}"
    local ssh_user="${4:-root}"
    local webhook_port="${5:-8080}"
    
    init_node_registry
    
    local registry=$(cat "$NODE_REGISTRY")
    
    # Add node if not exists
    registry=$(echo "$registry" | jq \
        --arg type "$node_type" \
        --arg ip "$node_ip" \
        --arg name "$node_name" \
        --arg user "$ssh_user" \
        --arg port "$webhook_port" \
        '.[$type] |= (
            if any(.ip == $ip) then
                map(if .ip == $ip then {
                    ip: $ip,
                    name: $name,
                    ssh_user: $user,
                    webhook_port: ($port | tonumber),
                    registered: now | todate,
                    last_sync: null,
                    status: "active"
                } else . end)
            else
                . + [{
                    ip: $ip,
                    name: $name,
                    ssh_user: $user,
                    webhook_port: ($port | tonumber),
                    registered: now | todate,
                    last_sync: null,
                    status: "active"
                }]
            end
        )')
    
    echo "$registry" > "$NODE_REGISTRY"
    log_success "Registered $node_type: $node_ip ($node_name)"
}

# Push sync to a single node
push_sync_to_node() {
    local node_type="$1"
    local node_ip="$2"
    local ssh_user="$3"
    local max_retries=3
    local retry_delay=5
    
    log_info "Pushing sync to $node_ip..."
    
    # Determine sync script based on node type
    local sync_script=""
    case "$node_type" in
        management_laptops)
            sync_script="sync-dns.sh"
            ;;
        vps_nodes)
            sync_script="sync-vps-routes.sh"
            ;;
        worker_nodes)
            sync_script="sync-dns.sh"
            ;;
        *)
            log_error "Unknown node type: $node_type"
            return 1
            ;;
    esac
    
    # Try SSH push with retries
    local attempt=1
    while [[ $attempt -le $max_retries ]]; do
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$ssh_user@$node_ip" \
            "cd ~/MyNodeOne && sudo ./scripts/$sync_script" &>/dev/null; then
            log_success "Synced: $node_ip"
            
            # Update last_sync time
            local registry=$(cat "$NODE_REGISTRY")
            registry=$(echo "$registry" | jq \
                --arg type "$node_type" \
                --arg ip "$node_ip" \
                '.[$type] |= map(
                    if .ip == $ip then
                        .last_sync = (now | todate) |
                        .status = "active"
                    else . end
                )')
            echo "$registry" > "$NODE_REGISTRY"
            
            return 0
        else
            log_warn "Attempt $attempt/$max_retries failed for $node_ip"
            if [[ $attempt -lt $max_retries ]]; then
                sleep $retry_delay
                ((retry_delay *= 2))  # Exponential backoff
            fi
        fi
        ((attempt++))
    done
    
    log_error "Failed to sync $node_ip after $max_retries attempts"
    
    # Mark as failed
    local registry=$(cat "$NODE_REGISTRY")
    registry=$(echo "$registry" | jq \
        --arg type "$node_type" \
        --arg ip "$node_ip" \
        '.[$type] |= map(
            if .ip == $ip then
                .status = "failed" |
                .last_error = (now | todate)
            else . end
        )')
    echo "$registry" > "$NODE_REGISTRY"
    
    return 1
}

# Push sync to all registered nodes
push_sync_all() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Pushing Config Updates to All Nodes"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    init_node_registry
    
    local registry=$(cat "$NODE_REGISTRY")
    local success_count=0
    local fail_count=0
    
    # Push to management laptops
    local laptops=$(echo "$registry" | jq -r '.management_laptops[] | @json')
    if [[ -n "$laptops" ]]; then
        log_info "Syncing management laptops..."
        while IFS= read -r node; do
            local ip=$(echo "$node" | jq -r '.ip')
            local user=$(echo "$node" | jq -r '.ssh_user')
            
            if push_sync_to_node "management_laptops" "$ip" "$user"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done <<< "$laptops"
    fi
    
    # Push to VPS nodes
    local vps=$(echo "$registry" | jq -r '.vps_nodes[] | @json')
    if [[ -n "$vps" ]]; then
        log_info "Syncing VPS nodes..."
        while IFS= read -r node; do
            local ip=$(echo "$node" | jq -r '.ip')
            local user=$(echo "$node" | jq -r '.ssh_user')
            
            if push_sync_to_node "vps_nodes" "$ip" "$user"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done <<< "$vps"
    fi
    
    # Push to worker nodes
    local workers=$(echo "$registry" | jq -r '.worker_nodes[] | @json')
    if [[ -n "$workers" ]]; then
        log_info "Syncing worker nodes..."
        while IFS= read -r node; do
            local ip=$(echo "$node" | jq -r '.ip')
            local user=$(echo "$node" | jq -r '.ssh_user')
            
            if push_sync_to_node "worker_nodes" "$ip" "$user"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        done <<< "$workers"
    fi
    
    echo ""
    log_success "Sync complete: $success_count succeeded, $fail_count failed"
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
            
            push_sync_all
            
            last_version="$current_version"
            echo ""
            log_info "Waiting for next change..."
            echo ""
        fi
        
        sleep 10  # Check every 10 seconds
    done
}

# Periodic reconciliation (safety net)
periodic_reconciliation() {
    local interval_hours="${1:-1}"
    
    log_info "Starting periodic reconciliation (every $interval_hours hour(s))..."
    
    while true; do
        sleep $((interval_hours * 3600))
        
        log_info "Running scheduled reconciliation..."
        push_sync_all
    done
}

# Health check for registered nodes
health_check() {
    log_info "Running health check on registered nodes..."
    
    init_node_registry
    local registry=$(cat "$NODE_REGISTRY")
    
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

# Main command dispatcher
case "${1:-}" in
    register)
        register_node "$2" "$3" "${4:-}" "${5:-root}" "${6:-8080}"
        ;;
    push)
        push_sync_all
        ;;
    watch)
        watch_and_push
        ;;
    reconcile)
        periodic_reconciliation "${2:-1}"
        ;;
    health)
        health_check
        ;;
    *)
        cat << 'EOF'
Sync Controller - Enterprise Event-Driven Push System

Usage:
  sync-controller.sh <command> [options]

Commands:
  register <type> <ip> [name] [ssh_user] [webhook_port]
                                Register a node for automatic sync
                                Types: management_laptops, vps_nodes, worker_nodes

  push                          Immediately push sync to all registered nodes

  watch                         Watch for ConfigMap changes and auto-push
                                (Run as systemd service for production)

  reconcile [hours]             Periodic reconciliation (default: 1 hour)
                                Safety net for missed events

  health                        Check health status of all nodes

Examples:
  # Register nodes
  sync-controller.sh register management_laptops 100.86.112.112 vinay-laptop vinaysachdeva
  sync-controller.sh register vps_nodes 100.68.225.92 contabo-vps root

  # One-time push to all nodes
  sync-controller.sh push

  # Watch for changes (production mode)
  sync-controller.sh watch

  # Run reconciliation every 4 hours
  sync-controller.sh reconcile 4

  # Check node health
  sync-controller.sh health

Production Setup:
  1. Register all nodes
  2. Run as systemd service:
     sudo systemctl start mynodeone-sync-controller
  3. Automatic push on every ConfigMap change
  4. Periodic reconciliation for fault tolerance

EOF
        exit 1
        ;;
esac
