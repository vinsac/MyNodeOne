# MyNodeOne - Your Private Cloud Infrastructure

> **Transform consumer hardware into enterprise cloud infrastructure**

**Build your own AWS-like cloud using regular computers, old laptops, mini PCs, or servers you already own**

**Version 1.0** - Production Ready • Consumer Hardware Focused • One Command Setup

**Author:** [Vinay Sachdeva](https://github.com/vinsac)  
**License:** MIT  
**Status:** ✅ Production Ready

---

## 💡 The Vision

**Turn everyday hardware into powerful cloud infrastructure.** MyNodeOne lets you build an enterprise-grade private cloud using:

- 🖥️ **Old laptops** gathering dust
- 💻 **Mini PCs** (Intel NUC, Raspberry Pi 4/5, Beelink, etc.)
- 🏠 **Home servers** you already have
- 🛒 **Used enterprise hardware** from eBay ($200-$500)
- ⚡ **Mix and match** - use whatever you have!

**No expensive enterprise gear required. No monthly cloud bills. Just your hardware, your data, your control.**

---

## 👋 New Here? → **[GETTING-STARTED.md](GETTING-STARTED.md)**

If you're new to MyNodeOne, start with **[GETTING-STARTED.md](GETTING-STARTED.md)** for a guided introduction.

**Never used terminal/command line?** → Read **[TERMINAL-BASICS.md](TERMINAL-BASICS.md)** first!

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

## 🖥️ Real-World Hardware Examples

**MyNodeOne works on everyday consumer hardware:**

### Example Setup 1: $0 (Use what you have)
- **Old laptop** (2015+, 8GB RAM) → Control plane
- **Mini PC** (Intel NUC, 4GB RAM) → Worker node
- **Raspberry Pi 5** (8GB) → Edge/worker node
- **Total cost:** $0 (using existing hardware)

### Example Setup 2: ~$400 Budget Build
- **Used Dell Optiplex** ($150, 16GB RAM, 500GB SSD) → Control plane
- **2x Mini PC** ($100 each, 8GB RAM) → Worker nodes
- **$5/month VPS** (optional, for public access)
- **Total:** ~$400 one-time + $5/month (optional)

### Example Setup 3: Power User ($800-1000)
- **Intel NUC** ($400, 32GB RAM, 1TB NVMe) → Control plane
- **2x Beelink Mini PC** ($200 each, 16GB RAM) → Workers
- **Total:** ~$800 (scales to 50+ services easily)

### Example Setup 4: VPS-Only (No Home Hardware)
- **2-3 VPS servers** ($15-20/month each)
  - 1x Control plane (4GB+ RAM)
  - 1-2x Worker nodes (2GB+ RAM)
- **Total:** ~$30-60/month
- **Perfect for:** No home hardware, 100% cloud-based, public internet access
- **Providers:** Contabo, Hetzner, DigitalOcean, Linode, Vultr

**Compatible with:**
- x86_64: Intel/AMD processors (most common)
- ARM64: Raspberry Pi 4/5, Apple Silicon (M1/M2)
- Any Ubuntu 24.04 LTS compatible machine

## 🚀 Ready to Install?

**→ Go to [INSTALLATION.md](INSTALLATION.md) for complete step-by-step installation!**

**That guide includes:**
- ✅ Prerequisites (what to install first)
- ✅ Which machine to use
- ✅ Where to run commands
- ✅ Complete installation process
- ✅ How to add more machines

**Time:** 30 minutes from start to finish!

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

- **Ubuntu 24.04 LTS** (Desktop or Server)
  - **New to Ubuntu?** For installation instructions, refer to the [official Ubuntu installation guide](https://ubuntu.com/tutorials/install-ubuntu-desktop) or search "how to install Ubuntu 24.04" on ChatGPT, Gemini, or your preferred AI assistant.
- **Git installed**
  
  **First, open your terminal:**
  - Press `Ctrl + Alt + T` on Ubuntu Desktop
  - Or see [TERMINAL-BASICS.md](TERMINAL-BASICS.md) for help
  
  **Then run these commands:**
  ```bash
  # Update package list
  sudo apt update
  
  # (Optional) Upgrade system packages - RECOMMENDED for fresh installations
  # WARNING: Skip this on existing/production machines to avoid breaking changes
  # sudo apt upgrade -y
  
  # Install git
  sudo apt install -y git
  ```
  - For assistance with git installation, consult ChatGPT, Gemini, or search online.

- **SSH Server installed** (required on ALL machines - control plane AND workers)
  
  **In the same terminal, run:**
  ```bash
  # Install OpenSSH Server:
  sudo apt install -y openssh-server
  
  # Start and enable SSH:
  sudo systemctl start ssh
  sudo systemctl enable ssh
  
  # Verify it's running:
  sudo systemctl status ssh
  ```
  
  **How to know if it's running:**
  - ✅ Look for `Active: active (running)` in **green** text = Good!
  - ❌ Look for `Active: inactive` or **red** text = Run start/enable commands above
  - Press `q` to exit the status screen
  
  - **Why needed on ALL nodes:** Control plane uses SSH to remotely configure worker nodes
  - For SSH troubleshooting, consult ChatGPT, Gemini, or search online.

- **Tailscale installed** on all machines
  
  **In the same terminal, run:**
  ```bash
  # Install curl (if not already installed):
  sudo apt install -y curl
  
  # Install Tailscale:
  curl -fsSL https://tailscale.com/install.sh | sh
  
  # Connect to your Tailscale network:
  sudo tailscale up
  # This will:
  # 1. Open a browser window (or show a URL)
  # 2. Ask you to log in with Google, Microsoft, or GitHub
  # 3. Approve this device on your Tailscale network
  # 4. Assign a 100.x.x.x IP address to this machine
  ```
  - **First time?** Sign up for free at https://tailscale.com before running this
  - **No browser?** Copy the URL shown and open it on another device
  - **Need help with Tailscale?** Ask ChatGPT, Gemini, or see [docs/networking.md](docs/networking.md)

- **Root/sudo access**

> **Need Help?** If you encounter any issues following these steps or understanding the commands, feel free to consult ChatGPT, Gemini, Claude, or other AI assistants for guidance.

---

## 🎯 Choosing Your Control Plane Machine

If you have **multiple machines**, choose your control plane wisely:

**Recommended characteristics:**
- ✅ **Most RAM/CPU** - Control plane runs cluster management + your workloads
- ✅ **Most reliable** - Should stay running 24/7
- ✅ **Best network** - Central location with good connectivity
- ✅ **Most storage** - Will host monitoring data, logs, and system databases

**Examples:**
- **Home setup:** Your most powerful desktop/server (not a laptop that moves around)
- **Multiple servers:** The one with 32GB+ RAM vs others with 8-16GB
- **Mixed hardware:** Intel NUC with 32GB RAM > Raspberry Pi with 8GB RAM

**Single machine?** No problem - it will be both control plane and worker!

---

### 1. Bootstrap Control Plane (First Node)

**Example:** If your first node is named `node-001` or `server-alpha`

```bash
# Clone this repo (HTTPS or SSH):
git clone https://github.com/vinsac/MyNodeOne.git
# OR: git clone git@github.com:vinsac/MyNodeOne.git

cd MyNodeOne

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

On each VPS (Contabo, DigitalOcean, Hetzner, Linode, Vultr, etc.):

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

## Adding Custom Domains

**Do you need this?** Only if you want your apps accessible via your own domain name (e.g., `myapp.com`) from the public internet. Skip if you're only using internal/Tailscale access.

### Option 1: Use the Helper Script (Recommended for Beginners)

```bash
# Easy way - let the script do the work!
./scripts/create-app.sh my-app --domain myapp.com --port 3000

# This automatically:
# - Creates the necessary configuration
# - Sets up SSL certificates
# - Configures routing
```

### Option 2: Manual Setup (Advanced Users)

**Step 1:** Point your domain's DNS to your VPS IP address(es):
```
Type  Name  Value              TTL
A     @     <your-vps-ip>      3600
A     www   <your-vps-ip>      3600
```

**Step 2:** Create an IngressRoute file (save as `my-app-ingress.yaml`):
```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.com`) || Host(`www.myapp.com`)
      kind: Rule
      services:
        - name: my-app
          port: 80
  tls:
    certResolver: letsencrypt
```

**Step 3:** Apply the configuration:
```bash
kubectl apply -f my-app-ingress.yaml
```

**Step 4:** Wait 1-2 minutes for SSL certificates to be issued automatically!

**Need help?** Check [docs/operations.md](docs/operations.md) for detailed deployment guides or use the helper script above.

## 📚 Documentation

### Getting Started
- **[GETTING-STARTED.md](GETTING-STARTED.md)** - Entry point for new users ⭐
- **[INSTALLATION.md](INSTALLATION.md)** - Step-by-step installation guide
- **[DOCUMENTATION-INDEX.md](DOCUMENTATION-INDEX.md)** - Find what you need quickly
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
