# Storage Scripts

Component-based modular scripts for managing MyNodeOne storage architecture.

## Directory Structure

```
scripts/storage/
├── README.md (this file)
├── longhorn/          # Longhorn block storage scripts
├── minio/             # MinIO object storage scripts
│   └── install-minio-worker.sh
├── velero/            # Velero backup scripts (reference only)
│   ├── install.sh
│   └── configure-backup.sh
└── integration/       # Cross-component integration scripts
```

## Architecture Overview

```
Control Plane:
- Longhorn (block storage, single-node, replica=1)

Worker Node:
- MinIO (object storage, local disks)
- Longhorn disabled (allowScheduling=false)

Current State:
- Manual backup and restore procedures
- MinIO provides object storage for applications
- No automated cluster backups (Velero removed per user decision)
```

## Scripts

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
sudo ./scripts/storage/minio/install-minio-worker.sh
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

## Installation Flow

### Control Plane Bootstrap

```bash
bootstrap-control-plane.sh
  └─> install_longhorn()
        └─> Longhorn block storage setup
```

### Worker Node Addition

```bash
add-worker-node.sh
  ├─> disable_longhorn_on_worker()
  │     └─ Disable Longhorn scheduling on worker
  └─> install_minio_worker()
        └─> scripts/storage/minio/install-minio-worker.sh
              ├─ Detect disks
              ├─ Install MinIO
              └─ Save credentials
```

## Verification Commands

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

## Manual Backup Operations

Since Velero was removed, backups are now manual. Here are the recommended approaches:

### Application Data Backup
```bash
# Backup application data using MinIO
# 1. Access MinIO console: http://minio.mynodeone.local:9001
# 2. Create buckets for application backups
# 3. Use application-specific backup tools

# Example: Backup Nextcloud data
kubectl exec -n nextcloud deployment/nextcloud -- \
  php occ files:scan --all
```

### Longhorn Volume Backup
```bash
# Create Longhorn backup manually
kubectl create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d-%H%M%S)
  namespace: longhorn-system
spec:
  volumeName: <volume-name>
  snapshotName: <snapshot-name>
EOF

# List backups
kubectl get backups -n longhorn-system
```

### Configuration Backup
```bash
# Backup Kubernetes configurations
kubectl get all --all-namespaces -o yaml > cluster-backup-$(date +%Y%m%d).yaml

# Backup ConfigMaps and Secrets
kubectl get configmaps,secrets --all-namespaces -o yaml > config-backup-$(date +%Y%m%d).yaml
```

## Troubleshooting

### MinIO Installation Failed
```bash
# Check MinIO pods
kubectl get pods -n minio -o wide

# Check MinIO logs
kubectl logs -n minio -l app=minio

# Check disk mounts
df -h | grep longhorn-disks

# Reinstall MinIO
sudo ./scripts/storage/minio/install-minio-worker.sh
```

### Longhorn Still Scheduling on Worker
```bash
# Check Longhorn node settings
kubectl get nodes.longhorn.io -n longhorn-system <worker-node> -o yaml

# Manually disable scheduling
kubectl -n longhorn-system patch nodes.longhorn.io <worker-node> \
  --type=merge -p '{"spec":{"allowScheduling":false}}'
```

### MinIO Access Issues
```bash
# Check MinIO service
kubectl get svc -n minio

# Check LoadBalancer IP
kubectl get svc -n minio -o yaml | grep LoadBalancer

# Test MinIO connectivity
curl -I http://<minio-ip>:9000/minio/health/live
```

## Architecture Decisions

### Why MinIO on Worker?
- Worker has dedicated disks for object storage
- Separates backup storage from primary storage
- Prevents control plane disk exhaustion
- Provides S3-compatible storage for applications

### Why Disable Longhorn on Worker?
- Single-node Longhorn is simpler and more reliable
- Avoids split-brain scenarios over Tailscale
- Reduces network overhead
- Manual backup-based resilience instead of replication

### Why No Automated Backups?
- Per user decision: No automated cluster backups needed
- Manual backups provide more control
- Reduces complexity and resource usage
- Users can implement backup strategies as needed

## Security Notes

### MinIO Credentials
- Stored in Kubernetes secret: `minio-credentials` (namespace: `minio`)
- Saved to file: `~/mynodeone-minio-worker-credentials.txt` (chmod 600)
- **Action Required:** Save credentials to password manager and delete file

### Access Control
- MinIO accessible via LoadBalancer (Tailscale network only)
- Longhorn UI protected by Tailscale VPN
- Local DNS resolution for `.mynodeone.local` domains

## Performance Considerations

### Storage Efficiency
- Longhorn provides block storage with replica=1
- MinIO provides object storage with distributed mode
- Network traffic over Tailscale for cross-node access

### Disk Usage
- Longhorn volumes consume dedicated disks
- MinIO uses available disks for object storage
- Monitor disk usage: `df -h | grep -E "(longhorn|minio)"`

## Future Enhancements

### Potential Improvements
- [ ] Add backup encryption at rest
- [ ] Implement backup verification tests
- [ ] Add backup dashboard in Grafana
- [ ] Add S3-compatible external backup target (e.g., Backblaze B2)
- [ ] Implement backup rotation policies per namespace
- [ ] Add pre/post backup hooks for databases

### Not Recommended
- ❌ Multi-node Longhorn replication (complexity, Tailscale overhead)
- ❌ Synchronous replication over Tailscale (latency, reliability)
- ❌ Ceph/Rook (overkill for 2-node cluster)
- ❌ Real-time backup (performance impact)

## Velero Reference

The Velero scripts remain in `scripts/storage/velero/` for reference only:
- Not called by any installation scripts
- Removed per user decision (Jan 9, 2026)
- Can be restored manually if automated backups are needed later

To restore Velero functionality:
1. Install Velero: `sudo ./scripts/storage/velero/install.sh`
2. Configure backup: `sudo ./scripts/storage/velero/configure-backup.sh`

## Getting Help

For storage-related issues:
1. Check the troubleshooting section above
2. Review MinIO and Longhorn logs
3. Verify disk mounts and network connectivity
4. Check Kubernetes resource status
