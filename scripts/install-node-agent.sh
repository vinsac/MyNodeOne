#!/bin/bash

###############################################################################
# Install MyNodeOne Node Agent
#
# This script installs the Node Agent on laptops, VPS nodes, and workers.
# The agent polls the control plane for config updates and sends heartbeats.
#
# Usage:
#   sudo ./scripts/install-node-agent.sh [options]
#
# Options:
#   --control-plane-ip <ip>   Tailscale IP of control plane (required)
#   --node-type <type>        Node type: laptop, vps, worker (default: laptop)
#   --node-name <name>        Node name (default: hostname)
#   --api-token <token>       API token for authentication
#   --poll-interval <secs>    Polling interval in seconds (default: 60)
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
POLL_INTERVAL="60"
HEARTBEAT_INTERVAL="60"
API_PORT="8443"

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
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --control-plane-ip <ip>   Tailscale IP of control plane (required)"
            echo "  --node-type <type>        Node type: laptop, vps, worker (default: laptop)"
            echo "  --node-name <name>        Node name (default: hostname)"
            echo "  --api-token <token>       API token for authentication"
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
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

# Create config directory
log_info "Creating config directory..."
mkdir -p /etc/mynodeone
chmod 700 /etc/mynodeone

# Create agent config file
log_info "Creating agent configuration..."
cat > /etc/mynodeone/agent.env <<EOF
# MyNodeOne Node Agent Configuration
# Generated: $(date -Iseconds)

# Control plane connection
CONTROL_PLANE_IP=$CONTROL_PLANE_IP
API_PORT=$API_PORT

# Node identity
NODE_NAME=$NODE_NAME
NODE_TYPE=$NODE_TYPE

# Polling intervals (seconds)
POLL_INTERVAL=$POLL_INTERVAL
HEARTBEAT_INTERVAL=$HEARTBEAT_INTERVAL

# API authentication (optional but recommended)
API_TOKEN=$API_TOKEN
EOF

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

# Run initial sync
log_info "Running initial sync..."
/usr/local/bin/mynodeone-node-agent sync 2>/dev/null || log_warn "Initial sync failed (will retry)"

# Display summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Node Agent is running and will:"
echo "  - Poll for config changes every ${POLL_INTERVAL} seconds"
echo "  - Send heartbeat every ${HEARTBEAT_INTERVAL} seconds"
echo "  - Apply config changes automatically"
echo ""
echo "Commands:"
echo "  View logs:     journalctl -u mynodeone-node-agent -f"
echo "  Check status:  mynodeone-node-agent status"
echo "  Manual sync:   sudo mynodeone-node-agent sync"
echo "  Restart:       sudo systemctl restart mynodeone-node-agent"
echo ""

# Show API token reminder if not set
if [[ -z "$API_TOKEN" ]]; then
    echo "Note: No API token configured. For better security, add the token:"
    echo "  1. Get token from control plane: cat /etc/mynodeone/api-token"
    echo "  2. Edit /etc/mynodeone/agent.env and set API_TOKEN=<token>"
    echo "  3. Restart: sudo systemctl restart mynodeone-node-agent"
    echo ""
fi
