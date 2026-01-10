#!/bin/bash

###############################################################################
# Remove Node from Cluster
#
# This script removes a node from the MyNodeOne cluster registry.
# Supports: Management Laptops, VPS Edge Nodes, Worker Nodes
#
# Usage:
#   sudo ./scripts/remove-node.sh [NODE_NAME]
#   sudo ./scripts/remove-node.sh --type <type> --name <name>
#   sudo ./scripts/remove-node.sh --ip <tailscale-ip>
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_MANAGER="$SCRIPT_DIR/lib/node-registry-manager.sh"

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

# Parse arguments
NODE_TYPE=""
NODE_NAME=""
NODE_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            NODE_TYPE="$2"
            shift 2
            ;;
        --name)
            NODE_NAME="$2"
            shift 2
            ;;
        --ip)
            NODE_IP="$2"
            shift 2
            ;;
        -h|--help)
            cat << 'EOF'
Remove Node from Cluster

Usage:
  sudo ./scripts/remove-node.sh [NODE_NAME]
  sudo ./scripts/remove-node.sh --type <type> --name <name>
  sudo ./scripts/remove-node.sh --ip <tailscale-ip>

Options:
  --type <type>    Node type (management_laptops, vps_nodes, worker_nodes)
  --name <name>    Node name
  --ip <ip>        Tailscale IP address
  -h, --help       Show this help message

Examples:
  # Interactive mode (lists all nodes)
  sudo ./scripts/remove-node.sh

  # Remove by name (auto-detects type)
  sudo ./scripts/remove-node.sh vinay-vivobook

  # Remove by type and name
  sudo ./scripts/remove-node.sh --type management_laptops --name vinay-vivobook

  # Remove by IP
  sudo ./scripts/remove-node.sh --ip 100.79.49.125

What this script does:
  1. Removes node from sync-controller-registry ConfigMap
  2. Cleans up SSH known_hosts entries
  3. Removes local configuration files (if applicable)
  4. Restarts sync-controller service

What this script does NOT do:
  - Does NOT uninstall software from the node itself
  - Does NOT remove Kubernetes worker nodes (use kubectl delete node)
  - Does NOT delete data or services on the node
EOF
            exit 0
            ;;
        *)
            # Assume it's a node name
            NODE_NAME="$1"
            shift
            ;;
    esac
done

# Get registry
get_registry() {
    kubectl get configmap sync-controller-registry -n kube-system \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo '{}'
}

# List all nodes
list_all_nodes() {
    local registry=$(get_registry)
    
    echo "Available nodes:"
    echo
    
    local i=1
    declare -g -A NODE_MAP
    
    # Management Laptops (exclude control-plane nodes)
    local laptop_count=$(echo "$registry" | jq '.management_laptops | length')
    if [[ "$laptop_count" -gt 0 ]]; then
        local has_laptops=false
        while IFS='|' read -r name ip status last_seen; do
            [[ -z "$name" ]] && continue
            
            # Check if this node is also a control-plane in cluster_nodes
            local is_control_plane=$(echo "$registry" | jq -r \
                --arg name "$name" \
                '.cluster_nodes[] | select(.name == $name and .role == "control-plane") | .name' 2>/dev/null)
            
            # Skip control-plane nodes
            if [[ -n "$is_control_plane" ]]; then
                continue
            fi
            
            if [[ "$has_laptops" == "false" ]]; then
                echo -e "${CYAN}Management Laptops:${NC}"
                has_laptops=true
            fi
            
            echo "  $i) $name (IP: $ip, Status: $status)"
            NODE_MAP[$i]="management_laptops|$name|$ip"
            ((i++))
        done < <(echo "$registry" | jq -r '.management_laptops[] | "\(.name // "unknown")|\(.ip)|\(.status // "unknown")|\(.last_sync // "never")"')
        
        if [[ "$has_laptops" == "true" ]]; then
            echo
        fi
    fi
    
    # VPS Nodes
    local vps_count=$(echo "$registry" | jq '.vps_nodes | length')
    if [[ "$vps_count" -gt 0 ]]; then
        echo -e "${CYAN}VPS Edge Nodes:${NC}"
        while IFS='|' read -r name ip status last_seen; do
            [[ -z "$name" ]] && continue
            echo "  $i) $name (IP: $ip, Status: $status)"
            NODE_MAP[$i]="vps_nodes|$name|$ip"
            ((i++))
        done < <(echo "$registry" | jq -r '.vps_nodes[] | "\(.name // "unknown")|\(.ip)|\(.status // "unknown")|\(.last_sync // "never")"')
        echo
    fi
    
    # Worker Nodes from cluster_nodes (exclude control-plane)
    local cluster_worker_count=$(echo "$registry" | jq '[.cluster_nodes[] | select(.role == "worker")] | length')
    if [[ "$cluster_worker_count" -gt 0 ]]; then
        echo -e "${CYAN}Worker Nodes:${NC}"
        while IFS='|' read -r name ip role status; do
            [[ -z "$name" ]] && continue
            echo "  $i) $name (IP: $ip, Role: $role, Status: $status)"
            NODE_MAP[$i]="cluster_nodes|$name|$ip"
            ((i++))
        done < <(echo "$registry" | jq -r '.cluster_nodes[] | select(.role == "worker") | "\(.name // "unknown")|\(.tailscale_ip // .ip)|\(.role)|\(.status // "unknown")"')
        echo
    fi
    
    if [[ $i -eq 1 ]]; then
        log_error "No nodes found in registry"
        exit 1
    fi
    
    read -p "Select node to remove (number): " selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ -z "${NODE_MAP[$selection]:-}" ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    IFS='|' read -r NODE_TYPE NODE_NAME NODE_IP <<< "${NODE_MAP[$selection]}"
}

# Find node by name or IP
find_node() {
    local registry=$(get_registry)
    local search_name="$1"
    local search_ip="$2"
    
    # Try to find by name first
    if [[ -n "$search_name" ]]; then
        # Check management_laptops (exclude control-plane)
        local found=$(echo "$registry" | jq -r \
            --arg name "$search_name" \
            '.management_laptops[] | select(.name == $name) | "\(.name)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            
            # Check if it's a control-plane node
            local is_control_plane=$(echo "$registry" | jq -r \
                --arg name "$NODE_NAME" \
                '.cluster_nodes[] | select(.name == $name and .role == "control-plane") | .name' 2>/dev/null)
            
            if [[ -n "$is_control_plane" ]]; then
                log_error "Cannot remove control-plane node: $NODE_NAME"
                exit 1
            fi
            
            NODE_TYPE="management_laptops"
            return 0
        fi
        
        # Check vps_nodes
        found=$(echo "$registry" | jq -r \
            --arg name "$search_name" \
            '.vps_nodes[] | select(.name == $name) | "\(.name)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            NODE_TYPE="vps_nodes"
            return 0
        fi
        
        # Check cluster_nodes (workers only)
        found=$(echo "$registry" | jq -r \
            --arg name "$search_name" \
            '.cluster_nodes[] | select(.name == $name and .role == "worker") | "\(.name)|\(.tailscale_ip // .ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            NODE_TYPE="cluster_nodes"
            return 0
        fi
    fi
    
    # Try to find by IP
    if [[ -n "$search_ip" ]]; then
        # Check management_laptops (exclude control-plane)
        local found=$(echo "$registry" | jq -r \
            --arg ip "$search_ip" \
            '.management_laptops[] | select(.ip == $ip) | "\(.name)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            
            # Check if it's a control-plane node
            local is_control_plane=$(echo "$registry" | jq -r \
                --arg name "$NODE_NAME" \
                '.cluster_nodes[] | select(.name == $name and .role == "control-plane") | .name' 2>/dev/null)
            
            if [[ -n "$is_control_plane" ]]; then
                log_error "Cannot remove control-plane node: $NODE_NAME"
                exit 1
            fi
            
            NODE_TYPE="management_laptops"
            return 0
        fi
        
        # Check vps_nodes
        found=$(echo "$registry" | jq -r \
            --arg ip "$search_ip" \
            '.vps_nodes[] | select(.ip == $ip) | "\(.name)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            NODE_TYPE="vps_nodes"
            return 0
        fi
        
        # Check cluster_nodes (workers only)
        found=$(echo "$registry" | jq -r \
            --arg ip "$search_ip" \
            '.cluster_nodes[] | select((.tailscale_ip // .ip) == $ip and .role == "worker") | "\(.name)|\(.tailscale_ip // .ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_IP <<< "$found"
            NODE_TYPE="cluster_nodes"
            return 0
        fi
    fi
    
    return 1
}

# Remove node from registry
remove_from_registry() {
    local type="$1"
    local name="$2"
    local ip="$3"
    
    log_info "Removing $name from registry..."
    
    # Get current registry
    local registry=$(get_registry)
    
    # Remove node from appropriate array(s)
    local updated_registry="$registry"
    
    if [[ "$type" == "cluster_nodes" ]]; then
        # Remove from cluster_nodes array
        updated_registry=$(echo "$updated_registry" | jq \
            --arg name "$name" \
            '.cluster_nodes |= map(select(.name != $name))')
    else
        # Remove from specified array (management_laptops, vps_nodes)
        updated_registry=$(echo "$updated_registry" | jq \
            --arg type "$type" \
            --arg name "$name" \
            'if .[$type] then .[$type] |= map(select(.name != $name)) else . end')
    fi
    
    # Update metadata
    updated_registry=$(echo "$updated_registry" | jq \
        --arg timestamp "$(date -Iseconds)" \
        --arg updated_by "$(whoami)@$(hostname)" \
        '.metadata.last_updated = $timestamp | .metadata.updated_by = $updated_by')
    
    # Update ConfigMap
    kubectl patch configmap sync-controller-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"registry.json\":\"$(echo "$updated_registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Removed from registry"
}

# Clean SSH known_hosts
clean_ssh_known_hosts() {
    local ip="$1"
    
    log_info "Cleaning SSH known_hosts..."
    
    if [[ -n "${ACTUAL_USER:-}" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
        su - "$ACTUAL_USER" -c "ssh-keygen -R $ip" &>/dev/null || true
    fi
    
    # Also clean root's known_hosts if running as sudo
    ssh-keygen -R "$ip" &>/dev/null || true
    
    log_success "SSH known_hosts cleaned"
}

# Clean local config files
clean_local_config() {
    local type="$1"
    local name="$2"
    
    case "$type" in
        vps_nodes)
            local vps_config="$ACTUAL_HOME/.mynodeone/vps-nodes/$name"
            if [[ -d "$vps_config" ]]; then
                log_info "Removing VPS configuration files..."
                rm -rf "$vps_config"
                log_success "Deleted $vps_config"
            fi
            ;;
        management_laptops)
            log_info "No local configuration files to clean for management laptops"
            ;;
        cluster_nodes)
            log_info "No local configuration files to clean for cluster nodes"
            log_warn "Remember to also run: kubectl delete node $name"
            ;;
    esac
}

# Main
main() {
    print_header "Remove Node from Cluster"
    
    # Interactive mode if no arguments
    if [[ -z "$NODE_TYPE" ]] && [[ -z "$NODE_NAME" ]] && [[ -z "$NODE_IP" ]]; then
        list_all_nodes
    else
        # Find node by name or IP
        if ! find_node "$NODE_NAME" "$NODE_IP"; then
            log_error "Node not found in registry"
            exit 1
        fi
    fi
    
    # Confirm removal
    echo
    log_warn "You are about to remove node: $NODE_NAME ($NODE_TYPE)"
    echo "IP: $NODE_IP"
    echo
    echo "This will:"
    echo "  1. Remove the node from sync-controller-registry ConfigMap"
    echo "  2. Clean SSH known_hosts entries"
    echo "  3. Remove local configuration files (if applicable)"
    echo "  4. Restart sync-controller service"
    echo
    echo -e "${YELLOW}Note: This does NOT:${NC}"
    echo "  - Uninstall software from the node itself"
    echo "  - Remove Kubernetes worker nodes (use: kubectl delete node <name>)"
    echo "  - Delete data or services on the node"
    echo
    
    read -p "Are you sure? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
    
    # Perform removal
    print_header "Removing $NODE_NAME..."
    
    remove_from_registry "$NODE_TYPE" "$NODE_NAME" "$NODE_IP"
    clean_ssh_known_hosts "$NODE_IP"
    clean_local_config "$NODE_TYPE" "$NODE_NAME"
    
    # Restart sync controller
    log_info "Restarting sync-controller..."
    systemctl restart mynodeone-sync-controller 2>/dev/null || true
    log_success "Sync-controller restarted"
    
    # Success
    print_header "Removal Complete"
    log_success "Node '$NODE_NAME' has been removed from the cluster registry."
    echo
    echo "Next steps:"
    echo "  - If this was a worker node, also run: kubectl delete node $NODE_NAME"
    echo "  - If you want to uninstall MyNodeOne from the node, SSH to it and run:"
    echo "    sudo ./scripts/uninstall-mynodeone.sh"
    echo
}

main
