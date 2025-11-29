# Cluster Management

This guide covers day-to-day cluster management tasks.

---

## Checking Cluster Health

```bash
# Node status
kubectl get nodes

# Pod status (all namespaces)
kubectl get pods -A

# Services and their IPs
kubectl get svc -A

# Storage volumes
kubectl get pv,pvc -A

# Resource usage
kubectl top nodes
kubectl top pods -A
```

---

## Adding Worker Nodes

```bash
# On control plane, get join command
cat /root/mynodeone-join-token.txt

# On new machine, run join command shown
sudo k3s agent --server https://... --token ...
```

Or use the helper script:
```bash
sudo ./scripts/add-worker-node.sh
```

For detailed instructions, see [Worker Node Installation](../installation/INSTALLATION.md#section-4-worker-node-installation).

---

## Managing Passwords

### Grafana
1. Login to Grafana
2. Click profile icon → Preferences
3. Change Password tab

### MinIO
1. Login to MinIO console
2. Identity → Users
3. Create new user with admin policy
4. Delete old admin user

### ArgoCD
```bash
argocd account update-password
```

---

## Backup and Recovery

### Kubernetes Manifests
```bash
# Save all your deployments
kubectl get all -A -o yaml > my-cluster-backup.yaml
```

### Longhorn Snapshots
1. Open Longhorn UI
2. Select volume
3. Click "Take Snapshot"
4. Schedule recurring snapshots

### MinIO Buckets
```bash
mc mirror myminio/my-bucket /backups/my-bucket
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -A

# Describe pod (shows events/errors)
kubectl describe pod <pod-name> -n <namespace>

# View logs
kubectl logs <pod-name> -n <namespace>
```

**Common issues:**
- **Image pull errors** - Check internet connection
- **CrashLoopBackOff** - Check logs for application errors
- **Pending status** - Check if nodes have resources

### Can't Access Services

**Most common issue: Tailscale not accepting routes**

```bash
# Check if routes are being accepted
tailscale status --self

# If you see "accept-routes is false" warning:
sudo tailscale up --accept-routes
```

**Checklist:**
- Is Tailscale running? `tailscale status`
- Is laptop accepting routes? Should NOT show "accept-routes is false"
- Was the subnet route approved in Tailscale admin console?
- Is the service showing an EXTERNAL-IP? `kubectl get svc -A`

### Cluster Slow or Unresponsive

```bash
# Check node resources
kubectl top nodes

# Check which pods are using resources
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu

# Check storage
kubectl get pv,pvc -A
```

**Common causes:**
- Out of disk space - Check Longhorn UI
- Out of memory - Scale down or add nodes
- Too many pods - Review what's running

---

## Viewing Logs

### From Command Line
```bash
# View pod logs
kubectl logs -n <namespace> <pod-name>

# Follow logs in real-time
kubectl logs -f -n <namespace> <pod-name>

# All pods with a label
kubectl logs -n <namespace> -l app=my-app
```

### From Grafana (Loki)
1. Click "Explore" (compass icon) on left sidebar
2. Select "Loki" from dropdown at top
3. Query examples:
   ```
   {namespace="demo-apps"}
   {app="my-app"}
   {namespace="demo-apps"} |= "error"
   ```

---

## Reboot Behavior

### Auto-Start Services

After reboot, these services start automatically:

| Service | Auto-Start | Notes |
|---------|-----------|-------|
| K3s | Yes | Kubernetes cluster |
| Tailscale | Yes | VPN networking |
| MetalLB | Yes | LoadBalancer (runs in K3s) |
| Longhorn | Yes | Storage (runs in K3s) |

### External USB Drives

If using external USB drives for storage, run this fix once to ensure proper boot order:

```bash
sudo ./scripts/fix-usb-disk-boot.sh
```

This ensures K3s waits for USB drives to be detected and mounted before starting.

### After Reboot Verification

```bash
# Check K3s is running
sudo systemctl status k3s

# Check disks are mounted
df -h | grep longhorn

# Check cluster is healthy
kubectl get nodes
kubectl get pods -A
```

---

## Getting Help

- **FAQ:** [FAQ.md](../reference/FAQ.md)
- **Troubleshooting:** [troubleshooting.md](troubleshooting.md)
- **Scaling:** [scaling.md](scaling.md)
- **GitHub Issues:** https://github.com/vinsac/MyNodeOne/issues
