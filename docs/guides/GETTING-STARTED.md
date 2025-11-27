# START HERE - New to MyNodeOne?

**Welcome!** This is your starting point for building your private cloud with MyNodeOne.

---

## Brand new to Linux/terminal?

**Never used command line before?** → Read **[TERMINAL-BASICS.md](TERMINAL-BASICS.md)** first!

This guide teaches you:
- How to open terminal
- How to copy/paste commands  
- What `sudo` means
- What to expect when running commands

**10 minutes reading = ready to install MyNodeOne!**

---

## Ready to install?

### If you're ready RIGHT NOW:
→ Go to **[INSTALLATION.md](INSTALLATION.md)** for step-by-step installation instructions!

**That guide will tell you:**
- Exactly which machine to use
- Where to open terminal
- What commands to run
- What to expect at each step

**Time:** 30 minutes from start to running cluster!

---

## Want to learn first?

If you want to understand before installing, read the sections below.

---

## What should you read?

> **Lost?** Check the **[DOCUMENTATION-INDEX.md](DOCUMENTATION-INDEX.md)** for a complete map of all documentation.

### Brand new? Read in this order:
1. **This file** - You're reading it! (understand what MyNodeOne is)
2. **[TERMINAL-BASICS.md](TERMINAL-BASICS.md)** - If new to terminal (10 min)
3. **[docs/setup-options-guide.md](docs/setup-options-guide.md)** - Understand your options (15 min)
4. **[INSTALLATION.md](INSTALLATION.md)** - Install step-by-step (30 min actual install)

### Ready to install now?
→ **[INSTALLATION.md](INSTALLATION.md)** - Complete installation guide with all commands

### Already installed?
1. **[docs/operations.md](docs/operations.md)** - Daily management
2. **[docs/architecture.md](docs/architecture.md)** - How it works
3. **[../reference/FAQ.md](../reference/FAQ.md)** - Common questions

### Something not working?
1. **[docs/troubleshooting.md](docs/troubleshooting.md)** - Problem solving
2. **[../reference/FAQ.md](../reference/FAQ.md)** - 50+ questions answered

---

## What do you need?

### Minimum requirements
- **1 machine** with Ubuntu LTS
  - **Recommended:** Ubuntu 24.04 LTS (best tested)
  - **Also works:** Ubuntu 22.04 LTS, Ubuntu 20.04 LTS
  - **New to Ubuntu?** For installation instructions, refer to the [official Ubuntu installation guide](https://ubuntu.com/tutorials/install-ubuntu-desktop) or search "how to install Ubuntu 24.04" on ChatGPT, Gemini, or your preferred AI assistant.
- **4GB RAM** (8GB+ recommended)
- **20GB disk** (100GB+ recommended)
- **Internet connection**
- **Basic software** (git, SSH, Tailscale) - [INSTALLATION.md](INSTALLATION.md) shows how to install these

That's it! Start with what you have, scale later.

### Optional additions
- **VPS with public IP** ($5-15/month) - for public internet access
- **More machines** - add workers later as you grow

> **Need help?** If you encounter any issues following these steps or understanding the commands, feel free to consult ChatGPT, Gemini, Claude, or other AI assistants for guidance.

---

## What does installation do?

The `sudo ./scripts/mynodeone` command:

1. **Cleans your system** - Removes unnecessary software to save RAM
2. **Detects external disks** - Finds and offers to configure extra storage
3. **Asks a few questions** - Name, location, what type of computer this is
4. **Secure networking** - Connects your machines safely (using Tailscale)
5. **Application platform** - Installs software to run your apps (Kubernetes)
6. **Storage system** - Sets up automatic backups and file storage
7. **Monitoring dashboard** - Lets you see what's happening in real-time
8. **Automatic deployment** - Apps update when you push to GitHub

**Time:** 30-45 minutes  
**Interaction:** Answer ~5 questions  
**Everything else:** Automatic

> **Don't understand these terms?** Check the [GLOSSARY.md](GLOSSARY.md) for simple explanations.

---

## Networking: Tailscale (default)

**MyNodeOne uses Tailscale by default** for secure networking between machines.

### What is Tailscale?
- Secure mesh VPN (like a private internet for your machines)
- Each machine gets a private IP (100.x.x.x)
- Works behind NAT/firewalls automatically
- Free for up to 20 devices

### Why Tailscale?
- Five minute setup - fastest option
- Zero configuration - just works
- Free for personal use
- Well suited for MyNodeOne

### Installation handles it
The installation script automatically:
- Installs Tailscale
- Authenticates (opens browser)
- Gets your IP
- Configures everything

**You don't need to do anything.**

### Want alternatives?
See [docs/networking.md](docs/networking.md) for Headscale, Netmaker, ZeroTier, WireGuard, etc.

**Recommendation:** Stick with Tailscale (default).

---

## Common scenarios

### Scenario 1: Just learning
**What you have:** 1 old laptop or desktop  
**What to do:**
1. Run `sudo ./scripts/mynodeone`
2. Select: **Control Plane**
3. Deploy example apps
4. Access via Tailscale from your phone/laptop

**Cost:** $0/month  
**Perfect for:** Learning Kubernetes, testing apps

---

### Scenario 2: Home server
**What you have:** 1 powerful home server (like yours: 256GB RAM)  
**What to do:**
1. Run `sudo ./scripts/mynodeone`
2. Select: **Control Plane**
3. Let it detect your external disks (2x18TB)
4. Access from laptop via Tailscale

**Cost:** $0/month (electricity only)  
**Perfect for:** Running LLMs, databases, apps at home

---

### Scenario 3: Public website
**What you have:** 1 home server + 1 VPS  
**What to do:**

**Home server:**
```bash
# Clone (HTTPS or SSH):
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

sudo ./scripts/mynodeone
# Select: Control Plane
```

**VPS:**
```bash
# Clone (HTTPS or SSH):
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

sudo ./scripts/mynodeone
# Select: VPS Edge Node
```

**Cost:** $5-15/month (VPS)  
**Perfect for:** Public-facing apps, websites with SSL

---

### Scenario 4: Production scale
**What you have:** 3 servers + 2 VPS  
**What to do:**

**Server 1:** Control Plane  
**Server 2-3:** Worker Nodes  
**VPS 1-2:** Edge Nodes (load balanced)

**Cost:** $10-30/month (VPS)  
**Perfect for:** High availability, production workloads

---

### Scenario 5: VPS-only (no home hardware)
**What you have:** No home hardware, just VPS  
**What to do:**

**VPS 1:** Control Plane (4GB+ RAM)  
**VPS 2-3:** Worker Nodes (2GB+ RAM)  

```bash
# On each VPS, run:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
# Select: Control Plane (VPS 1) or Worker Node (VPS 2-3)
```

**Cost:** $30-60/month  
**Perfect for:** 100% cloud-based, no home hardware needed, public internet access

---

## Documentation map

```
GETTING-STARTED.md ← you are here
    ↓
README.md (overview)
    ↓
docs/setup-options-guide.md (understand choices)
    ↓
INSTALLATION.md (step-by-step)
    ↓
sudo ./scripts/mynodeone (install!)
    ↓
docs/operations.md (daily use)
    ↓
docs/architecture.md (deep dive)
    ↓
docs/scaling.md (grow your cloud)
```

---

## Next steps

### Right now (5 minutes)
1. You're reading GETTING-STARTED.md
2. Read [README.md](README.md) - get the big picture
3. Read [docs/setup-options-guide.md](docs/setup-options-guide.md) - understand options

### Before installing (15 minutes)
1. Read [INSTALLATION.md](INSTALLATION.md) - see step-by-step
2. Skim [../reference/FAQ.md](../reference/FAQ.md) - common questions
3. Decide your scenario (learning, home, or production)

### Ready to install?
```bash
# Clone using HTTPS (recommended for beginners):
git clone https://github.com/vinsac/MyNodeOne.git
# OR using SSH: git clone git@github.com:vinsac/MyNodeOne.git

cd MyNodeOne
sudo ./scripts/mynodeone
```

Have [INSTALLATION.md](INSTALLATION.md) open for reference!

### After installation (1 hour)
1. Read [docs/operations.md](docs/operations.md) - learn daily management
2. Deploy an example app from `manifests/examples/`
3. Explore Grafana dashboards
4. Deploy the documentation website: `./website/deploy.sh`

### Growing your cloud
1. Read [docs/scaling.md](docs/scaling.md) - add more nodes
2. Customize for your needs
3. Star the repo if you like it

---

## Safety and common concerns

### Will this break my computer?
**No.** MyNodeOne only installs software in its own directories. Your personal files and existing setup remain untouched.

### What if something goes wrong?
The script stops if there's an error. Nothing is changed until you explicitly confirm. You'll see what's happening at each step.

### Can I undo the installation?
Yes! You can uninstall MyNodeOne completely. (We'll add an uninstall guide soon.)

### What about my existing files?
MyNodeOne installs to `/opt/mynodeone` and doesn't touch your documents, photos, etc.

**Important:** If you choose to format a disk for storage, that disk's data will be erased. The script will warn you and ask for confirmation first.

### What if I get stuck?
1. Check [docs/troubleshooting.md](docs/troubleshooting.md)
2. Check [../reference/FAQ.md](../reference/FAQ.md) - 50+ questions answered
3. Look up error messages in [GLOSSARY.md](GLOSSARY.md)
4. Open an issue on GitHub

---

## Quick questions

**Q: I have no idea what Kubernetes is. Can I still use this?**  
A: Yes! You don't need to understand the technology. Just follow the steps. (But check [GLOSSARY.md](GLOSSARY.md) if curious!)

**Q: Do I need a VPS?**  
A: No! Only if you want your apps accessible from the public internet. For personal/internal use, Tailscale is enough.

**Q: How much does this cost?**  
A: $0/month for home-only setup. $5-30/month if you add VPS for public access. No hidden costs!

**Q: Can I run this on Windows/Mac?**  
A: The servers need Ubuntu Linux. But your laptop (Windows/Mac/Linux) can manage the cluster via Tailscale.

**Q: How long does setup take?**  
A: 30-45 minutes for first node. Mostly automated - you just answer a few questions.

**Q: Which networking should I use?**  
A: **Tailscale (default)**. It's automatic and just works. Don't overthink it!

**Q: Can I migrate from AWS?**  
A: MyNodeOne IS your AWS alternative! Run the same apps here for 95% less cost.

**Q: What if I don't understand the technical terms?**  
A: Check [GLOSSARY.md](GLOSSARY.md) - we explain everything in simple language!

---

## All documentation

### Essential (read first)
- **[GETTING-STARTED.md](GETTING-STARTED.md)** ← You are here
- **[README.md](README.md)** - Project overview
- **[docs/setup-options-guide.md](docs/setup-options-guide.md)** - What each option means
- **[INSTALLATION.md](INSTALLATION.md)** - Step-by-step guide

### Reference guides
- **[docs/architecture.md](docs/architecture.md)** - How MyNodeOne works
- **[docs/operations.md](docs/operations.md)** - Daily management
- **[docs/troubleshooting.md](docs/troubleshooting.md)** - Fix problems
- **[docs/scaling.md](docs/scaling.md)** - Add more nodes
- **[docs/networking.md](docs/networking.md)** - Tailscale + alternatives

### Help and community
- **[../reference/FAQ.md](../reference/FAQ.md)** - 50+ questions answered
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute

### Technical deep dives
- **[FINAL-SUMMARY.md](FINAL-SUMMARY.md)** - Complete implementation
- **[ANSWERS-TO-QUESTIONS.md](ANSWERS-TO-QUESTIONS.md)** - Design decisions
- **[COMPLETION-REPORT.md](COMPLETION-REPORT.md)** - What's been built

---

## Ready to start?

1. **Read** [README.md](README.md) (5 min)
2. **Read** [docs/setup-options-guide.md](docs/setup-options-guide.md) (15 min)
3. **Run** `sudo ./scripts/mynodeone`
4. **Celebrate** your new private cloud.

---

## Pro tips

- **Use Tailscale (default)** - don't change it unless you know why
- **Start small** - one machine is fine, scale later
- **Say yes to disk detection** - let it configure storage
- **Say yes to system cleanup** - saves RAM and disk
- **Keep documentation open** - reference while installing
- **Don't skip backups** - set up after installation

---

## One command to run everything

```bash
sudo ./scripts/mynodeone
```

That's it. Everything else is automatic.

**Welcome to MyNodeOne.**

---

**Questions?** Check [FAQ.md](FAQ.md)  
**Problems?** See [docs/troubleshooting.md](docs/troubleshooting.md)  
**Ready?** Run `sudo ./scripts/mynodeone`
