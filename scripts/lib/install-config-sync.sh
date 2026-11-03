#!/bin/bash

###############################################################################
# Install Config Sync Components
#
# This script installs the appropriate config sync components based on node type:
# - Control Plane: Config API Server
# - VPS/Worker/Laptop: Node Agent
#
# Features:
# - Check if already installed
# - Install with retry logic
# - Fallback mechanisms
# - Validation after install
#
# Usage:
#   install-config-sync.sh <node-type> [control-plane-ip] [api-token] [node-name] [ssh-user] \
#       [--api-token-file <path>]
#
# Use --api-token-file and leave the api-token argument empty: a token on the command
# line is visible in `ps`.
#
# Token Acquisition (check, install, check, fallback):
#   1. Check if a token was provided (file or argument)
#   2. Try to fetch token via SSH from control plane (if ssh-user provided)
#   3. Prompt user interactively
#   4. Fallback: Install without token and provide manual instructions
#
# Node types: control-plane, vps, worker, laptop
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    # Only show debug if DEBUG environment variable is set
    if [[ -n "${DEBUG:-}" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

# Get script directory
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=node-agent-install.sh
source "$SCRIPT_DIR/node-agent-install.sh"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Detect actual user (multiple fallback methods)
# Priority: SUDO_USER > logname > who am i > whoami
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
elif [ -n "$(logname 2>/dev/null)" ] && [ "$(logname 2>/dev/null)" != "root" ]; then
    ACTUAL_USER=$(logname 2>/dev/null)
    ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
elif [ -n "$(who am i 2>/dev/null | awk '{print $1}')" ]; then
    ACTUAL_USER=$(who am i 2>/dev/null | awk '{print $1}')
    ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

# Final validation - if ACTUAL_HOME is /root but we're running as sudo, try harder
if [ "$ACTUAL_HOME" = "/root" ] && [ "$(id -u)" -eq 0 ]; then
    # Check if there's a non-root user's .mynodeone config we should use
    for user_home in /home/*; do
        if [ -f "$user_home/.mynodeone/config.env" ]; then
            ACTUAL_HOME="$user_home"
            ACTUAL_USER=$(basename "$user_home")
            break
        fi
    done
fi

###############################################################################
# Config API Server Installation (Control Plane)
###############################################################################

check_config_api_installed() {
    if [ -f /usr/local/bin/mynodeone-config-api ] && \
       systemctl is-enabled mynodeone-config-api &>/dev/null; then
        return 0
    fi
    return 1
}

# Go can be on PATH, in the tarball location, or from snap, and sudo often resets
# PATH, so look in all of them.
find_go() {
    local candidate
    for candidate in "$(command -v go 2>/dev/null || true)" /usr/local/go/bin/go /snap/bin/go; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install_go_if_needed() {
    local go_bin
    if go_bin=$(find_go); then
        log_success "Go already installed: $("$go_bin" version | awk '{print $3}')"
        return 0
    fi
    
    log_info "Installing Go..."
    
    # Keep in step with the toolchain line in go.mod
    local GO_VERSION="1.24.12"
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv6l" ;;
    esac
    
    # Method 1: Download from official source with better error visibility
    log_info "Downloading Go ${GO_VERSION} for ${ARCH}..."
    local go_url="https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz"
    
    if wget --timeout=30 --tries=3 "${go_url}" -O /tmp/go.tar.gz 2>/dev/null; then
        if [ -f /tmp/go.tar.gz ] && [ -s /tmp/go.tar.gz ]; then
            rm -rf /usr/local/go
            if tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null; then
                rm /tmp/go.tar.gz
                export PATH=$PATH:/usr/local/go/bin
                if command -v go &>/dev/null; then
                    log_success "Go $(go version | awk '{print $3}') installed"
                    return 0
                fi
            fi
        fi
        log_warn "Downloaded file is invalid, cleaning up..."
        rm -f /tmp/go.tar.gz
    else
        log_warn "Download failed from ${go_url}"
    fi
    
    # Method 2: Try snap
    if command -v snap &>/dev/null; then
        log_info "Trying snap installation..."
        if snap install go --classic 2>/dev/null; then
            log_success "Go installed via snap"
            return 0
        fi
    fi
    
    log_error "Failed to install Go"
    return 1
}

build_config_api() {
    log_info "Building Config API Server..."
    
    cd "$PROJECT_ROOT"
    
    # Ensure go.mod exists
    if [ ! -f "go.mod" ]; then
        log_error "go.mod not found in $PROJECT_ROOT"
        return 1
    fi
    
    local go_bin
    if ! go_bin=$(find_go); then
        log_error "Go not found"
        return 1
    fi

    # Initialize modules
    "$go_bin" mod tidy 2>/dev/null || true

    # Build beside the target and rename, so a failed build leaves the installed
    # binary untouched and a running one is replaced in one step.
    local build_output
    build_output=$(mktemp /usr/local/bin/.mynodeone-config-api.XXXXXX)
    if "$go_bin" build -o "$build_output" ./cmd/config-api/; then
        chmod 755 "$build_output"
        mv -f "$build_output" /usr/local/bin/mynodeone-config-api
        log_success "Config API Server built successfully"
        return 0
    else
        rm -f "$build_output"
        log_error "Failed to build Config API Server"
        return 1
    fi
}

install_config_api_service() {
    log_info "Installing Config API systemd service..."
    
    # Create config directory with correct ownership
    mkdir -p /etc/mynodeone
    chmod 700 /etc/mynodeone
    chown root:root /etc/mynodeone
    log_debug "Created /etc/mynodeone directory with root:root ownership"
    
    # Generate API token if not exists
    # The server refuses to start with a missing or empty token file.
    if [ ! -s /etc/mynodeone/api-token ]; then
        log_info "Generating API token..."
        (umask 077 && openssl rand -hex 32 > /etc/mynodeone/api-token)
        chmod 600 /etc/mynodeone/api-token
        log_success "API token generated"
    else
        log_debug "API token already exists"
    fi

    # Copy service file
    cp "$SCRIPT_DIR/mynodeone-config-api.service" /etc/systemd/system/
    
    # Reload and enable
    systemctl daemon-reload
    systemctl enable mynodeone-config-api
    
    log_success "Config API service installed"
}

start_config_api() {
    log_info "Starting Config API Server..."
    
    systemctl start mynodeone-config-api
    
    # Wait for startup
    local attempts=0
    while [ $attempts -lt 10 ]; do
        sleep 1
        if systemctl is-active --quiet mynodeone-config-api; then
            log_success "Config API Server is running"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    
    log_error "Config API Server failed to start"
    journalctl -u mynodeone-config-api -n 20 --no-pager
    return 1
}

validate_config_api() {
    log_info "Validating Config API Server..."
    
    local TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
    
    # Test health endpoint
    local attempts=0
    while [ $attempts -lt 5 ]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8443/api/v1/health" 2>/dev/null | grep -q "200"; then
            log_success "Config API health check passed"
            log_info "API available at: http://${TAILSCALE_IP}:8443"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    
    log_warn "Config API health check failed (may need more time to start)"
    return 1
}

install_config_api_server() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Installing Config API Server (Control Plane)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check if already installed
    if check_config_api_installed; then
        log_success "Config API Server already installed"
        log_info "To upgrade it, run: sudo scripts/installation/install-config-api.sh"

        # Ensure it's running
        if ! systemctl is-active --quiet mynodeone-config-api; then
            log_info "Starting Config API Server..."
            systemctl start mynodeone-config-api
        fi
        
        validate_config_api || true
        return 0
    fi
    
    # Install Go
    install_go_if_needed || {
        log_error "Cannot install Config API without Go"
        return 1
    }
    
    # Build the binary
    build_config_api || {
        log_error "Failed to build Config API Server"
        return 1
    }
    
    # Install systemd service
    install_config_api_service || {
        log_error "Failed to install Config API service"
        return 1
    }
    
    # Start the service
    start_config_api || {
        log_warn "Config API Server may not be running properly"
        # Don't fail installation, it can be fixed later
    }
    
    # Validate
    validate_config_api || true
    
    # Verify API token file exists
    if [ -f /etc/mynodeone/api-token ]; then
        log_success "API token file exists at /etc/mynodeone/api-token"
    else
        log_warn "API token file not found - Node Agents won't be able to authenticate"
        log_warn "Generate manually: openssl rand -hex 32 | sudo tee /etc/mynodeone/api-token"
    fi
    
    log_success "Config API Server installation complete"
    return 0
}

###############################################################################
# Node Agent Installation (VPS, Worker, Laptop)
###############################################################################

check_node_agent_installed() {
    if [ -f /usr/local/bin/mynodeone-node-agent ] && \
       systemctl is-enabled mynodeone-node-agent &>/dev/null; then
        return 0
    fi
    return 1
}

install_node_agent_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v curl &>/dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v jq &>/dev/null; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_info "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing_deps[@]}"
    fi
    
    log_success "Dependencies OK"
}

install_node_agent_binary() {
    log_info "Installing Node Agent..."

    node_agent_install_files || return 1

    log_success "Node Agent installed"
}

# Try to acquire API token via SSH (with retries)
acquire_api_token_via_ssh() {
    local control_plane_ip="$1"
    local ssh_user="$2"
    local max_attempts="${3:-3}"
    
    if [[ -z "$ssh_user" ]]; then
        return 1
    fi
    
    log_info "Attempting to fetch token via SSH from ${ssh_user}@${control_plane_ip} (with retries)..."
    
    local attempt=1
    local delay=2
    
    while [ $attempt -le $max_attempts ]; do
        local fetched_token
        fetched_token=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            "${ssh_user}@${control_plane_ip}" \
            "sudo cat /etc/mynodeone/api-token 2>/dev/null" 2>/dev/null) || true
        
        if [[ -n "$fetched_token" && ${#fetched_token} -ge 32 ]]; then
            echo "$fetched_token"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "SSH token fetch failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done
    
    log_warn "SSH token fetch failed after $max_attempts attempts"
    return 1
}

# Prompt user for API token interactively
prompt_for_api_token() {
    local control_plane_ip="$1"
    
    echo ""
    echo "To authenticate with the control plane, you need the API token."
    echo "You can get it from the control plane with:"
    echo "  ssh <user>@${control_plane_ip} 'sudo cat /etc/mynodeone/api-token'"
    echo ""
    read -p "Enter API token (or press Enter to skip): " -r user_token
    
    if [[ -n "$user_token" && ${#user_token} -ge 32 ]]; then
        echo "$user_token"
        return 0
    fi
    
    return 1
}

configure_node_agent() {
    local node_type="$1"
    local control_plane_ip="$2"
    local api_token="${3:-}"
    local node_name="${4:-$(hostname)}"

    log_info "Configuring Node Agent..."

    # Reconfiguring must not replace a working token with nothing.
    if [[ -z "$api_token" ]]; then
        api_token=$(node_agent_existing_token 2>/dev/null || true)
    fi
    
    # Create config directory with correct ownership
    mkdir -p /etc/mynodeone
    chmod 700 /etc/mynodeone
    chown root:root /etc/mynodeone
    log_debug "Ensured /etc/mynodeone directory has root:root ownership"
    
    # Determine poll interval based on node type
    local poll_interval=60
    if [ "$node_type" = "vps" ]; then
        poll_interval=30  # VPS nodes poll more frequently
    fi
    
    # Get cluster domain using centralized config detection
    local cluster_domain="mynodeone"
    log_info "Detecting cluster domain for Node Agent configuration..."
    
    # Try SSH fetch first if ssh_user provided (VPS nodes usually have this)
    if [[ -n "$ssh_user" && -n "$control_plane_ip" ]]; then
        log_debug "Attempting to fetch cluster domain via SSH from control plane..."
        local detected_domain
        detected_domain=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "${ssh_user}@${control_plane_ip}" \
            "grep '^CLUSTER_DOMAIN=' ~/.mynodeone/config.env /home/*/.mynodeone/config.env /root/.mynodeone/config.env 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null || echo "")
        
        if [[ -n "$detected_domain" ]]; then
            cluster_domain="$detected_domain"
            log_success "Detected cluster domain from control plane: $cluster_domain"
        else
            log_debug "SSH fetch failed, checking local config"
        fi
    fi
    
    # Fallback to local config detection
    if [[ "$cluster_domain" == "mynodeone" ]]; then
        log_debug "Checking local config for cluster domain..."
        
        # Source config-paths.sh to use get_config_value function
        if [[ -f "$PROJECT_ROOT/scripts/lib/config-paths.sh" ]]; then
            source "$PROJECT_ROOT/scripts/lib/config-paths.sh"
            local local_domain
            local_domain=$(get_config_value "CLUSTER_DOMAIN")
            
            if [[ -n "$local_domain" ]]; then
                cluster_domain="$local_domain"
                log_success "Detected cluster domain from local config: $cluster_domain"
            else
                log_warn "Could not detect cluster domain, using default: $cluster_domain"
            fi
        else
            log_warn "config-paths.sh not found, using default domain: $cluster_domain"
        fi
    fi
    
    # For VPS nodes, detect Traefik config directory
    local traefik_config_dir=""
    if [ "$node_type" = "vps" ]; then
        # The existing setting, or else the directory actually holding the routes.
        # TRAEFIK_CONFIG_DIR in the environment names one outright.
        local vps_user="${SUDO_USER:-root}"
        if ! traefik_config_dir=$(node_agent_detect_traefik_dir "${TRAEFIK_CONFIG_DIR:-}" "/home/$vps_user/traefik/config"); then
            log_error "Could not tell which Traefik config directory to manage. Nothing was changed."
            log_error "Run this again with TRAEFIK_CONFIG_DIR=<dir> set to the one Traefik reads."
            return 1
        fi
    fi

    # These values go into agent.env, which a root process sources.
    local value
    for value in "$control_plane_ip" "$node_name" "$node_type" "$api_token" "$cluster_domain" "$traefik_config_dir"; do
        if ! node_agent_valid_env_value "$value"; then
            log_error "A value contains characters that are not allowed in agent.env"
            return 1
        fi
    done

    # Create config file
    umask 077
    local agent_env_new
    agent_env_new=$(mktemp /etc/mynodeone/agent.env.XXXXXX) || return 1
    cat > "$agent_env_new" <<EOF
# MyNodeOne Node Agent Configuration
# Generated: $(date -Iseconds)

# Control plane connection
CONTROL_PLANE_IP=$control_plane_ip
API_PORT=8443

# Node identity
NODE_NAME=$node_name
NODE_TYPE=$node_type

# Cluster domain (for DNS entries like dashboard.{domain}.local)
CLUSTER_DOMAIN=$cluster_domain

# Polling intervals (seconds)
POLL_INTERVAL=$poll_interval
HEARTBEAT_INTERVAL=60

# API authentication
API_TOKEN=$api_token
EOF

    # Add VPS-specific config
    if [ -n "$traefik_config_dir" ]; then
        echo "" >> "$agent_env_new"
        echo "# VPS-specific config" >> "$agent_env_new"
        echo "TRAEFIK_CONFIG_DIR=$traefik_config_dir" >> "$agent_env_new"
    fi

    if ! node_agent_keep_unknown_settings "$agent_env_new"; then
        rm -f "$agent_env_new"
        log_error "Could not read the current agent.env. Nothing was changed."
        return 1
    fi
    mv -f "$agent_env_new" /etc/mynodeone/agent.env

    chmod 600 /etc/mynodeone/agent.env
    # A root process sources this file, so only root may own it. It holds the API
    # token too. Nothing else needs it: /etc/mynodeone is 700 root anyway.
    chown root:root /etc/mynodeone/agent.env
    umask 022

    if ! node_agent_write_sandbox_dropin "$traefik_config_dir"; then
        log_error "Could not make the Traefik config directory writable for the agent"
        return 1
    fi

    # Defensive verification: Ensure agent.env has correct values
    local saved_domain
    saved_domain=$(grep "^CLUSTER_DOMAIN=" /etc/mynodeone/agent.env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ "$saved_domain" != "$cluster_domain" ]; then
        log_warn "CLUSTER_DOMAIN mismatch! Expected: $cluster_domain, Got: $saved_domain"
        log_warn "Forcing correct value..."
        sed -i "s/^CLUSTER_DOMAIN=.*/CLUSTER_DOMAIN=$cluster_domain/" /etc/mynodeone/agent.env
    fi
    
    # Verify control plane IP is set
    local saved_ip
    saved_ip=$(grep "^CONTROL_PLANE_IP=" /etc/mynodeone/agent.env 2>/dev/null | cut -d'=' -f2 || echo "")
    if [ -z "$saved_ip" ]; then
        log_error "CONTROL_PLANE_IP not set in agent.env"
    fi
    
    log_success "Node Agent configured (CLUSTER_DOMAIN=$cluster_domain)"
}

install_node_agent_service() {
    log_info "Installing Node Agent systemd service..."

    # node_agent_install_files copied the unit.
    systemctl daemon-reload
    systemctl enable mynodeone-node-agent
    
    log_success "Node Agent service installed"
}

start_node_agent() {
    log_info "Starting Node Agent..."

    # Restart, not start: on a re-run the old version may be running.
    systemctl restart mynodeone-node-agent
    
    # Wait for startup
    sleep 2
    
    if systemctl is-active --quiet mynodeone-node-agent; then
        log_success "Node Agent is running"
        return 0
    else
        log_warn "Node Agent may not be running properly"
        return 1
    fi
}

validate_node_agent() {
    local control_plane_ip="$1"
    
    log_info "Validating Node Agent..."
    
    # Test connection to control plane
    if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "http://${control_plane_ip}:8443/api/v1/health" 2>/dev/null | grep -q "200"; then
        log_success "Connection to control plane OK"
        return 0
    else
        log_warn "Cannot connect to control plane at ${control_plane_ip}:8443"
        log_warn "Node Agent will retry automatically"
        return 1
    fi
}

# Verify heartbeat works after installation (with retries)
verify_node_agent_heartbeat() {
    local control_plane_ip="$1"
    local api_token="$2"
    local node_name="$3"
    local node_type="$4"
    local max_attempts="${5:-3}"
    
    log_info "Verifying heartbeat authentication (with retries)..."
    
    # Build heartbeat payload
    local payload
    payload=$(jq -cn \
        --arg node_name "$node_name" \
        --arg node_type "$node_type" \
        --arg node_ip "$(tailscale ip -4 2>/dev/null | head -n1 || echo 'unknown')" \
        '{node_name: $node_name, node_type: $node_type, node_ip: $node_ip,
          config_version: "install-test", uptime_seconds: 0}')

    local attempt=1
    local delay=2
    local last_http_code=""
    
    while [ $attempt -le $max_attempts ]; do
        # Send test heartbeat
        local http_code
        # The token goes through a config stream so it stays out of `ps`.
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            -K <(printf 'header = "X-API-Token: %s"\n' "$api_token") \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "http://${control_plane_ip}:8443/api/v1/heartbeat" 2>/dev/null) || true
        
        last_http_code="$http_code"
        
        if [[ "$http_code" == "200" ]]; then
            log_success "Heartbeat verification passed - node registered with control plane"
            return 0
        fi
        
        # Don't retry on auth errors (401/403) - those won't fix themselves
        if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
            break
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Heartbeat attempt failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done
    
    # Report specific error based on last attempt
    case "$last_http_code" in
        401)
            log_warn "Heartbeat failed: Authentication error (HTTP 401)"
            ;;
        403)
            log_warn "Heartbeat failed: Forbidden (HTTP 403)"
            ;;
        000|"")
            log_warn "Heartbeat failed: Could not connect to control plane after $max_attempts attempts"
            ;;
        *)
            log_warn "Heartbeat failed: HTTP $last_http_code"
            ;;
    esac
    return 1
}

# Show remediation steps for failed heartbeat
show_token_remediation() {
    local control_plane_ip="$1"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Manual Token Configuration Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To fix authentication:"
    echo ""
    echo "  1. Get the API token from the control plane:"
    echo "     ssh <user>@${control_plane_ip} 'sudo cat /etc/mynodeone/api-token'"
    echo ""
    echo "  2. Update the token in the agent config:"
    echo "     sudo sed -i 's/^API_TOKEN=.*/API_TOKEN=<your-token>/' /etc/mynodeone/agent.env"
    echo ""
    echo "  3. Restart the agent:"
    echo "     sudo systemctl restart mynodeone-node-agent"
    echo ""
    echo "  4. Verify heartbeat is working:"
    echo "     journalctl -u mynodeone-node-agent -n 5 | grep -i heartbeat"
    echo ""
}

install_node_agent() {
    local node_type="$1"
    local control_plane_ip="$2"
    local api_token="${3:-}"
    local node_name="${4:-$(hostname)}"
    local ssh_user="${5:-}"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Installing Node Agent ($node_type)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Validate inputs
    if [ -z "$control_plane_ip" ]; then
        log_error "Control plane IP is required"
        return 1
    fi
    
    ###########################################################################
    # Token Acquisition: check, install, check, fallback
    ###########################################################################
    
    # Step 1: Check if a token was provided
    if [[ -n "$api_token" ]]; then
        log_success "API token provided"
    else
        log_info "API token not provided, attempting to acquire..."
        
        # Step 2: Try to fetch via SSH
        if [[ -n "$ssh_user" ]]; then
            local fetched_token
            if fetched_token=$(acquire_api_token_via_ssh "$control_plane_ip" "$ssh_user"); then
                api_token="$fetched_token"
                log_success "API token fetched successfully via SSH"
            else
                log_warn "Could not fetch token via SSH"
            fi
        fi
        
        # Step 3: Prompt user interactively if still no token
        if [[ -z "$api_token" ]]; then
            local user_token
            if user_token=$(prompt_for_api_token "$control_plane_ip"); then
                api_token="$user_token"
                log_success "API token provided by user"
            else
                # Step 4: Fallback - continue without token
                log_warn "No API token configured - agent may not authenticate"
            fi
        fi
    fi
    
    # Check if already installed
    if check_node_agent_installed; then
        log_success "Node Agent already installed, updating it"

        # Update the script and unit, which on older installs may be the removed
        # copy with its own sandbox settings.
        install_node_agent_binary || {
            log_error "Failed to update Node Agent"
            return 1
        }

        # Update config if needed
        configure_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name"
        
        # Restart to pick up new script, unit and config
        systemctl daemon-reload
        systemctl restart mynodeone-node-agent
        
        # Verify heartbeat works
        if ! verify_node_agent_heartbeat "$control_plane_ip" "$api_token" "$node_name" "$node_type"; then
            show_token_remediation "$control_plane_ip"
        fi
        
        return 0
    fi
    
    # Install dependencies
    install_node_agent_dependencies || {
        log_error "Failed to install dependencies"
        return 1
    }
    
    # Install binary
    install_node_agent_binary || {
        log_error "Failed to install Node Agent"
        return 1
    }

    # Configure
    configure_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name" || {
        log_error "Failed to configure Node Agent"
        return 1
    }
    
    # Install service
    install_node_agent_service || {
        log_error "Failed to install Node Agent service"
        return 1
    }
    
    # Start
    start_node_agent || {
        log_warn "Node Agent may need manual start"
    }
    
    # Validate connection to control plane
    validate_node_agent "$control_plane_ip" || true
    
    ###########################################################################
    # Post-installation verification: check heartbeat, fallback with instructions
    ###########################################################################
    
    if verify_node_agent_heartbeat "$control_plane_ip" "$api_token" "$node_name" "$node_type"; then
        log_success "Node Agent installation complete - authenticated with control plane"
    else
        log_warn "Node Agent installed but authentication may have issues"
        show_token_remediation "$control_plane_ip"
    fi
    
    return 0
}

###############################################################################
# Main Entry Point
###############################################################################

usage() {
    cat <<EOF
Install Config Sync Components

Usage:
  $0 <node-type> [control-plane-ip] [--api-token-file <path>]
  $0 <node-type> [control-plane-ip] [api-token] [node-name] [ssh-user] [--api-token-file <path>]

Node Types:
  control-plane    Install Config API Server
  vps              Install Node Agent for VPS edge node
  worker           Install Node Agent for worker node
  laptop           Install Node Agent for management laptop

Examples:
  # On control plane
  $0 control-plane

  # On VPS node
  $0 vps 100.x.x.x --api-token-file <path>

  # On worker node
  $0 worker 100.x.x.x --api-token-file <path>

  # On laptop
  $0 laptop 100.x.x.x --api-token-file <path>

The file holds the token and should be mode 600. A token given as an argument still
works, but it is visible in ps.
EOF
}

main() {
    local positional=() api_token_file=""
    while (($#)); do
        case "$1" in
            --api-token-file)
                if [ $# -lt 2 ] || [ ! -r "$2" ]; then
                    log_error "Cannot read API token file: ${2:-(none given)}"
                    exit 1
                fi
                api_token_file="$2"
                shift 2
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done
    set -- ${positional[@]+"${positional[@]}"}

    local node_type="${1:-}"
    local control_plane_ip="${2:-}"
    local api_token="${3:-}"
    local node_name="${4:-$(hostname)}"
    local ssh_user="${5:-}"

    if [ -n "$api_token_file" ]; then
        api_token="$(tr -d '[:space:]' <"$api_token_file")"
    elif [ -n "$api_token" ]; then
        log_warn "A token on the command line is visible in ps; prefer --api-token-file"
    fi
    
    if [ -z "$node_type" ]; then
        usage
        exit 1
    fi
    
    case "$node_type" in
        control-plane)
            install_config_api_server
            ;;
        vps|worker|laptop)
            install_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name" "$ssh_user"
            ;;
        *)
            log_error "Unknown node type: $node_type"
            usage
            exit 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
