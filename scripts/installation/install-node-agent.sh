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
#     [--api-token-file <path> | --api-token <token>] \
#     [--ssh-user <user>] \
#     [--cluster-domain <domain>] \
#     [--traefik-config-dir <dir>]
#
# On a VPS the directory defaults to the current setting in agent.env, then the one
# holding mynodeone-routes.yml. With several candidates and neither of those, it stops
# and asks for --traefik-config-dir.
#
# Prefer --api-token-file: a token on the command line is visible in `ps`. With
# neither option, the token in an existing /etc/mynodeone/agent.env is kept.
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
TRAEFIK_CONFIG_DIR_FLAG=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/node-agent-install.sh
source "$SCRIPT_DIR/../lib/node-agent-install.sh"

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
        --api-token-file)
            if [ ! -r "$2" ]; then
                echo "Cannot read API token file: $2"
                exit 1
            fi
            API_TOKEN="$(tr -d '[:space:]' <"$2")"
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
        --traefik-config-dir)
            TRAEFIK_CONFIG_DIR_FLAG="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --control-plane-ip <ip> --node-name <name> --node-type <type> [--api-token-file <path> | --api-token <token>]"
            exit 1
            ;;
    esac
done

# Reconfiguring must not lose a token that already works.
if [ -z "$API_TOKEN" ]; then
    API_TOKEN="$(node_agent_existing_token 2>/dev/null || true)"
fi

# Validate required arguments
REQUIRED_MISSING=false
if [ -z "$CONTROL_PLANE_IP" ]; then echo "Missing required argument: --control-plane-ip"; REQUIRED_MISSING=true; fi
if [ -z "$NODE_NAME" ]; then echo "Missing required argument: --node-name"; REQUIRED_MISSING=true; fi
if [ -z "$NODE_TYPE" ]; then echo "Missing required argument: --node-type"; REQUIRED_MISSING=true; fi
if [ -z "$API_TOKEN" ]; then echo "Missing required argument: --api-token-file or --api-token"; REQUIRED_MISSING=true; fi

if [ "$REQUIRED_MISSING" = true ]; then
    echo "Usage: $0 --control-plane-ip <ip> --node-name <name> --node-type <type> [--api-token-file <path> | --api-token <token>] [--ssh-user <user>] [--cluster-domain <domain>]"
    exit 1
fi

# These values go into agent.env, which a root process sources.
for value in "$CONTROL_PLANE_IP" "$NODE_NAME" "$NODE_TYPE" "$API_TOKEN" "$API_PORT" "$POLL_INTERVAL" "$CLUSTER_DOMAIN"; do
    if ! node_agent_valid_env_value "$value"; then
        echo "An argument contains characters that are not allowed in agent.env"
        exit 1
    fi
done

# Debug logging for installation tracking
log_debug "=== Node Agent Installation Parameters ==="
log_debug "CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
log_debug "NODE_NAME: $NODE_NAME"
log_debug "NODE_TYPE: $NODE_TYPE"
log_debug "SSH_USER: ${SSH_USER:-'not set'}"
log_debug "CLUSTER_DOMAIN: ${CLUSTER_DOMAIN:-'not set (will auto-detect)'}"
log_debug "API_PORT: $API_PORT"
log_debug "POLL_INTERVAL: $POLL_INTERVAL"
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

log_info "Configuring Node Agent..."

# Create config directory with correct ownership
mkdir -p /etc/mynodeone
chmod 700 /etc/mynodeone
chown root:root /etc/mynodeone
log_debug "Created /etc/mynodeone directory with root:root ownership"

# Source the central config paths utility
source "$SCRIPT_DIR/../lib/config-paths.sh"

# Detect TRAEFIK_CONFIG_DIR for VPS nodes
TRAEFIK_CONFIG_DIR=""

# An explicit --cluster-domain wins; otherwise detect it
EXPLICIT_CLUSTER_DOMAIN="$CLUSTER_DOMAIN"
CLUSTER_DOMAIN="${EXPLICIT_CLUSTER_DOMAIN:-mynodeone}"  # Default fallback
log_info "Detecting cluster domain..."
log_debug "SSH_USER=${SSH_USER:-'not set'}, CONTROL_PLANE_IP=${CONTROL_PLANE_IP:-'not set'}"

# Method 1: Try SSH fetch from control plane (highest priority)
if [[ -z "$EXPLICIT_CLUSTER_DOMAIN" && -n "$SSH_USER" && -n "$CONTROL_PLANE_IP" ]]; then
    log_debug "Attempting to fetch cluster domain via SSH from control plane..."
    DETECTED_DOMAIN=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "grep '^CLUSTER_DOMAIN=' ~/.mynodeone/config.env /home/*/.mynodeone/config.env /root/.mynodeone/config.env 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null || echo "")
    
    if [[ -n "$DETECTED_DOMAIN" ]]; then
        CLUSTER_DOMAIN="$DETECTED_DOMAIN"
        log_success "Detected cluster domain from control plane: $CLUSTER_DOMAIN"
    else
        log_debug "SSH fetch failed, falling back to local config detection"
    fi
fi

# Method 2: Local config detection (uses improved get_config_value with proper priority)
if [[ -z "$EXPLICIT_CLUSTER_DOMAIN" && "$CLUSTER_DOMAIN" == "mynodeone" ]]; then
    log_debug "Checking local config files for cluster domain..."
    LOCAL_DOMAIN=$(get_config_value "CLUSTER_DOMAIN")
    
    if [[ -n "$LOCAL_DOMAIN" ]]; then
        CLUSTER_DOMAIN="$LOCAL_DOMAIN"
        log_success "Detected cluster domain from local config: $CLUSTER_DOMAIN"
    else
        log_warn "Could not detect cluster domain, using default: $CLUSTER_DOMAIN"
        log_debug "This indicates a possible configuration issue - user config should contain CLUSTER_DOMAIN"
    fi
fi

if ! node_agent_valid_env_value "$CLUSTER_DOMAIN"; then
    log_error "Detected cluster domain contains characters that are not allowed in agent.env"
    exit 1
fi

log_info "Final cluster domain: $CLUSTER_DOMAIN"
log_debug "This will be used for DNS entries: <service>.$CLUSTER_DOMAIN.local"

if [[ "$NODE_TYPE" == "vps" ]]; then
    # The existing setting, or else the directory actually holding the routes.
    if ! TRAEFIK_CONFIG_DIR=$(node_agent_detect_traefik_dir "$TRAEFIK_CONFIG_DIR_FLAG"); then
        log_error "Could not tell which Traefik config directory to manage. Nothing was changed."
        exit 1
    fi
    if ! node_agent_valid_env_value "$TRAEFIK_CONFIG_DIR"; then
        log_error "Traefik config directory contains characters that are not allowed in agent.env"
        exit 1
    fi
    log_info "Traefik config directory: $TRAEFIK_CONFIG_DIR"
fi

log_success "Node agent will use cluster domain: $CLUSTER_DOMAIN"
log_info "DNS entries will be created as: <service>.$CLUSTER_DOMAIN.local"

umask 077
AGENT_ENV_NEW="$(mktemp /etc/mynodeone/agent.env.XXXXXX)"
trap 'rm -f "$AGENT_ENV_NEW"' EXIT
cat > "$AGENT_ENV_NEW" <<EOF
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
    echo "" >> "$AGENT_ENV_NEW"
    echo "# VPS-specific config" >> "$AGENT_ENV_NEW"
    echo "TRAEFIK_CONFIG_DIR=$TRAEFIK_CONFIG_DIR" >> "$AGENT_ENV_NEW"
fi

if ! node_agent_keep_unknown_settings "$AGENT_ENV_NEW"; then
    log_error "Could not read the current agent.env. Nothing was changed."
    exit 1
fi
mv -f "$AGENT_ENV_NEW" /etc/mynodeone/agent.env
trap - EXIT

chmod 600 /etc/mynodeone/agent.env
# A root process sources this file, so only root may own it. It contains the API
# token too. Nothing else needs it: /etc/mynodeone is 700 root anyway.
chown root:root /etc/mynodeone/agent.env
umask 022

log_success "Config created: /etc/mynodeone/agent.env"

log_info "Installing Node Agent and systemd service..."
if ! node_agent_install_files; then
    log_error "Could not install the Node Agent"
    exit 1
fi
if ! node_agent_write_sandbox_dropin "$TRAEFIK_CONFIG_DIR"; then
    log_error "Could not make the Traefik config directory writable for the agent"
    exit 1
fi

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
# Restart, not start: on a re-run the old version may be running.
systemctl restart mynodeone-node-agent

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
    # The token goes through a config stream so it stays out of `ps`.
    if curl -s -K <(printf 'header = "X-API-Token: %s"\n' "$API_TOKEN") \
        "http://$CONTROL_PLANE_IP:$API_PORT/api/v1/nodes" | \
        jq -e --arg name "$NODE_NAME" '.nodes[]? | select(.name == $name)' >/dev/null 2>&1; then
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
