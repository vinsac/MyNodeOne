# Storage Architecture V3 - Implementation Plan

**Created:** January 9, 2026  
**Status:** Planning Phase  
**Goal:** Migrate from systemd MinIO to Kubernetes MinIO with MetalLB LoadBalancers

---

## Summary of Changes

### What We Built (Commits 1ee886b-8d8b7ff)
- ✅ MinIO as systemd service on worker nodes
- ✅ Independent credentials per node
- ✅ Disk detection and formatting
- ✅ Interactive installation
- ❌ No K8s Service integration
- ❌ No MetalLB LoadBalancer
- ❌ No .local domain

### What We Need (V3 Architecture)
- ✅ MinIO as Kubernetes StatefulSet
- ✅ MetalLB LoadBalancer per instance
- ✅ .local domain per instance (`minio-<node>.mynodeone.local`)
- ✅ Cluster-wide service discovery
- ✅ VPS-exposable
- ✅ Independent credentials (K8s Secrets)
- ✅ HostPath volumes (dedicated disks)

---

## Implementation Phases

### Phase 1: Longhorn on Worker Nodes (EASIEST)

**Goal:** Enable Longhorn scheduling on worker nodes for cluster-wide block storage.

**Current State:**
- Longhorn installed on control plane ✅
- Worker node installation calls `install_longhorn()` ✅
- May have logic disabling scheduling on worker ❌

**Changes Needed:**

**File:** `scripts/add-worker-node.sh`
- Remove any `disable_longhorn_on_worker()` calls
- Ensure `install_longhorn()` is called during worker setup
- Verify Longhorn adds worker disks to storage pool

**Verification:**
```bash
# Check Longhorn components on worker
kubectl get pods -n longhorn-system -o wide | grep <worker-name>

# Check Longhorn nodes
kubectl get nodes.longhorn.io -n longhorn-system

# Verify scheduling enabled
kubectl get nodes.longhorn.io <worker-name> -n longhorn-system -o yaml | grep allowScheduling
# Should show: allowScheduling: true
```

**Testing:**
1. Create PVC on worker node
2. Deploy pod with PVC on worker
3. Verify data persistence

**Estimated Time:** 1-2 hours

---

### Phase 2: MinIO Kubernetes Manifests (CORE)

**Goal:** Create reusable Kubernetes manifests for MinIO deployment.

**Directory Structure:**
```
manifests/minio/
├── namespace.yaml          # Per-node namespace template
├── secret.yaml             # Credentials secret template
├── pv-hostpath.yaml        # PersistentVolume using hostPath
├── pvc.yaml                # PersistentVolumeClaim
├── statefulset.yaml        # MinIO deployment
└── service.yaml            # LoadBalancer service
```

**Manifest Details:**

#### namespace.yaml
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio-NODENAME
  labels:
    app: minio
    node: NODENAME
```

#### secret.yaml
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: minio-NODENAME
type: Opaque
stringData:
  rootUser: admin
  rootPassword: GENERATED_PASSWORD
```

#### pv-hostpath.yaml
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-data-NODENAME
  labels:
    app: minio
    node: NODENAME
spec:
  capacity:
    storage: DISK_SIZE
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  hostPath:
    path: /mnt/minio
    type: Directory
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - NODENAME
```

#### pvc.yaml
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-data
  namespace: minio-NODENAME
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: minio-local
  resources:
    requests:
      storage: DISK_SIZE
  volumeName: minio-data-NODENAME
```

#### statefulset.yaml
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
  namespace: minio-NODENAME
spec:
  serviceName: minio
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
        node: NODENAME
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                - NODENAME
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootUser
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-credentials
              key: rootPassword
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-data
```

#### service.yaml
```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-NODENAME
  labels:
    app: minio
    node: NODENAME
spec:
  type: LoadBalancer
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
  selector:
    app: minio
```

**Placeholders to Replace:**
- `NODENAME` - Kubernetes node hostname (e.g., `canada-pc-0001-1`)
- `GENERATED_PASSWORD` - Unique password per node
- `DISK_SIZE` - Size of dedicated disk (e.g., `18Ti`)

**Estimated Time:** 3-4 hours

---

### Phase 3: Installation Script (AUTOMATION)

**Goal:** Create script to deploy MinIO as K8s service with disk detection.

**File:** `scripts/storage/minio/install-k8s-minio.sh`

**Script Flow:**
1. Detect node name (`kubectl get nodes`)
2. Detect available disks (reuse logic from `install-interactive.sh`)
3. Prompt user to select disk for MinIO
4. Format and mount disk to `/mnt/minio`
5. Generate unique credentials
6. Create namespace (`minio-<nodename>`)
7. Create secret with credentials
8. Apply manifests (substitute placeholders)
9. Wait for MinIO pod to be ready
10. Get LoadBalancer IP
11. Register service in service registry
12. Display access information

**Key Functions:**

```bash
detect_node_name() {
    kubectl get nodes -o jsonpath='{.items[*].metadata.name}'
}

detect_available_disks() {
    # Reuse from install-interactive.sh
    # Exclude OS disk, Longhorn disks
}

generate_credentials() {
    MINIO_USER="admin"
    MINIO_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
}

create_namespace() {
    local node_name=$1
    kubectl create namespace "minio-${node_name}" || true
}

deploy_minio() {
    local node_name=$1
    local disk_size=$2
    local password=$3
    
    # Substitute placeholders in manifests
    cat manifests/minio/namespace.yaml | sed "s/NODENAME/${node_name}/g" | kubectl apply -f -
    # ... repeat for all manifests
}

get_loadbalancer_ip() {
    local namespace=$1
    kubectl get svc minio -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

register_service() {
    local node_name=$1
    local lb_ip=$2
    
    # Use service-registry.sh
    bash scripts/lib/service-registry.sh register \
        "minio-${node_name}" \
        "object-storage" \
        "minio-${node_name}" \
        "minio" \
        9000 \
        true
}
```

**Integration with `add-worker-node.sh`:**

```bash
install_minio() {
    log_info "MinIO installation (optional)..."
    
    # Check for existing systemd MinIO
    if systemctl is-active --quiet minio 2>/dev/null; then
        log_warn "Systemd MinIO detected"
        read -p "Migrate to Kubernetes MinIO? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            bash "$SCRIPT_DIR/storage/minio/migrate-systemd-to-k8s.sh"
        fi
        return 0
    fi
    
    # Fresh installation
    read -p "Install MinIO on this node? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        bash "$SCRIPT_DIR/storage/minio/install-k8s-minio.sh"
    fi
}
```

**Estimated Time:** 6-8 hours

---

### Phase 4: Service Discovery & DNS (INTEGRATION)

**Goal:** Enable `.local` domain access and service registry integration.

**Components:**

#### 4.1 Service Registry Entry
- Use existing `scripts/lib/service-registry.sh`
- Register MinIO with domain: `minio-<nodename>.mynodeone.local`
- Store LoadBalancer IP in registry

#### 4.2 CoreDNS Integration
- Service registry auto-updates CoreDNS
- Domain resolves to LoadBalancer IP
- Accessible from anywhere in cluster

#### 4.3 DNS Verification
```bash
# From any pod in cluster
nslookup minio-canada-pc-0001-1.mynodeone.local

# Should return MetalLB IP
```

#### 4.4 External DNS (Laptop)
- Update laptop DNS with new MinIO entries
- Use `scripts/update-laptop-dns.sh`

**Estimated Time:** 2-3 hours

---

### Phase 5: Remove Velero (CLEANUP)

**Goal:** Remove Velero from cluster (user doesn't need it).

**Tasks:**

#### 5.1 Remove Velero from Control Plane Bootstrap
- File: `scripts/bootstrap-control-plane.sh`
- Remove `install_velero()` function call
- Remove Velero-related installation scripts

#### 5.2 Remove Velero Installation Scripts
- Delete: `scripts/storage/install-velero.sh` (if exists)
- Delete: `scripts/storage/configure-velero-backup.sh` (if exists)

#### 5.3 Remove Velero from Worker Node
- File: `scripts/add-worker-node.sh`
- Remove `configure_velero_backup()` function call
- Remove Velero-related configuration

#### 5.4 Documentation Cleanup
- Update architecture docs to remove Velero references
- Remove backup strategy based on Velero

**Estimated Time:** 1-2 hours

---

### Phase 6: Testing & Validation (CRITICAL)

**Test Scenarios:**

#### 6.1 Fresh Worker Node Installation
```bash
# On control plane
cd ~/MyNodeOne

# Add worker node (with MinIO)
sudo ./scripts/add-worker-node.sh
# Select "yes" for MinIO
# Select disk for MinIO (separate from Longhorn)

# Verify MinIO deployment
kubectl get all -n minio-<worker-name>

# Test access
curl http://minio-<worker-name>.mynodeone.local:9000/minio/health/live

# Test S3 operations
mc alias set worker http://minio-<worker-name>.mynodeone.local:9000 admin <password>
mc mb worker/test-bucket
mc ls worker/
```

#### 6.2 Disk Allocation Strategy
```bash
# During installation, verify disk allocation
# Longhorn should use separate disk OR OS folder
# MinIO should use separate disk OR OS folder
# They should NOT overlap

# Example: 2 physical disks available
# User selects: sda for Longhorn, sdb for MinIO

# Example: No physical disks available
# Longhorn uses: /var/lib/longhorn (OS disk)
# MinIO uses: /var/lib/minio (OS disk)
```

#### 6.3 Longhorn on Worker
```bash
# Create PVC on worker
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-worker
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
EOF

# Deploy pod with PVC
kubectl run test-pod --image=nginx --overrides='
{
  "spec": {
    "volumes": [{
      "name": "test-vol",
      "persistentVolumeClaim": {"claimName": "test-pvc-worker"}
    }],
    "containers": [{
      "name": "nginx",
      "image": "nginx",
      "volumeMounts": [{
        "name": "test-vol",
        "mountPath": "/data"
      }]
    }],
    "nodeSelector": {"kubernetes.io/hostname": "<worker-name>"}
  }
}'

# Verify pod runs on worker
kubectl get pod test-pod -o wide

# Cleanup
kubectl delete pod test-pod
kubectl delete pvc test-pvc-worker
```

#### 6.4 Service Discovery
```bash
# From any pod in cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
nslookup minio-<worker-name>.mynodeone.local
wget -O- http://minio-<worker-name>.mynodeone.local:9000/minio/health/live
exit
```

#### 6.5 Control Plane MinIO (Optional)
```bash
# If MinIO installed on control plane
kubectl get all -n minio-<control-plane-name>

# Test access
curl http://minio-<control-plane-name>.mynodeone.local:9000/minio/health/live

# Test S3 operations
mc alias set control http://minio-<control-plane-name>.mynodeone.local:9000 admin <password>
mc mb control/test-bucket
mc ls control/
```

#### 6.6 VPS Exposure (Optional)
```bash
# Setup proxy to MinIO
bash scripts/setup-app-proxy.sh \
  --app-name minio-worker \
  --service-namespace minio-<worker-name> \
  --service-name minio \
  --service-port 9000 \
  --proxy-port 9100

# Test from VPS
curl http://<vps-ip>:9100/minio/health/live
```

**Estimated Time:** 4-5 hours

---

## Summary Timeline

| Phase | Task | Time | Status |
|-------|------|------|--------|
| 1 | Longhorn on Worker | 1-2h | ⏳ Pending |
| 2 | MinIO Manifests | 3-4h | ⏳ Pending |
| 3 | Installation Script | 6-8h | ⏳ Pending |
| 4 | Service Discovery | 2-3h | ⏳ Pending |
| 5 | Remove Velero | 1-2h | ⏳ Pending |
| 6 | Testing | 4-5h | ⏳ Pending |

**Total Estimated Time:** 15-20 hours (reduced from 19-26h)

---

## Rollout Strategy

### Option A: Big Bang (All at Once)
- Implement all phases
- Test comprehensively
- Deploy to cluster
- **Risk:** High (many changes at once)
- **Benefit:** Complete solution

### Option B: Incremental (Phase by Phase)
1. Start with Phase 1 (Longhorn on worker) - Low risk
2. Create and test manifests (Phase 2) - Medium risk
3. Build installation script (Phase 3) - Medium risk
4. Enable service discovery (Phase 4) - Low risk
5. Create migration script (Phase 5) - Low risk
6. Full testing (Phase 6) - Validation

**Recommended:** Option B (Incremental)

---

## Risk Mitigation

### Backup Before Changes
```bash
# Backup Longhorn settings
kubectl get configmap -n longhorn-system -o yaml > longhorn-backup.yaml

# Backup existing MinIO data (if any)
sudo tar -czf /tmp/minio-backup.tar.gz /mnt/minio

# Backup cluster state
velero backup create pre-storage-v3 --wait
```

### Rollback Plan
If migration fails:
1. Restore systemd MinIO: `systemctl start minio`
2. Restore data from backup: `tar -xzf /tmp/minio-backup.tar.gz -C /`
3. Remove K8s resources: `kubectl delete namespace minio-<node>`
4. Revert code changes: `git revert <commit>`

---

## Next Steps

1. ✅ Document requirements (this file)
2. ⏳ Review and approve plan
3. ⏳ Create feature branch: `storage-v3-k8s-minio`
4. ⏳ Implement Phase 1 (Longhorn on worker)
5. ⏳ Implement Phase 2 (MinIO manifests)
6. ⏳ Continue with remaining phases

---

## Decisions Made (January 9, 2026)

1. **MetalLB Pool Size:**
   - ✅ Enough IPs available for multiple MinIO instances
   - No pool expansion needed

2. **Control Plane MinIO:**
   - ✅ Follow same pattern as other apps (Immich, LLM API)
   - Optional installation from control plane
   - Can be installed on control plane node if desired
   - Uses same K8s architecture as worker MinIO

3. **Namespace Strategy:**
   - ✅ Per-node namespace: `minio-<nodename>`
   - Easier for users to manage/remove/reinstall

4. **Migration:**
   - ✅ No migration needed
   - Fresh installation only

5. **Velero:**
   - ✅ Remove Velero from cluster entirely
   - User doesn't need it

6. **Disk Allocation Strategy:**
   - ✅ Both Longhorn and MinIO should:
     - Use separate physical disks (preferred)
     - OR use folders on OS drive if no separate disks available
   - Interactive selection during installation
   - Clear separation between Longhorn and MinIO storage
