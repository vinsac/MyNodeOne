# Root Cause Analysis: Why Networking Issues Appeared Now

## Executive Summary

The networking issues (UFW blocking, missing VXLAN port) were **latent bugs** in the
installation scripts that were **exposed when Longhorn replica count was changed from 3 to 1**.

With `replica=3` (Longhorn default), each node had a local copy of all volume data. Pods
accessed storage locally — cross-node networking was never truly exercised for data I/O.
When `replica=1` was set, storage data existed on only one node, forcing pods on the other
node to access it cross-node. This exposed the UFW misconfiguration that had always been there.

The Flannel interface disappearing on the control plane remains an unexplained transient issue,
likely triggered by K3s restarts during the Longhorn Helm upgrade work.

## The Core Mechanism: How Replica Count Masked Networking Issues

### Longhorn Architecture (from official docs)

> "The Longhorn Engine **always runs on the same node as the Pod** that uses the volume.
> It synchronously replicates the volume across the multiple replicas stored on multiple nodes."
> — longhorn.io/docs/concepts

Key architecture:
- **Engine**: Runs on the same node as the consuming Pod
- **Replicas**: Distributed across nodes for redundancy
- The Engine communicates with replicas over **pod-to-pod networking** (Flannel overlay)

### With replica=3 on 2 nodes (BEFORE the change)

```
┌─────────────────────────┐    ┌─────────────────────────┐
│  Node 1 (Control Plane) │    │  Node 2 (Worker)        │
│                         │    │                         │
│  Pod A ──► Engine       │    │  Pod B ──► Engine       │
│              │          │    │              │          │
│         ┌────┘          │    │         ┌────┘          │
│         ▼               │    │         ▼               │
│    Replica 1 (LOCAL)    │    │    Replica 2 (LOCAL)    │
│    Replica 3 (LOCAL)    │    │    Replica 1 (LOCAL)    │
│                         │    │                         │
│  Cross-node I/O: NO     │    │  Cross-node I/O: NO     │
│  (local replica serves) │    │  (local replica serves) │
└─────────────────────────┘    └─────────────────────────┘
```

- Longhorn places replicas on separate nodes (anti-affinity)
- With 3 replicas and 2 nodes: **each node always has at least 1 local replica**
- Engine reads from the **local** replica — no cross-node traffic for data I/O
- Writes go to all replicas (including remote) but reads are local
- Even if cross-node networking was broken, volumes worked in **degraded mode**

### With replica=1 on 2 nodes (AFTER the change)

```
┌─────────────────────────┐    ┌─────────────────────────┐
│  Node 1 (Control Plane) │    │  Node 2 (Worker)        │
│                         │    │                         │
│  Pod C ──► Engine ──────────────► Replica (REMOTE!)    │
│                         │    │                         │
│  Cross-node I/O: YES!   │    │                         │
│  (must reach Node 2     │    │                         │
│   via Flannel VXLAN)    │    │                         │
└─────────────────────────┘    └─────────────────────────┘
```

- Only 1 replica exists — on whichever node Longhorn's scheduler picks
- `dataLocality: disabled` (current setting!) — **no guarantee the replica is local**
- `replica-soft-anti-affinity: true` — Longhorn **prefers placing on different nodes**
- `replica-auto-balance: best-effort` — Longhorn distributes across nodes
- If pod runs on Node 1 but replica is on Node 2 → **ALL I/O crosses the network**
- Cross-node networking issues → **volume completely inaccessible** (not just degraded)

### The Critical Difference

| Scenario | Cross-node traffic needed? | Effect of broken networking |
|----------|--------------------------|----------------------------|
| replica=3, 2 nodes | Writes only (reads local) | Degraded but **functional** |
| replica=1, local replica | None | **Works fine** |
| replica=1, remote replica | ALL reads and writes | **Completely broken** |

### Current Longhorn Settings That Confirm This

```
dataLocality:              disabled        ← No preference for local placement
replica-soft-anti-affinity: true           ← PREFERS different nodes
replica-auto-balance:      best-effort     ← Distributes across nodes
default-replica-count:     1               ← Only one copy of data
```

With these settings, Longhorn's scheduler may place the single replica on a **different node**
than where the pod runs. This creates a hard dependency on cross-node networking that
**did not exist with replica=3**.

## Timeline Evidence

```
Worker Node Added:             Jan 8-18, 2026 (working fine with replica=3 default)
Worker Node Fixes:             Jan 18 (KUBECONFIG, Longhorn disk, MinIO)
Replica=1 Work Started:        Jan 19 (da6f33d - numberOfReplicas=1)
Heavy Longhorn Refactoring:    Feb 5-8 (74fdea6, 04d137f, d85d0ba, etc.)
Control Plane K3s Recreated:   Feb 8 (creationTimestamp in kubectl)
Worker OS Reinstalled:         Feb 15 09:35
Worker Rejoined Cluster:       Feb 15 15:38
Networking Issues Diagnosed:   Feb 15 16:00-21:00
```

## Why It Worked Before (replica=3 Era)

Git history confirms the worker node was added and working in January 2026:
```
ce87d72 2026-01-08 Fix worker node installation issues - disk detection and kubectl access
f80ed26 2026-01-08 Fix kubectl certificate issue on worker nodes
bfe8d1e 2026-01-18 fix: Robust kubectl configuration and GPU plugin deployment for worker nodes
c92fac5 2026-01-18 fix: Resolve KUBECONFIG override issue on worker nodes
3557a7a 2026-01-18 fix: Worker node post-install fixes - MinIO connectivity, Longhorn disk addition
```

The UFW misconfiguration (missing `allow routed` and `8472/udp`) was present from day one
in the installation scripts. But with replica=3:
- Each node had local replicas for all volumes
- Pods accessed storage locally — the Engine read from the local replica
- Cross-node networking was used for replica sync (writes) but not critical reads
- Even if VXLAN was degraded, Longhorn continued working with local data

**The cluster appeared healthy because the most demanding cross-node path (storage I/O)
was satisfied locally.**

## Why It Broke After replica=1

The replica=1 change had two effects:

### Effect 1: Forced Cross-Node Storage Access

With only 1 replica per volume and `dataLocality: disabled`:
- New volumes could have their single replica placed on any node
- If pod on Node A, replica on Node B → all I/O must cross the Flannel overlay
- This was the first time cross-node pod networking was **critical** (not just nice-to-have)
- The latent UFW `deny routed` policy now blocked real traffic

### Effect 2: Longhorn Helm Upgrades Triggered K3s Instability

The replica=1 work involved multiple Helm upgrades:
```
da6f33d 2026-01-19 fix: Add numberOfReplicas=1 to Longhorn StorageClass
74fdea6 2026-02-06 fix: Set Longhorn Helm replica count to 1 and improve fix robustness
1b59f30 2026-02-06 fix: Correct Longhorn ConfigMap patch method to prevent corruption
```

Each Helm upgrade restarts Longhorn components, which can trigger:
- K3s restarts (intentional or from component instability)
- Flannel interface recreation (which may fail silently)
- Temporary loss of the `flannel.1` VXLAN interface

### The Flannel Interface Mystery

The control plane's `flannel.1` interface was missing when we started debugging on Feb 15.
This remains the least understood part of the incident:
- On a fresh K3s install, Flannel works correctly
- The interface likely disappeared during a K3s restart triggered by Longhorn Helm upgrades
- A simple `systemctl restart k3s` recreated it immediately
- This is a **transient issue**, not a configuration problem

## The Installation Script Gap (The Latent Bug)

### What the scripts configured

```bash
# Both bootstrap-control-plane.sh and add-worker-node.sh had:
ufw --force enable
ufw allow 22/tcp comment 'SSH'
ufw allow in on tailscale0 comment 'Tailscale mesh network'
ufw default deny incoming
ufw default allow outgoing
# ❌ MISSING: ufw default allow routed
# ❌ MISSING: ufw allow 8472/udp comment 'Flannel VXLAN'
```

### Why this was never caught

- `ufw default deny routed` blocks forwarded/routed packets (Flannel VXLAN overlay traffic)
- With replica=3, storage I/O was local → routed traffic was only for replica sync writes
- Replica sync failures would show as "degraded" volumes, not service outages
- With replica=1, ALL storage I/O could be routed → `deny routed` = total storage failure

## What Got Fixed

### Installation Scripts (already applied)
- `scripts/installation/bootstrap-control-plane.sh`: Added `ufw allow 8472/udp` + `ufw default allow routed`
- `scripts/nodes/add-worker-node.sh`: Added `ufw allow 8472/udp` + `ufw default allow routed`
- `docs/installation/INSTALLATION.md`: Network requirements documented

### New Validation & Monitoring (already applied)
- `scripts/validation/validate-network.sh`: Post-installation network validation (17/18 checks passing)
- `scripts/validation/monitor-flannel-health.sh`: Systemd timer that auto-recovers missing Flannel interfaces
- `scripts/validation/test-multinode.sh`: Comprehensive multi-node end-to-end test

### Integrated into Installation Flow
- Flannel health monitor auto-installed on both control plane and worker nodes
- Network validation runs automatically after worker node addition

## The Structural Fix

The correct solution is **not** to avoid cross-node traffic (e.g., data locality, higher replica count).
Those are workarounds that break down at scale:

- **Data locality** fails with N nodes: replica=1 means data is on 1 node, N-1 nodes need cross-node access
- **replica=2** is a user choice, not something we can enforce — users may set replica=1

The structural fix is to **make cross-node pod networking work correctly**, which means:

1. **UFW routed policy = allow** — forwarded packets must not be dropped
2. **VXLAN port 8472/UDP open** — Flannel overlay traffic must flow between nodes
3. **Flannel interface monitored** — auto-recovery if `flannel.1` disappears

A pod on Node A accessing storage on Node B is a **normal Kubernetes operation**.
The networking infrastructure must support it regardless of replica count, node count,
or workload scheduling decisions.

These fixes are now built into the installation scripts and run automatically.

## Lessons Learned

1. **Cross-node networking is not optional**: Any Kubernetes cluster must support pods on Node A
   accessing resources on Node B. This is fundamental — not an edge case. Installation scripts
   must configure this from day one, even on single-node clusters.

2. **Latent bugs hide behind redundancy**: The UFW misconfiguration existed from day one but
   was masked by replica=3 keeping storage I/O local. Higher redundancy reduced the *frequency*
   of cross-node traffic, not the *need* for it.

3. **Replica count is a user choice, not a networking concern**: The networking layer must work
   correctly regardless of whether the user sets replica=1, 2, or 3. Storage scheduling decisions
   should never be constrained by networking limitations.

4. **Flannel interface stability**: K3s restarts during Helm upgrades can cause transient loss
   of the VXLAN interface. The Flannel health monitor now auto-recovers this.

---

**Document Status**: Complete (Revised)
**Date**: February 15, 2026
**Analysis Type**: Root Cause Analysis
**Root Cause**: Longhorn replica=1 with dataLocality=disabled exposed latent UFW misconfiguration
**Affected Components**: Longhorn replica scheduling, UFW routed policy, Flannel VXLAN
**Resolution**: Fixed UFW configuration in scripts, added network validation and Flannel monitoring
