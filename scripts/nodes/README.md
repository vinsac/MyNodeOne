# Node Management Scripts

This directory contains scripts for managing cluster nodes - adding, removing, and monitoring nodes in the MyNodeOne cluster.

## Adding Nodes

### `add-worker-node.sh`
Adds a new worker node to the cluster.

**Usage:**
```bash
sudo ./scripts/nodes/add-worker-node.sh
```

**Features:**
- Automatic worker registration
- Labels and taints configuration
- Storage setup (Longhorn, MinIO)
- Network configuration
- SSH key distribution

## Removing Nodes

### `remove-node.sh`
Universal node removal script for any node type.

**Usage:**
```bash
# Interactive mode
sudo ./scripts/nodes/remove-node.sh

# Remove by name
sudo ./scripts/nodes/remove-node.sh <node-name>

# Remove by type and name
sudo ./scripts/nodes/remove-node.sh --type <type> --name <name>
```

### `remove-vps-edge-node.sh`
Specialized removal for VPS edge nodes.

### `unregister-vps.sh`
Unregisters a VPS from the node registry.

## Monitoring

### `nodes-status.sh`
Shows status of all registered nodes.

**Usage:**
```bash
sudo ./scripts/nodes/nodes-status.sh
```

**Output:**
- Node names and types
- IP addresses
- Online/offline status
- Last heartbeat time
- Configuration version

## Management

### `update-vps-metadata.sh`
Updates VPS node metadata in the registry.

**Usage:**
```bash
sudo ./scripts/nodes/update-vps-metadata.sh
```

## Notes

- All node management scripts require `sudo`
- Node Agent must be running for heartbeat monitoring
- Removing nodes doesn't delete data - backup first
- Use `nodes-status.sh` regularly to monitor cluster health
