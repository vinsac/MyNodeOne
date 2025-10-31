# MyNodeOne Access Cheat Sheet
## Print This Out and Stick It On Your Wall! 📌

---

## 🏠 Your Main Dashboard

```
┌─────────────────────────────────────────────┐
│                                             │
│   http://mynodeone.local                    │
│                                             │
│   YOUR CONTROL CENTER                       │
│   - See all installed apps                  │
│   - Install new apps                        │
│   - View cluster status                     │
│                                             │
└─────────────────────────────────────────────┘
```

---

## 📱 All Your Apps (After Installation)

```
┌────────────────────────────────────────────────────────────┐
│  MEDIA & ENTERTAINMENT                                     │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  🎬 Jellyfin (Netflix)                                     │
│     http://jellyfin.mynodeone.local                        │
│                                                            │
│  🎮 Minecraft Server                                       │
│     minecraft.mynodeone.local:25565                        │
│                                                            │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  PHOTOS & FILES                                            │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  📸 Immich (Google Photos)                                 │
│     http://immich.mynodeone.local                          │
│                                                            │
│  ☁️  Nextcloud (Dropbox)                                   │
│     http://nextcloud.mynodeone.local                       │
│                                                            │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  SECURITY & TOOLS                                          │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  🔐 Vaultwarden (Passwords)                                │
│     http://vaultwarden.mynodeone.local                     │
│                                                            │
│  🏠 Homepage (Dashboard)                                   │
│     http://homepage.mynodeone.local                        │
│                                                            │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  SYSTEM MONITORING                                         │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  📊 Grafana (Monitoring)                                   │
│     http://grafana.mynodeone.local                         │
│     Username: admin                                        │
│     Password: (run: sudo ./scripts/show-credentials.sh)    │
│                                                            │
│  🚀 ArgoCD (GitOps)                                        │
│     https://argocd.mynodeone.local                         │
│                                                            │
│  💾 MinIO (Storage)                                        │
│     http://minio.mynodeone.local:9001                      │
│                                                            │
│  📦 Longhorn (Disk Management)                             │
│     http://longhorn.mynodeone.local                        │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

---

## ⚡ Quick Install Commands

```bash
# Media Server (Netflix-like)
sudo ./scripts/apps/install-jellyfin.sh

# Photo Backup (Google Photos-like)
sudo ./scripts/apps/install-immich.sh

# Password Manager
sudo ./scripts/apps/install-vaultwarden.sh

# Cloud Storage (Dropbox-like)
sudo ./scripts/apps/install-nextcloud.sh

# Team Chat (Slack-like)
sudo ./scripts/apps/install-mattermost.sh

# Game Server
sudo ./scripts/apps/install-minecraft.sh

# Or browse all apps:
sudo ./scripts/app-store.sh
```

---

## 🔧 Useful Commands

```bash
# View all credentials
sudo ./scripts/show-credentials.sh

# Check cluster status
./scripts/cluster-status.sh

# View installed apps
kubectl get namespaces | grep -v kube

# Restart an app (if it's misbehaving)
kubectl rollout restart deployment/jellyfin -n jellyfin

# View app logs
kubectl logs -f deployment/jellyfin -n jellyfin

# Uninstall an app
kubectl delete namespace jellyfin
```

---

## 📱 Mobile App Setup

### ⚠️ REQUIRED: Install Tailscale First!

**Mobile devices MUST have Tailscale to access your apps.**

### Step 1: Install Tailscale (One-Time)
- iOS: App Store → "Tailscale"
- Android: Play Store → "Tailscale"
- Open app → Login (same account as MyNodeOne) → Connect

### Step 2: Download Your App
- iOS: App Store
- Android: Play Store

### Step 3: Add Server
Point it to: `http://[appname].mynodeone.local`

### Step 4: Login
Use account you created on web

**Examples:**
```
Jellyfin app     → http://jellyfin.mynodeone.local
Immich app       → http://immich.mynodeone.local
Bitwarden app    → http://vaultwarden.mynodeone.local
Nextcloud app    → http://nextcloud.mynodeone.local
Mattermost app   → http://mattermost.mynodeone.local
```

---

## 🌍 Access From Anywhere

### Using Tailscale (Recommended)

**Setup Once:**
1. Install Tailscale on phone: https://tailscale.com/download
2. Login with same account
3. All addresses work from anywhere!

**Now you can:**
- Access Jellyfin from vacation
- View Immich photos at work
- Check Vaultwarden at coffee shop
- All encrypted and secure

---

## 🆘 Emergency Troubleshooting

### Can't access apps?
```bash
# Fix DNS
sudo ./scripts/setup-local-dns.sh

# On laptop, run:
sudo bash setup-client-dns.sh
```

### App not working?
```bash
# Check if it's running
kubectl get pods -n [appname]

# Restart it
kubectl rollout restart deployment/[appname] -n [appname]
```

### Out of storage?
```bash
# Check storage
kubectl get pv

# Delete old apps
kubectl delete namespace [unused-app-name]
```

### Forgot password?
```bash
# View all passwords
sudo ./scripts/show-credentials.sh
```

---

## 💡 The Simple Pattern

**Remember:**
```
Install command:    sudo ./scripts/apps/install-[NAME].sh
Access URL:         http://[NAME].mynodeone.local
Mobile app server:  http://[NAME].mynodeone.local
```

**Replace [NAME] with:**
- jellyfin
- immich
- vaultwarden
- nextcloud
- mattermost
- homepage
- etc.

---

## 📞 Get Help

- **Documentation:** https://github.com/vinsac/MyNodeOne
- **Issues:** https://github.com/vinsac/MyNodeOne/issues
- **FAQ:** See FAQ.md in the repo

---

**Pro Tip:** Bookmark `http://mynodeone.local` as your browser homepage!

---

*Print this out and keep it handy!*
*Last Updated: October 2024*
