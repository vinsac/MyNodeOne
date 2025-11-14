# MyNodeOne VPS Installation Guide

**Complete guide for installing MyNodeOne on cloud VPS (Contabo, DigitalOcean, Hetzner, etc.)**

---

## 🎯 Overview

This guide covers installing MyNodeOne on a **cloud VPS** instead of local hardware. Perfect for:
- Always-on infrastructure
- Remote access from anywhere
- No local hardware required
- Professional hosting

**Your Setup:** Contabo VPS, Ubuntu 24.04.3 LTS, IP: 45.8.133.192

---

## ⚠️ Important VPS Differences

### What's Different on VPS:

**1. No UI/Desktop**
- ❌ No graphical interface
- ✅ Everything done via SSH terminal
- ✅ Tailscale works in "headless" mode (CLI only)

**2. Public IP Address**
- ✅ VPS has public IP (45.8.133.192)
- ⚠️ Exposed to internet - **security critical**
- 🔒 Must harden security immediately

**3. Cloud Network**
- ❌ Not on your home network
- ❌ Can't access via .local domains initially
- ✅ Use Tailscale for secure access

**4. Single Node Setup**
- ✅ VPS becomes the control plane
- ✅ Can add local machines as workers later
- ✅ Hybrid cloud-local cluster possible

---

## 📋 Prerequisites Checklist

### Before You Start:

✅ **VPS Requirements:**
- [ ] Ubuntu 20.04/22.04/24.04 LTS
- [ ] 4GB+ RAM (8GB+ recommended)
- [ ] 2+ CPU cores (4+ recommended)
- [ ] 40GB+ storage (100GB+ recommended)
- [ ] Root or sudo access
- [ ] SSH access working

✅ **Your Local Machine:**
- [ ] Tailscale account (free: https://tailscale.com)
- [ ] SSH client (Terminal on Linux/Mac, PuTTY on Windows)
- [ ] GitHub account (for cloning repo)

✅ **Security Setup:**
- [ ] Changed default root password
- [ ] SSH key authentication set up
- [ ] Firewall configured
- [ ] Fail2ban installed (recommended)

---

## 🔒 Step 1: Secure Your VPS First

**CRITICAL: Do this BEFORE installing MyNodeOne!**

### 1.1 Update System

```bash
# Already connected via SSH to your VPS
sudo apt update
sudo apt upgrade -y
```

### 1.2 Create Non-Root User (Recommended)

```bash
# Create a regular user (recommended instead of using root)
adduser mynodeone
usermod -aG sudo mynodeone

# Switch to new user
su - mynodeone
```

**Or continue as root** (easier but less secure).

### 1.3 Set Up Firewall

```bash
# Install UFW (Uncomplicated Firewall)
sudo apt install -y ufw

# Allow SSH (CRITICAL - don't lock yourself out!)
sudo ufw allow 22/tcp

# Allow Kubernetes API (for remote management)
sudo ufw allow 6443/tcp

# Allow HTTP/HTTPS (for apps)
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow Tailscale
sudo ufw allow 41641/udp

# Enable firewall
sudo ufw enable

# Check status
sudo ufw status
```

### 1.4 Install Fail2ban (Prevents Brute Force)

```bash
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

**Why?** Your SSH logs show brute force attempts:
```
Oct 31 18:43:54 vmi2161443 sshd[6516]: Failed password for root from 103.123.53.88
Oct 31 18:44:02 vmi2161443 sshd[6653]: Failed password for invalid user git from 103.123.53.88
```

Fail2ban will auto-ban these attackers.

---

## 📡 Step 2: Install Tailscale (Headless Mode)

**Tailscale on VPS = No UI needed! Authentication via browser on your laptop.**

### 2.1 Install Tailscale

```bash
# On your VPS:
curl -fsSL https://tailscale.com/install.sh | sh
```

### 2.2 Start Tailscale (Headless/CLI Mode)

```bash
# Start Tailscale and get auth URL
sudo tailscale up --authkey= --advertise-exit-node

# OR simpler (no exit node):
sudo tailscale up
```

**You'll see output like:**
```
To authenticate, visit:
  https://login.tailscale.com/a/abcdef123456

```

### 2.3 Authenticate from Your Laptop

1. **Copy the URL** from VPS terminal
2. **Open it in browser** on your local laptop
3. **Log in** to Tailscale
4. **Approve** the VPS device
5. **Done!** VPS is now on your Tailscale network

### 2.4 Verify Tailscale Works

```bash
# On VPS - check Tailscale status
sudo tailscale status

# You should see your VPS with a Tailscale IP (100.x.x.x)
# Example output:
# 100.101.102.103  vmi2161443           mynodeone@  linux   -
```

**Note your Tailscale IP!** You'll use this to access apps.

### 2.5 Enable IP Forwarding (Required for Kubernetes)

```bash
# On your VPS:
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## 🚀 Step 3: Run the Automated VPS Setup

This is the easiest and most important step. You will run a single command **from your Control Plane** which will automatically configure the VPS.

### 3.1 Get Your VPS Information

You will need:
- The **username** for your VPS (e.g., `sammy`, `ubuntu`, or `root`).
- The **public IP address** of your VPS.

### 3.2 Run the `setup-edge-node.sh` Script

Log into your **Control Plane** machine via SSH. Navigate to the `MyNodeOne` directory and run the following command, replacing the user and IP with your VPS details.

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne
sudo ./scripts/setup-edge-node.sh <vps_username>@<vps_public_ip>
```

**Example:**
```bash
sudo ./scripts/setup-edge-node.sh sammy@45.8.133.192
```

### What This Command Does Automatically

This script handles everything for you:

1.  **Copies SSH Key**: Securely copies the control plane's `mynodeone_id_ed25519.pub` key to the VPS, authorizing it to connect.
2.  **Installs Software**: Installs `caddy` (for reverse proxying and auto-HTTPS) and other necessary tools on the VPS.
3.  **Hardens SSH**: Disables password login on the VPS, enforcing key-only authentication.
4.  **Establishes Reverse Tunnel**: Starts the `autossh` service on the control plane, creating a persistent reverse SSH tunnel to the VPS.
5.  **Registers the Node**: Adds the VPS to the `sync-controller-registry` so it receives automatic configuration updates.

### 3.3 Enter Your Domains

The script will prompt you to enter the public domain names you want to use. You can enter multiple domains, separated by spaces.

```
? Enter the domain(s) for this VPS (e.g., my-app.com www.my-app.com), separated by spaces:
> my.domain.one another.domain.two
```

Caddy will automatically acquire SSL certificates for these domains.

---

---

## 📦 Step 5: Install Your First App

### 5.1 Install Immich (Photo Backup)

```bash
cd ~/MyNodeOne
sudo ./scripts/apps/install-immich.sh
```

**Installation will show:**
```
✓ Immich installed successfully!
📍 Access Immich at: http://100.x.x.x (Tailscale IP)
```

### 5.2 Access from Your Laptop

On your **local laptop** (must be on Tailscale):

1. **Open browser**
2. **Navigate to:** `http://100.x.x.x` (use the IP shown in installation)
3. **Create admin account**
4. **Done!** Immich is running on your VPS

### 5.3 Access from Phone

1. **Install Tailscale** on your phone (iOS/Android)
2. **Log in** with same account
3. **Install Immich app**
4. **Connect to:** `http://100.x.x.x`

---

## 🎛️ Step 6: Install Dashboard

```bash
cd ~/MyNodeOne/website
sudo ./deploy-dashboard.sh
```

**Access dashboard at:** `http://100.x.x.x:8080` (via Tailscale)

---

## 🔍 Verification & Testing

### Check Cluster Status

```bash
# Check nodes
kubectl get nodes

# Should show:
# NAME          STATUS   ROLES                  AGE   VERSION
# vmi2161443    Ready    control-plane,master   10m   v1.28.x

# Check all pods
kubectl get pods -A

# All pods should be Running
```

### Check Tailscale Connectivity

```bash
# From VPS
sudo tailscale status

# From laptop
tailscale status

# Both should show each other
```

### Check App Access

```bash
# Get service IPs
kubectl get svc -A

# Try accessing from laptop via Tailscale IP
```

---

## 🐛 Troubleshooting VPS Issues

### Issue: "Can't access apps"

**Solutions:**

1. **Check Tailscale is connected:**
   ```bash
   tailscale status
   ```

2. **Check service has external IP:**
   ```bash
   kubectl get svc -A | grep LoadBalancer
   ```

3. **Check MetalLB is running:**
   ```bash
   kubectl get pods -n metallb-system
   ```

4. **Try public IP instead:**
   ```bash
   curl http://45.8.133.192
   ```

### Issue: "Installation stuck"

**Solutions:**

1. **Check disk space:**
   ```bash
   df -h
   # Need at least 20GB free
   ```

2. **Check memory:**
   ```bash
   free -h
   # Need at least 2GB available
   ```

3. **Check internet:**
   ```bash
   ping -c 3 google.com
   ```

4. **Check logs:**
   ```bash
   sudo journalctl -u k3s -f
   ```

### Issue: "Pod stuck in Pending"

**Solution:**

```bash
# Check pod details
kubectl describe pod <pod-name> -n <namespace>

# Common causes:
# 1. Insufficient resources
# 2. Storage not ready
# 3. Image pull errors

# Check Longhorn status
kubectl get pods -n longhorn-system
```

---

## 🔐 Security Best Practices for VPS

### 1. Use Tailscale Only (Recommended)

```bash
# Block direct public access
sudo ufw deny 80/tcp
sudo ufw deny 443/tcp
sudo ufw deny 6443/tcp

# Keep SSH open (change port first!)
sudo ufw allow 2222/tcp

# Only allow via Tailscale
# Apps accessible only via 100.x.x.x addresses
```

### 2. Change SSH Port

```bash
# Edit SSH config
sudo nano /etc/ssh/sshd_config

# Change line:
# Port 22
# to:
Port 2222

# Restart SSH
sudo systemctl restart sshd

# Update firewall
sudo ufw allow 2222/tcp
sudo ufw delete allow 22/tcp
```

### 3. Disable Root Login

```bash
# Edit SSH config
sudo nano /etc/ssh/sshd_config

# Set:
PermitRootLogin no
PasswordAuthentication no  # Use SSH keys only

# Restart SSH
sudo systemctl restart sshd
```

### 4. Regular Updates

```bash
# Create update script
cat > ~/update.sh << 'EOF'
#!/bin/bash
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
EOF

chmod +x ~/update.sh

# Run weekly
# Or set up unattended-upgrades
```

---

## 💰 VPS Cost Optimization

### Your Contabo VPS

**Specs:**
- 4 cores, 6GB RAM, 400GB SSD
- ~€5-10/month
- Perfect for MyNodeOne!

**Cost Savings:**
- **vs AWS EC2 t3.medium:** Save €20/month
- **vs DigitalOcean:** Save €15/month
- **vs Cloud storage:** Save €50+/month

**Apps you can run:**
- Immich (photo backup)
- Jellyfin (media server)
- Vaultwarden (password manager)
- Nextcloud (file sync)
- **Total savings:** €100+/month vs subscriptions

---

## 🌍 Accessing Your VPS from Anywhere

### Via Tailscale (Recommended)

**Laptop/Desktop:**
1. Install Tailscale
2. Log in
3. Access via `http://100.x.x.x`

**Phone/Tablet:**
1. Install Tailscale app
2. Log in
3. Access via `http://100.x.x.x` in browser or apps

**Always secure, always private, no port forwarding needed!**

### Via Public IP (Not Recommended)

If you must use public IP:
1. Set up SSL certificates (Let's Encrypt)
2. Enable authentication on all apps
3. Use strong, unique passwords
4. Monitor access logs
5. Consider Cloudflare proxy

---

## 📊 Monitoring Your VPS

### Check Resource Usage

```bash
# CPU and memory
htop

# Disk space
df -h

# Kubernetes resources
kubectl top nodes
kubectl top pods -A
```

### Access Grafana Dashboard

```bash
# Get Grafana password
kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode

# Access at: http://100.x.x.x:3000
# Username: admin
# Password: (from above command)
```

---

## 🚀 Next Steps

### After Installation:

1. **✅ Install more apps:**
   ```bash
   sudo ./scripts/app-store.sh
   ```

2. **✅ Set up backups:**
   - Configure Longhorn snapshots
   - Export to S3/BackBlaze
   - Document: `docs/backup-guide.md`

3. **✅ Add worker nodes:**
   - Install on local machines
   - Join to VPS cluster
   - Hybrid cloud setup!

4. **✅ Set up monitoring:**
   - Configure alerts
   - Set up log aggregation
   - Monitor costs

5. **✅ Harden security:**
   - Enable 2FA
   - Audit logs
   - Security scanning

---

## 📚 Related Documentation

- **[INSTALLATION.md](INSTALLATION.md)** - General installation guide
- **[docs/guides/MOBILE-ACCESS-GUIDE.md](MOBILE-ACCESS-GUIDE.md)** - Mobile app setup
- **[docs/reference/FAQ.md](../reference/FAQ.md)** - Common questions
- **[docs/use-cases/README.md](../use-cases/README.md)** - Use cases

---

## 🆘 Getting Help

### Common Issues:

1. **Installation error?**
   - Check error message
   - Look in logs: `sudo journalctl -u k3s -f`
   - Open GitHub issue with full error

2. **Can't access apps?**
   - Verify Tailscale: `tailscale status`
   - Check services: `kubectl get svc -A`
   - Try public IP

3. **Performance issues?**
   - Check resources: `htop`, `df -h`
   - Upgrade VPS plan
   - Optimize apps

### Get Support:

- **GitHub Issues:** https://github.com/vinsac/MyNodeOne/issues
- **Documentation:** Check docs/ folder
- **Community:** Share your setup!

---

## ✅ Summary

**VPS Installation Checklist:**

- [x] VPS provisioned (Contabo)
- [x] SSH access working
- [x] Security hardened (firewall, fail2ban)
- [x] Tailscale installed and authenticated
- [x] MyNodeOne installed
- [x] First app deployed
- [x] Access verified from laptop/phone
- [x] Monitoring enabled
- [x] Backups configured

**You now have:**
- ✨ Private cloud on VPS
- 🔒 Secure access via Tailscale
- 📦 One-click app installation
- 🌍 Access from anywhere
- 💰 Massive cost savings

**Your VPS is now your personal cloud!** 🚀

---

**Questions?** Check the error message and we'll debug together!
