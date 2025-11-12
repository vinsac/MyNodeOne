# MyNodeOne Installation Guide

**Complete step-by-step installation for each node type.**

---

## 📖 How to Use This Guide

This guide has **4 independent sections** - one for each node type:

| Section | Node Type | When to Use |
|---------|-----------|-------------|
| **[1. Control Plane](#section-1-control-plane-installation)** | First node (master) | **START HERE** - Always install this first |
| **[2. VPS Edge Node](#section-2-vps-edge-node-installation)** | Public internet access | Add after control plane for public apps |
| **[3. Management Laptop](#section-3-management-laptop-setup)** | Admin workstation | Optional - Control cluster from laptop |
| **[4. Worker Node](#section-4-worker-node-installation)** | Additional compute | Optional - Add more resources to cluster |

**👉 Always start with Section 1 (Control Plane), then choose which other sections you need.**

---

## 🌱 New to Terminal/Linux?

**First time with command line?** → Read **[TERMINAL-BASICS.md](TERMINAL-BASICS.md)** first!

Learn how to:
- Open terminal
- Copy/paste commands  
- Understand command output
- Fix common mistakes

**Takes 10 minutes, saves hours of confusion!**

---
---

# SECTION 1: Control Plane Installation

**🎯 START HERE - This is your first node!**

---

## What is a Control Plane?

- **Brain of your cluster** - Manages all other nodes
- **First node you install** - Everything else connects to this
- **Most important node** - Keep it reliable and secure
- **Recommended hardware:** 8GB+ RAM, 4+ CPU cores (4GB works for learning)

---

## Prerequisites

### Hardware:
- ✅ One machine with **Ubuntu 24.04 LTS** (or 22.04/20.04)
- ✅ At least **4GB RAM** (8GB+ recommended for production)
- ✅ At least **20GB disk space**
- ✅ Network connection (wired or WiFi)
- ✅ Desktop or Server edition works

### Software to Install:

#### 1. Git (for downloading MyNodeOne)

```bash
# Open terminal: Press Ctrl + Alt + T on Ubuntu Desktop

# Update package list
sudo apt update

# Install git
sudo apt install -y git

# Verify installation
git --version
# Expected output: git version 2.x.x
```

#### 2. SSH Server (for remote management)

```bash
# Install OpenSSH server
sudo apt install -y openssh-server

# Enable and start SSH
sudo systemctl enable ssh
sudo systemctl start ssh

# Verify it's running
sudo systemctl status ssh
# Expected: "active (running)"
```

#### 3. Tailscale (secure VPN networking)

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your Tailscale network
sudo tailscale up
# Open the URL shown in your browser to authenticate

# Verify connection
tailscale status
tailscale ip -4
# Note this IP - you'll need it for VPS/management setup!
```

---

## Installation Steps

### Step 1: Download MyNodeOne

```bash
# Clone the repository
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Verify you're in the right directory
ls
# Should show: scripts/ docs/ README.md etc.
```

### Step 2: Run Interactive Installation Wizard

```bash
# Run the installer
sudo ./scripts/mynodeone
```

**Interactive prompts:**

1. **Ready to start?** → `y`
2. **Select node type (1-4):** → `1` (Control Plane)
3. **Cluster name:** → Enter a name (e.g., `universe`, `homelab`, `mycloud`)
4. **Domain name:** → Enter a domain (e.g., `minicloud.local`)
5. **Deploy demo app?** → `y` (recommended for testing)

**Installation takes 5-10 minutes.**

**Success looks like:**
```
✅ Your MyNodeOne node has been set up successfully! 🎉

Next steps:
  1. Review credentials in /root/mynodeone-*-credentials.txt
  2. Check status: kubectl get nodes
  3. Deploy apps: kubectl apply -f manifests/examples/
```

### Step 3: ⚠️ MANDATORY - Configure Passwordless Sudo

> **🔴 CRITICAL:** This step is **MANDATORY** if you plan to add VPS edge nodes or management laptops!
>
> **Why?** VPS and management nodes need to run commands on the control plane remotely via SSH. Without passwordless sudo, these commands will hang waiting for a password.
>
> **When?** **RIGHT NOW**, immediately after control plane installation completes.

**Run this command:**

```bash
cd ~/MyNodeOne
./scripts/setup-control-plane-sudo.sh
# Both with and without 'sudo' work:
# sudo ./scripts/setup-control-plane-sudo.sh
```

**Expected output:**
```
🔐 MyNodeOne Control Plane - Passwordless Sudo Configuration

[INFO] Configuring passwordless sudo for: yourusername
[✓] Sudoers file installed
[✓] Sudoers syntax verified
[✓] kubectl passwordless sudo: OK
[✓] Script passwordless sudo: OK
[✓] Remote sudo pattern: OK

[✓] Passwordless sudo configured successfully!
```

**Verify it worked:**
```bash
# Should run WITHOUT asking for password:
sudo kubectl version --client
# Expected: Version output, no password prompt
```

**Which nodes need this script?**

| Node Type | Run This Script? |
|-----------|------------------|
| **Control Plane** | ✅ **YES** (run it now!) |
| **VPS Edge Node** | ❌ NO |
| **Management Laptop** | ❌ NO |
| **Worker Node** | ❌ NO |

> 💡 **Remember:** Only the control plane needs passwordless sudo because other nodes connect **TO** it, not vice versa.

### Step 4: (Optional) Apply Security Hardening

**Recommended for production deployments:**

```bash
cd ~/MyNodeOne
sudo ./scripts/enable-security-hardening.sh
```

**This enables:**
- Network policies
- Pod security standards
- Resource quotas
- Audit logging

### Step 5: Verify Control Plane is Ready

```bash
# Check node status
sudo kubectl get nodes
# Expected: "Ready"

# Check all pods are running
sudo kubectl get pods -A
# All pods should show "Running"

# Get your Tailscale IP (SAVE THIS!)
tailscale ip -4
# Example: 100.116.16.117
# You'll need this for VPS/management/worker setup
```

---

## ✅ Control Plane Installation Complete!

**What you have now:**
- ✅ Kubernetes cluster running
- ✅ Passwordless sudo configured
- ✅ Ready to add other nodes
- ✅ Control plane Tailscale IP noted

**Next Steps - Choose What You Need:**

- **Want public internet access for your apps?**
  → Go to [Section 2: VPS Edge Node](#section-2-vps-edge-node-installation)

- **Want to control your cluster from your laptop?**
  → Go to [Section 3: Management Laptop](#section-3-management-laptop-setup)

- **Want to add more compute resources?**
  → Go to [Section 4: Worker Node](#section-4-worker-node-installation)

- **Done for now?**
  → Your control plane is fully functional! You can deploy apps locally.

---
---

# SECTION 2: VPS Edge Node Installation

**Add a VPS with public IP to make your apps accessible from the internet.**

---

## What is a VPS Edge Node?

- **Public-facing reverse proxy** - Routes internet traffic to your cluster
- **SSL/TLS termination** - Handles HTTPS certificates automatically  
- **Requires:** A VPS with public IPv4 address
- **Popular providers:** Contabo, Hetzner, DigitalOcean, Linode, Vultr, AWS

---

## ⚠️ Prerequisites - MUST BE DONE FIRST

> **🔴 STOP!** Before installing VPS, verify these are complete:

### On Control Plane (Must Be Ready):

```bash
# 1. Verify control plane is running:
sudo kubectl get nodes
# Must show: "Ready"

# 2. Verify passwordless sudo is configured:
sudo kubectl version --client
# Must NOT ask for password

# 3. Get control plane Tailscale IP:
tailscale ip -4
# Example: 100.116.16.117
# SAVE THIS IP - you'll need it!
```

**If ANY of these fail, go back to [Section 1](#section-1-control-plane-installation) and complete it first!**

### On Your VPS:

#### 1. Provision Fresh VPS

- ✅ Ubuntu 24.04 LTS (or 22.04/20.04)
- ✅ At least 1GB RAM, 1 CPU core
- ✅ **Public IPv4 address** (required!)
- ✅ SSH access (as root or sudo user)

#### 2. Create Sudo User (RECOMMENDED)

**Don't run as root in production!**

```bash
# SSH to VPS as root:
ssh root@your-vps-ip

# Create sudo user:
sudo adduser vpsuser
sudo usermod -aG sudo vpsuser

# Switch to new user:
su - vpsuser

# All following commands run as vpsuser
```

#### 3. Install Tailscale on VPS

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your Tailscale network
sudo tailscale up
# Open browser URL to authenticate

# Verify connection
tailscale status
tailscale ip -4
# Example: 100.123.101.75
# Note this IP!
```

#### 4. ⚠️ CRITICAL: Exchange SSH Keys (VPS → Control Plane)

**🔴 This is the #1 most commonly skipped step! DO NOT SKIP THIS!**

```bash
# On VPS, generate SSH key:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy SSH key to control plane:
ssh-copy-id <your-username>@<control-plane-tailscale-ip>

# Example:
ssh-copy-id vinaysachdeva@100.116.16.117
# Enter password when prompted (last time!)

# Test SSH (should NOT ask for password):
ssh vinaysachdeva@100.116.16.117 'echo OK'
# Expected output: OK

# 🔴 CRITICAL TEST - Verify passwordless sudo works remotely:
ssh vinaysachdeva@100.116.16.117 'sudo kubectl version --client'
# Expected: Version output WITHOUT password prompt
```

**If the last command asks for password:**
- Passwordless sudo is NOT configured on control plane
- Go back to control plane and run: `./scripts/setup-control-plane-sudo.sh`
- Then test again

---

## Installation Steps

### Step 1: ⚠️ CRITICAL FIRST - Exchange SSH Keys

**🛑 STOP! Do this BEFORE downloading or running ANYTHING!**

**Important:** Run these commands as your **regular user** (not with sudo):

```bash
# On VPS, generate SSH key (as regular user, NOT with sudo):
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy SSH key to control plane (enter password one last time):
ssh-copy-id <your-username>@<control-plane-tailscale-ip>

# Example:
ssh-copy-id vinaysachdeva@100.116.16.117
# Enter password when prompted (LAST TIME you'll need it!)

# Test SSH (should NOT ask for password):
ssh vinaysachdeva@100.116.16.117 'echo OK'
# Expected: OK (no password prompt)

# 🔴 CRITICAL TEST - Verify passwordless sudo:
ssh vinaysachdeva@100.116.16.117 'sudo kubectl version --client'
# Expected: Version output WITHOUT asking for password
```

**Why not use sudo for these commands?**
- SSH keys must be in YOUR user's home directory (~/.ssh/)
- The installation script will automatically use YOUR keys even when run with sudo
- If you run ssh-keygen with sudo, keys go to /root/.ssh/ (wrong location!)

**✅ If both tests pass:** Continue to Step 2  
**❌ If sudo asks for password:** Run on control plane: `./scripts/setup-control-plane-sudo.sh`

---

### Step 2: Download MyNodeOne on VPS

```bash
# On VPS:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Verify you have latest code:
git log --oneline -1
```

### Step 3: Run Pre-flight Checks

**ALWAYS run pre-flight checks BEFORE installation!**

```bash
# On VPS:
./scripts/check-prerequisites.sh vps <control-plane-ip> <ssh-user>

# Example:
./scripts/check-prerequisites.sh vps 100.116.16.117 vinaysachdeva
```

**Expected output if ready:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🔍 Pre-flight Checks: vps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[✓] SSH connection: OK
[✓] Passwordless sudo: OK
[✓] Kubernetes cluster: RUNNING
[✓] Tailscale connected: 100.123.101.75
[✓] Docker: NOT INSTALLED (will be installed)
[✓] Ports 80, 443: AVAILABLE
[✓] No IP conflicts detected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Ready to proceed with vps installation!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**If ANY check fails:**

| Error | Fix |
|-------|-----|
| `SSH connection: FAILED` | Go back to Step 1 - Exchange SSH keys! |
| `Passwordless sudo: NOT CONFIGURED` | Fix control plane sudo setup |
| `Kubernetes cluster: NOT RUNNING` | Check control plane is running |
| `Ports in use: 80 443` | Stop services using these ports |

**DO NOT PROCEED until all checks pass!**

### Step 4: Run VPS Installation

**✅ Prerequisites complete? SSH keys work? Pre-flight checks passed?**

```bash
# On VPS:
sudo ./scripts/mynodeone
```

**Interactive prompts:**

1. **Ready to start?** → `y`
2. **Select node type (1-4):** → `3` (VPS Edge Node)
3. **Control plane Tailscale IP:** → `100.116.16.117` (your control plane IP)
4. **SSH username on control plane:** → `vinaysachdeva` (your username)
5. **Node name:** → Accept default or enter custom name
6. **Location:** → Enter provider-location (e.g., `contabo-europe`, `digitalocean-nyc`)
7. **Confirm public IP:** → Verify your VPS public IPv4 address
8. **Email for SSL certificates:** → `your-email@example.com`
9. **Proceed with installation?** → `y`
10. **Use STAGING mode?** → `y` (recommended for first install - unlimited cert requests!)

**Installation takes 5-10 minutes.**

**Success looks like:**
```
✅ VPS Edge Node setup complete! 🎉

Next steps:
  1. Point your DNS records to this IP: 45.8.133.192
  2. Add application routes in: /etc/traefik/dynamic/mynodeone-routes.yml
```

### Step 5: Verify VPS Installation

```bash
# Check Traefik is running:
docker ps
# Should show: traefik container with status "Up"

# Check ports are listening:
sudo netstat -tlnp | grep -E ':(80|443)'
# Should show Traefik listening on both ports

# Check Traefik logs:
docker logs traefik
# Should NOT show permission errors
```

### Step 6: Configure DNS for Your Domain

**Point your domain to your VPS public IP:**

```
# In your DNS provider (Cloudflare, Namecheap, etc.):
A     @     45.8.133.192   3600
A     *     45.8.133.192   3600

# Replace 45.8.133.192 with YOUR VPS public IP
```

**Verify DNS propagation:**
```bash
# On VPS:
~/MyNodeOne/scripts/check-dns-ready.sh yourdomain.com <your-vps-public-ip>

# Example:
~/MyNodeOne/scripts/check-dns-ready.sh example.com 45.8.133.192
```

---

## ✅ VPS Edge Node Installation Complete!

**What you have now:**
- ✅ Public-facing reverse proxy running
- ✅ SSL certificates automatically managed
- ✅ VPS registered in your cluster
- ✅ Firewall configured
- ✅ Ready to route public traffic to your apps

**Next Steps:**
- Add application routes in `/etc/traefik/dynamic/mynodeone-routes.yml`
- Deploy public-facing applications to your cluster
- Monitor certificates: `~/MyNodeOne/scripts/check-certificates.sh`

---
---

# SECTION 3: Management Laptop Setup

**Control your cluster from your laptop/desktop using kubectl.**

---

## What is a Management Laptop?

- **Remote admin workstation** - Your laptop or desktop
- **Runs kubectl commands** - Deploy apps, check status, manage cluster
- **Does NOT run workloads** - Only for administration
- **Optional but convenient** - You can also SSH to control plane

---

## ⚠️ Prerequisites

> **REQUIREMENT:** Control plane must be installed and passwordless sudo configured!

```bash
# Verify on control plane:
sudo kubectl get nodes
# Must show: "Ready"

sudo kubectl version --client
# Must NOT ask for password
```

---

## Installation Steps

### Step 1: Install Tailscale on Laptop

```bash
# Download from: https://tailscale.com/download
# Or on Ubuntu:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Verify connection
tailscale status
```

### Step 2: (Optional) Exchange SSH Keys

```bash
# On laptop:
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
ssh-copy-id vinaysachdeva@<control-plane-ip>

# Test:
ssh vinaysachdeva@<control-plane-ip> 'echo OK'
```

### Step 3: Install Management Workstation

```bash
# On laptop:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Run installation:
sudo ./scripts/mynodeone
# Select Option 4: Management Workstation
```

**Interactive prompts:**
1. **Control plane IP:** → Your control plane Tailscale IP
2. **SSH username:** → Your username on control plane

**Installation copies kubeconfig and configures kubectl.**

### Step 4: Verify

```bash
# Should work without sudo:
kubectl get nodes
# Shows your cluster nodes

kubectl get pods -A
# Shows all pods
```

---

## ✅ Management Laptop Setup Complete!

You can now manage your cluster from your laptop!

---
---

# SECTION 4: Worker Node Installation

**Add more compute resources to your cluster.**

---

## What is a Worker Node?

- **Additional compute node** - Runs workloads alongside control plane
- **Joins existing cluster** - Managed by control plane
- **Optional** - Only add if you need more resources

---

## Prerequisites

- ✅ Control plane installed and running
- ✅ Another machine with Ubuntu installed
- ✅ Network connectivity to control plane

---

## Installation Steps

### Step 1: Prepare Worker Machine

```bash
# Install prerequisites (same as control plane):
sudo apt update
sudo apt install -y git openssh-server

# Install Tailscale:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### Step 2: Get Join Token from Control Plane

```bash
# On control plane:
cat /root/mynodeone-join-token.txt
# Copy this token
```

### Step 3: Install Worker Node

```bash
# On worker machine:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

sudo ./scripts/mynodeone
# Select Option 2: Worker Node
# Paste join token when prompted
```

### Step 4: Verify

```bash
# On control plane:
sudo kubectl get nodes
# Should show worker node as "Ready"
```

---

## ✅ Worker Node Installation Complete!

Your cluster now has additional compute resources!

---
---

# Need Help?

- **📖 Complete prerequisite guide:** [INSTALLATION_PREREQUISITES.md](../INSTALLATION_PREREQUISITES.md)
- **🔧 Production ready summary:** [PRODUCTION_READY_SUMMARY.md](../PRODUCTION_READY_SUMMARY.md)
- **❓ Troubleshooting:** Check pre-flight scripts and logs
- **🐛 Found a bug?** Create an issue on GitHub

---

**Installation complete! Welcome to MyNodeOne! 🎉**

