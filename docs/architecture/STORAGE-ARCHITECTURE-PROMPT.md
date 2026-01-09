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
---

## NEW IMPLEMENTATION PLAN (January 9, 2026)

### Current State Analysis (from commits 1ee886b-8d8b7ff)

**What We Recently Built (Systemd MinIO):**
- ✅ MinIO as systemd service on worker nodes
- ✅ Independent credentials per node
- ✅ Disk detection and formatting logic
- ✅ Tailscale IP-based access (100.x.x.x:9000)
- ✅ Interactive installation with disk selection
- ❌ No Kubernetes Service integration
- ❌ No MetalLB LoadBalancer
- ❌ No .local domain

**Files Modified in Recent Work:**
- `scripts/storage/minio/install-interactive.sh` - Systemd installation with disk detection
- `scripts/add-worker-node.sh` - Calls systemd MinIO installer
- Removed kubectl dependencies for MinIO

### What Needs to Change

**Architecture Shift:**
```
From: MinIO as systemd service (node-level)
To:   MinIO as Kubernetes StatefulSet (cluster-level with node affinity)
```

**Key Differences:**
1. Deploy MinIO as K8s workload (not systemd service)
2. Create K8s Service with MetalLB LoadBalancer
3. Use hostPath volumes (keep dedicated disk architecture)
4. Store credentials in K8s Secrets (per-node, independent)
5. Enable cluster-wide service discovery
6. Support VPS exposure via standard routing

### Implementation Steps

#### Phase 1: Longhorn on Worker Nodes

**1.1 Modify Worker Node Installation**
- File: `scripts/add-worker-node.sh`
- Keep existing `install_longhorn()` function
- Remove `disable_longhorn_on_worker()` logic
- Allow Longhorn to schedule on worker nodes
- Worker disks added to Longhorn storage pool

**1.2 Ensure Replica=1 Enforcement**
- Longhorn can schedule on any node
- PVCs created with replica=1 (no cross-node replication)
- Pod affinity ensures pod runs where PVC is located

**1.3 Disk Allocation Strategy**
- User selects disks during installation
- Longhorn disks: For block storage (PVCs)
- MinIO disks: Separate, for object storage
- Must not overlap

#### Phase 2: MinIO as Kubernetes Services

**2.1 Create MinIO Kubernetes Manifests**
- New directory: `manifests/minio/`
- Files needed:
  - `namespace.yaml` - Per-node namespace (e.g., `minio-pc1`)
  - `secret.yaml` - Independent credentials per node
  - `statefulset.yaml` - MinIO deployment with node affinity
  - `service.yaml` - LoadBalancer service (MetalLB)
  - `pv-hostpath.yaml` - PersistentVolume using hostPath
  - `pvc.yaml` - PersistentVolumeClaim for the PV

**2.2 StatefulSet Configuration**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
  namespace: minio-<nodename>
spec:
  replicas: 1
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - <nodename>  # Pin to specific node
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
```

**2.3 Service Configuration**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-<nodename>
spec:
  type: LoadBalancer
  loadBalancerIP: <metalb-ip>  # From pool
  ports:
  - name: api
    port: 9000
  - name: console
    port: 9001
```

**2.4 HostPath PV Configuration**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-data-<nodename>
spec:
  capacity:
    storage: 18Ti
  accessModes:
  - ReadWriteOnce
  hostPath:
    path: /mnt/minio  # Dedicated physical disk
    type: Directory
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - <nodename>
```

**2.5 Independent Credentials**
- Each MinIO instance has unique Secret
- Secret name: `minio-credentials` in namespace `minio-<nodename>`
- Generated during installation (per node)
- No shared passwords between nodes

#### Phase 3: Installation Script Updates

**3.1 Create New Script: `scripts/storage/minio/install-k8s-minio.sh`**
- Interactive disk selection (reuse logic from `install-interactive.sh`)
- Disk formatting and mounting
- Generate unique credentials
- Create namespace
- Create secret with credentials
- Deploy PV, PVC, StatefulSet, Service
- Register service in cluster registry
- Wait for MinIO to be ready
- Display access information

**3.2 Modify `scripts/add-worker-node.sh`**
- Replace systemd MinIO installation
- Call new `install-k8s-minio.sh`
- Ensure kubectl is configured before MinIO installation
- Update function: `install_minio()` → uses K8s deployment

**3.3 Control Plane MinIO (Optional)**
- User can optionally install MinIO on control plane
- Same K8s architecture
- Separate namespace: `minio-<control-plane-name>`
- Independent credentials

#### Phase 4: Service Discovery & DNS

**4.1 CoreDNS / Service Registry Integration**
- Each MinIO gets entry in service registry
- Domain format: `minio-<nodename>.minicloud.local`
- Example:
  - Control plane: `minio-pc1.minicloud.local`
  - Worker: `minio-pc2.minicloud.local`

**4.2 MetalLB IP Allocation**
- Each MinIO service gets LoadBalancer IP from pool
- IPs from Tailscale subnet (100.x.x.x range)
- Automatically routable within cluster

**4.3 VPS Exposure**
- MinIO can be exposed via VPS using existing routing
- Use `setup-app-proxy.sh` or similar
- Standard Traefik/routing configuration

#### Phase 5: Migration from Systemd to K8s

**5.1 Detection of Existing Systemd MinIO**
- Check if `systemctl status minio` exists
- If yes, prompt user:
  - Migrate to Kubernetes deployment?
  - Keep systemd (not recommended)?

**5.2 Migration Steps (if user confirms)**
- Backup existing MinIO data
- Stop systemd service
- Deploy Kubernetes MinIO
- Restore data to new deployment
- Remove systemd service
- Update credentials file

**5.3 Fresh Installation**
- If no existing MinIO, proceed with K8s deployment
- No migration needed

### File Structure

```
MyNodeOne/
├── scripts/
│   ├── add-worker-node.sh                     [MODIFY] Use K8s MinIO
│   ├── bootstrap-control-plane.sh             [MODIFY] Optional MinIO
│   └── storage/
│       ├── longhorn/
│       │   └── install-interactive.sh         [KEEP] Already working
│       └── minio/
│           ├── install-interactive.sh         [DEPRECATE] Systemd version
│           ├── install-k8s-minio.sh          [CREATE] New K8s installer
│           └── migrate-systemd-to-k8s.sh     [CREATE] Migration helper
├── manifests/
│   └── minio/
│       ├── namespace.yaml                     [CREATE] Template
│       ├── secret.yaml                        [CREATE] Template
│       ├── pv-hostpath.yaml                   [CREATE] Template
│       ├── pvc.yaml                           [CREATE] Template
│       ├── statefulset.yaml                   [CREATE] Template
│       └── service.yaml                       [CREATE] Template
└── docs/
    └── architecture/
        └── STORAGE-ARCHITECTURE-PROMPT.md     [THIS FILE] Updated
```

### Testing Checklist

**Longhorn on Worker:**
- [ ] Worker node joins cluster
- [ ] Longhorn components run on worker
- [ ] Worker disks added to Longhorn
- [ ] PVC can be created on worker node
- [ ] Pod with PVC runs on worker

**MinIO on Worker:**
- [ ] MinIO StatefulSet deployed
- [ ] Pod runs on correct node (affinity)
- [ ] Service gets MetalLB LoadBalancer IP
- [ ] DNS resolves `minio-<nodename>.minicloud.local`
- [ ] MinIO accessible via LoadBalancer IP
- [ ] MinIO accessible via .local domain
- [ ] Independent credentials work
- [ ] Data stored on hostPath (dedicated disk)

**Service Discovery:**
- [ ] Other pods can access MinIO via service name
- [ ] VPS can route to MinIO (if exposed)
- [ ] Service registry shows MinIO entries

**Migration (if applicable):**
- [ ] Systemd MinIO data backed up
- [ ] Kubernetes MinIO deployed
- [ ] Data restored successfully
- [ ] Systemd service removed
- [ ] Access URLs updated

### Implementation Priority

1. **Longhorn on Worker** (Simple - already mostly working)
2. **MinIO Kubernetes Manifests** (Core architecture)
3. **Installation Script** (Automation)
4. **Service Discovery** (DNS integration)
5. **Migration Script** (For existing installations)
6. **Documentation** (User guides)

### Questions to Resolve

1. **Namespace Naming:**
   - Per-node namespace: `minio-<nodename>` (e.g., `minio-canada-pc-0001-1`)?
   - Or single namespace with node-labeled resources: `minio`?
   - **Recommendation:** Per-node namespace for isolation

2. **MetalLB IP Pool:**
   - Do we have enough IPs in MetalLB pool for multiple MinIO instances?
   - Current pool size?
   - **Action:** Verify pool has capacity

3. **Credential Storage:**
   - Kubernetes Secret per namespace?
   - Also save to file for reference (like systemd version)?
   - **Recommendation:** Both (Secret for apps, file for operators)

4. **Control Plane MinIO:**
   - Install by default or make optional?
   - **Recommendation:** Optional (prompt during bootstrap)

5. **Disk Selection:**
   - Interactive during worker addition?
   - Or automatic (use all available non-Longhorn disks)?
   - **Recommendation:** Interactive for control

---

---

---

## ARCHITECTURE REVISION (January 9, 2026)

### New Requirements - Storage Architecture V3

After implementing systemd-based MinIO (commits 1ee886b-8d8b7ff), we are revising the architecture to better support cluster-wide service discovery and VPS exposure.

**Longhorn Requirements:**
1. Install Longhorn on worker nodes during `add-worker-node.sh`
2. Worker node disks should be added to Longhorn storage pool (shared cluster-wide)
3. Longhorn manages block storage across all nodes (replica=1, but schedulable on any node)
4. PVCs can be placed on control plane OR worker node

**MinIO Requirements:**
1. Individual MinIO instances running on individual nodes
2. MinIO must NOT use Longhorn storage (uses dedicated physical disks)
3. Each MinIO instance has independent credentials (no shared passwords)
4. Each MinIO instance gets:
   - Kubernetes Service with MetalLB LoadBalancer IP
   - Cluster-local domain: `minio-<nodename>.minicloud.local`
   - Accessible cluster-wide via service discovery
   - Exposable to internet via VPS (using standard routing)
5. MinIO on worker nodes can be installed as Kubernetes apps from control plane (like Immich, LLM API)
   - Deployed as StatefulSet with node affinity
   - Uses hostPath volumes (dedicated physical disk)
   - Service with LoadBalancer type (MetalLB)

### Architecture Comparison

**Previous (Systemd-based - Commits 1ee886b-8d8b7ff):**
- ❌ MinIO as systemd service
- ❌ Accessed via Tailscale IP only (100.x.x.x:9000)
- ❌ No .local domain
- ❌ No MetalLB LoadBalancer
- ❌ No cluster-wide service discovery
- ✅ Independent credentials per node
- ✅ Uses dedicated physical disks

**New (Kubernetes Services - Current Goal):**
- ✅ MinIO as Kubernetes StatefulSet
- ✅ Each instance with MetalLB LoadBalancer IP
- ✅ Each instance with .local domain (minio-pc1.minicloud.local)
- ✅ Cluster-wide service discovery
- ✅ VPS-exposable via standard routing
- ✅ Independent credentials per instance (stored in per-node secrets)
- ✅ Uses dedicated physical disks (hostPath volumes)

---

## FINAL CONFIRMED ARCHITECTURE (January 6, 2026) - DEPRECATED

### Critical Design Principles

**NO Rebuild Hell:**
- Avoid network transfers over Tailscale for large data
- No cross-node PVC replication (Longhorn replica=1)
- No MinIO-to-MinIO object replication
- No distributed storage modes that sync over network
- Internet bandwidth: Limited, cannot support large transfers

**Storage Independence:**
- Each node: Standalone storage
- Longhorn: Management cluster-wide, data per-node (replica=1)
- MinIO: Standalone per node, no coordination

**Node Metadata Storage:**
- Node names, tags, location, Tailscale IPs stored in Kubernetes
- ConfigMap or custom resource for node registry
- Accessible by scripts and applications

---

## NEW PROPOSED ARCHITECTURE (January 6, 2026 - Under Review)

### Overview

**User's New Requirements:**
- Longhorn should be available on **ALL nodes** in the cluster (both control plane and worker)
- MinIO should be available on **both nodes** (optional installation on each node)
- MinIO should be **separate from Longhorn** (not using Longhorn storage)
- Interactive installation: Ask user if they want MinIO and let them choose disks/partitions

### Proposed Architecture

```
Control Plane Node:
├── Longhorn (Block Storage)
│   ├── Installed by default during bootstrap
│   ├── Uses dedicated disks OR falls back to OS disk
│   ├── replica=1 (no cross-node replication)
│   └── Scheduling ENABLED on this node
│
├── MinIO (Object Storage) - OPTIONAL
│   ├── User prompted during installation: "Install MinIO? (y/n)"
│   ├── If yes: User selects disk/partition for MinIO
│   ├── Separate from Longhorn (uses different disk or partition)
│   ├── Standalone mode (not distributed)
│   └── Can be used for backups, object storage
│
├── Velero (Backup System)
│   ├── Installed during bootstrap
│   └── Configured to backup to MinIO (if available)
│
└── Applications using Longhorn PVCs
    └── Can run on control plane or worker

Worker Node:
├── Longhorn (Block Storage)
│   ├── Installed by default when worker joins
│   ├── Uses dedicated disks OR falls back to OS disk
│   ├── replica=1 (no cross-node replication)
│   └── Scheduling ENABLED on this node
│
├── MinIO (Object Storage) - OPTIONAL
│   ├── User prompted during worker addition: "Install MinIO? (y/n)"
│   ├── If yes: User selects disk/partition for MinIO
│   ├── Separate from Longhorn (uses different disk or partition)
│   ├── Standalone mode (not distributed)
│   └── Can be used for backups, object storage
│
└── GPU Workloads
    └── vLLM models on hostPath (unchanged)
```

### Key Changes from Current Implementation

| Aspect | Current Implementation | New Proposal |
|--------|----------------------|--------------|
| Longhorn on control plane | ✓ Installed, scheduling enabled | ✓ Installed, scheduling enabled |
| Longhorn on worker | ✗ Scheduling disabled | ✓ Scheduling enabled |
| MinIO on control plane | ✗ Not installed | ? Optional (user prompted) |
| MinIO on worker | ✓ Auto-installed | ? Optional (user prompted) |
| MinIO storage backend | Longhorn PVC (old) / hostPath (current) | hostPath (separate disk) |
| Installation flow | Automatic | Interactive (user chooses) |

### Installation Flow

**Control Plane Bootstrap:**
```bash
1. Install K3s
2. Install MetalLB
3. Install Longhorn (default)
   └── Detect disks, format, add to Longhorn
4. Prompt: "Install MinIO on control plane? (y/n)"
   ├── If yes:
   │   ├── Show available disks/partitions
   │   ├── Let user choose disk for MinIO
   │   ├── Validate disk not used by Longhorn
   │   ├── Install MinIO on selected disk
   │   └──ASchitacture - CONFIRMED

**✅ Scendadona MIO per Node**
   └── If no: Skip MinIO
5.Dnaego
-.Eaclmi,de ru sAgndDp edentcMi.IOinstnc
-MIOue lcal iksn(NOTLnghr)
-N M--MsIOrlico
-No diributdmo
1.Non rtworkk ynchronoza iut

**DNSeNamg:**
-Node-specf npoi.(NtTallad-balalLed)
- Conghorn (defaulio-c1.miniclu.local (pc1D= nede tame)
-eWt dis nodeks,ormio-dc2.minicl uo.localg.(pr2m=:t dinnamn)er? (y/n)"
  App├─ xplcilyrtnpoint
   │   ├── Show available disks/partitions
  echoose dis:
  Sh├r─d admin Validate dis(generated k no,tseused)
- Admed:b`dmi`/ `[hard-assword]`
  Us│r ├c─nnsteata adliMionnIselectduss
  Eac  └── Save credethicredentil
   └─r- reIt d:credentiSlkOmt bread oeachnod ieendely
4. Configure Velero backup (if MinIO available)
5.ExamLle:**
```bash
# Conarol plane node (pc1)
MbnIO endpeilt: httpo//minio-pc1.m n clood.local:9000
Almin:eadme  /tshard-passwor
Usr cees: usrA / passwor123 (only exists on pc1

# Worker`nde(pc2)
endpot: htp://minio-pc2.miilou.locl:9000
Amin:adm /hard-password (SAME 1)
Usr mustcreat:urA /passw123 (maulyn pc2ifeede)
```

**Why This Dign:**
# Avoids#neMworkntrO sfersCoverdTeilstals
-QNsirobunld ll fombjctpliatin
- Si,prdicableehavior
- Eachode ully ndepnen
**User's Question:** 
> "Will the MinIO S3 on different nodes have different passwords or will they have a common login/API?"

**Options:**

**Option A: Separate MinIO Instances (Independent)**
- Each node has its own MinIO with unique credentials
- MinIO on control plane: `admin` / `password1`
- MinIO on worker: `admin` / `password2`
- Each is a standalone S3 service
- Use cases: Different storage purposes per node

**Option B: Common Credentials (Consistent)** ✅ **IMPLEMENTED**
- Generate credentials once during control plane setup
- Store in Kubernetes secret: `minio-credentials` in `minio` namespace
- Worker nodes read credentials from secret using kubectl
- Both MinIO instances accessible with same `admin` / `password`
- Use cases: Easier for users, consistent S3 endpoints
- **Implementation:** Workers configured with kubectl access during join to read shared credentials

**Option C: Distributed MinIO (Federated)**
- Both MinIO instances federated into single namespace
- One set of credentials for both nodes
- Data can be accessed from either node
- More complex setup but unified storage

### Disk Selection Strategy

**Challenge:** User needs to select disks for both Longhorn and MinIO

**Proposed Flow:**
```bash
# During installation, script detects all disks:
Available disks:
1. /dev/sda (OS disk - 500GB) - IN USE
2. /dev/sdb (20TB HDD) - AVAILABLE
3. /dev/sdc (20TB HDD) - AVAILABLE

Longhorn Installation:
  Select disks for Longhorn (comma-separated, or 'all' for all available):
  > 2,3  # User selects both 20TB disks
  
  Longhorn will use: /dev/sdb, /dev/sdc

MinIO Installation:
  Install MinIO? (y/n): y
  
  Available disks (not used by Longhorn):
  - None available (all disks assigned to Longhorn)
  
  Options:
  1. Use partition on existing disk (e.g., /dev/sdb1)
  2. Use OS disk partition (e.g., /var/lib/minio)
  3. Cancel MinIO installation
  
  Choice: 2
  
  MinIO will use: /var/lib/minio (on OS disk)
```

**Alternative:** Allocate disks proportionally
- If 2 disks available:
  - Longhorn gets: /dev/sdb
  - MinIO gets: /dev/sdc
- If 1 disk available:
  - Longhorn gets: /dev/sdb (primary)
  - MinIO gets: /var/lib/minio (fallback to OS disk)

### Longhorn Multi-Node Behavior

**Current Architecture:** Longhorn replica=1, scheduling disabled on worker

**New Architecture:** Longhorn replica=1, scheduling enabled on ALL nodes

**How Longhorn Works with Multiple Nodes:**
- Each node has its own Longhorn disks
- PVCs created with replica=1 are placed on ONE node only
- Kubernetes scheduler decides which node gets the PVC
- Pod must run on same node as PVC (node affinity)

**Example:**
```yaml
# Pod with PVC
apiVersion: v1
kind: Pod
metadata:
  name: postgres
spec:
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: postgres-pvc  # Could be on control plane OR worker
  # Kubernetes ensures pod runs where PVC is
```

**Question:** With Longhorn on both nodes, how do we ensure databases stay on control plane?
- Option 1: Node selector in app manifests (explicit placement)
- Option 2: Longhorn storage classes with node affinity
- Option 3: Let Kubernetes decide (PVC could be on either node)

### Velero Backup Strategy

**If MinIO on control plane only:**
- Velero on control plane → MinIO on control plane
- Local backups (no network transfer)

**If MinIO on worker only:**
- Velero on control plane → MinIO on worker
- Network transfer over Tailscale (current implementation)

**If MinIO on both nodes:**
- Which MinIO should Velero use?
- Option A: Use control plane MinIO (local, faster)
- Option B: Use worker MinIO (offsite from control plane)
- Option C: Both (replicate backups to both MinIO instances)

---

## IMPLEMENTATION STATUS 

**Previous Implementation Completed:** January 6, 2026

### What Was Previously Implemented

**1. Modular Storage Scripts** (`scripts/storage/`)
- `install-velero.sh` - Velero installation during control plane bootstrap
- `install-minio-worker.sh` - MinIO worker installation with disk detection
- `configure-velero-backup.sh` - Velero backup configuration

**2. Bootstrap Control Plane Changes** (`scripts/bootstrap-control-plane.sh`)
- Removed `install_minio()` function
- Added `install_velero()` function
- Updated bootstrap sequence: `install_velero` replaces `install_minio`
- Removed MinIO service registration
- Updated summary display to show Velero status
- Removed MinIO credentials from cleanup and display

**3. Worker Node Changes** (`scripts/add-worker-node.sh`)
- Added `disable_longhorn_on_worker()` - Disables Longhorn scheduling on worker
- Added `install_minio_worker()` - Installs MinIO with local disk detection
- Added `configure_velero_backup()` - Configures Velero backup to MinIO
- Updated main() sequence to call new functions after node joins

### Architecture Achieved

```
Control Plane Node:
├── Longhorn (Block Storage)
│   ├── Single-node operation (replica=1)
│   ├── Uses all available disks on control plane
│   ├── Default storage class for PVCs
│   └── Scheduling disabled on worker node
├── Velero (Backup System)
│   ├── Installed during bootstrap
│   ├── Backup storage configured when worker joins
│   └── Nightly backups: 2:00 AM UTC, 6-month retention
└── Applications using Longhorn PVCs
    └── Transparent to apps (abstracted)

Worker Node:
├── kubectl (Cluster Access)
│   ├── Configured automatically during worker join
│   ├── Kubeconfig copied from /etc/rancher/k3s/k3s.yaml
│   ├── Required for MinIO shared credentials (Option B architecture)
│   └── Required for service registration in cluster
├── MinIO (Object Storage)
│   ├── Uses ALL available disks (same detection as Longhorn)
│   ├── Fallback to /var/lib/minio if no dedicated disks
│   ├── Credentials READ from Kubernetes secrets (shared with control plane)
│   ├── Service registered in cluster for discovery
│   └── Serves as Velero backup target
├── Longhorn (Disabled)
│   └── allowScheduling=false
└── GPU Workloads
    └── vLLM models on hostPath (unchanged)

Backup Flow:
Control Plane (Longhorn PVCs) → Velero → Worker Node (MinIO)
```

### Key Features

**Defensive Programming:**
- Install → Verify → Retry → Check → Fallback → Error reporting
- All scripts include prerequisite checks
- Graceful degradation if components fail
- Clear error messages and recovery instructions

**Abstraction:**
- Apps request Longhorn storage without knowing it's control-plane-only
- Storage architecture is infrastructure-level decision
- No changes required to existing application manifests

**Automation:**
- Velero installed automatically during control plane bootstrap
- MinIO installed automatically when worker joins
- Backup configuration triggered automatically when worker joins
- Nightly backups scheduled automatically

### Testing Checklist

**Control Plane Installation:**
- [ ] Velero CLI installed
- [ ] Velero server running
- [ ] Longhorn installed on control plane
- [ ] Longhorn set as default storage class
- [ ] No MinIO on control plane

**Worker Node Addition:**
- [ ] Worker node joins cluster successfully
- [ ] Longhorn scheduling disabled on worker
- [ ] MinIO installed on worker with local disks
- [ ] MinIO credentials saved
- [ ] Velero backup storage location configured
- [ ] Backup schedules created

**Backup Verification:**
- [ ] `velero backup-location get` shows "Available"
- [ ] `velero schedule get` shows nightly schedules
- [ ] Test backup: `velero backup create test-backup --wait`
- [ ] Test restore: `velero restore create --from-backup test-backup`

**Storage Verification:**
- [ ] PVCs use Longhorn storage class
- [ ] PVCs only scheduled on control plane
- [ ] MinIO accessible from cluster
- [ ] Velero can write to MinIO bucket

### Files Modified

**Created:**
- `scripts/storage/install-velero.sh`
- `scripts/storage/install-minio-worker.sh`
- `scripts/storage/configure-velero-backup.sh`
- `docs/architecture/STORAGE-IMPLEMENTATION.md`

**Modified:**
- `scripts/bootstrap-control-plane.sh`
- `scripts/add-worker-node.sh`
- `docs/architecture/STORAGE-ARCHITECTURE-PROMPT.md` (this file)

### Next Steps

1. **Test on Fresh Installation:**
   - Bootstrap control plane
   - Verify Velero installation
   - Add worker node
   - Verify MinIO installation
   - Verify Velero backup configuration

2. **Validate Backups:**
   - Create test PVC
   - Create backup
   - Delete PVC
   - Restore from backup
   - Verify data integrity

3. **Documentation:**
   - Update main README with new storage architecture
   - Document backup/restore procedures
   - Add troubleshooting guide

4. **Merge to Main:**
   - After successful testing
   - Update CHANGELOG
   - Tag release
