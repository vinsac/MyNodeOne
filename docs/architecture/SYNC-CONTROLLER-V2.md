# Sync Controller V2 - Pull-Based Architecture

This document describes the redesigned sync controller that uses HTTP-based pull and heartbeat as the primary mechanism, with SSH-based push as a fallback.

---

## Quick Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CONTROL PLANE                                       │
│                                                                              │
│   ┌────────────────────────┐        ┌─────────────────────────────────────┐ │
│   │  Config API Server     │        │  SSH Sync Controller Daemon         │ │
│   │  (mynodeone-config-api)│        │  (mynodeone-sync-controller)        │ │
│   │                        │        │                                     │ │
│   │  • Serves config       │◄───────│  • Watches service-registry         │ │
│   │  • Receives heartbeats │        │  • Syncs service-registry (hourly)  │ │
│   │  • Tracks node status  │        │  • Checks which nodes are online    │ │
│   │                        │        │  • Pushes via SSH if node offline   │ │
│   └────────────────────────┘        └─────────────────────────────────────┘ │
│             ▲                                        │                       │
└─────────────┼────────────────────────────────────────┼───────────────────────┘
              │ HTTP (Primary)                         │ SSH (Fallback)
              │                                        │
    ┌─────────┴─────────┐                    ┌─────────┴─────────┐
    │                   │                    │                   │
    ▼                   ▼                    ▼                   ▼
┌────────────┐    ┌────────────┐       ┌────────────┐    ┌────────────┐
│ VPS Node   │    │ Laptop     │       │ VPS Node   │    │ Laptop     │
│ Agent      │    │ Agent      │       │ (offline)  │    │ (offline)  │
│ ✓ online   │    │ ✓ online   │       │ SSH push   │    │ SSH push   │
└────────────┘    └────────────┘       └────────────┘    └────────────┘
```

### Services Installed

| Node Type | Services | Purpose |
|-----------|----------|---------|
| **Control Plane** | `mynodeone-config-api` | Serves config, tracks heartbeats |
| **Control Plane** | `mynodeone-sync-controller` | SSH fallback when Node Agent fails, syncs service-registry hourly |
| **VPS/Laptop/Worker** | `mynodeone-node-agent` | Pulls config, sends heartbeats |

### How It Works

1. **Node Agent polls** control plane every 60 seconds for config updates
2. **Node Agent sends heartbeat** to report online status
3. **Config API tracks** which nodes are online/stale/offline
4. **Sync-controller runs periodic reconciliation** (every 1 hour):
   - Syncs service-registry (cleanup stale entries, discover new services)
   - Checks which nodes have active Node Agent (via Config API)
   - Skips SSH for online nodes (Node Agent will pull)
   - Uses SSH push for stale/offline nodes
5. **When config changes** (app install/uninstall), sync-controller:
   - Checks which nodes have active Node Agent (via Config API)
   - Skips SSH for online nodes (Node Agent will pull)
   - Uses SSH push for stale/offline nodes

---

## Problem Statement

The current sync controller has limitations:

| Issue | Impact |
|-------|--------|
| SSH from control plane to all nodes | Doesn't scale; requires SSH keys everywhere |
| No heartbeat | Can't tell which nodes are online/offline |
| Control plane must initiate | If control plane is restored, it may lack SSH keys |
| Tight coupling | Control plane must know about every node |

---

## Design Goals

1. **Nodes pull config** - Nodes fetch config from control plane (not pushed via SSH)
2. **Heartbeat system** - Know which nodes are online in real-time
3. **Self-healing** - Nodes automatically catch up when they come online
4. **Decoupled** - Control plane doesn't need SSH access to nodes
5. **Observable** - Dashboard shows node status

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE                            │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Config API Server (Port 8443 on Tailscale IP)          │   │
│  │                                                          │   │
│  │  Endpoints:                                              │   │
│  │  GET  /api/v1/config/{node-type}  → Config JSON         │   │
│  │  POST /api/v1/heartbeat           → Node reports status │   │
│  │  GET  /api/v1/nodes               → List all nodes      │   │
│  │  GET  /api/v1/health              → API health check    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│  ┌───────────────────────────┴─────────────────────────────┐   │
│  │  Data Sources                                            │   │
│  │  • ConfigMap: service-registry (apps, DNS entries)      │   │
│  │  • ConfigMap: node-registry (registered nodes)          │   │
│  │  • In-memory: heartbeat timestamps                      │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ HTTP over Tailscale (100.x.x.x)
        ┌─────────────────────┼─────────────────────────────────┐
        │                     │                                 │
        ▼                     ▼                                 ▼
┌───────────────┐     ┌───────────────┐              ┌───────────────┐
│  VPS Node     │     │  Laptop       │              │  Worker Node  │
│               │     │               │              │               │
│  Node Agent:  │     │  Node Agent:  │              │  Node Agent:  │
│  • Poll /config    │  • Poll /config              │  • Poll /config
│    every 30s  │     │    every 60s  │              │    every 60s  │
│  • POST       │     │  • POST       │              │  • POST       │
│    /heartbeat │     │    /heartbeat │              │    /heartbeat │
│    every 30s  │     │    every 60s  │              │    every 60s  │
│  • Apply:     │     │  • Apply:     │              │  • Apply:     │
│    Traefik    │     │    /etc/hosts │              │    /etc/hosts │
│    routes     │     │               │              │               │
└───────────────┘     └───────────────┘              └───────────────┘
```

---

## Components

### 1. Config API Server (Control Plane)

A lightweight Go HTTP server (`cmd/config-api/main.go`) running on the control plane.

It speaks plain HTTP, not HTTPS, even though the port is 8443. Traffic is encrypted
by Tailscale's WireGuard tunnel. `--bind=tailscale` (the default, and what the systemd
unit uses) listens on loopback and the Tailscale IP only, and every endpoint except
`/api/v1/health` requires the `X-API-Token` header. The server refuses to start if
the token file is missing or empty.

**Endpoints:**

#### GET /api/v1/config/{node-type}

Returns configuration for a specific node type.

```bash
# Request
curl -H "X-API-Token: <token>" -H "X-Node-Name: dev-laptop" \
     http://100.x.x.x:8443/api/v1/config/laptop

# Response
{
  "version": "v42",
  "timestamp": "2024-12-08T10:00:00Z",
  "dns_entries": [
    {"name": "jellyfin", "ip": "100.118.5.10"},
    {"name": "immich", "ip": "100.118.5.11"}
  ]
}
```

#### GET /api/v1/config/vps

Returns Traefik routes for VPS nodes.

```bash
# Response
{
  "version": "v42",
  "timestamp": "2024-12-08T10:00:00Z",
  "routes": [
    {
      "service": "jellyfin",
      "domain": "jellyfin.example.com",
      "backend": "100.118.5.10:8096"
    }
  ]
}
```

**Empty versus unknown.** Agents act on this difference, so it is part of the contract:

| Response | Meaning | What the agent does |
|----------|---------|---------------------|
| `200` with `"routes": []` or `"dns_entries": []` | The registry was read and there are none | Removes its routes or entries |
| `200` without the field | An older server, which can't express "none" | Keeps what it has |
| `503` | The registry couldn't be read; the version does not advance | Keeps what it has and retries |

`GET /api/v1/health` needs no token and reports `registry_schema`. Schema 2 and later
follow this table and understand `namespace/name` registry keys.

**Moving the registry to `namespace/name` keys is explicit.** Upgrade the config API
first, then run `scripts/lib/service-registry.sh migrate` once on the control plane.
Until then `sync` and `register` keep working: they update bare entries in place, add new
services under `namespace/name`, and `sync` warns. `migrate` refuses while the API doesn't
report schema 2. It moves the registry, then files each route in `routing.json` under the
new key, and records the opt-in in `service-registry/migration.json`. After that, `sync`
and `register` also move any bare entry an old client writes.

An entry remembers the name its route was first published under in `legacy_key`. Nothing
replaces it once it is set. A bare `routing.json` key goes to the one public service with
no record of its own that goes by that name; two claimants mean no route. Such a shared
record stays bare through the migration, because only an operator can say whose it is.

Any service can exclude path prefixes from its public route with a `public_blocked_paths`
field in its registry entry. Nothing is excluded by default, including for `llmapi`.
Tailnet clients using the LoadBalancer IP are not affected.

#### POST /api/v1/heartbeat

Nodes report their status.

```bash
# Request
curl -X POST \
     -H "X-API-Token: <token>" \
     -H "Content-Type: application/json" \
     -d '{
       "node_name": "dev-laptop",
       "node_type": "laptop",
       "node_ip": "100.86.112.112",
       "config_version": "v42",
       "uptime_seconds": 3600
     }' \
     http://100.x.x.x:8443/api/v1/heartbeat

# Response
{"status": "ok", "server_time": "2024-12-08T10:00:00Z"}
```

The server records the address the request came from, not the `node_ip` in the body,
for nodes on the tailnet. A heartbeat using a name that another online node holds is
refused with `409`, so one node can't take over another's entry.

#### GET /api/v1/nodes

Returns status of all registered nodes.

```bash
# Response
{
  "nodes": [
    {
      "name": "dev-laptop",
      "type": "laptop",
      "ip": "100.86.112.112",
      "status": "online",
      "last_heartbeat": "2024-12-08T09:59:30Z",
      "config_version": "v42"
    },
    {
      "name": "contabo-vps",
      "type": "vps",
      "ip": "100.68.225.92",
      "status": "offline",
      "last_heartbeat": "2024-12-08T09:45:00Z",
      "config_version": "v41"
    }
  ]
}
```

**Node Status Logic:**
- `online`: Heartbeat received within last 2 minutes
- `stale`: Heartbeat received within last 10 minutes
- `offline`: No heartbeat for 10+ minutes

### 2. Node Agent (All Nodes)

A lightweight daemon running on each node.

**Responsibilities:**
1. Poll control plane for config changes
2. Send heartbeat to control plane
3. Apply config locally when changed

**Implementation:** Bash script (`scripts/lib/node-agent.sh`, installed as
`/usr/local/bin/mynodeone-node-agent`) + systemd service
(`scripts/lib/mynodeone-node-agent.service`). The real script does more than this
sketch of its loop:

```bash
#!/bin/bash
# node-agent.sh (simplified)

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-100.x.x.x}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_TYPE="${NODE_TYPE:-laptop}"  # laptop, vps, worker
POLL_INTERVAL="${POLL_INTERVAL:-60}"
CONFIG_VERSION=""

while true; do
    # 1. Fetch config
    response=$(curl -s -K <(printf 'header = "X-API-Token: %s"\n' "$API_TOKEN") \
        -H "X-Node-Name: $NODE_NAME" \
        "http://$CONTROL_PLANE_IP:8443/api/v1/config/$NODE_TYPE")
    
    new_version=$(echo "$response" | jq -r '.version')
    
    # 2. Apply if changed
    if [[ "$new_version" != "$CONFIG_VERSION" ]]; then
        apply_config "$response"
        CONFIG_VERSION="$new_version"
    fi
    
    # 3. Send heartbeat
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"node_name\":\"$NODE_NAME\",\"node_type\":\"$NODE_TYPE\",\"config_version\":\"$CONFIG_VERSION\"}" \
        "http://$CONTROL_PLANE_IP:8443/api/v1/heartbeat"
    
    sleep "$POLL_INTERVAL"
done
```

**Apply Logic by Node Type:**

| Node Type | Apply Action |
|-----------|--------------|
| Laptop | Update `/etc/hosts` with DNS entries |
| Worker | Update `/etc/hosts` with DNS entries |
| VPS | Install rendered Traefik routes atomically; Traefik's file watcher picks them up without a restart |

**One `/etc/hosts` writer per host.** Where `mynodeone-local-dns-sync.timer` is enabled
(the control plane), `scripts/domains/sync-dns.sh` owns `/etc/hosts` and the agent leaves
it alone. Stopping the timer for maintenance changes nothing about that, and starting
`mynodeone-local-dns-sync.service` by hand still does its work. To hand the file to the
agent, disable the timer. Everywhere else the agent writes it. The agent's unit runs under
`ProtectSystem=strict` with `/etc/hosts` as a writable bind mount, so the file has to be
written in place: renaming over it fails, and `/etc/hosts.mynodeone.bak` could not be
created, so the backup is `/etc/mynodeone/hosts.bak`. On a VPS whose Traefik directory is
under `/home`, the installer adds a drop-in that makes that directory writable.

The same mount is why nothing here uses `sed -i` on `/etc/hosts`. A rename from outside the
service (`sed -i`, many editors) takes the mount away from the running agent, and its
writes then fail until it gets a new namespace. When a write fails and `/etc/hosts` is no
longer a mount point, the agent exits and `Restart=always` brings it back.

**A route file must be complete.** The agent installs one only if curl finished cleanly
with `200`, and every router names a service defined in the file with a backend. Anything
else leaves the current routes in place and is retried on the next poll.

**Which Traefik directory.** The installers use `--traefik-config-dir` if given, then
`TRAEFIK_CONFIG_DIR` from `agent.env`, then the one directory holding
`mynodeone-routes.yml`, then the one that exists. With several candidates
`install-node-agent.sh` stops and asks for the flag. Settings in `agent.env` that the
installer doesn't know are kept.

### 3. Authentication

Two layers, both always on:

- **Network:** the server listens only on loopback and the Tailscale IP (`--bind=tailscale`).
  Check any Tailscale ACLs too, because every device on the tailnet can reach that address
  unless an ACL says otherwise.
- **Token:** every endpoint except `/api/v1/health` needs `X-API-Token`, from
  `/etc/mynodeone/api-token` on the control plane. A missing or empty token file stops the
  server from starting rather than leaving it open.

There is one shared token, so any node holding it can read every node's config. Per-node
tokens are not implemented. To limit what a leaked token can do, deleting a node is only
allowed from the control plane itself or from the node's own IP, and heartbeats can't
overwrite another node's entry.

mTLS is not implemented.

---

## Architecture: Primary + Fallback

### Primary: HTTP-Based Sync (Node Agent)
- Node Agent installed on all nodes during setup
- Pulls config from Config API Server every 30-60 seconds
- Sends heartbeat to report status
- **Advantages:** Firewall-friendly, no SSH keys needed, real-time node visibility

### Fallback: SSH-Based Sync (Legacy)
- SSH sync controller checks if Node Agent is active before pushing
- If node has recent heartbeat → skip SSH push (Node Agent handles it)
- If node has no heartbeat → fall back to SSH push
- **Use case:** Node is active but Node Agent is not working (crashed, failed install, service stopped)

### Comparison: Node Agent vs SSH Fallback

| Mechanism | Heartbeat | Config Sync | Trigger |
|-----------|-----------|-------------|---------|
| **Node Agent** | ✅ Every 60s | ✅ Pulls on each poll | Continuous (always running) |
| **SSH Fallback** | ❌ None | ✅ Pushes when needed | Event-driven (config change) |

**Key Insight:** The Node Agent handles both heartbeats AND config sync (pulling changes). The SSH fallback only pushes config changes when triggered - it has no heartbeat capability.

### When SSH Fallback Triggers Automatically

The SSH fallback only activates when **both conditions are met**:

1. **A config change occurs** (e.g., app installed/uninstalled → service-registry ConfigMap changes)
2. **The node's heartbeat is stale/offline** (Node Agent not responding)

**Sequence:**
```
App Installed → service-registry updated → Sync Controller triggered
    ↓
Check node heartbeat status via Config API
    ↓
┌─────────────────────────────────────────────────────┐
│ If heartbeat recent (< 2 min):                      │
│   → Skip SSH, Node Agent will pull config          │
│                                                     │
│ If heartbeat stale/offline (> 2 min):              │
│   → Use SSH to push config to node                 │
└─────────────────────────────────────────────────────┘
```

**This means:**
- If no config changes happen, SSH fallback is never triggered (even if Node Agent is stopped)
- To test SSH fallback: stop Node Agent, wait for heartbeat to become stale, then install/uninstall an app

### How Fallback Works

```
┌─────────────────────────────────────────────────────────────┐
│                    Control Plane                            │
│                                                             │
│  ┌─────────────────┐       ┌─────────────────────────────┐ │
│  │ Config API      │       │ SSH Sync Controller         │ │
│  │ Server          │       │ (Fallback)                  │ │
│  │                 │       │                             │ │
│  │ - Serves config │       │ 1. Check: Is node online    │ │
│  │ - Tracks nodes  │◄──────│    in Config API?           │ │
│  │ - Heartbeats    │       │ 2. If YES → skip SSH push   │ │
│  └────────▲────────┘       │ 3. If NO → push via SSH     │ │
│           │                └─────────────────────────────┘ │
└───────────┼─────────────────────────────────────────────────┘
            │
    ┌───────┴───────┐
    │ HTTP Pull     │
    │ (Primary)     │
    ▼               ▼
┌────────┐     ┌────────┐
│ Node   │     │ Node   │
│ Agent  │     │ Agent  │
│ (VPS)  │     │(Laptop)│
└────────┘     └────────┘
```

### Installation

All node types install both mechanisms during setup:
- **Control Plane:** Config API Server + SSH Sync Controller
- **VPS/Worker/Laptop:** Node Agent (SSH access preserved as fallback)

---

## Service Registry Sync

The sync-controller daemon includes automatic service-registry synchronization as part of its periodic reconciliation loop.

### What It Does

Every hour (configurable), the sync-controller automatically:

1. **Discovers new LoadBalancer services** - Auto-registers services that were installed
2. **Cleans up stale entries** - Removes services from deleted namespaces
3. **Updates service-registry ConfigMap** - Keeps registry in sync with cluster state
4. **Maintains manage-app-visibility.sh accuracy** - Ensures service list is current

### Why This Matters

When you delete a namespace with services:
- Kubernetes deletes the services ✅
- **service-registry ConfigMap is NOT automatically updated** ❌
- Without periodic sync, stale entries remain in `manage-app-visibility.sh`

The periodic sync ensures the service-registry stays in sync with the actual cluster state.

### Implementation

The sync runs as part of the `periodic_reconciliation` function in `sync-controller.sh`:

```bash
# Sync service registry (cleanup stale entries, discover new services)
log_info "Syncing service registry..."
if [[ -f "$SCRIPT_DIR/service-registry.sh" ]]; then
    if bash "$SCRIPT_DIR/service-registry.sh" sync 2>&1 | grep -q "Synced"; then
        log_success "Service registry synced"
    else
        log_warn "Service registry sync had issues (non-critical)"
    fi
fi
```

### Configuration

The sync interval is controlled by the reconciliation interval (default: 1 hour):

```bash
# Start daemon with 1-hour reconciliation (includes service-registry sync)
sudo systemctl start mynodeone-sync-controller

# Or manually specify interval
/home/example-user/MyNodeOne/scripts/lib/sync-controller.sh daemon 2  # 2 hours
```

### Manual Sync

If you need to sync immediately (e.g., after deleting namespaces):

```bash
sudo bash /home/example-user/MyNodeOne/scripts/lib/service-registry.sh sync
```

---

## File Structure

```
cmd/
└── config-api/
    └── main.go                   # Go-based Config API Server

scripts/
├── lib/
│   ├── node-agent.sh             # Node agent (bash)
│   ├── mynodeone-config-api.service   # API server systemd unit
│   └── mynodeone-node-agent.service   # Node agent systemd unit
├── install-config-api.sh         # Install API server on control plane
├── install-node-agent.sh         # Install agent on any node
└── nodes-status.sh               # CLI to view node status
```

---

## Configuration

### Control Plane (`scripts/lib/mynodeone-config-api.service`)

The server takes command-line flags, set in the systemd unit:

```bash
mynodeone-config-api \
    --port=8443 \
    --bind=tailscale \
    --token-file=/etc/mynodeone/api-token \
    --require-tailscale=true
```

`--bind` also accepts a specific IP. Avoid `0.0.0.0`: on a machine with a public interface
the token would be the only thing protecting the API, sent over plain HTTP.

### Node (`/etc/mynodeone/agent.env`)

```bash
# Node Agent Configuration
CONTROL_PLANE_IP=100.x.x.x
NODE_NAME=dev-laptop
NODE_TYPE=laptop  # laptop, vps, worker

# Polling intervals (seconds)
POLL_INTERVAL=60
HEARTBEAT_INTERVAL=60

# Required. Root-owned, mode 600.
API_TOKEN=<token>
```

---

## Observability

### CLI Commands

```bash
# Check node status from control plane (requires sudo to read API token)
sudo ./scripts/nodes/nodes-status.sh

# Output:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   MyNodeOne Cluster Nodes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#    NAME                 TYPE     IP                 STATUS     LAST SEEN    CONFIG
#    ----                 ----     --                 ------     ---------    ------
# ●  dev-laptop         laptop   100.86.112.112     online     30s ago      v42
# ●  contabo-vps          vps      100.68.225.92      offline    15m ago      v41
# ●  worker-01            worker   100.90.1.5         online     45s ago      v42
#
# Total: 3 nodes  ● Online: 2  ● Stale: 0  ● Offline: 1
```

### Dashboard Integration

Add node status to `http://mynodeone.local` dashboard:
- Green: Online
- Yellow: Stale (may be sleeping laptop)
- Red: Offline

---

## Comparison: Old vs New

| Aspect | Old (SSH Push) | New (HTTP Pull) |
|--------|----------------|-----------------|
| Direction | Control plane → Nodes | Nodes → Control plane |
| Protocol | SSH | HTTP over Tailscale (WireGuard) |
| Authentication | SSH keys | Tailscale-only bind + shared API token |
| Heartbeat | None | Built-in |
| Offline detection | None | Automatic |
| Scalability | O(n) SSH connections | O(1) API server |
| Control plane recovery | Needs SSH keys | Just run API server |
| Node recovery | Wait for push | Automatic pull |

---

## Future Enhancements

1. **WebSocket for real-time updates** - Instead of polling, nodes maintain WebSocket connection
2. **Config versioning with rollback** - Store config history, allow rollback
3. **Multi-control-plane support** - Nodes can fall back to secondary control plane
4. **Metrics endpoint** - Expose Prometheus metrics from API server

---

## Implementation Status

**Implemented:**
- Config API Server (Go) - `cmd/config-api/main.go`
- Node Agent (Bash) - `scripts/lib/node-agent.sh`
- Systemd services for both components
- Installation scripts
- Node status CLI tool

**Decisions Made:**
- **Go for API server** - Better for scalability and future HA support
- **Tailscale IP + API Token** - Defense in depth authentication
- **ConfigMaps for storage** - Kubernetes-native, already in use
- **SSH kept for other uses** - VPS setup, troubleshooting, kubectl

---

## Installation

### On Control Plane

```bash
sudo ./scripts/installation/install-config-api.sh
```

### On Other Nodes (Laptops, VPS, Workers)

```bash
sudo ./scripts/installation/install-node-agent.sh \
    --control-plane-ip 100.x.x.x \
    --node-type laptop \
    --api-token-file <file-holding-the-control-plane-token>
```

### Check Status

```bash
sudo ./scripts/nodes/nodes-status.sh
```