# Longhorn Storage Settings

**Last Updated:** January 10, 2026  
**MyNodeOne Version:** Storage V3 (K8s + Longhorn)

---

## Overview

MyNodeOne uses Longhorn for distributed block storage across Kubernetes nodes. This document explains the configured settings and their rationale for home lab environments with Tailscale networking.

---

## Critical Settings

### 1. Replica Count: `1`

**Setting:** `defaultSettings.defaultReplicaCount=1`  
**StorageClass Parameter:** `numberOfReplicas: "1"`

**What it does:**
- Each PVC creates **1 replica** (single copy of data)
- Data stored on a single node, not replicated across nodes
- No synchronous replication over network

**Why this matters:**
- ✅ **Avoids rebuild storms** when nodes go offline temporarily
- ✅ **No data transfer over Tailscale** during normal operations
- ✅ **Predictable performance** (no network sync delays)
- ✅ **3x storage savings** (vs 3 replicas)
- ⚠️ **Lower redundancy** (backup strategy required)

**Architecture rationale:**
```
Home Lab Environment:
├── Tailscale WireGuard network (500 Mbps home internet)
├── Nodes may go offline for hours/days
├── No need for HA (high availability)
└── Backup-based resilience preferred over live replication

With replica=1:
├── PVC on Node 1: 100GB used (1 replica)
├── PVC on Node 2: 50GB used (1 replica)
└── Total: 150GB used

With replica=3 (NOT recommended):
├── PVC on Node 1: 300GB used (3 replicas × 100GB)
├── PVC on Node 2: 150GB used (3 replicas × 50GB)
└── Total: 450GB used + constant network sync
```

**When to change:**
- If you add high-speed local LAN (not Tailscale)
- If you need live cross-node redundancy
- If nodes are always online with stable network

---

### 2. Replica Replenishment Wait Interval: `5 days`

**Setting:** `defaultSettings.replicaReplenishmentWaitInterval=432000`  
**Value:** 432,000 seconds (120 hours = 5 days)

**What it does:**
- When a node goes offline, Longhorn waits **5 days** before creating new replicas
- Prevents rebuilding replicas for temporary outages

**Why this matters:**
```
Scenario: Worker node offline for maintenance

With 10 minutes (default 600 seconds):
├── T+0: Node goes offline
├── T+10min: Longhorn starts rebuilding replicas on other nodes
├── T+2hr: Rebuild complete (200GB transferred over Tailscale)
├── T+4hr: Node comes back online
└── Result: Wasted 200GB network transfer, duplicate replicas

With 5 days (432000 seconds):
├── T+0: Node goes offline
├── T+4hr: Node comes back online
├── T+4hr: Original replica used, no rebuild needed
└── Result: No wasted bandwidth, no rebuild storm
```

**Home lab benefits:**
- ✅ Nodes can be offline for days (power saving, maintenance)
- ✅ No rebuild storms when nodes restart
- ✅ No surprise network bandwidth usage
- ✅ Predictable system behavior

**When to change:**
- If nodes are expected to stay online 24/7
- If you have fast local LAN and want quick recovery
- If 5 days is too long for your use case

---

### 3. Replica Auto-Balance: `best-effort`

**Setting:** `defaultSettings.replicaAutoBalance="best-effort"`

**What it does:**
- Automatically moves replicas between nodes to balance disk usage
- Runs in background, non-disruptive
- Only moves replicas when imbalance exceeds threshold

**Example:**
```
Before auto-balance:
├── Node 1: 80% full (5 replicas)
├── Node 2: 20% full (1 replica)

After auto-balance:
├── Node 1: 50% full (3 replicas moved to Node 2)
├── Node 2: 50% full (3 replicas received from Node 1)
```

**Why we keep this enabled:**
- ✅ Prevents one node from filling up
- ✅ Best-effort = non-aggressive (won't cause network storms)
- ✅ Long-term disk usage optimization
- ⚠️ May cause some background network transfer (minimal)

**When to disable:**
- If you want full manual control of replica placement
- If background network usage is unacceptable
- If you're running on metered connection

---

### 4. Fast Replica Rebuild: `enabled` (default)

**Setting:** `defaultSettings.fastReplicaRebuildEnabled=true` (Longhorn default)

**What it does:**
- Uses **incremental sync** (only changed blocks)
- Faster rebuilds, less data transfer
- More aggressive rebuild triggering

**Why we keep this enabled:**
- ✅ **Less data transfer** (only changed blocks, not full replica)
- ✅ Faster recovery when rebuild is actually needed
- ⚠️ More aggressive (but mitigated by 5-day wait interval)

**Example:**
```
Scenario: 100GB PVC, 10GB changed since last sync

With fast rebuild enabled:
└── Transfers: 10GB (only changed blocks)

With fast rebuild disabled:
└── Transfers: 100GB (full replica copy)
```

**Combined with 5-day wait interval:**
```
Node offline → Wait 5 days → If still offline → Fast incremental rebuild
                                                   (minimal data transfer)
```

---

## How Settings Work Together

```
┌─────────────────────────────────────────────────────────┐
│  MyNodeOne Longhorn Configuration                        │
│                                                          │
│  Goal: Minimize network traffic over Tailscale          │
│        Avoid rebuild storms in home lab                  │
│        Single-replica storage with backup strategy       │
└─────────────────────────────────────────────────────────┘

1. PVC Created
   ↓
   numberOfReplicas: 1
   ↓
   Single replica on one node ✓

2. Node Goes Offline
   ↓
   replicaReplenishmentWaitInterval: 5 days
   ↓
   Longhorn waits 5 days before rebuilding ✓

3. Node Still Offline After 5 Days
   ↓
   fastReplicaRebuildEnabled: true
   ↓
   Incremental rebuild (minimal data transfer) ✓

4. Disk Usage Imbalance
   ↓
   replicaAutoBalance: best-effort
   ↓
   Gradual background rebalancing ✓
```

---

## StorageClass Configuration

The Longhorn StorageClass enforces these settings:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"        # Single replica (critical!)
  staleReplicaTimeout: "30"    # 30 minutes
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"     # No pod-to-data affinity
```

**Key Point:** StorageClass `numberOfReplicas: "1"` **overrides** all other replica settings when creating new PVCs.

---

## Installation Scripts

These settings are configured automatically during installation:

### Control Plane Bootstrap
**File:** `scripts/installation/bootstrap-control-plane.sh`

```bash
helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --version 1.5.3 \
    --set defaultSettings.defaultReplicaCount=1 \
    --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
    --set defaultSettings.replicaAutoBalance="best-effort" \
    --wait
```

### Interactive Longhorn Installation
**File:** `scripts/storage/longhorn/install-interactive.sh`

```bash
helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --version 1.5.3 \
    --set defaultSettings.defaultReplicaCount=1 \
    --set defaultSettings.defaultDataPath="${default_path}" \
    --set defaultSettings.replicaAutoBalance="best-effort" \
    --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
    --set defaultSettings.storageOverProvisioningPercentage=200 \
    --set defaultSettings.storageMinimalAvailablePercentage=10 \
    --wait \
    --timeout 10m
```

---

## Verifying Settings

Check current Longhorn settings:

```bash
# Check default replica count
kubectl get settings.longhorn.io default-replica-count -n longhorn-system -o yaml

# Check replenishment wait interval
kubectl get settings.longhorn.io replica-replenishment-wait-interval -n longhorn-system -o yaml

# Check auto-balance setting
kubectl get settings.longhorn.io replica-auto-balance -n longhorn-system -o yaml

# Check fast rebuild setting
kubectl get settings.longhorn.io fast-replica-rebuild-enabled -n longhorn-system -o yaml

# Check StorageClass
kubectl get storageclass longhorn -o yaml | grep -A 6 parameters
```

Expected output:
```yaml
default-replica-count:
  value: "1"

replica-replenishment-wait-interval:
  value: "432000"

replica-auto-balance:
  value: "best-effort"

fast-replica-rebuild-enabled:
  value: "true"

parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  dataLocality: "disabled"
```

---

## Troubleshooting

### Issue: New PVCs still have 3 replicas

**Cause:** StorageClass has old `numberOfReplicas: "3"` parameter

**Fix:**
```bash
# StorageClass parameters cannot be updated
# Must delete and recreate

# 1. Delete old StorageClass
sudo kubectl delete storageclass longhorn

# 2. Recreate with correct settings
sudo kubectl apply -f - << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"
EOF

# 3. Update ConfigMap to prevent Longhorn from recreating old version
sudo kubectl patch configmap longhorn-storageclass -n longhorn-system --type=merge \
  -p '{"data":{"storageclass.yaml":"kind: StorageClass\napiVersion: storage.k8s.io/v1\nmetadata:\n  name: longhorn\n  annotations:\n    storageclass.kubernetes.io/is-default-class: \"true\"\nprovisioner: driver.longhorn.io\nallowVolumeExpansion: true\nreclaimPolicy: \"Delete\"\nvolumeBindingMode: Immediate\nparameters:\n  numberOfReplicas: \"1\"\n  staleReplicaTimeout: \"30\"\n  fromBackup: \"\"\n  fsType: \"ext4\"\n  dataLocality: \"disabled\"\n"}}'
```

### Issue: Existing PVCs have 3 replicas

**Note:** We do NOT change existing PVCs to avoid data loss risk.

**Options:**
1. **Leave as-is** (safest) - Existing PVCs keep 3 replicas, new ones get 1
2. **Manually reduce** (risky) - Only if you understand the implications

If you want to reduce existing PVCs (advanced users only):
```bash
# List volumes
sudo kubectl get volumes.longhorn.io -n longhorn-system

# Reduce replicas (CAUTION: reduces redundancy)
sudo kubectl patch volumes.longhorn.io <volume-name> -n longhorn-system \
  --type=merge -p '{"spec":{"numberOfReplicas":1}}'
```

---

## Architecture Documents

For more context on storage architecture:

- `docs/architecture/STORAGE-ARCHITECTURE.md` - Overall storage strategy
- `docs/architecture/REGISTRY-ARCHITECTURE.md` - Node registry design

---

## Summary

**MyNodeOne Longhorn is configured for:**
- ✅ Single-replica storage (no cross-node replication)
- ✅ 5-day wait before rebuilding (avoid temporary outage rebuilds)
- ✅ Incremental fast rebuilds (minimal data transfer when needed)
- ✅ Best-effort auto-balance (long-term disk optimization)
- ✅ Home lab friendly (Tailscale-aware, power-saving compatible)

**Not configured for:**
- ❌ High availability (use backups instead)
- ❌ Fast failover (5-day rebuild window)
- ❌ Cross-node live redundancy (replica=1)

**This is intentional** and matches the home lab architecture where:
- Nodes may go offline for days
- Backups provide data safety
- Network bandwidth is limited
- Storage efficiency matters
