# NodeZero Architecture

## Overview

NodeZero is a distributed cloud infrastructure built on top of Kubernetes (K3s) with a focus on simplicity, scalability, and cost-effectiveness.

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

**Control Plane Node (toronto-0001)**
- Runs K3s server
- Hosts cluster state (etcd)
- Schedules workloads
- Also acts as worker node

**Worker Nodes (toronto-000x)**
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
  - Uses 2x18TB HDDs on Toronto nodes
  - Replication factor: Adjusts based on node count
  - Default: 1 replica (toronto-0001 only)
  - With toronto-0002: 2 replicas
  - With toronto-0003: 3 replicas

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
Developer (vivobook: 100.122.30.88)
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
  ├─→ toronto-0001: Replica 1
  ├─→ toronto-0002: Replica 2 (when added)
  └─→ toronto-0003: Replica 3 (when added)
```

## Scaling Scenarios

### Scenario 1: Single Node (Current)
- toronto-0001: Control plane + worker
- Storage: Local only, no replication
- HA: None (downtime if node fails)
- Suitable for: Development, testing, low-traffic apps

### Scenario 2: Three Nodes (In 2 months)
- toronto-0001: Control plane + worker
- toronto-0002: Worker
- toronto-0003: Worker
- Storage: 3x replication (high durability)
- HA: Apps survive 1 node failure
- Suitable for: Production apps, higher traffic

### Scenario 3: Multiple Regions (Future)
- Toronto cluster (toronto-000x)
- Montreal cluster (montreal-000x)
- Cross-region replication
- Geo-routing via VPS edge nodes

## Security Architecture

### Network Security
- **Tailscale**: WireGuard-based encryption
- **VPS Firewall**: Only 80, 443, 22 open
- **Internal services**: Only accessible via Tailscale
- **No public exposure**: Toronto nodes not directly internet-accessible

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

### toronto-0001 (256GB RAM, Ryzen 9950X)

**Control Plane** (~4GB RAM)
- K3s server
- etcd
- CoreDNS
- Metrics server

**Storage** (~20GB RAM)
- Longhorn manager
- MinIO

**Monitoring** (~8GB RAM)
- Prometheus
- Grafana
- Loki

**GitOps** (~2GB RAM)
- ArgoCD

**Available for Apps** (~222GB RAM)
- Your applications run here
- Can run 50-100+ microservices
- Or several large apps (LLMs, databases)

## Comparison with Cloud Providers

| Feature | NodeZero | AWS | GCP | Azure |
|---------|----------|-----|-----|-------|
| **Cost (monthly)** | ~$30 (VPS only) | $500+ | $500+ | $500+ |
| **Compute** | 256GB RAM, 32 cores | Extra charges | Extra charges | Extra charges |
| **Storage** | 36TB included | $1000+/mo | $1000+/mo | $1000+/mo |
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

### Why ArgoCD instead of Flux?
- Better UI
- Easier for beginners
- More features
- Larger community
- Great documentation

## Limitations & Trade-offs

### Single Point of Failure (Current)
- If toronto-0001 dies, everything is down
- Mitigation: Add toronto-0002, toronto-0003

### Home ISP Dependencies
- Upload speed limits (500 Mbps is good though)
- Potential IP blocks (rare)
- Mitigation: VPS edge nodes handle this

### No Multi-Region (Yet)
- All data in one location
- Mitigation: Future feature, can add more regions

### Manual VPS Configuration
- Need to configure routes manually
- Mitigation: Can be automated in future versions

## Future Enhancements

### Planned Features
1. **Database Operators**: One-click PostgreSQL, MySQL, Redis
2. **GPU Support**: For running local LLMs
3. **Backup/Restore**: Automated backups to cloud storage
4. **Multi-region**: Toronto + Montreal clusters
5. **Service Mesh**: Istio/Linkerd for advanced networking
6. **CI/CD**: Tekton pipelines for complex workflows
7. **Monitoring Alerts**: PagerDuty/Slack integration
8. **Cost Dashboard**: Track per-app resource usage

### Community Wishlist
- One-click apps marketplace
- Terraform modules
- Helm charts repository
- Mobile app for monitoring
- Desktop GUI for management

## Contributing

The architecture is designed to be modular. Want to add a feature? Submit a PR!

Areas for contribution:
- Operators for databases
- Monitoring dashboards
- Example applications
- Documentation improvements
- Bug fixes and optimizations

---

**Questions?** Open an issue on GitHub!
