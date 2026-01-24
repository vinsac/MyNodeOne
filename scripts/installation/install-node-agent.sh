#!/bin/bash

###############################################################################
# Install MyNodeOne Node Agent
#
# This script installs the node agent on a node (laptop, VPS, worker).
# The agent polls the control plane for config updates and applies them.
#
# Usage:
#   sudo ./install-node-agent.sh \
#     --control-plane-ip <ip> \
#     --node-name <name> \
#     --node-type <type> \
#     --api-token <token> \
#     [--ssh-user <user>] \
#     [--cluster-domain <domain>]
###############################################################################

set -euo pipefail

# Colors for logging
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

# Default values
CONTROL_PLANE_IP=""
NODE_NAME=""
NODE_TYPE=""
API_TOKEN=""
SSH_USER=""
CLUSTER_DOMAIN=""
API_PORT="8443"
POLL_INTERVAL="60"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --control-plane-ip)
            CONTROL_PLANE_IP="$2"
            shift 2
            ;;
        --node-name)
            NODE_NAME="$2"
            shift 2
            ;;
        --node-type)
            NODE_TYPE="$2"
            shift 2
            ;;
        --api-token)
            API_TOKEN="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --cluster-domain)
            CLUSTER_DOMAIN="$2"
            shift 2
            ;;
        --api-port)
            API_PORT="$2"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --control-plane-ip <ip> --node-name <name> --node-type <type> --api-token <token>"
            exit 1
            ;;
    esac
done

# Validate required arguments
REQUIRED_MISSING=false
if [ -z "$CONTROL_PLANE_IP" ]; then echo "Missing required argument: --control-plane-ip"; REQUIRED_MISSING=true; fi
if [ -z "$NODE_NAME" ]; then echo "Missing required argument: --node-name"; REQUIRED_MISSING=true; fi
if [ -z "$NODE_TYPE" ]; then echo "Missing required argument: --node-type"; REQUIRED_MISSING=true; fi
if [ -z "$API_TOKEN" ]; then echo "Missing required argument: --api-token"; REQUIRED_MISSING=true; fi

if [ "$REQUIRED_MISSING" = true ]; then
    echo "Usage: $0 --control-plane-ip <ip> --node-name <name> --node-type <type> --api-token <token> [--ssh-user <user>] [--cluster-domain <domain>]"
    exit 1
fi

# Debug logging for installation tracking
log_debug "=== Node Agent Installation Parameters ==="
log_debug "CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
log_debug "NODE_NAME: $NODE_NAME"
log_debug "NODE_TYPE: $NODE_TYPE"
log_debug "SSH_USER: ${SSH_USER:-'not set'}"
log_debug "CLUSTER_DOMAIN: ${CLUSTER_DOMAIN:-'not set (will auto-detect)'}"
log_debug "API_PORT: $API_PORT"
log_debug "POLL_INTERVAL: $POLL_INTERVAL"
log_debug "API_TOKEN: ${API_TOKEN:0:10}..."  # Show only first 10 chars for security
log_debug "Current user: $(whoami)"
log_debug "Current home: $HOME"
log_debug "========================================"

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

log_info "Checking dependencies..."
if ! command -v curl &>/dev/null; then
    log_error "curl is required but not installed"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
fi

log_success "Dependencies OK"

log_info "Installing Node Agent..."

# Install node agent binary
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check multiple locations for the node agent binary
BINARY_SOURCE=""
BINARY_LOCATIONS=(
    "/usr/local/bin/mynodeone-node-agent"  # Already installed
    "$SCRIPT_DIR/mynodeone-node-agent"     # Scripts directory (for fresh installs)
    "$SCRIPT_DIR/../lib/node-agent.sh"     # Source script location
)

for location in "${BINARY_LOCATIONS[@]}"; do
    if [ -f "$location" ]; then
        BINARY_SOURCE="$location"
        break
    fi
done

if [ -z "$BINARY_SOURCE" ]; then
    log_error "Node agent binary not found in any of these locations:"
    printf '  - %s\n' "${BINARY_LOCATIONS[@]}"
    exit 1
fi

# Install to /usr/local/bin if not already there
if [ ! -f "/usr/local/bin/mynodeone-node-agent" ] || [ "$BINARY_SOURCE" != "/usr/local/bin/mynodeone-node-agent" ]; then
    cp "$BINARY_SOURCE" /usr/local/bin/mynodeone-node-agent
    chmod +x /usr/local/bin/mynodeone-node-agent
    log_success "Node Agent installed from $BINARY_SOURCE"
else
    log_success "Node Agent already installed"
fi

# Install config-paths.sh dependency for Node Agent
if [ ! -f "/usr/local/bin/config-paths.sh" ]; then
    if [ -f "$SCRIPT_DIR/../lib/config-paths.sh" ]; then
        cp "$SCRIPT_DIR/../lib/config-paths.sh" /usr/local/bin/
        chmod +x /usr/local/bin/config-paths.sh
        chown root:root /usr/local/bin/config-paths.sh
        log_success "config-paths.sh dependency installed"
    else
        log_warn "config-paths.sh not found, Node Agent may not work properly"
    fi
fi

log_info "Configuring Node Agent..."

# Create config directory
mkdir -p /etc/mynodeone

# Source the central config paths utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config-paths.sh"

# Detect TRAEFIK_CONFIG_DIR for VPS nodes
TRAEFIK_CONFIG_DIR=""

# Fetch CLUSTER_DOMAIN from cluster config (defensive programming)
CLUSTER_DOMAIN="mynodeone"  # Default fallback
log_info "Detecting cluster domain from control plane..."
log_debug "SSH_USER=${SSH_USER:-'not set'}, CONTROL_PLANE_IP=${CONTROL_PLANE_IP:-'not set'}"

# Try to fetch from control plane's config.env
if [[ -n "$SSH_USER" && -n "$CONTROL_PLANE_IP" ]]; then
    log_debug "Attempting to fetch cluster domain via SSH from control plane..."
    DETECTED_DOMAIN=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "grep '^CLUSTER_DOMAIN=' ~/.mynodeone/config.env /home/*/.mynodeone/config.env /root/.mynodeone/config.env 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null || echo "")
    
    if [[ -n "$DETECTED_DOMAIN" ]]; then
        CLUSTER_DOMAIN="$DETECTED_DOMAIN"
        log_success "Detected cluster domain from control plane: $CLUSTER_DOMAIN"
    else
        log_warn "Could not detect cluster domain from control plane, checking local config..."
        log_debug "SSH command returned empty or failed"
        # Fallback: Check local config when SSH fails
        LOCAL_DOMAIN=$(get_config_value "CLUSTER_DOMAIN")
        log_debug "get_config_value returned: '${LOCAL_DOMAIN:-'empty'}'"
        if [[ -n "$LOCAL_DOMAIN" ]]; then
            CLUSTER_DOMAIN="$LOCAL_DOMAIN"
            log_success "Detected cluster domain from local config: $CLUSTER_DOMAIN"
        else
            log_warn "Could not detect cluster domain locally, using default: $CLUSTER_DOMAIN"
            log_debug "All detection methods failed, falling back to default"
        fi
    fi
else
    # SSH not available (e.g., installing on control plane itself), check local config first
    log_info "SSH not available, checking local config for cluster domain..."
    log_debug "Checking for local user config files..."
    
    # Check for user config first (highest priority for cluster-wide settings)
    USER_CONFIG=$(get_primary_user_config 2>/dev/null || echo "")
    log_debug "Primary user config found: ${USER_CONFIG:-'none'}"
    
    if [[ -n "$USER_CONFIG" && -f "$USER_CONFIG" ]]; then
        LOCAL_DOMAIN=$(grep "^CLUSTER_DOMAIN=" "$USER_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "")
        log_debug "CLUSTER_DOMAIN from user config: '${LOCAL_DOMAIN:-'not found'}'"
        if [[ -n "$LOCAL_DOMAIN" ]]; then
            CLUSTER_DOMAIN="$LOCAL_DOMAIN"
            log_success "Detected cluster domain from user config: $CLUSTER_DOMAIN"
        else
            log_debug "CLUSTER_DOMAIN not found in user config"
        fi
    fi
    
    # If still not found, try agent config as fallback
    if [[ "$CLUSTER_DOMAIN" == "mynodeone" ]]; then
        log_debug "Checking agent config as fallback..."
        AGENT_CONFIG=$(find_agent_config)
        log_debug "Agent config found: ${AGENT_CONFIG:-'none'}"
        
        if [[ -n "$AGENT_CONFIG" && -f "$AGENT_CONFIG" ]]; then
            LOCAL_DOMAIN=$(grep "^CLUSTER_DOMAIN=" "$AGENT_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "")
            log_debug "CLUSTER_DOMAIN from agent config: '${LOCAL_DOMAIN:-'not found'}'"
            if [[ -n "$LOCAL_DOMAIN" && "$LOCAL_DOMAIN" != "mynodeone" ]]; then
                CLUSTER_DOMAIN="$LOCAL_DOMAIN"
                log_success "Detected cluster domain from agent config: $CLUSTER_DOMAIN"
            fi
        fi
    fi
    
    if [[ "$CLUSTER_DOMAIN" == "mynodeone" ]]; then
        log_warn "Could not detect cluster domain locally, using default: $CLUSTER_DOMAIN"
        log_debug "This indicates a possible configuration issue - user config should contain CLUSTER_DOMAIN"
    fi
fi

log_info "Final cluster domain: $CLUSTER_DOMAIN"
log_debug "This will be used for DNS entries: <service>.$CLUSTER_DOMAIN.local"

if [[ "$NODE_TYPE" == "vps" ]]; then
    # Try to find existing Traefik config directory
    for dir in /home/*/traefik/config /root/traefik/config /etc/traefik/config; do
        if [[ -d "$dir" ]]; then
            TRAEFIK_CONFIG_DIR="$dir"
            log_info "Found Traefik config directory: $TRAEFIK_CONFIG_DIR"
            break
        fi
    done
    
    if [[ -z "$TRAEFIK_CONFIG_DIR" ]]; then
        # Default to /etc/traefik/config for VPS
        TRAEFIK_CONFIG_DIR="/etc/traefik/config"
        log_warn "Traefik config directory not found, using default: $TRAEFIK_CONFIG_DIR"
    fi
fi

log_success "Node agent will use cluster domain: $CLUSTER_DOMAIN"
log_info "DNS entries will be created as: <service>.$CLUSTER_DOMAIN.local"

cat > /etc/mynodeone/agent.env <<EOF
# MyNodeOne Node Agent Configuration
# Generated: $(date -Iseconds)

# Control plane connection
CONTROL_PLANE_IP=$CONTROL_PLANE_IP
API_PORT=$API_PORT

# Node identity
NODE_NAME=$NODE_NAME
NODE_TYPE=$NODE_TYPE

# Cluster domain (for DNS entries like dashboard.{domain}.local)
CLUSTER_DOMAIN=$CLUSTER_DOMAIN

# Polling intervals (seconds)
POLL_INTERVAL=$POLL_INTERVAL
HEARTBEAT_INTERVAL=60

# API authentication
API_TOKEN=$API_TOKEN
EOF

# Add VPS-specific config
if [ -n "$TRAEFIK_CONFIG_DIR" ]; then
    echo "" >> /etc/mynodeone/agent.env
    echo "# VPS-specific config" >> /etc/mynodeone/agent.env
    echo "TRAEFIK_CONFIG_DIR=$TRAEFIK_CONFIG_DIR" >> /etc/mynodeone/agent.env
fi

chmod 600 /etc/mynodeone/agent.env

# Set proper ownership if running with sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Get the actual user's home directory
    ACTUAL_USER_HOME=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "")
    if [ -n "$ACTUAL_USER_HOME" ]; then
        # Ensure the actual user can read the config
        chown "$SUDO_USER:$SUDO_USER" /etc/mynodeone/agent.env
        log_info "Config ownership set for user: $SUDO_USER"
    fi
fi

log_success "Config created: /etc/mynodeone/agent.env"

log_info "Installing systemd service..."
# Create systemd service
cat > /etc/systemd/system/mynodeone-node-agent.service <<EOF
[Unit]
Description=MyNodeOne Node Agent
Documentation=https://github.com/vinsac/MyNodeOne
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mynodeone-node-agent run
Restart=always
RestartSec=10
User=root
Group=root

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/mynodeone

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mynodeone-node-agent

log_success "Node Agent service installed"

log_info "Testing connection to control plane..."
if curl -s --connect-timeout 5 "http://$CONTROL_PLANE_IP:$API_PORT/api/v1/health" >/dev/null; then
    log_success "Connection to control plane OK"
else
    log_error "Cannot connect to control plane at $CONTROL_PLANE_IP:$API_PORT"
    exit 1
fi

log_info "Starting Node Agent..."
systemctl start mynodeone-node-agent

# Wait a moment for service to start
sleep 2

if systemctl is-active --quiet mynodeone-node-agent; then
    log_success "Node Agent is running"
else
    log_error "Node Agent failed to start"
    journalctl -u mynodeone-node-agent --no-pager -n 20
    exit 1
fi

log_info "Verifying heartbeat authentication (with retries)..."
max_attempts=5
attempt=1

while [ $attempt -le $max_attempts ]; do
    # Check if node is registered
    if curl -s -H "X-API-Token: $API_TOKEN" \
        "http://$CONTROL_PLANE_IP:$API_PORT/api/v1/nodes" | \
        jq -e ".nodes[]? | select(.name == \"$NODE_NAME\")" >/dev/null 2>&1; then
        log_success "Heartbeat verification passed - node registered with control plane"
        break
    else
        if [ $attempt -eq $max_attempts ]; then
            log_error "Heartbeat verification failed after $max_attempts attempts"
            exit 1
        fi
        
        log_warn "Heartbeat attempt $attempt/$max_attempts failed, retrying in 5s..."
        sleep 5
        ((attempt++))
    fi
done

log_success "Node Agent installation complete - authenticated with control plane"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "✓ Node Agent is running and authenticated"
echo ""
echo "Node Agent will:"
echo "  - Poll for config changes every $POLL_INTERVAL seconds"
echo "  - Send heartbeat every 60 seconds"
echo "  - Apply config changes automatically"
echo ""
echo "Commands:"
echo "  View logs:     journalctl -u mynodeone-node-agent -f"
echo "  Check status:  mynodeone-node-agent status"
echo "  Manual sync:   sudo mynodeone-node-agent sync"
echo "  Restart:       sudo systemctl restart mynodeone-node-agent"
echo ""
