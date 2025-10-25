# MyNodeOne Glossary - Simple Definitions

**For non-technical users and product managers**

---

## 📖 Basic Terms

### Cloud
**Simple:** Computers that run your applications, accessible from anywhere via the internet.

**Example:** Like renting an office vs. owning a building. AWS is renting, MyNodeOne is owning.

---

### Private Cloud
**Simple:** Your own personal cloud using your own computers.

**Example:** Like having your own Netflix server instead of using Netflix's servers.

---

### Node
**Simple:** A single computer or server in your system.

**Example:** Each laptop, desktop, or server you add is one node.

---

### Cluster
**Simple:** Multiple computers working together as one big computer.

**Example:** Like a team - individually they're people, together they're a department.

---

### Control Plane
**Simple:** The "boss" computer that tells other computers what to do.

**Example:** Like a project manager coordinating team members.

**Your Setup:** This is your first/main computer (like toronto-0001).

---

### Worker Node
**Simple:** Additional computers that run your applications.

**Example:** Like extra employees helping with the workload.

**Your Setup:** These are computers you add later (toronto-0002, toronto-0003).

---

###  VPS (Virtual Private Server)
**Simple:** A rented computer on the internet with a public address.

**Example:** Like renting a PO Box vs. using your home address - it's public and permanent.

**Common Providers:** Contabo ($6/month), DigitalOcean ($6/month), Hetzner ($5/month)

---

### Edge Node
**Simple:** A VPS that routes internet traffic to your home servers.

**Example:** Like a receptionist who forwards calls to the right department.

---

## 🌐 Networking Terms

### Tailscale
**Simple:** Software that securely connects your computers together, even if they're in different locations.

**Example:** Like a private phone line between your computers - only you can use it.

**Cost:** Free for up to 20 devices.

---

### IP Address
**Simple:** A unique number that identifies each computer on a network.

**Example:** Like a phone number for computers.

**Tailscale IP:** Usually looks like `100.x.x.x` - your private address.
**Public IP:** Regular internet address like `45.8.133.192` - visible to everyone.

---

### SSL Certificate
**Simple:** Makes your website show the padlock 🔒 (secure connection).

**Example:** Like putting mail in a locked mailbox instead of leaving it on your doorstep.

**MyNodeOne:** Does this automatically for free!

---

### NAT Traversal
**Simple:** Ability to connect to computers behind home routers.

**Example:** Like calling someone's cell phone directly instead of their office landline.

**Why it matters:** Your home computers can be reached without port forwarding.

---

## 💾 Storage Terms

### Storage
**Simple:** Where your data and files are saved.

**Example:** Like a filing cabinet for your digital stuff.

---

### Longhorn Storage
**Simple:** Automatically backs up your data across multiple computers.

**Example:** Like keeping copies of important documents in multiple filing cabinets - if one burns down, you have copies.

**Use for:** Databases, user uploads, important files.

---

### MinIO
**Simple:** S3-compatible storage for files and objects.

**Example:** Like Dropbox or Google Drive, but yours.

**Use for:** Images, videos, backups, file uploads.

---

### Block Storage
**Simple:** Storage that acts like a hard drive for your applications.

**Example:** Like plugging in an external hard drive to your computer.

---

### Object Storage
**Simple:** Storage for files, images, and media.

**Example:** Like a library where you store books (files) and retrieve them by name.

---

### RAID
**Simple:** Combining multiple disks for speed or backup.

**Types:**
- **RAID 0:** Fast but no backup (like writing on multiple pages at once)
- **RAID 1:** Full backup (like carbon copy - everything twice)
- **RAID 5:** Balanced (can lose one disk and recover)
- **RAID 10:** Best of both (fast AND backed up)

---

## 🚀 Application Terms

### Container
**Simple:** A packaged application with everything it needs to run.

**Example:** Like a food truck - it has the kitchen, ingredients, and chef all in one.

---

### Kubernetes (K8s)
**Simple:** Software that manages and runs your applications across multiple computers.

**Example:** Like a restaurant manager deciding which chef cooks which dish.

**MyNodeOne uses:** K3s (lightweight version, perfect for small setups).

---

### Docker
**Simple:** Tool for creating and running containers.

**Example:** Like a shipping container for software - works everywhere.

---

### Deployment
**Simple:** Installing or updating an application.

**Example:** Like publishing a new version of your app.

---

### Pod
**Simple:** One or more containers running together.

**Example:** Like a team working on the same project.

**You'll see:** `kubectl get pods` shows what's running.

---

## 📊 Monitoring Terms

### Monitoring
**Simple:** Watching what's happening in your system in real-time.

**Example:** Like a dashboard in your car showing speed, fuel, temperature.

---

### Prometheus
**Simple:** Collects data about what's happening in your system.

**Example:** Like a data logger recording everything.

---

### Grafana
**Simple:** Pretty dashboards showing your system's health.

**Example:** Like a fitness tracker showing your steps, heart rate, etc.

**You'll use:** To see CPU, RAM, disk usage, and app performance.

---

### Loki
**Simple:** Collects and searches through log messages.

**Example:** Like a search engine for your system's diary entries.

---

### Logs
**Simple:** Messages that applications write when something happens.

**Example:** Like a ship's log - records of what happened and when.

---

## 🔄 GitOps Terms

### GitOps
**Simple:** Your applications automatically update when you push changes to GitHub.

**Example:** Like auto-publish - write blog post, save to Dropbox, instantly appears on website.

---

### ArgoCD
**Simple:** Tool that watches your Git repo and deploys changes automatically.

**Example:** Like a robot that checks your TODO list and does the tasks automatically.

**You'll use:** Push code to GitHub → ArgoCD deploys it → App updates automatically.

---

### Git
**Simple:** Version control system - tracks changes to your code.

**Example:** Like "track changes" in Microsoft Word, but for code.

---

### Repository (Repo)
**Simple:** A folder containing your project's code and history.

**Example:** Like a project folder in Dropbox with version history.

---

## ⚙️ System Terms

### Ubuntu
**Simple:** The version of Linux that MyNodeOne uses.

**Example:** Like Windows or macOS, but free and open-source.

**Required:** Ubuntu 24.04 LTS (LTS = Long Term Support = stable for 5 years).

---

### Terminal / Command Line
**Simple:** Text-based way to control your computer.

**Example:** Like texting commands to your computer instead of clicking.

**Don't worry:** MyNodeOne's scripts do most of the work.

---

### sudo
**Simple:** "Run this command with admin powers."

**Example:** Like "Run as Administrator" in Windows.

**When you see:** `sudo ./scripts/mynodeone` - you're running with full permissions.

---

### Script
**Simple:** A file containing a list of commands to run automatically.

**Example:** Like a recipe - follow steps in order to get result.

**MyNodeOne scripts:** Do all the setup work for you!

---

## 🔐 Security Terms

### SSH
**Simple:** Secure way to access one computer from another.

**Example:** Like remote desktop, but more secure and text-based.

---

### Firewall
**Simple:** Controls what network traffic is allowed in/out.

**Example:** Like a security guard checking IDs at the door.

---

### Encryption
**Simple:** Scrambling data so only authorized people can read it.

**Example:** Like writing in a secret code only you know.

**Tailscale:** Everything is encrypted automatically.

---

## 💰 Cost Terms

### Egress Fees
**Simple:** Charges for data leaving a cloud provider.

**Example:** Like paying for outgoing mail - AWS charges $0.09 per GB leaving their servers.

**MyNodeOne:** $0 egress fees!

---

### TCO (Total Cost of Ownership)
**Simple:** All costs to run something, including hidden costs.

**Example:** Like car ownership - not just purchase price, also gas, insurance, maintenance.

**MyNodeOne TCO:** Hardware (one-time) + electricity (ongoing) + VPS (optional, $5-15/month).

---

### ROI (Return on Investment)
**Simple:** How much money you save/make compared to what you spent.

**Example:** Spend $2,000 on hardware, save $30,000/year = 2,400% ROI.

---

## 🎯 Quick Reference

### When You See...

| Term | Means... |
|------|----------|
| `kubectl` | Command to control Kubernetes |
| `K3s` | Lightweight Kubernetes |
| `100.x.x.x` | Tailscale private IP |
| `pod` | Application running |
| `node` | Computer in cluster |
| `pv` | Persistent Volume (storage) |
| `svc` | Service (how apps connect) |
| `ns` | Namespace (folder for organizing apps) |
| `deploy` | Deployment (running application) |

---

## 📞 Still Confused?

**This is normal!** You don't need to understand everything to use MyNodeOne.

**Think of it like driving a car:**
- ❌ You don't need to know how the engine works
- ✅ You just need to know gas, brake, steering

**With MyNodeOne:**
- ❌ You don't need to know how Kubernetes works
- ✅ You just need to run `sudo ./scripts/mynodeone` and answer questions

---

## 🔍 Need More Help?

- **Quick Questions:** Check [FAQ.md](FAQ.md)
- **Getting Started:** Read [GETTING-STARTED.md](GETTING-STARTED.md)
- **Detailed Guide:** See [INSTALLATION.md](INSTALLATION.md)
- **Problems:** Check [docs/troubleshooting.md](docs/troubleshooting.md)

---

**Remember:** Everyone was a beginner once. Take it step by step! 🚀
