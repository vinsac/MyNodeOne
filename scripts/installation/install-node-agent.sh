#!/bin/bash

###############################################################################
# Install MyNodeOne Node Agent
#
# This script installs the Node Agent on laptops, VPS nodes, and workers.
# The agent polls the control plane for config updates and sends heartbeats.
#
# Usage:
#   sudo ./scripts/installation/install-node-agent.sh [options]
#
# Options:
#   --control-plane-ip <ip>   Tailscale IP of control plane (required)
#   --node-type <type>        Node type: laptop, vps, worker (default: laptop)
#   --node-name <name>        Node name (default: hostname)
#   --api-token <token>       API token for authentication
#   --ssh-user <user>         SSH user on control plane (to fetch token)
#   --poll-interval <secs>    Polling interval in seconds (default: 60)
#
# Token Acquisition (check, install, check, fallback):
#   1. Check if --api-token provided
#   2. Try to fetch token via SSH from control plane
#   3. Prompt user interactively
#   4. Fallback: Install without token and provide manual instructions
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

# Default values
CONTROL_PLANE_IP=""
NODE_TYPE="laptop"
NODE_NAME="$(hostname)"
API_TOKEN=""
SSH_USER=""
POLL_INTERVAL="60"
HEARTBEAT_INTERVAL="60"
API_PORT="8443"
TOKEN_FETCH_ATTEMPTED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --control-plane-ip)
            CONTROL_PLANE_IP="$2"
            shift 2
            ;;
        --node-type)
            NODE_TYPE="$2"
            shift 2
            ;;
        --node-name)
            NODE_NAME="$2"
            shift 2
            ;;
        --api-token)
            API_TOKEN="$2"
            shift 2
            ;;
        --poll-interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --control-plane-ip <ip>   Tailscale IP of control plane (required)"
            echo "  --node-type <type>        Node type: laptop, vps, worker (default: laptop)"
            echo "  --node-name <name>        Node name (default: hostname)"
            echo "  --api-token <token>       API token for authentication"
            echo "  --ssh-user <user>         SSH user on control plane (to fetch token)"
            echo "  --poll-interval <secs>    Polling interval (default: 60)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MyNodeOne Node Agent Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Interactive mode if control plane IP not provided
if [[ -z "$CONTROL_PLANE_IP" ]]; then
    echo "Enter the Tailscale IP of your control plane:"
    read -r CONTROL_PLANE_IP
    
    if [[ -z "$CONTROL_PLANE_IP" ]]; then
        log_error "Control plane IP is required"
        exit 1
    fi
fi

# Validate node type
case "$NODE_TYPE" in
    laptop|vps|worker)
        ;;
    *)
        log_error "Invalid node type: $NODE_TYPE (must be laptop, vps, or worker)"
        exit 1
        ;;
esac

log_info "Configuration:"
log_info "  Control Plane: $CONTROL_PLANE_IP:$API_PORT"
log_info "  Node Name:     $NODE_NAME"
log_info "  Node Type:     $NODE_TYPE"
log_info "  Poll Interval: ${POLL_INTERVAL}s"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."

if ! command -v curl &>/dev/null; then
    log_info "Installing curl..."
    apt-get update -qq && apt-get install -y -qq curl
fi

if ! command -v jq &>/dev/null; then
    log_info "Installing jq..."
    apt-get update -qq && apt-get install -y -qq jq
fi

if ! command -v tailscale &>/dev/null; then
    log_error "Tailscale is not installed. Please install Tailscale first."
    exit 1
fi

# Check Tailscale connection
if ! tailscale status &>/dev/null; then
    log_error "Tailscale is not connected. Please run: sudo tailscale up"
    exit 1
fi

log_success "Prerequisites OK"

###############################################################################
# Retry Helper
###############################################################################

MAX_RETRIES=3
RETRY_DELAY=2

retry_with_backoff() {
    local description="$1"
    shift
    local attempt=1
    local delay=$RETRY_DELAY
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if "$@"; then
            return 0
        fi
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_warn "$description failed (attempt $attempt/$MAX_RETRIES). Retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done
    
    log_warn "$description failed after $MAX_RETRIES attempts"
    return 1
}

###############################################################################
# API Token Acquisition (check, install, check, fallback) - with retries
###############################################################################

# Fetch token via SSH (separate function for retry)
fetch_token_via_ssh() {
    local fetched_token
    fetched_token=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${CONTROL_PLANE_IP}" \
        "sudo cat /etc/mynodeone/api-token 2>/dev/null" 2>/dev/null) || return 1
    
    if [[ -n "$fetched_token" && ${#fetched_token} -ge 32 ]]; then
        API_TOKEN="$fetched_token"
        return 0
    fi
    return 1
}

acquire_api_token() {
    # Step 1: Check if token already provided via --api-token
    if [[ -n "$API_TOKEN" ]]; then
        log_success "API token provided via command line"
        return 0
    fi
    
    log_info "API token not provided, attempting to acquire..."
    
    # Step 2: Try to fetch token via SSH from control plane (with retries)
    if [[ -n "$SSH_USER" ]]; then
        log_info "Attempting to fetch token via SSH from ${SSH_USER}@${CONTROL_PLANE_IP}..."
        
        if retry_with_backoff "SSH token fetch" fetch_token_via_ssh; then
            log_success "API token fetched successfully via SSH"
            return 0
        else
            log_warn "Could not fetch token via SSH (may need password or token file doesn't exist)"
        fi
    fi
    
    # Step 3: Prompt user interactively
    echo ""
    echo "To authenticate with the control plane, you need the API token."
    echo "You can get it from the control plane with:"
    echo "  ssh <user>@${CONTROL_PLANE_IP} 'sudo cat /etc/mynodeone/api-token'"
    echo ""
    read -p "Enter API token (or press Enter to skip): " -r user_token
    
    if [[ -n "$user_token" && ${#user_token} -ge 32 ]]; then
        API_TOKEN="$user_token"
        log_success "API token provided by user"
        return 0
    fi
    
    # Step 4: Fallback - continue without token
    log_warn "No API token configured"
    log_warn "The agent will be installed but may not authenticate with the control plane"
    return 1
}

# Acquire token
acquire_api_token
TOKEN_FETCH_ATTEMPTED=true

# Create config directory
log_info "Creating config directory..."
mkdir -p /etc/mynodeone
chmod 700 /etc/mynodeone

# Create agent config file
log_info "Creating agent configuration..."

# Detect TRAEFIK_CONFIG_DIR for VPS nodes
TRAEFIK_CONFIG_DIR=""
CLUSTER_DOMAIN="mynodeone"

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
HEARTBEAT_INTERVAL=$HEARTBEAT_INTERVAL

# API authentication
API_TOKEN=$API_TOKEN
EOF

# Add VPS-specific config
if [[ "$NODE_TYPE" == "vps" && -n "$TRAEFIK_CONFIG_DIR" ]]; then
    echo "" >> /etc/mynodeone/agent.env
    echo "# VPS-specific config" >> /etc/mynodeone/agent.env
    echo "TRAEFIK_CONFIG_DIR=$TRAEFIK_CONFIG_DIR" >> /etc/mynodeone/agent.env
fi

chmod 600 /etc/mynodeone/agent.env
log_success "Config created: /etc/mynodeone/agent.env"

# Install the node agent script
log_info "Installing node agent..."
cp "$SCRIPT_DIR/lib/node-agent.sh" /usr/local/bin/mynodeone-node-agent
chmod +x /usr/local/bin/mynodeone-node-agent
log_success "Agent installed: /usr/local/bin/mynodeone-node-agent"

# Install systemd service
log_info "Installing systemd service..."
cp "$SCRIPT_DIR/lib/mynodeone-node-agent.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable mynodeone-node-agent

# Test connection to control plane
log_info "Testing connection to control plane..."
if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
    "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/health" 2>/dev/null | grep -q "200"; then
    log_success "Connection to control plane OK"
else
    log_warn "Could not connect to control plane at ${CONTROL_PLANE_IP}:${API_PORT}"
    log_warn "Make sure the Config API Server is running on the control plane"
    log_warn "The agent will retry automatically when started"
fi

# Start the service
log_info "Starting Node Agent..."
systemctl start mynodeone-node-agent

# Wait for startup
sleep 2

# Verify it's running
if systemctl is-active --quiet mynodeone-node-agent; then
    log_success "Node Agent is running"
else
    log_warn "Node Agent may have issues starting"
    log_info "Check logs: journalctl -u mynodeone-node-agent -n 20"
fi

###############################################################################
# Post-Installation Verification (check heartbeat, fallback with instructions)
###############################################################################

# Single heartbeat attempt (used by retry wrapper)
send_single_heartbeat() {
    # Build auth header if token exists
    local auth_header=""
    if [[ -n "$API_TOKEN" ]]; then
        auth_header="-H X-API-Token:${API_TOKEN}"
    fi
    
    # Build heartbeat payload
    local payload
    payload=$(cat <<EOJSON
{
    "node_name": "$NODE_NAME",
    "node_type": "$NODE_TYPE",
    "node_ip": "$(tailscale ip -4 2>/dev/null || echo 'unknown')",
    "config_version": "install-test",
    "uptime_seconds": 0
}
EOJSON
)
    
    # Send test heartbeat
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        -X POST \
        -H "Content-Type: application/json" \
        $auth_header \
        -d "$payload" \
        "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/heartbeat" 2>/dev/null) || true
    
    # Store for error reporting
    LAST_HEARTBEAT_CODE="$http_code"
    
    [[ "$http_code" == "200" ]]
}

verify_heartbeat() {
    log_info "Verifying heartbeat authentication (with retries)..."
    
    LAST_HEARTBEAT_CODE=""
    
    # Use retry with backoff
    if retry_with_backoff "Heartbeat verification" send_single_heartbeat; then
        log_success "Heartbeat verification passed - node registered with control plane"
        return 0
    fi
    
    # Report specific error based on last attempt
    case "$LAST_HEARTBEAT_CODE" in
        401)
            log_warn "Heartbeat failed: Authentication error (HTTP 401)"
            log_warn "The API token is missing or incorrect"
            ;;
        403)
            log_warn "Heartbeat failed: Forbidden (HTTP 403)"
            log_warn "Check if this node's Tailscale IP is allowed"
            ;;
        000|"")
            log_warn "Heartbeat failed: Could not connect to control plane"
            ;;
        *)
            log_warn "Heartbeat failed: HTTP $LAST_HEARTBEAT_CODE"
            ;;
    esac
    return 1
}

# Verify heartbeat works
HEARTBEAT_OK=false
if verify_heartbeat; then
    HEARTBEAT_OK=true
fi

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$HEARTBEAT_OK" == "true" ]]; then
    echo -e "${GREEN}✓ Node Agent is running and authenticated${NC}"
    echo ""
    echo "Node Agent will:"
    echo "  - Poll for config changes every ${POLL_INTERVAL} seconds"
    echo "  - Send heartbeat every ${HEARTBEAT_INTERVAL} seconds"
    echo "  - Apply config changes automatically"
else
    echo -e "${YELLOW}⚠ Node Agent is running but authentication may have issues${NC}"
    echo ""
fi

echo ""
echo "Commands:"
echo "  View logs:     journalctl -u mynodeone-node-agent -f"
echo "  Check status:  mynodeone-node-agent status"
echo "  Manual sync:   sudo mynodeone-node-agent sync"
echo "  Restart:       sudo systemctl restart mynodeone-node-agent"
echo ""

# Show remediation steps if heartbeat failed
if [[ "$HEARTBEAT_OK" != "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Manual Token Configuration Required"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To fix authentication:"
    echo ""
    echo "  1. Get the API token from the control plane:"
    echo "     ssh <user>@${CONTROL_PLANE_IP} 'sudo cat /etc/mynodeone/api-token'"
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
fi
