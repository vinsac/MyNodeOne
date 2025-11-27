# MyNodeOne Scaling Guide

## Scaling Philosophy

MyNodeOne is designed to scale with your needs:
- **Vertical Scaling**: Upgrade individual nodes (more RAM, CPU, storage)
- **Horizontal Scaling**: Add more nodes to the cluster
- **Application Scaling**: Increase replicas, optimize code

## Adding Your Second Node (Example: node-002)

### Prerequisites

- Ubuntu 24.04 LTS installed
- Tailscale installed and connected
- Root/sudo access

### Step-by-Step

#### 1. Install Tailscale on new machine

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

#### 2. Run the worker node script

```bash
# On your second machine (worker node)
git clone <mynodeone-repo-url>
cd mynodeone
sudo ./scripts/add-worker-node.sh
```

The script will:
- Auto-discover the control plane via Tailscale
- Ask for the join token
- Install K3s agent
- Configure storage
- Join the cluster

#### 3. Apply node labels (on control plane)

```bash
# On control plane
kubectl label node node-002 node-role.kubernetes.io/worker=true
kubectl label node node-002 mynodeone.io/location=home
kubectl label node node-002 mynodeone.io/storage=true
```

#### 4. Verify

```bash
kubectl get nodes
# Should show both control-plane and node-002

kubectl top nodes
# Check resource usage
```

#### 5. Update Longhorn replica count

```bash
# Now that you have 2 nodes, enable 2 replicas
kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
  -p '{"value":"2"}' --type=merge
```

### What Changes with 2 Nodes?

**Before (1 node):**
- Single point of failure
- No data redundancy
- All pods on one node

**After (2 nodes):**
- Apps survive single node failure
- Data replicated 2x
- Pods distributed across nodes
- Better resource utilization

## Adding Third Node (Example: node-003)

Same process as node-002!

```bash
# On your third machine
sudo ./scripts/add-worker-node.sh

# On control plane
kubectl label node node-003 node-role.kubernetes.io/worker=true
kubectl label node node-003 mynodeone.io/location=home
kubectl label node node-003 mynodeone.io/storage=true

# Update Longhorn for 3 replicas
kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
  -p '{"value":"3"}' --type=merge
```

**With 3 nodes:**
- Can survive 1 node failure without data loss
- Optimal for production workloads
- Quorum-based decisions
- Better load distribution

## Scaling Applications

### Manual Scaling

```bash
# Scale to 5 replicas
kubectl scale deployment/<deployment-name> --replicas=5

# Scale to 0 (pause app)
kubectl scale deployment/<deployment-name> --replicas=0
```

### Horizontal Pod Autoscaler (HPA)

Automatically scale based on CPU/memory usage:

```bash
# Auto-scale between 2 and 10 replicas based on CPU
kubectl autoscale deployment/<deployment-name> \
  --min=2 \
  --max=10 \
  --cpu-percent=80
```

Example HPA manifest:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 20
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 4
        periodSeconds: 30
      selectPolicy: Max
```

### Vertical Pod Autoscaler (VPA)

Automatically adjust resource requests/limits:

```bash
# Install VPA
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler
./hack/vpa-up.sh
```

Example VPA manifest:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Auto"  # or "Initial" or "Off"
  resourcePolicy:
    containerPolicies:
    - containerName: my-app
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: 2
        memory: 2Gi
```

## Storage Scaling

### Adding More Disks to Existing Nodes

```bash
# 1. Physically attach disk to node
# 2. Format and mount

sudo mkfs.ext4 /dev/sdb
sudo mkdir -p /mnt/longhorn2
sudo mount /dev/sdb /mnt/longhorn2

# Make permanent
echo "/dev/sdb /mnt/longhorn2 ext4 defaults 0 0" | sudo tee -a /etc/fstab

# 3. Add to Longhorn via UI
# Longhorn UI → Node → Edit Node → Add Disk
# Path: /mnt/longhorn2
# Storage Available: (auto-detected)
```

### Expanding Existing Volumes

```bash
# Check if storage class supports expansion
kubectl get storageclass longhorn -o yaml | grep allowVolumeExpansion

# Expand PVC
kubectl patch pvc <pvc-name> -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# Check status
kubectl get pvc <pvc-name> -w
```

### MinIO Scaling

#### Single Instance → Distributed

When you add your second node:

```bash
# Uninstall standalone MinIO
helm uninstall minio -n minio

# Install distributed MinIO
helm install minio minio/minio \
  --namespace minio \
  --set mode=distributed \
  --set replicas=4 \
  --set persistence.enabled=true \
  --set persistence.size=2Ti \
  --set persistence.storageClass=longhorn
```

## Network Scaling

### Adding More VPS Edge Nodes

Add more Contabo VPS or other providers:

```bash
# On new VPS
git clone <mynodeone-repo>
cd mynodeone
sudo ./scripts/setup-edge-node.sh
```

### DNS Load Balancing

Point domain to multiple VPS IPs:

```
# DNS Records
A    @    45.8.133.192
A    @    31.220.87.37
A    @    <new-vps-ip>
```

Clients will round-robin between IPs automatically.

### Geographic Distribution

Deploy VPS nodes in different regions:

```
Toronto VPS   → Low latency for North America
Europe VPS    → Low latency for EU users
Asia VPS      → Low latency for Asian users
```

Configure Traefik geo-routing (advanced):

```yaml
# /etc/traefik/dynamic/geo-routing.yml
http:
  routers:
    app-us:
      rule: "Host(`myapp.com`) && ClientIP(`<US-IP-Range>`)"
      service: us-backend
    app-eu:
      rule: "Host(`myapp.com`) && ClientIP(`<EU-IP-Range>`)"
      service: eu-backend
```

## Monitoring at Scale

### Prometheus Scalability

With many nodes/pods, Prometheus can become resource-intensive:

```bash
# Increase retention period and resources
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set prometheus.prometheusSpec.retention=90d \
  --set prometheus.prometheusSpec.resources.requests.memory=16Gi \
  --set prometheus.prometheusSpec.resources.requests.cpu=4
```

### Thanos for Long-term Storage

For unlimited retention with object storage:

```bash
# Install Thanos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install thanos bitnami/thanos \
  --set objstoreConfig.type=s3 \
  --set objstoreConfig.config.bucket=prometheus-data \
  --set objstoreConfig.config.endpoint=<minio-endpoint>
```

## Capacity Planning

### Current Capacity (1 node)

**Your control plane (example specs):**
- 16+ GB RAM
- 4+ CPU cores
- 100+ GB storage

**Estimated Capacity:**
- 50-100 small apps (100MB RAM each)
- 10-20 medium apps (1GB RAM each)
- 2-5 large apps (10GB+ RAM each)
- 1-2 LLMs (30GB+ RAM each)

### With 3 Nodes

If all nodes have similar specs (e.g., 16GB RAM, 4 cores each):
- **Total**: 48 GB RAM, 12 cores
- **Usable** (with overhead): ~40 GB RAM, 10 cores

**Workload Estimates:**
- 150-300 small apps
- 30-60 medium apps
- 6-15 large apps
- 3-6 LLMs

### Calculating Your Needs

```bash
# Check current usage
kubectl top nodes
kubectl top pods -A

# Sum up all pod memory requests
kubectl get pods -A -o json | \
  jq '[.items[].spec.containers[].resources.requests.memory // "0" | 
      gsub("Mi"; "") | tonumber] | add'

# Calculate headroom
# Recommended: Keep 30% free for bursts
```

### When to Add Nodes?

**Add a node when:**
- CPU utilization > 70% sustained
- Memory utilization > 80%
- Storage > 80% full
- Latency increases
- Planning new large workload
- Need better redundancy

## Performance Optimization

### Pod Affinity/Anti-Affinity

Distribute pods for better performance:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  template:
    spec:
      # Prefer spreading across nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - my-app
              topologyKey: kubernetes.io/hostname
```

### Node Affinity

Pin specific workloads to specific nodes:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-inference
spec:
  template:
    spec:
      # Only schedule on GPU nodes
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: mynodeone.io/gpu
                operator: In
                values:
                - "true"
```

### Taints and Tolerations

Reserve nodes for specific workloads:

```bash
# Taint node for GPU workloads only
kubectl taint nodes node-003 gpu=true:NoSchedule

# Pods with this toleration can schedule on tainted node
```

```yaml
spec:
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

## Database Scaling

### PostgreSQL with Replicas

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-primary
spec:
  ports:
  - port: 5432
  selector:
    app: postgres
    role: primary
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-replica
spec:
  ports:
  - port: 5432
  selector:
    app: postgres
    role: replica
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 3
  template:
    spec:
      containers:
      - name: postgres
        image: postgres:16
        # Configure streaming replication
```

Or use an operator:

```bash
# CloudNativePG operator
kubectl apply -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.20/releases/cnpg-1.20.0.yaml

# Create PostgreSQL cluster
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-cluster
spec:
  instances: 3
  storage:
    size: 100Gi
    storageClass: longhorn
EOF
```

## Cost Optimization

### Right-Sizing

```bash
# Install kube-resource-report
helm repo add deliveryhero https://charts.deliveryhero.io/
helm install kube-resource-report deliveryhero/kube-resource-report

# Access report
kubectl port-forward svc/kube-resource-report 8080:80
```

### Spot/Burst Instances

For cloud VPS, use spot instances for non-critical workloads:

```yaml
spec:
  tolerations:
  - key: "cloud.google.com/gke-preemptible"
    operator: "Exists"
```

### Resource Quotas

Prevent runaway costs:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: development
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    persistentvolumeclaims: "5"
    pods: "20"
```

## Disaster Recovery at Scale

### Multi-Node Backup Strategy

```bash
# Backup etcd from control plane
sudo k3s etcd-snapshot save --name daily-$(date +%Y%m%d)

# Backup Longhorn volumes (distributed)
# Via Longhorn UI → Recurring Backup
# Or via CronJob
```

### Regional Redundancy

When you have nodes in multiple locations:

```bash
# Label nodes by region
kubectl label node control-plane region=home
kubectl label node node-002 region=office

# Deploy apps across regions
```

```yaml
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values:
            - my-app
        topologyKey: region
```

## Scaling Checklist

### Before Adding a Node
- [ ] Verify current resource utilization
- [ ] Plan IP addressing
- [ ] Ensure Tailscale has capacity
- [ ] Check control plane can handle more workers
- [ ] Review storage requirements

### After Adding a Node
- [ ] Verify node is Ready: `kubectl get nodes`
- [ ] Apply appropriate labels
- [ ] Update Longhorn replica count
- [ ] Rebalance existing workloads
- [ ] Update monitoring dashboards
- [ ] Test failover scenarios
- [ ] Update documentation

### Regular Scaling Reviews
- [ ] Weekly: Check resource trends
- [ ] Monthly: Review capacity planning
- [ ] Quarterly: Optimize resource allocation
- [ ] Yearly: Hardware refresh planning

---

**Ready to scale?** Your MyNodeOne cluster grows with you! 🚀
