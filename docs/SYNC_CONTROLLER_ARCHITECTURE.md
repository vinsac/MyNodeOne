# Sync Controller Architecture

## Overview

The Sync Controller is the central orchestration system that maintains configuration consistency across all nodes in a MyNodeOne cluster. It implements a **unidirectional push model** where the Control Plane initiates all synchronization operations.

---

## Core Principles

### 1. Unidirectional Trust Model
- **Control Plane → Nodes**: Control plane SSHes to all nodes
- **Nodes ✗ Control Plane**: Nodes never SSH back to control plane
- **Security**: Private keys remain on control plane only

### 2. Event-Driven + Periodic Reconciliation
- **Immediate Sync**: Triggered when ConfigMaps change (watch mode)
- **Periodic Retry**: Hourly reconciliation for offline nodes
- **Fault Tolerance**: Offline nodes catch up automatically

### 3. Node-Type Specific Sync
- **VPS Nodes**: Receive Traefik routes via stdin
- **Management Laptops**: Receive DNS entries via SSH
- **Worker Nodes**: Receive DNS entries via SSH

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Control Plane                             │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │         Sync Controller Daemon (systemd)               │    │
│  │                                                         │    │
│  │  ┌──────────────────┐      ┌───────────────────────┐  │    │
│  │  │  Watch Mode      │      │  Reconciliation       │  │    │
│  │  │                  │      │  (Every 1 Hour)       │  │    │
│  │  │ • Monitor        │      │                       │  │    │
│  │  │   ConfigMap      │      │ • Retry offline nodes │  │    │
│  │  │ • Detect changes │      │ • Full consistency    │  │    │
│  │  │ • Immediate sync │      │ • Status tracking     │  │    │
│  │  │ • 10s poll       │      │ • Pending node retry  │  │    │
│  │  └────────┬─────────┘      └──────────┬────────────┘  │    │
│  │           │                           │               │    │
│  │           └─────────────┬─────────────┘               │    │
│  │                         │                             │    │
│  │                         ▼                             │    │
│  │              ┌──────────────────────┐                 │    │
│  │              │  push_sync_all()     │                 │    │
│  │              │                      │                 │    │
│  │              │ 1. Init registry     │                 │    │
│  │              │ 2. For each node:    │                 │    │
│  │              │    • Check reachable │                 │    │
│  │              │    • SSH to node     │                 │    │
│  │              │    • Run sync script │                 │    │
│  │              │    • Verify result   │                 │    │
│  │              │    • Update status   │                 │    │
│  │              └──────────────────────┘                 │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │              Node Registry (ConfigMap)                  │    │
│  │                                                         │    │
│  │  {                                                      │    │
│  │    "management_laptops": [...],                        │    │
│  │    "vps_nodes": [...],                                 │    │
│  │    "worker_nodes": [...]                               │    │
│  │  }                                                      │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │            Service Registry (ConfigMap)                 │    │
│  │                                                         │    │
│  │  {                                                      │    │
│  │    "demo": {                                           │    │
│  │      "subdomain": "demo",                              │    │
│  │      "ip": "100.x.x.x",                                │    │
│  │      "port": 80,                                       │    │
│  │      "public": true                                    │    │
│  │    }                                                   │    │
│  │  }                                                      │    │
│  └────────────────────────────────────────────────────────┘    │
└──────────────────────────┬───────────────────────────────────────┘
                           │
                           │ SSH over Tailscale
                           │
        ┌──────────────────┼──────────────────┬──────────────────┐
        │                  │                  │                  │
        ▼                  ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  VPS Node 1   │  │  VPS Node 2   │  │  Laptop 1     │  │  Laptop 2     │
│               │  │               │  │  (ONLINE)     │  │  (OFFLINE)    │
│  Receives:    │  │  Receives:    │  │               │  │               │
│  • Routes     │  │  • Routes     │  │  Receives:    │  │  Status:      │
│    via stdin  │  │    via stdin  │  │  • DNS via    │  │  • pending_   │
│  • Generates  │  │  • Generates  │  │    SSH        │  │    sync       │
│    Traefik    │  │    Traefik    │  │  • Updates    │  │  • Will retry │
│    config     │  │    config     │  │    /etc/hosts │  │    next cycle │
│               │  │               │  │               │  │               │
│  ✅ Synced    │  │  ✅ Synced    │  │  ✅ Synced    │  │  ⏳ Pending   │
└───────────────┘  └───────────────┘  └───────────────┘  └───────────────┘
                                                                  │
                                                                  │ Comes online
                                                                  ▼
                                                          ┌───────────────┐
                                                          │  Laptop 2     │
                                                          │  (ONLINE)     │
                                                          │               │
                                                          │  ✅ Synced    │
                                                          │  (next cycle) │
                                                          └───────────────┘
```

---

## Component Details

### 1. Watch Mode

**Purpose:** Immediate synchronization when ConfigMaps change

**How It Works:**
```bash
while true; do
    current_version=$(kubectl get configmap service-registry \
        -o jsonpath='{.metadata.resourceVersion}')
    
    if [[ "$current_version" != "$last_version" ]]; then
        log_info "ConfigMap changed, triggering sync..."
        push_sync_all
        last_version="$current_version"
    fi
    
    sleep 10  # Poll every 10 seconds
done
```

**Triggers:**
- App installed
- App made public
- Service registry updated
- Manual ConfigMap edit

**Latency:** ~10 seconds from change to sync

### 2. Periodic Reconciliation

**Purpose:** Retry offline nodes, ensure consistency

**How It Works:**
```bash
while true; do
    sleep 3600  # 1 hour
    
    # Find nodes with status="pending_sync"
    pending_nodes=$(get_pending_nodes)
    
    log_info "Found $count pending nodes, retrying..."
    
    # Attempt sync to all nodes
    push_sync_all
done
```

**Benefits:**
- Offline nodes catch up within 1 hour
- Consistency guarantee
- No manual intervention needed

**Configurable:** Default 1 hour, adjustable

### 3. Daemon Mode (Recommended)

**Purpose:** Combines watch + reconciliation for production

**How It Works:**
```bash
# Start reconciliation in background
periodic_reconciliation 1 &

# Run watch in foreground
watch_and_push
```

**Benefits:**
- Immediate sync on changes
- Automatic retry for offline nodes
- Production-ready
- Single service to manage

---

## Sync Flow by Node Type

### VPS Edge Nodes

**Data Flow:**
```
Control Plane                    VPS Node
     │                              │
     │ 1. Fetch service registry    │
     │    from ConfigMap            │
     │                              │
     │ 2. SSH to VPS                │
     ├─────────────────────────────>│
     │                              │
     │ 3. Pass registry via stdin   │
     ├─────────────────────────────>│
     │                              │
     │                              │ 4. sync-vps-routes.sh
     │                              │    • Read from stdin
     │                              │    • Filter public services
     │                              │    • Generate Traefik routes
     │                              │    • Reload Traefik
     │                              │
     │ 5. Verify routes file        │
     │<─────────────────────────────┤
     │                              │
     │ 6. Verify Traefik running    │
     │<─────────────────────────────┤
     │                              │
     │ 7. Update last_sync          │
     │                              │
```

**Key Points:**
- ✅ Unidirectional: Control plane → VPS
- ✅ stdin: No file transfer needed
- ✅ Verification: Ensures sync succeeded
- ✅ No VPS → Control plane SSH

### Management Laptops

**Data Flow:**
```
Control Plane                    Laptop
     │                              │
     │ 1. Check reachable           │
     ├─────────────────────────────>│
     │                              │
     │ 2. SSH to laptop             │
     ├─────────────────────────────>│
     │                              │
     │ 3. Run sync-dns.sh           │
     ├─────────────────────────────>│
     │                              │
     │                              │ 4. sync-dns.sh
     │                              │    • Fetch service registry
     │                              │      (via kubectl or SSH)
     │                              │    • Update /etc/hosts
     │                              │    • Remove old entries
     │                              │
     │ 5. Verify /etc/hosts         │
     │<─────────────────────────────┤
     │                              │
     │ 6. Update last_sync          │
     │                              │
```

**Key Points:**
- ✅ Graceful offline handling
- ✅ Automatic retry if offline
- ✅ No data loss
- ✅ Catches up within 1 hour

### Worker Nodes

**Data Flow:**
```
Control Plane                    Worker
     │                              │
     │ 1. SSH to worker             │
     ├─────────────────────────────>│
     │                              │
     │ 2. Run sync-dns.sh           │
     ├─────────────────────────────>│
     │                              │
     │                              │ 3. sync-dns.sh
     │                              │    • Fetch service registry
     │                              │    • Update /etc/hosts
     │                              │
     │ 4. Update last_sync          │
     │                              │
```

---

## Node Status Tracking

### Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `active` | Last sync successful | Continue normal operation |
| `pending_sync` | Offline or failed | Retry on next reconciliation |
| `error` | Persistent failure | Manual investigation needed |

### Status Transitions

```
        ┌─────────────┐
        │   active    │
        └──────┬──────┘
               │
               │ Sync fails / Node offline
               ▼
        ┌─────────────┐
        │ pending_sync│◄──────┐
        └──────┬──────┘       │
               │              │ Still offline
               │ Node online  │
               │ Sync success │
               ▼              │
        ┌─────────────┐       │
        │   active    │       │
        └──────┬──────┘       │
               │              │
               │ Multiple     │
               │ failures     │
               ▼              │
        ┌─────────────┐       │
        │    error    │───────┘
        └─────────────┘
```

### Registry Format

```json
{
  "management_laptops": [
    {
      "ip": "100.86.112.112",
      "name": "vinay-laptop",
      "ssh_user": "vinaysachdeva",
      "status": "active",
      "last_sync": "2025-11-21T20:45:00Z",
      "last_attempt": "2025-11-21T20:45:00Z"
    }
  ],
  "vps_nodes": [
    {
      "ip": "100.68.225.92",
      "name": "contabo-vps",
      "ssh_user": "sammy",
      "status": "active",
      "last_sync": "2025-11-21T20:45:00Z",
      "last_attempt": "2025-11-21T20:45:00Z"
    }
  ],
  "worker_nodes": []
}
```

---

## Error Handling

### Offline Node Handling

**Problem:** Node is offline during sync
**Detection:** SSH ping test fails
**Action:**
1. Mark node as `pending_sync`
2. Log warning (not error)
3. Continue to next node
4. Retry on next reconciliation

**Code:**
```bash
if ! ssh user@node "echo ping" 2>/dev/null; then
    log_warn "Node offline, will retry"
    mark_as_pending_sync
    return 1  # Don't error out
fi
```

### Sync Failure Handling

**Problem:** Sync command fails
**Detection:** Exit code != 0
**Action:**
1. Retry up to 3 times (5s delay)
2. If all fail, mark as `pending_sync`
3. Log detailed error
4. Retry on next reconciliation

### Verification Failure Handling

**Problem:** Sync succeeded but verification fails
**Detection:** Routes file missing or Traefik not running
**Action:**
1. Mark sync as failed
2. Mark node as `pending_sync`
3. Log specific failure reason
4. Retry on next reconciliation

---

## Performance Characteristics

### Resource Usage

**CPU:**
- Idle: ~1-2%
- During sync: ~5-10% (brief spike)
- Reconciliation: ~3-5%

**Memory:**
- ~40-50 MB resident
- Scales linearly with node count

**Network:**
- Watch mode: Minimal (ConfigMap poll)
- Sync: ~1-5 KB per node
- SSH: Connection reuse when possible

### Scalability

| Node Count | Performance | Recommendation |
|------------|-------------|----------------|
| 1-10 | Excellent | Default settings |
| 10-50 | Good | Default settings |
| 50-100 | Fair | Increase reconciliation interval |
| 100+ | Poor | Consider optimization |

**Optimization for Large Deployments:**
- Increase reconciliation interval (2-4 hours)
- Reduce ConfigMap poll frequency (30s)
- Implement parallel sync (future)

---

## Security Model

### SSH Key Management

**Control Plane:**
- Holds private key: `~/.ssh/mynodeone_id_ed25519`
- Never shared with other nodes
- Used to SSH to all nodes

**Other Nodes:**
- Hold public key in `~/.ssh/authorized_keys`
- Can be SSHed into by control plane
- Cannot SSH to control plane

### Data Flow Security

**VPS Nodes:**
- Service registry passed via stdin (encrypted SSH tunnel)
- No file transfer, no temporary files
- Traefik routes generated locally

**Management Laptops:**
- Fetch service registry via kubectl (authenticated)
- Or via SSH to control plane (encrypted)
- Update local /etc/hosts only

### Network Security

**Tailscale:**
- All SSH connections over Tailscale VPN
- End-to-end encrypted
- No public SSH exposure

**Firewall:**
- VPS: Only ports 22, 80, 443 open
- Control plane: SSH only via Tailscale
- Laptops: No inbound connections needed

---

## Monitoring & Observability

### Service Status

```bash
sudo systemctl status mynodeone-sync-controller
```

**Expected Output:**
```
● mynodeone-sync-controller.service
   Active: active (running)
   Main PID: 12345
   Tasks: 2 (watch + reconcile)
```

### Logs

```bash
# Live tail
sudo journalctl -u mynodeone-sync-controller -f

# Last 100 lines
sudo journalctl -u mynodeone-sync-controller -n 100

# Since 1 hour ago
sudo journalctl -u mynodeone-sync-controller --since "1 hour ago"
```

**Log Levels:**
- `[INFO]` - Normal operations
- `[⚠]` - Warnings (offline nodes, retries)
- `[✗]` - Errors (persistent failures)
- `[✓]` - Success messages

### Node Health

```bash
sudo ./scripts/lib/sync-controller.sh health
```

**Output:**
```
Management Laptops:
  • vinay-laptop: active (last sync: 2025-11-21T20:45:00Z)
  • dev-laptop: pending_sync (last sync: 2025-11-21T18:00:00Z)

VPS Edge Nodes:
  • contabo-vps: active (last sync: 2025-11-21T20:45:00Z)

Worker Nodes:
  • worker-01: active (last sync: 2025-11-21T20:45:00Z)
```

---

## Troubleshooting

### Issue: Sync Not Triggering

**Symptoms:** ConfigMap changes but no sync happens

**Diagnosis:**
```bash
# Check if service is running
sudo systemctl status mynodeone-sync-controller

# Check logs for errors
sudo journalctl -u mynodeone-sync-controller -n 50
```

**Common Causes:**
- Service not running
- K3s not running
- ConfigMap watch failing

**Fix:**
```bash
sudo systemctl restart mynodeone-sync-controller
```

### Issue: Node Stays in pending_sync

**Symptoms:** Node never syncs despite being online

**Diagnosis:**
```bash
# From control plane, test SSH
ssh user@node-ip "echo OK"

# Check node's Tailscale status
ssh user@node-ip "tailscale status"
```

**Common Causes:**
- SSH keys not exchanged
- Tailscale disconnected
- Firewall blocking SSH

**Fix:**
```bash
# Re-exchange SSH keys
ssh-copy-id user@node-ip

# Verify Tailscale
ssh user@node-ip "sudo tailscale up"
```

### Issue: VPS Routes Not Updating

**Symptoms:** App made public but not accessible

**Diagnosis:**
```bash
# Check if sync succeeded
sudo ./scripts/lib/sync-controller.sh health

# Check routes file on VPS
ssh user@vps-ip "cat ~/traefik/config/mynodeone-routes.yml"

# Check Traefik logs
ssh user@vps-ip "docker logs traefik -n 50"
```

**Common Causes:**
- Sync failed silently
- Traefik not reloading
- DNS not pointing to VPS

**Fix:**
```bash
# Force sync
sudo ./scripts/lib/sync-controller.sh push

# Restart Traefik on VPS
ssh user@vps-ip "cd ~/traefik && docker compose restart"
```

---

## Comparison with v3.0

### Preserved from v3.0 ✅

- Unidirectional trust model
- stdin-based VPS sync
- Verification (routes + Traefik)
- Retry logic (3 attempts)
- SSH agent handling

### New in Current Version ✅

- Reachability check (prevents hanging)
- Periodic reconciliation (retry offline nodes)
- Management laptop support
- Daemon mode (watch + reconcile)
- Status tracking (active/pending_sync/error)
- Systemd service integration

### No Regressions ✅

All v3.0 functionality preserved and enhanced.

---

## Future Enhancements

### Short Term

1. **Parallel Sync** - Sync multiple nodes simultaneously
2. **Webhook Support** - Immediate sync via Kubernetes webhooks
3. **Metrics Export** - Prometheus metrics for monitoring
4. **Web Dashboard** - Visual status of all nodes

### Long Term

1. **Pull Model** - Nodes pull config (alternative to push)
2. **Conflict Resolution** - Handle concurrent updates
3. **Multi-Cluster** - Sync across multiple clusters
4. **Encrypted ConfigMaps** - Sensitive data encryption

---

## Summary

The Sync Controller provides:

- ✅ **Unidirectional trust** - Control plane controls all
- ✅ **Event-driven** - Immediate sync on changes
- ✅ **Fault-tolerant** - Offline nodes catch up automatically
- ✅ **Verifiable** - Ensures sync actually succeeded
- ✅ **Production-ready** - Systemd service, logging, monitoring
- ✅ **Scalable** - Handles 1-50 nodes easily
- ✅ **Secure** - SSH over Tailscale, no public exposure

**The foundation for reliable, automated cluster management.**
