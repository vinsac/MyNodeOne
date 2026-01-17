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
#   install-config-sync.sh <node-type> [control-plane-ip] [api-token] [node-name] [ssh-user]
#
# Token Acquisition (check, install, check, fallback):
#   1. Check if api-token provided as argument
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

# Retry logic for commands
retry_command() {
    local max_attempts="$1"
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Command failed (attempt $attempt/$max_attempts). Retrying in 3 seconds..."
            sleep 3
        fi
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Get script directory
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

install_go_if_needed() {
    if command -v go &>/dev/null; then
        log_success "Go already installed: $(go version | awk '{print $3}')"
        return 0
    fi
    
    log_info "Installing Go..."
    
    local GO_VERSION="1.21.5"
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv6l" ;;
    esac
    
    # Method 1: Download from official source
    if retry_command 3 "wget -q 'https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz' -O /tmp/go.tar.gz"; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        log_success "Go $GO_VERSION installed"
        return 0
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
    
    # Initialize modules
    /usr/local/go/bin/go mod tidy 2>/dev/null || true
    
    # Build
    if /usr/local/go/bin/go build -o /usr/local/bin/mynodeone-config-api ./cmd/config-api/; then
        chmod +x /usr/local/bin/mynodeone-config-api
        log_success "Config API Server built successfully"
        return 0
    else
        log_error "Failed to build Config API Server"
        return 1
    fi
}

install_config_api_service() {
    log_info "Installing Config API systemd service..."
    
    # Create config directory
    mkdir -p /etc/mynodeone
    chmod 700 /etc/mynodeone
    
    # Generate API token if not exists
    if [ ! -f /etc/mynodeone/api-token ]; then
        log_info "Generating API token..."
        openssl rand -hex 32 > /etc/mynodeone/api-token
        chmod 600 /etc/mynodeone/api-token
        log_success "API token generated"
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
    
    cp "$SCRIPT_DIR/node-agent.sh" /usr/local/bin/mynodeone-node-agent
    chmod +x /usr/local/bin/mynodeone-node-agent
    
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
    
    # Create config directory
    mkdir -p /etc/mynodeone
    chmod 700 /etc/mynodeone
    
    # Determine poll interval based on node type
    local poll_interval=60
    if [ "$node_type" = "vps" ]; then
        poll_interval=30  # VPS nodes poll more frequently
    fi
    
    # Get cluster domain from local config (for DNS entries)
    local cluster_domain="mynodeone"
    local config_file="$ACTUAL_HOME/.mynodeone/config.env"
    log_info "Looking for cluster domain in: $config_file"
    if [ -f "$config_file" ]; then
        local configured_domain
        configured_domain=$(grep "^CLUSTER_DOMAIN=" "$config_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
        if [ -n "$configured_domain" ]; then
            cluster_domain="$configured_domain"
            log_info "Using cluster domain from config: $cluster_domain"
        else
            log_warn "CLUSTER_DOMAIN not found in config, using default: $cluster_domain"
        fi
    else
        log_warn "Config file not found: $config_file, using default domain: $cluster_domain"
    fi
    
    # For VPS nodes, detect Traefik config directory
    local traefik_config_dir=""
    if [ "$node_type" = "vps" ]; then
        # Check common locations
        local vps_user="${SUDO_USER:-root}"
        if [ -d "/home/$vps_user/traefik/config" ]; then
            traefik_config_dir="/home/$vps_user/traefik/config"
        elif [ -d "/root/traefik/config" ]; then
            traefik_config_dir="/root/traefik/config"
        fi
    fi
    
    # Create config file
    cat > /etc/mynodeone/agent.env <<EOF
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
        echo "" >> /etc/mynodeone/agent.env
        echo "# VPS-specific config" >> /etc/mynodeone/agent.env
        echo "TRAEFIK_CONFIG_DIR=$traefik_config_dir" >> /etc/mynodeone/agent.env
    fi
    
    chmod 600 /etc/mynodeone/agent.env
    
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
        log_error "CONTROL_PLANE_IP not set in agent.env!"
    fi
    
    log_success "Node Agent configured (CLUSTER_DOMAIN=$cluster_domain)"
}

install_node_agent_service() {
    log_info "Installing Node Agent systemd service..."
    
    cp "$SCRIPT_DIR/mynodeone-node-agent.service" /etc/systemd/system/
    
    systemctl daemon-reload
    systemctl enable mynodeone-node-agent
    
    log_success "Node Agent service installed"
}

start_node_agent() {
    log_info "Starting Node Agent..."
    
    systemctl start mynodeone-node-agent
    
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
    
    # Build auth header if token exists
    local auth_header=""
    if [[ -n "$api_token" ]]; then
        auth_header="-H X-API-Token:${api_token}"
    fi
    
    # Build heartbeat payload
    local payload
    payload=$(cat <<EOJSON
{
    "node_name": "$node_name",
    "node_type": "$node_type",
    "node_ip": "$(tailscale ip -4 2>/dev/null || echo 'unknown')",
    "config_version": "install-test",
    "uptime_seconds": 0
}
EOJSON
)
    
    local attempt=1
    local delay=2
    local last_http_code=""
    
    while [ $attempt -le $max_attempts ]; do
        # Send test heartbeat
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
            -X POST \
            -H "Content-Type: application/json" \
            $auth_header \
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
    
    # Step 1: Check if token provided as argument
    if [[ -n "$api_token" ]]; then
        log_success "API token provided via argument"
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
        log_success "Node Agent already installed"
        
        # Update config if needed
        configure_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name"
        
        # Restart to pick up new config
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
  $0 <node-type> [control-plane-ip] [api-token] [node-name]

Node Types:
  control-plane    Install Config API Server
  vps              Install Node Agent for VPS edge node
  worker           Install Node Agent for worker node
  laptop           Install Node Agent for management laptop

Examples:
  # On control plane
  $0 control-plane

  # On VPS node
  $0 vps 100.x.x.x <api-token>

  # On worker node
  $0 worker 100.x.x.x <api-token>

  # On laptop
  $0 laptop 100.x.x.x <api-token>
EOF
}

main() {
    local node_type="${1:-}"
    local control_plane_ip="${2:-}"
    local api_token="${3:-}"
    local node_name="${4:-$(hostname)}"
    local ssh_user="${5:-}"
    
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
