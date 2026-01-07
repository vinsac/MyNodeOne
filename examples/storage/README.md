# Storage Examples for MyNodeOne

This directory contains example Kubernetes manifests demonstrating proper storage usage in MyNodeOne cluster.

## Architecture Overview

**Longhorn (Block Storage):**
- Installed on ALL nodes (control plane + workers)
- Default replica count: 1 (data on single node)
- Default storage class for PVCs
- Cluster-wide UI: `http://longhorn.minicloud.local`

**MinIO (Object Storage):**
- Standalone instance per node (NOT distributed)
- Node-specific DNS endpoints: `minio-NODENAME.minicloud.local:9000`
- Shared admin credentials across all nodes
- Used for backups and S3-compatible storage

## Examples

### 1. StatefulSet with PVCs (`statefulset-with-pvcs.yaml`)

**Use Case:** Database or stateful application with multiple replicas

**Key Features:**
- Each pod gets its own PVC automatically via `volumeClaimTemplates`
- Pod anti-affinity spreads replicas across nodes
- PVCs persist even if pods are deleted
- Scale by adjusting `replicas` count

**Deploy:**
```bash
kubectl apply -f statefulset-with-pvcs.yaml
```

**Verify:**
```bash
# Check pods
kubectl get pods -l app=example-database

# Check PVCs
kubectl get pvc

# Check which node each pod is on
kubectl get pods -l app=example-database -o wide
```

**Important Notes:**
- Each PVC has replica=1 (data on single node)
- If node goes down, pod on that node cannot be rescheduled elsewhere
- PVC will reattach when node comes back online
- For HA, use application-level replication (e.g., PostgreSQL streaming replication)

---

### 2. Deployment with Single PVC (`deployment-with-pvc.yaml`)

**Use Case:** Single-instance application with persistent storage

**Key Features:**
- Single replica deployment (ReadWriteOnce PVC)
- Explicit PVC creation (not automatic)
- Can pin to specific node using nodeAffinity

**Deploy:**
```bash
kubectl apply -f deployment-with-pvc.yaml
```

**Pin to Specific Node (Optional):**

Uncomment and modify the `affinity` section in the deployment:
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - pc1  # Your node name
```

**Verify:**
```bash
kubectl get deployment example-app
kubectl get pvc app-data-pvc
kubectl describe pvc app-data-pvc
```

---

### 3. Application with MinIO Backup (`app-with-minio-backup.yaml`)

**Use Case:** Application data backed up to MinIO S3

**Key Features:**
- Longhorn PVC for application data
- CronJob for automated backups to MinIO
- Uses node-specific MinIO endpoint
- Backup retention policy (7 days)

**Prerequisites:**
```bash
# 1. Ensure MinIO is installed on at least one node
# 2. Get your node name
kubectl get nodes

# 3. Update MINIO_ENDPOINT in the manifest
# Replace 'pc1' with your actual node name
```

**Deploy:**
```bash
kubectl apply -f app-with-minio-backup.yaml
```

**Create MinIO Bucket:**
```bash
# Access MinIO console at: http://minio-NODENAME.minicloud.local:9001
# Login with credentials from: ~/mynodeone-minio-credentials.txt
# Create bucket named: backups
```

**Test Backup Manually:**
```bash
# Trigger backup job manually
kubectl create job --from=cronjob/app-backup manual-backup-1

# Check job status
kubectl get jobs
kubectl logs job/manual-backup-1
```

**Important Notes:**
- MinIO endpoint is node-specific (not load-balanced)
- If MinIO node goes down, backups will fail
- Consider backing up to multiple MinIO instances on different nodes
- MinIO credentials are shared cluster-wide

---

## Best Practices

### PVC Placement Strategy

**Option 1: Let Kubernetes Decide**
- Don't specify node affinity
- Kubernetes schedules pod on any node
- Longhorn creates volume on that node
- Pod always lands on same node (due to PVC affinity)

**Option 2: Pin to Specific Node**
- Use `nodeAffinity` to choose node
- Useful for nodes with faster disks or more storage
- Example: GPU workloads on GPU nodes

**Option 3: Spread Across Nodes (StatefulSet)**
- Use `podAntiAffinity` to spread replicas
- Each replica gets PVC on different node
- Better distribution of storage load

### Storage Sizing

**Check Available Storage per Node:**
```bash
# Longhorn dashboard
http://longhorn.minicloud.local

# Or via kubectl
kubectl get nodes.longhorn.io -n longhorn-system -o wide
```

**Monitor PVC Usage:**
```bash
# Inside pod
df -h

# From outside (requires metrics-server)
kubectl top pod <pod-name>
```

### Backup Strategy

**What to Backup:**
- **PVC Data:** Use MinIO or Velero
- **Kubernetes Manifests:** Use Velero (automated)
- **Application State:** Application-specific tools

**Backup Frequency:**
- **Critical Data:** Multiple times per day
- **Normal Data:** Daily
- **Static Data:** Weekly

**Backup Locations:**
- **Primary:** MinIO on same cluster
- **Secondary:** External S3 or rsync to external system
- **DO NOT** rely solely on in-cluster backups

### Multi-Node Considerations

**Longhorn with replica=1:**
- ✅ Fast (no network replication)
- ✅ Uses local disk fully
- ❌ No HA at storage level
- ➡️ Use application-level HA instead

**MinIO Standalone:**
- ✅ Simple, predictable
- ✅ No network overhead
- ❌ No automatic replication
- ➡️ Backup to multiple nodes manually

## Troubleshooting

### PVC Stuck in Pending

**Check:**
```bash
kubectl describe pvc <pvc-name>
```

**Common Causes:**
- No storage class specified
- Not enough space on any node
- Longhorn not installed

**Fix:**
```bash
# Check Longhorn status
kubectl get pods -n longhorn-system

# Check available storage
kubectl get nodes.longhorn.io -n longhorn-system
```

### Pod Not Scheduling

**Check:**
```bash
kubectl describe pod <pod-name>
```

**Common Causes:**
- PVC bound to node but pod has conflicting affinity
- Node with PVC is cordoned or not ready
- Resource constraints (CPU/memory)

**Fix:**
```bash
# Check node status
kubectl get nodes

# Check PVC location
kubectl get pv

# Remove conflicting affinity rules
```

### Backup Failures

**Check:**
```bash
kubectl logs cronjob/app-backup
```

**Common Causes:**
- MinIO endpoint unreachable
- Incorrect credentials
- Bucket doesn't exist
- Network issues

**Fix:**
```bash
# Test MinIO access
kubectl run -it --rm debug --image=minio/mc --restart=Never -- \
  mc alias set minio http://minio-pc1.minicloud.local:9000 ACCESS_KEY SECRET_KEY

# Verify credentials
cat ~/mynodeone-minio-credentials.txt
```

## Additional Resources

- [Longhorn Documentation](https://longhorn.io/docs/)
- [MinIO Documentation](https://min.io/docs/)
- [Kubernetes Storage Documentation](https://kubernetes.io/docs/concepts/storage/)
- MyNodeOne Architecture: `docs/architecture/STORAGE-ARCHITECTURE-PROMPT.md`
