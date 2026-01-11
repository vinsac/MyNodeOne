# MinIO Service Discovery and DNS

## Overview

MinIO instances on worker nodes are automatically registered in the cluster's service registry and assigned DNS names for easy access.

---

## Service Registration

### Automatic Registration

When MinIO is installed on any node (control plane or worker), the installer automatically:

1. **Creates LoadBalancer Services** - MetalLB assigns IPs from the pool
2. **Registers in Service Registry** - Adds entries to `service-registry` ConfigMap
3. **Updates DNS** - Syncs entries to `/etc/hosts` on control plane
4. **Provides DNS Names** - Node-specific endpoints for access

---

## DNS Naming Convention

### Format

```
minio-<node-name>.mynodeone.local:9000        # S3 API endpoint
minio-console-<node-name>.mynodeone.local:9001 # Web Console
```

### Examples

**Control Plane Node:**
```
Node name: canada-pc-control-0001
API:     minio-canada-pc-control-0001.mynodeone.local:9000
Console: minio-console-canada-pc-control-0001.mynodeone.local:9001
```

**Worker Node:**
```
Node name: canada-pc-worker-0001
API:     minio-canada-pc-worker-0001.mynodeone.local:9000
Console: minio-console-canada-pc-worker-0001.mynodeone.local:9001
```

---

## LoadBalancer IP Assignment

### MetalLB Integration

MinIO services use `type: LoadBalancer` to get IPs from MetalLB:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: minio-canada-pc-worker-0001
  namespace: minio
spec:
  type: LoadBalancer  # MetalLB assigns IP from pool
  ports:
  - port: 9000
    targetPort: 9000
  selector:
    app: minio
    node: canada-pc-worker-0001
```

**IP Assignment:**
- MetalLB automatically assigns IPs from configured pool
- Each MinIO instance gets 2 IPs (API + Console)
- IPs are stable and persist across pod restarts

---

## Service Registry

### ConfigMap Structure

Services are registered in `service-registry` ConfigMap in `kube-system` namespace:

```json
{
  "minio-canada-pc-worker-0001": {
    "subdomain": "minio-canada-pc-worker-0001",
    "namespace": "minio",
    "service": "minio-canada-pc-worker-0001",
    "ip": "100.77.243.210",
    "port": 9000,
    "public": false,
    "updated": "2026-01-08T18:45:00Z"
  },
  "minio-console-canada-pc-worker-0001": {
    "subdomain": "minio-console-canada-pc-worker-0001",
    "namespace": "minio",
    "service": "minio-console-canada-pc-worker-0001",
    "ip": "100.77.243.211",
    "port": 9001,
    "public": false,
    "updated": "2026-01-08T18:45:00Z"
  }
}
```

### Viewing Registry

```bash
# View all registered services
kubectl get configmap service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq

# View MinIO services only
kubectl get configmap service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq 'to_entries[] | select(.key | startswith("minio"))'

# Get specific MinIO service IP
kubectl get configmap service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq -r '.["minio-canada-pc-worker-0001"].ip'
```

---

## DNS Resolution

### /etc/hosts Updates

The `sync-dns.sh` script reads the service registry and updates `/etc/hosts` on the control plane:

```bash
# /etc/hosts on control plane
100.77.243.210 minio-canada-pc-worker-0001.mynodeone.local
100.77.243.211 minio-console-canada-pc-worker-0001.mynodeone.local
```

**Automatic Updates:**
- Triggered after MinIO installation
- Can be manually run: `sudo ./scripts/sync-dns.sh`
- Updates are idempotent (safe to run multiple times)

### DNS Propagation

**Control Plane:**
- ✅ Automatic - DNS entries added to `/etc/hosts`
- ✅ Immediate - Available right after installation

**Worker Nodes:**
- ❌ Not automatic - Workers don't run `sync-dns.sh`
- ✅ Can access via IP directly
- ✅ Can access via cluster DNS (if using CoreDNS)

**Management Laptops:**
- ❌ Not automatic - Need manual DNS update
- ✅ Can run `update-laptop-dns.sh` to sync

---

## Accessing MinIO

### From Control Plane

```bash
# Using DNS name (recommended)
mc alias set worker-minio http://minio-canada-pc-worker-0001.mynodeone.local:9000 admin [password]

# Using IP directly
mc alias set worker-minio http://100.77.243.210:9000 admin [password]

# Web Console
xdg-open http://minio-console-canada-pc-worker-0001.mynodeone.local:9001
```

### From Worker Node

```bash
# Worker can access its own MinIO via localhost
mc alias set local http://localhost:9000 admin [password]

# Or via cluster DNS
mc alias set local http://minio-canada-pc-worker-0001.minio.svc.cluster.local:9000 admin [password]
```

### From Applications in Cluster

```yaml
# Use Kubernetes service DNS
apiVersion: v1
kind: Pod
metadata:
  name: backup-job
spec:
  containers:
  - name: backup
    env:
    - name: S3_ENDPOINT
      value: "http://minio-canada-pc-worker-0001.minio.svc.cluster.local:9000"
    - name: S3_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: minio-credentials
          key: rootUser
    - name: S3_SECRET_KEY
      valueFrom:
        secretKeyRef:
          name: minio-credentials
          key: rootPassword
```

---

## Troubleshooting

### MinIO Not Accessible via DNS

**Symptom:** `ping minio-canada-pc-worker-0001.mynodeone.local` fails

**Diagnosis:**
```bash
# Check if service has LoadBalancer IP
kubectl get svc -n minio

# Check if service is registered
kubectl get configmap service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq '.["minio-canada-pc-worker-0001"]'

# Check /etc/hosts on control plane
grep minio /etc/hosts
```

**Fix:**
```bash
# Re-register services
sudo ./scripts/lib/service-registry.sh sync

# Update DNS
sudo ./scripts/sync-dns.sh

# Verify
ping minio-canada-pc-worker-0001.mynodeone.local
```

### LoadBalancer IP Pending

**Symptom:** `kubectl get svc -n minio` shows `<pending>` for EXTERNAL-IP

**Cause:** MetalLB not configured or IP pool exhausted

**Fix:**
```bash
# Check MetalLB status
kubectl get pods -n metallb-system

# Check IP pool configuration
kubectl get ipaddresspool -n metallb-system -o yaml

# Check if IPs are available
kubectl get svc --all-namespaces -o wide | grep LoadBalancer
```

### Service Registry Not Updated

**Symptom:** MinIO installed but not in service registry

**Cause:** Registration failed during installation

**Fix:**
```bash
# Get node name
NODE_NAME=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')

# Get service IPs
API_IP=$(kubectl get svc minio-${NODE_NAME} -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
CONSOLE_IP=$(kubectl get svc minio-console-${NODE_NAME} -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Manually register
sudo ./scripts/lib/service-registry.sh register \
  "minio-${NODE_NAME}" "minio-${NODE_NAME}" minio "minio-${NODE_NAME}" 9000 false

sudo ./scripts/lib/service-registry.sh register \
  "minio-console-${NODE_NAME}" "minio-console-${NODE_NAME}" minio "minio-console-${NODE_NAME}" 9001 false

# Sync DNS
sudo ./scripts/sync-dns.sh
```

### DNS Not Resolving on Worker

**Symptom:** Worker node can't resolve MinIO DNS names

**Cause:** Worker nodes don't have `/etc/hosts` updates

**Solution 1: Use Cluster DNS**
```bash
# Access via Kubernetes service DNS (works from any pod)
http://minio-canada-pc-worker-0001.minio.svc.cluster.local:9000
```

**Solution 2: Use IP Directly**
```bash
# Get IP from service
kubectl get svc minio-canada-pc-worker-0001 -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Use IP
http://100.77.243.210:9000
```

**Solution 3: Manual /etc/hosts Update**
```bash
# On worker node
sudo ./scripts/sync-dns.sh
```

---

## Service Discovery Commands

### Quick Reference

```bash
# List all MinIO services
kubectl get svc -n minio

# Get MinIO API IP
kubectl get svc minio-<node-name> -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Get MinIO Console IP
kubectl get svc minio-console-<node-name> -n minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# View service registry
kubectl get configmap service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq

# Sync DNS
sudo ./scripts/sync-dns.sh

# Test DNS resolution
ping minio-<node-name>.mynodeone.local
curl http://minio-<node-name>.mynodeone.local:9000/minio/health/live
```

---

## Related Documentation

- **Service Registry:** `scripts/lib/service-registry.sh`
- **DNS Sync:** `scripts/sync-dns.sh`
- **MinIO Credentials:** `scripts/storage/MINIO-CREDENTIALS.md`
- **Architecture:** `docs/architecture/STORAGE-ARCHITECTURE-PROMPT.md`
