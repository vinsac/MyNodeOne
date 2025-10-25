# MyNodeOne - Your Private Cloud Infrastructure

> Build your own mini AWS region with commodity hardware

**Version 1.0** - Production Ready • Fully Generic • One Command Setup

**Author:** [Vinay Sachdeva](https://github.com/vinsac)  
**License:** MIT  
**Status:** ✅ Production Ready

---

## 👋 New Here? → **[START HERE](START-HERE.md)**

If you're new to MyNodeOne, start with **[START-HERE.md](START-HERE.md)** for a guided introduction.

**Don't understand the technical terms?** → Check **[GLOSSARY.md](GLOSSARY.md)** for simple explanations!

---

## What is MyNodeOne?

MyNodeOne is a production-ready, scalable private cloud infrastructure that lets you run containerized applications across multiple machines with enterprise-grade features:

✅ **Auto-scaling** across multiple nodes  
✅ **S3-compatible object storage** (MinIO)  
✅ **Distributed block storage** with replication (Longhorn)  
✅ **Automatic SSL certificates** (Let's Encrypt)  
✅ **GitOps deployments** - just push to git! (ArgoCD)  
✅ **Comprehensive monitoring** (Prometheus + Grafana + Loki)  
✅ **Secure networking** (Tailscale mesh - **default** + VPS edge nodes)  
✅ **100% free and open source**

> **Networking:** MyNodeOne uses **Tailscale by default** for secure mesh networking. Zero configuration required!

## 🆕 What's New in Version 1.0

✅ **One Command Setup** - `sudo ./scripts/mynodeone` does everything  
✅ **System Cleanup** - Automatic removal of bloat and unused packages  
✅ **Disk Auto-Detection** - Finds and configures external drives automatically  
✅ **Fully Generic** - Works with ANY hardware, names, IPs  
✅ **Web Documentation** - Deploy docs website to your cluster  
✅ **LLM Support** - Run language models on CPU  
✅ **Complete Networking Guide** - Tailscale + alternatives fully explained  

## Quick Start

```bash
# Clone repository
git clone https://github.com/yourusername/mynodeone.git
cd mynodeone

# Run ONE command (handles everything)
sudo ./scripts/mynodeone

# Follow interactive prompts
# Done in 30 minutes!
```

For detailed guide, see [NEW-QUICKSTART.md](NEW-QUICKSTART.md)

## 🔒 Security Hardening

MyNodeOne includes comprehensive security features:

**Built-in (Automatic):**
- ✅ Firewall (UFW) on all nodes
- ✅ SSH brute-force protection (fail2ban)
- ✅ Strong random passwords (32 chars)
- ✅ Secure credential storage (chmod 600)
- ✅ Encrypted network traffic (Tailscale/WireGuard)

**Optional Hardening (One Command):**
```bash
# After installation, enable additional security
sudo ./scripts/enable-security-hardening.sh
```

Enables:
- Kubernetes audit logging
- Secrets encryption at rest
- Pod Security Standards (restricted)
- Network policies (default deny)
- Resource quotas
- Security headers (HSTS, CSP)

**Documentation:**
- [SECURITY-AUDIT.md](SECURITY-AUDIT.md) - Complete security review
- [docs/security-best-practices.md](docs/security-best-practices.md) - Production security guide  
- [docs/password-management.md](docs/password-management.md) - Password management strategy

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                 │
└────────────────┬────────────────────────────────────────────────┘
                 │
         ┌───────┴────────┐
         │  VPS Edge Nodes │  (Your Public IPs)
         │  - Traefik      │  - SSL termination
         │  - Reverse Proxy│  - DDoS protection
         └───────┬─────────┘
                 │
         ┌───────┴────────┐
         │   Tailscale    │  (Secure mesh: 100.x.x.x IPs)
         │   Overlay      │  - Auto-configured
         └───────┬─────────┘
                 │
    ┌────────────┴────────────────┐
    │                             │
┌───┴────────────┐    ┌───────────┴──────┐    ┌──────────────┐
│  Control Node  │    │   Worker Node    │    │ Worker Node  │
│  (Any Name)    │    │   (Any Name)     │    │  (Any Name)  │
│                │    │                  │    │              │
│ - K3s Master   │    │ - K3s Worker     │    │ - K3s Worker │
│ - Your RAM/CPU │    │ - Your RAM/CPU   │    │ - Your RAM   │
│ - Your Storage │    │ - Your Storage   │    │ - Your Disk  │
│ - Auto-Detected│    │ - Auto-Detected  │    │ - Detected   │
└────────────────┘    └──────────────────┘    └──────────────┘
         │                     │                      │
         └─────────────────────┴──────────────────────┘
                               │
                    ┌──────────┴───────────┐
                    │  Distributed Storage │
                    │  - MinIO (S3)        │
                    │  - Longhorn (Blocks) │
                    └──────────────────────┘
```

## Quick Start

### Prerequisites

- Ubuntu 24.04 LTS (Desktop or Server)
- Tailscale installed on all machines
- Root/sudo access
- Git installed

### 1. Bootstrap Control Plane (First Node)

**Example:** If your first node is named `node-001` or `server-alpha`

```bash
# Clone this repo
git clone https://github.com/yourusername/mynodeone.git
cd mynodeone

# Run bootstrap script
sudo ./scripts/bootstrap-control-plane.sh
```

This will:
- Install K3s as control plane
- Set up Tailscale networking
- Install Cert-Manager for SSL
- Deploy Traefik ingress controller
- Install Longhorn for storage
- Deploy MinIO for object storage
- Install monitoring stack (Prometheus, Grafana, Loki)
- Deploy ArgoCD for GitOps

### 2. Add Worker Nodes (Additional Nodes)

**Example:** Additional nodes like `node-002`, `node-003`, etc.

On each new machine:

```bash
# Run on the NEW worker node
sudo ./scripts/add-worker-node.sh
```

The script will automatically:
- Detect Tailscale network
- Join the K3s cluster
- Configure storage
- Register with monitoring

### 3. Configure VPS Edge Nodes

On each VPS (Contabo):

```bash
# Run on VPS
sudo ./scripts/setup-edge-node.sh
```

This sets up:
- Traefik as reverse proxy
- SSL certificate management
- Routing to your nodes via Tailscale

### 4. Deploy Your First App

```bash
# Create app repository
./scripts/create-app.sh my-awesome-app

# Push your code
cd my-awesome-app
git add .
git commit -m "Initial commit"
git push

# ArgoCD automatically deploys it!
```

## Management

### Access Web UIs

All accessible via Tailscale network from your vivobook:

- **ArgoCD** (GitOps): https://argocd.mynodeone.local
- **Grafana** (Monitoring): https://grafana.mynodeone.local
- **MinIO Console** (S3): https://minio.mynodeone.local
- **Traefik Dashboard**: https://traefik.mynodeone.local

### CLI Tools

```bash
# Check cluster status
kubectl get nodes

# View all apps
argocd app list

# Check storage
kubectl get pv,pvc -A

# Monitor resources
kubectl top nodes
kubectl top pods -A
```

## Storage

### Object Storage (S3-compatible)

```bash
# Access MinIO
mc alias set mynodeone http://minio.mynodeone.local accesskey secretkey

# Create bucket
mc mb mynodeone/my-bucket

# Upload file
mc cp myfile.txt mynodeone/my-bucket/
```

### Block Storage (Persistent Volumes)

Longhorn automatically provisions persistent volumes for your apps. Just request storage in your Kubernetes manifests:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-database
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Gi
```

## Monitoring

Access Grafana at https://grafana.mynodeone.local

Pre-configured dashboards:
- Cluster overview
- Node metrics (CPU, RAM, disk, network)
- Pod metrics
- Storage metrics
- Application logs (Loki)

## Adding Domains

1. Point your domain's DNS to VPS IP addresses:
   ```
   A    @              45.8.133.192
   A    @              31.220.87.37
   AAAA www            45.8.133.192
   AAAA www            31.220.87.37
   ```

2. Create IngressRoute:
   ```yaml
   apiVersion: traefik.containo.us/v1alpha1
   kind: IngressRoute
   metadata:
     name: my-app
   spec:
     entryPoints:
       - websecure
     routes:
       - match: Host(`curiios.com`)
         kind: Rule
         services:
           - name: my-app
             port: 80
     tls:
       certResolver: letsencrypt
   ```

3. SSL certificates are issued automatically!

## 📚 Documentation

### Getting Started
- **[START-HERE.md](START-HERE.md)** - Entry point for new users ⭐
- **[NEW-QUICKSTART.md](NEW-QUICKSTART.md)** - Step-by-step installation guide
- **[NAVIGATION-GUIDE.md](NAVIGATION-GUIDE.md)** - Find what you need quickly
- **[FAQ.md](FAQ.md)** - 50+ questions answered

### User Guides
- **[docs/comparison-guide.md](docs/comparison-guide.md)** - MyNodeOne vs alternatives (OpenStack, Proxmox, etc.) ⭐
- **[docs/setup-options-guide.md](docs/setup-options-guide.md)** - What each option means
- **[docs/networking.md](docs/networking.md)** - Tailscale guide (default)
- **[docs/operations.md](docs/operations.md)** - Daily management
- **[docs/troubleshooting.md](docs/troubleshooting.md)** - Problem solving

### Technical Guides
- **[docs/architecture.md](docs/architecture.md)** - How MyNodeOne works
- **[docs/scaling.md](docs/scaling.md)** - Add more nodes

### Community
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute
- **[dev-docs/](dev-docs/)** - Developer documentation

## Directory Structure

```
mynodeone/
├── scripts/
│   ├── mynodeone                      # ⭐ Main entry point
│   ├── interactive-setup.sh          # Configuration wizard
│   ├── bootstrap-control-plane.sh    # Control plane setup
│   ├── add-worker-node.sh            # Worker addition
│   ├── setup-edge-node.sh            # VPS edge setup
│   ├── create-app.sh                 # App scaffolding
│   └── cluster-status.sh             # Health check
├── manifests/examples/               # Ready-to-deploy apps
│   ├── hello-world-app.yaml
│   ├── postgres-database.yaml
│   ├── redis-cache.yaml
│   ├── fullstack-app.yaml
│   ├── cronjob-backup.yaml
│   └── llm-cpu-inference.yaml        # ⭐ LLM support
├── website/                          # ⭐ Documentation website
│   ├── index.html                    # Landing page
│   └── deploy.sh                     # Deploy to cluster
├── docs/                             # Comprehensive guides
└── config/                           # Configuration templates
```

## Philosophy

MyNodeOne is designed to be:
- **Simple**: Opinionated choices, minimal configuration
- **Scalable**: Add machines as you grow
- **Portable**: Not tied to specific hardware
- **Production-ready**: Battle-tested open source tools
- **Cost-effective**: Use commodity hardware you already own

## Roadmap

- [x] K3s cluster setup
- [x] Distributed storage (MinIO + Longhorn)
- [x] GitOps (ArgoCD)
- [x] Monitoring (Prometheus + Grafana + Loki)
- [x] Automatic SSL
- [ ] Database as a Service (PostgreSQL/MySQL operators)
- [ ] CI/CD pipelines (Tekton)
- [ ] GPU support for LLMs
- [ ] Backup/disaster recovery
- [ ] Multi-region support

## Contributing

MyNodeOne is designed to be a community project. Contributions welcome!

## License

MIT License - Use it however you want!

---

## 📜 Project Information

**Version:** 1.0.0  
**Author:** Vinay Sachdeva  
**License:** MIT  
**Repository:** https://github.com/vinsac/MyNodeOne  

**Development:** Built with assistance from AI tools for enhanced code quality and comprehensive documentation.

---

Built with ❤️ by [Vinay Sachdeva](https://github.com/vinsac) for those who want their own cloud
