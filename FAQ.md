# NodeZero - Frequently Asked Questions

## General Questions

### What is NodeZero?

NodeZero is a production-ready private cloud infrastructure that turns commodity hardware into an AWS-like environment. It uses open-source tools like Kubernetes (K3s), MinIO, Longhorn, and more to provide enterprise features at a fraction of the cost.

### Why should I use NodeZero instead of AWS/GCP/Azure?

**Cost:** Save $30,000+ per year compared to cloud providers  
**Control:** Full ownership of your infrastructure and data  
**Performance:** Local hardware = zero latency for your region  
**Privacy:** Your data never leaves your machines  
**Learning:** Understand how cloud infrastructure really works  

---

## 🆚 NodeZero vs Alternatives

### NodeZero vs OpenStack

**Use NodeZero when:**
- ✅ You want **simple, fast setup** (30 minutes vs days/weeks)
- ✅ You have **small to medium scale** (1-50 nodes)
- ✅ You want **container-first** infrastructure (Kubernetes native)
- ✅ You need to **get started quickly** without dedicated ops team
- ✅ You want **modern cloud-native** tools (K8s, GitOps, S3)
- ✅ **One person** can manage it (no specialized team needed)

**Use OpenStack when:**
- ❌ You have **100+ servers** (enterprise scale)
- ❌ You need **traditional VMs** (not containers)
- ❌ You have a **dedicated ops team** (5+ people)
- ❌ Setup time doesn't matter (weeks/months is acceptable)
- ❌ You need **multi-tenancy** with strict isolation
- ❌ You're replacing a **VMware infrastructure**

**Bottom line:** NodeZero is **easier, faster, and cheaper** for most use cases. OpenStack is better for massive enterprise VM deployments.

---

### NodeZero vs Proxmox

**Use NodeZero when:**
- ✅ You want **cloud-native** apps (containers, microservices)
- ✅ You need **automatic scaling** and orchestration
- ✅ You want **GitOps** deployment (push to GitHub, auto-deploy)
- ✅ You need **S3-compatible storage** (MinIO)
- ✅ You want **Kubernetes** for modern app deployment
- ✅ Target: **Developers and applications**

**Use Proxmox when:**
- ❌ You need **traditional VMs** (Windows servers, legacy apps)
- ❌ You want a **web GUI** for manual VM management
- ❌ You're running **mixed workloads** (VMs + containers)
- ❌ You need **backup/snapshot** features built-in
- ❌ You prefer **manual management** over automation
- ❌ Target: **Infrastructure and VMs**

**Bottom line:** NodeZero is for **modern cloud apps**, Proxmox is for **traditional VMs and mixed environments**.

---

### NodeZero vs Bare Kubernetes

**Use NodeZero when:**
- ✅ You want **everything pre-configured** (storage, networking, monitoring)
- ✅ You need **production-ready** out of the box
- ✅ You want **one command** to set up everything
- ✅ You don't want to **spend weeks** configuring
- ✅ You need **opinionated best practices** built-in
- ✅ You want **batteries included** (ArgoCD, Prometheus, Longhorn, MinIO)

**Use Bare Kubernetes when:**
- ❌ You need **complete customization** of every component
- ❌ You have **specific requirements** that don't fit NodeZero's stack
- ❌ You want to **learn every detail** of Kubernetes
- ❌ You have **time to configure** everything manually
- ❌ You're a **Kubernetes expert** already

**Bottom line:** NodeZero is **Kubernetes with everything configured**. Bare K8s is for experts who want full control.

---

### NodeZero vs Docker Compose

**Use NodeZero when:**
- ✅ You need **multiple servers** working together
- ✅ You want **high availability** (apps survive node failures)
- ✅ You need **automatic scaling** across machines
- ✅ You want **production-grade** infrastructure
- ✅ You need **distributed storage** (data replicated across nodes)
- ✅ You're growing beyond **one machine**

**Use Docker Compose when:**
- ❌ You have **one server** and will stay that way
- ❌ You're **prototyping** or in early development
- ❌ Downtime is **acceptable**
- ❌ You don't need **scaling**
- ❌ You want the **simplest** possible setup

**Bottom line:** Start with Docker Compose, graduate to NodeZero when you need multiple machines and production features.

---

### NodeZero vs Managed Kubernetes (EKS/GKE/AKS)

**Use NodeZero when:**
- ✅ You want to **save 90%+ on costs**
- ✅ You have **hardware available** (old servers, desktops)
- ✅ You can **manage your own infrastructure**
- ✅ Data **privacy** is important
- ✅ You want **no egress fees** ($0.09/GB on AWS adds up!)
- ✅ You're comfortable with **command line** and **Linux**

**Use Managed K8s when:**
- ❌ You need **global availability** (multi-region worldwide)
- ❌ You want **zero maintenance** burden
- ❌ You need **instant scaling** to 1000+ nodes
- ❌ Budget is **not a concern**
- ❌ You want **someone else** to handle everything
- ❌ You need **99.99%+ SLA** with financial guarantees

**Bottom line:** NodeZero for **cost-conscious** teams with hardware. Managed K8s for **hands-off, global scale**.

---

### NodeZero vs Cloud VMs + Manual Setup

**Use NodeZero when:**
- ✅ You want **automation** instead of manual work
- ✅ You need **repeatable** infrastructure (one command setup)
- ✅ You want **best practices** built-in
- ✅ You don't want to **research and configure** everything
- ✅ You value your **time** (30 min vs weeks)
- ✅ You want **documentation included**

**Use Manual Setup when:**
- ❌ You want to **learn every detail** (educational purposes)
- ❌ You have **very specific** requirements
- ❌ You enjoy **tinkering** with configurations
- ❌ Time is **not a constraint**

**Bottom line:** NodeZero **saves time** with automation and best practices. Manual setup is for learning or unique requirements.

---

## 🎯 When Should You Use NodeZero?

### ✅ Perfect For:

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

### ❌ Not Ideal For:

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

## 💰 Cost Comparison Reality Check

### Example: Small SaaS Startup

**AWS Costs (Monthly):**
- 3x t3.xlarge instances: $300
- 100GB RDS PostgreSQL: $200
- 1TB S3 storage: $25
- 500GB egress: $45
- Load balancer: $25
- Monitoring: $30
- **Total: $625/month = $7,500/year**

**NodeZero Costs (Monthly):**
- 3x used servers ($600 one-time)
- $6 VPS (edge node)
- Electricity: ~$20
- **Total: $26/month = $312/year** (after hardware)

**Savings: $7,188/year** 💰

**Break-even: 2.4 months** (hardware pays for itself)

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

🎉 Use NodeZero! 🎉
```

---

### Is NodeZero production-ready?

Yes! NodeZero uses battle-tested open-source tools:
- K3s (used by Cisco, Siemens, and thousands of companies)
- Longhorn (enterprise storage by SUSE/Rancher)
- MinIO (trusted by NASA, Intel, and many Fortune 500s)
- Traefik (powers millions of sites)
- Prometheus/Grafana (industry standard monitoring)

### Can I use NodeZero for commercial projects?

Absolutely! NodeZero is MIT licensed. Use it for your startup, business, or personal projects. All components are free and open source.

## Technical Questions

### What OS do I need?

Ubuntu 24.04 LTS (Desktop or Server edition). Other Linux distributions may work but are untested.

### Can I run NodeZero on just one machine?

Yes! Start with toronto-0001 and add more nodes later. The architecture scales from 1 to 100+ nodes.

### Do I need fast internet?

Recommended: 100 Mbps upload minimum. With 500 Mbps (like yours), you can serve HD video to 60+ concurrent users from home.

### What if my ISP blocks ports 80/443?

That's why we use VPS edge nodes! They handle public traffic and route to your home via Tailscale on non-blocked ports.

### Can I use NodeZero without Tailscale?

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
**Electricity:** ~$30-50/month for toronto-0001

**Total:** ~$30-50/month vs $2,000+/month on AWS

### What happens if toronto-0001 goes down?

With 1 node: Everything stops until it's back up.
With 2+ nodes: Apps automatically migrate to healthy nodes.
Solution: Add toronto-0002 and toronto-0003 for high availability.

### Can I mix different hardware?

Yes! NodeZero works with:
- Different CPU architectures (as long as all are x86_64 or all ARM64)
- Different RAM amounts
- Different storage sizes
- Different network speeds

Kubernetes handles scheduling appropriately.

### Does NodeZero support GPU workloads?

Not out of the box, but it's on the roadmap. You can manually install NVIDIA device plugin for GPU support.

## Storage Questions

### How does distributed storage work?

Longhorn replicates data across nodes:
- 1 node: 1 replica (no redundancy)
- 2 nodes: 2 replicas (survives 1 node failure)
- 3+ nodes: 3 replicas (survives 2 node failures)

### Can I expand storage later?

Yes! Add more disks to existing nodes via Longhorn UI. No downtime required.

### What's the difference between Longhorn and MinIO?

**Longhorn:** Block storage for databases and stateful apps (like AWS EBS)
**MinIO:** Object storage for files and media (like AWS S3)

Both are needed and complement each other.

### How do I backup my data?

1. Longhorn automatic snapshots (configured in bootstrap script)
2. MinIO replication to another bucket/location
3. K3s etcd automatic snapshots (every 12 hours)
4. Custom backup CronJobs (example included)

## Application Questions

### What apps can I run on NodeZero?

Anything that runs in Docker/containers:
- Web apps (React, Vue, Angular, etc.)
- APIs (Node.js, Python, Go, Java, etc.)
- Databases (PostgreSQL, MySQL, MongoDB, Redis)
- CMS (WordPress, Ghost, Strapi)
- E-commerce (WooCommerce, Magento)
- Analytics (Plausible, Matomo)
- And literally anything else!

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

Yes! Each app gets its own:
- Namespace
- SSL certificate
- Domain routing
- Resource allocation

Example: curiios.com, vinaysachdeva.com, blog.example.com all on the same cluster.

## Networking Questions

### How does traffic flow from internet to my app?

```
User → VPS (SSL termination) → Tailscale tunnel → toronto-0001 → App Pod
```

### Why use VPS instead of exposing toronto-0001 directly?

1. **ISP blocks:** Many ISPs block ports 80/443
2. **Dynamic IP:** Home IPs change; VPS IPs are static
3. **DDoS protection:** VPS can absorb attacks
4. **Bandwidth:** VPS has unlimited inbound bandwidth
5. **Latency:** VPS provides edge caching (optional)

### Can I add more VPS edge nodes?

Yes! Run `setup-edge-node.sh` on any VPS and point DNS to it. Load balancing is automatic (DNS round-robin).

### How do SSL certificates work?

1. You point DNS to VPS
2. Traefik on VPS requests cert from Let's Encrypt
3. Let's Encrypt verifies domain ownership (HTTP challenge)
4. Certificate issued automatically
5. Auto-renews every 60 days

Zero manual work!

### Can I use my own SSL certificates?

Yes, but not recommended. Let's Encrypt is free and automatic. If you need custom certs, configure Traefik manually.

## Security Questions

### Is NodeZero secure?

Yes, with best practices:
- All traffic encrypted (Tailscale uses WireGuard)
- Automatic security updates
- Minimal attack surface (VPS only exposes 80/443)
- Network isolation (Kubernetes network policies)
- Secrets management (Kubernetes secrets)
- RBAC for access control

### Should I expose toronto-0001 to the internet?

No! Keep it behind Tailscale. Only VPS nodes should have public IPs.

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

Add toronto-0002 when:
- CPU usage > 70% sustained
- RAM usage > 80%
- Need redundancy for production apps
- Want to deploy more apps

### How do I add a worker node?

```bash
# On new node
sudo ./scripts/add-worker-node.sh
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

### App not accessible from internet

**Cause:** VPS routing not configured
**Solution:** Update `/etc/traefik/dynamic/nodezero-routes.yml` on VPS

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

### What if I lose toronto-0001 completely?

1. Restore etcd from snapshot on new hardware
2. Restore Longhorn volumes from backups
3. Redeploy apps via ArgoCD

See disaster recovery section in operations.md

## Cost Questions

### What's the total cost of ownership?

**Initial Hardware:** (you already have)
- toronto-0001: $0 (already owned)
- vivobook: $0 (already owned)

**Monthly Costs:**
- 2x VPS: $30
- Domains: $2 (amortized)
- Electricity: $40
- **Total: ~$72/month**

**Compared to AWS:**
- Equivalent resources: $2,500/month
- **Savings: $2,428/month = $29,136/year**

### What if I don't want to use VPS?

If your ISP allows ports 80/443:
1. Skip VPS setup
2. Point DNS directly to home IP
3. Run Traefik on toronto-0001
4. Use dynamic DNS if IP changes

Cost: $0/month (electricity only)

### Can I sell hosting on NodeZero?

Technically yes, but consider:
- Legal/business licenses
- SLA commitments
- Redundancy requirements
- Bandwidth costs
- Support overhead

Better for personal/small business use.

## Migration Questions

### Can I migrate from AWS/GCP to NodeZero?

Yes! Process:
1. Set up NodeZero cluster
2. Migrate databases (dump/restore)
3. Build Docker images for apps
4. Deploy to NodeZero
5. Test thoroughly
6. Switch DNS
7. Decommission cloud resources

Saves $2,000+/month!

### Can I migrate from Docker Compose?

Yes! Very easy:
1. Convert docker-compose.yml to K8s manifests
2. Deploy to NodeZero
3. Much better scaling and management

### How long does migration take?

- Small apps: 1-2 days
- Medium apps: 1 week
- Large apps: 2-4 weeks
- Complex migrations: Plan for 1-2 months

## Community Questions

### Can I contribute to NodeZero?

Yes! See CONTRIBUTING.md. All contributions welcome:
- Bug fixes
- New features
- Documentation
- Example apps
- Testing

### Is there a NodeZero community?

We're just starting! Share your setup:
- GitHub Discussions
- Reddit /r/selfhosted
- Twitter/X with #NodeZero
- Your blog!

### Can I get help with my setup?

1. Read the docs (comprehensive!)
2. Check troubleshooting.md
3. Open GitHub issue
4. Community forums

### Can I hire someone to set this up?

NodeZero is designed to be self-service, but if you need help:
- Freelancers on Upwork/Fiverr
- DevOps consultants
- Or follow QUICKSTART.md - it's quite simple!

---

**Still have questions?** Open an issue on GitHub or check the docs folder!
