#!/bin/bash

###############################################################################
# Remove VPS Edge Node
#
# This script removes a VPS Edge Node from the Control Plane.
# It unregisters the node from the registry and deletes local configuration files.
#
# Usage:
#   sudo ./scripts/remove-vps-edge-node.sh [NODE_NAME]
###############################################################################

set -euo pipefail

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Detect user
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_HOME="$HOME"
fi

CONFIG_BASE="$ACTUAL_HOME/.mynodeone/vps-nodes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper functions
print_header() {
    echo
    echo -e "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[0;36m  $1\033[0m"
    echo -e "\033[0;36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo
}

print_success() {
    echo -e "\033[0;32m✓\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m✗\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m⚠\033[0m $1"
}

# 1. Select Node
NODE_NAME="${1:-}"

if [ -z "$NODE_NAME" ]; then
    print_header "Remove VPS Edge Node"
    
    if [ ! -d "$CONFIG_BASE" ] || [ -z "$(ls -A "$CONFIG_BASE" 2>/dev/null)" ]; then
        print_error "No VPS configurations found in $CONFIG_BASE"
        exit 1
    fi
    
    echo "Available VPS Nodes:"
    echo
    
    NODES=()
    i=1
    for d in "$CONFIG_BASE"/*; do
        if [ -d "$d" ]; then
            name=$(basename "$d")
            echo "  $i) $name"
            NODES+=("$name")
            ((i++))
        fi
    done
    echo
    
    read -p "Select node to remove (number): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#NODES[@]}" ]; then
        index=$((selection-1))
        NODE_NAME="${NODES[$index]}"
    else
        print_error "Invalid selection"
        exit 1
    fi
fi

NODE_DIR="$CONFIG_BASE/$NODE_NAME"
CONFIG_FILE="$NODE_DIR/config.env"

if [ ! -d "$NODE_DIR" ]; then
    print_error "Configuration for '$NODE_NAME' not found at $NODE_DIR"
    exit 1
fi

# 2. Confirm Removal
echo
print_warning "You are about to remove VPS node: $NODE_NAME"
echo "This will:"
echo "  1. Unregister the node from the control plane registry"
echo "  2. Delete local configuration files ($NODE_DIR)"
echo "  3. Restart the sync controller"
echo
echo "Note: This does NOT uninstall software from the VPS itself."
echo

read -p "Are you sure? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# 3. Get IP for unregistration
VPS_IP=""
if [ -f "$CONFIG_FILE" ]; then
    # Extract IP safely
    VPS_IP=$(grep "^VPS_TAILSCALE_IP=" "$CONFIG_FILE" | cut -d'"' -f2)
fi

if [ -z "$VPS_IP" ]; then
    print_warning "Could not find VPS_TAILSCALE_IP in config."
    read -p "Enter Tailscale IP to unregister (or leave blank to skip unregister): " input_ip
    VPS_IP="$input_ip"
fi

# 4. Perform Removal
print_header "Removing $NODE_NAME..."

# Unregister from ConfigMap
if [ -n "$VPS_IP" ]; then
    echo "Unregistering from domain-registry..."
    if [ -f "$SCRIPT_DIR/lib/multi-domain-registry.sh" ]; then
        bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" unregister-vps "$VPS_IP"
    else
        print_warning "Registry script not found, skipping unregistration."
    fi
    
    # Clean known_hosts
    echo "Cleaning SSH known_hosts..."
    if [ -n "${ACTUAL_USER:-}" ]; then
        su - "$ACTUAL_USER" -c "ssh-keygen -R $VPS_IP" &>/dev/null || true
    fi
else
    print_warning "Skipping registry unregistration (no IP provided)"
fi

# Remove local config
echo "Removing configuration files..."
rm -rf "$NODE_DIR"
print_success "Deleted $NODE_DIR"

# Restart Sync Controller
echo "Restarting sync controller..."
systemctl restart mynodeone-sync-controller 2>/dev/null || true
print_success "Sync controller restarted"

echo
print_header "Removal Complete"
print_success "VPS Edge Node '$NODE_NAME' has been removed from the Control Plane."
echo
