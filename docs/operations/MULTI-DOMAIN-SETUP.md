# Multi-Domain and Multi-VPS Setup

Advanced configuration for running MyNodeOne with multiple domains and VPS edge nodes.

---

## Overview

MyNodeOne supports:
- Multiple domains (e.g., `example.com`, `test.org`)
- Multiple VPS edge nodes for load balancing and failover
- Automatic sync across all nodes via the sync controller

```
Control Plane
     │
     ├── App Installed → Service Registry Updated
     │         │
     │         ▼
     │   ConfigMap Change Detected
     │         │
     │         ▼
     │   Sync Controller Pushes to All Nodes
     │         │
     ├─────────┼─────────┬─────────┐
     ▼         ▼         ▼         ▼
  Laptop1   Laptop2    VPS1      VPS2
  (DNS)     (DNS)    (routes)  (routes)
```

---

## Initial Setup

### 1. Initialize Registries

```bash
cd ~/MyNodeOne

# Initialize registries
sudo ./scripts/lib/service-registry.sh init
sudo ./scripts/domains/multi-domain-registry.sh init

# Sync existing services
sudo ./scripts/lib/service-registry.sh sync
```

### 2. Register Domains

```bash
sudo ./scripts/domains/multi-domain-registry.sh register-domain example.com "Main site"
sudo ./scripts/domains/multi-domain-registry.sh register-domain test.org "Test site"
```

### 3. Register VPS Nodes

```bash
# Format: register-vps <tailscale_ip> <public_ip> <region> <provider>
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.68.225.92 192.0.2.100 eu contabo

sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.70.123.45 167.99.1.1 us digitalocean
```

### 4. Verify Node Sync Status

Nodes automatically register via the Node Agent heartbeat system. Check status:

```bash
# View all nodes and their sync status (requires sudo)
sudo ./scripts/nodes/nodes-status.sh
```

> **Note:** The Node Agent (HTTP-based sync) is the primary mechanism. Each node pulls config from the control plane and sends heartbeats. SSH-based sync is only used as a fallback if the Node Agent is not working on a node.

---

## Service Routing

### Configure Routing Strategy

```bash
# Format: configure-routing <service> "<full_domains>" "<vps_ips>"
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,www.example.com,photos.test.org" \
    "100.68.225.92,100.70.123.45"
```

**Key Architectural Changes:**
1. **Full Domains**: No more pattern concatenation. Provide the exact FQDN (Fully Qualified Domain Name) you want to use.
2. **`expose` vs `domains`**: The registry now uses the `expose` key to store a list of full URLs.
3. **VPS Nodes**: VPS nodes currently act as a cluster of edge proxies. Every configured VPS node fetches all routes. High availability is achieved by adding multiple A records in your DNS pointing to your different VPS IPs.

### Load Balancing Flow
1. **DNS Level**: You add multiple A records (e.g., `photos.example.com` -> VPS1, VPS2).
2. **Edge Proxy**: Traffic hits a VPS. Traefik matches the Host header against the `expose` array.
3. **Tunnel**: Traffic is forwarded to the control plane via Tailscale.
4. **Target**: Cluster LoadBalancer sends traffic to the app pod.

---

## Domain Management Commands

The `multi-domain-registry.sh` script now supports granular domain management:

```bash
# Add a single domain to an existing service
sudo ./scripts/domains/multi-domain-registry.sh add-domain immich "new-link.com"

# Remove a single domain
sudo ./scripts/domains/multi-domain-registry.sh remove-domain immich "old-link.com"

# List all domains for a service
sudo ./scripts/domains/multi-domain-registry.sh list-domains immich
```

---

## View Configuration

```bash
sudo ./scripts/domains/multi-domain-registry.sh show
```

Output:
```
Multi-Domain, Multi-VPS Configuration

Registered Domains:
  - example.com: Main site
  - test.org: Test site

Registered VPS Nodes:
  - 100.68.225.92 → 192.0.2.100 (eu)
  - 100.70.123.45 → 167.99.1.1 (us)

Service Routing:
  - immich:
    Expose: example.com, test.org
    VPS: 100.68.225.92, 100.70.123.45
    Strategy: round-robin
```

---

## Scaling

### Add New VPS Node

```bash
# 1. Register in multi-domain registry
sudo ./scripts/domains/multi-domain-registry.sh register-vps \
    100.72.200.50 203.0.113.100 asia linode

# 2. Register in sync controller
sudo ./scripts/lib/sync-controller.sh register vps_nodes \
    100.72.200.50 linode-asia root

# 3. Update service routing to include new VPS
sudo ./scripts/domains/multi-domain-registry.sh configure-routing immich \
    "example.com,test.org" \
    "100.68.225.92,100.70.123.45,100.72.200.50" \
    round-robin

# 4. Push update
sudo ./scripts/lib/sync-controller.sh push
```

### Add New Management Laptop

```bash
# 1. Register laptop
sudo ./scripts/lib/sync-controller.sh register management_laptops \
    100.88.150.20 new-laptop username

# 2. On the laptop, run initial sync
cd ~/MyNodeOne
git pull origin main
sudo ./scripts/domains/sync-dns.sh
```

### Add New Domain

```bash
sudo ./scripts/domains/multi-domain-registry.sh register-domain example.com "Description"
```

---

## Monitoring

### Check Node Health

```bash
sudo ./scripts/lib/sync-controller.sh health
```

Output:
```
Node Health Status

Management Laptops:
  - dev-laptop (100.86.112.112): active (last sync: 2025-11-06T18:30:00Z)

VPS Edge Nodes:
  - contabo-vps (100.68.225.92): active (last sync: 2025-11-06T18:30:05Z)
```

### View Sync Controller Logs

```bash
sudo journalctl -u mynodeone-sync-controller -f
```

---

## Manual Sync

If automatic sync is not working:

```bash
# Push to all nodes from control plane
sudo ./scripts/lib/sync-controller.sh push

# Or sync individual machines:
# On laptop
sudo ./scripts/domains/sync-dns.sh

# On VPS
sudo ./scripts/vps/sync-vps-routes.sh
```

---

## Fault Tolerance

| Feature | Behavior |
|---------|----------|
| Automatic Retries | Failed pushes retry 3 times with exponential backoff |
| Periodic Reconciliation | Hourly sync ensures eventual consistency |
| State Persistence | Node registry saved to `~/.mynodeone/node-registry.json` |
| Health Tracking | Last sync time tracked per node |

---

## Troubleshooting

### Sync Not Working

```bash
# Check sync controller status
sudo systemctl status mynodeone-sync-controller
sudo journalctl -u mynodeone-sync-controller -n 50

# Manual push
sudo ./scripts/lib/sync-controller.sh push
```

### Node Not Receiving Updates

```bash
# Check registration
sudo ./scripts/lib/sync-controller.sh health

# Re-register node
sudo ./scripts/lib/sync-controller.sh register <type> <ip> <name> <user>
```

### Routes Not Working on VPS

```bash
# Check domain registry
sudo ./scripts/domains/multi-domain-registry.sh show

# Verify VPS has Tailscale IP
tailscale ip -4

# Test route generation
sudo ./scripts/domains/multi-domain-registry.sh export-vps-routes \
    $(tailscale ip -4) 100.122.68.75
```

---

## Performance

| Metric | Polling (old) | Push (current) |
|--------|---------------|----------------|
| Sync Latency | 0-5 minutes | 10-30 seconds |
| Network Traffic | High (constant) | Low (on change only) |
| Scalability | Poor | Excellent |

With 10 laptops + 5 VPS nodes:
- Old polling: ~180 requests/hour
- New push: ~15 pushes/day + 24 hourly reconciliations

---

## Quick Reference

```bash
# Control Plane
sudo ./scripts/lib/sync-controller.sh push        # Manual push
sudo ./scripts/lib/sync-controller.sh health      # Check nodes
sudo ./scripts/domains/multi-domain-registry.sh show  # View config

# Laptop
sudo ./scripts/domains/sync-dns.sh                        # Manual sync

# VPS
sudo ./scripts/vps/sync-vps-routes.sh                 # Manual sync
```

---

## Related Documentation

- [SYNC-CONTROLLER.md](../architecture/SYNC-CONTROLLER.md) - Sync controller architecture
- [scaling.md](scaling.md) - Adding worker nodes
- [INSTALLATION.md](../installation/INSTALLATION.md) - VPS edge node setup