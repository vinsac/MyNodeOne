# 🗺️ MyNodeOne Documentation Index

Quick reference for finding what you need in the MyNodeOne repository.

---

## 🎯 "I want to..."

### Get Started
- **"I'm brand new"** → [GETTING-STARTED.md](../GETTING-STARTED.md)
- **"Quick overview"** → [README.md](../README.md)
- **"Install now"** → Run `sudo ./scripts/mynodeone`
- **"Step-by-step guide"** → [INSTALLATION.md](../guides/INSTALLATION.md)

### Understand MyNodeOne
- **"What are the options?"** → [INSTALLATION.md](../guides/INSTALLATION.md) - node types, VPS, worker nodes, and management workstation
- **"How does it work?"** → [architecture.md](architecture.md)
- **"What about networking?"** → [networking.md](networking.md)
- **"What's new in v2?"** → [UPDATES-v2.md](UPDATES-v2.md)

### Daily usage
- **"How do I manage it?"** → [operations.md](../guides/operations.md)
- **"Deploy an app"** → Check `manifests/examples/`
- **"Check cluster health"** → Run `./scripts/cluster-status.sh`
- **"Add more nodes"** → [scaling.md](../guides/scaling.md)

### Troubleshooting
- **"Something broke"** → [troubleshooting.md](../guides/troubleshooting.md)
- **"Common questions"** → [FAQ](FAQ.md)
- **"Network issues"** → [networking.md](../networking.md)

### Advanced
- **"Complete technical docs"** → [FINAL-SUMMARY.md](FINAL-SUMMARY.md)
- **"Design decisions"** → [ANSWERS-TO-QUESTIONS.md](ANSWERS-TO-QUESTIONS.md)
- **"Contribute"** → [CONTRIBUTING.md](CONTRIBUTING.md)

---

## 📁 File Organization

```
mynodeone/
│
├── 🚀 GETTING-STARTED.md              ← Entry point for new users
├── 📖 README.md                       ← Project overview
├── ⚡ INSTALLATION.md                  ← Step-by-step installation
├── 🗺️ DOCUMENTATION-INDEX.md         ← This file
├── ❓ FAQ.md                          ← 50+ questions
├── 🤝 CONTRIBUTING.md                 ← How to contribute
│
├── scripts/                      ← Automation
│   └── 🎯 mynodeone               ← Main installer
│
├── docs/
│   ├── guides/                   ← Step-by-step guides
│   │   ├── POST_INSTALLATION_GUIDE.md       ← what to do after install
│   │   ├── TERMINAL-BASICS.md               ← terminal for beginners
│   │   ├── APP_DEPLOYMENT_GUIDE.md          ← deploy applications
│   │   ├── DEMO_APP_GUIDE.md                ← first app walkthrough
│   │   └── SECURITY_CREDENTIALS_GUIDE.md    ← security credentials
│   ├── reference/                ← reference documentation and indexes
│   │   ├── GLOSSARY.md                  ← term definitions
│   │   ├── ACCESS_INFORMATION.md        ← service URLs
│   │   └── DOCUMENTATION-INDEX.md       ← navigation and links
│   └── use-cases/                ← common deployment scenarios
│
├── manifests/examples/           ← Ready apps
├── website/                      ← Docs website
├── config/                       ← Templates
└── dev-docs/                     ← Developer docs (optional)
```

---

## 🎓 Reading Order by Experience Level

### Complete Beginner (Never used Kubernetes)
1. [TERMINAL-BASICS.md](../guides/TERMINAL-BASICS.md) - 10 min (if new to terminal) ⭐
2. [GETTING-STARTED.md](../GETTING-STARTED.md) - 5 min
3. [README.md](../README.md) - 5 min
4. [INSTALLATION.md](../guides/INSTALLATION.md) - 20 min
5. [FAQ.md](FAQ.md) - Common questions and scenarios
6. Install: `sudo ./scripts/mynodeone`
7. [POST_INSTALLATION_GUIDE.md](../guides/POST_INSTALLATION_GUIDE.md) - After install ⭐
8. [operations.md](../guides/operations.md) - Daily operations
9. [FAQ.md](FAQ.md) - When questions arise

### Intermediate (Some Linux/Docker experience)
1. [README.md](../README.md) - 5 min
2. [INSTALLATION.md](../guides/INSTALLATION.md) - 10 min
3. [architecture.md](architecture.md) - 15 min
4. Install: `sudo ./scripts/mynodeone`
5. [operations.md](../guides/operations.md) - Reference
6. [scaling.md](../guides/scaling.md) - When ready to grow

### Advanced (Kubernetes experience)
1. [architecture.md](architecture.md) - Technical design
2. [REPO-STRUCTURE.md](REPO-STRUCTURE.md) - Repository layout
3. Install: `sudo ./scripts/mynodeone`
4. Explore: `manifests/` and `scripts/`
5. [dev-docs/](dev-docs/) - Developer documentation
6. [CONTRIBUTING.md](CONTRIBUTING.md) - Help improve

---

## 🔍 Find Specific Topics

### Installation & Setup
- Main installer: `scripts/mynodeone`
- Installation guide: [INSTALLATION.md](../guides/INSTALLATION.md)
- Setup options: [INSTALLATION.md](../guides/INSTALLATION.md) - node types and scenarios
- Configuration wizard: `scripts/interactive-setup.sh`
- **VPS Edge Node Setup:** [docs/guides/VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md) ⭐ NEW
- VPS Installation: [docs/guides/VPS-INSTALLATION.md](../guides/VPS-INSTALLATION.md)

### Comparisons & Alternatives
- **MyNodeOne vs Alternatives:** [docs/reference/comparison-guide.md](comparsion-guide.md) ⭐
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
- Architecture: [architecture.md](architecture.md) - Section "Storage Layer"
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
- Add VPS: [INSTALLATION.md](INSTALLATION.md) - Section "Step 4"
- **Add VPS Edge Node:** [docs/guides/VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md) ⭐
- High availability: [architecture.md](architecture.md)

---

## 💡 Quick Answers

**"Where do I start?"**  
→ [GETTING-STARTED.md](GETTING-STARTED.md)

**"How do I install?"**  
→ `sudo ./scripts/mynodeone`

**"What's Tailscale?"**  
→ [networking.md](networking.md) - Default networking (automatic)

**"What options do I have?"**  
→ [INSTALLATION.md](../guides/INSTALLATION.md) - node types and basic scenarios

**"How do I add nodes?"**  
→ [scaling.md](../guides/scaling.md)

**"Something's broken!"**  
→ [troubleshooting.md](../guides/troubleshooting.md)

**"How does this work?"**  
→ [architecture.md](architecture.md)

**"I have a question..."**  
→ [FAQ.md](FAQ.md)

**"How do I add a domain to my VPS?"**  
→ [docs/guides/VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md) - Section "Adding Domain Later"

**"How do I expose apps publicly?"**  
→ [docs/guides/VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md)

---

## 📚 Documentation by Type

### Guides (how-to)
- [INSTALLATION.md](../guides/INSTALLATION.md) - installation walkthrough
- [VPS-EDGE-NODE-GUIDE.md](../guides/VPS-EDGE-NODE-GUIDE.md) - VPS edge node and domain setup
- [VPS-INSTALLATION.md](../guides/VPS-INSTALLATION.md) - VPS control plane setup
- [operations.md](../guides/operations.md) - daily management
- [scaling.md](../guides/scaling.md) - growth strategies
- [troubleshooting.md](../guides/troubleshooting.md) - problem solving

### Explanations (understanding)
- [README.md](../README.md) - what MyNodeOne is
- [architecture.md](architecture.md) - how it works
- [storage-guide.md](storage-guide.md) - storage options explained
- [networking.md](networking.md) - networking explained

### Reference (lookup)
- [FAQ](FAQ.md) - Q&A format
- [FINAL-SUMMARY.md](FINAL-SUMMARY.md) - technical specs
- [ANSWERS-TO-QUESTIONS.md](ANSWERS-TO-QUESTIONS.md) - design decisions
- `scripts/` - all automation

### Tutorials (Learning)
- [GETTING-STARTED.md](GETTING-STARTED.md) - Guided introduction
- [INSTALLATION.md](INSTALLATION.md) - Step-by-step
- `manifests/examples/` - Example deployments

---

## 🎯 Your Next Action

Based on where you are:

### Just Discovered MyNodeOne
→ Read [GETTING-STARTED.md](GETTING-STARTED.md)

### Ready to Install
→ Run `sudo ./scripts/mynodeone`

### Already Installed
→ Check [operations.md](../guides/operations.md)

### Having Issues
→ See [troubleshooting.md](../guides/troubleshooting.md)

### Want to Learn More
→ Read [architecture.md](architecture.md)

### Ready to Grow
→ Follow [scaling.md](../guides/scaling.md)

---

**Still lost?** Start at [GETTING-STARTED.md](GETTING-STARTED.md) - it guides you through everything!
