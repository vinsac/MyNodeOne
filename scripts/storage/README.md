# Storage Scripts

Component-based modular scripts for managing MyNodeOne storage architecture.

## Directory Structure

```
scripts/storage/
├── README.md (this file)
├── longhorn/          # Longhorn block storage scripts
├── minio/             # MinIO object storage scripts
│   └── install-worker.sh
├── velero/            # Velero backup scripts
│   ├── install.sh
│   └── configure-backup.sh
└── integration/       # Cross-component integration scripts
```

## Architecture Overview

```
Control Plane:
- Longhorn (block storage, single-node, replica=1)
- Velero (backup system)

Worker Node:
- MinIO (object storage, local disks)
- Longhorn disabled (allowScheduling=false)

Backup Flow:
Control Plane (Longhorn) → Velero → Worker (MinIO)
```

## Scripts

### install-velero.sh

**Purpose:** Install Velero backup system on control plane

**Called by:** `bootstrap-control-plane.sh` during control plane setup

**What it does:**
- Installs Velero CLI
- Installs Velero server components
- Waits for Velero to be ready
- Backup storage configured later when worker joins

**Usage:**
```bash
sudo ./scripts/storage/install-velero.sh
```

**Requirements:**
- Kubernetes cluster running
- kubectl configured
- Root access

**Output:**
- Velero CLI in `/usr/local/bin/velero`
- Velero deployment in `velero` namespace
- Ready for backup configuration

---

### install-minio-worker.sh

**Purpose:** Install MinIO object storage on worker node using local disks

**Called by:** `add-worker-node.sh` when worker joins cluster

**What it does:**
- Detects available disks (same logic as Longhorn)
- Prepares MinIO data directories
- Generates credentials
- Installs MinIO via Helm
- Configures hostPath volumes
- Saves credentials to `~/mynodeone-minio-worker-credentials.txt`

**Usage:**
```bash
sudo ./scripts/storage/install-minio-worker.sh
```

**Disk Detection:**
- Checks `/mnt/longhorn-disks/disk-*` for mounted disks
- Uses ALL available disks (distributed mode if multiple)
- Fallback to `/var/lib/minio` if no dedicated disks

**Requirements:**
- Kubernetes cluster running
- kubectl configured
- Helm installed
- Root access

**Output:**
- MinIO deployment in `minio` namespace
- MinIO credentials secret
- Credentials file: `~/mynodeone-minio-worker-credentials.txt`

---

### configure-velero-backup.sh

**Purpose:** Configure Velero to use MinIO as backup target

**Called by:** `add-worker-node.sh` after MinIO is installed

**What it does:**
- Retrieves MinIO credentials
- Creates Velero backup bucket in MinIO
- Creates Velero credentials secret
- Configures BackupStorageLocation
- Creates backup schedules:
  - `nightly-backup`: Full cluster backup (2AM UTC)
  - `longhorn-pvc-backup`: PVC backup (2AM UTC)
- Tests backup connectivity

**Usage:**
```bash
sudo ./scripts/storage/configure-velero-backup.sh
```

**Requirements:**
- Velero installed on control plane
- MinIO running on worker node
- kubectl configured
- Root access

**Backup Configuration:**
- Schedule: Nightly at 2:00 AM UTC
- Retention: 6 months (180 days)
- Bucket: `velero-backups`
- Incremental backups (Velero manages full/incremental)

**Output:**
- BackupStorageLocation: `default`
- Backup schedules created
- Test backup performed

---

## Installation Flow

### Control Plane Bootstrap

```bash
bootstrap-control-plane.sh
  └─> install_velero()
        └─> scripts/storage/install-velero.sh
              ├─ Install Velero CLI
              ├─ Install Velero server
              └─ Wait for ready
```

### Worker Node Addition

```bash
add-worker-node.sh
  ├─> disable_longhorn_on_worker()
  │     └─ Disable Longhorn scheduling on worker
  ├─> install_minio_worker()
  │     └─> scripts/storage/install-minio-worker.sh
  │           ├─ Detect disks
  │           ├─ Install MinIO
  │           └─ Save credentials
  └─> configure_velero_backup()
        └─> scripts/storage/configure-velero-backup.sh
              ├─ Create MinIO bucket
              ├─ Configure Velero
              └─ Create schedules
```

## Verification Commands

### Velero Status
```bash
# Check Velero installation
velero version

# Check backup storage location
velero backup-location get

# Check backup schedules
velero schedule get

# List backups
velero backup get
```

### MinIO Status
```bash
# Check MinIO pods
kubectl get pods -n minio

# Check MinIO service
kubectl get svc -n minio

# Get MinIO credentials
cat ~/mynodeone-minio-worker-credentials.txt
```

### Longhorn Status
```bash
# Check Longhorn nodes
kubectl get nodes.longhorn.io -n longhorn-system

# Verify worker scheduling disabled
kubectl get nodes.longhorn.io -n longhorn-system -o yaml | grep allowScheduling
```

## Backup Operations

### Create Manual Backup
```bash
# Backup entire cluster
velero backup create manual-backup-$(date +%Y%m%d-%H%M%S)

# Backup specific namespace
velero backup create app-backup --include-namespaces=myapp

# Backup with PVC snapshots
velero backup create pvc-backup --snapshot-volumes=true
```

### Restore from Backup
```bash
# List available backups
velero backup get

# Restore from backup
velero restore create --from-backup <backup-name>

# Restore specific namespace
velero restore create --from-backup <backup-name> --include-namespaces=myapp
```

### Monitor Backup Progress
```bash
# Watch backup progress
velero backup describe <backup-name>

# Watch restore progress
velero restore describe <restore-name>

# View logs
velero backup logs <backup-name>
```

## Troubleshooting

### Velero Not Ready
```bash
# Check Velero pods
kubectl get pods -n velero

# Check Velero logs
kubectl logs -n velero deployment/velero

# Reinstall Velero
sudo ./scripts/storage/install-velero.sh
```

### MinIO Installation Failed
```bash
# Check MinIO pods
kubectl get pods -n minio -o wide

# Check MinIO logs
kubectl logs -n minio -l app=minio

# Check disk mounts
df -h | grep longhorn-disks

# Reinstall MinIO
sudo ./scripts/storage/install-minio-worker.sh
```

### Backup Storage Location Unavailable
```bash
# Check backup location status
velero backup-location get

# Check MinIO connectivity
kubectl exec -n minio <minio-pod> -- mc ping myminio

# Reconfigure Velero backup
sudo ./scripts/storage/configure-velero-backup.sh
```

### Longhorn Still Scheduling on Worker
```bash
# Check Longhorn node settings
kubectl get nodes.longhorn.io -n longhorn-system <worker-node> -o yaml

# Manually disable scheduling
kubectl -n longhorn-system patch nodes.longhorn.io <worker-node> \
  --type=merge -p '{"spec":{"allowScheduling":false}}'
```

## Architecture Decisions

### Why Velero on Control Plane?
- Backup orchestration should be centralized
- Control plane has stable uptime
- Velero needs access to Kubernetes API

### Why MinIO on Worker?
- Worker has dedicated disks for object storage
- Separates backup storage from primary storage
- Prevents control plane disk exhaustion
- Worker can be offline without affecting backups (backups stored locally)

### Why Disable Longhorn on Worker?
- Single-node Longhorn is simpler and more reliable
- Avoids split-brain scenarios over Tailscale
- Reduces network overhead
- Backup-based resilience instead of replication

### Why Nightly Backups at 2AM UTC?
- Low usage time for most timezones
- Allows 6-hour window before business hours
- Consistent schedule for monitoring

## Security Notes

### MinIO Credentials
- Stored in Kubernetes secret: `minio-credentials` (namespace: `minio`)
- Saved to file: `~/mynodeone-minio-worker-credentials.txt` (chmod 600)
- **Action Required:** Save credentials to password manager and delete file

### Velero Credentials
- Stored in Kubernetes secret: `cloud-credentials` (namespace: `velero`)
- Uses MinIO root credentials
- Automatically configured by script

### Access Control
- MinIO accessible via LoadBalancer (Tailscale network only)
- Velero accessible via `velero` CLI (requires kubectl access)
- Longhorn UI protected by Tailscale VPN

## Performance Considerations

### Backup Impact
- Incremental backups minimize data transfer
- Backups run during low-usage hours (2AM UTC)
- No impact on application performance
- Network traffic over Tailscale (control plane → worker)

### Storage Efficiency
- Velero deduplicates backup data
- Compression enabled by default
- Retention policy prevents disk exhaustion (6 months)

### Restore Time
- Full cluster restore: ~10-30 minutes (depends on data size)
- Single namespace restore: ~2-5 minutes
- PVC restore: ~5-15 minutes (depends on volume size)

## Future Enhancements

### Potential Improvements
- [ ] Add backup encryption at rest
- [ ] Implement backup verification tests
- [ ] Add Slack/email notifications for backup failures
- [ ] Create backup dashboard in Grafana
- [ ] Add S3-compatible external backup target (e.g., Backblaze B2)
- [ ] Implement backup rotation policies per namespace
- [ ] Add pre/post backup hooks for databases

### Not Recommended
- ❌ Multi-node Longhorn replication (complexity, Tailscale overhead)
- ❌ Synchronous replication over Tailscale (latency, reliability)
- ❌ Ceph/Rook (overkill for 2-node cluster)
- ❌ Real-time backup (performance impact)
