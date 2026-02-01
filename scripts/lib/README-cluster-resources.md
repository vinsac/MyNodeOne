# Cluster Resource Detection Utilities

## Overview

The `cluster-resources.sh` library provides centralized functions for detecting total cluster resources across all nodes. This ensures consistent resource detection across all installation and management scripts.

## Why This Was Created

Previously, scripts had inline resource detection code that only checked the first node (`items[0]`), leading to incorrect resource counts in multi-node clusters. This library centralizes the logic and correctly sums resources across **all nodes**.

## Available Functions

### `get_cluster_cpu()`
Returns total CPU cores across all nodes in the cluster.

```bash
TOTAL_CPU=$(get_cluster_cpu)
echo "Total CPU cores: $TOTAL_CPU"
```

### `get_cluster_ram_gb()`
Returns total RAM in GB across all nodes in the cluster.

```bash
TOTAL_RAM_GB=$(get_cluster_ram_gb)
echo "Total RAM: ${TOTAL_RAM_GB}GB"
```

### `get_cluster_ram_kb()`
Returns total RAM in KB across all nodes in the cluster (for precise calculations).

```bash
TOTAL_RAM_KB=$(get_cluster_ram_kb)
```

### `get_cluster_gpu_count()`
Returns total GPU count across all nodes in the cluster.

```bash
GPU_COUNT=$(get_cluster_gpu_count)
echo "Total GPUs: $GPU_COUNT"
```

### `has_cluster_gpu()`
Returns 0 (success) if cluster has any GPUs, 1 (failure) otherwise.

```bash
if has_cluster_gpu; then
    echo "GPUs available"
else
    echo "No GPUs"
fi
```

### `get_cluster_node_count()`
Returns total number of nodes in the cluster.

```bash
NODE_COUNT=$(get_cluster_node_count)
```

### `get_cluster_ready_node_count()`
Returns number of Ready nodes in the cluster.

```bash
READY_NODES=$(get_cluster_ready_node_count)
```

### `print_cluster_resources()`
Prints a formatted summary of cluster resources.

```bash
print_cluster_resources
# Output:
# 📊 Cluster Resources (across 2/2 nodes):
#    • CPU Cores: 64
#    • RAM: 256GB
#    • GPUs: 2 NVIDIA GPU(s)
```

## Usage in Scripts

### Import the Library

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Load cluster resource detection utilities
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
```

### Use the Functions

```bash
# Get resources
TOTAL_CPU=$(get_cluster_cpu)
TOTAL_RAM_GB=$(get_cluster_ram_gb)
GPU_COUNT=$(get_cluster_gpu_count)

# Print summary
print_cluster_resources

# Check GPU availability
if has_cluster_gpu; then
    echo "GPU acceleration available"
fi
```

## Scripts Updated

The following scripts have been updated to use this centralized library:

1. **`scripts/apps/llmapi/install-llmapi.sh`** - LLM API installation
2. **`scripts/apps/llm-chat/install-llm-chat.sh`** - LLM Chat installation  
3. **`scripts/apps/llmapi/scale-backends.sh`** - Backend scaling

## Migration Guide

### Before (Incorrect - Only First Node)

```bash
# ❌ Only checks first node
TOTAL_CPU=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')
TOTAL_RAM_KB=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.memory}' | sed 's/Ki//')
```

### After (Correct - All Nodes)

```bash
# ✅ Sums across all nodes
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"
TOTAL_CPU=$(get_cluster_cpu)
TOTAL_RAM_KB=$(get_cluster_ram_kb)
```

## Benefits

1. **Accurate Multi-Node Detection**: Correctly sums resources across all cluster nodes
2. **Consistency**: All scripts use the same detection logic
3. **Maintainability**: Single source of truth for resource detection
4. **Simplicity**: Clean, reusable functions instead of inline kubectl commands

## Future Improvements

Potential enhancements for this library:

- Per-node resource breakdown
- Available vs. allocated resource tracking
- Resource utilization percentages
- Node-specific GPU detection (which node has which GPU)