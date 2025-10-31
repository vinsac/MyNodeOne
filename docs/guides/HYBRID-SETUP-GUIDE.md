# Hybrid Cloud Setup Guide

**Your home server + Cloud VPS = Professional infrastructure**

**For complete beginners** - No technical knowledge required!

---

## 🎯 What is Hybrid Setup?

**Simple explanation:**

Think of it like this:
- **Your home computer** = Where your apps and data live (private, free)
- **Cloud VPS** = Public doorman that lets people in (cheap, secure)

**Why this is awesome:**
- ✅ Apps run at home (your hardware, your data, $0/month)
- ✅ Access from internet via VPS ($5-10/month)
- ✅ VPS protects your home IP (security)
- ✅ Best of both worlds!

---

## 📊 Architecture (Visual)

```
          INTERNET
              ↓
    ┌─────────────────────┐
    │  VPS (Cloud)        │  ← $5/month
    │  • Public IP        │
    │  • SSL certificates │
    │  • Firewall         │
    └─────────────────────┘
              ↓
      (Tailscale VPN)
       Encrypted tunnel
              ↓
    ┌─────────────────────┐
    │  Home Computer      │  ← $0/month
    │  • Kubernetes       │
    │  • Your apps        │
    │  • Your data        │
    └─────────────────────┘
```

**User Journey:**
1. User visits: `photos.yourname.com`
2. DNS points to: VPS IP (45.8.133.192)
3. VPS routes via Tailscale to: Your home computer
4. App responds: Your photos load!

**Result:** Public access, private data, minimal cost! 

---

## 📋 What You Need

### Required:

- [ ] **Home computer/server** (old laptop, desktop, Raspberry Pi)
  - Must be on 24/7
  - 4GB+ RAM recommended
  - Internet connection

- [ ] **Cloud VPS** (Contabo, DigitalOcean, Hetzner, etc.)
  - $5-10/month
  - Ubuntu 20.04+
  - 2GB+ RAM

- [ ] **Domain name** (optional but recommended)
  - $10/year from Namecheap, GoDaddy, etc.
  - Examples: `yourname.com`, `familycloud.com`

- [ ] **Tailscale account** (free!)
  - Sign up at https://tailscale.com
  - Used to connect VPS ↔ Home

### Nice to have:

- [ ] Email for SSL certificates (free Let's Encrypt)
- [ ] Mobile phone (for Tailscale authentication)

---

## 🚀 Step-by-Step Setup

### Phase 1: Set Up Home Computer (Control Plane)

**Time:** 30-45 minutes

#### Step 1.1: Prepare Home Computer

**Requirements:**
- Ubuntu 20.04, 22.04, or 24.04
- Connected to internet
- Can stay on 24/7

**Install Tailscale:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Authentication:**
1. Command shows a URL like: `https://login.tailscale.com/a/abc123...`
2. Open URL on phone or laptop
3. Log in to Tailscale (or create account)
4. Click "Connect"

**Get Tailscale IP:**
```bash
tailscale ip -4
# Note this IP! Example: 100.118.5.68
```

---

#### Step 1.2: Install MyNodeOne

```bash
# Clone repository
cd ~
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Run installer
sudo ./scripts/mynodeone
```

**During installation, choose:**
1. **Node type:** `1` (Control Plane)
2. **Cluster name:** Whatever you want (e.g., `mycluster`)
3. **Node name:** Keep default or choose a name
4. **Location:** `home` (or your city)

**Wait 20-30 minutes for installation.**

---

#### Step 1.3: Verify Installation

```bash
# Check cluster
kubectl get nodes
# Should show your node in "Ready" status

# Check services
kubectl get svc -A
# Should show various services running
```

**Success!** ✅ Your home control plane is ready.

---

### Phase 2: Set Up Cloud VPS (Edge Node)

**Time:** 15-20 minutes

#### Step 2.1: Get a VPS

**Recommended providers:**

**Contabo (Cheapest):**
- Website: https://contabo.com
- Cost: ~$5/month
- Size: 4GB RAM, 2 CPU cores

**DigitalOcean:**
- Website: https://digitalocean.com
- Cost: $6/month
- Size: 1GB "Droplet"

**Hetzner:**
- Website: https://hetzner.com
- Cost: €4/month
- Size: 2GB CX11

**Choose:**
- OS: Ubuntu 24.04 LTS
- Location: Close to you (lower latency)
- Note the public IP!

---

#### Step 2.2: Install Tailscale on VPS

```bash
# SSH into VPS
ssh root@YOUR_VPS_IP

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Authenticate** (same as before - open URL on phone/laptop)

**Get VPS Tailscale IP:**
```bash
tailscale ip -4
# Note this IP! Example: 100.101.92.95
```

---

#### Step 2.3: Install MyNodeOne on VPS

```bash
# On VPS:
cd ~
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Run installer
sudo ./scripts/mynodeone
```

**During installation, choose:**
1. **Node type:** `3` (VPS Edge Node)  ← **IMPORTANT!**
2. **Cluster name:** Same as home (e.g., `mycluster`)
3. **Node name:** Keep default
4. **Location:** `contabo-germany` (or your VPS location)
5. **Public IP:** Confirm VPS public IP
6. **Control plane IP:** Enter home computer Tailscale IP (100.118.5.68)
7. **Email:** Your email for SSL certificates

**Wait 10-15 minutes for installation.**

---

#### Step 2.4: Verify VPS Setup

```bash
# Check Docker is running
docker ps
# Should show "traefik" container

# Check Tailscale connection to home
ping 100.118.5.68
# Should get responses

# View Traefik logs
docker logs traefik
# Should show "Starting provider"
```

**Success!** ✅ Your VPS edge node is ready.

---

### Phase 3: Install Your First App

**Time:** 10-15 minutes

#### Step 3.1: Install Immich (Photos) on Home

```bash
# On home computer (control plane):
cd ~/MyNodeOne
sudo ./scripts/apps/install-immich.sh
```

**During installation:**
1. Wait for Immich to deploy
2. **When asked:** "Configure VPS route?" → Choose **Yes**
3. **Enter domain:** `yourname.com` (if you have one)
4. **Enter subdomain:** `photos`

**What happens:**
- Immich installs on home computer
- VPS automatically configured to route `photos.yourname.com` → Your home
- SSL certificate will be auto-generated

---

#### Step 3.2: Configure DNS

**See detailed guide:** [DNS-SETUP-GUIDE.md](DNS-SETUP-GUIDE.md)

**Quick version:**

1. **Log into domain registrar** (Namecheap, GoDaddy, etc.)
2. **Go to DNS settings**
3. **Add A record:**
   ```
   Type: A
   Name: photos
   Value: YOUR_VPS_PUBLIC_IP (e.g., 45.8.133.192)
   TTL: 300
   ```
4. **Save**

**Wait 5-15 minutes for DNS to propagate.**

---

#### Step 3.3: Access Your App

**From any computer/phone:**

1. **Open browser**
2. **Go to:** `https://photos.yourname.com`
3. **First time:**
   - May take 1-2 minutes for SSL certificate
   - Create your admin account
4. **Done!** Your photos are accessible from anywhere!

**From phone:**
1. Install Immich mobile app
2. Server: `https://photos.yourname.com`
3. Login
4. Enable auto-backup
5. Photos upload to your home server!

---

### Phase 4: Install More Apps

**Repeat for each app:**

#### Jellyfin (Media Server)

```bash
# On home computer:
sudo ./scripts/apps/install-jellyfin.sh
```

**When prompted:**
- Domain: `yourname.com`
- Subdomain: `jellyfin` (or `media`)

**DNS setup:**
```
Type: A
Name: jellyfin
Value: YOUR_VPS_IP
```

**Access:** `https://jellyfin.yourname.com`

---

#### Vaultwarden (Password Manager)

```bash
# On home computer:
sudo ./scripts/apps/install-vaultwarden.sh
```

**When prompted:**
- Domain: `yourname.com`
- Subdomain: `vault` (or `passwords`)

**DNS setup:**
```
Type: A
Name: vault
Value: YOUR_VPS_IP
```

**Access:** `https://vault.yourname.com`

---

#### Dashboard

```bash
# On home computer:
cd ~/MyNodeOne/website
sudo ./deploy-dashboard.sh
```

**When prompted:**
- Domain: `yourname.com`
- Subdomain: `dashboard` (or `home`)

**DNS setup:**
```
Type: A
Name: dashboard
Value: YOUR_VPS_IP
```

**Access:** `https://dashboard.yourname.com`

---

## 🎯 Complete Example

**Your setup after everything:**

```
Domain: example.com
VPS IP: 45.8.133.192
Home Tailscale IP: 100.118.5.68

Apps:
  • https://photos.example.com → Immich (photos)
  • https://jellyfin.example.com → Jellyfin (movies/TV)
  • https://vault.example.com → Vaultwarden (passwords)
  • https://dashboard.example.com → Dashboard
  • https://cloud.example.com → Nextcloud (files)

All running on YOUR home computer!
All accessible from internet!
Total cost: $5-10/month (VPS only)
```

---

## 📱 Mobile Access

### Photos (Immich):

1. **Install Immich app**
   - iOS: App Store
   - Android: Play Store

2. **Configure:**
   - Server: `https://photos.yourname.com`
   - Login with admin account
   - Enable background upload

3. **Done!** Photos auto-backup to your home server

---

### Media (Jellyfin):

1. **Install Jellyfin app**
   - iOS: App Store
   - Android: Play Store

2. **Configure:**
   - Server: `https://jellyfin.yourname.com`
   - Login

3. **Stream your movies/TV from anywhere!**

---

### Passwords (Vaultwarden):

1. **Install Bitwarden app** (compatible with Vaultwarden)
   - iOS: App Store
   - Android: Play Store

2. **Configure:**
   - Go to Settings → Self-hosted
   - Server: `https://vault.yourname.com`
   - Login

3. **Your passwords everywhere!**

---

## 🔒 Security Features

**What protects you:**

✅ **Tailscale encryption:** Home ↔ VPS traffic is encrypted  
✅ **Home IP hidden:** Public sees VPS IP, not your home IP  
✅ **HTTPS everywhere:** Automatic SSL certificates  
✅ **Firewall on VPS:** Only necessary ports open  
✅ **Fail2ban:** Auto-ban brute force attempts  
✅ **No port forwarding:** No holes in home router  

**You're more secure than most cloud services!**

---

## 💰 Cost Breakdown

### Monthly Costs:

| Item | Cost | Notes |
|------|------|-------|
| Home Computer | $0 | Use existing hardware |
| Electricity | ~$5-10 | Old laptop uses ~20W |
| VPS | $5-10 | Contabo, DigitalOcean, Hetzner |
| **Total** | **$10-20/month** | |

### One-Time Costs:

| Item | Cost | Notes |
|------|------|-------|
| Domain name | $10/year | From Namecheap, etc. |
| Hardware | $0-200 | Use what you have! |

### Comparison:

**Without MyNodeOne (subscriptions):**
- Google Photos: $10/month
- Netflix/streaming: $15/month
- Cloud storage: $10/month
- Password manager: $5/month
- **Total: $40/month = $480/year**

**With MyNodeOne:**
- VPS: $10/month
- **Total: $10/month = $120/year**

**Savings: $360/year!** 💰

---

## 🐛 Troubleshooting

### Problem: Can't access via domain

**Check:**
1. DNS A record exists and points to VPS IP
2. Wait 15 minutes for DNS propagation
3. Check DNS: `dig photos.yourname.com`
4. Should show VPS IP

**Fix:**
- Verify DNS record in registrar
- Try `https://` not `http://`
- Clear browser cache

---

### Problem: "Connection refused"

**Check:**
1. Home computer is on and connected
2. Tailscale running on both home and VPS
3. Can VPS ping home?

**From VPS:**
```bash
ping 100.118.5.68
# Should get responses
```

**Fix:**
```bash
# On home computer:
sudo tailscale status
# Should show "online"

# On VPS:
sudo tailscale status
# Should show "online" and list home computer
```

---

### Problem: SSL certificate error

**Causes:**
- DNS not propagated yet
- Wrong domain in configuration
- Cloudflare proxy enabled (turn off orange cloud)

**Fix:**
- Wait 10 minutes
- Check DNS points to correct IP
- View Traefik logs: `docker logs traefik`

---

### Problem: VPS can't reach home

**Check Tailscale:**
```bash
# On both machines:
sudo tailscale status

# Should see each other in list
```

**Fix:**
```bash
# Restart Tailscale on both:
sudo tailscale down
sudo tailscale up
```

---

## 🆘 Getting Help

### Self-Help:

1. **Check status:**
   ```bash
   # Home computer:
   kubectl get pods -A
   tailscale status
   
   # VPS:
   docker ps
   docker logs traefik
   tailscale status
   ```

2. **Common issues:**
   - DNS not propagated → Wait 15 minutes
   - Tailscale disconnected → Restart
   - App not running → Check kubectl

3. **Logs:**
   ```bash
   # App logs (home):
   kubectl logs -f deployment/immich-server -n immich
   
   # VPS logs:
   docker logs -f traefik
   ```

### Ask for Help:

1. **GitHub Issues:** https://github.com/vinsac/MyNodeOne/issues
2. **Include:**
   - What step you're on
   - Error message (copy/paste)
   - Output of status commands above
3. **We'll help debug!**

---

## ✅ Success Checklist

**After complete setup:**

- [ ] Home computer running MyNodeOne (control plane)
- [ ] VPS running edge node (Traefik)
- [ ] Tailscale connecting both
- [ ] Domain pointing to VPS IP
- [ ] At least one app installed (Immich)
- [ ] Can access app via `https://subdomain.yourname.com`
- [ ] Mobile app configured and working
- [ ] Automatic photo backup working

**You now have your own cloud!** 🎉

---

## 🚀 What's Next?

### More Apps:

```bash
# See all available apps:
sudo ./scripts/app-store.sh

# Popular ones:
- Jellyfin (media server)
- Nextcloud (file sync)
- Vaultwarden (password manager)
- Home Assistant (smart home)
- Pi-hole (ad blocker)
```

### Advanced Features:

- [ ] Add more home computers as workers
- [ ] Set up automatic backups
- [ ] Configure monitoring (Grafana)
- [ ] Add authentication (Authelia)
- [ ] Multiple VPS edge nodes (redundancy)

### Share Your Setup:

- Tell friends about your cloud
- Save $500+/year on subscriptions
- Own your data
- Learn valuable skills

---

## 📚 Related Guides

- **[VPS-INSTALLATION.md](VPS-INSTALLATION.md)** - Detailed VPS setup
- **[DNS-SETUP-GUIDE.md](DNS-SETUP-GUIDE.md)** - Complete DNS instructions
- **[MOBILE-ACCESS-GUIDE.md](MOBILE-ACCESS-GUIDE.md)** - Mobile app setup
- **[../reference/FAQ.md](../reference/FAQ.md)** - Common questions

---

## 💡 Understanding What You Built

**You created enterprise-grade infrastructure!**

**Same technology used by:**
- Netflix (Kubernetes)
- Spotify (Kubernetes)
- Airbnb (Kubernetes)
- Your setup (Kubernetes!)

**What makes it special:**
- ✅ Scalable (add more computers anytime)
- ✅ Reliable (apps auto-restart if crashed)
- ✅ Secure (encrypted, firewalled, SSL)
- ✅ Professional (same as billion-dollar companies)
- ✅ Cheap (runs on your hardware)

**You're not just saving money - you're learning valuable skills!**

---

## 🎓 What You Learned

**Skills gained:**
- ✅ Linux system administration
- ✅ Container orchestration (Kubernetes)
- ✅ Networking (VPN, DNS, SSL)
- ✅ Cloud infrastructure
- ✅ DevOps practices

**Market value:** These skills are worth $80K-150K+/year jobs!

---

**Congratulations on building your own cloud! 🎉**

**You own your data. You control your infrastructure. You save money.**

**Welcome to MyNodeOne!** 🚀
