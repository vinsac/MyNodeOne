# DNS Architecture

MyNodeOne uses a dual DNS configuration for maximum compatibility and network-wide accessibility.

---

## Overview

Two DNS methods work together:

| Method | Purpose | Scope |
|--------|---------|-------|
| `/etc/hosts` | Local resolution on control plane | Single machine |
| `dnsmasq` | Network DNS server | All devices on network |

---

## Why Two Methods?

### Method 1: /etc/hosts (Local Resolution)

**Advantages:**
- Works instantly, no service dependency
- Always available, even if dnsmasq fails
- Highest priority in name resolution
- Simple and reliable

**Limitations:**
- Only works on the local machine
- Requires manual updates on each device

### Method 2: dnsmasq (Network DNS Server)

**Advantages:**
- Other devices can query it
- Caches DNS queries for performance
- Can serve entire network

**Limitations:**
- Requires running service
- Can conflict with other DNS services

---

## Configuration Flow

When `./scripts/setup/setup-local-dns.sh` runs:

```
1. Get LoadBalancer IPs from Kubernetes
   └─ kubectl get svc ... (Grafana, ArgoCD, MinIO, etc.)

2. Update /etc/hosts
   ├─ grafana.mynodeone.local → 100.x.x.204
   ├─ argocd.mynodeone.local → 100.x.x.205
   └─ minio.mynodeone.local → 100.x.x.203

3. Configure dnsmasq
   ├─ Create /etc/dnsmasq.d/mynodeone.conf
   ├─ Add address records for each service
   └─ Restart dnsmasq
```

---

## Name Resolution Order

Linux resolves names in this order (configured in `/etc/nsswitch.conf`):

1. **files** - Checks `/etc/hosts` first
2. **dns** - Queries dnsmasq second
3. **mdns** - Checks Avahi/mDNS third (not configured by MyNodeOne)

Since hostnames exist in both `/etc/hosts` and dnsmasq, `getent hosts` returns duplicates:

```bash
$ getent hosts grafana.mynodeone.local
100.122.68.204  grafana.mynodeone.local    # from /etc/hosts
100.122.68.204  grafana.mynodeone.local    # from dnsmasq
```

This is expected behavior and handled in validation scripts using `head -1`.

---

## Design Benefits

### Redundancy

If dnsmasq crashes, `/etc/hosts` still works:

```bash
$ systemctl status dnsmasq
● dnsmasq.service - failed

$ curl http://grafana.mynodeone.local
HTTP/1.1 200 OK  # Works via /etc/hosts
```

### Network Accessibility

Other devices can use the control plane as their DNS server:

```bash
# On laptop: set DNS to control plane
echo "nameserver 100.x.x.75" | sudo tee /etc/resolv.conf

# Now .local domains resolve
curl http://grafana.mynodeone.local  # Works via dnsmasq
```

### Zero Configuration on Control Plane

The control plane works immediately after setup with no additional DNS configuration.

---

## Configuration Files

### /etc/hosts

```
# MyNodeOne services
100.122.68.206    mynodeone.local
100.122.68.204    grafana.mynodeone.local
100.122.68.205    argocd.mynodeone.local
100.122.68.203    minio.mynodeone.local
100.122.68.201    longhorn.mynodeone.local
# End MyNodeOne services
```

### /etc/dnsmasq.d/mynodeone.conf

```
# Service DNS entries (explicit only - no wildcards)
address=/mynodeone.local/100.122.68.206
address=/grafana.mynodeone.local/100.122.68.204
address=/argocd.mynodeone.local/100.122.68.205
address=/minio.mynodeone.local/100.122.68.203
address=/longhorn.mynodeone.local/100.122.68.201
```

---

## Security: No Wildcards

MyNodeOne explicitly avoids wildcard DNS entries.

**Wildcard (not used):**
```
address=/.mynodeone.local/100.122.68.206
```

This would make ANY undefined subdomain resolve to the dashboard:
```bash
curl http://undefined.mynodeone.local  # Would work (bad)
curl http://attacker.mynodeone.local   # Would work (bad)
```

**Explicit entries (used):**
```
address=/grafana.mynodeone.local/100.122.68.204
address=/argocd.mynodeone.local/100.122.68.205
```

Only defined services resolve:
```bash
curl http://grafana.mynodeone.local    # Works
curl http://undefined.mynodeone.local  # Fails (good)
```

**Why this matters:**
- Prevents subdomain takeover attacks
- Explicit configuration is auditable
- Catches typos immediately
- Clear security boundary

---

## Client Device Setup

### Option 1: Use Control Plane as DNS Server

```bash
# Add control plane as DNS server
echo "nameserver 100.x.x.75" | sudo tee -a /etc/resolv.conf

# .local domains now resolve
curl http://grafana.mynodeone.local
```

### Option 2: Management Laptop Setup Script

The management laptop installation automatically configures DNS via the sync controller.

---

## Troubleshooting

### Test /etc/hosts Resolution

```bash
# Stop dnsmasq temporarily
sudo systemctl stop dnsmasq

# Test - should still work via /etc/hosts
getent hosts grafana.mynodeone.local

# Restart dnsmasq
sudo systemctl start dnsmasq
```

### Test dnsmasq Resolution

```bash
# Query dnsmasq directly
dig @localhost grafana.mynodeone.local +short

# Check dnsmasq status
systemctl status dnsmasq

# View dnsmasq logs
journalctl -u dnsmasq -f
```

### Check Resolution Order

```bash
cat /etc/nsswitch.conf | grep hosts
# hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4
```

---

## Avahi/mDNS

Avahi comes pre-installed on Ubuntu but MyNodeOne does not configure it. The `/etc/hosts` + dnsmasq setup is sufficient for all use cases.

**When you might enable Avahi:**
- iOS/macOS auto-discovery (Bonjour)
- Service discovery across subnets
- Zero-config mobile app integration

**Current recommendation:** Keep it simple. The dual-method setup provides all necessary functionality.

---

## Summary

| Feature | /etc/hosts | dnsmasq |
|---------|-----------|---------|
| Works locally | Yes | Yes |
| Works on network | No | Yes |
| Requires service | No | Yes |
| Priority | First | Second |
| Caching | No | Yes |

**Why both?**
- Redundancy: If dnsmasq fails, /etc/hosts works
- Accessibility: dnsmasq enables network-wide access
- Performance: dnsmasq caches, /etc/hosts is instant

---

## Related Documentation

- [NETWORKING.md](NETWORKING.md) - Tailscale network architecture
- [SYNC-CONTROLLER.md](SYNC-CONTROLLER.md) - How DNS syncs to other nodes
