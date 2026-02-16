# MyNodeOne Architecture

## Overview

MyNodeOne is a distributed cloud infrastructure built on top of Kubernetes (K3s) with a focus on simplicity, scalability, and cost-effectiveness.

## Design Principles

1. **Simplicity First**: Opinionated choices reduce complexity
2. **Horizontal Scalability**: Add machines as you grow
3. **Hybrid Edge-Compute**: VPS handles public traffic, home servers provide compute
4. **GitOps Native**: Infrastructure and apps as code
5. **Open Source Stack**: Uses well-maintained open source components (K3s, Longhorn, MinIO)

## Architecture Layers

### 1. Network Layer

#### Tailscale Mesh Network
- **Purpose**: Secure, encrypted connectivity between all nodes
- **Why**: NAT traversal, automatic peering, zero-trust security
- **Components**:
  - All nodes join the same Tailscale network
  - Private IPs (100.x.x.x range) for inter-node communication
  - No need to configure firewalls or port forwarding

#### Public Edge (VPS Nodes)
- **Purpose**: Handle internet traffic, SSL termination, DDoS protection
- **Why**: Home ISPs often block port 80/443, dynamic IPs, bandwidth caps
- **Components**:
  - Traefik reverse proxy
  - Let's Encrypt integration
  - Traffic routing to Toronto nodes via Tailscale

```
Internet → VPS (Public IP) → Tailscale → Toronto Nodes
```

### 2. Compute Layer

#### K3s Cluster
- **Why K3s over K8s**: 
  - 50% less memory footprint
  - Single binary, easy installation
  - Perfect for edge/IoT/home use
  - Full Kubernetes API compatibility

#### Node Types

**Control Plane Node (Example: control-plane)**
- Runs K3s server
- Hosts cluster state (etcd)
- Schedules workloads
- Also acts as worker node

**Worker Nodes (Example: worker-001, worker-002)**
- Run application workloads
- Can be added/removed dynamically
- Automatically discovered via Tailscale

**Edge Nodes (VPS)**
- Not part of K8s cluster
- Act as reverse proxies
- Monitor and route traffic

### 3. Storage Layer

#### Longhorn - Distributed Block Storage
- **Purpose**: Persistent volumes for databases, stateful apps
- **How it works**:
  - Provides block storage with replica count of 1
  - Creates snapshots and backups
  - Provides PersistentVolumes to Kubernetes
- **Configuration**:
  - Uses available storage on your nodes
  - **Fixed replica count: 1** (no cross-node replication)
  - 5-day rebuild wait to avoid network traffic over limited bandwidth
  - Optimized for home lab environments

#### MinIO - Object Storage
- **Purpose**: S3-compatible object storage
- **Use cases**:
  - User uploads (photos, videos, files)
  - Static assets (CSS, JS, images)
  - Backups
  - Machine learning datasets
- **Configuration**:
  - **Independent instances per node** (not distributed)
  - Each node has separate MinIO with unique credentials
  - MetalLB LoadBalancer for each instance
  - Compatible with AWS S3 SDK

### 4. Networking & Load Balancing

#### MetalLB
- **Purpose**: LoadBalancer service type on bare metal
- **How it works**:
  - Assigns IP addresses from Tailscale subnet
  - Announces IPs via L2 (ARP) or BGP
  - Services get stable IPs

#### Traefik Ingress
- **Purpose**: HTTP/HTTPS routing, SSL termination
- **Features**:
  - Automatic Let's Encrypt certificates
  - Path-based and host-based routing
  - Middleware (auth, rate limiting, etc.)
  - Dynamic configuration

### 5. Observability Layer

#### Prometheus
- **Purpose**: Metrics collection and alerting
- **Metrics collected**:
  - Node metrics (CPU, RAM, disk, network)
  - Container metrics
  - Application metrics
  - Storage metrics (Longhorn)

#### Grafana
- **Purpose**: Metrics visualization
- **Pre-configured dashboards**:
  - Cluster overview
  - Node details
  - Application performance
  - Storage utilization

#### Loki
- **Purpose**: Log aggregation
- **How it works**:
  - Promtail collects logs from all containers
  - Loki indexes and stores logs
  - Query via Grafana
  - Similar to ELK stack but lighter

### 6. GitOps Layer

#### ArgoCD
- **Purpose**: Continuous delivery for Kubernetes
- **Workflow**:
  1. Developer pushes code to GitHub
  2. GitHub Actions builds Docker image
  3. Updates Kubernetes manifest in git
  4. ArgoCD detects change
  5. Syncs to cluster
  6. Application deployed
- **Benefits**:
  - Git as single source of truth
  - Automatic deployments
  - Easy rollbacks
  - Visual UI

## Traffic Flow

### Public Web Application

```
User
  │
  │ HTTPS
  ↓
VPS Edge Node (192.0.2.100)
  │
  │ Traefik (SSL termination, routing)
  ↓
Tailscale Tunnel (encrypted)
  │
  ↓
Toronto Node (100.103.104.109)
  │
  │ Traefik Ingress Controller
  ↓
Kubernetes Service
  │
  ↓
Application Pods (replicated)
```

### Internal Service Access

```
Developer (laptop: 100.x.x.x)
  │
  │ Tailscale
  ↓
Direct access to:
  - Grafana (monitoring)
  - ArgoCD (deployments)
  - MinIO Console (storage)
  - Longhorn UI (storage management)
  - Kubernetes API (kubectl)
```

## Data Flow

### Object Storage (MinIO)

```
Application
  │
  │ S3 API
  ↓
MinIO Service
  │
  ↓
Longhorn PersistentVolume
  │
  ↓
Local Disk (replicated across nodes)
```

### Database Storage

```
PostgreSQL Pod
  │
  │ PersistentVolumeClaim (100Gi)
  ↓
Longhorn StorageClass (replica=1 default)
  │
  ↓
Longhorn Volume (local disk)
  │
  └─→ Single replica on scheduling node
      (user can increase via Longhorn UI if multi-node)
```

## Scaling Scenarios

### Scenario 1: Single Node
- Your first node: Control plane + worker
- Storage: Local only, no replication
- HA: None (downtime if node fails)
- Suitable for: Development, testing, low-traffic apps

### Scenario 2: Three Nodes
- Node 1: Control plane + worker
- Node 2: Worker
- Node 3: Worker
- Storage: 3x replication (high durability)
- HA: Apps survive 1 node failure
- Suitable for: Production apps, higher traffic

### Scenario 3: Multiple Regions
- Home cluster (node-001, node-002)
- Office cluster (node-003, node-004)
- Cross-region replication
- Geo-routing via VPS edge nodes

## Security Architecture

### Direction of Trust

A fundamental security principle in MyNodeOne is the **unidirectional flow of trust and connectivity**. The cluster's internal network, especially the Control Plane, is considered a secure, trusted zone. All external nodes, such as a public-facing VPS Edge Node, are considered untrusted.

- **Nodes pull config from Control Plane**: Each node runs a Node Agent that polls the control plane for configuration updates and sends heartbeats. This is firewall-friendly and requires no SSH keys between nodes.
- **SSH fallback for edge cases**: If a Node Agent is not working, the control plane can push config via SSH as a fallback.
- **No inbound public access to Control Plane**: The Control Plane's SSH port is never exposed to the public internet. It is only accessible via your local LAN or Tailscale.
- **Minimal attack surface**: If a public-facing VPS is compromised, an attacker has no network path or credentials to access the Control Plane.

## Configuration Sync Architecture

MyNodeOne uses a **pull-based configuration distribution** model where nodes pull config from the control plane, rather than the control plane pushing to nodes. This is more secure and firewall-friendly.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Config API** | Control Plane | Serves config to nodes via HTTP API |
| **Node Agent** | Each node (VPS, laptop, worker) | Polls Config API for updates, applies config |
| **Sync Controller** | Control Plane | Fallback SSH push, reconciliation |
| **ConfigMaps** | Kubernetes | Source of truth for all config |

### Node Agent (V2 Sync - Primary)

The Node Agent runs as a systemd service on each node and handles:

1. **Config Polling**: Fetches `/api/v1/config/{node-type}` every 60 seconds
2. **Heartbeat**: Reports node status every 60 seconds
3. **Config Application**: Applies routes (VPS) or DNS entries (laptop/worker)

```
┌─────────────────────────────────────────────────────────────────┐
│                        CONTROL PLANE                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐     ┌─────────────────────────────────┐   │
│  │   ConfigMaps    │────>│         Config API               │   │
│  │ (service-reg,   │     │  - GET /api/v1/config/vps        │   │
│  │  domain-reg)    │     │  - GET /api/v1/config/laptop     │   │
│  └─────────────────┘     │  - POST /api/v1/heartbeat        │   │
│                          │  - GET /api/v1/nodes             │   │
│                          └──────────────┬──────────────────┘   │
│                                         │                       │
└─────────────────────────────────────────│───────────────────────┘
                                          │ HTTP (Tailscale)
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
                    ▼                     ▼                     ▼
           ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
           │  VPS Node     │     │    Laptop     │     │    Worker     │
           │  Agent        │     │    Agent      │     │    Agent      │
           │               │     │               │     │               │
           │ • Poll /60s   │     │ • Poll /60s   │     │ • Poll /60s   │
           │ • Apply routes│     │ • Apply DNS   │     │ • Apply DNS   │
           │ • Heartbeat   │     │ • Heartbeat   │     │ • Heartbeat   │
           └───────────────┘     └───────────────┘     └───────────────┘
```

### Config Types by Node

| Node Type | Config Received | Action |
|-----------|-----------------|--------|
| **VPS** | Traefik routes (services → backends) | Writes `mynodeone-routes.yml` |
| **Laptop** | DNS entries (local_name → IP) | Updates `/etc/hosts` |
| **Worker** | DNS entries (local_name → IP) | Updates `/etc/hosts` |

### Making Apps Public - Sync Flow

When you make an app public via `manage-app-visibility.sh`:

```
Time    Control Plane                    Config API                      VPS Node Agent
─────   ──────────────────────────       ──────────────────              ──────────────────
 0s     Update ConfigMaps
        (service-registry,
         domain-registry)
                                         │
~30s                                     Detect ConfigMap change
                                         Update internal version
                                         │
~60s                                                                     Poll /api/v1/config/vps
                                         ◄───────────────────────────────
                                         Return routes JSON
                                         ─────────────────────────────────►
                                                                         Apply routes to Traefik
                                                                         (mynodeone-routes.yml)
                                         │
~90s    Poll VPS to verify routes ───────────────────────────────────────►
        ✓ Routes found! Done.
```

**Maximum delay**: ~90 seconds (30s Config API detection + 60s Node Agent poll)

### SSH Fallback (V1 Sync)

If the Node Agent doesn't sync within 2 minutes, the system falls back to SSH:

```bash
# Automatic fallback in manage-app-visibility.sh
ssh user@vps "cd ~/mynodeone && sudo ./scripts/vps/sync-vps-routes.sh"
```

This ensures reliability even if the Node Agent is down or misconfigured.

### Sync Controller

The Sync Controller runs on the control plane and provides:

1. **`push`**: Push to nodes without active Node Agent
2. **`push-force`**: Force SSH push to all nodes (for troubleshooting)
3. **`watch`**: Watch ConfigMaps for changes, push to V1 nodes
4. **`daemon`**: Combined watch + periodic reconciliation

```bash
# Check sync status
sudo ./scripts/lib/sync-controller.sh health

# Force sync to all nodes (bypasses Node Agent)
sudo ./scripts/lib/sync-controller.sh push-force
```

### Why Pull-Based?

| Push (SSH) | Pull (Node Agent) |
|------------|-------------------|
| Requires SSH keys on all nodes | No SSH keys needed |
| Control plane must reach nodes | Nodes reach control plane |
| Blocked by firewalls | Works through NAT/firewalls |
| Immediate | ~60s delay (acceptable) |
| Single point of failure | Nodes retry independently |

The pull-based model is more resilient and works in restrictive network environments where nodes can't be reached from the control plane.

## Service Registry Architecture

MyNodeOne uses two Kubernetes ConfigMaps as the source of truth for service identity and routing:

### ConfigMaps

| ConfigMap | Namespace | Purpose |
|-----------|-----------|---------|
| `service-registry` | `kube-system` | Stores service metadata: `local_name`, IP, port, namespace, `public` flag |
| `domain-registry` | `kube-system` | Stores registered domains, VPS nodes, and `routing.json` (expose arrays) |

### Clean Separation Principle

A service's **local identity** and **public identity** are completely independent:

```
service-registry (local identity)          domain-registry routing.json (public identity)
┌──────────────────────────────┐          ┌──────────────────────────────────────┐
│ "open-webui": {              │          │ "open-webui": {                      │
│   "local_name": "chat",     │──────X───│   "expose": ["curiios.com",          │
│   "ip": "100.x.x.201",     │  NO LINK │              "www.curiios.com"],      │
│   "public": true            │          │   "vps_nodes": ["100.x.x.92"],       │
│ }                            │          │   "strategy": "round-robin"           │
└──────────────────────────────┘          └──────────────────────────────────────┘
         │                                              │
         ▼                                              ▼
  chat.mynodeone.local                     https://curiios.com (via VPS Traefik)
  (DNS on laptops/workers)                 https://www.curiios.com
```

- **`local_name`** drives `.local` DNS entries only (e.g., `chat` → `chat.mynodeone.local`)
- **`expose`** drives public Traefik routes on VPS nodes (e.g., `curiios.com`)
- Changing one never affects the other

### Service Registration Flow

When an app is installed, registration happens in two places:

```
Install Script (e.g., install-jellyfin.sh)
  │
  ├─ 1. Creates K8s Service with annotation:
  │     mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
  │
  ├─ 2. Calls service-registry.sh register (direct registration)
  │     Key = K8s service name (e.g., "jellyfin")
  │
  └─ 3. Calls post-install-routing.sh (DNS update + user guidance)
        Key = K8s service name (must match step 2)
```

**Critical rule**: The registry key (first argument to `register` and `post-install-routing`) **must match the Kubernetes service name**. This is because `sync_registry` (which runs periodically) discovers services by their K8s name. A mismatch creates duplicate entries.

### sync_registry Discovery

`service-registry.sh sync` discovers all LoadBalancer services in the cluster and registers them:

1. Finds all K8s services with `type: LoadBalancer` and an assigned IP
2. For each service, determines `local_name` by:
   - **First**: Checking `mynodeone.io/subdomain` annotation on the K8s Service
   - **Fallback**: Checking `${CLUSTER_DOMAIN}.local/subdomain` annotation (legacy)
   - **Last resort**: Hardcoded case statement mapping (e.g., `argocd-server` → `argocd`)
3. Preserves existing `public` flag (doesn't reset to false on re-sync)
4. Removes stale entries for services that no longer exist

### Annotation Standard

All app install scripts must add this annotation to their K8s Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: my-app
  annotations:
    mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
spec:
  type: LoadBalancer
  ...
```

This ensures `sync_registry` picks up the correct `local_name` regardless of the K8s service name.

### Dashboard Bare-Domain Entry

The `dashboard` service gets a special additional DNS entry: the bare cluster domain (e.g., `mynodeone.local`) in addition to `dashboard.mynodeone.local`. This is consistent across all DNS paths:
- `service-registry.sh export_dns`
- Config API `getDNSEntries`
- `node-agent.sh apply_dns_config`

---

### Network Security
- **Tailscale**: WireGuard-based encryption
- **VPS Firewall**: Only 80, 443, 22 open
- **Internal services**: Only accessible via Tailscale
- **No public exposure**: Home/office nodes not directly internet-accessible

### Access Control
- **Kubernetes RBAC**: Role-based access control
- **ArgoCD**: SSO integration possible
- **MinIO**: IAM policies for buckets
- **Grafana**: Built-in authentication

### Data Security
- **At-rest**: Longhorn encryption (can be enabled)
- **In-transit**: TLS everywhere
- **Backups**: Longhorn snapshots to S3

## Resource Allocation

### Example Control Plane (16GB RAM, 4 cores)

**System Overhead** (~6GB RAM)
- K3s server, etcd, CoreDNS, Metrics server (~2GB)
- Longhorn manager (~1GB)
- Monitoring stack (Prometheus, Grafana, Loki) (~2GB)
- ArgoCD (~1GB)

**Available for Apps** (~10GB RAM)
- Your applications run here
- Suitable for several lightweight apps or a few medium apps

### Larger Setup (32GB+ RAM)

With more RAM, you can run heavier workloads like databases, media servers, or LLMs. Add worker nodes to scale horizontally.

## Comparison with Cloud Providers

Example: Home machine with 64GB RAM and 18TB storage, plus a $10/month VPS for public access.

| Feature | MyNodeOne | AWS | GCP | Azure |
|---------|----------|-----|-----|-------|
| **Cost (monthly)** | ~$10 (VPS only) | $500+ | $500+ | $500+ |
| **Compute** | 64GB RAM, 8+ cores | Extra charges | Extra charges | Extra charges |
| **Storage** | 18TB included | $1000+/mo | $1000+/mo | $1000+/mo |
| **Egress** | Unlimited (home ISP) | $0.09/GB | $0.12/GB | $0.08/GB |
| **Control** | Full | Limited | Limited | Limited |
| **Privacy** | 100% | Shared infra | Shared infra | Shared infra |
| **Latency** | Local | Variable | Variable | Variable |

## Technology Choices Explained

### Why K3s instead of K8s?
- 50% less memory usage
- Easier installation
- Same API as K8s
- Widely adopted (used by Rancher, SUSE, and many companies)

### Why Tailscale instead of VPN?
- Zero configuration
- NAT traversal (works behind any router)
- Automatic peering
- Mobile support
- Free for personal use

### Why Longhorn instead of Ceph/Rook?
- Simpler setup
- Lower resource usage
- Better UI
- Built for Kubernetes
- Used by Rancher/SUSE

### Why MinIO instead of SeaweedFS/Ceph?
- S3 compatibility
- Mature and stable
- Great performance
- Active development
- Easy to operate

### Why Traefik instead of Nginx?
- Native Kubernetes support
- Dynamic configuration
- Automatic Let's Encrypt
- Better observability
- Modern architecture

### Why All Apps Use Port 80?

MyNodeOne standardizes all web applications on port 80 externally, regardless of what port the application uses internally.

**The Problem:**
- Different apps run on different ports (Immich: 3001, Jellyfin: 8096, Homepage: 3000)
- Users must remember which app uses which port
- URLs like `http://immich.local:3001` are confusing for non-technical users
- Mobile app configuration becomes error-prone

**The Solution:**
```yaml
# Kubernetes Service configuration
spec:
  type: LoadBalancer
  ports:
  - port: 80          # External: standard HTTP port
    targetPort: 3001  # Internal: app's native port
```

**Result:**
| App | Internal Port | User Access |
|-----|---------------|-------------|
| Immich | 3001 | `http://immich.mynodeone.local` |
| Jellyfin | 8096 | `http://jellyfin.mynodeone.local` |
| Grafana | 3000 | `http://grafana.mynodeone.local` |

**Benefits:**
- Simple, consistent URLs for all apps
- No port numbers to remember
- Works like any website
- Easy mobile app configuration
- Professional appearance

**Security Note:** This does not reduce security. All services remain accessible only via Tailscale VPN. The port number (80 vs 3001) has no security impact—what matters is network isolation (Tailscale) and authentication (each app's login).

### Why ArgoCD instead of Flux?
- Better UI
- Easier for beginners
- More features
- Larger community
- Great documentation

## Limitations & Trade-offs

### Single Point of Failure (Current)
- If your control plane node dies, everything is down
- Mitigation: K3s automated etcd snapshots every 6 hours for state recovery

### Home ISP Dependencies
- Upload speed limits
- Potential IP blocks (rare)
- Mitigation: VPS edge nodes handle this

### No Multi-Region (Yet)
- All data in one location
- Mitigation: Future feature, can add more regions

The architecture is designed to be modular and will continue to evolve. Multi-region support is planned for future releases.