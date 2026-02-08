# MinIO - S3-Compatible Object Storage

MinIO provides S3-compatible object storage for the MyNodeOne cluster.

## Architecture

- **Deployment:** Kubernetes StatefulSet (not systemd service)
- **Isolation:** Per-node namespace (`minio-<nodename>`)
- **Storage:** HostPath volumes (dedicated physical disk or OS folder)
- **Network:** Dual LoadBalancer services (API + Console) via MetalLB
- **Discovery:** Accessible via `.local` domain
- **Credentials:** Independent per node with full admin privileges

## Features

✅ **Multi-Node Support**
- Install on any node (control plane or worker)
- Install multiple times on different nodes
- Each installation is independent

✅ **Cluster-Wide Access**
- LoadBalancer IP from MetalLB
- `.local` domain: `minio-<nodename>.mynodeone.local`
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

## ⚠️ Important: Version Constraint

> [!CAUTION]
> **Do NOT upgrade MinIO past `RELEASE.2025-04-22T22-12-26Z`**

In early 2025, MinIO removed the full admin console from the Community Edition. Versions after April 2025 only show an object browser—no user management, IAM policies, or settings.

**Current pinned version:** `minio/minio:RELEASE.2025-04-22T22-12-26Z`

This is the **last version** that includes:
- Identity management (Users, Groups, Policies)
- Monitoring and audit logs
- Configuration settings UI
- Full administrative console

For admin tasks on newer versions, you would need to use the `mc` CLI or MinIO's paid product (AIStor).

## Dual LoadBalancer Architecture

MinIO uses **two separate LoadBalancer services** for enhanced security and flexibility:

### API Service
- **Domain:** `minio-<nodename>.<domain>.local:9000`
- **Purpose:** S3 API endpoints for programmatic access
- **Use Cases:** 
  - Application storage (Immich, Paperless, etc.)
  - CLI tools (mc, aws-cli, s3cmd)
  - Backup scripts
  - Cross-cluster replication
- **Public Exposure:** ✅ Safe to expose publicly for S3 API access

### Console Service
- **Domain:** `minio-console-<nodename>.<domain>.local:9001`
- **Purpose:** Web-based admin UI with full privileges
- **Features:**
  - User/group management
  - IAM policy configuration
  - Bucket management
  - Monitoring and metrics
  - System settings
- **Public Exposure:** ⚠️ Keep private (Tailscale-only access recommended)

### Security Benefits

**Separate IPs and Services:**
- ✅ Expose API publicly without exposing admin console
- ✅ Reduced attack surface (admin UI not on internet)
- ✅ Independent firewall rules per service
- ✅ Separate monitoring and rate limiting
- ✅ Granular access control

**Example: Selective Public Exposure**
```bash
# Expose only API service via VPS (public S3 access)
sudo ./scripts/networking/manage-app-visibility.sh expose \
  minio-canada-pc-0001 \
  minio-canada-pc-0001 \
  minio-canada-pc-0001.mynodeone.local

# Console remains private (Tailscale-only)
# Access: http://minio-console-canada-pc-0001.mynodeone.local:9001
```

Result:
- **Public:** `https://minio-canada-pc-0001.yourdomain.com` (S3 API via VPS)
- **Private:** `http://minio-console-canada-pc-0001.mynodeone.local:9001` (Admin UI via Tailscale)

### Admin Privileges

**All MinIO installations have full admin privileges** regardless of node type:
- ✅ Control plane installations: Full admin access
- ✅ Worker node installations: Full admin access
- ✅ Complete IAM policy management
- ✅ User/group management capabilities
- ✅ All console features enabled

The dual LoadBalancer setup provides security through **network isolation**, not privilege restriction. Each MinIO instance is fully functional with complete administrative capabilities.

## Installation

### Install on a Node

```bash
sudo ./scripts/storage/minio/install-minio.sh
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
sudo ./scripts/storage/minio/install-minio.sh

# Select node: 2 (canada-pc-0001-1)
# Select disk: 2 (Use OS folder)
```

Result:
- Namespace: `minio-canada-pc-0001-1`
- Domain: `minio-canada-pc-0001-1.mynodeone.local`
- Credentials: Saved to `~/minio-canada-pc-0001-1-credentials.txt`

### Example: Install on Control Plane

```bash
sudo ./scripts/storage/minio/install-minio.sh

# Select node: 1 (canada-pc-0001)
# Select disk: 2 (Use OS folder)
```

Result:
- Namespace: `minio-canada-pc-0001`
- Domain: `minio-canada-pc-0001.mynodeone.local`
- Credentials: Saved to `~/minio-canada-pc-0001-credentials.txt`

## Access

### Via .local Domain

```bash
# API endpoint
curl http://minio-<nodename>.<domain>.local:9000/minio/health/live

# Console (web UI) - separate domain
open http://minio-console-<nodename>.<domain>.local:9001
```

### Via LoadBalancer IPs

MinIO has **two separate LoadBalancer IPs**:

```bash
# Get API LoadBalancer IP
kubectl get svc minio -n minio-<nodename>

# Get Console LoadBalancer IP
kubectl get svc minio-console -n minio-<nodename>

# Access API via IP
curl http://<api-loadbalancer-ip>:9000/minio/health/live

# Access Console via IP
open http://<console-loadbalancer-ip>:9001
```

Example output after installation:
```
📡 API LoadBalancer IP: 100.79.104.207
📡 Console LoadBalancer IP: 100.79.104.208

🌍 Access URLs:
   API:     http://minio-canada-pc-0001.mynodeone.local:9000
   Console: http://minio-console-canada-pc-0001.mynodeone.local:9001
   API:     http://100.79.104.207:9000
   Console: http://100.79.104.208:9001
```

### Using mc CLI

```bash
# Install mc (MinIO client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Add alias
mc alias set mynode http://minio-<nodename>.mynodeone.local:9000 admin <password>

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
# - Services (API and Console LoadBalancers)
# - PVC
# - Secret
# - All data in /var/lib/minio (if using OS folder)

# Note: Both LoadBalancer IPs will be released back to MetalLB pool
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
sudo ./scripts/domains/update-laptop-dns.sh

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

## More Information

- Official docs: https://min.io/docs/minio/kubernetes/upstream/
- mc client guide: https://min.io/docs/minio/linux/reference/minio-mc.html
- S3 API compatibility: https://min.io/product/s3-compatibility