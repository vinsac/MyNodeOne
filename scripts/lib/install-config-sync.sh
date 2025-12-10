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
#   install-config-sync.sh <node-type> [control-plane-ip] [api-token]
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Detect actual user
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
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
    
    log_success "Node Agent configured"
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

install_node_agent() {
    local node_type="$1"
    local control_plane_ip="$2"
    local api_token="${3:-}"
    local node_name="${4:-$(hostname)}"
    
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
    
    # Check if already installed
    if check_node_agent_installed; then
        log_success "Node Agent already installed"
        
        # Update config if needed
        configure_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name"
        
        # Restart to pick up new config
        systemctl restart mynodeone-node-agent
        
        validate_node_agent "$control_plane_ip" || true
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
    
    # Verify API token was configured
    if [ -f /etc/mynodeone/node-agent.conf ]; then
        if grep -q "API_TOKEN=" /etc/mynodeone/node-agent.conf && \
           [ -n "$(grep "API_TOKEN=" /etc/mynodeone/node-agent.conf | cut -d= -f2)" ]; then
            log_success "API token configured in Node Agent"
        else
            log_warn "API token not configured - get token from control plane:"
            log_warn "  cat /etc/mynodeone/api-token"
        fi
    fi
    
    log_success "Node Agent installation complete"
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
    
    if [ -z "$node_type" ]; then
        usage
        exit 1
    fi
    
    case "$node_type" in
        control-plane)
            install_config_api_server
            ;;
        vps|worker|laptop)
            install_node_agent "$node_type" "$control_plane_ip" "$api_token" "$node_name"
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
