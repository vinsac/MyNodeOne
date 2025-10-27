# MyNodeOne Quick Start Guide

## ✅ Your Cluster is Ready!

Your MyNodeOne control plane has been successfully installed and is operational.

---

## 🌐 Access Your Services

All services are accessible via your Tailscale VPN:

| Service | URL | Credentials |
|---------|-----|-------------|
| **Grafana** | http://100.118.5.203 | admin / qBGpQApYl5g79EG91XlhBh7Yc4ljZWHf |
| **MinIO Console** | http://100.118.5.202:9001 | admin / gztYwRw2luaxQXPlJiHOc397hmLrtJ1k |
| **Longhorn UI** | http://100.118.5.205 | No authentication |
| **ArgoCD** | https://100.118.5.204 | See /root/mynodeone-argocd-credentials.txt |

📌 **Important**: These services are only accessible when connected to Tailscale VPN.

---

## 🚀 Deploy Your First App (5 Minutes)

### Step 1: Verify Cluster is Healthy
```bash
kubectl get nodes --kubeconfig ~/.kube/config
# Should show: canada-pc-0001   Ready   ...
```

### Step 2: Create a Simple Web App
```bash
# Create deployment
kubectl create deployment hello-world \
  --image=nginxinc/nginx-unprivileged:alpine \
  --kubeconfig ~/.kube/config

# Expose it with a LoadBalancer
kubectl expose deployment hello-world \
  --port=80 \
  --target-port=8080 \
  --type=LoadBalancer \
  --kubeconfig ~/.kube/config

# Wait for external IP (takes ~30 seconds)
kubectl get svc hello-world --kubeconfig ~/.kube/config
```

### Step 3: Access Your App
```bash
# Get the external IP
EXTERNAL_IP=$(kubectl get svc hello-world -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --kubeconfig ~/.kube/config)

# Open in browser
echo "Visit: http://$EXTERNAL_IP"
```

🎉 **Success!** You've deployed your first application to MyNodeOne!

---

## 📊 Monitor Your Cluster

### Grafana Dashboards
1. Open http://100.118.5.203
2. Login with `admin` / `qBGpQApYl5g79EG91XlhBh7Yc4ljZWHf`
3. Navigate to **Dashboards** → Browse
4. View:
   - **Kubernetes / Compute Resources / Cluster**: Overall cluster health
   - **Kubernetes / Compute Resources / Node**: Per-node metrics
   - **Kubernetes / Compute Resources / Namespace**: Per-namespace usage

### View All Resources
```bash
# See everything running
kubectl get all -A --kubeconfig ~/.kube/config

# See persistent volumes
kubectl get pv,pvc -A --kubeconfig ~/.kube/config

# See storage classes
kubectl get storageclass --kubeconfig ~/.kube/config
```

---

## 💾 Using Storage

### Create a Persistent Volume Claim
```yaml
# save as pvc-example.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f pvc-example.yaml --kubeconfig ~/.kube/config
kubectl get pvc my-app-data --kubeconfig ~/.kube/config
```

### Use in a Deployment
```yaml
# Add to your deployment spec:
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-app-data

volumeMounts:
  - name: data
    mountPath: /data
```

---

## 🔧 Common Commands

### Cluster Management
```bash
# View cluster info
kubectl cluster-info --kubeconfig ~/.kube/config

# View node details
kubectl describe node canada-pc-0001 --kubeconfig ~/.kube/config

# View resource usage
kubectl top nodes --kubeconfig ~/.kube/config
kubectl top pods -A --kubeconfig ~/.kube/config
```

### Application Management
```bash
# List all deployments
kubectl get deployments -A --kubeconfig ~/.kube/config

# Scale a deployment
kubectl scale deployment <name> --replicas=3 --kubeconfig ~/.kube/config

# Delete a deployment
kubectl delete deployment <name> --kubeconfig ~/.kube/config

# Restart a deployment
kubectl rollout restart deployment/<name> --kubeconfig ~/.kube/config
```

### Debugging
```bash
# View pod logs
kubectl logs <pod-name> -n <namespace> --kubeconfig ~/.kube/config

# Follow logs in real-time
kubectl logs -f <pod-name> -n <namespace> --kubeconfig ~/.kube/config

# Execute command in pod
kubectl exec -it <pod-name> -n <namespace> --kubeconfig ~/.kube/config -- /bin/sh

# View pod events
kubectl describe pod <pod-name> -n <namespace> --kubeconfig ~/.kube/config
```

---

## 🎯 Next Steps

### 1. Secure Your Cluster
- [ ] Change Grafana admin password (first login)
- [ ] Store credentials securely
- [ ] Delete credential files: `sudo rm /root/mynodeone-*-credentials.txt`

### 2. Explore Monitoring
- [ ] Open Grafana and explore dashboards
- [ ] Check Longhorn storage UI
- [ ] View MinIO buckets

### 3. Deploy Real Applications
- [ ] Deploy a database (PostgreSQL, MySQL, Redis)
- [ ] Set up ArgoCD for GitOps deployments
- [ ] Deploy your own applications

### 4. Add Worker Nodes (Optional)
```bash
# On another machine, run:
sudo ./scripts/mynodeone

# Select "Worker Node" when prompted
# Provide join token from /root/mynodeone-join-token.txt
```

---

## 🆘 Troubleshooting

### Can't Access Services?
1. Ensure you're connected to Tailscale VPN
2. Check service status: `kubectl get svc -A --kubeconfig ~/.kube/config`
3. Verify pods are running: `kubectl get pods -A --kubeconfig ~/.kube/config`

### Pods Not Starting?
1. Check events: `kubectl describe pod <pod-name> --kubeconfig ~/.kube/config`
2. View logs: `kubectl logs <pod-name> --kubeconfig ~/.kube/config`
3. Check Pod Security Policy (new namespaces enforce "restricted" security)

### Storage Issues?
1. Check Longhorn UI: http://100.118.5.205
2. View PVCs: `kubectl get pvc -A --kubeconfig ~/.kube/config`
3. Check disk space: `df -h | grep longhorn`

### K3s Not Running?
```bash
# Check status
sudo systemctl status k3s

# View logs
sudo journalctl -u k3s -n 100

# Restart if needed
sudo systemctl restart k3s
```

---

## 📚 More Resources

- **Full Access Info**: [ACCESS_INFORMATION.md](./ACCESS_INFORMATION.md)
- **Installation Guide**: [INSTALLATION.md](./INSTALLATION.md)
- **Architecture**: [docs/architecture.md](./docs/architecture.md)
- **FAQ**: [FAQ.md](./FAQ.md)

---

**Happy Clustering! 🚀**

For more help, check the documentation in the `/home/canada-pc-0001/MyNodeOne/docs/` directory.
