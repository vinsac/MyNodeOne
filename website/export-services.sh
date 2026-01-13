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
    local nodes_json=$(kubectl get nodes -o json | jq -c '[
        .items[] | {
            name: .metadata.name,
            status: .status.conditions[] | select(.type=="Ready") | .status,
            roles: .metadata.labels // {} | with_entries(select(.key | endswith("-node"))) | keys,
            os: .status.nodeInfo.osImage,
            kernel: .status.nodeInfo.kernelVersion,
            kubernetes: .status.nodeInfo.kubeletVersion,
            created: .metadata.creationTimestamp,
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
    echo "[$(date)] Exported $count nodes"
}

# Export cluster overview function
export_cluster() {
    # Get basic cluster info
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready")
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
    
    local cluster_json=$(jq -c --arg total_nodes "$total_nodes" \
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
        storage: $storage_info,
        timestamp: now
    }')
    
    echo "$cluster_json" > "$OUTPUT_DIR/cluster.json.tmp"
    mv "$OUTPUT_DIR/cluster.json.tmp" "$OUTPUT_DIR/cluster.json"
    
    echo "[$(date)] Exported cluster overview"
}

# Export all data
export_all() {
    export_services
    export_nodes
    export_cluster
}

# Initial export
export_all

# Watch loop
while true; do
    sleep "$REFRESH_INTERVAL"
    export_all
done
