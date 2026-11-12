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

## ⚠️ Important: Server Image (PGSTY Silo, not upstream MinIO)

> [!CAUTION]
> **Do NOT switch back to `minio/minio` images.** Use the pinned `pgsty/silo` image.

**Default image:** `pgsty/silo:RELEASE.2026-11-09T00-00-00Z`, pinned by digest in `install-minio.sh`
(`MINIO_IMAGE_DEFAULT`). The installer substitutes it into `manifests/statefulset.yaml`.

Why:
- **Console removed upstream (2025):** after `RELEASE.2025-04-22T22-12-26Z`, MinIO Community Edition
  replaced the full admin console with a bare object browser (no users, groups, policies or settings).
  MyNodeOne originally pinned that release to keep the console.
- **Upstream distribution ended:** MinIO stopped publishing binaries/images in Oct 2025, put the
  repo into maintenance mode, then archived it on 2026-04-25. Around Sep 2026 the `minio/minio` and
  `minio/mc` images disappeared from Docker Hub, and `quay.io/minio/minio` refuses anonymous pulls.
  A pinned upstream tag keeps working only while it is cached on the node. Once kubelet image GC
  removes it (for example under disk pressure) the pod is stuck in `ImagePullBackOff`. This happened
  in Nov 2026.
- **PGSTY Silo** ([github.com/pgsty/silo](https://github.com/pgsty/silo), AGPL-3.0) is a
  community-maintained fork of the MinIO server. It restores the full admin console, ships security
  fixes and signed multi-arch images, and keeps the `MINIO_*` env vars, `server /data` CLI, S3/admin
  APIs and on-disk format, so it is a drop-in image swap. Silo is not affiliated with MinIO, Inc.
- **Chainguard (`cgr.dev/chainguard/minio`) was briefly the default** (Nov 2026). It builds current
  upstream source, so it has the reduced console, ships no shell or `mc`, and its free tier only
  offers `latest`. Silo replaced it because the full console is a requirement.

Things to know about the Silo image:
- **Runs as non-root.** The StatefulSet sets `runAsUser`/`runAsGroup` to `MINIO_RUN_AS_UID`
  (default 65532), drops all capabilities and disallows privilege escalation. `hostPath` volumes
  ignore `fsGroup`, so the installer sets the owner of the data directory. Silo has been verified to
  work this way.
- **Shell and clients included.** The image ships `sh`, `mc` and `mcli`, so
  `kubectl exec -n minio-<nodename> minio-0 -- mc ...` works. The standalone client image is `pgsty/mc`.

**Naming is unchanged on purpose.** Namespaces (`minio-<nodename>`), the `minio` StatefulSet and
services, `.local` domains (`minio-<nodename>`, `minio-console-<nodename>`), the `minio-credentials`
secret and the `/minio/health/*` probe paths all keep the "minio" name. It describes the role (S3
object storage), and renaming would break app endpoints, DNS, credentials files and backups for no
functional gain. Only the container image changed.

To use a different image:

```bash
MINIO_IMAGE=registry.example.com/minio@sha256:<digest> MINIO_RUN_AS_UID=<uid> \
  sudo -E ./scripts/storage/minio/install-minio.sh
```

Upgrading: read the [Silo release notes](https://silo.pgsty.com/) first, then update the tag **and**
digest of `MINIO_IMAGE_DEFAULT` in `install-minio.sh` (and roll running instances with
`kubectl set image`, below). Downgrading after newer Silo versions have written metadata is not
guaranteed, so back up important buckets before major upgrades. Mirror the image to your own
registry if you need to be independent of Docker Hub.

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
# Install mc (MinIO-compatible client from pgsty/mc; upstream dl.min.io binaries are gone)
# Pick the release pinned in scripts/lib/versions.sh (MINIO_CLIENT_VERSION), e.g.:
VER=RELEASE.2026-11-12T00-00-00Z; N=20261112000000.0.0; ARCH=amd64   # or arm64
wget https://github.com/pgsty/mc/releases/download/$VER/mcli_${N}_linux_${ARCH}.tar.gz
tar -xzf mcli_${N}_linux_${ARCH}.tar.gz mcli
sudo install -m 0755 mcli /usr/local/bin/mc

# Or skip installing: the server pod already ships `mc` (and `mcli`)
kubectl exec -it -n minio-<nodename> minio-0 -- mc --version

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
# Update image (Silo; pin a release tag + digest, never :latest. The image must work as the
# data directory owner's UID; Silo does. See "Server Image" above.)
kubectl set image statefulset/minio minio=pgsty/silo:<RELEASE-TAG>@sha256:<DIGEST> -n minio-<nodename>

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

### OS Folder

- Path: `/var/lib/minio`
- Size: Depends on OS disk
- No formatting required
- Easy to get started

### Dedicated Physical Disk (Recommended)

- Dedicated disk (e.g., `/dev/sdb`)
- Mounted at `/mnt/minio`
- Full disk capacity
- Better performance and isolation
- Formatted as ext4 with GPT partition table
- Safety lock (`chattr +i`) on mount point prevents writes to root filesystem if mount fails

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
  path: /mnt/minio    # Dedicated disk
  # or: /var/lib/minio  # OS folder
  type: Directory
```

With node affinity to ensure pod runs where data is.

## More Information

- Silo docs (server, console, `mc` reference): https://silo.pgsty.com/docs/
- Silo source & releases: https://github.com/pgsty/silo/releases
- Migrating from upstream MinIO: https://silo.pgsty.com/compatibility/migration/
- MinIO compatibility audit: https://silo.pgsty.com/compatibility/server/
- mc client (pgsty fork): https://github.com/pgsty/mc/releases
- Upstream MinIO docs (archived project, still useful for S3/IAM concepts): https://min.io/docs/