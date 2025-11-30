# MyNodeOne App Store

## Overview

MyNodeOne now includes a built-in **App Store** with one-click installations for popular self-hosted applications. Non-technical users can easily deploy powerful applications to their personal cloud without writing any code.

## Installation Guide

**NEW!** For comprehensive installation instructions, error handling, and troubleshooting:

👉 **[Complete App Installation Guide](../guides/APP-INSTALLATION-GUIDE.md)**

Covers:
- ✅ Prerequisites and validation
- ✅ Step-by-step installation
- ✅ All edge cases and solutions
- ✅ Error handling
- ✅ Post-installation verification
- ✅ Troubleshooting commands

---

## How Do You Access Apps?

**Great News!** Every app gets an **easy-to-remember address** automatically:

```
jellyfin.mynodeone.local    ← Your Netflix-like media server
immich.mynodeone.local      ← Your Google Photos backup
vaultwarden.mynodeone.local ← Your password manager
nextcloud.mynodeone.local   ← Your Dropbox replacement
...and so on!
```

### On Your Laptop/Desktop (Local Network)

**Works immediately after DNS setup!** Just type the address in your browser.

**Example:** After installing Jellyfin, open your browser and go to:
```
http://jellyfin.mynodeone.local
```

**Works on:**
- ✅ Your laptop (with DNS configured)
- ✅ Your desktop computer
- ✅ Any computer that ran `setup-client-dns.sh`

### On Mobile Devices (Requires Tailscale)

**IMPORTANT: Mobile phones and tablets need Tailscale installed**

**Why?** Your apps run on a secure Tailscale network (100.x.x.x IPs). Mobile devices must join this network to access them.

**How to Set Up Tailscale on Mobile (5 minutes, one-time):**

1. **Install Tailscale app**
   - iPhone: App Store → "Tailscale"
   - Android: Play Store → "Tailscale"

2. **Connect**
   - Open app → Login with SAME account as MyNodeOne
   - Tap "Connect"

3. **Done!** Open Safari/Chrome and go to:
   - `http://jellyfin.mynodeone.local` - it just works!

**What you get:**
- ✅ Access apps from anywhere (home, coffee shop, vacation)
- ✅ Encrypted connection (like a personal VPN)
- ✅ Same easy URLs work everywhere
- ✅ No port forwarding or router setup needed
- ✅ Free for personal use!

### Public Access (Advanced)

Want to share Jellyfin with family not on your network?

- Set up custom domain (like `movies.yourfamily.com`)
- Requires VPS edge node (~$5/month)
- See EDGE_NODE_GUIDE.md for setup

## Available Applications

### AI & Assistant
- **LLM Chat (Open WebUI + Ollama)** ✅ - Private AI chat with local LLMs (ChatGPT alternative)
  - 100% private - no data leaves your cluster
  - Download models: phi3, llama3.2, mistral, and more
  - Document upload & analysis
  - Auto-installed during control plane setup
  - High-performance optimized

### Media & Entertainment
- **Jellyfin** ✅ - Open source media server (Netflix alternative)
- **Plex** 🚧 - Premium media server with apps for every device
- **Audiobookshelf** 🚧 - Audiobook and podcast server
- **Minecraft Server** ✅ - Host your own game server

### Photos & Files
- **Immich** ✅ - Self-hosted Google Photos alternative with AI features
- **Nextcloud** ✅ - Complete cloud storage and collaboration platform
- **Paperless-ngx** 🚧 - Document management with OCR

### Communication & Productivity
- **Mattermost** 🚧 - Team chat (Slack alternative)
- **Gitea** 🚧 - Self-hosted Git service (GitHub alternative)

### Security & Monitoring
- **Vaultwarden** ✅ - Password manager (Bitwarden server)
- **Uptime Kuma** 🚧 - Service monitoring and status pages
- **Homepage** ✅ - Beautiful dashboard for all your services

**Legend:** ✅ Ready to use | 🚧 Coming soon

## How to Install Apps

### Method 1: Interactive App Store (Easiest)

SSH into your control plane and run:
```bash
sudo ./scripts/app-store.sh
```

This launches an interactive menu where you can:
1. Browse available applications
2. Select an app by number
3. Wait for automatic installation
4. Get access URL and credentials

### Method 2: Direct Script Execution

Install any app directly:
```bash
# AI Chat Assistant
sudo ./scripts/apps/install-llm-chat.sh

# Media server
sudo ./scripts/apps/install-jellyfin.sh

# Photo backup
sudo ./scripts/apps/install-immich.sh

# Cloud storage
sudo ./scripts/apps/install-nextcloud.sh

# Password manager
sudo ./scripts/apps/install-vaultwarden.sh

# Game server
sudo ./scripts/apps/install-minecraft.sh

# Application dashboard
sudo ./scripts/apps/install-homepage.sh
```

### Method 3: Web Dashboard

1. Open http://mynodeone.local in your browser
2. Scroll to "One-Click App Installation"
3. Click on any app card
4. Copy the installation command
5. Run it on your control plane

## What Happens During Installation?

Each script automatically:
1. ✅ Creates isolated namespace
2. ✅ Deploys required database (PostgreSQL/MySQL/Redis if needed)
3. ✅ Configures persistent storage via Longhorn
4. ✅ Assigns LoadBalancer IP via MetalLB
5. ✅ Generates secure random passwords
6. ✅ Displays access URL and credentials

## Resource Requirements

| Application | RAM | CPU | Storage | Notes |
|------------|-----|-----|---------|-------|
| Jellyfin | 2GB | 1 core | 10GB + media | Hardware transcoding available |
| Immich | 4GB | 2 cores | 50GB + photos | Includes PostgreSQL + Redis |
| Vaultwarden | 512MB | 0.5 core | 1GB | Very lightweight |
| Minecraft | 2-4GB | 2 cores | 5GB | Adjustable memory |
| Homepage | 256MB | 0.2 core | 500MB | Just for dashboard |

## Recommended Installation Order

### For Personal/Family Use:
1. **Vaultwarden** - Secure passwords first
2. **Nextcloud** - File storage and sync
3. **Immich** - Photo backup from phones
4. **Jellyfin** - Media streaming
5. **Uptime Kuma** - Monitor everything

### For Home Lab/Learning:
1. **Homepage** - Dashboard to organize access
2. **Gitea** - Version control for projects
3. **Uptime Kuma** - Service monitoring
4. **Mattermost** - Team communication
5. **Minecraft** - Fun testing workload

### For Media Server:
1. **Jellyfin** (or Plex) - Main media server
2. **Audiobookshelf** - Audiobooks/podcasts
3. **Homepage** - Organize all media services
4. **Nextcloud** - Share files with family

## Managing Installed Apps

### View Installed Apps
```bash
kubectl get namespaces | grep -E "jellyfin|immich|vaultwarden|minecraft|homepage"
```

### Check App Status
```bash
# Replace <app-name> with: jellyfin, immich, vaultwarden, etc.
kubectl get all -n <app-name>
```

### View App Logs
```bash
kubectl logs -f deployment/<app-name> -n <app-name>
```

### Restart App
```bash
kubectl rollout restart deployment/<app-name> -n <app-name>
```

### Uninstall App
```bash
# This removes everything (data included!)
kubectl delete namespace <app-name>
```

## Security Features

All installed apps include:
- ✅ **Strong passwords** - Auto-generated 32-character passwords
- ✅ **Network isolation** - Each app in separate namespace
- ✅ **Resource limits** - CPU/memory limits prevent resource exhaustion
- ✅ **Persistent storage** - Data replicated via Longhorn
- ✅ **Encrypted network** - All traffic via Tailscale VPN

## Mobile App Support

Many apps have excellent mobile clients:

| Application | iOS | Android | Web |
|------------|-----|---------|-----|
| Immich | ✅ | ✅ | ✅ |
| Vaultwarden (Bitwarden) | ✅ | ✅ | ✅ |
| Jellyfin | ✅ | ✅ | ✅ |
| Nextcloud | ✅ | ✅ | ✅ |
| Mattermost | ✅ | ✅ | ✅ |
| Minecraft | ✅ | ✅ | - |

### How to Set Up Mobile Apps

**⚠️ IMPORTANT: Install Tailscale on your phone FIRST!**

All mobile apps require Tailscale to access your MyNodeOne services.

**One-Time Setup (5 minutes):**

1. **Install Tailscale**
   - iPhone: App Store → "Tailscale"
   - Android: Play Store → "Tailscale"

2. **Connect**
   - Open Tailscale app
   - Login with SAME account as MyNodeOne
   - Tap "Connect"

3. **Install your app** (e.g., Immich, Jellyfin, Bitwarden)
   - Download from App Store/Play Store

4. **Configure server**
   - Immich: `http://immich.mynodeone.local`
   - Jellyfin: `http://jellyfin.mynodeone.local`
   - Bitwarden (for Vaultwarden): `http://vaultwarden.mynodeone.local`
   - Nextcloud: `http://nextcloud.mynodeone.local`
   - Mattermost: `http://mattermost.mynodeone.local`

5. **Login and enjoy!**

**Note:** Keep Tailscale running in background for seamless access.

## Troubleshooting

### App won't start
```bash
# Check pod status
kubectl get pods -n <app-name>

# View logs
kubectl logs <pod-name> -n <app-name>

# Common issues:
# - Out of storage: kubectl get pv
# - Out of memory: kubectl top nodes
# - Database not ready: Wait 2-3 minutes
```

### Can't access app
```bash
# Check service IP
kubectl get svc -n <app-name>

# Verify Tailscale connection
tailscale status

# Test connectivity
curl http://<service-ip>
```

### App using too much resources
```bash
# Check resource usage
kubectl top pods -n <app-name>

# Edit resource limits (advanced)
kubectl edit deployment <app-name> -n <app-name>
```

## Contributing

Want to add a new app to the store?

1. **Create installation script**: `scripts/apps/install-<appname>.sh`
2. **Follow the template** from existing apps (Jellyfin, Immich, etc.)
3. **Include these sections**:
   - Namespace creation
   - Storage configuration (if needed)
   - Database deployment (if needed)
   - Main application deployment
   - Service with LoadBalancer
   - Display access info and credentials
4. **Create uninstall script**: `scripts/apps/uninstall-<appname>.sh`
5. **Update**:
   - `scripts/apps/README.md`
   - `scripts/app-store.sh` (add menu option)
   - `website/dashboard.html` (add app card)
   - This `APP-STORE.md` file
6. **Test on real cluster**
7. **Submit Pull Request**

### App Requirements:
- ✅ Must work with K3s
- ✅ Must use Longhorn for storage
- ✅ Must request LoadBalancer service
- ✅ Must generate secure random passwords
- ✅ Must display access info clearly
- ✅ Should have reasonable resource defaults

## More Information

- **Full installation scripts**: `scripts/apps/`
- **App-specific docs**: see each app's official documentation
- **Troubleshooting guide**: [troubleshooting.md](../troubleshooting.md)
- **Storage management**: [storage-guide.md](../storage-guide.md)
- **Scaling guide**: [scaling.md](../scaling.md)

## Need Help?

- Open an issue on GitHub
- Check the FAQ: [FAQ](FAQ.md)
- Read troubleshooting guide: [troubleshooting.md](../troubleshooting.md)

---

**Built to make self-hosting accessible to everyone**
