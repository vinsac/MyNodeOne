# Subdomain Access in MyNodeOne
## How Every App Gets Its Own Easy-to-Remember Address

---

## 🎯 The Problem We Solved

**Before:** Apps were accessible via IP addresses like:
- `http://100.64.12.45:8096` ← What app is this? 😕
- `http://192.168.1.200:3001` ← Hard to remember! 🤔
- `http://10.43.251.8` ← Which service? 😵

**After:** Apps get friendly subdomain names:
- `http://jellyfin.mynodeone.local` ← Obviously Jellyfin! 😊
- `http://immich.mynodeone.local` ← Photo backup! 📸
- `http://vaultwarden.mynodeone.local` ← Password manager! 🔐

---

## ✨ How It Works

### Automatic Configuration

When you install an app, MyNodeOne **automatically**:

1. **Deploys the app** to Kubernetes
2. **Assigns a LoadBalancer IP** via MetalLB (on Tailscale network)
3. **Creates DNS entry** mapping `appname.mynodeone.local` → IP
4. **Updates hosts files** on control plane
5. **Generates client script** for your laptop/phone

**You don't do anything!** It just works.

---

## 🌐 Access Patterns

### Pattern 1: Web Browser Access

**Simple Rule:**
```
http://[appname].mynodeone.local
```

**Examples:**
```bash
# Media server
http://jellyfin.mynodeone.local

# Photo backup
http://immich.mynodeone.local

# Password manager
http://vaultwarden.mynodeone.local

# Cloud storage
http://nextcloud.mynodeone.local

# Team chat
http://mattermost.mynodeone.local
```

### Pattern 2: Mobile App Configuration

When setting up mobile apps, use the same address:

**Jellyfin Mobile App:**
```
Server: http://jellyfin.mynodeone.local
```

**Immich Mobile App:**
```
Server URL: http://immich.mynodeone.local
```

**Bitwarden (Vaultwarden) Mobile App:**
```
Server URL: http://vaultwarden.mynodeone.local
```

**Nextcloud Mobile App:**
```
Server URL: http://nextcloud.mynodeone.local
```

### Pattern 3: Game Servers

**Minecraft:**
```
Server Address: minecraft.mynodeone.local:25565
```

---

## 🏠 Local Network Access (Default)

### How It Works

1. **Control Plane DNS:** dnsmasq running on control plane resolves `.local` domains
2. **Client DNS:** Your laptop's `/etc/hosts` file has entries
3. **Same Network:** All devices on your WiFi can access

### Setup (One-Time)

**On Control Plane (already done during bootstrap):**
```bash
sudo ./scripts/setup-local-dns.sh
```

**On Your Laptop/Desktop:**
```bash
# Download the setup script from control plane
scp user@mynodeone:~/MyNodeOne/setup-client-dns.sh .

# Run it
sudo bash setup-client-dns.sh
```

**On Your Phone/Tablet:**
- Just works! (broadcasts via mDNS/Avahi)
- Or connect via Tailscale for guaranteed access

---

## 🌍 Remote Access (Tailscale)

### How It Works

**With Tailscale:**
1. All devices join your private mesh network
2. DNS works across the entire network
3. Same URLs work from anywhere
4. Fully encrypted connection

### Setup (5 Minutes)

**On Your Phone:**
1. Install Tailscale app: https://tailscale.com/download
2. Login with same account as MyNodeOne
3. Done! Open `http://jellyfin.mynodeone.local` from anywhere

**On Your Laptop:**
1. Install Tailscale: https://tailscale.com/download
2. Login with same account
3. All apps accessible from coffee shops, hotels, etc.

---

## 🔧 Behind the Scenes

### DNS Resolution Flow

```
User types: http://jellyfin.mynodeone.local
    ↓
Browser queries DNS
    ↓
DNS resolver checks:
    1. /etc/hosts file
    2. dnsmasq (if on control plane)
    3. Avahi/mDNS (if on same network)
    4. Tailscale MagicDNS (if using Tailscale)
    ↓
Returns: 100.64.x.x (Tailscale IP)
    ↓
Browser connects to app
    ↓
App loads!
```

### Technical Components

1. **MetalLB:** Assigns LoadBalancer IPs from Tailscale subnet
2. **dnsmasq:** DNS server on control plane
3. **Avahi:** mDNS for `.local` domain broadcasting
4. **Tailscale MagicDNS:** Optional DNS for remote access
5. **/etc/hosts:** Fallback on client devices

---

## 📋 Complete App Address List

### System Services (Pre-installed)
```
Dashboard:   http://mynodeone.local
Grafana:     http://grafana.mynodeone.local
ArgoCD:      https://argocd.mynodeone.local
MinIO:       http://minio.mynodeone.local:9001
Longhorn:    http://longhorn.mynodeone.local
```

### Installable Apps
```
Jellyfin:      http://jellyfin.mynodeone.local
Plex:          http://plex.mynodeone.local
Immich:        http://immich.mynodeone.local
Nextcloud:     http://nextcloud.mynodeone.local
Vaultwarden:   http://vaultwarden.mynodeone.local
Mattermost:    http://mattermost.mynodeone.local
Gitea:         http://gitea.mynodeone.local
Homepage:      http://homepage.mynodeone.local
Uptime Kuma:   http://uptime-kuma.mynodeone.local
Paperless:     http://paperless.mynodeone.local
Audiobookshelf: http://audiobookshelf.mynodeone.local
Minecraft:     minecraft.mynodeone.local:25565
```

---

## 🆘 Troubleshooting

### Problem: Can't resolve `.local` domains

**Solution 1: Update DNS**
```bash
# On control plane
sudo ./scripts/configure-app-dns.sh

# On client
sudo bash setup-app-dns-client.sh
```

**Solution 2: Use IP directly**
```bash
# Find the IP
kubectl get svc -n jellyfin

# Access via IP
http://100.64.x.x:8096
```

**Solution 3: Check Tailscale**
```bash
# Ensure connected
tailscale status

# Test ping
ping mynodeone.local
```

### Problem: DNS works on control plane but not laptop

**Cause:** Client DNS not configured

**Fix:**
```bash
# On control plane, regenerate client script
sudo ./scripts/configure-app-dns.sh

# Copy to laptop
scp user@mynodeone:~/MyNodeOne/setup-app-dns-client.sh .

# Run on laptop
sudo bash setup-app-dns-client.sh
```

### Problem: App installed but subdomain doesn't work

**Cause:** DNS not updated after app installation

**Fix:**
```bash
# Apps auto-configure DNS, but if it failed:
sudo ./scripts/configure-app-dns.sh
```

### Problem: Can't access from phone

**Cause:** Mobile devices require Tailscale to access the private network

**Fix:** Install Tailscale on phone (REQUIRED for all mobile access)
```
1. App Store/Play Store → "Tailscale"
2. Install and login with SAME account as MyNodeOne
3. Tap "Connect"
4. All addresses work now - home WiFi, mobile data, anywhere!
```

**Note:** This is not optional - mobile devices MUST have Tailscale installed to access MyNodeOne apps.

---

## 💡 Pro Tips

### 1. Bookmark Your Apps
Create browser bookmarks:
```
Bookmarks Bar/
├── MyNodeOne/
│   ├── Dashboard → http://mynodeone.local
│   ├── Jellyfin → http://jellyfin.mynodeone.local
│   ├── Immich → http://immich.mynodeone.local
│   └── Vaultwarden → http://vaultwarden.mynodeone.local
```

### 2. Set as Homepage
```
Browser Settings → Homepage
Set to: http://mynodeone.local
```

### 3. Share with Family
```
# Create accounts for family members
# Give them the URLs
# They can access from any device on your WiFi
```

### 4. Use Tailscale for Remote
```
# Everyone installs Tailscale
# Everyone uses same URLs
# Works from anywhere
# Fully encrypted
```

### 5. Print the Cheat Sheet
```
See: ACCESS-CHEAT-SHEET.md
Print and stick on your wall!
```

---

## 🔐 Security Notes

### What's Protected

✅ **Network Isolation:** Only accessible via Tailscale VPN  
✅ **No Public Exposure:** Not accessible from internet  
✅ **Encrypted Transport:** Tailscale uses WireGuard  
✅ **Individual Auth:** Each app has its own login  

### What You Should Do

1. **Use Strong Passwords:** For each app
2. **Enable 2FA:** Where available (Vaultwarden, Nextcloud, etc.)
3. **Regular Updates:** Keep apps updated
4. **Backup Credentials:** Save in password manager
5. **Monitor Access:** Check Grafana for unusual activity

---

## 📚 Related Documentation

- **[BEGINNER-GUIDE.md](BEGINNER-GUIDE.md)** - Complete beginner's guide
- **[QUICK-START.md](QUICK-START.md)** - Get started in 10 minutes
- **[ACCESS-CHEAT-SHEET.md](ACCESS-CHEAT-SHEET.md)** - All URLs in one place
- **[APP-STORE.md](APP-STORE.md)** - Available applications

---

## 🎉 Summary

**The Magic:**
- Install app → Automatically gets `appname.mynodeone.local`
- No IP addresses to remember
- Works everywhere (home network + Tailscale)
- Perfect for non-technical users

**The Pattern:**
```
sudo ./scripts/apps/install-[name].sh
→ Access at: http://[name].mynodeone.local
```

**That's it!** Simple, consistent, user-friendly. 🚀

---

*Questions? See the FAQ or open an issue on GitHub!*
