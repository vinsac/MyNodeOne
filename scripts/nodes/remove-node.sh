#!/bin/bash

###############################################################################
# Remove Node from Cluster
#
# This script removes a node from the MyNodeOne cluster registry.
# Supports: Management Laptops, VPS Edge Nodes, Worker Nodes
#
# Usage:
#   sudo ./scripts/nodes/remove-node.sh [NODE_NAME]
#   sudo ./scripts/nodes/remove-node.sh --type <type> --name <name>
#   sudo ./scripts/nodes/remove-node.sh --ip <tailscale-ip>
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
REGISTRY_MANAGER="$SCRIPT_DIR/../lib/node-registry-manager.sh"

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
  sudo ./scripts/nodes/remove-node.sh [NODE_NAME]
  sudo ./scripts/nodes/remove-node.sh --type <type> --name <name>
  sudo ./scripts/nodes/remove-node.sh --ip <tailscale-ip>

Options:
  --type <type>    Node type (management_laptops, vps_nodes, worker_nodes)
  --name <name>    Node name
  --ip <ip>        Tailscale IP address
  -h, --help       Show this help message

Examples:
  # Interactive mode (lists all nodes)
  sudo ./scripts/nodes/remove-node.sh

  # Remove by name (auto-detects type)
  sudo ./scripts/nodes/remove-node.sh dev-laptop

  # Remove by type and name
  sudo ./scripts/nodes/remove-node.sh --type management_laptops --name dev-laptop

  # Remove by IP
  sudo ./scripts/nodes/remove-node.sh --ip 100.79.49.125

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

# Get Config API settings
API_PORT="${API_PORT:-8443}"
CONTROL_PLANE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
API_TOKEN=""
if [[ -f /etc/mynodeone/api-token ]]; then
    API_TOKEN=$(cat /etc/mynodeone/api-token 2>/dev/null)
fi

# Fetch nodes from Config API
fetch_nodes() {
    local url="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/nodes"
    
    if [[ -n "$API_TOKEN" ]]; then
        curl -s -H "X-API-Token: $API_TOKEN" "$url" 2>/dev/null
    else
        curl -s "$url" 2>/dev/null
    fi
}

# Get registry (legacy function for compatibility)
get_registry() {
    kubectl get configmap sync-controller-registry -n kube-system \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo '{}'
}

# List all nodes
list_all_nodes() {
    # Check if Config API is running
    if ! curl -s -o /dev/null -w "%{http_code}" "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/health" 2>/dev/null | grep -q "200"; then
        log_error "Config API Server is not running"
        echo
        echo "Start it with:"
        echo "  sudo systemctl start mynodeone-config-api"
        echo
        exit 1
    fi
    
    # Fetch nodes from Config API
    local response=$(fetch_nodes)
    
    if [[ -z "$response" ]]; then
        log_error "No nodes found in registry"
        exit 1
    fi
    
    echo "Available nodes:"
    echo
    
    local i=1
    declare -g -A NODE_MAP
    
    # Get control plane name from ConfigMap to exclude it
    local registry=$(get_registry)
    local control_plane_name=$(echo "$registry" | jq -r '.cluster_nodes[] | select(.role == "control-plane") | .name' 2>/dev/null | head -1)
    
    # Group nodes by type
    local has_laptops=false
    local has_vps=false
    local has_workers=false
    
    # Parse nodes and group by type (use process substitution to avoid subshell)
    while IFS='|' read -r name type ip status; do
        [[ -z "$name" ]] && continue
        
        # Skip control-plane node
        if [[ "$name" == "$control_plane_name" ]]; then
            continue
        fi
        
        case "$type" in
            laptop)
                if [[ "$has_laptops" == "false" ]]; then
                    echo -e "${CYAN}Management Laptops:${NC}"
                    has_laptops=true
                fi
                echo "  $i) $name (IP: $ip, Status: $status)"
                NODE_MAP[$i]="laptop|$name|$ip"
                ((i++))
                ;;
            vps)
                if [[ "$has_vps" == "false" ]]; then
                    echo -e "${CYAN}VPS Edge Nodes:${NC}"
                    has_vps=true
                fi
                echo "  $i) $name (IP: $ip, Status: $status)"
                NODE_MAP[$i]="vps|$name|$ip"
                ((i++))
                ;;
            worker)
                if [[ "$has_workers" == "false" ]]; then
                    echo -e "${CYAN}Worker Nodes:${NC}"
                    has_workers=true
                fi
                echo "  $i) $name (IP: $ip, Status: $status)"
                NODE_MAP[$i]="worker|$name|$ip"
                ((i++))
                ;;
        esac
    done < <(echo "$response" | jq -r '.nodes[] | "\(.name)|\(.type)|\(.ip)|\(.status)"' 2>/dev/null)
    
    if [[ $i -eq 1 ]]; then
        log_error "No removable nodes found"
        exit 1
    fi
    
    echo
    read -p "Select node to remove (number): " selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ -z "${NODE_MAP[$selection]:-}" ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    IFS='|' read -r NODE_TYPE NODE_NAME NODE_IP <<< "${NODE_MAP[$selection]}"
}

# Find node by name or IP
find_node() {
    local search_name="$1"
    local search_ip="$2"
    
    # Check if Config API is running
    if ! curl -s -o /dev/null -w "%{http_code}" "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/health" 2>/dev/null | grep -q "200"; then
        log_error "Config API Server is not running"
        exit 1
    fi
    
    # Fetch nodes from Config API
    local response=$(fetch_nodes)
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    # Get control plane name from ConfigMap to exclude it
    local registry=$(get_registry)
    local control_plane_name=$(echo "$registry" | jq -r '.cluster_nodes[] | select(.role == "control-plane") | .name' 2>/dev/null | head -1)
    
    # Try to find by name first
    if [[ -n "$search_name" ]]; then
        # Check if it's the control-plane node
        if [[ "$search_name" == "$control_plane_name" ]]; then
            log_error "Cannot remove control-plane node: $search_name"
            exit 1
        fi
        
        local found=$(echo "$response" | jq -r \
            --arg name "$search_name" \
            '.nodes[] | select(.name == $name) | "\(.name)|\(.type)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_TYPE NODE_IP <<< "$found"
            return 0
        fi
    fi
    
    # Try to find by IP
    if [[ -n "$search_ip" ]]; then
        local found=$(echo "$response" | jq -r \
            --arg ip "$search_ip" \
            '.nodes[] | select(.ip == $ip) | "\(.name)|\(.type)|\(.ip)"' 2>/dev/null)
        
        if [[ -n "$found" ]]; then
            IFS='|' read -r NODE_NAME NODE_TYPE NODE_IP <<< "$found"
            
            # Check if it's the control-plane node
            if [[ "$NODE_NAME" == "$control_plane_name" ]]; then
                log_error "Cannot remove control-plane node: $NODE_NAME"
                exit 1
            fi
            
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
    
    log_info "Removing $name from Config API registry..."
    
    # Remove from Config API
    local url="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/nodes/${name}"
    local response
    
    if [[ -n "$API_TOKEN" ]]; then
        response=$(curl -s -X DELETE -H "X-API-Token: $API_TOKEN" "$url" 2>/dev/null)
    else
        response=$(curl -s -X DELETE "$url" 2>/dev/null)
    fi
    
    if echo "$response" | jq -e '.status == "removed"' &>/dev/null; then
        log_success "Removed from Config API registry"
    else
        log_error "Failed to remove from Config API: $response"
        return 1
    fi
    
    # Also remove from ConfigMap if present
    log_info "Removing $name from ConfigMap registry..."
    local registry=$(get_registry)
    
    # Check if node exists in ConfigMap
    local in_configmap=false
    if echo "$registry" | jq -e ".management_laptops[]? | select(.name == \"$name\")" &>/dev/null || \
       echo "$registry" | jq -e ".vps_nodes[]? | select(.name == \"$name\")" &>/dev/null || \
       echo "$registry" | jq -e ".cluster_nodes[]? | select(.name == \"$name\")" &>/dev/null; then
        in_configmap=true
    fi
    
    if [[ "$in_configmap" == "true" ]]; then
        # Remove from all arrays in ConfigMap
        local updated_registry="$registry"
        updated_registry=$(echo "$updated_registry" | jq \
            --arg name "$name" \
            '.management_laptops |= map(select(.name != $name)) |
             .vps_nodes |= map(select(.name != $name)) |
             .cluster_nodes |= map(select(.name != $name))')
        
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
        
        log_success "Removed from ConfigMap registry"
    else
        log_info "Node not found in ConfigMap (already clean)"
    fi
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
        vps)
            local vps_config="$ACTUAL_HOME/.mynodeone/vps-nodes/$name"
            if [[ -d "$vps_config" ]]; then
                log_info "Removing VPS configuration files..."
                rm -rf "$vps_config"
                log_success "Deleted $vps_config"
            fi
            ;;
        laptop)
            log_info "No local configuration files to clean for management laptops"
            ;;
        worker)
            log_info "No local configuration files to clean for worker nodes"
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
    echo "    sudo ./scripts/installation/uninstall-mynodeone.sh"
    echo
}

main
