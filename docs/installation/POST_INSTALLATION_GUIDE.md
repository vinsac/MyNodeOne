# Post-Installation Guide

Your MyNodeOne cluster is installed. This guide covers immediate next steps.

---

## Your Services Are Ready

During installation, the installer displayed your service URLs and credentials. These use `.local` domain names that work on any device connected to your Tailscale network:

| Service | URL | Notes |
|---------|-----|-------|
| **Grafana** | `http://grafana.<your-domain>.local` | Monitoring dashboards |
| **ArgoCD** | `https://argocd.<your-domain>.local` | GitOps deployments |
| **Longhorn** | `http://longhorn.<your-domain>.local` | Storage management |
| **MinIO** | `http://minio.<your-domain>.local` | S3-compatible storage |

**Credentials** were displayed during installation. If you need them again, run on **control plane**:
```bash
sudo ./scripts/show-credentials.sh
```

---

## Approve Tailscale Subnet Route (Required, One-Time)

For other devices to access your services, approve the subnet route in Tailscale:

1. Go to https://login.tailscale.com/admin/machines
2. Find your control plane machine
3. Click "..." → "Edit route settings"
4. Toggle ON the subnet route (e.g., `100.118.5.0/24`)
5. Click "Save"

After this, any device on your Tailscale network can access your services.

---

## Verify Your Cluster

Run on **control plane** or **management laptop** (after setup):
```bash
# Check nodes are ready
kubectl get nodes

# Check all pods are running
kubectl get pods -A

# Check services have IPs
kubectl get svc -A
```

---

## Deploy Your First App

Run on **control plane**:
```bash
sudo ./scripts/deploy-demo-app.sh deploy
```

Access the URL shown after deployment. Remove when done:
```bash
sudo ./scripts/deploy-demo-app.sh remove
```

---

## Install Apps from the App Store

Run on **control plane**:
```bash
sudo ./scripts/app-store.sh
```

Or install directly:
```bash
sudo ./scripts/apps/install-jellyfin.sh    # Media server
sudo ./scripts/apps/install-immich.sh      # Photo backup
sudo ./scripts/apps/install-vaultwarden.sh # Password manager
```

See [APP-STORE.md](../reference/APP-STORE.md) for the full catalog.

---

## Next Steps

- **Deploy apps:** See [APP-STORE.md](../reference/APP-STORE.md)
- **Manage your cluster:** See [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md)
- **Add worker nodes:** See [INSTALLATION.md](INSTALLATION.md#section-4-worker-node-installation)
- **Set up management laptop:** See [INSTALLATION.md](INSTALLATION.md#section-3-management-laptop-setup)
- **Troubleshooting:** See [FAQ.md](../reference/FAQ.md)
