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
    local services="{}"
    local services_output
    if services_output=$(kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null); then
        services="$services_output"
    else
        echo "[$(date)] WARNING: Could not fetch service registry, using empty object"
        services="{}"
    fi
    
    if [ "$services" != "{}" ]; then
        # Transform to array format for easier JavaScript consumption
        local services_array
        if services_array=$(echo "$services" | jq -c '[
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
        ]' 2>/dev/null); then
            # Write to temp file then move (atomic)
            echo "$services_array" > "$OUTPUT_DIR/services.json.tmp"
            mv "$OUTPUT_DIR/services.json.tmp" "$OUTPUT_DIR/services.json"
            
            local count=$(echo "$services_array" | jq 'length')
            echo "[$(date)] Exported $count services"
        else
            echo "[$(date)] ERROR: Failed to parse services JSON, creating empty array"
            echo '[]' > "$OUTPUT_DIR/services.json.tmp"
            mv "$OUTPUT_DIR/services.json.tmp" "$OUTPUT_DIR/services.json"
        fi
    else
        echo "[$(date)] No services found in registry"
        echo '[]' > "$OUTPUT_DIR/services.json"
    fi
}

# Export nodes function
export_nodes() {
    # Try to get comprehensive node data from Config API first
    local config_api_nodes="{}"
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
        config_api_nodes=$(curl -s -H "X-API-Token: $api_token" "http://${control_plane_ip}:${api_port}/api/v1/nodes" 2>/dev/null || echo "{}")
    fi
    
    # Check if Config API returned valid data
    if [[ "$config_api_nodes" != "{}" ]] && echo "$config_api_nodes" | jq -e '.nodes' &>/dev/null; then
        # Use Config API data - includes VPS nodes and management laptops
        echo "$config_api_nodes" > "$OUTPUT_DIR/nodes.json.tmp"
        mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
        
        local count=$(echo "$config_api_nodes" | jq '.nodes | length')
        echo "[$(date)] Exported $count nodes from Config API"
    else
        # Fallback to Kubernetes nodes only
        echo "[$(date)] Config API unavailable, falling back to Kubernetes nodes"
        
        # Get node metrics (if accessible)
        local metrics_json="{}"
        if kubectl top nodes &>/dev/null; then
            metrics_json=$(kubectl top nodes --no-headers | awk '{gsub("%","",$3); gsub("%","",$5); printf "\"%s\":{\"cpu\":%s,\"memory\":%s},", $1, $3, $5}' | sed 's/,$//')
            metrics_json="{${metrics_json}}"
        fi

        # Ensure kubectl command succeeds and returns valid JSON
        local nodes_kubectl_output
        if nodes_kubectl_output=$(kubectl get nodes -o json 2>/dev/null); then
            # Validate metrics_json is valid JSON or set to empty object
            if ! echo "$metrics_json" | jq . &>/dev/null; then
                metrics_json="{}"
            fi
            
            local nodes_json=$(echo "$nodes_kubectl_output" | jq -c --argjson metrics "$metrics_json" '[
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
            
            # Validate the generated JSON
            if echo "$nodes_json" | jq . &>/dev/null; then
                echo "$nodes_json" > "$OUTPUT_DIR/nodes.json.tmp"
                mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
                
                local count=$(echo "$nodes_json" | jq 'length')
                echo "[$(date)] Exported $count Kubernetes nodes (fallback)"
            else
                echo "[$(date)] ERROR: Failed to generate valid nodes JSON, creating empty array"
                echo '[]' > "$OUTPUT_DIR/nodes.json.tmp"
                mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
            fi
        else
            echo "[$(date)] ERROR: Failed to get nodes from kubectl, creating empty array"
            echo '[]' > "$OUTPUT_DIR/nodes.json.tmp"
            mv "$OUTPUT_DIR/nodes.json.tmp" "$OUTPUT_DIR/nodes.json"
        fi
    fi
}

# Export cluster overview function
export_cluster() {
    # Get Kubernetes node counts for cluster overview (primary source)
    local total_nodes=0
    local ready_nodes=0
    
    # Always use Kubernetes nodes for cluster overview - this shows cluster health
    local kubectl_output
    if kubectl_output=$(kubectl get nodes --no-headers 2>/dev/null); then
        total_nodes=$(echo "$kubectl_output" | wc -l)
        # Count only nodes with "Ready" status, not "NotReady" or other states
        ready_nodes=$(echo "$kubectl_output" | awk '$2 == "Ready" {count++} END {print count+0}')
        echo "[$(date)] Cluster Overview: Using Kubernetes node counts: $ready_nodes/$total_nodes ready"
    else
        echo "[$(date)] ERROR: Failed to get nodes from kubectl, using zero counts"
        total_nodes=0
        ready_nodes=0
    fi
    
    local total_pods=0
    local running_pods=0
    local pods_output
    if pods_output=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null); then
        total_pods=$(echo "$pods_output" | wc -l)
        running_pods=$(echo "$pods_output" | grep -c "Running" || echo "0")
    else
        echo "[$(date)] ERROR: Failed to get pods from kubectl, using zero counts"
    fi
    
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
