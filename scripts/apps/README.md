# One-Click App Installation Scripts

This directory contains one-click installation scripts for popular self-hosted applications. Each script deploys a fully configured application to your MyNodeOne cluster.

## 📦 Available Applications

### Media & Entertainment
- **Plex** - Premium media server (Netflix-like experience)
- **Jellyfin** - Open source media server (Plex alternative)
- **Audiobookshelf** - Audiobook and podcast server
- **Minecraft Server** - Host your own Minecraft server

### Photos & Files
- **Immich** - Self-hosted Google Photos alternative
- **Nextcloud** - Complete cloud storage and collaboration platform
- **Paperless-ngx** - Document management and OCR system

### Communication & Productivity
- **Mattermost** - Team chat (Slack alternative)
- **Gitea** - Self-hosted Git service (GitHub alternative)

### Security & Monitoring
- **Vaultwarden** - Password manager (Bitwarden server)
- **Uptime Kuma** - Service monitoring and status page
- **Homepage** - Application dashboard and homepage

## 🚀 Usage

Each script can be run independently:

```bash
# SSH into your control plane
ssh user@control-plane

# Navigate to the repository
cd /path/to/MyNodeOne

# Run any installation script
sudo ./scripts/apps/install-plex.sh
sudo ./scripts/apps/install-immich.sh
sudo ./scripts/apps/install-nextcloud.sh
```

## ✅ What Each Script Does

1. **Creates namespace** - Isolated environment for the app
2. **Deploys database** (if needed) - PostgreSQL, MySQL, or Redis
3. **Configures storage** - Persistent volumes via Longhorn
4. **Sets up networking** - LoadBalancer IP for access
5. **Generates credentials** - Secure random passwords
6. **Displays access info** - URL and login details

## 🔒 Security Features

- ✅ Strong random passwords (32 characters)
- ✅ Isolated namespaces
- ✅ Resource limits to prevent resource exhaustion
- ✅ Persistent storage with replication
- ✅ Encrypted network traffic via Tailscale

## 📊 Resource Requirements

Each app includes sensible defaults but can be customized:

| Application | RAM | CPU | Storage |
|------------|-----|-----|---------|
| Plex | 2GB | 1 core | 10GB + media |
| Jellyfin | 2GB | 1 core | 10GB + media |
| Immich | 4GB | 2 cores | 50GB + photos |
| Nextcloud | 2GB | 1 core | 20GB + files |
| Mattermost | 2GB | 1 core | 10GB |
| Vaultwarden | 512MB | 0.5 core | 1GB |
| Gitea | 1GB | 1 core | 10GB |
| Minecraft | 2-4GB | 2 cores | 5GB |
| Uptime Kuma | 512MB | 0.5 core | 2GB |
| Homepage | 256MB | 0.2 core | 500MB |

## 🎯 Recommended Setup Order

**For Personal/Family Use:**
1. **Vaultwarden** - Secure your passwords first
2. **Nextcloud** - File storage and sync
3. **Immich** - Photo backup and organization
4. **Jellyfin** - Media streaming
5. **Uptime Kuma** - Monitor your services

**For Home Lab/Learning:**
1. **Homepage** - Dashboard for everything
2. **Gitea** - Version control
3. **Uptime Kuma** - Monitoring
4. **Mattermost** - Team communication
5. **Minecraft** - Fun testing workload

**For Media Server:**
1. **Plex** or **Jellyfin** - Main media server
2. **Audiobookshelf** - Audiobooks/podcasts
3. **Homepage** - Organize access to media
4. **Nextcloud** - Share files with family

## 🆘 Uninstalling Apps

Each script has a corresponding uninstall script:

```bash
sudo ./scripts/apps/uninstall-plex.sh
sudo ./scripts/apps/uninstall-immich.sh
```

Or manually remove:
```bash
kubectl delete namespace <app-name>
```

## 💡 Tips

1. **Storage Location**: Apps store data in Longhorn volumes (replicated across nodes)
2. **Accessing Apps**: Use the Tailscale IP shown after installation
3. **Domain Names**: Optionally configure `.local` domains (see setup-local-dns.sh)
4. **Backups**: Enable Longhorn snapshots for automatic backups
5. **Updates**: Run the install script again to update to latest version

## 🔧 Customization

Each script can be customized by editing these variables:
- Storage size
- Memory/CPU limits
- Replica count
- Ingress configuration

## 📚 Documentation

For detailed information about each application, see:
- [Plex Documentation](https://support.plex.tv/)
- [Jellyfin Documentation](https://jellyfin.org/docs/)
- [Immich Documentation](https://immich.app/docs)
- [Nextcloud Documentation](https://docs.nextcloud.com/)
- And more in each app's official docs

## 🐛 Troubleshooting

**App won't start:**
```bash
kubectl get pods -n <app-name>
kubectl logs <pod-name> -n <app-name>
```

**Can't access app:**
```bash
kubectl get svc -n <app-name>
# Check the LoadBalancer IP
```

**Out of storage:**
```bash
kubectl get pv
# Check available capacity
```

**Need more help:**
See [docs/troubleshooting.md](../../docs/troubleshooting.md)

## 🤝 Contributing

Want to add a new app? Follow this structure:
1. Create `install-<appname>.sh`
2. Include namespace, deployment, service, PVC
3. Display access info at the end
4. Create `uninstall-<appname>.sh`
5. Update this README
6. Test on a real cluster

---

**Note**: These scripts are designed for MyNodeOne clusters. They assume:
- K3s installed via bootstrap-control-plane.sh
- Longhorn storage available
- MetalLB for LoadBalancer services
- Tailscale networking configured
