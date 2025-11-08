# VPS Edge Node Setup Guide

**Complete guide for setting up a VPS as a public-facing edge node for your MyNodeOne cluster**

---

## 🎯 What is a VPS Edge Node?

A **VPS Edge Node** is a public-facing server that:
- Routes external traffic to your cluster
- Handles SSL certificates automatically
- Enables public domain access (e.g., `https://photos.yourdomain.com`)
- Acts as a reverse proxy to your internal services

**Use Cases:**
- Access your apps from anywhere without VPN
- Share apps with family/friends via public URLs
- Professional web hosting for your services
- SSL/HTTPS for all your applications

---

## 📋 Prerequisites

Before you start:

✅ **VPS Requirements:**
- [ ] Ubuntu 20.04/22.04/24.04 LTS
- [ ] 2GB+ RAM (4GB recommended)
- [ ] 1+ CPU cores (2+ recommended)
- [ ] 20GB+ storage
- [ ] Public IP address
- [ ] Root or sudo access

✅ **Existing MyNodeOne Cluster:**
- [ ] Control plane already installed
- [ ] Tailscale configured and running
- [ ] Cluster accessible

✅ **Optional (but recommended):**
- [ ] Public domain name (e.g., `yourdomain.com`)
- [ ] DNS access to configure A records
- [ ] Email address for SSL certificates

---

## 🚀 Installation

### Step 1: Initial VPS Setup

```bash
# SSH into your VPS
ssh root@your-vps-ip

# Update system
sudo apt update && sudo apt upgrade -y

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Clone MyNodeOne repository
cd ~
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
```

### Step 2: Run Interactive Setup

```bash
# Start the setup wizard
sudo ./scripts/mynodeone

# When prompted:
? Select node type (1-4): 3  (VPS Edge Node)
```

### Step 3: Configuration Questions

The wizard will ask:

**Control Plane Details:**
```
? Control plane Tailscale IP: 100.76.150.5
? SSH username on control plane: yourusername
```

**VPS Details:**
```
? What should we call this node: edge-europe
? Where is this node located: contabo-europe
? Confirm this VPS public IP: 45.8.133.192
? Enter control plane Tailscale IP: 100.76.150.5
? Enter your email for SSL certificates: you@example.com
```

**Domain Configuration:**

Option 1 - You have a domain:
```
Enter your public domain (or press Enter to skip): yourdomain.com
```

Option 2 - You don't have a domain yet:
```
Enter your public domain (or press Enter to skip): [Press Enter]
[⚠] Skipping domain configuration. You can add it later to ~/.mynodeone/config.env
```

### Step 4: Installation Process

The setup will:
1. ✅ Install Docker and Traefik
2. ✅ Configure firewall (UFW)
3. ✅ Set up monitoring
4. ✅ Register with control plane
5. ✅ Run validation tests

**Expected Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🔍 Validating VPS Edge Node Setup
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Testing: Tailscale installed... ✓
  Testing: Tailscale running... ✓
  Testing: cloudflared installed... ✓
  Testing: Traefik running... ✓

[✓] ✅ All validation tests passed!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installation Complete!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 🌐 Domain Setup

### Option A: I Have a Domain - Initial Setup

If you entered a domain during installation, you're mostly done! Just configure DNS:

**1. Log into your domain registrar** (Namecheap, GoDaddy, Cloudflare, etc.)

**2. Add DNS A records:**

```
Type  Name     Value            TTL
A     @        45.8.133.192     300
A     *        45.8.133.192     300
```

This configures:
- `@` = Root domain (e.g., `yourdomain.com`)
- `*` = Wildcard (e.g., `photos.yourdomain.com`, `vault.yourdomain.com`)

**3. Wait for DNS propagation** (5-60 minutes)

**4. Verify DNS:**
```bash
# From your laptop or VPS
dig yourdomain.com
dig photos.yourdomain.com

# Should both return: 45.8.133.192
```

**5. SSL certificates will be automatically obtained!** 🎉

---

### Option B: Adding Domain Later

If you skipped domain configuration during setup, here's how to add it:

#### Step 1: Update Configuration

```bash
# On your VPS edge node
cd ~/MyNodeOne

# Add domain to config
echo 'PUBLIC_DOMAIN="yourdomain.com"' >> ~/.mynodeone/config.env

# Verify it was added
cat ~/.mynodeone/config.env | grep PUBLIC_DOMAIN
```

#### Step 2: Configure DNS Records

Follow the same DNS setup as Option A above.

#### Step 3: Re-run Registration

```bash
# On your VPS edge node
cd ~/MyNodeOne
sudo ./scripts/setup-vps-node.sh
```

**Expected Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🌍 VPS Node Registration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] VPS Details:
  • Tailscale IP: 100.113.214.2
  • Public IP: 45.8.133.192
  • Hostname: edge-europe

[✓] Domain configured: yourdomain.com

[INFO] Registering with control plane...
[✓] VPS registered in multi-domain registry
[✓] VPS registered in sync controller

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ VPS Node Configured!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

What's configured:
  • Registered in control plane registry
  • Auto-sync enabled for new apps
  • Traefik routes configured
  • Domain: yourdomain.com
```

#### Step 4: Update Traefik Configuration

```bash
# Edit Traefik dynamic configuration
sudo nano /etc/traefik/dynamic/mynodeone-routes.yml
```

Add your app routes:
```yaml
http:
  routers:
    immich:
      rule: "Host(`photos.yourdomain.com`)"
      service: immich
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
    
  services:
    immich:
      loadBalancer:
        servers:
          - url: "http://100.76.150.10"  # Your app's Tailscale IP
```

#### Step 5: Restart Traefik

```bash
cd /etc/traefik
docker compose restart
```

#### Step 6: Verify SSL Certificate

```bash
# Check certificate was obtained
docker logs traefik | grep "yourdomain.com"

# Should see:
# "Certificate obtained for domain yourdomain.com"
```

---

## 📱 Exposing Apps to the Internet

### Method 1: Automatic (Recommended)

When you install apps on your cluster, they can automatically register with the edge node:

```bash
# On control plane
cd ~/MyNodeOne
sudo ./scripts/apps/install-immich.sh

# Choose: y (Make publicly accessible)
? Make this app publicly accessible? [y/N]: y

# This will:
# 1. Register app in service registry
# 2. Sync routing to VPS edge node
# 3. Configure SSL certificate
# 4. App accessible at: https://photos.yourdomain.com
```

### Method 2: Manual Configuration

For apps already installed:

**On Control Plane:**
```bash
# Register app for public access
cd ~/MyNodeOne
sudo ./scripts/manage-app-visibility.sh

# Select app: immich
# Choose subdomain: photos
# Enable public access: yes
```

**On VPS Edge Node:**
```bash
# Sync latest routing
cd ~/MyNodeOne
sudo ./scripts/sync-vps-routes.sh
```

### Method 3: Custom Configuration

For advanced routing, edit Traefik config directly:

```bash
# On VPS edge node
sudo nano /etc/traefik/dynamic/custom-routes.yml
```

---

## 🔒 SSL/HTTPS Setup

### Automatic SSL (Let's Encrypt)

SSL certificates are obtained automatically when:
1. ✅ Domain DNS points to your VPS public IP
2. ✅ Port 80 and 443 are open in firewall
3. ✅ Traefik can reach the domain
4. ✅ Email is configured in setup

**Traefik handles:**
- Automatic certificate request
- Certificate renewal (every 90 days)
- HTTPS redirection
- Multiple domains/subdomains

### Verify SSL is Working

```bash
# Check certificate status
docker logs traefik 2>&1 | grep -i certificate

# Test HTTPS
curl -I https://photos.yourdomain.com

# Should show:
# HTTP/2 200
# server: traefik
```

### Troubleshooting SSL

**Certificate not obtained?**

```bash
# Check DNS is correct
dig photos.yourdomain.com  # Should return your VPS IP

# Check ports are open
sudo ufw status | grep -E '80|443'

# Check Traefik logs
docker logs traefik -f | grep -i acme

# Restart Traefik
cd /etc/traefik && docker compose restart
```

---

## 🔧 Configuration Files

### Main Traefik Config

**Location:** `/etc/traefik/traefik.yml`

```yaml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: you@example.com
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
```

### Dynamic Routes

**Location:** `/etc/traefik/dynamic/mynodeone-routes.yml`

Automatically updated when apps are installed/removed.

### Manual Edits

**Location:** `/etc/traefik/dynamic/custom-routes.yml`

For your custom routing rules.

---

## 🛠️ Common Operations

### Adding a New App

```bash
# 1. Install app on control plane
ssh user@control-plane
cd ~/MyNodeOne
sudo ./scripts/apps/install-<app>.sh

# 2. VPS automatically syncs new routes
# (or manually trigger sync)
ssh user@vps-edge
cd ~/MyNodeOne
sudo ./scripts/sync-vps-routes.sh

# 3. Access via public URL
# https://<app>.yourdomain.com
```

### Updating Domain

```bash
# On VPS edge node
sudo nano ~/.mynodeone/config.env

# Update line:
PUBLIC_DOMAIN="newdomain.com"

# Re-register
cd ~/MyNodeOne
sudo ./scripts/setup-vps-node.sh
```

### Removing Edge Node

```bash
# On control plane
cd ~/MyNodeOne
sudo ./scripts/lib/multi-domain-registry.sh unregister-vps <vps-tailscale-ip>

# On VPS (optional - clean up)
cd /etc/traefik
docker compose down
sudo rm -rf /etc/traefik
```

---

## 📊 Monitoring

### Check Edge Node Status

```bash
# On VPS edge node
docker ps  # Should show traefik running
docker logs traefik -f  # Watch traffic

# Check routing rules
docker exec traefik cat /etc/traefik/dynamic/mynodeone-routes.yml
```

### View Access Logs

```bash
# On VPS edge node
docker logs traefik 2>&1 | grep "access"
```

### Monitor Certificate Renewals

```bash
# Certificates auto-renew at 60 days
# Check renewal status
docker logs traefik 2>&1 | grep -i renew
```

---

## 🐛 Troubleshooting

### Issue: "Domain not resolving"

**Check:**
```bash
# DNS configured?
dig yourdomain.com

# Should return your VPS IP
# If not, check domain registrar DNS settings
```

### Issue: "SSL certificate error"

**Solutions:**
```bash
# 1. Check email in config
cat ~/.mynodeone/config.env | grep SSL_EMAIL

# 2. Check Traefik logs
docker logs traefik 2>&1 | grep -i acme

# 3. Check DNS propagation
dig yourdomain.com

# 4. Restart Traefik
cd /etc/traefik && docker compose restart
```

### Issue: "Can't reach app"

**Check:**
```bash
# 1. App running on control plane?
ssh user@control-plane
kubectl get pods -A | grep <app>

# 2. VPS can reach control plane via Tailscale?
ping $(grep CONTROL_PLANE_IP ~/.mynodeone/config.env | cut -d= -f2 | tr -d '"')

# 3. Routing configured?
docker exec traefik cat /etc/traefik/dynamic/mynodeone-routes.yml | grep <app>

# 4. Firewall allows traffic?
sudo ufw status
```

### Issue: "Too many redirects"

**Fix:**
```bash
# Edit Traefik config to ensure proper HTTPS handling
sudo nano /etc/traefik/traefik.yml

# Make sure HTTP → HTTPS redirect is configured once
# Not in both static and dynamic configs
```

---

## 🔐 Security Best Practices

### 1. Limit Exposed Apps

Only expose apps that need public access:
- ✅ Photo sharing (Immich)
- ✅ Password manager (Vaultwarden)
- ❌ Monitoring dashboards
- ❌ Admin panels

### 2. Enable Authentication

For publicly exposed apps:
```bash
# Enable app-level authentication
# Most apps have built-in auth

# Or add Traefik middleware auth
sudo nano /etc/traefik/dynamic/auth-middleware.yml
```

### 3. Rate Limiting

```yaml
# In /etc/traefik/dynamic/rate-limit.yml
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100
        burst: 50
```

### 4. Monitor Access

```bash
# Set up fail2ban for Traefik
sudo apt install fail2ban

# Configure to watch Traefik logs
sudo nano /etc/fail2ban/jail.local
```

### 5. Keep Updated

```bash
# Regular updates
sudo apt update && sudo apt upgrade -y

# Update Traefik
cd /etc/traefik
docker compose pull
docker compose up -d
```

---

## 💡 Tips & Tricks

### Multiple Domains

You can register multiple domains:
```bash
# Add to config
echo 'PUBLIC_DOMAIN_2="anotherdomain.com"' >> ~/.mynodeone/config.env

# Configure DNS for both domains
# Both will get SSL certificates
```

### Subdomain per App

Organize apps with subdomains:
- `photos.yourdomain.com` → Immich
- `vault.yourdomain.com` → Vaultwarden
- `files.yourdomain.com` → Nextcloud
- `media.yourdomain.com` → Jellyfin

### Custom Routing Rules

```yaml
# /etc/traefik/dynamic/custom-routes.yml
http:
  routers:
    custom-app:
      rule: "Host(`custom.yourdomain.com`) && Path(`/api`)"
      service: custom-service
      middlewares:
        - custom-auth
```

---

## 📚 Related Documentation

- **[VPS-INSTALLATION.md](VPS-INSTALLATION.md)** - Installing control plane on VPS
- **[DOMAIN-MANAGEMENT.md](../DOMAIN-MANAGEMENT.md)** - Advanced domain routing
- **[APP-PUBLIC-ACCESS.md](../APP-PUBLIC-ACCESS.md)** - Making apps publicly accessible
- **[HYBRID-SETUP-GUIDE.md](HYBRID-SETUP-GUIDE.md)** - Hybrid cloud-local setup

---

## ✅ Quick Reference

### Configuration File Locations

```
~/.mynodeone/config.env          # MyNodeOne configuration
/etc/traefik/traefik.yml         # Traefik static config
/etc/traefik/dynamic/*.yml       # Traefik dynamic routes
/etc/traefik/docker-compose.yml  # Traefik service
/letsencrypt/acme.json           # SSL certificates
```

### Useful Commands

```bash
# View configuration
cat ~/.mynodeone/config.env

# Re-register VPS
sudo ./scripts/setup-vps-node.sh

# Sync latest routes
sudo ./scripts/sync-vps-routes.sh

# Check Traefik status
docker ps | grep traefik

# View Traefik logs
docker logs traefik -f

# Restart Traefik
cd /etc/traefik && docker compose restart

# Run validation
sudo ./scripts/lib/validate-installation.sh vps-edge
```

### Getting Help

**Common Issues:**
1. Domain not resolving → Check DNS settings
2. No SSL certificate → Check email, DNS, logs
3. Can't reach app → Check app running, routing, firewall

**Support:**
- GitHub Issues: https://github.com/vinsac/MyNodeOne/issues
- Documentation: `docs/` folder
- Validation: `./scripts/lib/validate-installation.sh vps-edge`

---

## 🎉 Success!

You now have:
- ✅ VPS edge node configured
- ✅ Public domain with SSL/HTTPS
- ✅ Apps accessible from anywhere
- ✅ Automatic certificate renewal
- ✅ Secure reverse proxy setup

**Your apps are now accessible to the world!** 🌍

---

**Last Updated:** 2025-11-08
**MyNodeOne Version:** 1.0+
