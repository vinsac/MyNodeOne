# Longhorn Storage Settings

**Last Updated:** February 8, 2026  
**MyNodeOne Version:** Storage V3 (K8s + Longhorn)

---

## Overview

MyNodeOne uses Longhorn for distributed block storage across Kubernetes nodes. This document explains the configured settings and their rationale for home lab environments with Tailscale networking.

---

## Critical Settings

### 1. Replica Count: User-Selectable (default: `1`)

**Setting:** `defaultSettings.defaultReplicaCount=$LONGHORN_REPLICA_COUNT`  
**StorageClass Parameter:** `persistence.defaultClassParameter.numberOfReplicas=$LONGHORN_REPLICA_COUNT`

During installation, the user is prompted to choose a replica count:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Longhorn Replica Count
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

How many copies of each volume should Longhorn maintain?

  1) 1 replica (recommended for home lab)
  2) 2 replicas (survives 1 node failure, requires 2+ nodes)
  3) 3 replicas (survives 2 node failures, requires 3+ nodes)

Select replica count [1/2/3] (default: 1):
```

**Override via environment variable** (skips prompt default):
```bash
LONGHORN_REPLICA_COUNT=2 sudo bash scripts/storage/longhorn/install-interactive.sh
```

**What it does:**
- Each PVC creates the selected number of replicas
- Replica count 1: data on single node, no cross-node replication
- Replica count 2-3: data replicated across nodes for redundancy

**Important:** Both settings are required:
- `defaultSettings.defaultReplicaCount` - Sets default for volumes created after installation
- `persistence.defaultClassParameter.numberOfReplicas` - Sets the StorageClass parameter (overrides default)

Without the StorageClass parameter, new PVCs will use the chart's default (3 replicas) even if defaultSettings is changed.

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

### Interactive Longhorn Installation (Primary)
**File:** `scripts/storage/longhorn/install-interactive.sh`

```bash
helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --version "$LONGHORN_VERSION" \
    --set defaultSettings.defaultReplicaCount=$LONGHORN_REPLICA_COUNT \
    --set persistence.defaultClass=true \
    --set persistence.defaultClassParameter.numberOfReplicas=$LONGHORN_REPLICA_COUNT \
    --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
    --set defaultSettings.autoSalvage=true \
    --set defaultSettings.disableSchedulingOnCordonedNode=true \
    --set defaultSettings.nodeDrainPolicy='block-if-contains-last-replica' \
    --set defaultSettings.replicaSoftAntiAffinity=false \
    --set defaultSettings.replicaZoneSoftAntiAffinity=true \
    --set defaultSettings.defaultDataPath="$default_path" \
    --set defaultSettings.fastReplicaRebuildEnabled=true \
    --set defaultSettings.replicaAutoBalance="best-effort" \
    --set defaultSettings.storageOverProvisioningPercentage=200 \
    --set defaultSettings.storageMinimalAvailablePercentage=10 \
    --set persistence.defaultClassReplicaCount=$LONGHORN_REPLICA_COUNT \
    --wait \
    --timeout 10m
```

**Single-replica safety settings** (critical for 1-replica setups):
- `nodeDrainPolicy=block-if-contains-last-replica` — prevents `kubectl drain` from evicting the only replica (data loss)
- `disableSchedulingOnCordonedNode=true` — prevents scheduling on nodes being drained
- `replicaSoftAntiAffinity=false` — prevents placing multiple replicas on same node

### Bootstrap Fallback
**File:** `scripts/installation/bootstrap-control-plane.sh`

The bootstrap script calls `install-interactive.sh`. If the script is missing, a minimal fallback runs with the same core settings.

---

## Verifying Settings

Check current Longhorn settings:

```bash
# Check default replica count (global setting)
kubectl get settings.longhorn.io default-replica-count -n longhorn-system -o yaml

# Check replenishment wait interval
kubectl get settings.longhorn.io replica-replenishment-wait-interval -n longhorn-system -o yaml

# Check auto-balance setting
kubectl get settings.longhorn.io replica-auto-balance -n longhorn-system -o yaml

# Check fast rebuild setting
kubectl get settings.longhorn.io fast-replica-rebuild-enabled -n longhorn-system -o yaml

# Check StorageClass (this is what actually applies to new PVCs)
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

**Root Cause:** Longhorn manages StorageClass via a ConfigMap (`longhorn-storageclass`), not directly via Kubernetes. StorageClass parameters are immutable once created. Simply patching or re-applying won't work — Longhorn recreates it from the ConfigMap.

**Correct Fix (ConfigMap-based):**
```bash
# 1. Check current status
kubectl get storageclass longhorn -o yaml | grep numberOfReplicas

# 2. Fix the ConfigMap that Longhorn uses to manage StorageClass
kubectl get configmap longhorn-storageclass -n longhorn-system -o jsonpath='{.data.storageclass.yaml}'
# Update numberOfReplicas to "1" in the output, then patch:
kubectl patch configmap longhorn-storageclass -n longhorn-system --type merge \
  -p '{"data":{"storageclass.yaml":"...updated yaml with numberOfReplicas: \"1\"..."}}'

# 3. Delete StorageClass — Longhorn recreates it from the updated ConfigMap
kubectl delete storageclass longhorn
# Wait ~10 seconds, then verify:
kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}'
```

**Why not `kubectl apply`?** The script originally tried to `kubectl apply` a new StorageClass, but Longhorn immediately recreated it from its ConfigMap with the old parameters. The ConfigMap-based approach is the correct fix.

**Prevention:** The installation script now includes:
1. Pre-installation ConfigMap validation (fixes before Helm runs)
2. Post-installation verification with 3 retry attempts
3. Graceful degradation if fix fails (installation continues)

### Issue: Existing PVCs have 3 replicas

**Note:** We do NOT change existing PVCs to avoid data loss risk.

**Options:**
1. **Leave as-is** (safest) - Existing PVCs keep 3 replicas, new ones get 1
2. **Manually reduce** (risky) - Only if you understand the implications

If you want to reduce existing PVCs (advanced users only):
```bash
# List volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Reduce replicas (CAUTION: reduces redundancy)
kubectl patch volumes.longhorn.io <volume-name> -n longhorn-system \
  --type=merge -p '{"spec":{"numberOfReplicas":1}}'
```

### Issue: Bootstrap stops at Longhorn installation

The bootstrap script now handles Longhorn failures gracefully:
```bash
local exit_code=0
bash "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh" || exit_code=$?
if [ $exit_code -eq 0 ]; then
    log_success "Longhorn installed successfully"
else
    log_error "Longhorn installation failed with exit code $exit_code"
    # Don't exit - continue with other components
fi
```
Monitoring, ArgoCD, dashboard, and demo apps will still be installed even if Longhorn has issues.

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
- ✅ Drain-safe (blocks eviction of last replica)

**Not configured for:**
- ❌ High availability (use backups instead)
- ❌ Fast failover (5-day rebuild window)
- ❌ Cross-node live redundancy (replica=1)

**This is intentional** and matches the home lab architecture where:
- Nodes may go offline for days
- Backups provide data safety
- Network bandwidth is limited
- Storage efficiency matters

---

## Appendix: Regression History

This section documents regressions found and fixed during code audits, preserved for future reference.

### Feb 5-8 Audit (21 commits: 1b59f30 through e2537ae)

| # | Regression | Fix |
|---|-----------|-----|
| 1 | **Wrong node detection** — `items[0]` returns first node alphabetically | Hostname matching with label fallback |
| 2 | **Control plane detection** — checked label value `"true"`, but kubeadm sets empty string | Check label existence via `--show-labels` + grep |
| 3 | **Hardcoded domain** — `minicloud.local` instead of dynamic cluster domain | `CLUSTER_DOMAIN` env → ConfigMap → `mynodeone` fallback |
| 4 | **Disk structure mismatch** — `spec.disks` treated as array, Longhorn uses map | Use object structure `{"disk_name": {...}}` |
| 5 | **Invalid stat command** — `-f` and `-c` flags mutually exclusive | Use `df --output=size` |
| 6 | **Pipeline subshell** — kubectl errors silently ignored | Process substitution `< <(...)` |
| 7 | **Wrong jq query** — `disks[]?` assumes array | `to_entries[]` for object iteration |

### Post-62b3a5d Audit (30 commits)

| # | Regression | Fix |
|---|-----------|-----|
| 1 | **NVMe disks skipped** — `[0-9]$` regex matches NVMe disk names | `lsblk TYPE=disk` filter |
| 2 | **Helm drain policy removed** — `kubectl drain` could evict only replica | Restored `nodeDrainPolicy`, `disableSchedulingOnCordonedNode`, `replicaSoftAntiAffinity` |
| 3 | **fstab missing `nofail`** — boot hangs if disk removed | Restored `nofail` mount option |
| 4 | **UUID mismatch detection** — wrong jsonpath (node-level vs per-disk) | Restored `diskStatus[].conditions[].reason == "DiskFilesystemChanged"` |
| 5 | **Missing `wipefs`** — stale filesystem signatures | Restored `umount` + `wipefs -a` before partitioning |
| 6 | **No sudo validation** — half-formatted disks on failure | Upfront `sudo -v` check |
| 7 | **Dead `ACTUAL_HOME`** — fails under `set -euo pipefail` | Removed unused variable |
| 8 | **Hardcoded node role** — `--role "control-plane"` always | Dynamic via `is_control_plane` |
| 9 | **Hardcoded version** — `1.5.3` in 3 places | `LONGHORN_VERSION` variable with env override |
| 10 | **Bootstrap exit_code** — `$?` consumed by `if` statement | `|| exit_code=$?` pattern |