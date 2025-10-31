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

- 🎮 **Your gaming PC** when you're not gaming (perfect control plane!)
- 🖥️ **Old laptops** gathering dust
- 💻 **Mini PCs** (Intel NUC, Raspberry Pi 4/5, Beelink, etc.)
- 🏠 **Home servers** you already have
- 🛒 **Used enterprise hardware** from eBay ($200-$500)
- ⚡ **Mix and match** - use whatever you have!

**Popular Setup:** Gaming PC as control plane + old laptop as worker node = Powerful private cloud!

**No expensive enterprise gear required. No monthly cloud bills. Just your hardware, your data, your control.**

---

## 👋 New Here? → **[GETTING-STARTED.md](docs/guides/GETTING-STARTED.md)**

If you're new to MyNodeOne, start with **[GETTING-STARTED.md](docs/guides/GETTING-STARTED.md)** for a guided introduction.

**Never used terminal/command line?** → Read **[TERMINAL-BASICS.md](docs/TERMINAL-BASICS.md)** first!

**Don't understand the technical terms?** → Check **[GLOSSARY.md](docs/GLOSSARY.md)** for simple explanations!

---

## 📚 Documentation Quick Links

### 🎯 Use Cases & Solutions
- **[USE-CASES.md](docs/use-cases/README.md)** - Overview of all use cases
- **[Enterprise SaaS](docs/use-cases/enterprise-saas.md)** - Save $100K+/year on compliance infrastructure
- **[Dev/Test/QA](docs/use-cases/devtest-qa.md)** - Unlimited development environments
- **Personal Cloud** - Replace $500/year in subscriptions (see docs/guides/BEGINNER-GUIDE.md)
- Coming soon: Small SaaS, API Products, Data Analytics, Internal Tools, Education

### 🚀 For Everyone
- **[QUICK-START.md](docs/guides/QUICK-START.md)** - Install your first app in 10 minutes
- **[ACCESS-CHEAT-SHEET.md](docs/reference/ACCESS-CHEAT-SHEET.md)** - All your app URLs (print this!)
- **[APP-STORE.md](docs/reference/APP-STORE.md)** - Browse 10+ one-click apps (Jellyfin, Immich, etc.)

### 👶 For Non-Technical Users
- **[BEGINNER-GUIDE.md](docs/guides/BEGINNER-GUIDE.md)** - Step-by-step guide, no experience needed
- **[MOBILE-ACCESS-GUIDE.md](docs/guides/MOBILE-ACCESS-GUIDE.md)** - How to use apps on your phone
- Access dashboard: `http://mynodeone.local` (after installation)
- Interactive app store: `sudo ./scripts/app-store.sh`

### 🔧 For Technical Users
- **[INSTALLATION.md](docs/guides/INSTALLATION.md)** - Full installation documentation
- **[docs/architecture.md](docs/architecture.md)** - System architecture details
- **[FAQ.md](docs/reference/FAQ.md)** - Frequently asked questions

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

## ✨ Core Features (Version 1.0)

✅ **One Command Setup** - `sudo ./scripts/mynodeone` does everything  
✅ **Local Dashboard** - Access at `http://mynodeone.local` after installation  
✅ **One-Click App Store** - Install 10+ self-hosted apps (Jellyfin, Immich, Vaultwarden, etc.)  
✅ **System Cleanup** - Automatic removal of bloat and unused packages  
✅ **Disk Auto-Detection** - Finds and configures external drives automatically  
✅ **Fully Generic** - Works with ANY hardware, names, IPs  
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
- ✅ Strong random passwords (32 characters)
- ✅ Secure credential storage (chmod 600)
- ✅ Encrypted network traffic (Tailscale/WireGuard)

**Additional Hardening (RECOMMENDED for Production):**
```bash
# Run RIGHT AFTER control plane installation, BEFORE adding workers
sudo ./scripts/enable-security-hardening.sh
```

**⚠️ Important:** Apply this on your control plane **BEFORE** adding worker nodes! Security policies will then automatically apply to all workers.

**Enables:**
- ✅ Kubernetes audit logging (track all API activity)
- ✅ Secrets encryption at rest (encrypt etcd database)
- ✅ Pod Security Standards (restrict container privileges)
- ✅ Network policies (default deny, explicit allow)
- ✅ Resource quotas (prevent resource exhaustion)
- ✅ Security headers (HSTS, CSP, X-Frame-Options)

**Takes:** 3-5 minutes | **Required:** No, but HIGHLY recommended | **Skip if:** Learning/testing only

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
│ Control Plane  │    │   Worker Node    │    │ Worker Node  │
│  (Any Name)    │    │   (Any Name)     │    │  (Any Name)  │
│                │    │                  │    │              │
│ - K3s Server   │    │ - K3s Worker     │    │ - K3s Worker │
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

> 💡 **Understanding Command Output:** Not sure if a command worked? Copy the output and ask ChatGPT, Gemini, or Claude: "Did this command succeed?" They can instantly help you understand what you're seeing!

- **Ubuntu 24.04 LTS** (Desktop or Server) - **Recommended**
  - Also compatible: Ubuntu 22.04 LTS, Ubuntu 20.04 LTS
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
  
  **Success looks like:** `Setting up git...` with no error messages. Verify with `git --version`
  
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
  
  **Expected outputs:**
  - Install: Shows `Setting up openssh-server...` 
  - Start: No output = success! (silence is good)
  - Enable: May show `Synchronizing state...` or nothing = success!
  
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
  
  **Expected outputs:**
  - curl: `curl is already the newest version` or `Setting up curl...`
  - Tailscale install: Shows progress, ends with `Installation complete!`
  - tailscale up: Shows a URL to open, then displays `Success.` when complete ✅
  
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
- **Deploy local dashboard** at http://mynodeone.local
- Configure Tailscale subnet routes automatically

**⚠️ IMPORTANT:** After installation completes, **approve the Tailscale subnet route** (30 seconds):
1. Go to https://login.tailscale.com/admin/machines
2. Find your control plane machine → Edit route settings
3. Enable the subnet route (shown in installation output)
4. Click Save

This enables `.local` domain access from your laptop (e.g., `http://grafana.mynodeone.local`).

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

### 4. Deploy Your First App (Demo)

**Option A: During Installation** - When prompted, say 'yes' to deploy demo app

**Option B: After Installation** - Run this command on your control plane:

```bash
# Deploy demo application to verify cluster works
sudo ./scripts/deploy-demo-app.sh deploy
```

This deploys a secure web app that shows:
- ✅ Cluster is operational
- ✅ LoadBalancer working (gets Tailscale IP)
- ✅ Security features active
- ✅ Storage and networking functional

**Access the demo:**
- URL will be shown after deployment (e.g., http://100.x.x.x)
- Open in browser on any device connected to Tailscale

**Remove when done:**
```bash
sudo ./scripts/deploy-demo-app.sh remove
```

**See [DEMO_APP_GUIDE.md](DEMO_APP_GUIDE.md) for detailed instructions**

## 🎯 One-Click App Installation

MyNodeOne includes an **App Store** with ready-to-deploy applications:

### Quick Access
```bash
# Interactive app store menu
sudo ./scripts/app-store.sh

# Or visit the dashboard
# Open http://mynodeone.local in your browser
```

### Available Apps (10+ and growing!)

**Media & Entertainment:**
- 🎬 **Jellyfin** - Netflix-like media server
- 🎮 **Minecraft** - Game server

**Photos & Files:**
- 📸 **Immich** - Google Photos alternative with AI
- ☁️ **Nextcloud** - Cloud storage (coming soon)

**Security:**
- 🔐 **Vaultwarden** - Password manager (Bitwarden)
- 🏠 **Homepage** - Beautiful dashboard

**And more:** Plex, Gitea, Mattermost, Uptime Kuma, Paperless-ngx, Audiobookshelf

**See [APP-STORE.md](APP-STORE.md) for complete guide and installation instructions**

### Example: Install Jellyfin Media Server
```bash
# One command - fully automated
sudo ./scripts/apps/install-jellyfin.sh

# Result: Complete media server with:
# ✅ Automatic storage configuration
# ✅ LoadBalancer IP assigned
# ✅ Ready to add your movies/TV shows
# ✅ Mobile apps available for iOS/Android
```

## Management

### Access Web UIs

All services accessible via Tailscale network (LoadBalancer IPs):

```bash
# View all service URLs and credentials
sudo ./scripts/show-credentials.sh
```

**Services are accessible at Tailscale IPs (100.x.x.x) or .local domains:**
- **Dashboard**: http://mynodeone.local (main control center)
- **Grafana** (Monitoring): http://grafana.mynodeone.local
- **ArgoCD** (GitOps): https://argocd.mynodeone.local
- **MinIO Console** (S3): http://minio.mynodeone.local:9001
- **Longhorn UI** (Storage): http://longhorn.mynodeone.local

See [ACCESS_INFORMATION.md](ACCESS_INFORMATION.md) for complete access details and credentials.

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
# Get MinIO credentials
sudo ./scripts/show-credentials.sh

# Access MinIO (replace with your IP from show-credentials.sh)
mc alias set mynodeone http://100.x.x.x:9000 <access-key> <secret-key>

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

Access Grafana at the URL shown during installation (Tailscale IP).

```bash
# View Grafana URL and credentials
sudo ./scripts/show-credentials.sh
```

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
- **[POST_INSTALLATION_GUIDE.md](docs/guides/POST_INSTALLATION_GUIDE.md)** - What to do after installation ⭐ **READ THIS FIRST!**
- **[QUICK_START.md](docs/guides/QUICK_START.md)** - 5-minute quick reference
- **[FAQ.md](FAQ.md)** - 50+ questions answered

### For Non-Technical Users 👋
- **[POST_INSTALLATION_GUIDE.md](docs/guides/POST_INSTALLATION_GUIDE.md)** - Complete guide for beginners ⭐ **START HERE**
- **[DEMO_APP_GUIDE.md](docs/guides/DEMO_APP_GUIDE.md)** - Deploy your first app (step-by-step)
- **[TERMINAL-BASICS.md](docs/guides/TERMINAL-BASICS.md)** - Never used command line? Start here!
- **[GLOSSARY.md](docs/reference/GLOSSARY.md)** - Understand the technical terms

### Application Deployment
- **[APP_DEPLOYMENT_GUIDE.md](docs/guides/APP_DEPLOYMENT_GUIDE.md)** - Complete deployment guide
- **scripts/manage-apps.sh** - One-click app deployment (PostgreSQL, MySQL, Redis)
- **scripts/deploy-demo-app.sh** - Deploy demo application
- **scripts/deploy-llm-chat.sh** - Deploy local AI chat (Open WebUI + Ollama) ⭐ NEW
- **[DEMO_APP_GUIDE.md](docs/guides/DEMO_APP_GUIDE.md)** - Detailed demo app instructions

### Security & Credentials 🔒
- **[SECURITY_CREDENTIALS_GUIDE.md](docs/guides/SECURITY_CREDENTIALS_GUIDE.md)** - Security best practices
- **[ACCESS_INFORMATION.md](docs/reference/ACCESS_INFORMATION.md)** - Service URLs and credentials
- **scripts/show-credentials.sh** - View all credentials (reads from Kubernetes securely)
- **⚠️ IMPORTANT:** Credentials auto-deleted after you save them during installation

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
