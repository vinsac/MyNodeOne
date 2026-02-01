# Domain & DNS Management Scripts

This directory contains scripts for managing domains, DNS configuration, and name resolution across the cluster.

---

## Quick Start: Which Script Should I Use?

### **Primary Tools** (Recommended)
| **Task** | **Script** | **When to Use** |
|----------|------------|----------------|
| **Manage Visibility** | `manage-app-visibility.sh` | **Best** - Interactive menu for local_name and public exposure |
| **Domain Operations** | `multi-domain-registry.sh` | **Best** - All-in-one tool for domains, VPS, and routing |
| **Check DNS** | `check-dns-ready.sh` | **Standard** - Validate DNS configuration |

### **Legacy/Wrapper Scripts**
| **Task** | **Script** | **When to Use** |
|----------|------------|----------------|
| **Add base domain** | `add-domain.sh` | Wrapper for `multi-domain-registry.sh register-domain` |
| **Remove domain** | `remove-domain.sh` | Wrapper for `multi-domain-registry.sh unregister-domain` |
| **Configure routing** | `configure-domain-routing.sh` | Legacy - Use `manage-app-visibility.sh` instead |

---

## Script Documentation

### `add-domain.sh`
**Interactive domain addition with SSL setup**

**Usage:**
```bash
sudo ./scripts/domains/add-domain.sh
```

**Features:**
- Interactive domain registration
- Automatic SSL certificate setup (Let's Encrypt)
- VPS edge node selection
- Service routing configuration
- DNS validation

**When to use:** Adding a single domain to your cluster

---

### `remove-domain.sh`
**Safe domain removal with cleanup**

**Usage:**
```bash
sudo ./scripts/domains/remove-domain.sh <domain>
```

**Features:**
- Complete domain cleanup
- Service routing updates
- SSL certificate removal
- Safety checks

**When to use:** Removing a domain from your cluster

---

### `configure-domain-routing.sh`
**Interactive service routing configuration**

**Usage:**
```bash
sudo ./scripts/domains/configure-domain-routing.sh <domain>
```

**Features:**
- Service-to-domain mapping
- Service selection interface
- Automatic routing updates

**When to use:** Managing which services are accessible via a domain

---

### `multi-domain-registry.sh`
**Advanced multi-domain and multi-VPS management**

**Usage:**
```bash
sudo ./scripts/domains/multi-domain-registry.sh <command> [options]
```

**Features:**
- Multiple domain management
- Load balancing across VPS nodes
- Advanced routing strategies
- Registry inspection and export
- Programmatic access

**When to use:** Complex setups with multiple domains and VPS nodes

**Documentation:** See [MULTI-DOMAIN-REGISTRY.md](MULTI-DOMAIN-REGISTRY.md) for complete reference

---

## DNS Configuration Scripts

### `setup-local-dns.sh`
**Configure local DNS resolution for .local domains**

**Usage:**
```bash
sudo ./scripts/domains/setup-local-dns.sh
```

**Features:**
- Local domain resolution
- Tailscale network integration
- Automatic CoreDNS configuration

---

### `sync-dns.sh`
**Manual DNS synchronization (troubleshooting)**

**Usage:**
```bash
sudo ./scripts/domains/sync-dns.sh
```

**Features:**
- Force DNS synchronization
- Manual troubleshooting
- Immediate updates

**Note:** DNS sync is automatic via node agent. Use this for troubleshooting only.

---

### `configure-app-dns.sh`
**Configure DNS entries for deployed applications**

**Usage:**
```bash
sudo ./scripts/domains/configure-app-dns.sh
```

**Features:**
- App-specific DNS setup
- Automatic service discovery
- Domain mapping

---

## DNS Troubleshooting Scripts

### `check-dns-ready.sh`
**Verify DNS configuration and propagation**

**Usage:**
```bash
./scripts/domains/check-dns-ready.sh <domain>
```

**Features:**
- DNS validation
- Propagation checking
- Resolution testing

---

### `fix-duplicate-dns.sh`
**Fix duplicate DNS entries in CoreDNS**

**Usage:**
```bash
sudo ./scripts/domains/fix-duplicate-dns.sh
```

**Features:**
- Duplicate entry cleanup
- CoreDNS configuration repair

---

### `fix-tailscale-dns-permanent.sh`
**Permanently fix Tailscale DNS conflicts**

**Usage:**
```bash
sudo ./scripts/domains/fix-tailscale-dns-permanent.sh
```

**Features:**
- Tailscale DNS conflict resolution
- Permanent fixes

---

### `coredns-dns-guardian.sh`
**Monitor and auto-fix DNS issues (daemon mode)**

**Usage:**
```bash
sudo ./scripts/domains/coredns-dns-guardian.sh
```

**Features:**
- Continuous DNS monitoring
- Automatic issue resolution
- Health reporting

---

## Workflow Examples

### **Example 1: Add Your First Domain**

```bash
# 1. Configure DNS at your registrar
# Add A records: @ and * pointing to your VPS public IP

# 2. Add domain to cluster
sudo ./scripts/domains/add-domain.sh
# Follow prompts for domain name, VPS selection, SSL email

# 3. Verify DNS propagation
./scripts/domains/check-dns-ready.sh yourdomain.com

# 4. Configure services for the domain
sudo ./scripts/domains/configure-domain-routing.sh yourdomain.com
```

### **Example 2: Advanced Multi-Domain Setup**

```bash
# 1. Initialize multi-domain registry
sudo ./scripts/domains/multi-domain-registry.sh init

# 2. Register base domains
sudo ./scripts/domains/multi-domain-registry.sh register-domain example.com "Main site"
sudo ./scripts/domains/multi-domain-registry.sh register-domain test.org "Test site"

# 3. Register VPS nodes
sudo ./scripts/domains/multi-domain-registry.sh register-vps 100.68.225.92 192.0.2.100 eu contabo

# 4. Configure exposure (root + www + subdomain)
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,www.example.com,photos.test.org" "100.68.225.92"

# 5. View configuration
sudo ./scripts/domains/multi-domain-registry.sh show
```

### **Example 3: Troubleshooting DNS Issues**

```bash
# 1. Check DNS resolution
./scripts/domains/check-dns-ready.sh yourdomain.com

# 2. Fix duplicate entries if needed
sudo ./scripts/domains/fix-duplicate-dns.sh

# 3. Force manual sync
sudo ./scripts/domains/sync-dns.sh

# 4. Start DNS guardian for monitoring
sudo ./scripts/domains/coredns-dns-guardian.sh
```

---

## Complete Documentation

- **[MULTI-DOMAIN-REGISTRY.md](/scripts/domains/MULTI-DOMAIN-REGISTRY.md)** - Advanced multi-domain management
- **[DOMAIN-AND-PUBLIC-ACCESS.md](/docs/operations/DOMAIN-AND-PUBLIC-ACCESS.md)** - Complete domain setup guide
- **[MULTI-DOMAIN-SETUP.md](/docs/operations/MULTI-DOMAIN-SETUP.md)** - Multi-domain architecture
- **[INSTALLATION.md](/docs/installation/INSTALLATION.md)** - VPS edge node setup

---

## Important Notes

- **DNS Propagation**: Changes may take 5-60 minutes to propagate globally
- **Local Domains**: `.local` domains work only within Tailscale network
- **Public Domains**: Require VPS edge node for internet access
- **SSL Certificates**: Automatically managed by Let's Encrypt
- **Automatic Sync**: DNS changes sync automatically via node agent
- **Validation**: Always use `check-dns-ready.sh` to verify configuration

---

## Getting Help

```bash
# Check domain registry status
sudo ./scripts/domains/multi-domain-registry.sh show

# Verify DNS configuration
./scripts/domains/check-dns-ready.sh yourdomain.com

# View DNS logs
sudo journalctl -u coredns -f

# Check sync controller status
sudo systemctl status mynodeone-sync-controller
```

---

## Related Scripts

- **`../lib/sync-controller.sh`** - Automatic synchronization
- **`../lib/service-registry.sh`** - Service registration
- **`../vps/sync-vps-routes.sh`** - VPS route synchronization
- **`../nodes/nodes-status.sh`** - Node status monitoring