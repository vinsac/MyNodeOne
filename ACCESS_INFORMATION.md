# MyNodeOne Access Information

## 🎉 Control Plane Successfully Installed

Your MyNodeOne control plane is running on `canada-pc-0001` (100.118.5.68)

---

## 🔑 Service Access Credentials

### Grafana (Monitoring & Metrics)
- **URL**: http://100.118.5.203
- **Username**: `admin`
- **Password**: `qBGpQApYl5g79EG91XlhBh7Yc4ljZWHf`
- **Description**: Dashboards for monitoring cluster health, resource usage, and application metrics

### MinIO (S3-Compatible Object Storage)
- **Console URL**: http://100.118.5.202:9001
- **API Endpoint**: http://100.118.5.201:9000
- **Username**: `admin`
- **Password**: `gztYwRw2luaxQXPlJiHOc397hmLrtJ1k`
- **Description**: S3-compatible storage for backups, media files, and object storage

### Longhorn (Block Storage UI)
- **URL**: http://100.118.5.205
- **Authentication**: None (internal cluster access only via Tailscale)
- **Description**: Manage persistent volumes and storage for your applications
- **Storage**: 32.8TB across 2 x 18TB drives

### ArgoCD (GitOps Deployment)
- **URL**: https://100.118.5.204
- **Username**: `admin`
- **Password**: See `/root/mynodeone-argocd-credentials.txt`
- **Description**: GitOps continuous deployment for Kubernetes applications

---

## 📊 Cluster Information

### Hardware Resources
- **CPU**: 32 cores
- **Memory**: 249GB RAM
- **Storage**: 32.8TB (Longhorn distributed storage)
  - `/dev/sda`: 16.4TB
  - `/dev/sdb`: 16.4TB
- **Network**: Tailscale VPN (100.118.5.68)

### Installed Components
- ✅ K3s Kubernetes (v1.28.5+k3s1)
- ✅ Helm package manager
- ✅ cert-manager (certificate management)
- ✅ Traefik (ingress controller)
- ✅ MetalLB (load balancer)
- ✅ Longhorn (distributed block storage)
- ✅ MinIO (S3-compatible object storage)
- ✅ Prometheus + Grafana + Loki (monitoring stack)
- ✅ ArgoCD (GitOps platform)

---

## 🔒 Security Hardening Status

### ✅ Enabled Security Features
1. **Audit Logging**: All API server requests logged to `/var/log/k3s-audit.log`
2. **Pod Security Standards**: Enforced at "restricted" level for new namespaces
3. **Firewall (UFW)**: Enabled, allowing only SSH and Tailscale traffic

### ⚠️ Secrets Encryption
- **Status**: Temporarily disabled due to configuration conflict
- **Reason**: Existing secrets were encrypted with a different provider
- **Action Required**: Re-encrypt secrets after validating cluster stability

#### To Re-enable Secrets Encryption:
```bash
# 1. Create encryption config
sudo cp /etc/rancher/k3s/encryption-config.yaml.bak /etc/rancher/k3s/encryption-config.yaml

# 2. Update K3s config
sudo vi /etc/rancher/k3s/config.yaml
# Add under kube-apiserver-arg:
#   - "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"

# 3. Restart K3s
sudo systemctl restart k3s

# 4. Re-encrypt existing secrets
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

---

## 🚀 Quick Start Commands

### Check Cluster Health
```bash
# View all nodes
kubectl get nodes --kubeconfig ~/.kube/config

# View all pods across all namespaces
kubectl get pods -A --kubeconfig ~/.kube/config

# View all services
kubectl get svc -A --kubeconfig ~/.kube/config
```

### Deploy Your First Application
```bash
# Example: Deploy nginx
kubectl create deployment nginx --image=nginx --kubeconfig ~/.kube/config
kubectl expose deployment nginx --port=80 --type=LoadBalancer --kubeconfig ~/.kube/config

# Check the service
kubectl get svc nginx --kubeconfig ~/.kube/config
```

### View Logs
```bash
# View logs for a specific pod
kubectl logs -n <namespace> <pod-name> --kubeconfig ~/.kube/config

# Follow logs in real-time
kubectl logs -f -n <namespace> <pod-name> --kubeconfig ~/.kube/config
```

---

## 📝 Important Files

### Configuration Files
- **Kubeconfig**: `~/.kube/config` (for kubectl access)
- **K3s Config**: `/etc/rancher/k3s/config.yaml`
- **MyNodeOne Config**: `/root/.mynodeone/config.env`

### Credentials Files (Stored securely with 600 permissions)
- **ArgoCD**: `/root/mynodeone-argocd-credentials.txt`
- **MinIO**: `/root/mynodeone-minio-credentials.txt`
- **Worker Join Token**: `/root/mynodeone-join-token.txt`

### Security Configuration
- **Audit Policy**: `/etc/rancher/k3s/audit-policy.yaml`
- **Pod Security**: `/etc/rancher/k3s/pod-security-config.yaml`
- **Audit Log**: `/var/log/k3s-audit.log`

---

## 🛠️ Troubleshooting

### Services Not Accessible
1. **Check if running on Tailscale**: Ensure you're connected to Tailscale VPN
2. **Verify service status**:
   ```bash
   kubectl get svc -A --kubeconfig ~/.kube/config
   ```
3. **Check pod status**:
   ```bash
   kubectl get pods -A --kubeconfig ~/.kube/config
   ```

### Pods Not Starting
1. **Check pod events**:
   ```bash
   kubectl describe pod <pod-name> -n <namespace> --kubeconfig ~/.kube/config
   ```
2. **View pod logs**:
   ```bash
   kubectl logs <pod-name> -n <namespace> --kubeconfig ~/.kube/config
   ```
3. **Check Pod Security Policy**: New namespaces enforce "restricted" security by default

### Storage Issues
1. **Check Longhorn status**: Visit http://100.118.5.205
2. **View PVCs**:
   ```bash
   kubectl get pvc -A --kubeconfig ~/.kube/config
   ```
3. **Check disk mounts**:
   ```bash
   df -h | grep longhorn
   ```

---

## 📚 Documentation Links

- **Installation Guide**: `/home/canada-pc-0001/MyNodeOne/INSTALLATION.md`
- **Getting Started**: `/home/canada-pc-0001/MyNodeOne/GETTING-STARTED.md`
- **Architecture**: `/home/canada-pc-0001/MyNodeOne/docs/architecture.md`
- **Operations**: `/home/canada-pc-0001/MyNodeOne/docs/operations.md`
- **FAQ**: `/home/canada-pc-0001/MyNodeOne/FAQ.md`
- **Troubleshooting**: `/home/canada-pc-0001/MyNodeOne/docs/troubleshooting.md`

---

## 🔐 Security Recommendations

1. **Change Default Passwords**: Immediately change Grafana admin password
2. **Rotate Credentials**: Regularly rotate ArgoCD and MinIO passwords
3. **Backup Credentials**: Store all credentials in a secure password manager
4. **Delete Credential Files**: After saving passwords securely:
   ```bash
   sudo rm /root/mynodeone-*-credentials.txt
   ```
5. **Enable Secrets Encryption**: Follow the steps above to re-enable after testing
6. **Regular Updates**: Keep K3s and applications updated

---

## 📞 Support

For issues or questions:
1. Check documentation in `/home/canada-pc-0001/MyNodeOne/docs/`
2. View project on GitHub: https://github.com/vinsac/MyNodeOne
3. Check logs: `sudo journalctl -u k3s -n 100`

---

**Last Updated**: October 26, 2025  
**Cluster Version**: K3s v1.28.5+k3s1  
**Node**: canada-pc-0001 (100.118.5.68)
