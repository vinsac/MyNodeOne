# Domain Management Guide

## Overview

This guide covers how to manage multiple domains in your MyNodeOne cluster. Whether you're adding your first domain or your tenth, the process is simple and automated.

---

## Common Scenarios

### Scenario 1: Just Purchased a New Domain

**You bought `newdomain.com` and want to expose some apps through it.**

```bash
# On control plane
sudo ./scripts/add-domain.sh
```

**What it does:**
1. ✅ Registers domain in cluster
2. ✅ Lets you select which VPS nodes to use
3. ✅ Lets you select which services to expose
4. ✅ Pushes configuration to all VPS
5. ✅ Provides DNS setup instructions

**Interactive prompts:**
```
Enter your new domain: newdomain.com
Enter a description: My new website
Select VPS nodes: 1,2 (or 'all')
Select services to expose: 1,3,5 (or 'all' or 'none')
```

**Time to complete:** 2 minutes

---

### Scenario 2: Add More Services to Existing Domain

**You want to expose a new app on `newdomain.com` that you added last month.**

```bash
# On control plane
sudo ./scripts/configure-domain-routing.sh newdomain.com
```

**What it does:**
1. Shows services currently on the domain
2. Shows all available services
3. Lets you add or remove services
4. Pushes configuration automatically

**Example:**
```
Currently on newdomain.com:
  ✓ immich → https://photos.newdomain.com
  ✓ open-webui → https://chat.newdomain.com

Available services:
  1. immich (photos) [currently on newdomain.com]
  2. open-webui (chat) [currently on newdomain.com]
  3. grafana (grafana)
  4. homepage (home)

Select action:
  1. Add services
  2. Remove services

Choice: 1
Select services to ADD: 3,4

✓ Added grafana
✓ Added homepage

Services added to newdomain.com
```

---

### Scenario 3: Remove a Domain

**You no longer need `olddomain.com` or it expired.**

```bash
# On control plane
sudo ./scripts/remove-domain.sh olddomain.com
```

**What it does:**
1. Shows which services use this domain
2. Warns if services will lose public access
3. Asks for confirmation
4. Updates all routing
5. Pushes to VPS nodes

**Safety features:**
- Shows impact before removing
- Requires explicit confirmation (`yes`)
- Services on other domains are unaffected
- VPS nodes automatically updated

---

## Complete Workflow

### 1. Add Your First Domain

**One-time setup during cluster installation:**

```bash
# During control plane setup, you're prompted:
? Enter your public domain (optional): curiios.com

# Or add later
sudo ./scripts/add-domain.sh
```

### 2. Purchase Additional Domains

**As your project grows, you buy more domains:**

```bash
# Add each new domain
sudo ./scripts/add-domain.sh

Enter domain: vinaysachdeva.com
Description: Professional portfolio
Select VPS: all
Select services: 1,2,3
```

**Result:**
```
✓ Domain registered
✓ Routing configured
✓ VPS updated

Add these DNS records:
  Type: A
  Name: *
  Value: 45.8.133.192
  TTL: 300
```

### 3. Manage Service Exposure

**Control which apps are accessible on which domains:**

```bash
# Service available on multiple domains
sudo ./scripts/lib/multi-domain-registry.sh configure-routing immich \
    "curiios.com,vinaysachdeva.com,newdomain.com" \
    "100.68.225.92,100.70.123.45" \
    round-robin
```

**Result:**
- `photos.curiios.com` → Works ✓
- `photos.vinaysachdeva.com` → Works ✓
- `photos.newdomain.com` → Works ✓

All pointing to the same Immich instance!

---

## DNS Configuration

### Initial Setup

When you add a domain, you get specific DNS instructions:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  📋 Configure DNS Records
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Add these records to your domain registrar:

VPS: 100.68.225.92 (Public IP: 45.8.133.192)

  Option 1: Wildcard (covers all services)
    Type: A
    Name: *
    Value: 45.8.133.192
    TTL: 300

  Option 2: Specific services
    Type: A, Name: photos, Value: 45.8.133.192
    Type: A, Name: chat, Value: 45.8.133.192
    Type: A, Name: grafana, Value: 45.8.133.192
```

### DNS Propagation

- **Time:** 5-30 minutes typically
- **Check status:** `dig photos.newdomain.com`
- **SSL certs:** Automatically obtained once DNS resolves

---

## Multi-VPS Strategies

### Round-Robin (Load Balancing)

**Use case:** Distribute traffic across multiple VPS

```bash
sudo ./scripts/add-domain.sh

Domain: newdomain.com
VPS nodes: all (or 1,2,3)
Services: 1,2,3
```

**Result:**
- `photos.newdomain.com` → VPS1 (EU)
- `chat.newdomain.com` → VPS2 (US)
- Traffic distributed geographically

**DNS Setup:**
```
# Add A records pointing to different VPS
photos.newdomain.com → 45.8.133.192 (VPS1 EU)
chat.newdomain.com → 167.99.1.1 (VPS2 US)
```

### Primary-Backup (Failover)

**Use case:** High availability with backup VPS

```bash
sudo ./scripts/lib/multi-domain-registry.sh configure-routing chat \
    "newdomain.com" \
    "100.68.225.92,100.70.123.45" \
    primary-backup
```

**Result:**
- Primary: VPS1 serves traffic
- Backup: VPS2 ready if VPS1 fails

---

## Common Tasks

### List All Domains

```bash
sudo ./scripts/lib/multi-domain-registry.sh show
```

**Output:**
```
Registered Domains:
  • curiios.com: Personal site
  • vinaysachdeva.com: Professional site
  • newdomain.com: New project

VPS Nodes:
  • 100.68.225.92 → 45.8.133.192 (eu/contabo)
  • 100.70.123.45 → 167.99.1.1 (us/digitalocean)

Service Routing:
  • immich:
    Domains: curiios.com, vinaysachdeva.com
    VPS: 100.68.225.92, 100.70.123.45
    Strategy: round-robin
```

### Check Which Services Are Public

```bash
kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' | jq -r 'to_entries[] | select(.value.public == true) | .key'
```

### Test Domain Access

```bash
# Check DNS resolution
dig photos.newdomain.com

# Test HTTP access
curl -I https://photos.newdomain.com

# Check SSL certificate
openssl s_client -connect photos.newdomain.com:443 -servername photos.newdomain.com
```

---

## Troubleshooting

### Domain Added But Not Working

**1. Check DNS propagation:**
```bash
dig photos.newdomain.com
# Should return your VPS public IP
```

**2. Check VPS routing:**
```bash
# On VPS
cat /etc/traefik/dynamic/mynodeone-routes.yml | grep newdomain.com
```

**3. Check Traefik logs:**
```bash
# On VPS
docker logs traefik | grep newdomain.com
```

**4. Force sync:**
```bash
# On control plane
sudo ./scripts/lib/sync-controller.sh push

# Or on VPS directly
sudo ./scripts/sync-vps-routes.sh
```

### SSL Certificate Not Obtained

**Common causes:**
1. DNS not propagated yet (wait 30 minutes)
2. Port 80/443 not open (check firewall)
3. Domain pointing to wrong IP

**Check Traefik logs:**
```bash
docker logs traefik | grep -i "acme\|certificate"
```

**Manual cert renewal:**
```bash
# On VPS
cd /etc/traefik && docker compose restart
```

### Service Shows on Domain List But Not Accessible

**1. Check service is running:**
```bash
kubectl get svc -n <namespace>
kubectl get pods -n <namespace>
```

**2. Check LoadBalancer IP:**
```bash
kubectl get svc -n immich immich-server
# Should have EXTERNAL-IP assigned
```

**3. Re-sync configuration:**
```bash
sudo ./scripts/lib/sync-controller.sh push
```

---

## Advanced Scenarios

### Different Apps on Different Domains

**Use case:** Separate personal and professional services

```bash
# Personal apps on curiios.com
sudo ./scripts/configure-domain-routing.sh curiios.com
# Add: immich, jellyfin, nextcloud

# Professional apps on vinaysachdeva.com
sudo ./scripts/configure-domain-routing.sh vinaysachdeva.com
# Add: open-webui, grafana, homepage
```

**Result:**
- `photos.curiios.com` → Immich
- `chat.vinaysachdeva.com` → OpenWebUI
- Clear separation of use cases

### Multiple Domains for Same Service

**Use case:** Brand consistency across domains

```bash
sudo ./scripts/lib/multi-domain-registry.sh configure-routing immich \
    "curiios.com,vinaysachdeva.com,photos-app.com" \
    "100.68.225.92" \
    round-robin
```

**Result:**
- `photos.curiios.com` → Same Immich
- `photos.vinaysachdeva.com` → Same Immich
- `photos.photos-app.com` → Same Immich

All URLs work, same service!

### Geographic Distribution

**Use case:** Serve users from nearest VPS

```bash
# EU VPS for European domain
sudo ./scripts/lib/multi-domain-registry.sh configure-routing immich \
    "europe.myapp.com" \
    "100.68.225.92" \
    round-robin

# US VPS for American domain
sudo ./scripts/lib/multi-domain-registry.sh configure-routing immich \
    "usa.myapp.com" \
    "100.70.123.45" \
    round-robin
```

---

## Best Practices

### 1. Use Wildcard DNS

**Recommendation:** Add wildcard A record for each domain

```
Type: A
Name: *
Value: <VPS Public IP>
TTL: 300
```

**Benefits:**
- New services automatically work
- No DNS changes needed per service
- Faster deployment

### 2. Start with Fewer Domains

**Recommendation:** Begin with 1-2 domains, add more as needed

**Rationale:**
- Easier to manage
- Lower cost
- Can always add more later

### 3. Document Your Domains

**Keep track of:**
- Which domain is for what purpose
- Renewal dates
- DNS registrar login
- SSL certificate status

### 4. Use Descriptive Descriptions

```bash
# Good
sudo ./scripts/add-domain.sh
Description: Personal blog and photos

# Better
Description: Personal blog, photo gallery, expires 2026-03-15
```

### 5. Regular Audits

**Monthly check:**
```bash
# Review all domains
sudo ./scripts/lib/multi-domain-registry.sh show

# Remove unused domains
sudo ./scripts/remove-domain.sh <unused-domain>
```

---

## Quick Reference

### Add Domain
```bash
sudo ./scripts/add-domain.sh
```

### Configure Services on Domain
```bash
sudo ./scripts/configure-domain-routing.sh <domain>
```

### Remove Domain
```bash
sudo ./scripts/remove-domain.sh <domain>
```

### View All Domains
```bash
sudo ./scripts/lib/multi-domain-registry.sh show
```

### Force Sync to VPS
```bash
sudo ./scripts/lib/sync-controller.sh push
```

---

## Summary

**Domain management is:**
- ✅ Simple (interactive scripts)
- ✅ Flexible (add/remove anytime)
- ✅ Automated (auto-sync to VPS)
- ✅ Safe (confirmation required)
- ✅ Scalable (unlimited domains)

**Common pattern:**
1. Buy domain
2. Run `sudo ./scripts/add-domain.sh`
3. Add DNS records
4. Wait 15 minutes
5. Access via `https://subdomain.domain.com`

**Questions?** Check the troubleshooting section or run scripts with `-h` flag.
