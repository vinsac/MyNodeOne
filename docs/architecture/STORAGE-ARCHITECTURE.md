# MyNodeOne Storage Architecture

**Created:** January 11, 2026  
**Version:** 3.0  
**Status:** Current Implementation  

---

## Overview

MyNodeOne uses a dual-storage architecture designed for home lab and small business environments. The system provides both block storage and object storage capabilities, optimized for reliability, simplicity, and performance in limited-bandwidth environments.

### Storage Components

1. **Longhorn** - Distributed block storage system for Kubernetes PVCs
2. **MinIO** - S3-compatible object storage for large files and backups
3. **Node Agent** - Manages storage coordination and health monitoring

---

## Architecture Principles

### Design Goals

- **Resilience over High Availability**: Focus on data protection rather than uptime
- **Simplicity over Complexity**: Avoid distributed systems that require perfect networking
- **Predictable Failure Modes**: Clear recovery paths and manual restore processes
- **Network Efficiency**: Minimize cross-node data transfers over limited bandwidth

### Anti-Patterns Avoided

- ❌ Cross-node synchronous replication over Tailscale
- ❌ Automatic rebuild storms when nodes reconnect
- ❌ Complex distributed storage systems (Ceph, Rook, GlusterFS)
- ❌ Assumption of reliable high-bandwidth networking

---

## Storage Components

## 1. Longhorn - Block Storage

### Purpose
Longhorn provides Kubernetes Persistent Volume Claims (PVCs) for:
- Databases (PostgreSQL, MySQL, Redis)
- Stateful application data
- Application configuration and state
- Small to medium file storage

### Architecture
```
Control Plane Node          Worker Node
├── Longhorn Manager       ├── Longhorn Manager
├── Longhorn Engine        ├── Longhorn Engine  
├── Instance Manager       ├── Instance Manager
├── CSI Driver             ├── CSI Driver
└── Storage Disks          └── Storage Disks
```

### Key Settings
- **Replica Count**: 1 (no cross-node replication)
- **Scheduling**: Available on all nodes
- **Storage Class**: `longhorn` (cluster default)
- **Failure Mode**: Manual restore from backups

### Disk Management
- **Interactive Selection**: User chooses disks during installation
- **Automatic Detection**: Scripts identify available disks
- **Formatting**: Disks formatted with XFS filesystem
- **Mount Points**: `/mnt/longhorn-disks/disk-*`
- **Fallback**: Uses OS disk (`/var/lib/longhorn`) if no dedicated disks

### Installation Flow

#### Control Plane (bootstrap-control-plane.sh)
```bash
1. Install Longhorn via Helm
2. Detect available disks
3. Interactive disk selection
4. Format and mount selected disks
5. Add disks to Longhorn storage pool
6. Verify Longhorn components
```

#### Worker Node (add-worker-node.sh)
```bash
1. Install Longhorn components
2. Detect available disks on worker
3. Interactive disk selection
4. Format and mount selected disks
5. Add worker disks to cluster storage pool
6. Enable scheduling on worker node
```

---

## 2. MinIO - Object Storage

### Purpose
MinIO provides S3-compatible object storage for:
- Large file storage (photos, videos, documents)
- Application backups and archives
- Media streaming and content delivery
- LLM model storage and serving

### Architecture
```
Each Node: Independent MinIO Instance
├── Kubernetes StatefulSet
├── MetalLB LoadBalancer Service
├── Dedicated Physical Disks
├── Independent Credentials
└── .local Domain Access
```

### Key Features
- **Per-Node Instances**: Each node runs independent MinIO
- **Independent Credentials**: Unique admin credentials per instance
- **MetalLB Integration**: LoadBalancer IP for each instance
- **Service Discovery**: `minio-<nodename>.mynodeone.local`
- **HostPath Storage**: Direct disk access (not PVC)

### Disk Management
- **Separate from Longhorn**: Uses different disks than Longhorn
- **Interactive Selection**: User chooses disks during installation
- **Direct Mount**: `/mnt/minio` with dedicated disks
- **No Replication**: Each instance is standalone

### Installation Flow

#### Interactive Installation (install-minio.sh)
```bash
1. Select target node (control plane or worker)
2. Detect available disks (excluding Longhorn disks)
3. Interactive disk selection for MinIO
4. Format and mount disk to /mnt/minio
5. Generate unique credentials
6. Deploy Kubernetes StatefulSet
7. Create MetalLB LoadBalancer service
8. Register in service registry
9. Configure .local domain access
```

#### Access Patterns
```bash
# Cluster internal (service discovery)
minio-pc1.mynodeone.local:9000
minio-worker1.mynodeone.local:9000

# Direct IP access
100.116.16.117:9000  # Control plane
100.116.16.118:9000  # Worker node

# Application access
S3_ENDPOINT="http://minio-worker1.mynodeone.local:9000"
```

---

## 3. Node Agent - Storage Coordination

### Purpose
The Node Agent service provides:
- Storage health monitoring
- Configuration synchronization
- Service registry updates
- Backup coordination

### Components
```bash
Node Agent Service (mynodeone-node-agent)
├── Storage Health Checks
├── Disk Usage Monitoring  
├── Service Registration
├── Heartbeat to Control Plane
└── Configuration Sync
```

### Installation
- **Control Plane**: Installed during bootstrap
- **Worker Nodes**: Installed during node addition
- **Systemd Service**: Runs as system service
- **Logs**: `/var/log/mynodeone-node-agent.log`

---

## Installation Flow

## Control Plane Bootstrap

```bash
# scripts/installation/bootstrap-control-plane.sh

1. Install K3s
2. Install MetalLB (LoadBalancer)
3. Install Traefik (Ingress)
4. Install Longhorn (interactive disk selection)
5. Install MinIO (optional, interactive)
6. Install Node Agent
7. Install Monitoring (Grafana, Prometheus)
8. Install ArgoCD (GitOps)
```

### Longhorn Installation
```bash
install_longhorn() {
    # Interactive disk detection and selection
    # Format and mount disks
    # Add to Longhorn storage pool
    # Verify components running
}
```

### MinIO Installation
```bash
install_minio() {
    # Optional installation prompt
    # Interactive disk selection (separate from Longhorn)
    # Deploy as Kubernetes StatefulSet
    # Configure MetalLB LoadBalancer
    # Register service
}
```

## Worker Node Addition

```bash
# scripts/nodes/add-worker-node.sh

1. Join cluster (K3s agent)
2. Configure kubectl access
3. Install Longhorn (interactive disk selection)
4. Install MinIO (optional, interactive)
5. Install Node Agent
6. Apply node labels
7. Verify storage components
```

### Storage Setup
```bash
install_longhorn() {
    # Detect disks on worker node
    # Interactive selection
    # Add to cluster storage pool
    # Enable scheduling on worker
}

install_minio() {
    # Show installation instructions
    # User runs MinIO installer from control plane
    # Selects worker node as target
    # Deploys MinIO on worker
}
```

---

## Storage Classes

### Default Storage Class
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"     # 30 minutes
  replicaReplenishmentWaitInterval: "432000"  # 5 days (432000 seconds)
  fromBackup: ""
  fsType: "xfs"
```

### Key Longhorn Settings

#### staleReplicaTimeout: "30" (30 minutes)
- **Purpose**: How long Longhorn waits before marking a replica as "stale"
- **Behavior**: After 30 minutes of no communication, replica is marked stale
- **Impact**: Short timeout ensures quick detection of failed replicas

#### replicaReplenishmentWaitInterval: "432000" (5 days)
- **Purpose**: How long Longhorn waits before rebuilding a lost replica
- **Behavior**: Waits 5 days before starting replica rebuild process
- **Impact**: Prevents unnecessary rebuilds when nodes temporarily disconnect
- **Critical for**: Avoiding network traffic over limited bandwidth connections

### Usage Patterns

#### Database Storage
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Gi
```

#### Application Storage
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 50Gi
```

---

## Service Discovery

### DNS Configuration
Each MinIO instance gets a `.local` domain:
- `minio-pc1.mynodeone.local` - Control plane MinIO
- `minio-worker1.mynodeone.local` - Worker node MinIO

### Service Registry
```bash
# Service registry entries
{
  "name": "minio-pc1",
  "type": "object-storage", 
  "namespace": "minio-pc1",
  "service": "minio",
  "port": 9000,
  "domain": "minio-pc1.mynodeone.local",
  "loadbalancer_ip": "100.116.16.117"
}
```

### Access Methods
```bash
# 1. Service discovery (cluster internal)
curl http://minio-worker1.mynodeone.local:9000/minio/health/live

# 2. LoadBalancer IP (direct access)
curl http://100.116.16.118:9000/minio/health/live

# 3. Node port (via Tailscale)
curl http://worker1-tailscale-ip:9000/minio/health/live
```

---

## Disk Management

### Disk Detection Algorithm
```bash
detect_available_disks() {
    # List all block devices
    lsblk -d -n -o NAME,SIZE,ROTA,TYPE,MOUNTPOINT | \
    grep -E "disk" | \
    while read disk size rota type mount; do
        # Skip OS disk (mounted on /)
        # Skip mounted disks
        # Skip Longhorn disks
        # Skip MinIO disks
        echo "$disk $size"
    done
}
```

### Disk Selection Flow
```bash
1. Detect all available disks
2. Filter out system disks
3. Filter out already-used disks
4. Present interactive menu
5. User selects disk(s)
6. Format with XFS
7. Mount to appropriate location
8. Add to storage system
```

### Mount Points
```bash
# Longhorn storage
/mnt/longhorn-disks/disk-1
/mnt/longhorn-disks/disk-2

# MinIO storage  
/mnt/minio

# OS fallback locations
/var/lib/longhorn
/var/lib/minio
```

---

## Backup Strategy

### Current Approach (No Velero)
MyNodeOne has **removed Velero** from the cluster. Backup strategy is now:

1. **Application-Level Backups**: Apps handle their own backups
2. **MinIO Cross-Replication**: Optional manual replication between MinIO instances
3. **External Backups**: Users can backup MinIO data to external storage
4. **Longhorn Snapshots**: Manual snapshots for critical data

### Manual Backup Examples
```bash
# MinIO backup to external location
mc mirror minio-worker1/backup /external/backup/

# Longhorn volume backup
kubectl create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: VolumeBackup
metadata:
  name: manual-backup-$(date +%Y%m%d)
  namespace: longhorn-system
spec:
  volumeName: pvc-12345
EOF
```

---

## Monitoring and Observability

### Longhorn Monitoring
```bash
# Longhorn UI
http://longhorn.mynodeone.local

# Prometheus metrics
kubectl get svc -n longhorn-system longhorn-prometheus

# Disk usage
kubectl get nodes.longhorn.io -n longhorn-system
```

### MinIO Monitoring
```bash
# MinIO Console
http://minio-pc1.mynodeone.local:9001

# Health check
curl http://minio-pc1.mynodeone.local:9000/minio/health/live

# Disk usage
df -h /mnt/minio
```

### Node Agent Logs
```bash
# Check node agent status
sudo systemctl status mynodeone-node-agent

# View logs
sudo journalctl -u mynodeone-node-agent -f

# Storage health report
sudo /opt/mynodeone/node-agent storage-health
```

---

## Troubleshooting

### Common Issues

#### Longhorn Issues
```bash
# Longhorn components not running
kubectl get pods -n longhorn-system

# Disks not added
kubectl get nodes.longhorn.io -n longhorn-system

# PVC stuck in pending
kubectl describe pvc <pvc-name>
```

#### MinIO Issues
```bash
# MinIO pod not ready
kubectl get pods -n minio-<nodename>

# Service not accessible
kubectl get svc -n minio-<nodename>

# Disk not mounted
exec_into_minio_pod && df -h
```

#### Disk Issues
```bash
# Check disk mounts
lsblk
df -h

# Check XFS filesystem
sudo xfs_repair /dev/sdX

# Check disk health
sudo smartctl -a /dev/sdX
```

### Recovery Procedures

#### Longhorn Recovery
```bash
# Restart Longhorn components
kubectl rollout restart deployment/longhorn-manager -n longhorn-system

# Re-add disk to Longhorn
kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Node
metadata:
  name: <nodename>
  namespace: longhorn-system
spec:
  disks:
  - name: disk-1
    path: /mnt/longhorn-disks/disk-1
    allowScheduling: true
EOF
```

#### MinIO Recovery
```bash
# Restart MinIO pod
kubectl rollout restart statefulset/minio -n minio-<nodename>

# Restore from backup (if available)
mc mirror /backup/minio-data/ minio-<nodename>/
```

---

## Performance Considerations

### Longhorn Performance
- **Replica Count**: 1 (no network overhead)
- **Filesystem**: XFS (optimized for large files)
- **Direct I/O**: Bypass cache for better performance
- **SSD vs HDD**: SSD recommended for databases

### MinIO Performance
- **Direct Disk Access**: HostPath volumes (no PVC overhead)
- **Erbium Coding**: Erasure coding for data protection
- **Parallel Uploads**: Multi-part uploads for large files
- **Cache Settings**: Tune based on available RAM

### Network Considerations
- **Tailscale**: Limited bandwidth, avoid large transfers
- **Local Access**: Prefer same-node access when possible
- **Service Discovery**: Use .local domains for cluster access

---

## Security

### Access Control
```bash
# Longhorn RBAC
kubectl get clusterrole longhorn-manager
kubectl get clusterrolebinding longhorn-manager

# MinIO Credentials (per-instance)
MINIO_ROOT_USER="admin"
MINIO_ROOT_PASSWORD="<unique-per-node>"

# Node Agent Permissions
sudo systemctl status mynodeone-node-agent
```

### Network Security
- **Tailscale VPN**: All cluster communication encrypted
- **MetalLB IPs**: Internal cluster IPs only
- **Service Discovery**: .local domains not exposed externally
- **VPS Exposure**: Explicit routing configuration required

### Data Protection
- **Encryption**: XFS filesystem encryption optional
- **Backups**: Application-level backup responsibility
- **Access Logs**: MinIO and Longhorn access logging
- **Audit Trail**: Node Agent operation logging

---

## Future Enhancements

### Planned Improvements
1. **Automated Backups**: Cross-node MinIO replication
2. **Storage Monitoring**: Enhanced Grafana dashboards
3. **Performance Tuning**: Automatic optimization based on workload
4. **Disk Health Monitoring**: SMART attribute monitoring
5. **Capacity Planning**: Usage prediction and alerts

### Architecture Evolution
- **Multi-Cluster Support**: Storage across multiple clusters
- **Cloud Integration**: Hybrid cloud storage options
- **Advanced Replication**: Optional async replication
- **Storage Classes**: Multiple performance tiers

---

## Configuration Reference

### Longhorn Settings
```yaml
# longhorn-settings.yaml
defaultReplicaCount: 1
defaultDataPath: /var/lib/longhorn
createDefaultDiskLabeledNodes: true
failedRetryThreshold: 5
backupTarget: ""
disableRevisionCounter: false
systemManagedPodsImagePullPolicy: IfNotPresent
```

### MinIO Configuration
```yaml
# minio-env.yaml
MINIO_ROOT_USER: "admin"
MINIO_ROOT_PASSWORD: "<generated>"
MINIO_BROWSER_REDIRECT_URL: "http://minio-<node>.mynodeone.local:9001"
MINIO_SERVER_URL: "http://minio-<node>.mynodeone.local:9000"
```

### Node Agent Configuration
```bash
# /etc/mynodeone/node-agent.conf
NODE_TYPE="control-plane|worker"
STORAGE_MONITORING=true
HEALTH_CHECK_INTERVAL=30
SERVICE_REGISTRY_URL="http://control-plane:8080"
```

---

## Conclusion

MyNodeOne's storage architecture provides a robust, simple, and efficient storage solution for home lab and small business environments. The dual-storage approach with Longhorn for block storage and MinIO for object storage covers all common use cases while maintaining simplicity and reliability.

The architecture prioritizes:
- **Data safety** through manual backup processes
- **Network efficiency** by avoiding cross-node replication
- **Simplicity** with interactive installation and clear failure modes
- **Flexibility** with per-node storage management

This design ensures that users have reliable storage without the complexity of distributed systems, making it ideal for environments with limited bandwidth and technical resources.
