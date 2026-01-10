# Node Registry Architecture

This document explains the design and structure of the MyNodeOne node registry system.

---

## Overview

MyNodeOne uses a **two-tier node architecture** to manage both Kubernetes cluster nodes and external infrastructure nodes.

**Location:** `kube-system/sync-controller-registry` ConfigMap

---

## Registry Structure

```json
{
  "management_laptops": [],  // External dev/admin machines (SSH sync)
  "vps_nodes": [],           // External VPS for public routing (SSH sync)
  "worker_nodes": [],        // External workers (non-Kubernetes, future use)
  "cluster_nodes": [         // Kubernetes cluster members (control-plane + workers)
    {"name": "...", "role": "control-plane", ...},
    {"name": "...", "role": "worker", ...}
  ],
  "metadata": {
    "version": "2.0",
    "last_updated": "2026-01-10T10:00:00Z",
    "updated_by": "user@hostname"
  }
}
```

---

## Array Definitions

### `management_laptops`

**Purpose:** External development and administration machines

**Characteristics:**
- Not part of Kubernetes cluster
- Receive DNS sync (`.local` domains)
- Receive config sync via SSH
- Used for cluster management and development

**Example:**
```json
{
  "name": "vinay-vivobook",
  "ip": "100.79.49.125",
  "ssh_user": "vinaysachdeva1",
  "status": "offline",
  "last_sync": "2026-01-09T12:30:00Z"
}
```

**Sync Method:** SSH push from control plane (or Node Agent pull)

---

### `vps_nodes`

**Purpose:** External VPS nodes for public internet routing

**Characteristics:**
- Not part of Kubernetes cluster
- Run Traefik reverse proxy
- Handle SSL certificates (Let's Encrypt)
- Route public traffic to cluster services
- Receive route configuration via SSH

**Example:**
```json
{
  "name": "vps-edge-0001",
  "ip": "100.99.197.116",
  "public_ip": "45.8.133.192",
  "ssh_user": "sammy",
  "status": "online",
  "last_sync": "2026-01-10T10:00:00Z"
}
```

**Sync Method:** SSH push from control plane (or Node Agent pull)

---

### `worker_nodes`

**Purpose:** External workers (non-Kubernetes)

**Characteristics:**
- **Currently empty** - Reserved for future use
- NOT for Kubernetes workers (those go in `cluster_nodes`)
- For external compute nodes that are NOT part of Kubernetes
- Examples: Docker Swarm workers, Nomad clients, standalone workers

**Why Empty?**
- All current workers are Kubernetes nodes → stored in `cluster_nodes`
- This array is reserved for future non-Kubernetes workers
- Maintains backward compatibility with scripts that expect this array

**Future Use Case:**
```json
{
  "name": "docker-swarm-worker-01",
  "ip": "100.80.50.100",
  "ssh_user": "ubuntu",
  "type": "docker-swarm",
  "status": "active"
}
```

**Sync Method:** SSH push from control plane (or Node Agent pull)

---

### `cluster_nodes`

**Purpose:** Kubernetes cluster members (control plane + workers)

**Characteristics:**
- Part of Kubernetes cluster
- Managed by Kubernetes API
- Includes control plane and worker nodes
- Contains hardware metadata (CPU, RAM, GPU)
- Contains storage metadata (Longhorn, MinIO)
- Source of truth for cluster topology

**Example (Control Plane):**
```json
{
  "name": "canada-pc-0001",
  "k8s_node_name": "canada-pc-0001",
  "role": "control-plane",
  "location": "home",
  "tailscale_ip": "100.83.31.109",
  "ssh_user": "vinaysachdeva1",
  "hardware": {
    "cpu": "AMD Ryzen 9 9950X 16-Core",
    "ram": "123Gi",
    "gpu": "NVIDIA GeForce RTX 3090",
    "os": "Ubuntu 24.04.3 LTS"
  },
  "longhorn": {
    "enabled": true,
    "disks": [...]
  },
  "status": "active"
}
```

**Example (Worker):**
```json
{
  "name": "canada-pc-0001-1",
  "k8s_node_name": "canada-pc-0001-1",
  "role": "worker",
  "location": "home",
  "tailscale_ip": "100.90.70.25",
  "ssh_user": "vinaysachdeva1",
  "hardware": {...},
  "longhorn": {...},
  "minio": {...},
  "status": "active"
}
```

**Sync Method:** Node Agent pull (HTTP-based) or SSH push fallback

---

## Two-Tier Architecture

### **Tier 1: Kubernetes Cluster** (`cluster_nodes`)

**Managed By:** Kubernetes API

**Nodes:**
- Control plane nodes
- Kubernetes worker nodes

**Sync Method:**
- Primary: Node Agent (HTTP pull from Config API)
- Fallback: SSH push from sync-controller

**Source of Truth:** Kubernetes API + `cluster_nodes` array

---

### **Tier 2: External Infrastructure**

**Managed By:** SSH sync from control plane

**Node Types:**
- `management_laptops` - Dev/admin machines
- `vps_nodes` - Public routing nodes
- `worker_nodes` - External workers (future)

**Sync Method:**
- Primary: Node Agent (HTTP pull from Config API)
- Fallback: SSH push from sync-controller

**Source of Truth:** `sync-controller-registry` ConfigMap

---

## Why This Design?

### **Separation of Concerns**

1. **Kubernetes nodes** (`cluster_nodes`)
   - Managed by Kubernetes
   - Part of the cluster
   - Have k8s-specific metadata (roles, taints, labels)

2. **External nodes** (`management_laptops`, `vps_nodes`, `worker_nodes`)
   - NOT managed by Kubernetes
   - NOT part of the cluster
   - Have infrastructure-specific metadata (SSH, sync status)

### **Flexibility**

- Can add non-Kubernetes workers in the future
- Can mix Kubernetes and non-Kubernetes infrastructure
- Clear separation makes it easy to understand node types

### **Backward Compatibility**

- Scripts that read `worker_nodes` handle empty arrays gracefully
- Validation scripts check for array existence (not content)
- No breaking changes when array is empty

---

## Common Questions

### **Q: Why is `worker_nodes` empty?**

**A:** All current workers are Kubernetes nodes, so they're stored in `cluster_nodes`. The `worker_nodes` array is reserved for external workers that are NOT part of the Kubernetes cluster.

### **Q: Why is control plane in both `management_laptops` and `cluster_nodes`?**

**A:** The control plane serves dual purposes:
1. **Kubernetes control plane** → `cluster_nodes` (role: control-plane)
2. **Management machine** → `management_laptops` (for SSH sync to other nodes)

This is intentional and correct.

### **Q: Should I populate `worker_nodes` from `cluster_nodes`?**

**A:** No. This would create data duplication and sync complexity. Kubernetes workers belong in `cluster_nodes` only.

### **Q: Can I remove the `worker_nodes` array?**

**A:** Not recommended. This would break backward compatibility with scripts that expect the array to exist. Keep it empty for future use.

---

## Script Compatibility

### **Scripts That Read Registry**

1. **`sync-controller.sh`**
   - Reads: `management_laptops`, `vps_nodes`, `worker_nodes`
   - Handles empty arrays gracefully
   - ✅ Compatible

2. **`remove-node.sh`**
   - Reads: `management_laptops`, `vps_nodes`, `cluster_nodes`
   - Excludes control-plane from removal
   - ✅ Compatible

3. **`nodes-status.sh`**
   - Reads: Config API (aggregates all arrays)
   - Shows all nodes regardless of array
   - ✅ Compatible

4. **`audit-registry-consistency.sh`**
   - Validates: Array structure (not content)
   - Checks array exists (not populated)
   - ✅ Compatible

5. **`sync-models-to-workers.sh`**
   - Uses: Kubernetes API directly
   - Independent of registry
   - ✅ Compatible

---

## Registry Management

### **View Registry**

```bash
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | jq '.'
```

### **Add Node**

```bash
# Management laptop
sudo ./scripts/setup-management-laptop.sh

# VPS node
sudo ./scripts/install-vps-edge-node.sh

# Worker node (Kubernetes)
sudo ./scripts/add-worker-node.sh
```

### **Remove Node**

```bash
# Any node type
sudo ./scripts/remove-node.sh <node-name>

# Kubernetes worker (also remove from k8s)
kubectl delete node <node-name>
```

### **View Nodes**

```bash
# All nodes (from Config API)
sudo ./scripts/nodes-status.sh

# Kubernetes nodes only
kubectl get nodes
```

---

## Related Documentation

- [Node Management Guide](../operations/NODE-MANAGEMENT.md) - Adding, removing, managing nodes
- [Sync Controller V2](SYNC-CONTROLLER-V2.md) - Config sync architecture
- [Installation Guide](../installation/INSTALLATION.md) - Initial setup

---

## Summary

**Key Takeaways:**

1. ✅ **Two-tier architecture** - Kubernetes cluster + external infrastructure
2. ✅ **`cluster_nodes`** - Kubernetes control plane + workers
3. ✅ **`worker_nodes`** - Reserved for external (non-k8s) workers
4. ✅ **Empty arrays are OK** - Scripts handle them gracefully
5. ✅ **Dual registration is OK** - Control plane in multiple arrays
6. ✅ **Don't duplicate data** - Each node type has one primary location

**The current structure is correct by design. Don't change it.** 🎯
