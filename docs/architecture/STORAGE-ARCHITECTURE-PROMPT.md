Right now in the MyNodeOne infrastructure even though there are many options available for storage, we are using Longhorn as the primary storage solution. 

We now want to make some changed to the stroage strategy. We want to install longhorm on the control plane as default in the installation script of control plane node. We then want to use MinIO as the storage solution for the worker node and we want to install it on the worker node installation script. I am sharing the constraints below:

Please ask me any questions if you need more information. DO not make assumptions.

You are working in a home-lab Kubernetes environment with the following characteristics and constraints.
All architectural suggestions, YAMLs, Helm values, and operational advice MUST respect these constraints.

### Cluster Topology
- Kubernetes cluster with 2 nodes:
  - 1 control-plane node
  - 1 worker node
- Both nodes:
  - AMD Ryzen 9950 CPU
  - 128 GB RAM
  - NVIDIA RTX 3090 GPU
  - 2 × 20 TB HDDs (no RAID)
- Total storage:
  - 40 TB on control plane
  - 40 TB on worker
- Nodes are connected over a **Tailscale (WireGuard) network**
- Home internet:
  - 500 Mbps
  - No redundancy
  - Nodes may go offline for hours or days

---

### Storage Architecture (CRITICAL)
- Longhorn is installed in the cluster
- **Longhorn is used as single-node primary storage**
  - PVC replica count = 1
  - Storage disks are enabled ONLY on the control-plane node
  - No cross-node synchronous replication
  - Avoid all Longhorn rebuild storms
- Worker node disks must NOT be used for Longhorn replicas
- Longhorn is used ONLY for:
  - Databases
  - Stateful app PVCs
  - Small/medium latency-sensitive storage

---

### Backup & Data Safety
- **High Availability is NOT required**
- **Backups ARE required**
- MinIO is deployed on the worker node using local disks
- MinIO is used as:
  - Object storage for large data (photos, media, artifacts)
  - Backup target for Velero
- Velero is used for:
  - Scheduled incremental backups
  - PVC snapshots
  - Disaster recovery restores
- Backups are asynchronous (nightly / weekly)
- Manual restore is acceptable

---

### Application Constraints
- Applications MUST NOT require app-level configuration changes
- Apps must rely on:
  - PVCs
  - Kubernetes primitives
- App developers should be able to fork repos and deploy without modifying storage logic
- Databases are expected to be:
  - PostgreSQL
  - MySQL
  - Redis
- Databases must assume:
  - Single-node writable storage
  - Restore from backup on failure
- Apps may be public-facing MVP SaaS products (up to ~20k users)

---

### Scheduling & Performance
- GPUs are primarily on the worker node
- GPU workloads:
  - LLM inference
  - Media processing
- Databases and I/O-heavy workloads should prefer the control-plane node
- Pods may access PVCs remotely if needed, but locality is preferred
- Use:
  - Node selectors
  - Affinity / anti-affinity
  - PriorityClasses (when appropriate)


---

### What to AVOID (IMPORTANT)
❌ Do NOT suggest:
- Multi-node Longhorn replication
- “Replica = 2 or 3 across nodes”
- Synchronous writes over Tailscale
- Ceph, Rook, GlusterFS, or similar
- Automatic HA database clustering
- Rebuild-on-rejoin patterns
- Assuming reliable LAN or cloud-like networking

---

### What to PREFER
✅ Prefer:
- Single-writer storage models
- Backup-based resilience
- Object storage for large data
- Predictable failure modes
- Simple recovery paths
- Clear operational control

---

### Expectations from you
When generating:
- Helm charts
- Kubernetes manifests
- Architecture advice
- Operational runbooks
- Scaling strategies

You must:
- Optimize for **resilience over HA**
- Optimize for **simplicity over theoretical purity**
- Respect that this is a **home-lab + SaaS MVP environment**
- Avoid designs that cause rebuild storms, split-brain, or silent corruption

If an idea conflicts with these constraints, explicitly call it out and DO NOT recommend it.

---

## IMPLEMENTATION PLAN

### Current State Analysis

**Control Plane (bootstrap-control-plane.sh):**
- ✅ Longhorn already installed with `defaultReplicaCount=1`
- ✅ Longhorn uses `/var/lib/longhorn` or dedicated disk paths
- ❌ MinIO currently installed on control plane using Longhorn storage
- ❌ No explicit node taints/labels to restrict Longhorn to control plane

**Worker Node (add-worker-node.sh):**
- ❌ No MinIO installation
- ❌ No object storage configured
- ✅ Creates model storage directories at `/var/lib/llmapi/models/`
- ❌ No Longhorn disk exclusion logic

### Implementation Steps

#### Phase 1: Control Plane Changes

**1.1 Modify Longhorn Installation (bootstrap-control-plane.sh)**
- Add node selector to ensure Longhorn components run only on control plane
- Configure Longhorn to disable scheduling on worker nodes by default
- Add taint to control plane or labels to explicitly mark storage nodes
- Helm values to add:
  ```yaml
  --set longhornManager.nodeSelector."node-role\.kubernetes\.io/control-plane"=""
  --set longhornDriver.nodeSelector."node-role\.kubernetes\.io/control-plane"=""
  ```

**1.2 Remove MinIO from Control Plane**
- Remove MinIO installation from `install_minio()` function in bootstrap-control-plane.sh
- Or add `--dry-run` flag with warning that MinIO should be on worker
- Document migration path for existing MinIO deployments

**1.3 Add Control Plane Storage Labels**
- Label control plane node: `mynodeone.io/storage-type=longhorn`
- Label control plane node: `mynodeone.io/storage-node=true`
- This helps apps explicitly request Longhorn storage

#### Phase 2: Worker Node Changes

**2.1 Create MinIO Installation Function (add-worker-node.sh)**
- New function: `install_minio_worker()`
- Use local disk paths (not Longhorn PVC)
- Deploy MinIO as DaemonSet or StatefulSet with:
  - `nodeSelector`: worker node
  - `hostPath` volumes pointing to `/mnt/minio-data` or similar
  - Single replica (standalone mode)
  
**2.2 Prepare MinIO Data Directories**
- Create `/mnt/minio-data` on worker node
- Use one of the 20TB HDDs as primary MinIO storage
- Set permissions: `chown -R 1000:1000 /mnt/minio-data`

**2.3 MinIO Helm Configuration**
- Install in new namespace: `minio-worker`
- Use `hostPath` instead of PVC:
  ```yaml
  --set persistence.enabled=false  # Disable PVC
  --set mode=standalone
  --set replicas=1
  ```
- Add explicit volumes for hostPath in custom values file

**2.4 Add Worker Storage Labels**
- Label worker node: `mynodeone.io/storage-type=minio`
- Label worker node: `mynodeone.io/object-storage=true`

#### Phase 3: Longhorn Node Restrictions

**3.1 Disable Longhorn Scheduling on Worker**
- After worker joins, patch Longhorn node CRD:
  ```bash
  kubectl -n longhorn-system patch nodes.longhorn.io $WORKER_NODE \
    --type=merge -p '{"spec":{"allowScheduling":false}}'
  ```
- Ensure no disks are added to worker node in Longhorn

**3.2 Update Longhorn Disk Auto-Detection**
- Modify disk detection logic in bootstrap-control-plane.sh
- Only add disks if node is control plane
- Skip worker nodes entirely

#### Phase 4: Application PVC Strategy

**4.1 Storage Class Annotations**
- Keep `longhorn` as default storage class
- Apps on control plane: use default (Longhorn)
- Apps on worker needing object storage: use MinIO S3 SDK directly

**4.2 Database Node Affinity**
- Update database deployments (Redis, PostgreSQL, etc.) to prefer control plane:
  ```yaml
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: Exists
  ```

**4.3 Large Data Workloads**
- Apps like Immich, Nextcloud, Paperless: continue using Longhorn PVCs
- Use MinIO only for:
  - Velero backups
  - Optional object storage for apps that support S3
  - Media streaming (if app supports S3 backend)

#### Phase 5: Velero Backup Integration

**5.1 Install Velero (if not already installed)**
- Deploy Velero in control plane
- Configure MinIO (on worker) as backup target

**5.2 Velero Configuration**
- Create backup location pointing to MinIO worker endpoint
- Configure schedules:
  - Daily incremental: all PVCs
  - Weekly full: entire cluster state
  
**5.3 Backup Storage Location**
```yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: minio-worker
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: velero-backups
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: http://minio-worker.minio-worker.svc.cluster.local:9000
```

#### Phase 6: Testing & Validation

**6.1 Longhorn Verification**
- Verify Longhorn components run only on control plane:
  ```bash
  kubectl get pods -n longhorn-system -o wide
  ```
- Verify no Longhorn disks on worker:
  ```bash
  kubectl get nodes.longhorn.io -n longhorn-system -o yaml
  ```

**6.2 MinIO Verification**
- Verify MinIO pod runs on worker:
  ```bash
  kubectl get pods -n minio-worker -o wide
  ```
- Verify data is on hostPath (not PVC):
  ```bash
  kubectl exec -n minio-worker <pod> -- df -h /data
  ```

**6.3 Storage Class Test**
- Deploy test PVC on control plane
- Verify it uses Longhorn and stays on control plane
- Deploy test app on worker
- Verify it can access MinIO via S3 endpoint

**6.4 Velero Backup Test**
- Create test PVC with data
- Run Velero backup
- Verify backup in MinIO bucket
- Test restore to verify recovery works

### File Changes Required

**Files to Modify:**
1. `scripts/bootstrap-control-plane.sh`
   - Modify `install_longhorn()` - add node selectors
   - Remove/disable `install_minio()` - move to worker
   - Add storage node labels

2. `scripts/add-worker-node.sh`
   - Add `install_minio_worker()` function
   - Add `setup_minio_storage_directories()`
   - Add Longhorn node restriction logic
   - Add worker storage labels

3. `scripts/longhorn-maintenance/scripts/add-disk-to-longhorn.sh`
   - Add check: skip if node is worker
   - Only allow disks on control plane

**New Files to Create:**
1. `scripts/storage/install-minio-worker.sh`
   - Standalone MinIO installation for worker
   - Can be called from add-worker-node.sh

2. `scripts/storage/setup-velero-minio-backup.sh`
   - Configure Velero with MinIO backend
   - Setup backup schedules

3. `manifests/minio-worker-hostpath.yaml`
   - MinIO StatefulSet with hostPath volumes
   - Node affinity for worker node

**Documentation to Update:**
1. `docs/architecture/STORAGE.md` (create if doesn't exist)
   - Document control plane = Longhorn
   - Document worker = MinIO
   - Document backup strategy

2. `README.md`
   - Update storage architecture section
   - Add Velero backup instructions

### Migration Path (for existing clusters)

**If cluster already has MinIO on control plane:**

1. **Backup existing MinIO data:**
   ```bash
   mc mirror minio/mybucket /backup/minio-data/
   ```

2. **Install new MinIO on worker:**
   ```bash
   ./scripts/storage/install-minio-worker.sh
   ```

3. **Restore data to new MinIO:**
   ```bash
   mc mirror /backup/minio-data/ minio-worker/mybucket/
   ```

4. **Update app configurations:**
   - Change S3 endpoints from old to new MinIO
   - Update Velero BackupStorageLocation

5. **Uninstall old MinIO:**
   ```bash
   helm uninstall minio -n minio
   ```

### Questions to Clarify Before Implementation

1. **MinIO Deployment Model:** ✅ CONFIRMED
   - MinIO auto-installed in add-worker-node.sh
   - NOT installed on control plane
   - Use disk detection/formatting logic similar to Longhorn installation
   - Fallback to OS disk if no empty disks available

2. **MinIO Data Directory:** ✅ CONFIRMED
   - Install MinIO on ALL available disks on worker node
   - Use same disk identification/formatting strategy as Longhorn
   - Do NOT format disk with OS
   - Support multiple 20TB disks or disks of any size

3. **Existing Deployments:** ✅ CONFIRMED
   - NO migration scripts needed
   - Fresh install only
   - Documentation for new installations

4. **Velero Installation:** ✅ CONFIRMED
   - Auto-install in bootstrap-control-plane.sh
   - Use separate installation script (called during control plane bootstrap)
   - Configure Velero to backup Longhorn → MinIO when worker node is added
   - Nightly automated backups

5. **Storage Class Behavior:** ✅ CONFIRMED
   - Keep Longhorn as cluster default
   - Abstract storage location from apps
   - Apps request Longhorn storage without knowing it's control-plane-only
   - Infrastructure-level decision, transparent to users

6. **GPU Workload Storage:** ✅ CONFIRMED
   -Key  vLLMmentation Requirements (User Confir ed)

**Core Principles:**
1. **Abstraction:** Apps should not know Longhorn is control-planm-ooly
2. **Audomels s:**tVelero + MinIa backup only activates when worker is added
3. **Defensive Programming:** Install → Verify → Retry → Check → Fallback → Error reporting
4. **Transparency:** Storage architectuye is infrastructure-level, hid on fnom app manifests hostPath
   - May move to MinIO later, but not in this implementation
**Critical Details:
- MinIO uses ALL available disks on worker (same logic as Longhorn disk detection)
- Velero backups: Longhorn (control plane) → MinIO (worker), nightly schedule
- Remove MinIO from control plane installation entirely
- No migration support needed (fresh installs only)

### Implementation Order

**
### Implementation Order

**R✅commended sequence:** (CONFIRMED)
. ⏳ Reference Longhorn disk detection/formatting code
4 Create Veleroinstallation script
5. ⏳ :
  - Remove MinIO installation
   - Add Velero installation call
   - Add 
6. ✅ Create branch (done: `ref:
a  - Add tor-storage-archit with disk dtclctiof
   - AddaLonghi noscheduliqg dusablsons above
   -fAddbVeleoorbaak-prconfogure.sh  trigger(Longhorn node restrictions)
4. ⏳ Tdsf ke.s MIhstallaeiIO swellar ma
8. ⏳ Test on fresh cluster installation
9 ⏳ Create migration guide for existing clusters
8. ⏳ Add Velero integration (optional)
9. ⏳ Update documentation
10. ⏳ Merge to main after validation
FinalClarificaion Needed
---
stat

1. Velero Backup Schedule:**
   ##WhatNtimexfor  ightly backupS? (e.g.,2:00 AM UTC?)
   - Reentinpolicy? (.g., keep la 7 days?)

2. **Veler ItallationTmig:**
  - Inall Veler durigconrlpneboottrap (ven wihout worker)?
   - Or skp if n worker ode exists?
   **Suggested:**Installdung cntol plane boostrap,cnigurebacku wen worker joins

3. **MinIO Nmepac on Worker:**
   - Ue`miio`or `minio-orkr`nameace?
  - **Suggstd:** `minio` fosimplicty

4. **Corol Plane MnIO Remov:**
   *eRemoveorinIO enstallrocee fromdbooting p-conwrol-plani.sh in thim PR?
   - Or keee fmr backwaed companibiliny a dldepreeate aater?
   - **Ssggee cd:**fRemive entirelym(:** install

5. **Disk Detection Reference:**
   - Use exact same logic as Longhornws sk detecto n iq bootstrup-tontril-plaoe.nh?
   - Locased it ln eQ 1038-1130u(disktdetoct on, fot atting, addilg ao Longhorn)- [ ] Priority of phases (can we skip Velero initially?)
   -]**CMigratation needid:** Shoulo MinIO follos idtnttcagy atte(n?

Onue thpsp 5rpo nes are confirmed,isting clusters wi f begshoimmedianyy
- [ ] Any additional constraints or requirements

Once confirmed, we will proceed with implementation following the plan above.
