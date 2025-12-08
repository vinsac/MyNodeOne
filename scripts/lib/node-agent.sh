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
###############################################################################

set -euo pipefail

# Colors for logging
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Load configuration
load_config() {
    local config_file="${AGENT_CONFIG_FILE:-/etc/mynodeone/agent.env}"
    
    if [[ -f "$config_file" ]]; then
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
    
    # Validate required config
    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        log_error "CONTROL_PLANE_IP is required"
        exit 1
    fi
}

# Build API URL
get_api_url() {
    local endpoint="$1"
    echo "http://${CONTROL_PLANE_IP}:${API_PORT}${endpoint}"
}

# Build auth header
get_auth_header() {
    if [[ -n "$API_TOKEN" ]]; then
        echo "-H X-API-Token: $API_TOKEN"
    fi
}

# Fetch config from control plane
fetch_config() {
    local url
    url=$(get_api_url "/api/v1/config/${NODE_TYPE}")
    
    local response
    local http_code
    
    # Make request with optional auth header
    if [[ -n "$API_TOKEN" ]]; then
        response=$(curl -s -w "\n%{http_code}" \
            -H "X-API-Token: $API_TOKEN" \
            -H "X-Node-Name: $NODE_NAME" \
            "$url" 2>/dev/null) || true
    else
        response=$(curl -s -w "\n%{http_code}" \
            -H "X-Node-Name: $NODE_NAME" \
            "$url" 2>/dev/null) || true
    fi
    
    # Extract HTTP code (last line)
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" != "200" ]]; then
        log_error "Failed to fetch config: HTTP $http_code"
        return 1
    fi
    
    echo "$response"
}

# Send heartbeat to control plane
send_heartbeat() {
    local url
    url=$(get_api_url "/api/v1/heartbeat")
    
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
    
    local payload
    payload=$(cat <<EOF
{
    "node_name": "$NODE_NAME",
    "node_type": "$NODE_TYPE",
    "node_ip": "$(get_tailscale_ip)",
    "config_version": "${CURRENT_CONFIG_VERSION:-unknown}",
    "uptime_seconds": $uptime_seconds
}
EOF
)
    
    local http_code
    if [[ -n "$API_TOKEN" ]]; then
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "X-API-Token: $API_TOKEN" \
            -d "$payload" \
            "$url" 2>/dev/null) || true
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$url" 2>/dev/null) || true
    fi
    
    if [[ "$http_code" == "200" ]]; then
        log_success "Heartbeat sent"
        return 0
    else
        log_warn "Heartbeat failed: HTTP $http_code"
        return 1
    fi
}

# Get Tailscale IP
get_tailscale_ip() {
    tailscale ip -4 2>/dev/null || echo "unknown"
}

# Apply DNS config (for laptops and workers)
apply_dns_config() {
    local config="$1"
    
    # Extract DNS entries
    local entries
    entries=$(echo "$config" | jq -r '.dns_entries[]? | "\(.ip) \(.name).mynodeone.local \(.name)"' 2>/dev/null)
    
    if [[ -z "$entries" ]]; then
        log_info "No DNS entries to apply"
        return 0
    fi
    
    # Backup current hosts file
    local hosts_file="/etc/hosts"
    local backup_file="/etc/hosts.mynodeone.bak"
    
    if [[ ! -f "$backup_file" ]]; then
        cp "$hosts_file" "$backup_file"
    fi
    
    # Remove old MyNodeOne entries
    local temp_file
    temp_file=$(mktemp)
    grep -v "# MyNodeOne" "$hosts_file" | grep -v ".mynodeone.local" > "$temp_file" || true
    
    # Add new entries
    echo "" >> "$temp_file"
    echo "# MyNodeOne DNS entries (managed by node-agent)" >> "$temp_file"
    echo "$entries" >> "$temp_file"
    
    # Apply changes
    if [[ "$(id -u)" -eq 0 ]]; then
        mv "$temp_file" "$hosts_file"
    else
        sudo mv "$temp_file" "$hosts_file"
    fi
    
    local count
    count=$(echo "$entries" | wc -l)
    log_success "Applied $count DNS entries to /etc/hosts"
}

# Apply Traefik routes (for VPS nodes)
apply_vps_config() {
    local config="$1"
    
    # Extract routes
    local routes
    routes=$(echo "$config" | jq -r '.routes[]?' 2>/dev/null)
    
    if [[ -z "$routes" ]]; then
        log_info "No routes to apply"
        return 0
    fi
    
    # Generate Traefik dynamic config
    local traefik_config_dir="${TRAEFIK_CONFIG_DIR:-$HOME/traefik/config}"
    local routes_file="$traefik_config_dir/mynodeone-routes.yml"
    
    mkdir -p "$traefik_config_dir"
    
    # Generate YAML
    cat > "$routes_file" <<EOF
# MyNodeOne Routes (managed by node-agent)
# Generated: $(date -Iseconds)

http:
  routers:
EOF

    # Add routers
    echo "$config" | jq -r '.routes[]? | "    \(.service):
      rule: \"Host(\`\(.domain)\`)\"
      service: \(.service)
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt"' >> "$routes_file"

    # Add services
    cat >> "$routes_file" <<EOF

  services:
EOF

    echo "$config" | jq -r '.routes[]? | "    \(.service):
      loadBalancer:
        servers:
          - url: \"http://\(.backend)\""' >> "$routes_file"

    log_success "Generated Traefik routes: $routes_file"
    
    # Reload Traefik if running
    if command -v docker &>/dev/null && docker ps | grep -q traefik; then
        # Traefik watches config files, no reload needed
        log_info "Traefik will auto-reload config"
    fi
}

# Apply config based on node type
apply_config() {
    local config="$1"
    
    case "$NODE_TYPE" in
        laptop|worker)
            apply_dns_config "$config"
            ;;
        vps)
            apply_vps_config "$config"
            ;;
        *)
            log_error "Unknown node type: $NODE_TYPE"
            return 1
            ;;
    esac
}

# Main agent loop
run_agent() {
    log_info "Starting MyNodeOne Node Agent"
    log_info "Node: $NODE_NAME ($NODE_TYPE)"
    log_info "Control Plane: $CONTROL_PLANE_IP:$API_PORT"
    log_info "Poll interval: ${POLL_INTERVAL}s"
    
    local last_config_version=""
    local heartbeat_counter=0
    
    while true; do
        # Fetch config
        local config
        if config=$(fetch_config); then
            # Extract version
            local new_version
            new_version=$(echo "$config" | jq -r '.version' 2>/dev/null || echo "")
            
            # Apply if changed
            if [[ -n "$new_version" && "$new_version" != "$last_config_version" ]]; then
                log_info "Config changed: $last_config_version -> $new_version"
                if apply_config "$config"; then
                    last_config_version="$new_version"
                    CURRENT_CONFIG_VERSION="$new_version"
                    export CURRENT_CONFIG_VERSION
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
    if config=$(fetch_config); then
        apply_config "$config"
        send_heartbeat
        log_success "Sync complete"
    else
        log_error "Sync failed"
        exit 1
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
    if config=$(fetch_config 2>/dev/null); then
        echo "Connection:      OK"
        echo "Server Version:  $(echo "$config" | jq -r '.version' 2>/dev/null)"
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
  API_TOKEN           API token for authentication (optional)

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
        help|--help|-h)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
