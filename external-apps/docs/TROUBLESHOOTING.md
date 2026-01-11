# Troubleshooting External Apps

Common issues and solutions when deploying apps on MyNodeOne.

---

## Deployment Issues

### ImagePullBackOff

**Symptom**: Pod shows `ImagePullBackOff` status

```bash
kubectl get pods -n myapp
# NAME                    READY   STATUS             RESTARTS
# myapp-web-xxx           0/1     ImagePullBackOff   0
```

**Causes**:
1. Docker image doesn't exist
2. Wrong image name/tag
3. Private registry needs credentials

**Solutions**:

```bash
# Check exact error
kubectl describe pod -n myapp <pod-name>

# For private registries, create secret:
kubectl create secret docker-registry regcred \
  --docker-server=<registry-url> \
  --docker-username=<username> \
  --docker-password=<password> \
  -n myapp

# Update deployment to use secret
kubectl patch serviceaccount default -n myapp \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```

### CrashLoopBackOff

**Symptom**: Pod keeps restarting

**Check logs**:
```bash
kubectl logs -n myapp <pod-name>
kubectl logs -n myapp <pod-name> --previous  # Previous crash
```

**Common causes**:
- Missing environment variables
- Wrong port configuration
- Database connection failed
- Application error on startup

**Fix**: Check logs for specific error and update deployment.

### Pending Pods

**Symptom**: Pods stuck in `Pending` state

**Causes**:
- Not enough resources (CPU/RAM)
- PVC can't be bound
- Node selector issues

**Check**:
```bash
kubectl describe pod -n myapp <pod-name>
# Look for "Events" section
```

**Solutions**:
```bash
# Check available resources
kubectl top nodes

# Check PVC
kubectl get pvc -n myapp

# Reduce resource requests
kubectl edit deployment -n myapp <deployment-name>
```

---

## Access Issues

### Can't Access via Local Domain

**Symptom**: `http://myapp.mynodeone.local` doesn't work

**Check DNS registration**:
```bash
# Check service registry
kubectl get configmap -n kube-system service-registry -o yaml

# Check /etc/hosts
cat /etc/hosts | grep mynodeone.local
```

**Fix**:
```bash
# Re-sync DNS
sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh

# Check from control plane
ping myapp.mynodeone.local

# From other nodes
sudo bash /path/to/MyNodeOne/scripts/sync-controller.sh
```

### LoadBalancer IP Pending

**Symptom**: Service shows `<pending>` for EXTERNAL-IP

```bash
kubectl get svc -n myapp
# NAME    TYPE           EXTERNAL-IP   PORT(S)
# myapp   LoadBalancer   <pending>     80:30123/TCP
```

**Causes**:
- MetalLB not configured
- IP pool exhausted

**Check**:
```bash
# Check MetalLB
kubectl get pods -n metallb-system

# Check IP pool
kubectl get ipaddresspool -n metallb-system
```

**Fix**:
```bash
# Expand IP pool if needed
kubectl edit ipaddresspool -n metallb-system
```

### Public Domain Not Working

**Symptom**: Can access locally but not via public domain

**Checklist**:
1. DNS A record added at registrar?
   ```bash
   dig app.yourdomain.com
   # Should return VPS IP
   ```

2. VPS routing configured?
   ```bash
   sudo bash /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
   ```

3. SSL certificate obtained?
   ```bash
   kubectl get certificate -A
   ```

4. Firewall allows traffic?
   ```bash
   # On VPS
   sudo ufw status
   # Should allow 80 and 443
   ```

---

## Performance Issues

### App Running Slow

**Check resource usage**:
```bash
# Pod resource usage
kubectl top pods -n myapp

# Node resource usage
kubectl top nodes
```

**Solutions**:
```bash
# Increase resources
kubectl edit deployment -n myapp <deployment-name>
# Update resources.requests and resources.limits

# Scale horizontally
kubectl scale deployment -n myapp <deployment-name> --replicas=3
```

### Database Connection Timeouts

**Check database pod**:
```bash
kubectl get pods -n myapp
kubectl logs -n myapp <db-pod-name>
```

**Check connection string**:
```bash
kubectl exec -it -n myapp <app-pod> -- env | grep DATABASE
```

**Common issues**:
- Wrong hostname (use service name, e.g., `postgres` not `localhost`)
- Wrong namespace (use `postgres.myapp.svc.cluster.local`)
- Database not ready (add readiness probe)

---

## Storage Issues

### PVC Not Binding

**Symptom**: PVC shows `Pending`

```bash
kubectl get pvc -n myapp
# NAME         STATUS    VOLUME
# myapp-data   Pending
```

**Check**:
```bash
kubectl describe pvc -n myapp myapp-data
```

**Causes**:
- Longhorn not running
- No available storage

**Fix**:
```bash
# Check Longhorn
kubectl get pods -n longhorn-system

# Check storage capacity
kubectl get nodes -o custom-columns=NAME:.metadata.name,CAPACITY:.status.capacity.storage
```

### Data Persists After Redeploy

**Expected**: When you delete and redeploy, data should persist (via PVC)

**If data is lost**:
- PVC was deleted
- Volume mount path wrong
- Using wrong PVC

**Check**:
```bash
kubectl get pvc -n myapp
# Should exist even after pod deletion

kubectl describe deployment -n myapp <name>
# Check volumeMounts and volumes sections
```

---

## Networking Issues

### Services Can't Talk to Each Other

**Symptom**: Frontend can't reach backend

**Check service discovery**:
```bash
# From inside a pod
kubectl exec -it -n myapp <frontend-pod> -- nslookup backend

# Should resolve to ClusterIP
```

**Common issues**:
- Wrong service name in environment variable
- Wrong port
- Wrong namespace

**Use FQDN**:
```
http://backend.myapp.svc.cluster.local:8000
```

Or if in same namespace:
```
http://backend:8000
```

### External API Calls Failing

**Check outbound connectivity**:
```bash
kubectl exec -it -n myapp <pod> -- curl -I https://api.example.com
```

**If fails**:
- Check network policies
- Check firewall rules
- Check DNS resolution

---

## Update/Rollback Issues

### Update Failed

**Rollback to previous version**:
```bash
kubectl rollout undo deployment -n myapp <deployment-name>
```

**Check rollout status**:
```bash
kubectl rollout status deployment -n myapp <deployment-name>
```

### Can't Update Image

**Force update even with same tag**:
```bash
kubectl rollout restart deployment -n myapp <deployment-name>
```

---

## Debugging Commands

### Check Everything
```bash
# All resources in namespace
kubectl get all -n myapp

# Describe everything (find errors)
kubectl describe all -n myapp

# Events (recent issues)
kubectl get events -n myapp --sort-by='.lastTimestamp'
```

### Interactive Debugging
```bash
# Shell into pod
kubectl exec -it -n myapp <pod-name> -- /bin/sh

# Run commands
wget http://backend:8000
env | grep -i db
ps aux
```

### Log Aggregation
```bash
# All pods logs
kubectl logs -n myapp -l app=myapp --all-containers=true

# Follow logs
kubectl logs -n myapp -l app=myapp -f

# Last 100 lines
kubectl logs -n myapp <pod-name> --tail=100
```

---

## Common Error Messages

### "insufficient memory"
Reduce memory request in deployment or add more nodes.

### "Back-off pulling image"
Image not found or registry authentication failed.

### "context deadline exceeded"
Usually network timeout - check network connectivity.

### "connection refused"
Service not listening on expected port, or port mismatch.

### "no space left on device"
Node disk full - clean up or add storage.

---

## Getting Help

1. **Check logs first**: `kubectl logs -n myapp -l app=myapp -f`
2. **Check pod status**: `kubectl get pods -n myapp`
3. **Check events**: `kubectl get events -n myapp`
4. **Search this doc**: Most issues covered here
5. **GitHub Issues**: For MyNodeOne-specific issues
6. **Kubernetes docs**: For general K8s issues

---

## Quick Fixes

### Restart Everything
```bash
kubectl rollout restart deployment -n myapp --all
```

### Re-sync DNS
```bash
sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh
```

### Force Redeploy
```bash
kubectl delete pods -n myapp --all
# Pods will auto-recreate
```

### Check Cluster Health
```bash
bash /path/to/MyNodeOne/scripts/operations/cluster-status.sh
```
