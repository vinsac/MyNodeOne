# MinIO - S3-Compatible Object Storage

MinIO provides S3-compatible object storage for the MyNodeOne cluster.

## Architecture

- **Deployment:** Kubernetes StatefulSet (not systemd service)
- **Isolation:** Per-node namespace (`minio-<nodename>`)
- **Storage:** HostPath volumes (dedicated physical disk or OS folder)
- **Network:** LoadBalancer service via MetalLB
- **Discovery:** Accessible via `.local` domain
- **Credentials:** Independent per node

## Features

✅ **Multi-Node Support**
- Install on any node (control plane or worker)
- Install multiple times on different nodes
- Each installation is independent

✅ **Cluster-Wide Access**
- LoadBalancer IP from MetalLB
- `.local` domain: `minio-<nodename>.minicloud.local`
- Accessible from anywhere in cluster
- Can be exposed via VPS

✅ **Independent Credentials**
- Unique username/password per node
- Stored in Kubernetes Secrets
- Also saved to credentials file

✅ **Kubernetes Native**
- StatefulSet with node affinity
- HostPath PersistentVolume
- Service discovery integration

## Installation

### Install on a Node

```bash
sudo ./scripts/apps/minio/install-minio.sh
```

The script will:
1. Prompt for target node selection
2. Detect available disks
3. Format and mount selected disk (or use OS folder)
4. Generate unique credentials
5. Deploy MinIO to Kubernetes
6. Register in service discovery
7. Display access information

### Example: Install on Worker Node

```bash
# On control plane
cd ~/MyNodeOne
sudo ./scripts/apps/minio/install-minio.sh

# Select node: 2 (canada-pc-0001-1)
# Select disk: 2 (Use OS folder)
```

Result:
- Namespace: `minio-canada-pc-0001-1`
- Domain: `minio-canada-pc-0001-1.minicloud.local`
- Credentials: Saved to `~/minio-canada-pc-0001-1-credentials.txt`

### Example: Install on Control Plane

```bash
sudo ./scripts/apps/minio/install-minio.sh

# Select node: 1 (canada-pc-0001)
# Select disk: 2 (Use OS folder)
```

Result:
- Namespace: `minio-canada-pc-0001`
- Domain: `minio-canada-pc-0001.minicloud.local`
- Credentials: Saved to `~/minio-canada-pc-0001-credentials.txt`

## Access

### Via .local Domain

```bash
# API endpoint
curl http://minio-<nodename>.minicloud.local:9000/minio/health/live

# Console (web UI)
open http://minio-<nodename>.minicloud.local:9001
```

### Via LoadBalancer IP

```bash
# Get LoadBalancer IP
kubectl get svc minio -n minio-<nodename>

# Access API
curl http://<loadbalancer-ip>:9000/minio/health/live

# Access Console
open http://<loadbalancer-ip>:9001
```

### Using mc CLI

```bash
# Install mc (MinIO client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Add alias
mc alias set mynode http://minio-<nodename>.minicloud.local:9000 admin <password>

# Create bucket
mc mb mynode/test-bucket

# Upload file
mc cp file.txt mynode/test-bucket/

# List buckets
mc ls mynode/
```

## Management

### View Resources

```bash
# List all MinIO instances
kubectl get namespaces | grep minio

# View specific instance
kubectl get all -n minio-<nodename>

# View logs
kubectl logs -n minio-<nodename> -l app=minio

# View credentials
cat ~/minio-<nodename>-credentials.txt
```

### Update MinIO

```bash
# Update image
kubectl set image statefulset/minio minio=minio/minio:latest -n minio-<nodename>

# Or edit StatefulSet
kubectl edit statefulset minio -n minio-<nodename>
```

### Uninstall

```bash
# Delete entire instance
kubectl delete namespace minio-<nodename>

# This will delete:
# - StatefulSet
# - Service (LoadBalancer)
# - PVC
# - Secret
# - All data in /var/lib/minio (if using OS folder)
```

## Storage

### OS Folder (Default)

- Path: `/var/lib/minio`
- Size: Depends on OS disk
- No formatting required
- Easy to get started

### Physical Disk (Future)

- Dedicated disk (e.g., `/dev/sdb`)
- Full disk capacity
- Better performance
- Requires formatting

## Use Cases

### Backup Storage

Store backups from applications:
```bash
# Example: Backup PostgreSQL to MinIO
pg_dump mydb | mc pipe mynode/backups/postgres-$(date +%Y%m%d).sql
```

### Media Storage

Use as S3 backend for apps:
- Immich: Photo storage
- Paperless: Document storage
- Nextcloud: File storage

### Model Storage

Store LLM models:
```bash
# Upload model
mc cp llama-2-7b.gguf mynode/models/

# Download on worker
mc cp mynode/models/llama-2-7b.gguf /var/lib/llmapi/models/
```

### Cross-Cluster Sync

Sync data between clusters:
```bash
# Mirror bucket to remote
mc mirror mynode/photos remote/photos-backup
```

## Differences from Other Apps

### Like Other Apps (Immich, LLM API)

- ✅ Installed via app script
- ✅ Kubernetes-native deployment
- ✅ Service discovery integration
- ✅ LoadBalancer access

### Unlike Other Apps

- ✅ **Can install multiple times** (once per node)
- ✅ **Per-node namespaces** (not single shared namespace)
- ✅ **Independent credentials** (not cluster-wide shared)
- ✅ **Node-pinned** (via node affinity)

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n minio-<nodename> -l app=minio

# Check logs
kubectl logs -n minio-<nodename> -l app=minio

# Common issues:
# - Directory /var/lib/minio not created
# - Insufficient permissions
# - Node not available
```

### LoadBalancer IP Pending

```bash
# Check service
kubectl get svc minio -n minio-<nodename>

# Check MetalLB
kubectl get ipaddresspool -n metallb-system

# If IP pool exhausted, expand pool or use NodePort
```

### Cannot Access via .local Domain

```bash
# Check service registry
kubectl get configmap -n kube-system domain-registry -o yaml

# Update laptop DNS
sudo ./scripts/update-laptop-dns.sh

# Or use LoadBalancer IP directly
```

### Data Loss After Reinstall

**Warning:** Deleting the namespace deletes all data!

To preserve data:
1. Backup buckets before uninstall
2. Use dedicated physical disk (survives namespace deletion)
3. Keep PV with `Retain` policy

## Architecture Details

### Namespace per Node

Each MinIO instance runs in its own namespace:
```
minio-canada-pc-0001      (control plane)
minio-canada-pc-0001-1    (worker node)
```

Benefits:
- Easy to manage independently
- Easy to delete without affecting others
- Clear resource isolation

### Node Affinity

StatefulSet pinned to specific node:
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - canada-pc-0001-1
```

### HostPath Volume

Data stored on node's filesystem:
```yaml
hostPath:
  path: /var/lib/minio
  type: Directory
```

With node affinity to ensure pod runs where data is.

## Future Enhancements

- [ ] Physical disk detection and formatting
- [ ] Automatic bucket creation
- [ ] S3 policy templates
- [ ] Backup/restore helpers
- [ ] Multi-disk support (distributed mode)
- [ ] TLS/HTTPS support
- [ ] IAM user management
- [ ] Prometheus metrics integration

## More Information

- Official docs: https://min.io/docs/minio/kubernetes/upstream/
- mc client guide: https://min.io/docs/minio/linux/reference/minio-mc.html
- S3 API compatibility: https://min.io/product/s3-compatibility
