# MyNodeOne Documentation Index

Quick reference for finding what you need in the MyNodeOne repository.

---

## "I want to..."

### Get Started
- **"I'm brand new"** → [GETTING-STARTED.md](../guides/GETTING-STARTED.md)
- **"Quick overview"** → [README.md](../../README.md)
- **"Install now"** → Run `sudo ./scripts/mynodeone`
- **"Step-by-step guide"** → [INSTALLATION.md](../installation/INSTALLATION.md)

### Understand MyNodeOne
- **"What are the options?"** → [INSTALLATION.md](../installation/INSTALLATION.md) - node types, VPS, worker nodes, and management workstation
- **"How does it work?"** → [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- **"What about networking?"** → [networking.md](networking.md)
- **"What's new in v2?"** → [UPDATES-v2.md](UPDATES-v2.md)

### Daily usage
- **"How do I manage it?"** → [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md)
- **"Deploy an app"** → Check `manifests/examples/`
- **"Check cluster health"** → Run `./scripts/cluster-status.sh`
- **"Add more nodes"** → [scaling.md](../guides/scaling.md)

### Troubleshooting
- **"Something broke"** → [troubleshooting.md](../guides/troubleshooting.md)
- **"Common questions"** → [FAQ](FAQ.md)
- **"Network issues"** → [networking.md](networking.md)

### Advanced
- **"Complete technical docs"** → [FINAL-SUMMARY.md](FINAL-SUMMARY.md)
- **"Design decisions"** → [ANSWERS-TO-QUESTIONS.md](ANSWERS-TO-QUESTIONS.md)
- **"Contribute"** → [CONTRIBUTING.md](CONTRIBUTING.md)

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
│   │   └── CLUSTER-MANAGEMENT.md     ← Day-to-day operations
│   ├── guides/                       ← How-to guides
│   │   ├── GETTING-STARTED.md        ← Entry point for new users
│   │   └── TERMINAL-BASICS.md        ← Terminal for beginners
│   ├── reference/                    ← Reference documentation
│   │   ├── APP-STORE.md              ← Available apps
│   │   ├── FAQ.md                    ← Common questions
│   │   └── GLOSSARY.md               ← Term definitions
│   ├── architecture/                 ← System architecture
│   └── use-cases/                    ← Deployment scenarios
├── manifests/                        ← Kubernetes manifests
└── website/                          ← Dashboard
```

---

## Reading Order by Experience Level

### Complete Beginner (Never used Kubernetes)
1. [TERMINAL-BASICS.md](../guides/TERMINAL-BASICS.md) - 10 min (if new to terminal)
2. [GETTING-STARTED.md](../guides/GETTING-STARTED.md) - 5 min
3. [README.md](../../README.md) - 5 min
4. [INSTALLATION.md](../installation/INSTALLATION.md) - 20 min
5. [FAQ.md](FAQ.md) - Common questions and scenarios
6. Install: `sudo ./scripts/mynodeone`
7. [POST_INSTALLATION_GUIDE.md](../installation/POST_INSTALLATION_GUIDE.md) - After install
8. [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md) - Daily operations

### Intermediate (Some Linux/Docker experience)
1. [README.md](../../README.md) - 5 min
2. [INSTALLATION.md](../installation/INSTALLATION.md) - 10 min
3. [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - 15 min
4. Install: `sudo ./scripts/mynodeone`
5. [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md) - Reference
6. [scaling.md](../guides/scaling.md) - When ready to grow

### Advanced (Kubernetes experience)
1. [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - Technical design
2. [REPO-STRUCTURE.md](REPO-STRUCTURE.md) - Repository layout
3. Install: `sudo ./scripts/mynodeone`
4. Explore: `manifests/` and `scripts/`
5. [dev-docs/](dev-docs/) - Developer documentation
6. [CONTRIBUTING.md](CONTRIBUTING.md) - Help improve

---

## Find Specific Topics

### Installation & Setup
- Main installer: `scripts/mynodeone`
- Installation guide: [INSTALLATION.md](../installation/INSTALLATION.md)
- Setup options: [INSTALLATION.md](../installation/INSTALLATION.md) - node types and scenarios
- Configuration wizard: `scripts/interactive-setup.sh`
- VPS Edge Node Setup: [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md)
- VPS Installation: [VPS-INSTALLATION.md](../installation/VPS-INSTALLATION.md)

### Comparisons & Alternatives
- **MyNodeOne vs Alternatives:** [comparison-guide.md](comparison-guide.md)
- MyNodeOne vs OpenStack
- MyNodeOne vs Proxmox
- MyNodeOne vs Bare Kubernetes
- MyNodeOne vs Docker Compose
- MyNodeOne vs Managed K8s (AWS/GCP/Azure)
- When to use MyNodeOne?
- Decision tree and use cases

### Networking
- Default (Tailscale): [networking.md](networking.md)
- All options: [networking.md](networking.md) - Section "Alternative Solutions"
- Troubleshooting: [troubleshooting.md](../guides/troubleshooting.md)

### Storage
- Disk setup: [storage-guide.md](storage-guide.md)
- Architecture: [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - Section "Storage Layer"
- Operations: [operations.md](../guides/operations.md) - Section "Storage Management"

### Applications
- Example apps: `manifests/examples/`
- Create new app: `scripts/create-app.sh`
- Deploy guide: [operations.md](../guides/operations.md)
- LLM support: `manifests/examples/llm-cpu-inference.yaml`

### Monitoring
- Setup: Automatic during installation
- Usage: [operations.md](../guides/operations.md) - Section "Monitoring"
- Troubleshooting: [troubleshooting.md](../guides/troubleshooting.md)

### Scaling
- Add workers: [scaling.md](../guides/scaling.md)
- Add VPS: [INSTALLATION.md](../installation/INSTALLATION.md) - Section 2
- Add VPS Edge Node: [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md)
- High availability: [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)

---

## Quick Answers

**"Where do I start?"**  
→ [GETTING-STARTED.md](../guides/GETTING-STARTED.md)

**"How do I install?"**  
→ `sudo ./scripts/mynodeone`

**"What's Tailscale?"**  
→ [networking.md](networking.md) - Default networking (automatic)

**"What options do I have?"**  
→ [INSTALLATION.md](../installation/INSTALLATION.md) - node types and basic scenarios

**"How do I add nodes?"**  
→ [scaling.md](../guides/scaling.md)

**"Something's broken!"**  
→ [troubleshooting.md](../guides/troubleshooting.md)

**"How does this work?"**  
→ [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)

**"I have a question..."**  
→ [FAQ.md](FAQ.md)

**"How do I add a domain to my VPS?"**  
→ [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md)

**"How do I expose apps publicly?"**  
→ [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md)

---

## Documentation by Type

### Guides (how-to)
- [INSTALLATION.md](../installation/INSTALLATION.md) - installation walkthrough
- [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md) - VPS edge node and domain setup
- [VPS-INSTALLATION.md](../installation/VPS-INSTALLATION.md) - VPS control plane setup
- [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md) - daily management
- [scaling.md](../guides/scaling.md) - growth strategies
- [troubleshooting.md](../guides/troubleshooting.md) - problem solving

### Explanations (understanding)
- [README.md](../../README.md) - what MyNodeOne is
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - how it works
- [storage-guide.md](storage-guide.md) - storage options explained
- [networking.md](networking.md) - networking explained

### Reference (lookup)
- [FAQ](FAQ.md) - Q&A format
- [FINAL-SUMMARY.md](FINAL-SUMMARY.md) - technical specs
- [ANSWERS-TO-QUESTIONS.md](ANSWERS-TO-QUESTIONS.md) - design decisions
- `scripts/` - all automation

### Tutorials (Learning)
- [GETTING-STARTED.md](../guides/GETTING-STARTED.md) - Guided introduction
- [INSTALLATION.md](../installation/INSTALLATION.md) - Step-by-step
- `manifests/examples/` - Example deployments

---

## Your Next Action

Based on where you are:

### Just Discovered MyNodeOne
→ Read [GETTING-STARTED.md](../guides/GETTING-STARTED.md)

### Ready to Install
→ Run `sudo ./scripts/mynodeone`

### Already Installed
→ Check [CLUSTER-MANAGEMENT.md](../operations/CLUSTER-MANAGEMENT.md)

### Having Issues
→ See [troubleshooting.md](../guides/troubleshooting.md)

### Want to Learn More
→ Read [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)

### Ready to Grow
→ Follow [scaling.md](../guides/scaling.md)

---

**Still lost?** Start at [GETTING-STARTED.md](../guides/GETTING-STARTED.md) - it guides you through everything!
