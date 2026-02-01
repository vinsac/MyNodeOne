# MyNodeOne Documentation Index

Quick reference for finding what you need in the MyNodeOne repository.

---

## "I want to..."

### Get Started
- **"I'm brand new"** → [GETTING-STARTED.md](guides/GETTING-STARTED.md)
- **"Quick overview"** → [README.md](/README.md)
- **"Install now"** → Run `sudo ./scripts/installation/install-mynodeone.sh`
- **"Step-by-step guide"** → [INSTALLATION.md](installation/INSTALLATION.md)

### Understand MyNodeOne
- **"What are the options?"** → [INSTALLATION.md](installation/INSTALLATION.md) - node types, VPS, worker nodes, and management workstation
- **"How does it work?"** → [ARCHITECTURE.md](architecture/ARCHITECTURE.md)
- **"What about networking?"** → [NETWORKING.md](architecture/NETWORKING.md)
- **"What's new in v2?"** → [SYNC-CONTROLLER-V2.md](architecture/SYNC-CONTROLLER-V2.md)

### Daily usage
- **"How do I manage it?"** → [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md)
- **"Deploy an app"** → Check `manifests/examples/`
- **"Deploy my own app"** → [external-apps/](/external-apps) - One command deployment
- **"Check cluster health"** → Run `./scripts/operations/cluster-status.sh`
- **"Add more nodes"** → [scaling.md](operations/scaling.md)

### Troubleshooting
- **"Something broke"** → [troubleshooting.md](operations/troubleshooting.md)
- **"Common questions"** → [FAQ.md](reference/FAQ.md)
- **"Network issues"** → [NETWORKING.md](architecture/NETWORKING.md)

### Advanced
- **"Architecture deep-dive"** → [ARCHITECTURE.md](architecture/ARCHITECTURE.md)
- **"Sync system design"** → [SYNC-CONTROLLER-V2.md](architecture/SYNC-CONTROLLER-V2.md)
- **"Contribute"** → [CONTRIBUTING.md](/CONTRIBUTING.md)

---

## File Organization

```
mynodeone/
├── README.md                         ← Project overview
├── CONTRIBUTING.md                   ← How to contribute
├── scripts/                          ← Automation
│   ├── mynodeone                     ← Main installer
│   └── apps/                         ← App installation scripts
├── docs/
│   ├── installation/                 ← Installation guides
│   │   ├── INSTALLATION.md           ← Main installation guide
│   │   ├── POST_INSTALLATION_GUIDE.md← After installation
│   │   └── UNINSTALL.md              ← Removing MyNodeOne
│   ├── operations/                   ← Cluster management
│   │   ├── CLUSTER-MANAGEMENT.md     ← Day-to-day operations
│   │   ├── DOMAIN-AND-PUBLIC-ACCESS.md ← Domains and public apps
│   │   ├── MULTI-DOMAIN-SETUP.md     ← Advanced multi-domain setup
│   │   ├── NODE-MANAGEMENT.md        ← Adding/removing nodes
│   │   ├── VPS-EDGE-NODE-METADATA.md ← VPS node metadata management
│   │   ├── scaling.md                ← Adding nodes
│   │   └── troubleshooting.md        ← Problem solving
│   ├── guides/                       ← User guides
│   │   ├── GETTING-STARTED.md        ← Entry point for new users
│   │   ├── TERMINAL-BASICS.md        ← Terminal for beginners
│   │   ├── BEGINNER-GUIDE.md         ← Complete beginner's tutorial
│   │   ├── ADMIN-GUIDE.md             ← Cluster administration
│   │   └── MOBILE-ACCESS-GUIDE.md    ← Phone/tablet access
│   ├── apps/                         ← App catalog
│   │  → See [APP-STORE.md](apps/APP-STORE.md) for available applications
│   ├── reference/                    ← Reference documentation
│   │   ├── FAQ.md                    ← Common questions
│   │   └── GLOSSARY.md               ← Technical terms explained
│   ├── security/                     ← Security documentation
│   │   ├── SECURITY.md               ← Security overview
│   │   ├── PASSWORD-MANAGEMENT.md    ← Credential storage
│   │   └── BEST-PRACTICES.md         ← Production hardening
│   ├── architecture/                 ← System architecture
│   │   ├── ARCHITECTURE.md           ← Overall design
│   │   ├── DNS.md                    ← DNS configuration
│   │   ├── GPU-SUPPORT.md            ← NVIDIA GPU setup for AI/ML workloads
│   │   ├── NETWORKING.md             ← Tailscale and networking
│   │   ├── REVERSE-PROXY.md          ← Traefik routing (multi-domain, SSL)
│   │   ├── REGISTRY-ARCHITECTURE.md  ← Node registry system
│   │   ├── STORAGE-ARCHITECTURE.md   ← Longhorn and MinIO design
│   │   ├── SYNC-CONTROLLER-V2.md     ← Node sync (HTTP pull + heartbeat) - PRIMARY
│   │   └── SYNC-CONTROLLER.md        ← Node sync (SSH push) - FALLBACK
│   └── use-cases/                    ← Deployment scenarios (moved to website)
├── manifests/                        ← Kubernetes manifests
└── website/                          ← Dashboard
```

---

## Reading Order by Experience Level

### Complete Beginner (Never used Kubernetes)
1. [TERMINAL-BASICS.md](guides/TERMINAL-BASICS.md) - 10 min (if new to terminal)
2. [GETTING-STARTED.md](guides/GETTING-STARTED.md) - 5 min
3. [README.md](/README.md) - 5 min
4. [BEGINNER-GUIDE.md](guides/BEGINNER-GUIDE.md) - 15 min
5. [INSTALLATION.md](installation/INSTALLATION.md) - 20 min
6. [FAQ.md](reference/FAQ.md) - Common questions and scenarios
7. Install: `sudo ./scripts/installation/install-mynodeone.sh`
8. [POST_INSTALLATION_GUIDE.md](installation/POST_INSTALLATION_GUIDE.md) - After install
9. [ADMIN-GUIDE.md](guides/ADMIN-GUIDE.md) - Daily operations
10. [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md) - Cluster management

### Intermediate (Some Linux/Docker experience)
1. [README.md](/README.md) - 5 min
2. [INSTALLATION.md](installation/INSTALLATION.md) - 10 min
3. [ARCHITECTURE.md](architecture/ARCHITECTURE.md) - 15 min
4. Install: `sudo ./scripts/installation/install-mynodeone.sh`
5. [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md) - Reference
6. [scaling.md](operations/scaling.md) - When ready to grow

### Advanced (Kubernetes experience)
1. [ARCHITECTURE.md](architecture/ARCHITECTURE.md) - Technical design
2. Install: `sudo ./scripts/installation/install-mynodeone.sh`
3. Explore: `manifests/` and `scripts/`
4. [CONTRIBUTING.md](/CONTRIBUTING.md) - Help improve

---

## Find Specific Topics

### Installation & Setup
- Main installer: `scripts/installation/install-mynodeone.sh`
- Installation guide: [INSTALLATION.md](installation/INSTALLATION.md)
- Setup options: [INSTALLATION.md](installation/INSTALLATION.md) - node types and scenarios
- Configuration wizard: `scripts/installation/interactive-setup.sh`
- VPS Edge Node Setup: [INSTALLATION.md](installation/INSTALLATION.md#section-2-vps-edge-node-installation)

### Comparisons & Alternatives
- **MyNodeOne vs Alternatives:** See [FAQ.md](reference/FAQ.md) - Comparison questions
- MyNodeOne vs OpenStack
- MyNodeOne vs Proxmox
- MyNodeOne vs Bare Kubernetes
- MyNodeOne vs Docker Compose
- MyNodeOne vs Managed K8s (AWS/GCP/Azure)
- When to use MyNodeOne?
- Decision tree and use cases

### Networking
- Default (Tailscale): [NETWORKING.md](architecture/NETWORKING.md)
- All options: [NETWORKING.md](architecture/NETWORKING.md) - Section "Alternative Solutions"
- Troubleshooting: [troubleshooting.md](operations/troubleshooting.md)

### Storage
- Architecture: [ARCHITECTURE.md](architecture/ARCHITECTURE.md) - Section "Storage Layer"
- Operations: [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md)
- FAQ: [FAQ.md](reference/FAQ.md) - Storage questions

### Applications
- Example apps: `manifests/examples/`
- Create new app: `scripts/operations/create-app.sh`
- Deploy guide: [APP-STORE.md](apps/APP-STORE.md)
- **Deploy your own apps:** [external-apps/](/external-apps) (All materials consolidated here)
- LLM support: `manifests/examples/llm-cpu-inference.yaml`

### Monitoring
- Setup: Automatic during installation
- Usage: [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md)
- Troubleshooting: [troubleshooting.md](operations/troubleshooting.md)

### Scaling
- Add workers: [scaling.md](operations/scaling.md)
- Add VPS: [INSTALLATION.md](installation/INSTALLATION.md) - Section 2
- Add VPS Edge Node: [INSTALLATION.md](installation/INSTALLATION.md#section-2-vps-edge-node-installation)
- High availability: [ARCHITECTURE.md](architecture/ARCHITECTURE.md)

---

## Quick Answers

**"Where do I start?"**  
→ [GETTING-STARTED.md](guides/GETTING-STARTED.md)

**"How do I install?"**  
→ `sudo ./scripts/installation/install-mynodeone.sh`

**"What's Tailscale?"**  
→ [NETWORKING.md](architecture/NETWORKING.md) - Default networking

**"What options do I have?"**  
→ [INSTALLATION.md](installation/INSTALLATION.md) - node types and basic scenarios

**"How do I add nodes?"**  
→ [scaling.md](operations/scaling.md)

**"Something's broken!"**  
→ [troubleshooting.md](operations/troubleshooting.md)

**"How does this work?"**  
→ [ARCHITECTURE.md](architecture/ARCHITECTURE.md)

**"I have a question..."**  
→ [FAQ.md](reference/FAQ.md)

**"How do I add a domain to my VPS?"**  
→ [DOMAIN-AND-PUBLIC-ACCESS.md](operations/DOMAIN-AND-PUBLIC-ACCESS.md)

**"How do I expose apps publicly?"**  
→ [DOMAIN-AND-PUBLIC-ACCESS.md](operations/DOMAIN-AND-PUBLIC-ACCESS.md)

**"How do I deploy my own apps?"**  
→ [external-apps/](/external-apps) - Everything in one place

**"Can I keep my app code separate?"**  
→ Yes! See [external-apps/README.md](/external-apps/README.md)

---

## Documentation by Type

### Guides (how-to)
- [INSTALLATION.md](installation/INSTALLATION.md) - installation walkthrough
- [BEGINNER-GUIDE.md](guides/BEGINNER-GUIDE.md) - complete beginner tutorial
- [ADMIN-GUIDE.md](guides/ADMIN-GUIDE.md) - cluster administration
- [MOBILE-ACCESS-GUIDE.md](guides/MOBILE-ACCESS-GUIDE.md) - phone/tablet setup
- [DOMAIN-AND-PUBLIC-ACCESS.md](operations/DOMAIN-AND-PUBLIC-ACCESS.md) - domains and public apps
- [VPS-EDGE-NODE-METADATA.md](operations/VPS-EDGE-NODE-METADATA.md) - VPS node metadata management
- [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md) - daily management
- [scaling.md](operations/scaling.md) - growth strategies
- [troubleshooting.md](operations/troubleshooting.md) - problem solving

### Explanations (understanding)
- [README.md](/README.md) - what MyNodeOne is
- [ARCHITECTURE.md](architecture/ARCHITECTURE.md) - how it works
- [NETWORKING.md](architecture/NETWORKING.md) - networking explained

### Reference (lookup)
- [FAQ.md](reference/FAQ.md) - Q&A format
- [GLOSSARY.md](reference/GLOSSARY.md) - technical terms explained
- `scripts/` - all automation

### Tutorials (Learning)
- [GETTING-STARTED.md](guides/GETTING-STARTED.md) - Guided introduction
- [INSTALLATION.md](installation/INSTALLATION.md) - Step-by-step
- `manifests/examples/` - Example deployments

---

## Your Next Action

Based on where you are:

### Just Discovered MyNodeOne
→ Read [GETTING-STARTED.md](guides/GETTING-STARTED.md)

### Ready to Install
→ Run `sudo ./scripts/installation/install-mynodeone.sh`

### Already Installed
→ Check [CLUSTER-MANAGEMENT.md](operations/CLUSTER-MANAGEMENT.md)

### Having Issues
→ See [troubleshooting.md](operations/troubleshooting.md)

### Want to Learn More
→ Read [ARCHITECTURE.md](architecture/ARCHITECTURE.md)

### Ready to Grow
→ Follow [scaling.md](operations/scaling.md)

---

**Still lost?** Start at [GETTING-STARTED.md](guides/GETTING-STARTED.md) - it guides you through everything!