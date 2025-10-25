# MyNodeOne Troubleshooting Guide

## Quick Diagnostics

### Health Check Script

```bash
#!/bin/bash
# Save as check-health.sh

echo "=== MyNodeOne Health Check ==="
echo

echo "1. Nodes Status:"
kubectl get nodes
echo

echo "2. System Pods:"
kubectl get pods -n kube-system | grep -v Running
echo

echo "3. Failed Pods:"
kubectl get pods -A | grep -v Running | grep -v Completed
echo

echo "4. Resource Usage:"
kubectl top nodes
echo

echo "5. Storage Status:"
kubectl get pv | grep -v Bound
kubectl get pvc -A | grep -v Bound
echo

echo "6. Certificate Status:"
kubectl get certificates -A | grep -v True
echo

echo "=== Health Check Complete ==="
```

## Common Issues & Solutions

### 1. Pod Stuck in Pending

**Symptom**: `kubectl get pods` shows pods in `Pending` state

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
```

**Common Causes & Solutions**:

#### Insufficient Resources
```
Events:
  Warning  FailedScheduling  pod didn't trigger scale-up: insufficient cpu/memory
```

**Solution**: Scale down other apps or add more nodes
```bash
# Reduce replicas
kubectl scale deployment/<deployment-name> --replicas=1

# Or increase node resources
# Or add toronto-0002 node
```

#### No Node Available
```
Events:
  Warning  FailedScheduling  0/1 nodes available: node didn't match node selector
```

**Solution**: Check node labels and selectors
```bash
kubectl get nodes --show-labels
kubectl edit deployment/<deployment-name>  # Remove or fix nodeSelector
```

#### PVC Not Bound
```
Events:
  Warning  FailedScheduling  persistentvolumeclaim "my-pvc" not found
```

**Solution**: Check PVC status
```bash
kubectl get pvc
kubectl describe pvc <pvc-name>

# If Longhorn issue, check:
kubectl get pods -n longhorn-system
```

### 2. Pod Stuck in ImagePullBackOff

**Symptom**: `kubectl get pods` shows `ImagePullBackOff` or `ErrImagePull`

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
```

**Common Causes & Solutions**:

#### Image Doesn't Exist
```
Failed to pull image "myrepo/myapp:latest": not found
```

**Solution**: Check image name and tag
```bash
# List available tags in your registry
# Fix image reference in deployment
kubectl edit deployment/<deployment-name>
```

#### Private Registry Authentication
```
Failed to pull image: unauthorized
```

**Solution**: Create image pull secret
```bash
kubectl create secret docker-registry regcred \
  --docker-server=ghcr.io \
  --docker-username=<username> \
  --docker-password=<token>

# Add to deployment
kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```

### 3. Pod CrashLoopBackOff

**Symptom**: Pod keeps restarting

**Diagnosis**:
```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
kubectl logs <pod-name> --previous  # Logs from crashed container
```

**Common Causes & Solutions**:

#### Application Error
```
Error: Cannot find module 'express'
```

**Solution**: Fix application code, rebuild image

#### Missing Environment Variables
```
Error: DATABASE_URL is not defined
```

**Solution**: Add missing env vars
```bash
kubectl create secret generic app-config \
  --from-literal=DATABASE_URL=postgres://...

kubectl edit deployment/<deployment-name>
# Add env from secret
```

#### Insufficient Resources
```
OOMKilled (exit code 137)
```

**Solution**: Increase memory limits
```bash
kubectl edit deployment/<deployment-name>
# Increase resources.limits.memory
```

#### Liveness Probe Failing
```
Liveness probe failed: Get http://10.42.0.5:3000/health: dial tcp 10.42.0.5:3000: connect: connection refused
```

**Solution**: Fix health check endpoint or adjust probe timing
```bash
kubectl edit deployment/<deployment-name>
# Increase initialDelaySeconds, adjust path
```

### 4. Service Not Accessible

**Symptom**: Cannot access service via domain or IP

**Diagnosis**:
```bash
# Check service
kubectl get svc <service-name>
kubectl describe svc <service-name>

# Check endpoints
kubectl get endpoints <service-name>

# Check ingress
kubectl get ingress
kubectl describe ingress <ingress-name>
```

**Common Causes & Solutions**:

#### No Endpoints
```
Endpoints: <none>
```

**Solution**: Check pod selector matches
```bash
kubectl get pods --show-labels
kubectl get svc <service-name> -o yaml | grep selector

# Fix selector in service
kubectl edit svc <service-name>
```

#### LoadBalancer Pending
```
EXTERNAL-IP: <pending>
```

**Solution**: Check MetalLB
```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system deployment/metallb-controller

# Check IP pool
kubectl get ipaddresspool -n metallb-system
```

#### Ingress Not Working
```
Cannot reach http://myapp.com
```

**Solution**: Check Traefik and DNS
```bash
# Check Traefik ingress controller
kubectl get pods -n traefik
kubectl logs -n traefik deployment/traefik

# Check certificate
kubectl get certificate
kubectl describe certificate <cert-name>

# Verify DNS
dig myapp.com
# Should point to VPS IP: 45.8.133.192 or 31.220.87.37
```

### 5. Storage Issues

**Symptom**: PVC stuck in `Pending`, volumes not attaching

**Diagnosis**:
```bash
kubectl get pv,pvc -A
kubectl describe pvc <pvc-name>
kubectl get pods -n longhorn-system
```

**Common Causes & Solutions**:

#### Longhorn Manager Down
```bash
kubectl get pods -n longhorn-system | grep manager
```

**Solution**: Restart Longhorn
```bash
kubectl rollout restart deployment/longhorn-driver-deployer -n longhorn-system
kubectl rollout restart daemonset/longhorn-manager -n longhorn-system
```

#### Insufficient Disk Space
```
Events:
  Warning  ProvisioningFailed  failed to provision volume: not enough disk space
```

**Solution**: 
```bash
# Check disk space
df -h

# Clean up unused images
crictl rmi --prune

# Or add more disks to Longhorn
# Longhorn UI → Node → Add Disk
```

#### Volume Attach Failure
```
AttachVolume.Attach failed: Volume is already attached to another node
```

**Solution**: Force detach
```bash
# Via Longhorn UI: Select Volume → Detach

# Or delete pod using the volume
kubectl delete pod <pod-name>
```

### 6. Monitoring Not Working

**Symptom**: Grafana not showing data, Prometheus not scraping

**Diagnosis**:
```bash
kubectl get pods -n monitoring
kubectl logs -n monitoring deployment/kube-prometheus-stack-operator
```

**Common Causes & Solutions**:

#### Prometheus Not Scraping
```bash
# Check ServiceMonitor
kubectl get servicemonitor -A

# Check Prometheus targets (port-forward first)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Visit http://localhost:9090/targets
```

**Solution**: Verify service has correct labels
```bash
kubectl get svc <service-name> -o yaml
# Should have labels matching ServiceMonitor selector
```

#### Grafana Can't Connect to Prometheus
```bash
kubectl logs -n monitoring deployment/kube-prometheus-stack-grafana
```

**Solution**: Check datasource configuration
```bash
# Access Grafana UI → Configuration → Data Sources
# Verify Prometheus URL is correct
```

### 7. ArgoCD Sync Issues

**Symptom**: ArgoCD shows "OutOfSync" but won't sync

**Diagnosis**:
```bash
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd
```

**Common Causes & Solutions**:

#### Git Repository Unreachable
```
Unable to connect to repository: authentication required
```

**Solution**: Add repository credentials
```bash
# Via ArgoCD UI: Settings → Repositories → Connect Repo
# Or CLI:
argocd repo add https://github.com/username/repo --username <user> --password <token>
```

#### Manifest Error
```
Failed to sync: deployment.apps "myapp" is invalid
```

**Solution**: Fix YAML syntax
```bash
# Validate manifest locally
kubectl apply --dry-run=client -f manifest.yaml

# Fix errors and push to git
```

#### Auto-Sync Disabled
**Solution**: Enable auto-sync
```bash
argocd app set <app-name> --sync-policy automated --auto-prune --self-heal
```

### 8. SSL Certificate Issues

**Symptom**: HTTPS not working, certificate errors

**Diagnosis**:
```bash
kubectl get certificate -A
kubectl describe certificate <cert-name>
kubectl get certificaterequest -A
```

**Common Causes & Solutions**:

#### Let's Encrypt Rate Limit
```
Error: too many certificates already issued
```

**Solution**: Wait 1 week or use staging issuer
```bash
# Use staging for testing
kubectl edit clusterissuer letsencrypt
# Change server to: https://acme-staging-v02.api.letsencrypt.org/directory
```

#### DNS Not Propagated
```
Error: CAA record does not match
```

**Solution**: Wait for DNS propagation (up to 48 hours)
```bash
# Check DNS
dig myapp.com
nslookup myapp.com
```

#### HTTP Challenge Failed
```
Error: cannot reach .well-known/acme-challenge
```

**Solution**: Check Traefik routing
```bash
# Ensure HTTP (port 80) is accessible
curl http://myapp.com/.well-known/acme-challenge/test

# Check firewall on VPS
sudo ufw status
```

### 9. Node Connectivity Issues

**Symptom**: Node shows `NotReady`, pods not scheduling

**Diagnosis**:
```bash
kubectl get nodes
kubectl describe node <node-name>
```

**Common Causes & Solutions**:

#### Tailscale Disconnected
```
NodeStatusUnknown: Cannot reach node
```

**Solution**: Check Tailscale
```bash
# On affected node
sudo tailscale status
sudo tailscale up

# Check connectivity
ping <control-plane-tailscale-ip>
```

#### K3s Service Down
```bash
# On affected node
sudo systemctl status k3s
sudo systemctl status k3s-agent

# Check logs
sudo journalctl -u k3s-agent -n 100
```

**Solution**: Restart K3s
```bash
sudo systemctl restart k3s-agent
```

#### Disk Pressure
```
Conditions:
  DiskPressure  True  NodeHasDiskPressure
```

**Solution**: Free up disk space
```bash
# Clean up
docker system prune -a
sudo journalctl --vacuum-time=7d

# Check disk usage
df -h
du -sh /var/lib/rancher/k3s/*
```

### 10. VPS Edge Node Issues

**Symptom**: Cannot reach apps from internet

**Diagnosis**:
```bash
# On VPS
docker logs traefik

# Check Traefik config
cat /etc/traefik/dynamic/mynodeone-routes.yml

# Test Tailscale connectivity to Toronto
ping <toronto-tailscale-ip>
```

**Common Causes & Solutions**:

#### Firewall Blocking
```bash
sudo ufw status
# Ensure 80, 443 are allowed
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

#### Traefik Not Running
```bash
cd /etc/traefik
docker compose ps

# Restart Traefik
docker compose restart
```

#### Wrong Backend IP
```bash
# Check control plane IP
cat /etc/traefik/control-plane-ip

# Update if wrong
echo "<correct-tailscale-ip>" > /etc/traefik/control-plane-ip

# Update routes
vi /etc/traefik/dynamic/mynodeone-routes.yml
# Change server URL to correct IP

docker compose restart
```

## Performance Issues

### High CPU Usage

**Diagnosis**:
```bash
kubectl top nodes
kubectl top pods -A --sort-by=cpu
```

**Solutions**:
1. Identify resource-hungry pods
2. Set CPU limits
3. Scale horizontally (add replicas or nodes)
4. Optimize application code

### High Memory Usage

**Diagnosis**:
```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory
```

**Solutions**:
1. Check for memory leaks
2. Set memory limits
3. Add more nodes
4. Use memory-efficient data structures

### Slow Storage

**Diagnosis**:
```bash
# Check Longhorn volumes
kubectl get volumes -n longhorn-system

# Check disk I/O on nodes
sudo iotop
```

**Solutions**:
1. Use SSDs for Longhorn (NVMe preferred)
2. Reduce replica count (if acceptable)
3. Check disk health: `sudo smartctl -a /dev/sdX`

## Emergency Procedures

### Cluster Completely Down

```bash
# 1. Check control plane node
ssh <toronto-0001-tailscale-ip>
sudo systemctl status k3s

# 2. Restart K3s
sudo systemctl restart k3s

# 3. Wait for cluster to come up
kubectl get nodes
kubectl get pods -A

# 4. If etcd corrupted, restore from backup
sudo k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<latest-snapshot>
```

### Storage Completely Down

```bash
# 1. Check Longhorn pods
kubectl get pods -n longhorn-system

# 2. Restart Longhorn
kubectl rollout restart daemonset/longhorn-manager -n longhorn-system

# 3. If persistent issue, reinstall Longhorn
helm uninstall longhorn -n longhorn-system
# Wait for cleanup
helm install longhorn longhorn/longhorn -n longhorn-system
```

### Data Corruption

```bash
# 1. Identify affected volumes
kubectl get pv

# 2. Restore from Longhorn snapshot
# Longhorn UI → Volume → Snapshots → Revert

# 3. Restart pods using the volume
kubectl rollout restart deployment/<deployment-name>
```

## Getting Help

### Collect Debug Information

```bash
#!/bin/bash
# Save as collect-debug-info.sh

OUTPUT_DIR="mynodeone-debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

echo "Collecting debug information..."

kubectl get nodes -o wide > "$OUTPUT_DIR/nodes.txt"
kubectl get pods -A -o wide > "$OUTPUT_DIR/pods.txt"
kubectl get svc -A > "$OUTPUT_DIR/services.txt"
kubectl get pv,pvc -A > "$OUTPUT_DIR/storage.txt"
kubectl top nodes > "$OUTPUT_DIR/top-nodes.txt"
kubectl top pods -A > "$OUTPUT_DIR/top-pods.txt"

kubectl get events -A --sort-by='.lastTimestamp' > "$OUTPUT_DIR/events.txt"

kubectl logs -n kube-system -l k3s-app=metrics-server --tail=100 > "$OUTPUT_DIR/metrics-server.log"
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100 > "$OUTPUT_DIR/longhorn.log"
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=100 > "$OUTPUT_DIR/traefik.log"

tar czf "$OUTPUT_DIR.tar.gz" "$OUTPUT_DIR"
echo "Debug info saved to $OUTPUT_DIR.tar.gz"
```

### Community Support

- GitHub Issues: https://github.com/yourusername/mynodeone/issues
- Kubernetes Slack: https://kubernetes.slack.com
- K3s GitHub: https://github.com/k3s-io/k3s/issues
- Longhorn Slack: https://slack.rancher.io

### Useful Resources

- K3s Documentation: https://docs.k3s.io
- Kubernetes Troubleshooting: https://kubernetes.io/docs/tasks/debug/
- Longhorn Troubleshooting: https://longhorn.io/docs/latest/troubleshooting/
- Traefik Documentation: https://doc.traefik.io/traefik/

---

**Still stuck?** Open an issue with the debug info bundle attached!
