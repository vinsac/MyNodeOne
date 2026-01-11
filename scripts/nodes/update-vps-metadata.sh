#!/bin/bash

###############################################################################
# Update VPS Edge Node Metadata
#
# This script collects and updates comprehensive metadata for a VPS edge node
# in the cluster registry. Run this on the VPS itself or from the control plane.
#
# Usage:
#   # On VPS (updates own metadata):
#   sudo ./scripts/nodes/update-vps-metadata.sh
#
#   # From control plane (updates remote VPS):
#   sudo ./scripts/nodes/update-vps-metadata.sh --name <vps-name> --ip <tailscale-ip>
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_COLLECTOR="$SCRIPT_DIR/../lib/collect-vps-metadata.sh"
REGISTRY_MANAGER="$SCRIPT_DIR/../lib/node-registry-manager.sh"

# Detect user
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

# Parse arguments
VPS_NAME=""
VPS_IP=""
REMOTE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            VPS_NAME="$2"
            REMOTE_MODE=true
            shift 2
            ;;
        --ip)
            VPS_IP="$2"
            shift 2
            ;;
        -h|--help)
            cat << 'EOF'
Update VPS Edge Node Metadata

Usage:
  # On VPS (updates own metadata):
  sudo ./scripts/nodes/update-vps-metadata.sh

  # From control plane (updates remote VPS):
  sudo ./scripts/nodes/update-vps-metadata.sh --name <vps-name> --ip <tailscale-ip>

Options:
  --name <name>    VPS node name (for remote updates)
  --ip <ip>        VPS Tailscale IP (for remote updates)
  -h, --help       Show this help message

Examples:
  # Update metadata on the VPS itself:
  sudo ./scripts/nodes/update-vps-metadata.sh

  # Update metadata from control plane:
  sudo ./scripts/nodes/update-vps-metadata.sh --name vps-edge-0001 --ip 100.99.197.116

What this script does:
  1. Collects comprehensive VPS metadata (hardware, software, location, provider)
  2. Updates the cluster registry ConfigMap with the metadata
  3. Validates the update was successful

Metadata collected:
  - Hardware: CPU, RAM, disk space, OS
  - Location: Region/datacenter
  - Provider: Cloud provider (DigitalOcean, AWS, etc.)
  - Public IP: Internet-facing IP address
  - Tailscale IP: Private cluster IP
  - Traefik: Installation status and version
  - Docker: Version information
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

print_header "Update VPS Edge Node Metadata"

# Determine mode
if [ "$REMOTE_MODE" = true ]; then
    # Remote mode: Update VPS from control plane
    if [ -z "$VPS_NAME" ] || [ -z "$VPS_IP" ]; then
        log_error "Both --name and --ip are required for remote updates"
        exit 1
    fi
    
    log_info "Remote mode: Updating metadata for $VPS_NAME ($VPS_IP)"
    echo
    
    # Verify we're on control plane
    if [ ! -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
        log_error "Control plane configuration not found"
        exit 1
    fi
    
    source "$ACTUAL_HOME/.mynodeone/config.env"
    
    if [ "${NODE_TYPE:-}" != "control-plane" ]; then
        log_error "This script must be run on the control plane for remote updates"
        exit 1
    fi
    
    # Collect metadata from remote VPS
    log_info "Collecting metadata from VPS..."
    
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$VPS_IP" "test -f ~/mynodeone/scripts/lib/collect-vps-metadata.sh" 2>/dev/null; then
        log_error "Metadata collector not found on VPS"
        log_error "Please ensure MyNodeOne is installed on the VPS"
        exit 1
    fi
    
    METADATA_JSON=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$VPS_IP" \
        "sudo bash ~/mynodeone/scripts/lib/collect-vps-metadata.sh json" 2>/dev/null)
    
    if [ -z "$METADATA_JSON" ]; then
        log_error "Failed to collect metadata from VPS"
        exit 1
    fi
    
    log_success "Metadata collected from VPS"
    echo
    
else
    # Local mode: Update own metadata
    log_info "Local mode: Updating metadata for this VPS"
    echo
    
    # Load local config
    if [ ! -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
        log_error "VPS configuration not found at $ACTUAL_HOME/.mynodeone/config.env"
        exit 1
    fi
    
    source "$ACTUAL_HOME/.mynodeone/config.env"
    
    VPS_NAME="${NODE_NAME:-$(hostname)}"
    VPS_IP="${TAILSCALE_IP:-$(tailscale ip -4 2>/dev/null || echo '')}"
    
    if [ -z "$VPS_IP" ]; then
        log_error "Could not determine Tailscale IP"
        exit 1
    fi
    
    # Collect local metadata
    log_info "Collecting metadata..."
    
    if [ ! -f "$METADATA_COLLECTOR" ]; then
        log_error "Metadata collector not found: $METADATA_COLLECTOR"
        exit 1
    fi
    
    chmod +x "$METADATA_COLLECTOR"
    METADATA_JSON=$(bash "$METADATA_COLLECTOR" json)
    
    if [ -z "$METADATA_JSON" ]; then
        log_error "Failed to collect metadata"
        exit 1
    fi
    
    log_success "Metadata collected"
    echo
fi

# Display collected metadata
log_info "Collected metadata:"
echo "$METADATA_JSON" | jq '.'
echo

# Update registry
log_info "Updating cluster registry..."

if [ ! -f "$REGISTRY_MANAGER" ]; then
    log_error "Registry manager not found: $REGISTRY_MANAGER"
    exit 1
fi

# Source the registry manager functions
source "$REGISTRY_MANAGER"

# Call the update function
if update_vps_metadata --name "$VPS_NAME" --metadata-json "$METADATA_JSON"; then
    echo
    log_success "VPS metadata updated successfully!"
    echo
    echo "Node: $VPS_NAME"
    echo "IP: $VPS_IP"
    echo
    echo "To view the updated metadata:"
    echo "  kubectl get configmap sync-controller-registry -n kube-system -o json | jq '.data.\"registry.json\" | fromjson | .vps_nodes[] | select(.name==\"$VPS_NAME\")'"
    echo
else
    echo
    log_error "Failed to update VPS metadata"
    exit 1
fi
