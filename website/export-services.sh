#!/bin/bash
###############################################################################
# Cluster Status Exporter
# 
# Runs as sidecar in dashboard pod to export cluster status to JSON
# Dashboard JavaScript can then fetch:
# - /api/services.json for service registry
# - /api/nodes.json for node status
# - /api/cluster.json for cluster overview
###############################################################################

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/usr/share/nginx/html/api}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-30}"

echo "[$(date)] Cluster Status Exporter starting..."
echo "[$(date)] Output dir: $OUTPUT_DIR"
echo "[$(date)] Refresh interval: ${REFRESH_INTERVAL}s"

# Create API directory
mkdir -p "$OUTPUT_DIR"

# Export services function
export_services() {
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    if [ "$services" != "{}" ]; then
        # Transform to array format for easier JavaScript consumption
        local services_array=$(echo "$services" | jq -c '[
            to_entries[] | 
            {
                name: .key,
                subdomain: .value.subdomain,
                namespace: .value.namespace,
                service: .value.service,
                ip: .value.ip,
                port: .value.port,
                public: (.value.public // false)
            }
        ]')
        
        # Write to temp file then move (atomic)
        echo "$services_array" > "$OUTPUT_DIR/services.json.tmp"
        mv "$OUTPUT_DIR/services.json.tmp" "$OUTPUT_DIR/services.json"
        
        local count=$(echo "$services_array" | jq 'length')
        echo "[$(date)] Exported $count services"
    else
        echo "[$(date)] No services found in registry"
        echo '[]' > "$OUTPUT_DIR/services.json"
    fi
}

# Export nodes function
export_nodes() {
    # Try to get comprehensive node data from nodes-status.sh script first
    if [[ -x "/scripts/nodes-status.sh" ]]; then
        echo "[$(date)] Using nodes-status.sh script for comprehensive node data"
        
        # Run nodes-status.sh script and capture output
        local nodes_output=$(timeout 15 /scripts/nodes-status.sh 2>/dev/null || echo "")
        
        if [[ -n "$nodes_output" ]] && echo "$nodes_output" | grep -q "Total:"; then
            # Parse the output to create a JSON structure
            local total_nodes=$(echo "$nodes_output" | grep "Total:" | awk '{print $2}')
            local online_nodes=$(echo "$nodes_output" | grep "Total:" | awk '{print $5}')
            
            # Create a simple JSON structure with node count
            local nodes_json=$(jq -n --arg total "$total_nodes" --arg online "$online_nodes" '{
                nodes: [
                    {
                        name: "cluster-nodes",
                        type: "summary",
                        status: "online",
                        total_nodes: ($total | tonumber),
                        online_nodes: ($online | tonumber),
                        last_heartbeat: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
                    }
                ]
            }')
            
            echo "$nodes_json" > "$OUTPUT_DIR/nodes.json.tmp"
            mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
            
            echo "[$(date)] Exported $total_nodes total nodes ($online_nodes online) from nodes-status.sh"
            return
        fi
    fi
    
    # Fallback to Kubernetes nodes only
    echo "[$(date)] nodes-status.sh not available, falling back to Kubernetes nodes"
    
    # Get node metrics (if accessible)
    local metrics_json="{}"
    if kubectl top nodes &>/dev/null; then
        metrics_json=$(kubectl top nodes --no-headers | awk '{gsub("%","",$3); gsub("%","",$5); printf "\"%s\":{\"cpu\":%s,\"memory\":%s},", $1, $3, $5}' | sed 's/,$//')
        metrics_json="{${metrics_json}}"
    fi

    local nodes_json=$(kubectl get nodes -o json | jq -c --argjson metrics "$metrics_json" '[
        .items[] | {
            name: .metadata.name,
            status: .status.conditions[] | select(.type=="Ready") | .status,
            roles: .metadata.labels // {} | with_entries(select(.key | endswith("-node"))) | keys,
            os: .status.nodeInfo.osImage,
            kernel: .status.nodeInfo.kernelVersion,
            kubernetes: .status.nodeInfo.kubeletVersion,
            created: .metadata.creationTimestamp,
            usage: ($metrics[.metadata.name] // {cpu: 0, memory: 0}),
            capacity: {
                cpu: .status.capacity.cpu,
                memory: .status.capacity.memory,
                storage: .status.capacity["ephemeral-storage"],
                pods: .status.capacity.pods
            },
            allocatable: {
                cpu: .status.allocatable.cpu,
                memory: .status.allocatable.memory,
                storage: .status.allocatable["ephemeral-storage"],
                pods: .status.allocatable.pods
            }
        }
    ]')
    
    echo "$nodes_json" > "$OUTPUT_DIR/nodes.json.tmp"
    mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
    
    local count=$(echo "$nodes_json" | jq 'length')
    echo "[$(date)] Exported $count Kubernetes nodes (fallback)"
}

# Export cluster overview function
export_cluster() {
    # Try to get comprehensive node count from Config API first
    local total_nodes=0
    local ready_nodes=0
    local control_plane_ip=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
    local api_port="8443"
    
    # Get API token
    local api_token=""
    if [[ -r "/etc/mynodeone/api-token" ]]; then
        api_token=$(cat "/etc/mynodeone/api-token")
        echo "[$(date)] API token found and readable"
    else
        echo "[$(date)] API token not found or not readable"
    fi
    
    # Fetch from Config API
    if [[ -n "$api_token" ]]; then
        local config_api_nodes=$(curl -s -H "X-API-Token: $api_token" "http://${control_plane_ip}:${api_port}/api/v1/nodes" 2>/dev/null || echo "{}")
        
        if [[ "$config_api_nodes" != "{}" ]] && echo "$config_api_nodes" | jq -e '.nodes' &>/dev/null; then
            total_nodes=$(echo "$config_api_nodes" | jq '.nodes | length')
            ready_nodes=$(echo "$config_api_nodes" | jq '[.nodes[] | select(.status == "online")] | length')
            echo "[$(date)] Using Config API node counts: $ready_nodes/$total_nodes online"
        fi
    fi
    
    # Fallback to Kubernetes nodes if Config API unavailable
    if [[ $total_nodes -eq 0 ]]; then
        total_nodes=$(kubectl get nodes --no-headers | wc -l)
        ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready")
        echo "[$(date)] Using Kubernetes node counts: $ready_nodes/$total_nodes ready"
    fi
    
    local total_pods=$(kubectl get pods --all-namespaces --no-headers | wc -l)
    local running_pods=$(kubectl get pods --all-namespaces --no-headers | grep -c "Running")
    
    # Get storage info (simplified)
    local storage_info='{}'
    if kubectl get storageclass longhorn &>/dev/null; then
        storage_info=$(kubectl get pvc --all-namespaces -o json | jq -c '{
            total_pvc: length,
            bound_pvc: [.items[] | select(.status.phase=="Bound")] | length
        }' 2>/dev/null || echo '{}')
    fi
    
    local cluster_json=$(jq -n -c --arg total_nodes "$total_nodes" \
        --arg ready_nodes "$ready_nodes" \
        --arg total_pods "$total_pods" \
        --arg running_pods "$running_pods" \
        --argjson storage "$storage_info" '{
        nodes: {
            total: ($total_nodes | tonumber),
            ready: ($ready_nodes | tonumber)
        },
        pods: {
            total: ($total_pods | tonumber),
            running: ($running_pods | tonumber)
        },
        storage: $storage,
        timestamp: now
    }')
    
    echo "$cluster_json" > "$OUTPUT_DIR/cluster.json.tmp"
    mv "$OUTPUT_DIR/cluster.json.tmp" "$OUTPUT_DIR/cluster.json"
    
    echo "[$(date)] Exported cluster overview: $ready_nodes/$total_nodes nodes, $running_pods/$total_pods pods"
}

# Export cluster configuration function
export_cluster_config() {
    # Get cluster domain from config.env
    local cluster_domain="mynodeone"
    local cluster_name="mynodeone"
    
    # Try to read from config.env in multiple locations
    local config_locations=(
        "/etc/cluster-config/config.env"
        "/etc/mynodeone/config.env"
        "$HOME/.mynodeone/config.env"
        "/home/vinaysachdeva1/.mynodeone/config.env"
    )
    
    for config_file in "${config_locations[@]}"; do
        if [[ -f "$config_file" ]]; then
            echo "[$(date)] Found config at: $config_file"
            source "$config_file"
            cluster_domain="${CLUSTER_DOMAIN:-mynodeone}"
            cluster_name="${CLUSTER_NAME:-mynodeone}"
            break
        fi
    done
    
    # Create cluster config JSON
    local config_json=$(jq -n --arg domain "$cluster_domain" --arg name "$cluster_name" '{
        CLUSTER_DOMAIN: $domain,
        CLUSTER_NAME: $name
    }')
    
    echo "$config_json" > "$OUTPUT_DIR/cluster-config.json.tmp"
    mv "$OUTPUT_DIR/cluster-config.json.tmp" "$OUTPUT_DIR/cluster-config.json"
    
    echo "[$(date)] Exported cluster config: $cluster_domain (name: $cluster_name)"
}

# Export all data
export_all() {
    export_services
    export_nodes
    export_cluster
    export_cluster_config
}

# Initial export
export_all

# Watch loop
while true; do
    sleep "$REFRESH_INTERVAL"
    export_all
done
