# Sync Controller V2 - Pull-Based Architecture

This document describes the redesigned sync controller that replaces SSH-based push with HTTP-based pull and heartbeat.

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
                              │ HTTPS over Tailscale (100.x.x.x)
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

A lightweight HTTP server running on the control plane.

**Implementation Options:**
- Go binary (single file, easy to distribute)
- Python Flask (easier to modify)
- Bash + netcat (simplest, limited features)

**Endpoints:**

#### GET /api/v1/config/{node-type}

Returns configuration for a specific node type.

```bash
# Request
curl -H "X-Node-Name: vinay-laptop" \
     https://100.x.x.x:8443/api/v1/config/laptop

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

#### POST /api/v1/heartbeat

Nodes report their status.

```bash
# Request
curl -X POST \
     -H "Content-Type: application/json" \
     -d '{
       "node_name": "vinay-laptop",
       "node_type": "laptop",
       "node_ip": "100.86.112.112",
       "config_version": "v42",
       "uptime_seconds": 3600
     }' \
     https://100.x.x.x:8443/api/v1/heartbeat

# Response
{"status": "ok", "server_time": "2024-12-08T10:00:00Z"}
```

#### GET /api/v1/nodes

Returns status of all registered nodes.

```bash
# Response
{
  "nodes": [
    {
      "name": "vinay-laptop",
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

**Implementation:** Bash script + systemd service

```bash
#!/bin/bash
# mynodeone-agent.sh

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-100.x.x.x}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
NODE_TYPE="${NODE_TYPE:-laptop}"  # laptop, vps, worker
POLL_INTERVAL="${POLL_INTERVAL:-60}"
CONFIG_VERSION=""

while true; do
    # 1. Fetch config
    response=$(curl -s -H "X-Node-Name: $NODE_NAME" \
        "https://$CONTROL_PLANE_IP:8443/api/v1/config/$NODE_TYPE")
    
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
        "https://$CONTROL_PLANE_IP:8443/api/v1/heartbeat"
    
    sleep "$POLL_INTERVAL"
done
```

**Apply Logic by Node Type:**

| Node Type | Apply Action |
|-----------|--------------|
| Laptop | Update `/etc/hosts` with DNS entries |
| Worker | Update `/etc/hosts` with DNS entries |
| VPS | Generate Traefik routes, reload Traefik |

### 3. Authentication

**Option A: Tailscale IP Verification (Recommended)**
- API server only listens on Tailscale IP (100.x.x.x)
- Only devices on the Tailscale network can reach it
- No additional auth needed

**Option B: Shared Secret**
- Generate a secret during installation
- Nodes include it in `Authorization` header
- Stored in `/etc/mynodeone/agent.env`

**Option C: mTLS**
- Each node has a client certificate
- Most secure but complex to manage

**Recommendation:** Start with Option A (Tailscale IP verification). Add Option B if needed.

---

## Migration Plan

### Phase 1: Add Config API Server (Parallel)
- Deploy API server on control plane
- Keep existing SSH-based sync running
- Test API endpoints manually

### Phase 2: Deploy Node Agent to VPS
- VPS nodes are most critical (public traffic)
- Test pull-based config + heartbeat
- Verify Traefik routes update correctly

### Phase 3: Deploy Node Agent to Laptops/Workers
- Lower risk (internal DNS only)
- Test heartbeat visibility

### Phase 4: Remove SSH-Based Sync
- Disable old sync controller
- Remove SSH key requirements
- Update documentation

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

### Control Plane (`/etc/mynodeone/config-api.env`)

```bash
# API Server Configuration
API_PORT=8443
API_BIND_IP=0.0.0.0  # Tailscale handles access control

# Heartbeat settings
HEARTBEAT_ONLINE_THRESHOLD=120    # seconds
HEARTBEAT_STALE_THRESHOLD=600     # seconds

# Optional: Shared secret for auth
# API_SECRET=your-secret-here
```

### Node (`/etc/mynodeone/agent.env`)

```bash
# Node Agent Configuration
CONTROL_PLANE_IP=100.x.x.x
NODE_NAME=vinay-laptop
NODE_TYPE=laptop  # laptop, vps, worker

# Polling intervals (seconds)
POLL_INTERVAL=60
HEARTBEAT_INTERVAL=60

# Optional: Shared secret for auth
# API_SECRET=your-secret-here
```

---

## Observability

### CLI Commands

```bash
# Check node status from control plane
./scripts/nodes-status.sh

# Output:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#   MyNodeOne Cluster Nodes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#    NAME                 TYPE     IP                 STATUS     LAST SEEN    CONFIG
#    ----                 ----     --                 ------     ---------    ------
# ●  vinay-laptop         laptop   100.86.112.112     online     30s ago      v42
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
| Protocol | SSH | HTTPS |
| Authentication | SSH keys | Tailscale IP / shared secret |
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
sudo ./scripts/install-config-api.sh
```

### On Other Nodes (Laptops, VPS, Workers)

```bash
sudo ./scripts/install-node-agent.sh \
    --control-plane-ip 100.x.x.x \
    --node-type laptop \
    --api-token <token-from-control-plane>
```

### Check Status

```bash
./scripts/nodes-status.sh
```
