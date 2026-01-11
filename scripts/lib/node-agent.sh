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
    CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"  # Used for DNS entries (e.g., dashboard.{domain}.local)
    
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
    local domain="${CLUSTER_DOMAIN:-mynodeone}.local"
    entries=$(echo "$config" | jq -r --arg domain "$domain" '.dns_entries[]? | "\(.ip) \(.name).\($domain) \(.name)"' 2>/dev/null)
    
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
    local domain="${CLUSTER_DOMAIN:-mynodeone}.local"
    grep -v "# MyNodeOne" "$hosts_file" | grep -v ".${domain}" > "$temp_file" || true
    
    # Add new entries
    echo "" >> "$temp_file"
    echo "# MyNodeOne DNS entries (managed by node-agent)" >> "$temp_file"
    echo "$entries" >> "$temp_file"
    
    # Apply changes and ensure proper permissions (644 so all users can read)
    if [[ "$(id -u)" -eq 0 ]]; then
        mv "$temp_file" "$hosts_file"
        chmod 644 "$hosts_file"
    else
        sudo mv "$temp_file" "$hosts_file"
        sudo chmod 644 "$hosts_file"
    fi
    
    # Defensive check: Verify permissions are correct
    local perms
    perms=$(stat -c "%a" "$hosts_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "644" ]]; then
        log_warn "/etc/hosts has permissions $perms, forcing to 644"
        if [[ "$(id -u)" -eq 0 ]]; then
            chmod 644 "$hosts_file"
        else
            sudo chmod 644 "$hosts_file"
        fi
    fi
    
    local count
    count=$(echo "$entries" | wc -l)
    log_success "Applied $count DNS entries to /etc/hosts"
}

# Apply Traefik routes (for VPS nodes)
# Generates Traefik YAML matching V1 SSH-based sync format from multi-domain-registry.sh
apply_vps_config() {
    local config="$1"
    
    # Validate config is valid JSON
    if ! echo "$config" | jq -e '.' &>/dev/null; then
        log_error "Invalid config JSON received"
        return 1
    fi
    
    # Extract routes count
    local route_count
    route_count=$(echo "$config" | jq -r '.routes | length' 2>/dev/null || echo "0")
    
    if [[ "$route_count" -eq 0 ]]; then
        log_info "No routes to apply"
        return 0
    fi
    
    # Generate Traefik dynamic config
    # Try multiple locations for Traefik config (priority order)
    local traefik_config_dir="${TRAEFIK_CONFIG_DIR:-}"
    
    if [[ -z "$traefik_config_dir" ]]; then
        # Check common locations - look for existing traefik directories
        local search_dirs=(
            "/home/sammy/traefik/config"      # Common VPS user
            "/home/ubuntu/traefik/config"     # Ubuntu default
            "/home/${SUDO_USER:-}/traefik/config"
            "$HOME/traefik/config"
            "/root/traefik/config"
            "/etc/traefik/config"
        )
        
        for dir in "${search_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                traefik_config_dir="$dir"
                break
            fi
        done
        
        # Fallback to /etc/traefik/config if nothing found
        traefik_config_dir="${traefik_config_dir:-/etc/traefik/config}"
    fi
    
    local routes_file="$traefik_config_dir/mynodeone-routes.yml"
    local routes_file_tmp="${routes_file}.tmp.$$"
    
    # Ensure directory exists with proper permissions
    if [[ ! -d "$traefik_config_dir" ]]; then
        log_warn "Traefik config directory does not exist: $traefik_config_dir"
        if ! mkdir -p "$traefik_config_dir" 2>/dev/null; then
            log_error "Failed to create directory: $traefik_config_dir"
            return 1
        fi
        chmod 755 "$traefik_config_dir"
        log_info "Created directory: $traefik_config_dir"
    fi
    
    # Check directory is writable
    if [[ ! -w "$traefik_config_dir" ]]; then
        log_error "Directory not writable: $traefik_config_dir"
        return 1
    fi
    
    # Get directory owner for proper file ownership
    local dir_owner dir_group
    dir_owner=$(stat -c '%U' "$traefik_config_dir" 2>/dev/null || echo "root")
    dir_group=$(stat -c '%G' "$traefik_config_dir" 2>/dev/null || echo "root")
    
    # Generate YAML to temp file first (atomic write pattern)
    # Format matches V1 multi-domain-registry.sh export_vps_routing
    cat > "$routes_file_tmp" <<EOF
# MyNodeOne Routes (managed by node-agent)
# Generated: $(date -Iseconds)
# Format matches V1 SSH-based sync for consistency

http:
  routers:
EOF

    # Add HTTPS routers - format: {service}-{domain-dashed}
    # Using jq to generate proper router names matching V1 format
    echo "$config" | jq -r '.routes[]? | 
        # Convert domain to dashed format (e.g., example.com -> example-com)
        (.domain | gsub("\\."; "-")) as $domain_dashed |
        "    " + .service + "-" + $domain_dashed + ":\n" +
        "      rule: \"Host(`" + .domain + "`)\"\n" +
        "      service: " + .service + "-service\n" +
        "      entryPoints:\n" +
        "        - websecure\n" +
        "      tls:\n" +
        "        certResolver: letsencrypt\n"' >> "$routes_file_tmp"

    # Add HTTP routers for redirect - format: {service}-{domain-dashed}-http
    echo "$config" | jq -r '.routes[]? | 
        (.domain | gsub("\\."; "-")) as $domain_dashed |
        "    " + .service + "-" + $domain_dashed + "-http:\n" +
        "      rule: \"Host(`" + .domain + "`)\"\n" +
        "      service: " + .service + "-service\n" +
        "      entryPoints:\n" +
        "        - web\n" +
        "      middlewares:\n" +
        "        - https-redirect\n"' >> "$routes_file_tmp"

    # Add services section - format: {service}-service
    cat >> "$routes_file_tmp" <<EOF
  services:
EOF

    # Add services (deduplicated by service name)
    echo "$config" | jq -r '[.routes[]? | .service] | unique | .[] as $svc |
        # Find backend for this service (use first match)
        ($ARGS.named.config | .routes[] | select(.service == $svc) | .backend) as $backend |
        "    " + $svc + "-service:\n" +
        "      loadBalancer:\n" +
        "        servers:\n" +
        "          - url: \"http://" + $backend + "\"\n"' --jsonargs config="$config" >> "$routes_file_tmp" 2>/dev/null || \
    # Fallback if jsonargs not supported (older jq)
    echo "$config" | jq -r '.routes | group_by(.service) | .[] | .[0] |
        "    " + .service + "-service:\n" +
        "      loadBalancer:\n" +
        "        servers:\n" +
        "          - url: \"http://" + .backend + "\"\n"' >> "$routes_file_tmp"

    # Add middlewares for HTTP to HTTPS redirect - matches V1 format
    cat >> "$routes_file_tmp" <<EOF
  middlewares:
    https-redirect:
      redirectScheme:
        scheme: https
        permanent: true
EOF

    # Validate generated YAML is not empty/malformed
    if [[ ! -s "$routes_file_tmp" ]]; then
        log_error "Generated routes file is empty"
        rm -f "$routes_file_tmp"
        return 1
    fi
    
    # Check YAML has required sections
    if ! grep -q "routers:" "$routes_file_tmp" || ! grep -q "services:" "$routes_file_tmp"; then
        log_error "Generated YAML missing required sections"
        rm -f "$routes_file_tmp"
        return 1
    fi
    
    # Atomic move: rename temp file to final location
    if ! mv "$routes_file_tmp" "$routes_file"; then
        log_error "Failed to write routes file: $routes_file"
        rm -f "$routes_file_tmp"
        return 1
    fi
    
    # Set proper ownership to match directory owner (important when running as root)
    if [[ "$dir_owner" != "root" ]] && [[ -n "$dir_owner" ]]; then
        chown "${dir_owner}:${dir_group}" "$routes_file" 2>/dev/null || \
            log_warn "Could not set ownership to ${dir_owner}:${dir_group}"
    fi
    
    # Set secure but readable permissions (Traefik needs to read this)
    chmod 644 "$routes_file"
    
    log_success "Generated Traefik routes: $routes_file"
    log_info "Routes configured: $route_count (V1-compatible format)"
    log_info "File ownership: ${dir_owner}:${dir_group}, permissions: 644"
    
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
