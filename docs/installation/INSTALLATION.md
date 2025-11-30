# MyNodeOne Installation Guide

**Complete step-by-step installation for each node type.**

---

## How to Use This Guide

This guide has **4 independent sections** - one for each node type:

| Section | Node Type | When to Use |
|---------|-----------|-------------|
| **[1. Control Plane](#section-1-control-plane-installation)** | First node (master) | **START HERE** - Always install this first |
| **[2. VPS Edge Node](#section-2-vps-edge-node-installation)** | Public internet access | Add after control plane for public apps |
| **[3. Management Laptop](#section-3-management-laptop-setup)** | Admin workstation | Optional - Control cluster from laptop |
| **[4. Worker Node](#section-4-worker-node-installation)** | Additional compute | Optional - Add more resources to cluster |

**Always start with Section 1 (Control Plane), then choose which other sections you need.**

---

## New to Terminal/Linux?

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

**START HERE - This is your first node!**

---

## What is a Control Plane?

- **Brain of your cluster** - Manages all other nodes
- **First node you install** - Everything else connects to this
- **Most important node** - Keep it reliable and secure
- **Recommended hardware:** 8GB+ RAM, 4+ CPU cores

---

## Prerequisites

### Hardware:
- One machine with **Ubuntu 24.04 LTS** (or 22.04/20.04)
- At least **8GB RAM**
- At least **50GB disk space**
- Network connection (wired or WiFi)

### Software to Install on Control Plane machine:

All commands in this section must be run on the control plane machine:
- If your control plane is a local PC, open a terminal (for example, Ctrl + Alt + T on Ubuntu Desktop).
- If your control plane is a VPS or VDS, SSH into the server from your laptop or desktop and run the commands there.

#### 1. Git (for downloading MyNodeOne)

```bash
# Update package list and upgrade packages
sudo apt update && sudo apt upgrade -y

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

If the SSH service is not `active (running)` or you see errors, re-run the `sudo systemctl enable ssh`, `sudo systemctl start ssh`, and `sudo systemctl status ssh` commands and resolve any reported issues before continuing.

#### 3. Passwordless Sudo (for automation)

**Required for automated sync and cluster management. Run these commands on the control plane machine to configure passwordless sudo for your user.**

**Important:** Before running the commands below, replace `yourusername` with your own Linux username in both the sudoers line and the filename.

```bash
# Create sudoers file (replace 'yourusername' with your actual username)
echo 'yourusername ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/yourusername
sudo chmod 0440 /etc/sudoers.d/yourusername

# Verify it works (should not prompt for a password)
sudo -n echo "Success!"
```

#### 4. Tailscale (secure VPN networking)

**Before you start:** Create a free account at https://tailscale.com and sign in. During installation you will be asked to authenticate with this account.

```bash
# Install curl (if not already installed)
sudo apt install -y curl

# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your Tailscale network
sudo tailscale up
# Open the URL shown in your browser to authenticate

# Verify connection
tailscale status
tailscale ip -4
# Note this IP - you'll need it for VPS/management workstation setup!
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
   This is a human-friendly name for your MyNodeOne cluster; it is used in prompts, logs, and dashboards.
4. **Domain name:** → Enter a domain (e.g., `minicloud.local`)
   This is the base domain you will use to access your services locally (for example, `grafana.minicloud.local`).
5. **Deploy demo app?** → `y` (recommended for testing)

**Installation takes 45-60 minutes.**

**Success looks like:**
```
Your MyNodeOne node has been set up successfully!

Next steps:
  1. Review credentials in your home directory (`~/mynodeone-*-credentials.txt`)
  2. Check status: kubectl get nodes
  3. Deploy apps: kubectl apply -f manifests/examples/
```


### Step 3: (Optional) Apply Security Hardening

**Recommended for production deployments.**

**Note:** The installation wizard in Step 2 already applies these hardening settings, so you do not need to run this separately during a normal installation. This step is available if you skipped hardening during installation or want to apply it later.

```bash
cd ~/MyNodeOne
sudo ./scripts/enable-security-hardening.sh
```

**This enables:**
- Network policies
- Pod security standards
- Resource quotas
- Audit logging

### Step 4: Verify Control Plane is Ready

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
# You'll need this for VPS/management workstation/worker node setup
```

---

## Control Plane Installation Complete!

**What you have now:**
- Kubernetes cluster running
- Passwordless sudo configured automatically
- All services synced and accessible via `.local` domains
- Ready to add other nodes (VPS, workers, management laptops)
- Control plane Tailscale IP noted

**What this means:** Under the hood, MyNodeOne has installed a Kubernetes cluster on your control plane machine. Kubernetes is software that runs and manages containerized applications across one or more machines. Because it runs entirely on hardware you control and is only reachable over your private Tailscale network, it behaves like your own private cloud instead of relying on a public cloud provider.

**Check in your browser on the control plane PC:** Open a web browser on the control plane machine and visit a few `.local` URLs from your credentials file, using the domain name you selected during installation (for example, if you chose `minicloud.local` as your domain, you might see URLs like `http://minicloud.local` or `http://grafana.minicloud.local`). If these pages load, your core control plane services are accessible from that machine.

**Passwordless Sudo:**
The installation automatically configures passwordless sudo for your user. This enables:
- Running `kubectl` commands without password prompts
- Automated sync operations to VPS nodes
- Seamless cluster management

If for any reason it wasn't configured, run:
```bash
sudo ./scripts/setup-control-plane-sudo.sh
```

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

**Add a VPS with a public IP to make your apps accessible from the internet.**

---

## What is a VPS Edge Node (Edge Node)?

A VPS (Virtual Private Server) is a virtual machine you rent from a hosting provider. In MyNodeOne, this VPS acts as an edge node that safely exposes selected services from your private cloud to the internet so you can reach them from other machines. For non-technical users, you can think of it as a secure gateway that forwards traffic from the internet to your private cloud. In the rest of this guide, we may refer to this VPS simply as the edge node.

- **Public Gateway**: A cloud server that acts as a secure entry point to your cluster.
- **Reverse Proxy**: Routes public internet traffic to your control plane through Tailscale's secure mesh network.
- **Auto-HTTPS**: Automatically obtains and renews SSL/TLS certificates from Let's Encrypt.
- **Providers**: Works with any cloud provider (Contabo, Hetzner, DigitalOcean, Linode, Vultr) or a small VM from hyperscalers like AWS, Google Cloud, or Azure.

---

## Security Architecture

**Important:** VPS Edge Nodes are **ONLY** installed from the Control Plane for security reasons:
- Control Plane manages VPS configuration remotely
- VPS cannot access Control Plane (one-way trust)
- SSH keys exchanged securely during orchestration
- Prevents VPS from having Control Plane credentials

---

## Prerequisites

Before you set up a VPS edge node, it is strongly recommended to purchase a domain name. This domain is how your services will be exposed on the internet (for example, `app.yourdomain.com`) and is required for automatic HTTPS certificates. You can buy a domain from any registrar such as Name.com, GoDaddy, or similar providers.

### On Your Control Plane:

Run these commands in a terminal on your control plane machine:

- **Section 1 Complete**: You must have a fully installed and running Control Plane.
- **Kubectl Working**: Run `kubectl get nodes` to verify cluster is running.
- **Tailscale Connected**: Run `tailscale status` to verify.
- **Control Plane Tailscale IP**: Run `tailscale ip -4` and save this IP.

### On Your VPS:

1.  **Provision a Fresh VPS**
    - Ubuntu 24.04 LTS (or 22.04/20.04)
    - At least **8GB RAM required**
    - A **public IPv4 address** assigned by your VPS provider (IPv6-only setups are not supported yet)
    - SSH access working

    For example, providers like Contabo offer suitable VPS plans with a public IPv4 address starting around USD $7 per month.

2.  **Create a Sudo User**
    
    From a terminal on your control plane machine (or another machine with SSH access), connect to your VPS using the initial credentials from your provider (commonly `ssh root@YOUR_VPS_PUBLIC_IP` or `ssh admin@YOUR_VPS_PUBLIC_IP`). Once logged in, you will create your own sudo user.

    In the examples below `sammy` is just an example username. Replace it with your own preferred username, and choose a username that is different from the one you use on your control plane. In these examples, `YOUR_VPS_PUBLIC_IP` is a placeholder – replace it with the public IPv4 address your VPS provider gives you (for example, `203.0.113.10`), without any `<` or `>` characters.

    ⚠️ **Do not use root user** for security reasons.

    ```bash
    # FROM YOUR CONTROL PLANE (or another machine with SSH access):
    ssh root@YOUR_VPS_PUBLIC_IP    # or ssh admin@YOUR_VPS_PUBLIC_IP, depending on your provider

    # ON YOUR NEW VPS (connected as root or admin from the previous command):

    # 1. Create a new user (replace 'sammy' with your own username)
    adduser sammy

    # 2. Add user to sudo group
    usermod -aG sudo sammy

    # 3. Configure passwordless sudo (REQUIRED for orchestration)
    echo 'sammy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/sammy
    sudo chmod 0440 /etc/sudoers.d/sammy

    # 4. Test passwordless sudo
    su - sammy
    sudo -n echo 'Sudo works!'
    # Expected: "Sudo works!" (no password prompt)

    # 5. Log out and reconnect as the new user
    exit
    exit
    # ssh sammy@YOUR_VPS_PUBLIC_IP
    ```

3.  **Install Tailscale on the VPS**
    
    From a terminal on your control plane machine, SSH into the VPS as your new sudo user (for example, `sammy`) using its public IPv4 address (for example, `ssh sammy@YOUR_VPS_PUBLIC_IP`). Once you are logged in, run the following commands on the VPS:
    
    ```bash
    # FROM YOUR CONTROL PLANE (or another machine with SSH access):
    ssh sammy@YOUR_VPS_PUBLIC_IP

    # ON YOUR NEW VPS (connected your sudo user 'sammy' from the previous command):

    # Install curl (if not already installed)
    sudo apt install -y curl

    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    # Start Tailscale and authenticate
    sudo tailscale up

    # Follow the URL to authenticate in browser
    # Verify it's connected
    tailscale status
    
    # Get and save your VPS Tailscale IP
    tailscale ip -4
    # Example: 100.101.237.15 (you'll need this!)

    # When finished, exit to return to your control plane terminal
    exit
    ```

--- 

## Installation Steps

**All steps are performed FROM your Control Plane** - the VPS will be configured remotely.

Open a fresh terminal window on your control plane machine before running the commands below.

### Choose Your Installation Method

**Method 1: One-Click Installation (Recommended)**

Fast, non-interactive installation with all parameters in one command:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne

sudo ./scripts/install-vps-edge-node.sh \
  --name "vps-edge-01" \
  --ip "100.80.255.123" \
  --user "sammy" \
  --public-ip "45.8.133.192" \
  --domain "curiios.com" \
  --email "admin@example.com" \
  --location "NYC"
```

**Replace with your actual values:**
- `--name`: Friendly name for your VPS (e.g., "vps-edge-01")
- `--ip`: VPS Tailscale IP (from `tailscale ip -4` on VPS)
- `--user`: Your sudo user on VPS (e.g., "sammy")
- `--public-ip`: VPS public IP address
- `--domain`: Your public domain name
- `--email`: Your email for SSL certificates
 - `--location`: Optional label for where this VPS is hosted (for example, `NYC`, `London`, or a provider region name). Used in internal registries and dashboards.

**Method 2: Interactive Installation**

Step-by-step with prompts:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne
sudo ./scripts/mynodeone
```

When prompted:
```
Select node type:
  1) Control Plane
  2) Worker Node
  3) VPS Edge Node    ← Select this
  4) Management Workstation
```

Choose **3) VPS Edge Node** and answer the prompts for VPS details

**Interactive prompts will ask for:**

1. **VPS Node Name** (e.g., `vps-edge-01`, `nyc-edge`)
2. **VPS Tailscale IP** (e.g., `100.101.237.15`)
3. **VPS SSH Username** (e.g., `sammy`)
4. **VPS Public IPv4 Address** (e.g., `45.8.133.192`)
5. **VPS Primary Domain** (e.g., `curiios.com`)
6. **SSL Email Address** (e.g., `admin@example.com`)
7. **VPS Location** (Optional: e.g., `NYC`, `London`)

---

### What Happens During Installation

The installer will show a summary and then automatically:
- Detect Control Plane cluster configuration
- Exchange SSH keys with the VPS
- Verify passwordless sudo on VPS
- Generate VPS configuration file
- Transfer MyNodeOne scripts to VPS
- Execute installation remotely
- Install Traefik reverse proxy with Docker
- Configure firewall and monitoring
- Register VPS in sync controller
- Push initial service registry

### What Gets Installed on the VPS

The orchestration automatically installs:
- **Traefik**: Modern reverse proxy with automatic HTTPS
- **Docker**: Container runtime for Traefik
- **UFW Firewall**: Allows only ports 22 (SSH), 80 (HTTP), 443 (HTTPS)
- **Node Exporter**: Monitoring agent for Prometheus
- **Fail2ban**: Protection against brute-force attacks

--- 

## VPS Edge Node Installation Complete!

**What you have now:**
- Secure public entry point for your cluster
- Traefik reverse proxy with automatic HTTPS
- Firewall and monitoring configured
- Secure Tailscale mesh network to Control Plane
- Automated sync system for configuration updates

---

## Making Services Public

After installing your VPS, you can expose your applications to the internet.

### Step 1: Configure DNS

Point your domain to your VPS public IP using your domain registrar's DNS management page (for example, Name.com, GoDaddy, or Cloudflare):

`YOUR_VPS_PUBLIC_IP` is a placeholder – replace it with the public IPv4 address your VPS provider gives you (for example, `45.8.133.192`), without any `<` or `>` characters.

```
Type: A
Name: @ (or your domain)
Value: YOUR_VPS_PUBLIC_IP
TTL: 300

# For subdomains:
Type: A
Name: demo
Value: YOUR_VPS_PUBLIC_IP

Type: A  
Name: chat
Value: YOUR_VPS_PUBLIC_IP
```

### Step 2: Make Services Public

Use the `manage-app-visibility.sh` script to expose services:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne

# Make demo app public
sudo ./scripts/manage-app-visibility.sh public demo yourdomain.com YOUR_VPS_TAILSCALE_IP

# Make LLM chat public (Open WebUI)
sudo ./scripts/manage-app-visibility.sh public open-webui yourdomain.com YOUR_VPS_TAILSCALE_IP

# Example with actual values:
sudo ./scripts/manage-app-visibility.sh public demo curiios.com 100.80.255.123
sudo ./scripts/manage-app-visibility.sh public open-webui curiios.com 100.80.255.123
```

In these commands:

- `public` tells the script to make the service accessible from the internet (use `private` to make it local-only again).
- `demo` or `open-webui` is the internal service name in the MyNodeOne service registry. For example, `open-webui` uses the `chat` subdomain, so it becomes `https://chat.yourdomain.com`.
- `yourdomain.com` is the domain you registered and pointed at your VPS in Step 1. You can pass multiple domains as a comma-separated list (for example, `curiios.com,example.com`).
- `YOUR_VPS_TAILSCALE_IP` is the Tailscale IPv4 address of your VPS edge node (from `tailscale ip -4`). If you have multiple VPS edge nodes, you can pass a comma-separated list of Tailscale IPs.

You can also run the script with no arguments to use the interactive wizard:

```bash
sudo ./scripts/manage-app-visibility.sh
```

The wizard lets you choose the app, domains, and VPS nodes from menus instead of passing them on the command line.

**What happens automatically:**
1. Service is marked as `public: true` in the registry
2. Configuration is pushed to the VPS via SSH
3. VPS generates Traefik routes for the service
4. Traefik requests Let's Encrypt SSL certificate
5. Service becomes accessible at `https://subdomain.yourdomain.com`

### Step 3: Verify Access

Wait 2-5 minutes for SSL certificates, then test:

```bash
# Check if service is accessible
curl -I https://demo.yourdomain.com
curl -I https://chat.yourdomain.com
```

### Automated Sync System

The sync system automatically propagates configuration changes:

- **When you deploy/remove apps**: Service registry is updated
- **When you make services public**: Configuration is pushed to VPS
- **Manual sync**: `sudo ./scripts/lib/sync-controller.sh push`

**How it works:**
1. Control plane maintains service registry in Kubernetes ConfigMap
2. When changes occur, sync-controller SSHes to registered VPS nodes
3. VPS fetches updated registry and regenerates Traefik routes
4. Traefik automatically reloads with new configuration

---

# SECTION 3: Management Laptop/Workstation Setup (Optional)

**Optional:** Set up a laptop or desktop so you can control your cluster/private cloud using `kubectl` from anywhere (for example, your gaming PC stays at home but you manage the cluster from college or a coffee shop), without sitting in front of the control plane machine.

---

## What is a Management Laptop?

- **Remote admin workstation** - Your laptop or desktop that you can use from anywhere (for example, your gaming PC is at home but you control the cluster from campus or a coffee shop)
- **Runs kubectl commands** - Deploy apps, check status, and manage your private cloud from a terminal
- **Does NOT run workloads** - Only for administration
- **Optional but convenient** - Useful if you do not want to sit in front of your control plane PC and prefer to manage things while you are mobile (you can always just SSH directly to the control plane instead)

In simple terms, `kubectl` is the command-line tool for talking to your Kubernetes cluster. You type commands like `kubectl get pods` and it asks the cluster what's running or tells it what to do (for example, deploy an app, scale it up or down, or show logs).

In this section, "management laptop" and "management workstation" are used interchangeably — both refer to the same remote admin machine (your laptop or desktop) that you use to manage the cluster.

---

## Prerequisites

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

Run these commands on your management laptop or workstation:

```bash
sudo apt install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Verify connection
tailscale status

# Get your laptop's Tailscale IP (save this!)
tailscale ip -4
# Example: 100.86.112.112
```

---

### Step 2: Setup SSH Access (Control Plane → Management Laptop)

**⚠️ IMPORTANT:** This step must be done **before** adding the management workstation to the cluster

**Why this is needed:**
- Control plane's sync service needs to SSH to your laptop to push DNS updates
- Service runs as root, so we need root's SSH key
- We also copy your user's key for manual operations and flexibility

**Run the automated setup script (ON YOUR LAPTOP):**

```bash
# On management laptop, clone MyNodeOne first:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Run SSH setup script (it will SSH to control plane and set up keys):
./scripts/setup-management-laptop-ssh.sh \
    <control-plane-user> CONTROL_PLANE_TAILSCALE_IP \
    <laptop-user> LAPTOP_TAILSCALE_IP

# Example:
./scripts/setup-management-laptop-ssh.sh \
    vinaysachdeva 100.101.4.2 \
    vinay 100.101.4.3

# Here, CONTROL_PLANE_TAILSCALE_IP and LAPTOP_TAILSCALE_IP are the **Tailscale IPv4 addresses** of your control plane and laptop, taken from running `tailscale ip -4` on each machine. These are **not** public IP addresses.
# The script will:
# 1. SSH to control plane
# 2. Generate mynodeone SSH keys on control plane (if missing)
# 3. Copy those keys back to your laptop
# 4. Verify SSH access works
```

**What this script does automatically:**
1. **Generates SSH keys** on control plane (if they don't exist)
   - Creates `/root/.ssh/mynodeone_id_ed25519` (for sync service)
   - Creates `~/.ssh/mynodeone_id_ed25519` (for manual operations)
2. **Copies keys to laptop** using `ssh-copy-id` (handles retries, edge cases)
   - Root's key → Required for automatic sync service
   - User's key → Allows manual SSH without sudo
3. **Verifies SSH access** works from control plane to laptop
4. **Handles edge cases:** missing keys, authentication failures, timeouts

**You'll be prompted for:**
- Control plane password (to SSH to control plane)
- Laptop password (for ssh-copy-id to copy keys)

**Security:**
- SSH over encrypted Tailscale VPN only
- Key-based authentication (no passwords after setup)
- Both root and user keys for redundancy

---

### Step 3: Install Management Workstation

```bash
# On laptop (already cloned in Step 2):
cd MyNodeOne

# Run installation:
sudo ./scripts/mynodeone
# Select Option 4: Management Workstation
```

**Interactive prompts:**
1. **Control plane IP:** → Your control plane Tailscale IP
2. **SSH username:** → Your username on control plane

**What the installation does automatically:**

- **Configures passwordless sudo** (allows automatic `/etc/hosts` updates)
- **Copies kubeconfig** from control plane (enables kubectl access)
- **Updates /etc/hosts** with current .local domain names
- **Registers laptop** in control plane sync registry
- **Runs initial DNS sync**

**Result:** 
- kubectl works from laptop
- Services accessible via .local domains
- Auto-sync enabled (DNS updates pushed automatically when apps are installed)

---

### Step 4: Verify Installation

**Verify Security Configuration:**

```bash
# On management laptop:

# 1. Test passwordless sudo
sudo -n echo "Passwordless sudo works!"
# Should print message without password prompt

# 2. Verify both SSH keys were added
cat ~/.ssh/authorized_keys | grep mynodeone
# Should show TWO keys: root's and user's

# On control plane:

# 3. Test SSH as root (what sync service uses - critical!)
sudo ssh username@LAPTOP_TAILSCALE_IP "echo 'Root SSH works!'"
# Should print "Root SSH works!" without password prompt

# 4. Test SSH as your user (for manual operations)
ssh username@LAPTOP_TAILSCALE_IP "echo 'User SSH works!'"
# Should print "User SSH works!" without password prompt

# 5. Test the actual sync command (as root)
sudo ssh username@LAPTOP_TAILSCALE_IP "cd ~/MyNodeOne && sudo ./scripts/sync-dns.sh"
# Should complete without errors
```

In these examples, replace `username` with your Linux username on the laptop and `LAPTOP_TAILSCALE_IP` with the laptop's **Tailscale IPv4 address** from `tailscale ip -4`.

**Verify Cluster Access:**

```bash
# On management laptop:
# Should work without sudo:
kubectl get nodes
# Shows your cluster nodes

kubectl get pods -A
# Shows all pods
```

**Verify DNS Configuration:**

```bash
# On management laptop:
# Check /etc/hosts has MyNodeOne entries
grep "MyNodeOne Services" /etc/hosts
# Should show comment line

# Access services via .local domains:
curl http://grafana.minicloud.local
curl http://photos.minicloud.local
# Replace 'minicloud' with your cluster domain
```

---

## Management Laptop Setup Complete!

**What you can do now:**
- Manage cluster from your laptop using kubectl
- Access services via .local domain names automatically
- Deploy apps without SSHing to control plane
- View logs, restart pods, manage resources

**Automatic DNS Sync:**
When you install new apps on the control plane, DNS entries are **automatically synced** to your laptop! Just wait a few seconds and the new service will be accessible via its .local domain.

**Example workflow (from your management laptop):**
```bash
# 1. Install app using kubectl on your management laptop (kubeconfig already configured)
kubectl apply -f my-app.yaml

# 2. Wait for app to get LoadBalancer IP (still from your management laptop)
kubectl get svc -n my-app

# 3. DNS automatically syncs (no action needed!)
# Wait ~10 seconds for auto-sync

# 4. Access via .local domain from your management laptop
curl http://my-app.minicloud.local
```

**Manual sync (if needed, on your management laptop):**
If you need to force an immediate sync from your management laptop:
```bash
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

---

## Troubleshooting Management Laptop

### Issue: "sudo: a terminal is required to read the password"

**Cause:** Passwordless sudo not configured

**Fix:**
```bash
# On laptop:
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${USER}-nopasswd"
sudo chmod 0440 "/etc/sudoers.d/${USER}-nopasswd"

# Verify:
sudo -n echo "Works"
```

### Issue: "Permission denied (publickey)" when control plane tries to sync

**Cause:** SSH keys not properly configured

**Fix: Re-run the SSH setup script:**
```bash
# On laptop:
cd ~/MyNodeOne
./scripts/setup-management-laptop-ssh.sh \
    <control-plane-user> CONTROL_PLANE_TAILSCALE_IP \
    <laptop-user> LAPTOP_TAILSCALE_IP

# This will (using Tailscale IPv4 addresses for both control plane and laptop):
# - Generate missing SSH keys on control plane
# - Copy both root's and user's keys to laptop
# - Verify SSH access works
```

### Issue: Auto-sync not working

**Symptoms:** New apps installed but not accessible via .local domains

**Diagnosis:**
```bash
# 1. Check if laptop is registered
# On control plane:
sudo ./scripts/lib/sync-controller.sh health
# Should show your laptop in "Management Laptops" section

# 2. Check if sync-controller service is running
# On control plane:
sudo systemctl status mynodeone-sync-controller

# 3. Test manual sync
# On laptop:
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

**Fix:**
```bash
# If not registered, register manually:
# On control plane:
sudo ./scripts/lib/sync-controller.sh register \
    management_laptops \
    LAPTOP_TAILSCALE_IP \
    <laptop-hostname> \
    <username>

# Enable sync service if not running:
sudo ./scripts/enable-sync-controller-service.sh
```

In this example, `LAPTOP_TAILSCALE_IP` is the laptop's **Tailscale IPv4 address** from `tailscale ip -4` (not a public IP address).

### Issue: Laptop was offline, now DNS is stale

**Solution:** Sync happens automatically within 1 hour (periodic reconciliation)

**Or force immediate sync:**
```bash
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

---
---

# SECTION 4: Worker Node Installation (Optional)

**Add more compute resources to your cluster.**

---

## What is a Worker Node?

- **Additional compute node** - Runs workloads alongside control plane
- **Joins existing cluster** - Managed by control plane
- **Optional** - Only add if you need more resources; for example, you can join a friend's gaming PC to your cluster to borrow extra compute, or repurpose your old gaming PC as a worker node.

---

## Prerequisites

- Control plane installed and running
- Another machine (PC or server) with **Ubuntu 24.04 LTS** (or 22.04/20.04) installed
- Network connectivity to control plane

---

## Installation Steps

### Step 1: Get Join Token from Control Plane

```bash
# ON CONTROL PLANE:
cat ~/mynodeone-join-token.txt
# Copy this token and keep it handy
```

### Step 2: Prepare Worker Machine

```bash
# ON WORKER MACHINE: install prerequisites (same as control plane)
sudo apt update
sudo apt install -y git openssh-server

# Install Tailscale (and curl if needed):
sudo apt install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### Step 3: Install Worker Node

```bash
# ON WORKER MACHINE:
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

sudo ./scripts/mynodeone
# Select Option 2: Worker Node
# Paste join token when prompted
```

### Step 4: Verify from Control Plane

```bash
# ON CONTROL PLANE:
sudo kubectl get nodes
# Should show worker node as "Ready"
```

---

## Worker Node Installation Complete!

Your cluster now has additional compute resources!

---

**Installation complete! Welcome to MyNodeOne!**

**Next:** See [POST_INSTALLATION_GUIDE.md](POST_INSTALLATION_GUIDE.md) for immediate next steps.

