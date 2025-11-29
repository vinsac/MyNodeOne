# Sync Controller Architecture

The Sync Controller maintains configuration consistency across all nodes in a MyNodeOne cluster using a unidirectional push model where the control plane initiates all synchronization operations.

---

## Core Principles

### Unidirectional Trust Model

- **Control Plane → Nodes**: Control plane SSHes to all nodes
- **Nodes → Control Plane**: Nodes never SSH back to control plane
- **Security**: Private keys remain on control plane only

### Event-Driven + Periodic Reconciliation

- **Immediate Sync**: Triggered when ConfigMaps change (watch mode)
- **Periodic Retry**: Hourly reconciliation for offline nodes
- **Fault Tolerance**: Offline nodes catch up automatically

### Node-Type Specific Sync

| Node Type | Data Synced | Method |
|-----------|-------------|--------|
| VPS Edge Nodes | Traefik routes | stdin over SSH |
| Management Laptops | DNS entries | SSH command |
| Worker Nodes | DNS entries | SSH command |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Control Plane                            │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐    │
│  │         Sync Controller Daemon (systemd)               │    │
│  │                                                        │    │
│  │  ┌──────────────────┐      ┌───────────────────────┐  │    │
│  │  │  Watch Mode      │      │  Reconciliation       │  │    │
│  │  │                  │      │  (Every 1 Hour)       │  │    │
│  │  │ • Monitor        │      │                       │  │    │
│  │  │   ConfigMap      │      │ • Retry offline nodes │  │    │
│  │  │ • Detect changes │      │ • Full consistency    │  │    │
│  │  │ • Immediate sync │      │ • Status tracking     │  │    │
│  │  └────────┬─────────┘      └──────────┬────────────┘  │    │
│  │           └─────────────┬─────────────┘               │    │
│  │                         ▼                             │    │
│  │              ┌──────────────────────┐                 │    │
│  │              │  push_sync_all()     │                 │    │
│  │              │  • Check reachable   │                 │    │
│  │              │  • SSH to node       │                 │    │
│  │              │  • Run sync script   │                 │    │
│  │              │  • Verify result     │                 │    │
│  │              └──────────────────────┘                 │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐           │
│  │  Node Registry      │    │  Service Registry   │           │
│  │  (ConfigMap)        │    │  (ConfigMap)        │           │
│  └─────────────────────┘    └─────────────────────┘           │
└──────────────────────────┬──────────────────────────────────────┘
                           │ SSH over Tailscale
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  VPS Node     │  │  Laptop       │  │  Worker       │
│  Receives:    │  │  Receives:    │  │  Receives:    │
│  • Routes     │  │  • DNS        │  │  • DNS        │
│    via stdin  │  │    entries    │  │    entries    │
└───────────────┘  └───────────────┘  └───────────────┘
```

---

## Sync Flow

### VPS Edge Nodes

1. Control plane fetches service registry from ConfigMap
2. SSH to VPS over Tailscale
3. Pass registry via stdin (no file transfer)
4. VPS runs `sync-vps-routes.sh`:
   - Filter public services
   - Generate Traefik routes
   - Reload Traefik
5. Control plane verifies routes file exists
6. Update node status to `active`

### Management Laptops and Workers

1. Control plane checks node is reachable
2. SSH to node over Tailscale
3. Run `sync-dns.sh` on node:
   - Fetch service registry
   - Update `/etc/hosts`
4. Update node status

---

## Node Status Tracking

| Status | Meaning | Action |
|--------|---------|--------|
| `active` | Last sync successful | Normal operation |
| `pending_sync` | Offline or failed | Retry on next reconciliation |
| `error` | Persistent failure | Manual investigation |

### Registry Format

```json
{
  "management_laptops": [
    {
      "ip": "100.86.112.112",
      "name": "vinay-laptop",
      "ssh_user": "vinay",
      "status": "active",
      "last_sync": "2025-11-21T20:45:00Z"
    }
  ],
  "vps_nodes": [...],
  "worker_nodes": [...]
}
```

---

## Error Handling

### Offline Nodes

- Detection: SSH ping test fails
- Action: Mark as `pending_sync`, continue to next node
- Recovery: Automatic retry on next reconciliation cycle

### Sync Failures

- Retry up to 3 times with 5-second delay
- If all fail, mark as `pending_sync`
- Log detailed error for troubleshooting

---

## Security Model

### SSH Key Management

- **Control Plane**: Holds private key (`~/.ssh/mynodeone_id_ed25519`)
- **Other Nodes**: Hold public key in `authorized_keys`
- Keys never shared; control plane initiates all connections

### Data Flow Security

- All SSH connections over Tailscale VPN (encrypted)
- VPS receives data via stdin (no temporary files)
- No public SSH exposure

---

## Monitoring

### Service Status

```bash
sudo systemctl status mynodeone-sync-controller
```

### Logs

```bash
# Live tail
sudo journalctl -u mynodeone-sync-controller -f

# Last 100 lines
sudo journalctl -u mynodeone-sync-controller -n 100
```

### Node Health

```bash
sudo ./scripts/lib/sync-controller.sh health
```

---

## Design Rationale: Why SSH Push Model?

The sync controller uses SSH from control plane to nodes rather than having nodes pull or subscribe to events. This design was chosen for:

1. **Security**: Private keys stay on control plane only. Nodes cannot initiate connections back.

2. **Simplicity**: No additional services (webhooks, message queues) needed on nodes.

3. **Reliability**: Works even if nodes are behind restrictive firewalls or NAT.

4. **Consistency**: Control plane is single source of truth; push ensures all nodes get same config.

**Trade-offs acknowledged:**
- Nodes must be SSH-accessible from control plane
- Sync latency depends on poll interval (10 seconds)
- Scale limited by sequential SSH connections

For most home/small deployments (1-50 nodes), this model works well. Larger deployments may benefit from parallel sync or a pull-based model.

---

## Troubleshooting

### Sync Not Triggering

```bash
# Check service running
sudo systemctl status mynodeone-sync-controller

# Check logs
sudo journalctl -u mynodeone-sync-controller -n 50

# Restart if needed
sudo systemctl restart mynodeone-sync-controller
```

### Node Stays in pending_sync

```bash
# Test SSH from control plane
ssh user@node-ip "echo OK"

# Check Tailscale
ssh user@node-ip "tailscale status"

# Re-exchange keys if needed
ssh-copy-id user@node-ip
```

### VPS Routes Not Updating

```bash
# Check routes file on VPS
ssh user@vps-ip "cat /etc/traefik/dynamic/mynodeone-routes.yml"

# Force sync
sudo ./scripts/lib/sync-controller.sh push

# Restart Traefik
ssh user@vps-ip "cd /etc/traefik && docker compose restart"
```
