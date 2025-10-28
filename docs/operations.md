# MyNodeOne Operations Guide

## Day-to-Day Operations

### Checking Cluster Health

```bash
# Check all nodes
kubectl get nodes

# Check all pods across namespaces
kubectl get pods -A

# Check system components
kubectl get pods -n kube-system
kubectl get pods -n longhorn-system
kubectl get pods -n monitoring
kubectl get pods -n argocd

# Resource usage
kubectl top nodes
kubectl top pods -A
```

### Accessing Web UIs

All web UIs are accessible via Tailscale from your laptop:

```bash
# Get LoadBalancer IPs  
kubectl get svc -A | grep LoadBalancer

# Access via browser (replace with actual IPs)
# Grafana: http://<grafana-ip>
# ArgoCD: https://<argocd-ip>
# MinIO Console: http://<minio-console-ip>
# Longhorn: http://<control-plane-ip>:30080
```

### Viewing Logs

```bash
# View logs for a specific pod
kubectl logs <pod-name>

# Follow logs in real-time
kubectl logs -f <pod-name>

# View logs for all pods of a deployment
kubectl logs -f deployment/<deployment-name>

# View logs in a specific namespace
kubectl logs -f deployment/<deployment-name> -n <namespace>

# Previous container logs (if crashed)
kubectl logs <pod-name> --previous
```

### Deploying Applications

#### Method 1: Using create-app.sh (Recommended for new apps)

```bash
./scripts/create-app.sh my-app --domain myapp.com --port 3000 --storage 10Gi

cd my-app
# Customize your code
git remote add origin <repo-url>
git push -u origin main

# Deploy to cluster
kubectl apply -f k8s/argocd-application.yaml
```

#### Method 2: Direct kubectl apply

```bash
kubectl apply -f your-manifest.yaml
```

#### Method 3: Using Helm

```bash
helm install my-release chart-name
```

### Updating Applications

#### GitOps Way (Recommended)
1. Make changes to your code
2. Push to GitHub
3. GitHub Actions builds new image
4. Updates manifest
5. ArgoCD auto-syncs (or manual sync via UI)

#### Manual Way
```bash
# Edit deployment
kubectl edit deployment <deployment-name>

# Or apply updated manifest
kubectl apply -f updated-manifest.yaml

# Restart deployment (force new rollout)
kubectl rollout restart deployment/<deployment-name>
```

### Rolling Back Deployments

```bash
# View rollout history
kubectl rollout history deployment/<deployment-name>

# Rollback to previous version
kubectl rollout undo deployment/<deployment-name>

# Rollback to specific revision
kubectl rollout undo deployment/<deployment-name> --to-revision=2
```

### Scaling Applications

```bash
# Scale deployment
kubectl scale deployment/<deployment-name> --replicas=5

# Autoscale based on CPU
kubectl autoscale deployment/<deployment-name> --min=2 --max=10 --cpu-percent=80
```

## Storage Operations

### MinIO (Object Storage)

#### Install MinIO Client

```bash
# On your laptop
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Configure
MINIO_ENDPOINT=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
mc alias set mynodeone http://$MINIO_ENDPOINT:9000 <access-key> <secret-key>
# Get credentials from /root/mynodeone-minio-credentials.txt on control plane
```

#### Common MinIO Operations

```bash
# List buckets
mc ls mynodeone

# Create bucket
mc mb mynodeone/my-bucket

# Upload file
mc cp myfile.txt mynodeone/my-bucket/

# Download file
mc cp mynodeone/my-bucket/myfile.txt ./

# Sync directory
mc mirror ./local-dir mynodeone/my-bucket/

# Set bucket policy (public read)
mc anonymous set download mynodeone/my-bucket

# Get bucket size
mc du mynodeone/my-bucket
```

### Longhorn (Block Storage)

#### Access Longhorn UI

```bash
# Get control plane node IP
CONTROL_PLANE_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Longhorn UI: http://$CONTROL_PLANE_IP:30080"
```

#### Common Longhorn Operations

```bash
# List persistent volumes
kubectl get pv

# List persistent volume claims
kubectl get pvc -A

# Check volume health
kubectl get volumes -n longhorn-system

# Create snapshot (via UI or kubectl)
# Access Longhorn UI → Select Volume → Take Snapshot

# Restore from snapshot
# Longhorn UI → Snapshots → Create Volume from Snapshot
```

#### Expanding Storage

```bash
# Expand PVC (if storage class allows)
kubectl patch pvc <pvc-name> -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'

# Add new disk to Longhorn
# 1. Mount disk on node (e.g., /mnt/longhorn2)
# 2. Longhorn UI → Node → Add Disk
# 3. Specify path and size
```

## Monitoring & Alerting

### Grafana Dashboards

```bash
# Get Grafana URL
GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Grafana: http://$GRAFANA_IP"
# Default credentials: admin/admin (change after first login!)
```

#### Key Dashboards
- **Kubernetes / Compute Resources / Cluster**: Overall cluster health
- **Kubernetes / Compute Resources / Node**: Per-node metrics
- **Kubernetes / Compute Resources / Pod**: Per-pod metrics
- **Longhorn**: Storage metrics
- **Node Exporter Full**: Detailed node metrics

### Prometheus Queries

```bash
# Access Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Visit http://localhost:9090
```

#### Useful PromQL Queries

```promql
# CPU usage by node
100 - (avg by (instance) (irate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Memory usage by node
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100

# Disk usage by node
(node_filesystem_size_bytes - node_filesystem_avail_bytes) / node_filesystem_size_bytes * 100

# Pod restart count
kube_pod_container_status_restarts_total

# Top 10 CPU consuming pods
topk(10, sum by (pod) (rate(container_cpu_usage_seconds_total[5m])))

# Top 10 memory consuming pods
topk(10, sum by (pod) (container_memory_working_set_bytes))
```

### Viewing Logs with Loki

```bash
# Access Loki via Grafana
# Grafana → Explore → Select Loki as datasource
```

#### LogQL Examples

```logql
# All logs from namespace
{namespace="default"}

# Logs from specific app
{app="my-app"}

# Error logs only
{namespace="default"} |= "error"

# Logs matching regex
{app="my-app"} |~ "error|ERROR|Error"

# Count errors per minute
rate({namespace="default"} |= "error" [1m])
```

## Maintenance Tasks

### Updating K3s

```bash
# On control plane
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.28.6+k3s1" sh -s - server

# On worker nodes
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.28.6+k3s1" sh -
```

### Updating Helm Charts

```bash
# Update helm repos
helm repo update

# Check for updates
helm list -A

# Upgrade a release
helm upgrade <release-name> <chart-name> -n <namespace>

# Example: Upgrade Longhorn
helm upgrade longhorn longhorn/longhorn -n longhorn-system
```

### Cleaning Up Resources

```bash
# Remove unused images
kubectl -n kube-system exec -it <containerd-pod> -- crictl rmi --prune

# Remove completed pods
kubectl delete pods --field-selector=status.phase==Succeeded -A
kubectl delete pods --field-selector=status.phase==Failed -A

# Check for unused PVCs
kubectl get pvc -A

# Remove evicted pods
kubectl get pods -A | grep Evicted | awk '{print $2 " -n " $1}' | xargs -L1 kubectl delete pod
```

### Backing Up Critical Data

#### Backup etcd (Kubernetes state)

```bash
# K3s automatically backs up etcd to /var/lib/rancher/k3s/server/db/snapshots/
# Manual snapshot
sudo k3s etcd-snapshot save --name manual-backup

# List snapshots
sudo k3s etcd-snapshot ls

# Restore from snapshot (CAREFUL!)
sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-name>
```

#### Backup Longhorn Volumes

```bash
# Via Longhorn UI
# 1. Select Volume
# 2. Create Snapshot
# 3. Backup Snapshot to S3

# Or automated via CronJob (example)
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: volume-backup
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: longhornio/longhorn-engine:v1.5.3
            command: ["/bin/sh", "-c"]
            args:
            - |
              # Backup logic here
          restartPolicy: OnFailure
EOF
```

#### Backup MinIO Data

```bash
# Using mc mirror
mc mirror mynodeone s3-backup-location

# Or setup MinIO replication
mc replicate add mynodeone/my-bucket --remote-bucket backup-bucket --priority 1
```

### Certificate Management

```bash
# Check certificates
kubectl get certificates -A

# Check certificate requests
kubectl get certificaterequests -A

# Manual certificate creation (if auto fails)
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com
  namespace: default
spec:
  secretName: example-com-tls
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
  dnsNames:
  - example.com
  - www.example.com
EOF
```

## Troubleshooting Commands

### Node Issues

```bash
# Describe node
kubectl describe node <node-name>

# Check node conditions
kubectl get nodes -o json | jq '.items[].status.conditions'

# SSH to node (via Tailscale)
ssh <node-tailscale-ip>

# Check K3s service
sudo systemctl status k3s       # Control plane
sudo systemctl status k3s-agent  # Worker

# View K3s logs
sudo journalctl -u k3s -f       # Control plane
sudo journalctl -u k3s-agent -f  # Worker
```

### Pod Issues

```bash
# Describe pod
kubectl describe pod <pod-name>

# Get pod events
kubectl get events --sort-by='.lastTimestamp' | grep <pod-name>

# Check pod logs
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>  # If multiple containers

# Execute command in pod
kubectl exec -it <pod-name> -- /bin/bash
kubectl exec -it <pod-name> -c <container-name> -- /bin/sh

# Check resource usage
kubectl top pod <pod-name>
```

### Network Issues

```bash
# Check services
kubectl get svc -A

# Check endpoints
kubectl get endpoints

# Test DNS
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Test connectivity
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- bash
# Inside pod:
# ping <service-name>
# curl <service-name>
```

### Storage Issues

```bash
# Check PV/PVC
kubectl get pv,pvc -A

# Check storage class
kubectl get storageclass

# Check Longhorn volumes
kubectl get volumes -n longhorn-system

# Check volume attachments
kubectl get volumeattachments
```

## Performance Tuning

### Kubernetes

```bash
# Increase max pods per node (if needed)
# Edit /etc/rancher/k3s/config.yaml
kubelet-arg:
  - "max-pods=500"

# Restart K3s
sudo systemctl restart k3s
```

### Longhorn

```bash
# Adjust replica count
kubectl -n longhorn-system edit settings.longhorn.io default-replica-count

# Adjust concurrent volume backups
kubectl -n longhorn-system edit settings.longhorn.io concurrent-automatic-engine-upgrade-per-node-limit
```

### MinIO

```bash
# Increase MinIO resources
helm upgrade minio minio/minio -n minio \
  --set resources.requests.memory=8Gi \
  --set resources.requests.cpu=2
```

## Security Best Practices

### Regular Updates

```bash
# Update apt packages
sudo apt update && sudo apt upgrade -y

# Update K3s (quarterly)
# Check release notes first!

# Update Helm charts (monthly)
helm repo update
```

### Access Control

```bash
# Create read-only user
kubectl create serviceaccount readonly-user
kubectl create clusterrolebinding readonly-user --clusterrole=view --serviceaccount=default:readonly-user

# Get token
kubectl create token readonly-user
```

### Secrets Management

```bash
# Create secret
kubectl create secret generic my-secret --from-literal=password=mypassword

# Use secret in pod
# See manifests/examples/secret-usage.yaml

# Rotate secrets regularly
kubectl delete secret my-secret
kubectl create secret generic my-secret --from-literal=password=newpassword
kubectl rollout restart deployment/<deployment-name>
```

## Disaster Recovery

### Scenario: Node Failure

1. **Immediate Actions**
   - Check if node is really down: `kubectl get nodes`
   - Check pod status: `kubectl get pods -A -o wide`
   - Pods on failed node will be rescheduled automatically after 5 minutes

2. **Recovery**
   - If node comes back online, pods return to normal
   - If node is permanently gone:
     ```bash
     kubectl delete node <node-name>
     kubectl get pods -A  # Check all pods are running
     ```

### Scenario: Complete Cluster Failure

1. **Restore etcd from backup**
   ```bash
   sudo k3s server --cluster-reset --cluster-reset-restore-path=/path/to/snapshot
   ```

2. **Restore Longhorn volumes**
   - Access Longhorn UI
   - Restore volumes from backups

3. **Redeploy applications**
   - ArgoCD will auto-sync if working
   - Or manually: `kubectl apply -f manifests/`

### Scenario: Data Corruption

1. **Restore from Longhorn snapshot**
   - Longhorn UI → Volumes → Select Volume → Snapshots → Revert

2. **Restore from MinIO backup**
   ```bash
   mc mirror s3-backup-location mynodeone
   ```

## Regular Maintenance Schedule

### Daily
- Check cluster health
- Review monitoring dashboards
- Check for failed pods

### Weekly
- Review resource usage trends
- Check for available updates
- Review logs for errors
- Test backups

### Monthly
- Update Helm charts
- Review and cleanup unused resources
- Test disaster recovery procedures
- Update documentation

### Quarterly
- Update K3s
- Review and optimize resource allocations
- Security audit
- Capacity planning

---

**Need Help?** Check the troubleshooting guide or open an issue on GitHub!
