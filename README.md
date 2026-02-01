# MyNodeOne

**Your Private Cloud Infrastructure**

MyNodeOne turns everyday hardware into a powerful private cloud you own and control. Build a Kubernetes-based cluster using regular computers, old laptops, mini PCs, or servers you already have.

- **Your gaming PC** when you're not gaming
- **Old laptops** gathering dust
- **Mini PCs** (Intel NUC, Raspberry Pi 4/5, Beelink, etc.)
- **Home servers** you already have
- **Used enterprise hardware**
- **Mix and match** - use whatever you have

**No expensive enterprise gear required. No monthly cloud bills. Just your hardware, your data, your control.**

---

## What is MyNodeOne?

MyNodeOne is a private cloud platform for home enthusiasts and dev teams. It lets you run containerized applications across multiple machines using open-source tools you can learn and customize.

Under the hood, MyNodeOne installs and manages a Kubernetes cluster on your machines. Kubernetes keeps your containerized applications healthy and can spread them across multiple machines. Because this cluster runs on hardware and networks you control, you get cloud-like capabilities as your own private cloud instead of renting them from a public cloud provider.

**Key capabilities:**
- Auto-scaling across multiple nodes
- S3-compatible object storage (MinIO)
- Distributed block storage with replication (Longhorn)
- Automatic SSL certificates (Let's Encrypt)
- GitOps deployments (ArgoCD)
- Comprehensive monitoring (Prometheus + Grafana + Loki)
- Secure networking (Tailscale mesh + optional VPS edge nodes)
- 100% free and open source

## Features

- **One Command Setup** - `sudo ./scripts/installation/install-mynodeone.sh` does everything
- **Local Dashboard** - Access at `http://mynodeone.local` after installation
- **One-Click App Store** - Install 10+ self-hosted apps (Jellyfin, Immich, Nextcloud, etc.)
- **System Cleanup** - Automatic removal of bloat and unused packages
- **Disk Auto-Detection** - Finds and configures external drives automatically
- **Fully Generic** - Works with any hardware, names, IPs
- **LLM Support** - Run language models on CPU and Nvidia GPUs

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         INTERNET                                │
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
│                │    │                  │    │              │
│ - K3s Server   │    │ - K3s Worker     │    │ - K3s Worker │
│ - Your RAM/CPU │    │ - Your RAM/CPU   │    │ - Your RAM   │
│ - Your Storage │    │ - Your Storage   │    │ - Your Disk  │
│ - MinIO/Longhorn│    │ - MinIO/Longhorn │    │ - MinIO/     │
└────────────────┘    └──────────────────┘    │ Longhorn     │
                                            └──────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    Distributed Storage                          │
│  - MinIO (S3-compatible object storage)                        │
│  - Longhorn (Distributed block storage with replication)       │
│  - Available on ALL nodes (Control Plane + Workers)            │
└─────────────────────────────────────────────────────────────────┘
```

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](docs/guides/GETTING-STARTED.md) | Entry point for new users |
| [Installation](docs/installation/INSTALLATION.md) | Step-by-step installation |
| [Admin Guide](docs/guides/ADMIN-GUIDE.md) | Daily management and troubleshooting |
| [App Store](docs/apps/APP-STORE.md) | Available one-click apps |
| [FAQ](docs/reference/FAQ.md) | Frequently asked questions |
| [Architecture](docs/architecture/ARCHITECTURE.md) | Technical design and components |
| [Documentation Index](docs/DOCUMENTATION-INDEX.md) | Complete documentation map |

**Terminology:**
- **Node**: A single machine (PC, laptop, mini PC, or server) in your cluster
- **Control Plane**: The main node that manages the cluster
- **Worker Node**: Additional nodes that run your applications
- **VPS Edge Node**: A cloud VPS that provides public internet access

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](/CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](/LICENSE) for details.

For comprehensive legal terms, see [DISCLAIMER.md](/DISCLAIMER.md).

---

**Author:** [Vinay Sachdeva](https://github.com/vinsac)  
**Repository:** https://github.com/vinsac/MyNodeOne

Built with assistance from AI tools for enhanced code quality and comprehensive documentation.