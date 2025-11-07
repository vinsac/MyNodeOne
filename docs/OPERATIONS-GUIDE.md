### # MyNodeOne Operations Guide

**Complete guide for all common operations**

---

## Table of Contents

1. [Installation & Setup](#installation--setup)
2. [App Management](#app-management)
3. [Domain Management](#domain-management)
4. [Access Control](#access-control)
5. [Monitoring & Troubleshooting](#monitoring--troubleshooting)
6. [Maintenance](#maintenance)

---

## Installation & Setup

### One-Click Installation

All installations are fully automated - just run the script and follow prompts.

#### Install Control Plane (First Time)

```bash
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: 1 (Control Plane)
```

**What happens automatically:**
- ✅ Installs K3s, Tailscale, all services
- ✅ Initializes service registry
- ✅ Initializes multi-domain registry
- ✅ Installs sync controller as systemd service
- ✅ Discovers and registers all services
- ✅ Updates local DNS

**No manual steps required!**

---

#### Add VPS Edge Node

```bash
# On VPS
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: 3 (VPS Edge Node)
```

**What happens automatically:**
- ✅ Installs Tailscale, Docker, Traefik
- ✅ Configures firewall
- ✅ Auto-detects VPS details (IP, provider, region)
- ✅ Registers in multi-domain registry
- ✅ Registers in sync controller
- ✅ Runs initial route sync
- ✅ Configured for auto-updates

**No manual steps required!**

---

#### Setup Management Laptop

```bash
# On laptop
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: 4 (Management Workstation)
```

**What happens automatically:**
- ✅ Installs kubectl
- ✅ Fetches kubeconfig
- ✅ Validates cluster access
- ✅ Updates local DNS (/etc/hosts)
- ✅ Registers in sync controller
- ✅ Runs initial DNS sync
- ✅ Configured for auto-updates

**No manual steps required!**

---

#### Upgrade Existing Cluster to Enterprise Registry

```bash
# On control plane
cd ~/MyNodeOne
git pull origin main
sudo ./scripts/setup-enterprise-registry.sh
```

**One command** upgrades your existing cluster to enterprise features!

---

## App Management

### Install App

```bash
# On control plane
sudo ./scripts/apps/install-<app-name>.sh

# Examples:
sudo ./scripts/apps/install-immich.sh      # Photo management
sudo ./scripts/apps/install-open-webui.sh  # AI chat
sudo ./scripts/apps/install-jellyfin.sh    # Media server
```

**Interactive public access configuration:**

During installation, you'll be asked:

```
Do you want to make this app publicly accessible from the internet?

Options:
  1. Yes, make it public (expose via domain)
  2. No, keep it local-only (Tailscale VPN access only)
  3. Configure later
```

**If you choose "Yes":**
- ✅ Select which domain(s) to use
- ✅ Routing configured automatically
- ✅ Pushed to all VPS nodes within 30s
- ✅ SSL certificates obtained automatically

**See full guide:** [APP-PUBLIC-ACCESS.md](APP-PUBLIC-ACCESS.md)

**No manual routing or DNS configuration needed!**

---

### Make App Publicly Accessible

**Scenario:** You installed an app, but it's private. Now you want it public.

```bash
sudo ./scripts/manage-app-visibility.sh
```

**Interactive wizard:**
1. Select app
2. Choose "Make public"
3. Select domains
4. Select VPS nodes
5. Done! Auto-synced to all VPS

**Command-line mode:**
```bash
sudo ./scripts/manage-app-visibility.sh public immich \
    "curiios.com,vinaysachdeva.com" \
    "100.68.225.92"
```

---

### Take App Offline (Make Private)

**Scenario:** You want to stop public access, keep local access.

```bash
sudo ./scripts/manage-app-visibility.sh
```

**Interactive wizard:**
1. Select app
2. Choose "Make private"
3. Confirm
4. Done! Routes removed from all VPS

**Command-line mode:**
```bash
sudo ./scripts/manage-app-visibility.sh private immich
```

---

### List All Apps

```bash
sudo ./scripts/lib/service-registry.sh list
```

**Output:**
```
Available services:
  • immich (photos) - 100.122.68.209:80 - Public ✓
  • open-webui (chat) - 100.122.68.208:80 - Public ✓
  • grafana (grafana) - 100.122.68.204:80 - Private
```

---

### Uninstall App

```bash
# Most apps have uninstall scripts
sudo ./scripts/apps/uninstall-<app-name>.sh

# Manual cleanup
kubectl delete namespace <app-namespace>

# Remove from registry
sudo ./scripts/lib/service-registry.sh sync
```

---

## Domain Management

### Add New Domain

**Scenario:** You purchased `newdomain.com`

```bash
sudo ./scripts/add-domain.sh
```

**Interactive wizard:**
1. Enter domain name
2. Select VPS nodes
3. Select services to expose
4. Get DNS setup instructions
5. Done!

**Time:** 2 minutes

---

### Add Services to Existing Domain

**Scenario:** Expose more apps on `newdomain.com`

```bash
sudo ./scripts/configure-domain-routing.sh newdomain.com
```

**Interactive wizard:**
1. Shows current services on domain
2. Select "Add services"
3. Pick services
4. Done! Auto-synced

---

### Remove Domain

**Scenario:** Domain expired or no longer needed

```bash
sudo ./scripts/remove-domain.sh olddomain.com
```

**Safety features:**
- Shows impact before removal
- Requires confirmation
- Updates all routing
- Syncs to VPS automatically

---

### List All Domains

```bash
sudo ./scripts/lib/multi-domain-registry.sh show
```

**Output:**
```
Registered Domains:
  • curiios.com: Personal site
  • vinaysachdeva.com: Professional site

VPS Nodes:
  • 100.68.225.92 → 45.8.133.192 (eu/contabo)

Service Routing:
  • immich: curiios.com, vinaysachdeva.com
```

---

## Access Control

### Check Service Status

```bash
# View all services
kubectl get svc -A

# Check specific service
kubectl get svc -n immich immich-server

# Check if public
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | \
    jq '.immich.public'
```

---

### View Current Public Services

```bash
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | \
    jq -r 'to_entries[] | select(.value.public == true) | .key'
```

---

### Test Service Access

```bash
# Test local access
curl -I http://photos.mycloud.local

# Test public access
curl -I https://photos.curiios.com

# Check DNS resolution
dig photos.curiios.com

# Check SSL certificate
echo | openssl s_client -connect photos.curiios.com:443 -servername photos.curiios.com 2>/dev/null | openssl x509 -noout -dates
```

---

## Monitoring & Troubleshooting

### Check Sync Controller Status

```bash
# On control plane
sudo systemctl status mynodeone-sync-controller

# View logs
sudo journalctl -u mynodeone-sync-controller -f

# Check health of all nodes
sudo ./scripts/lib/sync-controller.sh health
```

**Output:**
```
Node Health Status

Management Laptops:
  • vinay-laptop: active (last sync: 2025-11-06T20:30:00Z)

VPS Edge Nodes:
  • contabo-vps: active (last sync: 2025-11-06T20:30:05Z)
```

---

### Manual Sync

**If auto-sync fails or you want immediate update:**

```bash
# Force sync to all nodes
sudo ./scripts/lib/sync-controller.sh push

# Sync specific laptop
sudo ./scripts/sync-dns.sh

# Sync specific VPS
sudo ./scripts/sync-vps-routes.sh
```

---

### Check Service Registry

```bash
# View entire registry
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | jq '.'

# Resync from cluster state
sudo ./scripts/lib/service-registry.sh sync
```

---

### View Traefik Routes (on VPS)

```bash
# View generated routes
cat /etc/traefik/dynamic/mynodeone-routes.yml

# Check Traefik logs
docker logs traefik | tail -100

# Test route
curl -I https://photos.curiios.com
```

---

### Common Issues & Fixes

#### Issue: App installed but not accessible

**Check:**
1. Service has LoadBalancer IP?
   ```bash
   kubectl get svc -n <namespace>
   ```

2. Registered in service registry?
   ```bash
   sudo ./scripts/lib/service-registry.sh list | grep <app-name>
   ```

3. DNS updated on laptop?
   ```bash
   grep mycloud.local /etc/hosts
   ```

**Fix:**
```bash
# Resync everything
sudo ./scripts/lib/service-registry.sh sync
sudo ./scripts/lib/sync-controller.sh push
sudo ./scripts/sync-dns.sh  # On laptop
```

---

#### Issue: Domain not working

**Check:**
1. DNS propagated?
   ```bash
   dig photos.newdomain.com
   ```

2. VPS has routes?
   ```bash
   # On VPS
   cat /etc/traefik/dynamic/mynodeone-routes.yml | grep newdomain
   ```

3. Traefik running?
   ```bash
   # On VPS
   docker ps | grep traefik
   ```

**Fix:**
```bash
# On control plane
sudo ./scripts/lib/sync-controller.sh push

# On VPS
sudo ./scripts/sync-vps-routes.sh
cd /etc/traefik && docker compose restart
```

---

#### Issue: SSL certificate not obtained

**Common causes:**
- DNS not propagated (wait 30 min)
- Port 80/443 blocked (check firewall)
- Let's Encrypt rate limit (5 certs/week per domain)

**Check:**
```bash
# On VPS
docker logs traefik | grep -i "certificate\|acme"
```

**Fix:**
```bash
# Wait for DNS propagation
dig photos.newdomain.com

# Restart Traefik
cd /etc/traefik && docker compose restart

# Check firewall
sudo ufw status
```

---

#### Issue: Sync controller not running

**Check:**
```bash
sudo systemctl status mynodeone-sync-controller
```

**Fix:**
```bash
# Restart
sudo systemctl restart mynodeone-sync-controller

# View logs for errors
sudo journalctl -u mynodeone-sync-controller -n 50

# Reinstall if needed
sudo cp ~/MyNodeOne/systemd/mynodeone-sync-controller.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart mynodeone-sync-controller
```

---

## Maintenance

### Regular Tasks

#### Weekly: Check Node Health

```bash
sudo ./scripts/lib/sync-controller.sh health
```

---

#### Monthly: Audit Services & Domains

```bash
# List all services
sudo ./scripts/lib/service-registry.sh list

# List all domains
sudo ./scripts/lib/multi-domain-registry.sh show

# Remove unused services/domains
sudo ./scripts/remove-domain.sh <old-domain>
```

---

#### As Needed: Backup Configuration

```bash
# Backup service registry
kubectl get configmap -n kube-system service-registry -o yaml > service-registry-backup.yaml

# Backup domain registry
kubectl get configmap -n kube-system domain-registry -o yaml > domain-registry-backup.yaml

# Backup node registry
cp ~/.mynodeone/node-registry.json ~/.mynodeone/node-registry-backup.json
```

---

#### As Needed: Restore Configuration

```bash
# Restore from backup
kubectl apply -f service-registry-backup.yaml
kubectl apply -f domain-registry-backup.yaml

# Force sync
sudo ./scripts/lib/sync-controller.sh push
```

---

### Update MyNodeOne

```bash
# On all machines (control plane, VPS, laptops)
cd ~/MyNodeOne
git pull origin main

# Restart sync controller (control plane only)
sudo systemctl restart mynodeone-sync-controller
```

---

### Add More VPS Nodes

**As your traffic grows:**

```bash
# Setup new VPS
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: 3 (VPS Edge Node)

# Auto-registers and receives routing!
```

---

### Add More Management Laptops

**Team members joining:**

```bash
# On new laptop
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: 4 (Management Workstation)

# Auto-registers and receives DNS updates!
```

---

## Quick Reference

### Common Commands

```bash
# INSTALLATION
sudo ./scripts/mynodeone                                    # Main menu

# APP MANAGEMENT
sudo ./scripts/apps/install-<app>.sh                       # Install app
sudo ./scripts/manage-app-visibility.sh                    # Make app public/private
sudo ./scripts/lib/service-registry.sh list                # List all apps

# DOMAIN MANAGEMENT
sudo ./scripts/add-domain.sh                               # Add new domain
sudo ./scripts/configure-domain-routing.sh <domain>        # Manage services on domain
sudo ./scripts/remove-domain.sh <domain>                   # Remove domain
sudo ./scripts/lib/multi-domain-registry.sh show           # List all domains

# SYNC & MONITORING
sudo ./scripts/lib/sync-controller.sh push                 # Force sync to all nodes
sudo ./scripts/lib/sync-controller.sh health               # Check node health
sudo systemctl status mynodeone-sync-controller            # Check controller status
sudo journalctl -u mynodeone-sync-controller -f            # View controller logs

# MANUAL SYNC (if needed)
sudo ./scripts/sync-dns.sh                                 # Sync DNS on laptop
sudo ./scripts/sync-vps-routes.sh                          # Sync routes on VPS

# TROUBLESHOOTING
kubectl get svc -A                                         # List all services
kubectl get pods -A                                        # List all pods
kubectl logs -n <namespace> <pod-name>                     # View pod logs
dig <subdomain>.<domain>                                   # Check DNS
curl -I https://<subdomain>.<domain>                       # Test HTTPS access
```

---

### File Locations

```
~/.mynodeone/config.env                                    # User configuration
~/.mynodeone/node-registry.json                            # Registered nodes
~/.kube/config                                             # Kubernetes config
/etc/rancher/k3s/k3s.yaml                                  # K3s config (control plane)
/etc/traefik/                                              # Traefik config (VPS)
/etc/traefik/dynamic/mynodeone-routes.yml                  # Dynamic routes (VPS)
```

---

### Important Services

```
# Control Plane
sudo systemctl status k3s                                  # Kubernetes
sudo systemctl status mynodeone-sync-controller            # Sync controller

# VPS
docker ps                                                  # Running containers
cd /etc/traefik && docker compose logs -f                  # Traefik logs

# All Nodes
sudo systemctl status tailscale                            # VPN status
```

---

## Getting Help

1. **Check Logs:**
   - Sync controller: `sudo journalctl -u mynodeone-sync-controller -f`
   - Traefik (VPS): `docker logs traefik -f`
   - K3s: `sudo journalctl -u k3s -f`

2. **Manual Sync:**
   - Force push: `sudo ./scripts/lib/sync-controller.sh push`
   - Laptop DNS: `sudo ./scripts/sync-dns.sh`
   - VPS routes: `sudo ./scripts/sync-vps-routes.sh`

3. **Verify State:**
   - Services: `sudo ./scripts/lib/service-registry.sh list`
   - Domains: `sudo ./scripts/lib/multi-domain-registry.sh show`
   - Nodes: `sudo ./scripts/lib/sync-controller.sh health`

4. **Documentation:**
   - Domain Management: `docs/DOMAIN-MANAGEMENT.md`
   - Enterprise Setup: `docs/ENTERPRISE-SETUP.md`
   - Operations Guide: `docs/OPERATIONS-GUIDE.md` (this file)

---

## Summary

**MyNodeOne is designed for one-click operations:**

✅ **Installation:** Run script, follow prompts, done
✅ **Apps:** Install → Auto-registered → Auto-synced
✅ **Domains:** Add → Select services → DNS instructions → Done
✅ **Visibility:** Make public/private with one script
✅ **Sync:** Automatic push to all nodes within 30s
✅ **Monitoring:** Health checks and logs available
✅ **Scaling:** Add VPS/laptops → Auto-configured

**Everything is automated. No manual kubectl/SSH needed for daily operations!**
