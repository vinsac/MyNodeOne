#!/bin/bash

###############################################################################
# MyNodeOne Nodes Status
#
# Display the status of all nodes in the cluster using the Config API.
#
# Usage:
#   ./scripts/nodes/nodes-status.sh              # List all nodes
#   ./scripts/nodes/nodes-status.sh remove <name> # Remove a node from registry
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load API token
TOKEN_FILE="/etc/mynodeone/api-token"
API_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    API_TOKEN=$(cat "$TOKEN_FILE")
fi

# Get control plane Tailscale IP
CONTROL_PLANE_IP=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
API_PORT="${API_PORT:-8443}"

# Fetch nodes from API
fetch_nodes() {
    local url="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/nodes"
    
    if [[ -n "$API_TOKEN" ]]; then
        curl -s -H "X-API-Token: $API_TOKEN" "$url" 2>/dev/null
    else
        curl -s "$url" 2>/dev/null
    fi
}

# Format timestamp
format_time() {
    local timestamp="$1"
    if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
        echo "never"
        return
    fi
    
    # Parse ISO timestamp and calculate relative time
    local ts_epoch
    ts_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local diff=$((now_epoch - ts_epoch))
    
    if [[ $diff -lt 60 ]]; then
        echo "${diff}s ago"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60))m ago"
    elif [[ $diff -lt 86400 ]]; then
        echo "$((diff / 3600))h ago"
    else
        echo "$((diff / 86400))d ago"
    fi
}

# Status color
status_color() {
    local status="$1"
    case "$status" in
        online)  echo -e "${GREEN}●${NC}" ;;
        stale)   echo -e "${YELLOW}●${NC}" ;;
        offline) echo -e "${RED}●${NC}" ;;
        *)       echo -e "${BLUE}●${NC}" ;;
    esac
}

# Main
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  MyNodeOne Cluster Nodes${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check if API is running
    if ! curl -s -o /dev/null -w "%{http_code}" "http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/health" 2>/dev/null | grep -q "200"; then
        echo -e "${RED}Error: Config API Server is not running${NC}"
        echo ""
        echo "Start it with:"
        echo "  sudo systemctl start mynodeone-config-api"
        echo ""
        exit 1
    fi
    
    # Fetch nodes
    local response
    response=$(fetch_nodes)
    
    if [[ -z "$response" ]]; then
        echo -e "${YELLOW}No nodes registered yet${NC}"
        echo ""
        echo "Nodes will appear here after they send their first heartbeat."
        echo ""
        exit 0
    fi
    
    # Parse and display nodes
    local nodes
    nodes=$(echo "$response" | jq -r '.nodes[]?' 2>/dev/null)
    
    if [[ -z "$nodes" ]]; then
        echo -e "${YELLOW}No nodes registered yet${NC}"
        echo ""
        exit 0
    fi
    
    # Print header
    printf "%-3s %-20s %-8s %-18s %-10s %-12s %s\n" \
        "" "NAME" "TYPE" "IP" "STATUS" "LAST SEEN" "CONFIG"
    printf "%-3s %-20s %-8s %-18s %-10s %-12s %s\n" \
        "" "----" "----" "--" "------" "---------" "------"
    
    # Print each node
    echo "$response" | jq -r '.nodes[] | "\(.name)|\(.type)|\(.ip)|\(.status)|\(.last_heartbeat)|\(.config_version)"' 2>/dev/null | \
    while IFS='|' read -r name type ip status last_heartbeat config_version; do
        local status_icon
        status_icon=$(status_color "$status")
        local last_seen
        last_seen=$(format_time "$last_heartbeat")
        
        printf "%s  %-20s %-8s %-18s %-10s %-12s %s\n" \
            "$status_icon" "$name" "$type" "$ip" "$status" "$last_seen" "$config_version"
    done
    
    echo ""
    
    # Summary
    local total online stale offline
    total=$(echo "$response" | jq '.nodes | length' 2>/dev/null || echo "0")
    online=$(echo "$response" | jq '[.nodes[] | select(.status == "online")] | length' 2>/dev/null || echo "0")
    stale=$(echo "$response" | jq '[.nodes[] | select(.status == "stale")] | length' 2>/dev/null || echo "0")
    offline=$(echo "$response" | jq '[.nodes[] | select(.status == "offline")] | length' 2>/dev/null || echo "0")
    
    echo -e "Total: $total nodes  ${GREEN}●${NC} Online: $online  ${YELLOW}●${NC} Stale: $stale  ${RED}●${NC} Offline: $offline"
    echo ""
}

# Remove a node from the registry
remove_node() {
    local node_name="$1"
    
    if [[ -z "$node_name" ]]; then
        echo -e "${RED}Error: Node name required${NC}"
        echo "Usage: $0 remove <node-name>"
        exit 1
    fi
    
    echo -e "${BLUE}Removing node: $node_name${NC}"
    
    local url="http://${CONTROL_PLANE_IP}:${API_PORT}/api/v1/nodes/${node_name}"
    local response
    
    if [[ -n "$API_TOKEN" ]]; then
        response=$(curl -s -X DELETE -H "X-API-Token: $API_TOKEN" "$url" 2>/dev/null)
    else
        response=$(curl -s -X DELETE "$url" 2>/dev/null)
    fi
    
    if echo "$response" | jq -e '.status == "removed"' &>/dev/null; then
        echo -e "${GREEN}Node '$node_name' removed successfully${NC}"
    else
        echo -e "${RED}Failed to remove node: $response${NC}"
        exit 1
    fi
}

# Parse command
case "${1:-}" in
    remove)
        remove_node "${2:-}"
        ;;
    *)
        main "$@"
        ;;
esac
