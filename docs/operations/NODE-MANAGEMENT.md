# Node Management

This guide covers adding, removing, and managing nodes in your MyNodeOne cluster.

---

## Overview

MyNodeOne supports multiple node types:
- **Control Plane** - Main cluster controller (1 per cluster)
- **Worker Nodes** - Additional compute nodes for workloads
- **VPS Edge Nodes** - Public-facing reverse proxy nodes
- **Management Laptops** - Development/admin machines with DNS sync

---

## Adding Nodes

### Control Plane

The control plane is installed during initial setup:

```bash
sudo ./scripts/installation/install-mynodeone.sh
# Select: 1. Install Control Plane
```

**See:** [`docs/installation/INSTALLATION.md`](../installation/INSTALLATION.md)

### Worker Nodes

Add worker nodes to expand cluster capacity:

```bash
# On control plane
sudo ./scripts/nodes/add-worker-node.sh
```

**Features:**
- Kubernetes worker node registration
- Longhorn storage (optional)
- MinIO object storage (optional)
- Node Agent for config sync

**See:** [`docs/installation/INSTALLATION.md#worker-nodes`](../installation/INSTALLATION.md#worker-nodes)

### VPS Edge Nodes

Add VPS nodes for public internet access:

```bash
# On control plane
sudo ./scripts/installation/install-vps-edge-node.sh
```

**Features:**
- Traefik reverse proxy
- Automatic SSL certificates (Let's Encrypt)
- Domain routing
- Node Agent for config sync

**See:** [`docs/installation/INSTALLATION.md#vps-edge-nodes`](../installation/INSTALLATION.md#vps-edge-nodes)

**VPS Metadata Management:** See [VPS-EDGE-NODE-METADATA.md](VPS-EDGE-NODE-METADATA.md) for comprehensive VPS node metadata management, including automatic collection, updates, and troubleshooting.

### Management Laptops

Setup laptops for cluster management:

```bash
# On laptop
sudo ./scripts/setup/setup-management-laptop.sh
```

**Features:**
- Local DNS sync (`.local` domains)
- Node Agent for config sync
- SSH access to cluster

**See:** [`docs/installation/INSTALLATION.md#management-laptops`](../installation/INSTALLATION.md#management-laptops)

---

## Removing Nodes

### Universal Node Removal Script

Use `remove-node.sh` to remove any node type from the cluster registry:

```bash
# Interactive mode (lists all nodes)
sudo ./scripts/nodes/remove-node.sh

# Remove by name (auto-detects type)
sudo ./scripts/nodes/remove-node.sh dev-laptop

# Remove by type and name
sudo ./scripts/nodes/remove-node.sh --type management_laptops --name dev-laptop

# Remove by IP
sudo ./scripts/nodes/remove-node.sh --ip 100.79.49.125
```

**What it does:**
1. ✅ Removes node from `sync-controller-registry` ConfigMap
2. ✅ Cleans SSH `known_hosts` entries
3. ✅ Removes local configuration files (VPS nodes)
4. ✅ Restarts sync-controller service

**What it does NOT do:**
- ❌ Does NOT uninstall software from the node itself
- ❌ Does NOT remove Kubernetes worker nodes
- ❌ Does NOT delete data or services on the node

### Complete Node Removal Process

#### 1. Remove from Cluster Registry

```bash
# On control plane
sudo ./scripts/nodes/remove-node.sh <node-name>
```

#### 2. Remove Kubernetes Worker Node (if applicable)

If the node is a Kubernetes worker:

```bash
# On control plane
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>
```

#### 3. Uninstall Software from Node (optional)

If you want to completely uninstall MyNodeOne from the node:

```bash
# SSH to the node
ssh <user>@<node-ip>

# Run uninstall script
sudo ./scripts/installation/uninstall-mynodeone.sh
```

### Node Type Specific Removal

#### Management Laptops

```bash
# 1. Remove from registry (on control plane)
sudo ./scripts/nodes/remove-node.sh dev-laptop

# 2. Uninstall from laptop (on laptop)
sudo ./scripts/installation/uninstall-mynodeone.sh
```

**Cleanup:**
- Removes from `sync-controller-registry`
- Cleans SSH known_hosts
- No local config files to remove (laptops don't store node configs)

#### Worker Nodes

```bash
# 1. Remove from registry (on control plane)
sudo ./scripts/nodes/remove-node.sh canada-pc-0001-1

# 2. Remove from Kubernetes (on control plane)
kubectl drain canada-pc-0001-1 --ignore-daemonsets --delete-emptydir-data
kubectl delete node canada-pc-0001-1

# 3. Uninstall from worker (on worker node)
sudo ./scripts/installation/uninstall-mynodeone.sh
```

**Important:**
- Drain node before deletion to migrate workloads
- Backup any data stored on node (Longhorn, MinIO)
- Update DNS if node had services

#### VPS Edge Nodes

```bash
# 1. Remove from registry (on control plane)
sudo ./scripts/nodes/remove-node.sh vps-edge-0001

# 2. Remove from domain registry (on control plane)
# This is done automatically by remove-node.sh

# 3. Uninstall from VPS (on VPS)
sudo ./scripts/installation/uninstall-mynodeone.sh
```

**Cleanup:**
- Removes from `sync-controller-registry`
- Removes from `domain-registry`
- Deletes VPS config files (`~/.mynodeone/vps-nodes/<name>`)
- Cleans SSH known_hosts

---

## Viewing Cluster Nodes

### All Nodes (Sync Registry)

View all nodes registered in the sync-controller registry:

```bash
sudo ./scripts/nodes/nodes-status.sh
```

**Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  MyNodeOne Cluster Nodes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    NAME                 TYPE     IP                 STATUS     LAST SEEN    CONFIG
    ----                 ----     --                 ------     ---------    ------
●  vps-edge-0001        vps      100.99.197.116     online     53s ago      v1768016802
●  dev-laptop         laptop   100.79.49.125      offline    12h ago      v1767904572
●  canada-pc-0001-1     worker   100.90.70.25       online     14s ago      v1768016802

Total: 3 nodes  ● Online: 2  ● Stale: 0  ● Offline: 1
```

**Status:**
- **online** - Heartbeat received within last 2 minutes
- **stale** - Heartbeat received within last 10 minutes
- **offline** - No heartbeat for 10+ minutes

### Kubernetes Nodes Only

View Kubernetes cluster nodes (control plane + workers):

```bash
kubectl get nodes
```

**Output:**
```
NAME               STATUS   ROLES                              AGE     VERSION
canada-pc-0001     Ready    control-plane,etcd,master,worker   11h     v1.28.5+k3s1
canada-pc-0001-1   Ready    worker                             6h30m   v1.28.5+k3s1
```

---

## Node Registry Architecture

### Sync Controller Registry

**Location:** `kube-system/sync-controller-registry` ConfigMap

**Structure:**
```json
{
  "management_laptops": [
    {
      "name": "dev-laptop",
      "ip": "100.79.49.125",
      "ssh_user": "example-user",
      "status": "offline",
      "last_sync": "2026-01-09T12:30:00Z",
      "config_version": "v1767904572"
    }
  ],
  "vps_nodes": [
    {
      "name": "vps-edge-0001",
      "ip": "100.99.197.116",
      "public_ip": "192.0.2.100",
      "ssh_user": "root",
      "status": "online",
      "last_sync": "2026-01-10T06:45:00Z",
      "config_version": "v1768016802"
    }
  ],
  "worker_nodes": [
    {
      "name": "canada-pc-0001-1",
      "ip": "100.90.70.25",
      "ssh_user": "example-user",
      "status": "online",
      "last_sync": "2026-01-10T06:46:00Z",
      "config_version": "v1768016802"
    }
  ],
  "metadata": {
    "version": "2.0",
    "last_updated": "2026-01-10T06:46:00Z",
    "updated_by": "example-user@canada-pc-0001"
  }
}
```

### Node Agent

Each node runs `mynodeone-node-agent` service that:
- Polls control plane every 60 seconds for config updates
- Sends heartbeat to report online status
- Applies config changes locally (DNS, routes, etc.)

**Check status:**
```bash
# On any node
systemctl status mynodeone-node-agent
```

---

## Troubleshooting

### Node Shows as Offline

**Symptoms:**
- Node shows "offline" in `nodes-status.sh`
- Last seen > 10 minutes ago

**Causes:**
1. Node Agent service stopped
2. Network connectivity issues
3. Node powered off

**Solutions:**

```bash
# SSH to the node
ssh <user>@<node-ip>

# Check Node Agent status
systemctl status mynodeone-node-agent

# Restart if stopped
sudo systemctl restart mynodeone-node-agent

# Check logs
journalctl -u mynodeone-node-agent -f
```

### Node Not Receiving Config Updates

**Symptoms:**
- Config version outdated
- DNS entries not syncing
- VPS routes not updating

**Solutions:**

```bash
# On control plane - force sync
sudo ./scripts/lib/sync-controller.sh push-force

# On the node - manually sync
sudo ./scripts/domains/sync-dns.sh  # For laptops/workers
sudo ./scripts/vps/sync-vps-routes.sh  # For VPS nodes
```

### Cannot Remove Node

**Error:** "Node not found in registry"

**Solutions:**

```bash
# List all nodes to verify name
sudo ./scripts/nodes/nodes-status.sh

# Try removing by IP instead
sudo ./scripts/nodes/remove-node.sh --ip <tailscale-ip>

# Manually edit ConfigMap (last resort)
kubectl edit configmap sync-controller-registry -n kube-system
```

### Worker Node Stuck in "NotReady"

**After removing a worker node:**

```bash
# Force delete the node
kubectl delete node <node-name> --force --grace-period=0

# Clean up any remaining resources
kubectl get pods --all-namespaces --field-selector spec.nodeName=<node-name>
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
```

### Worker Validation Fails

**Symptoms:**
- Node successfully joined the cluster (`kubectl get nodes` shows it)
- Validation script reports "Node not registered" or fails node checks
- Node appears Ready in Kubernetes but validation says otherwise

**Cause:**
Validation uses the machine's `hostname` to check node registration, but the worker may have joined with a different `NODE_NAME` from your configuration.

**Solutions:**

1. **Use the exact NODE_NAME from config when labeling:**
   ```bash
   # The worker script prints this exact command - use it verbatim
   kubectl label node <NODE_NAME_FROM_CONFIG> node-role.kubernetes.io/worker=true
   kubectl label node <NODE_NAME_FROM_CONFIG> mynodeone.io/location=<location>
   ```

2. **Check for name mismatch:**
   ```bash
   # See what name Kubernetes knows
   kubectl get nodes
   
   # See what the validation script expects
   hostname
   ```

3. **If names differ, either:**
   - Re-run the label command with the correct Kubernetes node name
   - Or ensure your config's NODE_NAME matches the machine's hostname

**Note:** Validation uses `hostname` for simplicity. The worker script warns if NODE_NAME (config) differs from the detected cluster name, but proceeds with the config name.

---

## Best Practices

### Before Removing a Node

1. **Backup data** - If node has Longhorn or MinIO, backup data first
2. **Drain workloads** - For worker nodes, drain before removal
3. **Update DNS** - Remove any custom DNS entries pointing to the node
4. **Document** - Note why the node is being removed

### Node Naming Conventions

- **Control Plane:** `<location>-pc-<number>` (e.g., `canada-pc-0001`)
- **Worker Nodes:** `<location>-pc-<number>-<worker-id>` (e.g., `canada-pc-0001-1`)
- **VPS Nodes:** `vps-edge-<number>` or `<provider>-vps-<number>`
- **Laptops:** `<purpose>-<type>` (e.g., `dev-laptop`, `work-laptop`)

### Node Maintenance

- **Regular updates:** Keep nodes updated with `apt update && apt upgrade`
- **Monitor status:** Check `nodes-status.sh` regularly
- **Restart services:** Restart Node Agent if config sync fails
- **Clean up offline nodes:** Remove nodes that are permanently offline

---

## Related Documentation

- [Installation Guide](../installation/INSTALLATION.md) - Initial setup
- [Uninstall Guide](../installation/UNINSTALL.md) - Complete uninstallation
- [Admin Guide](../guides/ADMIN-GUIDE.md) - Cluster administration
- [Troubleshooting](troubleshooting.md) - Common issues and solutions

---

## Quick Reference

### Add Nodes
```bash
sudo ./scripts/nodes/add-worker-node.sh           # Worker node
sudo ./scripts/installation/install-vps-edge-node.sh     # VPS edge node
sudo ./scripts/setup/setup-management-laptop.sh   # Management laptop
```

### Remove Nodes
```bash
sudo ./scripts/nodes/remove-node.sh <node-name>   # Any node type
kubectl delete node <node-name>             # Kubernetes worker
```

### View Nodes
```bash
sudo ./scripts/nodes/nodes-status.sh              # All nodes (sync registry)
kubectl get nodes                           # Kubernetes nodes only
```

### Node Agent
```bash
systemctl status mynodeone-node-agent       # Check status
sudo systemctl restart mynodeone-node-agent # Restart service
journalctl -u mynodeone-node-agent -f       # View logs
```
