#!/bin/bash

###############################################################################
# Cluster Resource Detection Utilities
# 
# Provides functions to detect total cluster resources across all nodes
# Used by installation scripts to make resource-aware decisions
###############################################################################

# Get total CPU cores across all nodes in the cluster
get_cluster_cpu() {
    kubectl get nodes -o jsonpath='{.items[*].status.capacity.cpu}' 2>/dev/null | \
        tr ' ' '\n' | \
        awk '{s+=$1}END{print s}'
}

# Get total RAM in GB across all nodes in the cluster
get_cluster_ram_gb() {
    local total_ram_kb=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.memory}' 2>/dev/null | \
        tr ' ' '\n' | \
        sed 's/Ki//' | \
        awk '{s+=$1}END{print s}')
    echo $((total_ram_kb / 1024 / 1024))
}

# Get total RAM in KB across all nodes in the cluster
get_cluster_ram_kb() {
    kubectl get nodes -o jsonpath='{.items[*].status.capacity.memory}' 2>/dev/null | \
        tr ' ' '\n' | \
        sed 's/Ki//' | \
        awk '{s+=$1}END{print s}'
}

# Get total GPU count across all nodes in the cluster
get_cluster_gpu_count() {
    kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | \
        tr ' ' '\n' | \
        grep -v '^$' | \
        paste -sd+ | \
        bc 2>/dev/null || echo "0"
}

# Check if cluster has any GPUs
has_cluster_gpu() {
    local gpu_count=$(get_cluster_gpu_count)
    [ "$gpu_count" -gt 0 ] 2>/dev/null && return 0 || return 1
}

# Get number of nodes in the cluster
get_cluster_node_count() {
    kubectl get nodes --no-headers 2>/dev/null | wc -l
}

# Get number of ready nodes in the cluster
get_cluster_ready_node_count() {
    kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready "
}

# Print cluster resource summary
print_cluster_resources() {
    local cpu=$(get_cluster_cpu)
    local ram_gb=$(get_cluster_ram_gb)
    local gpu_count=$(get_cluster_gpu_count)
    local node_count=$(get_cluster_node_count)
    local ready_nodes=$(get_cluster_ready_node_count)
    
    echo "📊 Cluster Resources (across $ready_nodes/$node_count nodes):"
    echo "   • CPU Cores: $cpu"
    echo "   • RAM: ${ram_gb}GB"
    if [ "$gpu_count" -gt 0 ]; then
        echo "   • GPUs: $gpu_count NVIDIA GPU(s)"
    else
        echo "   • GPUs: None detected"
    fi
}

# Export functions for use in other scripts
export -f get_cluster_cpu
export -f get_cluster_ram_gb
export -f get_cluster_ram_kb
export -f get_cluster_gpu_count
export -f has_cluster_gpu
export -f get_cluster_node_count
export -f get_cluster_ready_node_count
export -f print_cluster_resources
