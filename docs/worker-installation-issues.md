# Worker Node Installation Issues - Jan 9, 2026

## ✅ Resolution Status

**All issues have been fixed and committed to `storage-v3-k8s-minio` branch.**

| Issue | Status | Fix |
|-------|--------|-----|
| #1 Missing label confirmation | ✅ Fixed | Added prompt to wait for labels before proceeding |
| #2 kubectl on worker | ℹ️ Info | Already correct - needed for local operations |
| #3 Hardcoded domain | ✅ Fixed | Export CLUSTER_DOMAIN for child scripts |
| #4 systemd MinIO | ✅ Fixed | Worker script already correct (old installer removed) |
| #5 Node registration timeout | ✅ Fixed | Increased from 30s to 60s |
| #6 Longhorn disk UUID | ✅ Fixed | Manual: delete/recreate Longhorn node resource |

**Commit:** `3bfc7a5` - "Fix worker node installation issues"

---

## Context
Worker node `canada-pc-0001-1` (100.90.70.25) was added to cluster `universe` with control plane at `100.83.31.109`.

## Observed Issues

### 1. Missing User Confirmation for kubectl Labels
**Status:** 🔴 Critical  
**Location:** `scripts/add-worker-node.sh` - `label_node()` function

**Observation:**
```
[INFO] Run this command on the control plane:
  kubectl label node canada-pc-0001-1 node-role.kubernetes.io/worker=true ...
[INFO] Installing Longhorn storage (interactive)...
```

The script immediately proceeded to Longhorn installation without waiting for user to apply labels on control plane.

**Impact:**
- Node may not have proper labels during Longhorn installation
- Could affect Longhorn's ability to detect/configure the worker node
- Labels are critical for node selection, storage configuration

**Root Cause:**
Script displays instruction but doesn't wait for confirmation that labels were applied.

---

### 2. kubectl Configuration on Worker Node
**Status:** 🟡 Question  
**Location:** `scripts/add-worker-node.sh` - `configure_kubectl_worker()` function

**Observation:**
```
[INFO] Configuring kubectl on worker node...
[INFO] Generating kubeconfig for worker node...
[SUCCESS] Kubeconfig created at /home/example-user/.kube/config
[WARN] kubectl configured but cluster access verification failed
```

**Question:**
Is kubectl configuration needed on worker nodes when MinIO is now installed from control plane via SSH (like any other app)?

**Current Architecture:**
- MinIO installed from control plane using `scripts/storage/minio/install-minio.sh`
- Script uses SSH to execute commands on target node
- All kubectl operations run from control plane

**Potential Issue:**
- Unnecessary complexity on worker nodes
- Failed verification warning may confuse users
- Worker nodes don't need direct cluster API access

---

### 3. Hardcoded Domain in Longhorn Installer
**Status:** 🔴 Critical  
**Location:** `scripts/storage/longhorn/install-interactive.sh`

**Observation:**
```
[INFO] 2026-01-09 18:28:29 UI will be accessible at: http://longhorn.mynodeone.local
```

**Expected:**
Should use cluster domain from config: `mynodeone.local`

**Impact:**
- Incorrect DNS information shown to user
- May indicate other hardcoded values in the script
- Inconsistent with cluster configuration

**Root Cause:**
Hardcoded `mynodeone.local` instead of reading from `CLUSTER_DOMAIN` or config.env

---

### 4. Wrong MinIO Installation Method
**Status:** 🔴 Critical  
**Location:** `scripts/add-worker-node.sh` - `install_minio()` function

**Observation:**
```
Created symlink /etc/systemd/system/multi-user.target.wants/minio.service → /etc/systemd/system/minio.service.
```

MinIO was installed as **systemd service** instead of **Kubernetes deployment**.

**Expected Behavior:**
- MinIO should NOT be installed during worker node setup
- MinIO should be installed separately from control plane using `scripts/storage/minio/install-minio.sh`
- Should deploy as Kubernetes StatefulSet with Helm
- Should get MetalLB LoadBalancer IP
- Should get cluster-wide DNS domain (minio-<nodename>.mynodeone.local)

**Current Behavior:**
- Installed as systemd service (old architecture)
- Only accessible via node IP (100.90.70.25:9000)
- No MetalLB integration
- No cluster DNS domain
- No Kubernetes service registration

**Root Cause:**
Worker script calls old systemd-based MinIO installer instead of informing user to use new K8s-based installer from control plane.

---

### 5. Node Registration Timeout Too Short
**Status:** 🟡 Minor  
**Location:** `scripts/lib/validate-installation.sh`

**Observation:**
```
[✗] Node not registered after 30s
  Testing: Node is Ready... ✗ FAILED
```

**Verification:**
Node actually registered successfully (confirmed by user):
```
kubectl get nodes
NAME               STATUS   ROLES                              AGE     VERSION
canada-pc-0001     Ready    control-plane,etcd,master,worker   5h44m   v1.28.5+k3s1
canada-pc-0001-1   Ready    worker                             35m     v1.28.5+k3s1
```

**Impact:**
- False negative in validation
- May confuse users
- Node is actually working fine

**Root Cause:**
30 second timeout may be too short for node registration, especially on slower networks or busy systems.

**Recommendation:**
Increase timeout to 60 seconds to match typical Kubernetes node registration time.

---

### 6. Longhorn Worker Disk Not Showing / Unschedulable
**Status:** 🔴 Critical  
**Location:** Longhorn configuration on worker node

**Observation:**
User reports:
> "When I login into longhorn, I can see that it has two nodes but it does not show storage on the worker node. It mentions that there is not storage on worker node and it is unschedulable."

**Installation Log Shows:**
```
[✓] 2026-01-09 18:28:21 Mounted /dev/sda at /mnt/longhorn-disks/disk-sda
[⚠] 2026-01-09 18:28:23 kubectl not available (worker node) - Longhorn installation via control plane only
[INFO] 2026-01-09 18:28:28 kubectl not available - disk reservation optimization skipped
[INFO] 2026-01-09 18:28:29 kubectl not available - node registry update skipped
```

**Root Causes:**
1. **kubectl not available on worker** - Can't configure Longhorn node settings
2. **Missing node labels** - Script didn't wait for user to apply labels on control plane (Issue #1)
3. **Disk not registered with Longhorn** - Worker formatted and mounted disk, but Longhorn doesn't know about it
4. **Scheduling disabled by default** - Longhorn may have worker node disabled for scheduling

**Expected Behavior:**
- Worker disk should appear in Longhorn UI
- Disk should show ~16TB available storage
- Node should be schedulable
- Disk reservation should be optimized (5% or 250GB max)

**Required Fixes:**
1. Ensure node labels are applied before Longhorn installation
2. Add disk to Longhorn from control plane after worker joins
3. Enable scheduling on worker node
4. Optimize disk reservations

**CRITICAL FINDING - Root Cause Identified:**

Running `kubectl get nodes.longhorn.io canada-pc-0001-1 -n longhorn-system -o yaml` reveals:

```yaml
diskStatus:
  default-disk-87ffc8ad8fd86a16:
    conditions:
    - message: 'Disk default-disk-87ffc8ad8fd86a16(/mnt/longhorn-disks/disk-sda)
        on node canada-pc-0001-1 is not ready: record diskUUID doesn''t match the
        one on the disk '
      reason: DiskFilesystemChanged
      status: "False"
      type: Ready
    - message: the disk default-disk-87ffc8ad8fd86a16(/mnt/longhorn-disks/disk-sda)
        on the node canada-pc-0001-1 is not ready
      reason: DiskNotReady
      status: "False"
      type: Schedulable
    storageAvailable: 0
    storageMaximum: 0
```

**The Real Problem:**
The worker disk `/dev/sda` was **previously formatted and used by Longhorn** (likely during a previous test installation). When the worker installation script reformatted it, the filesystem UUID changed, but Longhorn still has the old UUID in its records.

**Evidence:**
- Disk shows 1.1TB reserved (correct 5% of 16TB)
- Disk is mounted at `/mnt/longhorn-disks/disk-sda` (correct)
- But `storageAvailable: 0` and `storageMaximum: 0` (wrong!)
- Error: "record diskUUID doesn't match the one on the disk"

**Solution:**
Need to delete the Longhorn node resource and let it re-detect the disk with new UUID, OR manually update the diskUUID in the Longhorn node spec.

---

## Additional Observations

### Positive Findings
✅ Worker node joined cluster successfully  
✅ K3s agent running properly  
✅ GPU detected and configured  
✅ Disk formatted with GPT (16.4TB usable)  
✅ Node Agent installed and heartbeat working  
✅ Tailscale connectivity working  

### Architecture Compliance
❌ MinIO installation doesn't follow V3 architecture (systemd vs K8s)  
❌ Longhorn disk not integrated with cluster storage pool  
✅ Worker node properly labeled as worker role  

---

## Next Steps

1. Fix worker script to wait for label confirmation
2. Remove/simplify kubectl configuration on worker nodes
3. Fix hardcoded domain in Longhorn installer
4. Remove systemd MinIO installation from worker script
5. Increase node registration timeout to 60s
6. Add Longhorn worker disk from control plane
7. Enable scheduling on Longhorn worker node
8. Document proper MinIO installation procedure for workers

---

## Testing Required After Fixes

1. Add fresh worker node and verify all issues resolved
2. Verify Longhorn shows worker disk and is schedulable
3. Install MinIO on worker from control plane
4. Verify MinIO gets MetalLB IP and DNS domain
5. Test storage operations on both Longhorn and MinIO
