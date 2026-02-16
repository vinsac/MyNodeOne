# MyNodeOne - Frequently Asked Questions

## Installation Issues

### "command not found" errors during installation

**Problem**: Scripts don't have execute permissions after cloning

**Solution**: 
```bash
# Fix permissions for all scripts
find ~/MyNodeOne -name "*.sh" -exec chmod +x {} \;

# Or run the permission fix script
sudo ./scripts/setup/fix-script-permissions.sh
```

**Prevention**: Scripts now include proper permissions in the repository

### VPS installation shows "Initial sync failed"

**Problem**: Node Agent can't start due to missing dependencies

**Symptoms**:
```
mynodeone-node-agent: line 43: /usr/local/bin/config-paths.sh: No such file or directory
```

**Solution**:
```bash
# Manual fix (for existing installations)
ssh user@vps-ip "sudo cp ~/mynodeone/scripts/lib/config-paths.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/config-paths.sh && sudo chown root:root /usr/local/bin/config-paths.sh"

# Restart Node Agent
ssh user@vps-ip "sudo systemctl restart mynodeone-node-agent"
```

**Prevention**: Fixed in install-node-agent.sh (commit 01dfe16)

### VPS shows "VPS not found in sync controller registry"

**Problem**: Verification logic using wrong search criteria

**Symptoms**:
```
❌ VPS not found in sync controller registry
❌ VPS not found in domain registry
```

**Solution**: This is now fixed with ConfigMap-based verification (commit 947742c)

### Node Agent heartbeat failures

**Problem**: Node Agent can't authenticate with control plane

**Symptoms**:
```
[ERROR] CONTROL_PLANE_IP is required
Unauthorized: Invalid API token
```

**Solution**:
```bash
# Check API token
sudo cat /etc/mynodeone/api-token

# Verify Node Agent config
sudo cat /etc/mynodeone/agent.env

# Check Node Agent status
sudo mynodeone-node-agent status
```

### remove-domain.sh fails with jq errors

**Problem**: Incorrect JSON path in domain registry queries

**Symptoms**:
```
jq: error: Cannot index array with string "domain-name"
```

**Solution**: Fixed in scripts/domains/remove-domain.sh (commit 947742c)

## Node Agent & Sync Issues

### Node Agent keeps restarting

**Problem**: Missing config-paths.sh dependency

**Diagnosis**:
```bash
# Check Node Agent logs
sudo journalctl -u mynodeone-node-agent -f

# Look for this error:
mynodeone-node-agent: line 43: /usr/local/bin/config-paths.sh: No such file or directory
```

**Solution**: See "VPS installation shows 'Initial sync failed'" above

### Heartbeat not reaching control plane

**Problem**: Network or authentication issues

**Diagnosis**:
```bash
# On VPS: Check Node Agent status
sudo mynodeone-node-agent status

# On Control Plane: Check for heartbeats
sudo journalctl -u mynodeone-config-api -f | grep heartbeat
```

**Common Causes**:
- API token mismatch
- Network connectivity (Tailscale)
- Control plane API server not running

### Config not syncing to VPS

**Problem**: V2 sync system not working

**Diagnosis**:
```bash
# Check if Node Agent is pulling config
sudo journalctl -u mynodeone-config-api -f | grep "config.*request"

# Check sync controller health
sudo ./scripts/lib/sync-controller.sh health
```

**Expected Behavior**:
- Config requests every 30 seconds
- Heartbeats every 60 seconds
- V2 sync nodes skip SSH push

## General Questions

### What is MyNodeOne?

MyNodeOne is a private cloud platform that turns **consumer hardware** into a robust environment for running your own applications and services. You can use old laptops, mini PCs, Raspberry Pis, or other regular computers you already own. It uses open-source tools like Kubernetes (K3s), MinIO, Longhorn, and more to provide many of the capabilities of cloud platforms without requiring expensive enterprise hardware or monthly cloud bills.

### Why should I use MyNodeOne instead of AWS/GCP/Azure?

**Cost:** Save $30,000+ per year compared to cloud providers  
**Control:** Full ownership of your infrastructure and data  
**Performance:** Local hardware = zero latency for your region  
**Privacy:** Your data never leaves your machines  
**Learning:** Understand how cloud infrastructure really works  

### Is MyNodeOne secure?

MyNodeOne includes several built-in security measures, but you are responsible for evaluating whether they are sufficient for your environment and compliance requirements.

**Built-in security (automatic):**
- Firewall (UFW) on all nodes
- SSH brute-force protection (fail2ban)
- Strong 32-character random passwords
- Encrypted network traffic (Tailscale/WireGuard)
- Secure credential storage (chmod 600)
- No default passwords

**Optional Hardening (One Command):**
```bash
sudo ./scripts/setup/enable-security-hardening.sh
```

Enables:
- Kubernetes audit logging
- Secrets encryption at rest
- Pod Security Standards (restricted)
- Network policies (default deny)
- Resource quotas
- Security headers (HSTS, CSP)

**Security documentation:**
- Production security guidance included
- Password management strategy documented
- See: `../security/` directory for complete security guides

**Suitable for:**
- Workloads where you are comfortable operating and maintaining your own infrastructure
- Business and internal applications after appropriate testing and hardening
- Privacy-focused deployments where you prefer data to stay on hardware you control
- Internal company use and non-critical services
- Environments with clear backup, monitoring, and recovery plans

---

## Hardware Questions

### What hardware do I need?

**Minimum (Single Node):**
- Any computer with 4GB RAM (8GB+ recommended)
- 20GB disk space (50GB+ recommended)
- Ubuntu 24.04 LTS installed
- Internet connection

**Examples that work:**
- Old laptop (2015+)
- Intel NUC or similar mini PC
- Home server
- Raspberry Pi 4/5 (4GB+ RAM)
- Used Dell/HP/Lenovo from eBay ($150-300)

**For production (recommended):**
- 1 control plane: 8-16GB RAM, 100GB+ disk
- 1-3 worker nodes: 4-8GB RAM each
- Total cost: $0 (use what you have) to $500 (buy used hardware)

### Can I use old laptops?

**Yes!** Old laptops are perfect for MyNodeOne:
- Keep the lid closed, plug in external monitor (optional)
- Use as control plane or worker nodes
- Even 2015 laptops with 8GB RAM work great
- Power consumption ~15-30W (cheaper than a VPS!)

### Does it work on Raspberry Pi?

**Yes!** Raspberry Pi 4/5 with 4GB+ RAM works perfectly:
- Can be control plane (8GB model) or worker node
- ARM64 architecture fully supported
- Great for edge nodes or low-power setups
- Note: Use fast SD card or SSD via USB

### What about mixing different hardware?

**Absolutely!** Mix and match freely:
- Old laptop + Mini PC + Raspberry Pi = perfectly valid cluster
- Different CPU speeds = no problem (workloads balance automatically)
- Different RAM sizes = works great (specify limits per node)
- Different storage = Longhorn handles it all

### Do I need enterprise server hardware?

**No!** Consumer hardware works perfectly:
- Don't need: Enterprise servers, RAID cards, SAN storage
- Do need: Regular computers with Ubuntu 24.04
- **Why?** Kubernetes handles redundancy and distribution in software

### What if I only have one computer?

**That works!** Start with one machine:
- Run control plane + workloads on same node
- Add more nodes later (zero downtime)
- Perfect for learning, development, or small projects
- Can still run 10-20 services easily

### What if I only have one disk (no additional storage)?

**No problem!** MyNodeOne works perfectly on single-disk machines:

**Common scenario:**
- Most laptops, mini PCs, and home machines have just one disk
- The OS is installed on this disk
- No additional storage disks available

**What MyNodeOne does automatically:**
- Detects single-disk configuration
- Automatically configures storage on OS disk at `/var/lib/longhorn`
- Installation continues seamlessly
- No manual configuration needed

**Performance:**
- Works great for home labs, development, and learning
- Handles personal websites, databases, and most applications
- Especially good with SSDs (fast enough for most uses)
- Shared I/O with OS (not ideal for high-traffic production)

**Capacity:**
- Uses free space on your OS disk
- Recommended: 500GB+ total disk with 100GB+ free
- Monitor with: `df -h /var/lib/longhorn`

**Can I add disks later?**
- Yes! Additional disks can be added to Longhorn storage pool
- Disks are automatically detected and made available
- Zero downtime migration for existing volumes

---

### How much does hardware cost?

**$0 to $1000 depending on what you have:**

**Option 1: Free ($0)**
- Use computers you already own
- Old laptop + desktop + Pi = powerful cluster

**Option 2: Budget ($300-500)**
- 1x Used Dell Optiplex ($150-200, 16GB RAM)
- 1-2x Mini PC ($100-150 each, 8GB RAM)
- Total: Cluster suitable as a foundation for serious workloads after testing and hardening

**Option 3: New Hardware ($800-1000)**
- 1x Intel NUC ($400, 32GB RAM)
- 2x Beelink Mini PC ($200 each, 16GB RAM)
- Professional setup, scales to 50+ services

**No monthly fees!** Unlike cloud, you pay once and own it forever.

### Can I run multiple node types on one machine?

No. Each physical machine should be configured as a single node type. Use separate machines for the control plane, worker nodes, VPS edge nodes, and your management workstation.

### Can I change node type later?

Not easily. The safest approach is to reinstall the node with the new role and migrate any important data or workloads.

### Do I need a VPS?

No. A VPS edge node is only required if you want your apps accessible from the public internet. For personal or internal use, accessing services over Tailscale is enough.

### How many worker nodes do I need?

You can start with zero worker nodes because the control plane can also run application workloads. Add worker nodes later when you need more CPU, memory, or redundancy.

### What if I only have one VPS?

That is fine for most setups. High availability with multiple VPS edge nodes is optional and typically only needed for more demanding production environments.

### Can I add nodes later?

Yes. One of the benefits of Kubernetes is that you can add or remove nodes over time. Start with a simple setup and grow the cluster as your needs increase.

---

## 🆚 MyNodeOne vs Alternatives

### MyNodeOne vs OpenStack

**Use MyNodeOne when:**
- You want **simple, fast setup** (30 minutes vs days/weeks)
- You have **small to medium scale** (1-50 nodes)
- You want **container-first** infrastructure (Kubernetes native)
- You need to **get started quickly** without dedicated ops team
- You want **modern cloud-native** tools (K8s, GitOps, S3)
- **One person** can manage it (no specialized team needed)

**Use OpenStack when:**
- You have **100+ servers** (enterprise scale)
- You need **traditional VMs** (not containers)
- You have a **dedicated ops team** (5+ people)
- Setup time doesn't matter (weeks/months is acceptable)
- You need **multi-tenancy** with strict isolation
- You're replacing a **VMware infrastructure**

**Bottom line:** MyNodeOne is **easier, faster, and cheaper** for most use cases. OpenStack is better for massive enterprise VM deployments.

---

### MyNodeOne vs Proxmox

**Use MyNodeOne when:**
- You want **cloud-native** apps (containers, microservices)
- You need **automatic scaling** and orchestration
- You want **GitOps** deployment (push to GitHub, auto-deploy)
- You need **S3-compatible storage** (MinIO)
- You want **Kubernetes** for modern app deployment
- Target: **Developers and applications**

**Use Proxmox when:**
- You need **traditional VMs** (Windows servers, legacy apps)
- You want a **web GUI** for manual VM management
- You're running **mixed workloads** (VMs + containers)
- You need **backup/snapshot** features built-in
- You prefer **manual management** over automation
- Target: **Infrastructure and VMs**

**Bottom line:** MyNodeOne is for **modern cloud apps**, Proxmox is for **traditional VMs and mixed environments**.

---

### MyNodeOne vs Bare Kubernetes

**Use MyNodeOne when:**
- You want **everything pre-configured** (storage, networking, monitoring)
- You want a strong starting point that you can validate and harden for production
- You want **one command** to set up everything
- You don't want to **spend weeks** configuring
- You prefer **opinionated best practices** built-in
- You want **batteries included** (ArgoCD, Prometheus, Longhorn, MinIO)

**Use Bare Kubernetes when:**
- You need **complete customization** of every component
- You have **specific requirements** that don't fit MyNodeOne's stack
- You want to **learn every detail** of Kubernetes
- You have **time to configure** everything manually
- You're a **Kubernetes expert** already

**Bottom line:** MyNodeOne is **Kubernetes with everything configured**. Bare K8s is for experts who want full control.

---

### MyNodeOne vs Docker Compose

**Use MyNodeOne when:**
- You need **multiple servers** working together
- You want **high availability** (apps survive node failures)
- You need **automatic scaling** across machines
- You want **a more robust infrastructure layer** than a single Docker host
- You need **distributed storage** (data replicated across nodes)
- You're growing beyond **one machine**

**Use Docker Compose when:**
- You have **one server** and will stay that way
- You're **prototyping** or in early development
- Downtime is **acceptable**
- You don't need **scaling**
- You want the **simplest** possible setup

**Bottom line:** Start with Docker Compose, graduate to MyNodeOne when you need multiple machines and production features.

---

### MyNodeOne vs Managed Kubernetes (EKS/GKE/AKS)

**Use MyNodeOne when:**
- You want to **save 90%+ on costs**
- You have **hardware available** (old servers, desktops)
- You can **manage your own infrastructure**
- Data **privacy** is important
- You want **no egress fees** ($0.09/GB on AWS adds up!)
- You're comfortable with **command line** and **Linux**

**Use Managed K8s when:**
- You need **global availability** (multi-region worldwide)
- You want **zero maintenance** burden
- You need **instant scaling** to 1000+ nodes
- Budget is **not a concern**
- You want **someone else** to handle everything
- You need **99.99%+ SLA** with financial guarantees

**Bottom line:** MyNodeOne for **cost-conscious** teams with hardware. Managed K8s for **hands-off, global scale**.

---

### MyNodeOne vs Cloud VMs + Manual Setup

**Use MyNodeOne when:**
- You want **automation** instead of manual work
- You need **repeatable** infrastructure (one command setup)
- You want **best practices** built-in
- You don't want to **research and configure** everything
- You value your **time** (30 min vs weeks)
- You want **documentation included**

**Use Manual Setup when:**
- You want to **learn every detail** (educational purposes)
- You have **very specific** requirements
- You enjoy **tinkering** with configurations
- Time is **not a constraint**

**Bottom line:** MyNodeOne **saves time** with automation and best practices. Manual setup is for learning or unique requirements.

---

## When Should You Use MyNodeOne?

### Perfect For:

**Startups & Small Teams**
- Need production infrastructure on a budget
- Want to move fast without infrastructure burden
- 1-10 person teams who can't afford dedicated ops

**Cost-Conscious Projects**
- Paying $2,000+/month for AWS and want to cut 95%
- Have hardware available (old servers, desktops)
- Want to avoid cloud egress fees

**Learning & Development**
- Learning Kubernetes and cloud-native tools
- Need staging/testing environments
- Want hands-on experience without breaking bank

**Privacy-Focused Applications**
- Need data to stay on your hardware
- Regulatory requirements (HIPAA, GDPR)
- Don't trust third-party cloud providers

**Side Projects & Indie Hackers**
- Building SaaS products
- Running personal services
- Hosting client applications

**Companies with On-Prem Hardware**
- Already have servers in office/data center
- Want to modernize without cloud migration
- Need to maximize existing hardware investment

### Not Ideal For:

**Enterprise at Scale**
- 100+ servers with dedicated ops team
- Need multi-tenancy with strict isolation
- Require 99.99%+ SLA with penalties

**Global Services**
- Need presence in 20+ regions worldwide
- Require instant global scaling
- Can't use Tailscale mesh networking

**Zero-Maintenance Teams**
- Want absolutely no infrastructure management
- Have unlimited budget for managed services
- Prefer outsourcing everything

**Windows-Heavy Environments**
- Primary workload is Windows VMs
- Legacy Windows applications
- Active Directory dependencies

---

## Cost comparison

### Example: Small SaaS Startup

**AWS Costs (Monthly):**
- 3x t3.xlarge instances: $300
- 100GB RDS PostgreSQL: $200
- 1TB S3 storage: $25
- 500GB egress: $45
- Load balancer: $25
- Monitoring: $30
- **Total: $625/month = $7,500/year**

**MyNodeOne Costs (Monthly):**
- 3x used servers ($600 one-time)
- $6 VPS (edge node)
- Electricity: ~$20
- **Total: $26/month = $312/year** (after hardware)

---

## 🧠 Decision Tree

```
Do you need 100+ servers?
├─ Yes → Consider OpenStack or Managed K8s
└─ No ↓

Do you need traditional VMs primarily?
├─ Yes → Use Proxmox
└─ No ↓

Do you have hardware available?
├─ No → Rent cheap VPS ($6-15/mo) or use cloud initially
└─ Yes ↓

Can you spend 30 minutes on setup?
├─ No → Maybe cloud isn't for you yet
└─ Yes ↓

Want to save $30,000+/year?
├─ No → Use AWS/GCP (unlimited budget)
└─ Yes ↓

Use MyNodeOne! 
```

---

### Who is MyNodeOne for?

MyNodeOne is designed for **home enthusiasts** and **dev teams** who want to learn Kubernetes, self-host applications, or build a personal cloud. It uses well-maintained open-source tools:
- K3s (lightweight Kubernetes by Rancher/SUSE)
- Longhorn (distributed storage by Rancher/SUSE)
- MinIO (S3-compatible object storage)
- Traefik (reverse proxy and load balancer)
- Prometheus/Grafana (monitoring and dashboards)

**Note:** MyNodeOne runs on a single control plane by default. For high-availability requirements, consider managed Kubernetes services or multi-master setups.

### Can I use MyNodeOne for commercial projects?

Absolutely! MyNodeOne is MIT licensed. Use it for your startup, business, or personal projects. All components are free and open source.

## Technical Questions

### What OS do I need?

**Recommended:** Ubuntu 24.04 LTS (Desktop or Server edition) - best tested and fully supported

**Also compatible:** Ubuntu 22.04 LTS, Ubuntu 20.04 LTS

**Other Linux distributions:** May work but are untested. MyNodeOne is optimized for Ubuntu.

### Can I run MyNodeOne on just one machine?

Yes! Start with your first node (e.g., `node-001`) and add more nodes later. The architecture scales from 1 to 100+ nodes.

**Note:** Node names like `toronto-0001`, `node-001`, etc. are just examples. You can use any hostname you prefer.

### Do I need fast internet?

Recommended: 100 Mbps upload minimum. With 500 Mbps (like yours), you can serve HD video to 60+ concurrent users from home.

### What if my ISP blocks ports 80/443?

That's why we use VPS edge nodes! They handle public traffic and route to your home via Tailscale on non-blocked ports.

### Can I use MyNodeOne without Tailscale?

Not recommended. Tailscale provides:
- NAT traversal (works behind any router)
- Encrypted mesh networking
- Zero configuration
- Free for personal use

Alternatives like WireGuard require manual configuration.

### How much does it cost to run?

**Hardware:** You already own it ($0/month)
**VPS Edge Nodes:** ~$15/month each (Contabo)
**Domains:** ~$10-20/year
**Electricity:** ~$30-50/month for your control plane node

**Total:** ~$30-50/month vs $2,000+/month on AWS

### What happens if my control plane node goes down?

With 1 node: Everything stops until it's back up.
With 2+ nodes: Apps automatically migrate to healthy nodes.
Solution: Add additional nodes (e.g., `node-002`, `node-003`) for high availability.

### Can I mix different hardware?

Yes! MyNodeOne works with:
- Different CPU architectures (as long as all are x86_64 or all ARM64)
- Different RAM amounts
- Different storage sizes
- Different network speeds

Kubernetes handles scheduling appropriately.

### Does MyNodeOne support GPU workloads?

Not out of the box, but it's on the roadmap. You can manually install NVIDIA device plugin for GPU support.

## Storage Questions

### How does distributed storage work?

Longhorn replicates data across nodes. During installation, you choose the replica count:
- 1 replica (default): no cross-node replication, recommended for home lab
- 2 replicas: survives 1 node failure, requires 2+ nodes
- 3 replicas: survives 2 node failures, requires 3+ nodes

### How do I change the Longhorn replica count?

**During installation:** The installer prompts you to choose 1, 2, or 3 replicas.

**Via environment variable** (pre-set before running the installer):
```bash
LONGHORN_REPLICA_COUNT=2 sudo bash scripts/storage/longhorn/install-interactive.sh
```

**After installation:** Re-run the installer — it uses `helm upgrade --install` which is idempotent and will apply the new setting. Note: existing PVCs keep their original replica count; only new PVCs use the updated value.

### Can I expand storage later?

Yes! Add more disks to existing nodes via Longhorn UI. No downtime required.

### What's the difference between Longhorn and MinIO?

**Longhorn:** Block storage for databases and stateful apps (like AWS EBS)
**MinIO:** Object storage for files and media (like AWS S3)

Both are needed and complement each other.

### How is my MinIO data protected from mount failures?
**Safety Valve**: The installation script now applies an "immutable lock" (`chattr +i`) to the `/mnt/minio` directory.
- If the disk fails to mount, MinIO sees a **read-only** file system and stops, preventing it from silently writing data to your operating system drive.
- This ensures you never "think" you are saving data when you are actually filling up your root partition.

### How do I backup my data?

1. Longhorn automatic snapshots (configured in bootstrap script)
2. MinIO replication to another bucket/location
3. K3s etcd automatic snapshots (every 12 hours)
4. Custom backup CronJobs (example included)

## Application Questions

### Can I run Virtual Machines (VMs) on MyNodeOne?

**No, MyNodeOne is container-only** (Kubernetes-based). It does NOT support VMs out of the box.

**Why containers instead of VMs?**
- ⚡ **Faster:** Start in seconds (vs minutes for VMs)
- **Lighter:** 10-100MB (vs GBs for VMs)  
- **Modern:** Better for cloud-native apps, CI/CD, microservices
- **Portable:** Works everywhere (dev, test, prod)

**"But I need VMs for dev services!"**

Most dev services work BETTER as containers:
- **Databases:** PostgreSQL, MySQL, MongoDB, Redis → All have official Docker images
- **Dev Tools:** GitLab, Jenkins, VS Code Server → Run as containers
- **Message Queues:** RabbitMQ, Kafka → Official images available
- **Testing:** Selenium, test databases → Faster as containers

**When you ACTUALLY need VMs:**
- Windows applications (use Proxmox instead)
- Legacy apps that can't containerize (use Proxmox)
- Testing different OS kernels (use Proxmox)
- **Advanced:** You can add KubeVirt to run VMs on Kubernetes (not included by default)

**Bottom line:** If you primarily need VMs, use Proxmox. If you're running modern apps/services, MyNodeOne's containers are faster and better!

### What apps can I run on MyNodeOne?

Anything that runs in Docker/containers:
- Web apps (React, Vue, Angular, etc.)
- APIs (Node.js, Python, Go, Java, etc.)
- Databases (PostgreSQL, MySQL, MongoDB, Redis)
- Message queues (RabbitMQ, Kafka)
- ML/AI models
- Game servers
- WordPress, Ghost, etc.

If it has a Docker image, it runs on MyNodeOne!

### How do I deploy my first app?

Three options:
1. Use `create-app.sh` script (recommended for new apps)
2. Apply example manifests: `kubectl apply -f manifests/examples/`
3. Use ArgoCD UI to deploy from Git repos

### Can I use Docker Compose files?

Yes! Convert them to Kubernetes manifests using:
```bash
kompose convert -f docker-compose.yml
```
Or use Kompose directly.

### How does GitOps work?

1. Push code to GitHub
2. GitHub Actions builds Docker image
3. Updates Kubernetes manifest
4. ArgoCD detects change
5. Deploys to cluster automatically

No manual deployments needed!

### Can I run multiple apps with different domains?

Yes! Each app can be exposed on multiple domains and patterns simultaneously:
- **Root Domain**: `yourdomain.com`
- **WWW Subdomain**: `www.yourdomain.com`
- **Custom Subdomain**: `service.test-org.net`

MyNodeOne uses a **Clean Separation** architecture where:
1. **Local Identity**: Every app has a `local_name` (e.g. `immich`) for internal access via `immich.mynodeone.local`.
2. **Public Identity**: The `expose` array contains any number of full public URLs.

This ensures you can use a root domain publicly without breaking internal `.local` resolution.

## Networking Questions

### How does traffic flow from internet to my app?

```
User → VPS (SSL termination) → Tailscale tunnel → Control Plane Node → App Pod
```

### How do pods on different nodes communicate?

MyNodeOne uses **Flannel VXLAN** for pod-to-pod networking across nodes. Each node gets its own pod subnet (e.g., `10.42.0.0/24`, `10.42.2.0/24`). Flannel creates a virtual overlay network that tunnels pod traffic between nodes over **UDP port 8472**.

This is transparent to your applications — a pod on Node A can reach a pod on Node B using its pod IP, just like they were on the same network.

**Requirements** (configured automatically by installation scripts):
- UFW routed policy set to `allow` (for forwarded packets)
- UDP port 8472 open (for VXLAN encapsulation)
- `flannel.1` interface present on each node

See [NETWORKING.md](../architecture/NETWORKING.md) for the full architecture diagram.

### Pods on my worker can't reach services on the control plane

This is almost always a **UFW firewall misconfiguration**. Check:

```bash
# Quick diagnosis
sudo ufw status verbose | grep "Default:"
# Must show: deny (incoming), allow (outgoing), allow (routed)
#                                                ^^^^^^^^^^^^^^
# If it shows "deny (routed)" — that's the problem.

# Fix:
sudo ufw default allow routed
sudo ufw allow 8472/udp comment 'Flannel VXLAN'
sudo ufw reload
```

Do this on **every node** (control plane and all workers).

Or run the automated fix: `sudo bash scripts/validation/validate-network.sh --fix`

### Longhorn CSI plugin is crashlooping on my worker node

The Longhorn CSI plugin on each node needs to reach the `longhorn-backend` ClusterIP service via pod networking. If cross-node networking is broken (see above), the CSI plugin cannot communicate with Longhorn and will crashloop.

**Fix the networking first** — once `ufw default allow routed` and `ufw allow 8472/udp` are set on all nodes, the CSI plugin will recover automatically.

### The `flannel.1` interface disappeared

This can happen after K3s restarts or heavy Helm upgrades. The fix is simple:

```bash
# Control plane
sudo systemctl restart k3s

# Worker node
sudo systemctl restart k3s-agent
```

A Flannel health monitor runs automatically on all nodes (installed during setup). It checks every 2 minutes and auto-restarts K3s if `flannel.1` is missing.

```bash
# Check monitor status
sudo bash scripts/validation/monitor-flannel-health.sh --status
```

### How do I validate my cluster's networking after adding a node?

```bash
# Quick validation (checks UFW, Flannel, VXLAN, DNS, storage, cross-node ping)
sudo bash scripts/validation/validate-network.sh

# Full multi-node end-to-end test (deploys test pods, tests cross-node I/O)
sudo bash scripts/validation/test-multinode.sh
```

The network validation also runs automatically at the end of `add-worker-node.sh`.

### Why use VPS instead of exposing my node directly?

1. **ISP blocks:** Many ISPs block ports 80/443
2. **Dynamic IP:** Home IPs change; VPS IPs are static
3. **DDoS protection:** VPS can absorb attacks
4. **Bandwidth:** VPS has unlimited inbound bandwidth
5. **Latency:** VPS provides edge caching (optional)

### Can I add more VPS edge nodes?

Yes! You can add multiple VPS nodes to your cluster. 
- **Setup**: Run the VPS installation on your new node.
- **Load Balancing**: Add A records for each VPS IP in your domain registrar.
- **Routing**: Use `manage-app-visibility.sh` to select all VPS nodes for your service.

Currently, all VPS nodes in the registry fetch all routes from the control plane, acting as a pool of redundant edge proxies. High availability is managed at the DNS level (Round-robin A records).

### How do SSL certificates work?

1. You point DNS to VPS
2. Traefik on VPS requests cert from Let's Encrypt
3. Let's Encrypt verifies domain ownership (HTTP challenge)
4. Certificate issued automatically
5. Auto-renews every 60 days

Zero manual work!

### Can I use my own SSL certificates?

Yes, but not recommended. Let's Encrypt is free and automatic. If you need custom certs, configure Traefik manually.

## Node Synchronization Questions

### How do nodes stay in sync with the cluster?

MyNodeOne uses a **two-tier sync system**:

**Primary: HTTP-Based Sync (Node Agent)**
- Every node runs a Node Agent that polls the control plane for config updates
- Sends heartbeats every 30-60 seconds so you can see which nodes are online
- Automatically applies DNS entries (laptops/workers) or Traefik routes (VPS)
- No SSH keys required between nodes

**Fallback: SSH-Based Sync**
- If Node Agent is not working on a node, the control plane pushes config via SSH
- Only used when a node is active but its Node Agent has crashed or failed to install

### How do I check which nodes are online?

```bash
# On control plane (requires sudo to read API token)
sudo ./scripts/nodes/nodes-status.sh
```

This shows all nodes with their status (online/stale/offline), last heartbeat time, and config version.

### How do I remove a node from the cluster?

```bash
# Remove from Kubernetes
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>

# Remove from sync controller registry
sudo ./scripts/nodes/nodes-status.sh remove <node-name>
```

### What happens if a node goes offline?

- **Node Agent stops sending heartbeats** → Status changes to "stale" (2-10 min) then "offline" (10+ min)
- **When node comes back online** → Node Agent automatically fetches latest config and applies it
- **No manual intervention needed** → Self-healing by design

### Where can I learn more about the sync architecture?

- [Sync Controller V2 (HTTP-based)](../architecture/SYNC-CONTROLLER-V2.md) - Primary mechanism
- [Sync Controller (SSH-based)](../architecture/SYNC-CONTROLLER.md) - Fallback mechanism

## Security Questions

### What security features does MyNodeOne have?

**Automatic Security (Built-in):**
- Firewall (UFW) on all nodes - only allows SSH and Tailscale
- fail2ban protection against SSH brute-force attacks
- All passwords are 32-character random strings (no defaults)
- Credentials stored with chmod 600 (owner-only access)
- Encrypted network traffic (Tailscale uses WireGuard)
- Minimal attack surface (only VPS exposes 80/443)
- RBAC enabled for access control

**Optional Hardening (Run after install):**
```bash
sudo ./scripts/setup/enable-security-hardening.sh
```

Adds:
- Kubernetes audit logging (tracks all cluster operations)
- Secrets encryption at rest in etcd
- Pod Security Standards (prevents privileged containers)
- Network policies (default deny all traffic)
- Resource quotas (prevents DoS)
- Security headers (HSTS, CSP, XSS protection)

**Security documentation:**
- Full security audit performed (0 vulnerabilities remaining)
- Production security guide: `../security/BEST-PRACTICES.md`
- Password management guide: `../security/PASSWORD-MANAGEMENT.md`

### Should I expose my control plane node to the internet?

No! Keep it behind Tailscale. Only VPS edge nodes should have public IPs.

### How do I manage secrets?

Use Kubernetes secrets:
```bash
kubectl create secret generic my-secret \
  --from-literal=password=mysecretpassword
```

For production, consider:
- Sealed Secrets
- External Secrets Operator
- HashiCorp Vault

### Can I restrict who can deploy apps?

Yes! Use Kubernetes RBAC to create different user roles with limited permissions.

### How do I audit access?

1. Kubernetes audit logs (enabled by default)
2. Grafana access logs
3. ArgoCD activity logs
4. VPS access logs (SSH, Traefik)

## Scaling Questions

### When should I add a second node?

Add a second node when:
- CPU usage > 70% sustained
- RAM usage > 80%
- Need redundancy for production apps
- Want to deploy more apps

### How do I add a worker node?

```bash
# On new node
sudo ./scripts/nodes/add-worker-node.sh
```

That's it! The script handles everything.

### Can I remove a node?

Yes:
```bash
# Drain node (move pods elsewhere)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Delete node
kubectl delete node <node-name>
```

### How many nodes can I have?

K3s supports 100+ nodes. Practical limit depends on control plane resources. With your hardware, 20-30 nodes is reasonable.

### Can I have nodes in different locations?

Yes! Use Tailscale to connect nodes across cities/countries. Label them by location and use affinity rules for geo-distribution.

## Troubleshooting Questions

### Pods are stuck in Pending

**Cause:** Usually insufficient resources or PVC issues
**Solution:** Check `kubectl describe pod <pod-name>` and see troubleshooting.md

### Can't access web UIs

**Cause:** Tailscale not connected or services not started
**Solution:** 
```bash
tailscale status
kubectl get svc -A | grep LoadBalancer
```

### SSL certificate not issued

**Cause:** DNS not propagated or HTTP challenge failed
**Solution:** Wait for DNS (up to 48h), check Traefik logs on VPS

### Storage volumes not attaching

**Cause:** Longhorn issues or disk full
**Solution:** Check Longhorn UI, verify disk space with `df -h`

### My PVCs have the wrong replica count

**Cause:** Longhorn StorageClass created with wrong parameters
**Symptoms:**
- New PVCs show unexpected replica count in Longhorn UI
- `kubectl get sc longhorn -o yaml` shows wrong `numberOfReplicas`

**Solution (Automatic):**
Re-run the installer and select your desired replica count at the prompt:
```bash
cd MyNodeOne
sudo ./scripts/storage/longhorn/install-interactive.sh
```
The installer verifies and fixes the StorageClass after Helm installation.

**Solution (Manual — ConfigMap-based):**
Longhorn manages StorageClass via a ConfigMap. Direct `kubectl apply` won't work because Longhorn recreates the StorageClass from the ConfigMap.
```bash
# 1. Check current setting
kubectl get sc longhorn -o jsonpath='{.parameters.numberOfReplicas}'

# 2. Update the ConfigMap (replace N with desired count: 1, 2, or 3)
# Get current ConfigMap, update numberOfReplicas, then patch it

# 3. Delete StorageClass — Longhorn recreates from updated ConfigMap
kubectl delete sc longhorn
# Wait ~10 seconds, then verify:
kubectl get sc longhorn -o jsonpath='{.parameters.numberOfReplicas}'
```

**Prevention:**
- The installer automatically verifies and fixes StorageClass after Helm installation
- Use `LONGHORN_REPLICA_COUNT=N` env var to pre-set the desired count

**Note:** Existing PVCs keep their original replica count. Only new PVCs use the updated value.

### Why does Longhorn wait 5 days to rebuild replicas?

**Purpose:** Prevents unnecessary network traffic over limited bandwidth connections
- **Home/Tailscale networks**: Limited bandwidth, high latency
- **Temporary disconnections**: Common in home environments
- **Rebuild storms**: Can saturate network when nodes reconnect

**Override if needed:**
```bash
# Change to 1 hour (3600 seconds)
kubectl patch settings.longhorn.io replica-replenishment-wait-interval -n longhorn-system -p '{"value":"3600"}'
```

### App not accessible from internet

**Cause:** VPS routing not configured
**Solution:** Update `/etc/traefik/dynamic/mynodeone-routes.yml` on VPS

### Worker validation fails even though the node joined

**Symptoms:**
- Node shows up in `kubectl get nodes` as Ready
- Validation script says "Node not registered" or fails checks
- The worker script completed successfully

**Cause:** 
The validation script uses the machine's `hostname` to check registration, but the worker may have joined the cluster with a different `NODE_NAME` from your configuration file.

**Solution:**
1. Use the exact label command printed by the worker script (it uses the correct NODE_NAME from your config)
2. If you already applied labels with the wrong name, re-run with the correct Kubernetes node name:
   ```bash
   # Check what name Kubernetes knows
   kubectl get nodes
   
   # Re-label with the correct name
   kubectl label node <ACTUAL_NODE_NAME> node-role.kubernetes.io/worker=true
   kubectl label node <ACTUAL_NODE_NAME> mynodeone.io/location=<location>
   ```

**Prevention:**
- Always copy the label command directly from the worker script output
- Ensure your config's NODE_NAME matches the machine's hostname if you prefer consistency

See: [Node Management - Worker Validation Fails](../operations/NODE-MANAGEMENT.md#worker-validation-fails)

## Maintenance Questions

### How often should I update?

- **Daily:** Check cluster health
- **Weekly:** Review monitoring, check for alerts
- **Monthly:** Update Helm charts
- **Quarterly:** Update K3s version
- **Yearly:** Review hardware/plan expansions

### How do I update K3s?

```bash
# On control plane
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.28.6+k3s1" sh -s - server

# On workers
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.28.6+k3s1" sh -
```

### How do I backup everything?

1. **etcd snapshots:** Automatic (K3s does this)
2. **Longhorn volumes:** Configure recurring backups in UI
3. **MinIO data:** Use `mc mirror` to sync elsewhere
4. **Configs:** Git repo (infrastructure as code!)

### What if I lose my control plane node completely?

1. Restore etcd from snapshot on new hardware
2. Restore Longhorn volumes from backups
3. Redeploy apps via ArgoCD

See disaster recovery section in operations.md

## Cost Questions

### What's the total cost of ownership?

**Initial Hardware:** (you already have)
- Control plane node: $0 (repurposed hardware)
- Additional nodes: $0 (repurposed hardware)

**Monthly Costs:**
- 2x VPS: $30
- Domains: $2 (amortized)
- Electricity: $40
- **Total: ~$72/month**

### What if I don't want to use VPS?

If your ISP allows ports 80/443:
1. Skip VPS setup
2. Point DNS directly to home IP
3. Run Traefik on your node
4. Use dynamic DNS if IP changes

Cost: $0/month (electricity only)

### Can I sell hosting on MyNodeOne?

Technically yes, but consider:
- Legal/business licenses
- SLA commitments
- Redundancy requirements
- Bandwidth costs
- Support overhead

Better for personal/small business use.

## Migration Questions

### Can I migrate from AWS/GCP to MyNodeOne?

Yes! Process:
1. Set up MyNodeOne cluster
2. Migrate databases (dump/restore)
3. Build Docker images for apps
4. Deploy to MyNodeOne
5. Test thoroughly
6. Switch DNS
7. Decommission cloud resources

Saves $2,000+/month!

### Can I migrate from Docker Compose?

Yes! Very easy:
1. Convert docker-compose.yml to K8s manifests
2. Deploy to MyNodeOne
3. Much better scaling and management

### How long does migration take?

- Small apps: 1-2 days
- Medium apps: 1 week
- Large apps: 2-4 weeks
- Complex migrations: Plan for 1-2 months

## Community Questions

### Can I contribute to MyNodeOne?

Yes! See CONTRIBUTING.md. All contributions welcome:
- Bug fixes
- New features
- Documentation
- Example apps
- Testing

### Is there a MyNodeOne community?

We're just starting! Share your setup:
- GitHub Discussions
- Reddit /r/selfhosted
- Twitter/X with #MyNodeOne
- Your blog!

### Can I get help with my setup?

1. Read the docs (comprehensive!)
2. Check troubleshooting.md
3. Open GitHub issue
4. Community forums

### Can I hire someone to set this up?

MyNodeOne is designed to be self-service, but if you need help:
- Freelancers on Upwork/Fiverr
- DevOps consultants
- Or follow GETTING-STARTED.md - it's quite simple!

---

**Still have questions?** Open an issue on GitHub or check the docs folder!