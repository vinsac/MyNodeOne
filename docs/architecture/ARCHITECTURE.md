# MyNodeOne Architecture

## Overview

MyNodeOne is a distributed cloud infrastructure built on top of Kubernetes (K3s) with a focus on simplicity, scalability, and cost-effectiveness.

## Design Principles

1. **Simplicity First**: Opinionated choices reduce complexity
2. **Horizontal Scalability**: Add machines as you grow
3. **Hybrid Edge-Compute**: VPS handles public traffic, home servers provide compute
4. **GitOps Native**: Infrastructure and apps as code
5. **Production Ready**: Battle-tested open source components

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
  - Replicates data across nodes
  - Creates snapshots and backups
  - Provides PersistentVolumes to Kubernetes
- **Configuration**:
  - Uses available storage on your nodes
  - Replication factor: Adjusts based on node count
  - Default: 1 replica (single node)
  - With 2 nodes: 2 replicas
  - With 3 nodes: 3 replicas

#### MinIO - Object Storage
- **Purpose**: S3-compatible object storage
- **Use cases**:
  - User uploads (photos, videos, files)
  - Static assets (CSS, JS, images)
  - Backups
  - Machine learning datasets
- **Configuration**:
  - Distributed mode (when multiple nodes available)
  - Erasure coding for redundancy
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
VPS Edge Node (45.8.133.192)
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
Longhorn StorageClass
  │
  ↓
Replicated Volume (2x18TB HDDs)
  │
  ├─→ Node 1: Replica 1
  ├─→ Node 2: Replica 2 (when added)
  └─→ Node 3: Replica 3 (when added)
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

- **Connections originate from the inside**: All administrative connections (installation, configuration, synchronization) originate from the Control Plane and connect outwards to edge nodes.
- **No inbound public access to Control Plane**: The Control Plane's SSH port is never exposed to the public internet. It is only accessible via your local LAN or Tailscale.
- **Minimal attack surface**: If a public-facing VPS is compromised, an attacker has no network path or credentials to access the Control Plane.

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
- Production-ready (used by companies like Cisco)

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

**Exception:** Game servers (e.g., Minecraft on port 25565) that require specific ports for protocol compatibility

### Why ArgoCD instead of Flux?
- Better UI
- Easier for beginners
- More features
- Larger community
- Great documentation

## Limitations & Trade-offs

### Single Point of Failure (Current)
- If your control plane node dies, everything is down

### Home ISP Dependencies
- Upload speed limits
- Potential IP blocks (rare)
- Mitigation: VPS edge nodes handle this

### No Multi-Region (Yet)
- All data in one location
- Mitigation: Future feature, can add more regions


## Limitations & Future Improvements

The architecture is designed to be modular and will continue to evolve. Current limitations include single control plane (no HA yet) and single-region deployments. Multi-region support is planned for future releases.
