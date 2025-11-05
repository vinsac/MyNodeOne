# DNS Architecture in MyNodeOne

## Overview

MyNodeOne uses a **dual DNS configuration** for maximum compatibility and network-wide accessibility.

---

## Why Two DNS Methods?

### Method 1: `/etc/hosts` (Local Resolution)
**Purpose:** Immediate local DNS resolution on the control plane itself

**Advantages:**
- ✅ Works instantly, no service needed
- ✅ Always available, even if dnsmasq fails
- ✅ No dependencies
- ✅ Simple and reliable
- ✅ Highest priority in name resolution

**Limitations:**
- ❌ Only works on the local machine
- ❌ Other devices can't use it
- ❌ Requires manual updates on each device

### Method 2: `dnsmasq` (Network DNS Server)
**Purpose:** DNS server for network-wide resolution

**Advantages:**
- ✅ Other devices can query it
- ✅ Acts as DNS server for the network
- ✅ Advertises `.local` domains via mDNS
- ✅ Can be used by laptops, phones, other nodes
- ✅ Caches DNS queries for performance

**Limitations:**
- ❌ Requires a running service
- ❌ Slightly more complex setup
- ❌ Can conflict with other DNS services

---

## Configuration Flow

When you run `./scripts/setup-local-dns.sh`, here's what happens:

```bash
1. Get LoadBalancer IPs
   ├─ kubectl get svc ... (Grafana)
   ├─ kubectl get svc ... (ArgoCD)
   ├─ kubectl get svc ... (MinIO)
   └─ kubectl get svc ... (Dashboard, Traefik, Longhorn)

2. Update /etc/hosts                    ← First DNS method
   ├─ Add: mycloud.local → 100.122.68.206
   ├─ Add: grafana.mycloud.local → 100.122.68.204
   ├─ Add: argocd.mycloud.local → 100.122.68.205
   ├─ Add: minio.mycloud.local → 100.122.68.203
   └─ Add: longhorn.mycloud.local → 100.122.68.201

3. Configure dnsmasq                    ← Second DNS method
   ├─ Create: /etc/dnsmasq.d/mycloud.conf
   ├─ Add: address=/mycloud.local/100.122.68.206
   ├─ Add: address=/grafana.mycloud.local/100.122.68.204
   ├─ Add: address=/argocd.mycloud.local/100.122.68.205
   └─ Restart: systemctl restart dnsmasq
```

---

## Result: Duplicate DNS Entries

### Same Hostnames in BOTH Places

**Example:** `grafana.mycloud.local`

```
/etc/hosts:
100.122.68.204    grafana.mycloud.local

/etc/dnsmasq.d/mycloud.conf:
address=/grafana.mycloud.local/100.122.68.204
```

### How Linux Resolves Names

When you query `grafana.mycloud.local`:

```bash
$ getent hosts grafana.mycloud.local
100.122.68.204  grafana.mycloud.local    # from /etc/hosts
100.122.68.204  grafana.mycloud.local    # from dnsmasq
```

**Resolution order (configured in `/etc/nsswitch.conf`):**
1. **files** → Checks `/etc/hosts` first
2. **dns** → Queries dnsmasq second
3. **mdns** → Checks mDNS if available

Since the hostname exists in BOTH, `getent` returns it TWICE!

---

## Why This Is Good Design

### 1. **Redundancy**
If dnsmasq crashes, `/etc/hosts` still works:
```bash
# dnsmasq is down
$ systemctl status dnsmasq
● dnsmasq.service - failed

# DNS still works locally!
$ curl http://grafana.mycloud.local
HTTP/1.1 200 OK  ← Works via /etc/hosts
```

### 2. **Network Accessibility**
Other devices can use the control plane as DNS server:

**On your laptop:**
```bash
# Set DNS server to control plane
$ sudo sh -c 'echo "nameserver 100.122.68.75" > /etc/resolv.conf'

# Now .local domains work on laptop too!
$ curl http://grafana.mycloud.local
HTTP/1.1 200 OK  ← Works via dnsmasq
```

### 3. **Zero Configuration on Control Plane**
The control plane works immediately after setup, no additional DNS configuration needed.

### 4. **Best of Both Worlds**
```
Local access:  /etc/hosts (instant, reliable)
Remote access: dnsmasq (network-wide)
```

---

## Implications for Validation

### The Duplicate Entry Challenge

When validating DNS, we need to handle duplicates:

**Before Fix:**
```bash
# Returns TWO results
resolved_ip=$(getent hosts grafana.mycloud.local | awk '{print $1}')
echo "$resolved_ip"
# Output:
# 100.122.68.204
# 100.122.68.204

# Comparison fails! (two lines vs one line)
if [ "$resolved_ip" != "100.122.68.204" ]; then
    echo "FAIL"  # False positive!
fi
```

**After Fix:**
```bash
# Take only first result
resolved_ip=$(getent hosts grafana.mycloud.local | awk '{print $1}' | head -1)
echo "$resolved_ip"
# Output: 100.122.68.204

# Comparison works!
if [ "$resolved_ip" != "100.122.68.204" ]; then
    echo "PASS"  # Correct!
fi
```

**Fix Location:** `scripts/lib/service-validation.sh` line 180

---

## Configuration Files

### 1. `/etc/hosts`
**Format:**
```
IP_ADDRESS    hostname    # optional comment
```

**MyNodeOne entries:**
```bash
# MyNodeOne services
100.122.68.206      mycloud.local
100.122.68.204        grafana.mycloud.local
100.122.68.205         argocd.mycloud.local
100.122.68.203  minio.mycloud.local
100.122.68.202      minio-api.mycloud.local
100.122.68.201       longhorn.mycloud.local
100.122.68.200    traefik.mycloud.local
# End MyNodeOne services
```

**Managed by:** `scripts/setup-local-dns.sh` (function: `update_hosts_file`)

### 2. `/etc/dnsmasq.d/mycloud.conf`
**Format:**
```
address=/hostname/IP_ADDRESS
```

**MyNodeOne entries:**
```bash
# Service DNS entries (explicit only - no wildcards!)
address=/mycloud.local/100.122.68.206
address=/dashboard.mycloud.local/100.122.68.206
address=/grafana.mycloud.local/100.122.68.204
address=/argocd.mycloud.local/100.122.68.205
address=/minio.mycloud.local/100.122.68.203
address=/minio-api.mycloud.local/100.122.68.202
address=/traefik.mycloud.local/100.122.68.200
address=/longhorn.mycloud.local/100.122.68.201
```

**Managed by:** `scripts/setup-local-dns.sh` (function: `setup_dnsmasq`)

---

## Troubleshooting

### Check Which Method Is Resolving

**Test /etc/hosts only:**
```bash
# Temporarily stop dnsmasq
sudo systemctl stop dnsmasq

# Test resolution
getent hosts grafana.mycloud.local
# If it works → /etc/hosts is working

# Restart dnsmasq
sudo systemctl start dnsmasq
```

**Test dnsmasq only:**
```bash
# Query dnsmasq directly
dig @localhost grafana.mycloud.local

# Or use nslookup
nslookup grafana.mycloud.local localhost
```

**See both at once:**
```bash
# This shows duplicates
getent hosts grafana.mycloud.local
100.122.68.204  grafana.mycloud.local    # /etc/hosts
100.122.68.204  grafana.mycloud.local    # dnsmasq

# Get unique IPs only
getent hosts grafana.mycloud.local | awk '{print $1}' | sort -u
100.122.68.204
```

### Check Name Resolution Order

```bash
# View resolution order
cat /etc/nsswitch.conf | grep hosts
hosts:          files mdns4_minimal [NOTFOUND=return] dns mdns4

# Order:
# 1. files      = /etc/hosts
# 2. dns        = dnsmasq, systemd-resolved
# 3. mdns       = Avahi/mDNS
```

### Verify dnsmasq Configuration

```bash
# Check dnsmasq is running
systemctl status dnsmasq

# View configuration
cat /etc/dnsmasq.d/mycloud.conf

# Test dnsmasq directly
dig @localhost grafana.mycloud.local +short
100.122.68.204

# Check dnsmasq logs
journalctl -u dnsmasq -f
```

---

## Security Considerations

### No Wildcards!

**We explicitly avoid wildcard DNS:**

**❌ BAD (Wildcard):**
```bash
address=/.mycloud.local/100.122.68.206
```
This would make **ANY** undefined subdomain resolve to the dashboard!

```bash
curl http://undefined.mycloud.local    # Would work (BAD!)
curl http://attacker.mycloud.local     # Would work (BAD!)
curl http://anything.mycloud.local     # Would work (BAD!)
```

**✅ GOOD (Explicit):**
```bash
address=/grafana.mycloud.local/100.122.68.204
address=/argocd.mycloud.local/100.122.68.205
```
Only defined services resolve:

```bash
curl http://grafana.mycloud.local      # Works ✓
curl http://undefined.mycloud.local    # Fails (GOOD!)
```

**Why this matters:**
- Prevents subdomain takeover attacks
- Explicit configuration is auditable
- Catches typos immediately
- Clear security boundary

**Validation:** The comprehensive validation script checks for dangerous wildcards!

---

## For Other Devices (Laptops, Phones)

### Option 1: Use Control Plane as DNS Server

**On client device:**
```bash
# Add control plane as DNS server
echo "nameserver 100.122.68.75" | sudo tee -a /etc/resolv.conf
```

**Now .local domains work:**
```bash
curl http://grafana.mycloud.local   # Works!
```

### Option 2: Run Client Setup Script

MyNodeOne generates a client setup script:

```bash
# On control plane
cat ~/MyNodeOne/setup-client-dns.sh

# Copy to client and run
scp setup-client-dns.sh user@laptop:~
ssh user@laptop 'sudo bash ~/setup-client-dns.sh'
```

This configures the client to use the control plane for `.local` domains.

---

## Summary

| Feature | /etc/hosts | dnsmasq |
|---------|-----------|---------|
| **Works locally** | ✅ Yes | ✅ Yes |
| **Works on network** | ❌ No | ✅ Yes |
| **Requires service** | ❌ No | ✅ Yes |
| **Priority** | 🥇 First | 🥈 Second |
| **Reliability** | 🔥 100% | ⚡ 99.9% |
| **Setup complexity** | ⭐ Simple | ⭐⭐ Medium |
| **Caching** | ❌ No | ✅ Yes |

**Why both?**
- **Redundancy:** If dnsmasq fails, /etc/hosts works
- **Accessibility:** dnsmasq enables network-wide access
- **Performance:** dnsmasq caches, /etc/hosts is instant
- **Flexibility:** Best of both worlds

**Key takeaway:** This dual configuration ensures DNS always works, both locally and across your network!

---

## Related Documentation

- `COMPREHENSIVE_VALIDATION.md` - How validation handles duplicate entries
- `DNS_AUTOMATION_EXPLAINED.md` - Why DNS automation is permanent
- `docs/network-architecture.md` - Overall network design
- `scripts/setup-local-dns.sh` - DNS configuration script
- `scripts/lib/service-validation.sh` - Validation with duplicate handling
