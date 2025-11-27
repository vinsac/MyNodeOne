# App Public Access Guide

**How to make your apps publicly accessible during and after installation**

---

## Table of Contents

1. [Overview](#overview)
2. [During App Installation](#during-app-installation)
3. [After App Installation](#after-app-installation)
4. [Understanding the Flow](#understanding-the-flow)
5. [Common Scenarios](#common-scenarios)
6. [Troubleshooting](#troubleshooting)

---

## Overview

When you install an app in MyNodeOne, you have **full control** over whether it's publicly accessible or private. The system will ask you clearly during installation and provide options.

### Access Types

**🔒 Private (Local-Only)**
- Accessible only via Tailscale VPN
- URL: `http://subdomain.mycloud.local`
- No internet exposure
- Best for: Personal apps, admin panels, sensitive services

**🌍 Public (Internet-Accessible)**
- Accessible from anywhere on the internet
- URL options:
  - **Subdomain**: `https://subdomain.yourdomain.com` (e.g., `photos.curiios.com`)
  - **Root domain**: `https://yourdomain.com` (e.g., `curiios.com`)
- Automatic SSL certificates
- Best for: Sharing with others, public portfolios, client-facing apps

### Subdomain vs Root Domain

**Subdomain (Default):**
```
photos.curiios.com    → Immich
chat.curiios.com      → Open-WebUI
media.curiios.com     → Jellyfin
```
✅ **Use this when:** You have multiple apps on same domain  
✅ **Benefit:** Organize apps by subdomain  

**Root Domain:**
```
curiios.com           → Your main website/app
myportfolio.com       → Your portfolio site
myblog.com            → Your blog
```
✅ **Use this when:** Domain dedicated to one app  
✅ **Benefit:** Cleaner URL, no subdomain prefix  
⚠️  **Note:** One app per domain only (root can't share)

---

## During App Installation

### The Interactive Flow

When you install any app (e.g., Immich, Jellyfin, Open-WebUI), you'll see:

```bash
$ sudo ./scripts/apps/install-immich.sh

[App deploys to Kubernetes...]
[Gets LoadBalancer IP...]
[Registers in service registry...]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🌍 Public Access Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Do you want to make this app publicly accessible from the internet?

Options:
  1. Yes, make it public (expose via domain)
  2. No, keep it local-only (Tailscale VPN access only)
  3. Configure later

Choice (1/2/3): 
```

### Option 1: Make It Public ✅

**If you have multiple domains:**

```bash
Choice (1/2/3): 1

Available domains:
  1. curiios.com
  2. vinaysachdeva.com
  3. photos-app.com

Select domains (comma-separated numbers, 'all', or press Enter for all):
Selection: 1,2

How do you want to access this app?

  1. Use subdomain: photos.<domain> (e.g., photos.curiios.com)
  2. Use root domain: <domain> only (e.g., curiios.com)

Choice (1/2): 1

✓ Will use subdomain: photos
✓ Public routing configured
✓ Configuration pushed to VPS nodes

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Service Registered Successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Access via:
   • Local: http://photos.mycloud.local
   • Public: https://photos.curiios.com
   • Public: https://photos.vinaysachdeva.com
```

**Example with root domain:**
```bash
Choice (1/2/3): 1

Selection: 1  # Just curiios.com

How do you want to access this app?

  1. Use subdomain: photos.<domain> (e.g., photos.curiios.com)
  2. Use root domain: <domain> only (e.g., curiios.com)

Choice (1/2): 2

✓ Will use root domain (no subdomain)
✓ Public routing configured
✓ Configuration pushed to VPS nodes

Access via:
   • Local: http://mycloud.local (root domain not supported locally)
   • Public: https://curiios.com (root domain)
```

**What gets asked:**
1. ✅ Make public? (Yes/No/Later)
2. ✅ Which domain(s)? (Select from list)
3. ✅ **NEW! Subdomain or root domain?** (subdomain.domain.com vs domain.com)

**What happens:**
1. ✅ Script lists all registered domains from domain-registry
2. ✅ You select which domains to expose the app on
3. ✅ Can select one, multiple, or all domains
4. ✅ Routing configured in multi-domain registry
5. ✅ Service marked as `public=true`
6. ✅ Configuration pushed to all VPS nodes automatically
7. ✅ SSL certificates obtained automatically (within 5 minutes)

**If you have no domains yet:**

```bash
Choice (1/2/3): 1

No domains configured yet.

Enter your domain (e.g., example.com): mysite.com

✓ Domain registered: mysite.com
✓ Public routing configured
✓ Configuration pushed to VPS nodes

Access via:
   • Local: http://photos.mycloud.local
   • Public: https://photos.mysite.com
```

**What happens:**
1. ✅ Prompts you to enter your domain
2. ✅ Validates domain format
3. ✅ Registers domain in cluster
4. ✅ Saves to `~/.mynodeone/config.env` for future use
5. ✅ Configures routing
6. ✅ Pushes to VPS nodes

**If you have no VPS yet:**

```bash
Choice (1/2/3): 1

⚠  No VPS nodes registered yet

Domain will be registered, but you need a VPS to enable public access.

To complete setup:
  1. Install VPS edge node: sudo ./scripts/mynodeone → Option 3
  2. Then run: sudo ./scripts/manage-app-visibility.sh
```

**What happens:**
1. ✅ Domain still registered
2. ⚠️ Can't configure routing yet (no VPS)
3. ✅ Can complete setup after VPS installed

---

### Option 2: Keep It Private 🔒

```bash
Choice (1/2/3): 2

✓ App will be local-only (accessible via Tailscale VPN)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Service Registered Successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Access via:
   • Local: http://photos.mycloud.local

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📡 Accessing Your Service
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

From management laptops (after DNS sync):
  cd ~/MyNodeOne && sudo ./scripts/sync-dns.sh
  Then open: http://photos.mycloud.local

To make public later:
  sudo ./scripts/manage-app-visibility.sh
```

**What happens:**
1. ✅ Service marked as `public=false`
2. ✅ Only local DNS entry created
3. ✅ No public routing configured
4. ✅ Accessible via Tailscale VPN only
5. ✅ Can make public later with one command

**Best for:**
- Admin panels (Grafana, ArgoCD)
- Development/testing services
- Sensitive data apps
- Personal-only apps

---

### Option 3: Configure Later ⏰

```bash
Choice (1/2/3): 3

✓ You can configure public access later with:
  sudo ./scripts/manage-app-visibility.sh

Access via:
   • Local: http://photos.mycloud.local
```

**What happens:**
- Same as Option 2 (private)
- Shows command to configure later
- No rush to decide

---

## After App Installation

### Make App Public Later

If you chose "private" or "configure later" during installation, you can easily make it public:

```bash
sudo ./scripts/manage-app-visibility.sh
```

**Interactive wizard:**

```bash
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🌐 Manage App Public Visibility
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Available services:

  1. immich (photos) - 🔒 Private
  2. open-webui (chat) - 🌍 Public
  3. grafana (grafana) - 🔒 Private

Select service number: 1

Selected: immich (photos)
Current status: 🔒 Private (local-only)

What do you want to do?
  1. Make public (accessible from internet)
  2. Make private (local access only)
  3. Cancel

Choice: 1

[Shows domains, you select, configures, done!]
```

### Make App Private Again

Same script, choose option 2:

```bash
sudo ./scripts/manage-app-visibility.sh

Select service: 2 (open-webui)
Choice: 2 (Make private)

✓ Service is now private
✓ Routes removed from VPS
```

---

## Understanding the Flow

### What Happens Behind the Scenes

#### When You Choose "Make Public":

```
1. Query domain-registry
   ├─ Get list of registered domains
   └─ Show to user

2. User selects domain(s)
   └─ Validates selection

3. Configure multi-domain routing
   ├─ Update domain-registry ConfigMap
   ├─ Add service → domain mappings
   └─ Specify VPS nodes to use

4. Update service registry
   └─ Mark service as public=true

5. Trigger sync controller
   ├─ Push to all VPS nodes
   ├─ Generate Traefik routes
   ├─ Restart Traefik
   └─ Obtain SSL certificates

6. Verify configuration
   └─ Confirm routes applied
```

**Time:** ~30 seconds for complete propagation

#### When You Choose "Keep Private":

```
1. Register service in service-registry
   └─ Mark as public=false

2. Update local DNS only
   └─ Add to /etc/hosts on control plane

3. Skip public routing
   └─ No VPS configuration

4. Service accessible via Tailscale
   └─ http://subdomain.mycloud.local
```

**Time:** Instant

---

## Common Scenarios

### Scenario 1: First App, Have Domain and VPS

**Situation:** Clean install, already configured domain and VPS

```bash
sudo ./scripts/apps/install-immich.sh
Choice: 1 (Make public)
Domain: curiios.com (from registry)
Result: https://photos.curiios.com (works immediately)
```

**Timeline:**
- App deploys: 2-3 minutes
- Public config: 30 seconds
- SSL cert: 2-5 minutes
- **Total: ~8 minutes to fully public**

---

### Scenario 2: First App, No Domain Yet

**Situation:** Fresh cluster, no domains configured

```bash
sudo ./scripts/apps/install-immich.sh
Choice: 1 (Make public)
Enter domain: mysite.com
Result: Domain registered, routes configured
```

**Next step:** Add DNS records to your registrar

```
Type: A
Name: * (wildcard)
Value: <Your VPS Public IP>
TTL: 300
```

**Wait 15-30 minutes for DNS propagation**

Then access: `https://photos.mysite.com`

---

### Scenario 3: Multiple Apps, Same Domain

**Situation:** Installing multiple apps on one domain

```bash
# Install Immich
sudo ./scripts/apps/install-immich.sh
Choice: 1, Domain: curiios.com
Result: photos.curiios.com

# Install Open-WebUI
sudo ./scripts/apps/install-open-webui.sh
Choice: 1, Domain: curiios.com
Result: chat.curiios.com

# Install Jellyfin
sudo ./scripts/apps/install-jellyfin.sh
Choice: 1, Domain: curiios.com
Result: media.curiios.com
```

**All work on the same domain with different subdomains!**

---

### Scenario 4: Same App, Multiple Domains

**Situation:** Expose one app on multiple domains

```bash
sudo ./scripts/apps/install-immich.sh
Choice: 1
Domains: curiios.com, vinaysachdeva.com, photos-app.com
Result:
  - photos.curiios.com
  - photos.vinaysachdeva.com
  - photos.photos-app.com
```

**All URLs point to the same Immich instance!**

---

### Scenario 5: Start Private, Make Public Later

**Situation:** Not sure yet, decide later

```bash
# Install privately
sudo ./scripts/apps/install-immich.sh
Choice: 2 (Keep private)
Access: http://photos.mycloud.local

# Two weeks later, decide to share
sudo ./scripts/manage-app-visibility.sh
Select: immich
Choice: 1 (Make public)
Domains: curiios.com
Result: Now public at https://photos.curiios.com
```

---

### Scenario 6: Testing Locally First

**Situation:** Want to test before exposing

```bash
# Install
sudo ./scripts/apps/install-open-webui.sh
Choice: 2 (Keep private)

# Test locally
open http://chat.mycloud.local

# Everything works? Make public
sudo ./scripts/manage-app-visibility.sh
Select: open-webui
Choice: 1 (Make public)
```

**Best practice for new apps!**

---

### Scenario 7: Root Domain for Main Website

**Situation:** Want your app at root domain (no subdomain)

```bash
# Install Homepage as your main site
sudo ./scripts/apps/install-homepage.sh
Choice: 1 (Make public)
Domain: mysite.com
Subdomain or root: 2 (Root domain)

Result: https://mysite.com (no subdomain!)
```

**Perfect for:**
- Personal homepage/portfolio
- Blog as main site
- Business website
- Dedicated app domains

**Example setup:**
```
mysite.com              → Homepage (root)
photos.mysite.com       → Immich (subdomain)
blog.mysite.com         → Ghost (subdomain)

myportfolio.com         → Homepage (root, dedicated)
myblog.com              → Ghost (root, dedicated)
photos-app.com          → Immich (root, dedicated)
```

**Pro tip:** Buy separate domains for dedicated apps!

---

## Troubleshooting

### App Installed but Not Accessible

**Issue:** Installed app, can't access it

**Check:**

```bash
# 1. Is service running?
kubectl get svc -n <namespace>

# 2. Does it have LoadBalancer IP?
kubectl get svc -n immich immich-server
# Should show EXTERNAL-IP

# 3. Is it in service registry?
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | jq '.immich'

# 4. Is local DNS updated?
grep mycloud.local /etc/hosts
```

**Fix:**
```bash
# Resync everything
sudo ./scripts/lib/service-registry.sh sync
sudo ./scripts/sync-dns.sh
```

---

### Public URL Not Working

**Issue:** Made app public, but domain not accessible

**Check:**

```bash
# 1. DNS propagated?
dig photos.curiios.com
# Should return your VPS IP

# 2. Routes on VPS?
# SSH to VPS
cat /etc/traefik/dynamic/mynodeone-routes.yml | grep immich

# 3. Traefik running?
docker ps | grep traefik

# 4. SSL certificate obtained?
docker logs traefik | grep -i certificate
```

**Fix:**

```bash
# On control plane
sudo ./scripts/lib/sync-controller.sh push

# On VPS
sudo ./scripts/sync-vps-routes.sh
cd /etc/traefik && docker compose restart

# Wait 5 minutes for SSL cert
```

---

### Wrong Domain Selected

**Issue:** Chose wrong domain during installation

**Fix:**

```bash
# Remove from wrong domain
sudo ./scripts/configure-domain-routing.sh wrongdomain.com
Choice: 2 (Remove services)
Select: immich

# Add to correct domain
sudo ./scripts/configure-domain-routing.sh correctdomain.com
Choice: 1 (Add services)
Select: immich

# Or use manage-app-visibility.sh
sudo ./scripts/manage-app-visibility.sh
# Make private, then make public again with correct domain
```

---

### SSL Certificate Not Obtained

**Issue:** HTTP works, HTTPS doesn't

**Common causes:**
1. DNS not propagated yet (wait 30 min)
2. Port 80/443 blocked by firewall
3. Let's Encrypt rate limit (5/week per domain)

**Check:**

```bash
# On VPS
docker logs traefik 2>&1 | grep -i "acme\|certificate\|error"

# Check firewall
sudo ufw status | grep -E "80|443"

# Should see:
# 80/tcp ALLOW Anywhere
# 443/tcp ALLOW Anywhere
```

**Fix:**

```bash
# If ports blocked
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Force cert renewal
cd /etc/traefik && docker compose restart

# Check logs
docker logs -f traefik
```

---

### Made Public by Accident

**Issue:** Accidentally made sensitive app public

**Immediate fix:**

```bash
sudo ./scripts/manage-app-visibility.sh
Select: <app-name>
Choice: 2 (Make private)

# Verify
curl -I https://subdomain.yourdomain.com
# Should return error (no route)
```

Routes removed within 30 seconds!

---

## Best Practices

### 1. Start Private for Testing

**Recommendation:** Install apps privately first, test locally, then make public

```bash
# Install privately
sudo ./scripts/apps/install-<app>.sh
Choice: 2

# Test via VPN
open http://subdomain.mycloud.local

# Works? Make public
sudo ./scripts/manage-app-visibility.sh
```

---

### 2. Use Different Domains for Different Purposes

**Example:**

```
curiios.com → Personal apps
  - photos.curiios.com (Immich)
  - media.curiios.com (Jellyfin)

vinaysachdeva.com → Professional apps
  - portfolio.vinaysachdeva.com
  - blog.vinaysachdeva.com

admin.mysite.com → Admin tools (NOT PUBLIC)
  - grafana.mycloud.local
  - argocd.mycloud.local
```

---

### 3. Keep Admin Panels Private

**Never make these public:**
- Grafana
- ArgoCD
- Longhorn UI
- Any admin interface

**If you need remote access:**
- Use Tailscale VPN
- Or add authentication layer first

---

### 4. Regular Audits

**Monthly check:**

```bash
# View all public services
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | \
    jq -r 'to_entries[] | select(.value.public == true) | .key'

# Should this be public? If not:
sudo ./scripts/manage-app-visibility.sh
```

---

## Quick Reference

### Make App Public During Install

```bash
sudo ./scripts/apps/install-<app>.sh
# When prompted:
Choice: 1
Domains: Select from list or enter new
```

### Make App Public After Install

```bash
sudo ./scripts/manage-app-visibility.sh
# Select app
# Choose: Make public
# Select domains
```

### Make App Private

```bash
sudo ./scripts/manage-app-visibility.sh
# Select app
# Choose: Make private
```

### Change Which Domains App Is On

```bash
sudo ./scripts/configure-domain-routing.sh <domain>
# Add or remove services
```

### Check App Status

```bash
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | jq '.["<app-name>"]'
```

---

## Summary

**MyNodeOne gives you complete control:**

✅ **Clear choice during installation** - Public or private?  
✅ **Easy to change later** - One command to switch  
✅ **Multiple domains** - Expose on many domains  
✅ **Safe defaults** - Start private, go public when ready  
✅ **Automatic everything** - SSL, routing, DNS all handled  
✅ **No surprises** - You choose, system confirms  

**The flow is:**
1. Install app
2. Answer: Public or private?
3. If public: Which domain(s)?
4. Done! System configures everything

**Can always change with:**
```bash
sudo ./scripts/manage-app-visibility.sh
```

**Questions?** Check [OPERATIONS-GUIDE.md](OPERATIONS-GUIDE.md) for more details.
