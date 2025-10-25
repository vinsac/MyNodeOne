# MyNodeOne Setup Options Guide

Complete guide to understanding each setup option and choosing the right one for your needs.

## Node Types

### 1. Control Plane Node

**What it is:** The "brain" of your cluster. First node you must set up.

**What it does:**
- Runs Kubernetes master (API server, scheduler, controller)
- Manages cluster state (etcd database)
- Runs monitoring (Grafana, Prometheus, Loki)
- Runs GitOps (ArgoCD)
- Can also run application workloads

**Requirements:**
- **Minimum:** 2 CPU cores, 4GB RAM, 20GB disk
- **Recommended:** 8+ cores, 16GB+ RAM, 100GB+ SSD
- **OS:** Ubuntu 24.04 LTS

**When to use:**
- ✅ Always your FIRST node
- ✅ If you only have one machine
- ✅ Your most powerful/reliable machine

**Example hardware:**
- Home server (Ryzen 9950X, 256GB RAM like toronto-0001)
- Mini PC (Intel NUC, Beelink, etc.)
- Old desktop/workstation

---

### 2. Worker Node

**What it is:** Additional compute for your cluster. Add AFTER control plane.

**What it does:**
- Runs your application workloads
- Provides more CPU/RAM/storage
- Connects to control plane
- Can be added/removed anytime

**Requirements:**
- **Minimum:** 2 cores, 2GB RAM, 20GB disk
- **Recommended:** 4+ cores, 8GB+ RAM, 50GB+ disk
- **Must:** Connect to control plane via Tailscale

**When to use:**
- ✅ When control plane runs out of resources
- ✅ To add redundancy
- ✅ To scale horizontally
- ✅ To separate workloads

**Example hardware:**
- Second home server (toronto-0002)
- Raspberry Pi 4/5
- Old laptop
- Another mini PC

---

### 3. VPS Edge Node

**What it is:** Public-facing reverse proxy on a VPS with public IP.

**What it does:**
- Routes internet traffic to your home cluster
- Provides SSL certificates (Let's Encrypt)
- Acts as DDoS protection
- No application workloads run here

**Requirements:**
- **Minimum:** 1 core, 1GB RAM, 20GB disk
- **Must have:** Public IP address
- **Typical cost:** $5-15/month

**When to use:**
- ✅ When you want apps accessible from internet
- ✅ When your ISP blocks port 80/443
- ✅ When you need static public IP
- ❌ NOT needed for internal/Tailscale-only access

**Example providers:**
- Contabo ($6/month)
- DigitalOcean ($6/month)
- Hetzner ($5/month)
- Vultr ($6/month)

---

### 4. Management Workstation

**What it is:** Your laptop/desktop for managing the cluster.

**What it does:**
- Runs kubectl for deployments
- Accesses web UIs (Grafana, ArgoCD)
- Develops and tests applications
- NO server workloads run here

**Requirements:**
- **Any OS:** Windows, Mac, Linux
- **Needs:** kubectl installed
- **Needs:** Tailscale connection

**When to use:**
- ✅ Your daily driver laptop/desktop
- ✅ For deploying apps from dev machine
- ✅ For viewing monitoring dashboards

**Example:**
- Your laptop (vinay-vivobook)
- Your desktop PC
- Any workstation with Tailscale

---

## Disk Setup Options

### Option 1: Longhorn Storage (Recommended)

**What it is:** Distributed block storage for Kubernetes

**Use for:**
- Persistent volumes for apps
- Databases (PostgreSQL, MySQL, MongoDB)
- Stateful applications
- Replicated storage across nodes

**How it works:**
- Each disk becomes part of Longhorn pool
- Data can be replicated 1x, 2x, or 3x
- Automatic failover if disk fails
- Accessible from any node

**Best for:** General purpose storage

---

### Option 2: MinIO Storage

**What it is:** S3-compatible object storage

**Use for:**
- File uploads
- Media storage (images, videos)
- Backups
- Application assets

**How it works:**
- Disks combined into MinIO pool
- S3 API for access
- Can use from anywhere
- Easy integration with apps

**Best for:** Object/blob storage

---

### Option 3: RAID Array

**What it is:** Hardware RAID combining multiple disks

**RAID levels:**
- **RAID 0:** Striping (fast, no redundancy)
- **RAID 1:** Mirroring (redundancy, half capacity)
- **RAID 5:** Parity (good balance, needs 3+ disks)
- **RAID 10:** Mirrored stripes (best, needs 4+ disks)

**Use for:**
- Maximum performance
- Hardware-level redundancy
- Traditional storage needs

**Best for:** Advanced users who know RAID

---

### Option 4: Individual Mounts

**What it is:** Each disk mounted separately

**Use for:**
- Simple setups
- Different purposes per disk
- Easy to understand
- Maximum flexibility

**Example:**
- `/mnt/disk1` → Application data
- `/mnt/disk2` → Database backups
- `/mnt/disk3` → Media files

**Best for:** Simple, straightforward storage

---

## Decision Flowchart

### Which Node Type?

```
Do you have a cluster already?
├─ No → Control Plane (first node)
└─ Yes
   ├─ Want to add compute? → Worker Node
   ├─ Want public access? → VPS Edge Node
   └─ Want to manage cluster? → Management Workstation
```

### How Many VPS?

```
Do you need public internet access?
├─ No → 0 VPS (use Tailscale only)
└─ Yes
   ├─ Just testing? → 1 VPS
   ├─ Production? → 2+ VPS (high availability)
   └─ Global? → Multiple VPS in different regions
```

### Which Disk Setup?

```
What storage do you need?
├─ Databases/PVs → Longhorn
├─ Files/Media → MinIO
├─ Both → Longhorn + MinIO
├─ Advanced → RAID
└─ Simple → Individual Mounts
```

---

## Common Setups

### Beginner: Single Machine

**Hardware:**
- 1 powerful home server

**Configuration:**
- 1 Control Plane node
- 0 VPS (Tailscale access only)
- 1 Management Workstation (your laptop)

**Cost:** $0/month (electricity only)

**Use case:** Learning, development, internal apps

---

### Intermediate: Home + VPS

**Hardware:**
- 1 home server
- 1 VPS

**Configuration:**
- 1 Control Plane (home)
- 1 VPS Edge Node
- 1 Management Workstation

**Cost:** $5-15/month (VPS)

**Use case:** Public-facing apps, production-ready

---

### Advanced: Multi-Node + HA

**Hardware:**
- 3 home servers
- 2 VPS

**Configuration:**
- 1 Control Plane
- 2 Worker Nodes
- 2 VPS Edge Nodes (load balanced)
- 1 Management Workstation

**Cost:** $10-30/month (VPS)

**Use case:** High availability, scale, production

---

## System Cleanup Explained

When you run `sudo ./scripts/mynodeone`, it offers to clean up your system:

### What Gets Cleaned

1. **Snap packages** (optional)
   - Saves 500MB+ RAM
   - Controversial but effective
   - You'll be asked before removal

2. **Unused packages**
   - Old dependencies
   - Orphaned packages
   - Safe to remove

3. **Old kernels**
   - Keeps current + 1 backup
   - Frees disk space
   - Safe operation

4. **APT cache**
   - Downloaded package files
   - Can be re-downloaded if needed
   - Frees disk space

### Why Clean?

- ✅ More RAM for applications
- ✅ More disk space
- ✅ Faster system
- ✅ Less attack surface

### Can I Skip?

Yes! Answer "No" when prompted. Your system will work fine either way.

---

## External Disk Detection

MyNodeOne automatically detects and offers to set up:

### Detected Disks

- USB external drives
- Additional internal drives
- NVMe drives
- SATA drives
- Any unmounted block device

### What Happens

1. Script scans for unmounted disks
2. Shows you what it found (size, model)
3. Asks if you want to use them
4. Offers setup options
5. Formats and mounts automatically
6. Adds to /etc/fstab (persistent across reboots)

### Safety

- ✅ Only shows UNMOUNTED disks
- ✅ Confirms before formatting
- ✅ Shows clear warnings
- ✅ You can skip entirely

---

## FAQ

**Q: Can I run multiple node types on one machine?**
A: No. Each physical machine should be one node type. Use separate machines.

**Q: Can I change node type later?**
A: Not easily. Better to reinstall. Data can be migrated.

**Q: Do I need a VPS?**
A: No! Only if you want public internet access. Tailscale works great for internal/personal use.

**Q: How many worker nodes do I need?**
A: Start with 0 (control plane can run apps). Add workers when you need more resources.

**Q: Can I use a Raspberry Pi?**
A: Yes! Pi 4/5 with 4GB+ RAM works as worker node. Control plane needs more power.

**Q: What if I only have 1 VPS?**
A: That's fine! You don't need HA for most setups. One VPS works great.

**Q: Can I add nodes later?**
A: Yes! That's the beauty of Kubernetes. Add/remove nodes anytime.

**Q: Do all nodes need external disks?**
A: No. Just the ones where you want extra storage. Control plane benefits most.

---

## Next Steps

1. Read this guide carefully
2. Decide your node type
3. Run: `sudo ./scripts/mynodeone`
4. Follow the prompts
5. Refer back to this guide if confused

For more help, see:
- `INSTALLATION.md` - Step-by-step setup
- `docs/networking.md` - Tailscale guide
- `FAQ.md` - Common questions
