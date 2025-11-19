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

> **Cloud Deployment Note:** Planning to run your Control Plane on a cloud server (VPS/VDS) instead of a physical machine at home? Read the [**Cloud Control Plane Use Case**](../use-cases/cloud-control-plane.md) first for critical security setup instructions.

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

#### 3. Passwordless Sudo (for automation)

**Required for automated sync and cluster management.**

```bash
# Test if you already have passwordless sudo
sudo -n echo "Passwordless sudo works!"

# If it asks for password, you need to configure it:
# The installation script will configure this automatically,
# or you can set it up manually:

# Create sudoers file (replace 'yourusername' with your actual username)
echo 'yourusername ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/yourusername
sudo chmod 0440 /etc/sudoers.d/yourusername

# Verify it works
sudo -n echo "Success!"
```

**Note:** The control plane installation script will configure this automatically at the end. This is just for reference if you want to set it up beforehand.

#### 4. Tailscale (secure VPN networking)

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
  1. Review credentials in your home directory (`~/mynodeone-*-credentials.txt`)
  2. Check status: kubectl get nodes
  3. Deploy apps: kubectl apply -f manifests/examples/
```


### Step 3: (Optional) Apply Security Hardening

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
# You'll need this for VPS/management/worker setup
```

---

## ✅ Control Plane Installation Complete!

**What you have now:**
- ✅ Kubernetes cluster running
- ✅ Passwordless sudo configured automatically
- ✅ All services synced and accessible via `.local` domains
- ✅ Ready to add other nodes (VPS, workers, management laptops)
- ✅ Control plane Tailscale IP noted

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

## What is a VPS Edge Node?

- **Public Gateway**: A cloud server that acts as a secure entry point to your cluster.
- **Reverse Proxy**: Routes public internet traffic to your control plane through Tailscale's secure mesh network.
- **Auto-HTTPS**: Automatically obtains and renews SSL/TLS certificates from Let's Encrypt.
- **Providers**: Works with any cloud provider (Contabo, Hetzner, DigitalOcean, Linode, Vultr, etc.).

---

## 🔒 Security Architecture

**Important:** VPS Edge Nodes are **ONLY** installed from the Control Plane for security reasons:
- ✅ Control Plane manages VPS configuration remotely
- ✅ VPS cannot access Control Plane (one-way trust)
- ✅ SSH keys exchanged securely during orchestration
- ✅ Prevents VPS from having Control Plane credentials

---

## Prerequisites

### On Your Control Plane:

- ✅ **Section 1 Complete**: You must have a fully installed and running Control Plane.
- ✅ **Kubectl Working**: Run `kubectl get nodes` to verify cluster is running.
- ✅ **Tailscale Connected**: Run `tailscale status` to verify.
- ✅ **Control Plane Tailscale IP**: Run `tailscale ip -4` and save this IP.

### On Your VPS:

1.  **Provision a Fresh VPS**
    - ✅ Ubuntu 24.04 LTS (or 22.04/20.04)
    - ✅ At least **1GB RAM, 1 CPU core** (2GB+ RAM recommended)
    - ✅ A **public IPv4 address** is required
    - ✅ SSH access working

2.  **Create a Sudo User**
    
    ⚠️ **Do not use root user** for security reasons.

    ```bash
    # ON YOUR NEW VPS (connect as root):

    # 1. Create a new user (e.g., 'sammy')
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
    # ssh sammy@<vps-ip>
    ```

3.  **Install Tailscale on the VPS**
    
    ```bash
    # ON YOUR VPS (as your sudo user 'sammy'):

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
    ```

--- 

## Installation Steps

**All steps are performed FROM your Control Plane** - the VPS will be configured remotely.

### Choose Your Installation Method

**Method 1: One-Click Installation (Recommended)** ⚡

Fast, non-interactive installation with all parameters in one command:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne

sudo ./scripts/install-vps-edge-node.sh \
  --node-name "vps-edge-01" \
  --tailscale-ip "100.80.255.123" \
  --ssh-user "sammy" \
  --public-ip "45.8.133.192" \
  --domain "curiios.com" \
  --email "vinaysachdeva27@gmail.com"
```

**Replace with your actual values:**
- `--node-name`: Friendly name for your VPS (e.g., "vps-edge-01")
- `--tailscale-ip`: VPS Tailscale IP (from `tailscale ip -4` on VPS)
- `--ssh-user`: Your sudo user on VPS (e.g., "sammy")
- `--public-ip`: VPS public IP address
- `--domain`: Your public domain name
- `--email`: Your email for SSL certificates

**Method 2: Interactive Installation** 💬

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
- ✅ Detect Control Plane cluster configuration
- ✅ Exchange SSH keys with the VPS
- ✅ Verify passwordless sudo on VPS
- ✅ Generate VPS configuration file
- ✅ Transfer MyNodeOne scripts to VPS
- ✅ Execute installation remotely
- ✅ Install Traefik reverse proxy with Docker
- ✅ Configure firewall and monitoring
- ✅ Register VPS in sync controller
- ✅ Push initial service registry

### What Gets Installed on the VPS

The orchestration automatically installs:
- **Traefik**: Modern reverse proxy with automatic HTTPS
- **Docker**: Container runtime for Traefik
- **UFW Firewall**: Allows only ports 22 (SSH), 80 (HTTP), 443 (HTTPS)
- **Node Exporter**: Monitoring agent for Prometheus
- **Fail2ban**: Protection against brute-force attacks

--- 

## ✅ VPS Edge Node Installation Complete!

**What you have now:**
- ✅ Secure public entry point for your cluster
- ✅ Traefik reverse proxy with automatic HTTPS
- ✅ Firewall and monitoring configured
- ✅ Secure Tailscale mesh network to Control Plane
- ✅ Automated sync system for configuration updates

---

## Making Services Public

After installing your VPS, you can expose your applications to the internet.

### Step 1: Configure DNS

Point your domain to your VPS public IP:

```
Type: A
Name: @ (or your domain)
Value: <your-vps-public-ip>
TTL: 300

# For subdomains:
Type: A
Name: demo
Value: <your-vps-public-ip>

Type: A  
Name: chat
Value: <your-vps-public-ip>
```

### Step 2: Make Services Public

Use the `manage-app-visibility.sh` script to expose services:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne

# Make demo app public
sudo ./scripts/manage-app-visibility.sh public demo demo yourdomain.com <vps-tailscale-ip>

# Make LLM chat public
sudo ./scripts/manage-app-visibility.sh public open-webui chat yourdomain.com <vps-tailscale-ip>

# Example with actual values:
sudo ./scripts/manage-app-visibility.sh public demo demo curiios.com 100.80.255.123
sudo ./scripts/manage-app-visibility.sh public open-webui chat curiios.com 100.80.255.123
```

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

**Next Steps:**

### 1. Point Your DNS

In your domain registrar (Namecheap, Cloudflare, etc.), create an **A record** pointing to your VPS public IP:

```
Type: A
Name: @ (or subdomain like 'app')
Value: <VPS_PUBLIC_IP>
TTL: Automatic or 300 seconds
```

**Example:**
```
A    @       →  45.8.133.192
A    www     →  45.8.133.192
A    app     →  45.8.133.192
```

### 2. Configure Traefik Routes

SSH into your VPS and edit the Traefik routes file:

```bash
# SSH into VPS
ssh sammy@<vps-tailscale-ip>

# Edit routes configuration
sudo nano /etc/traefik/dynamic/mynodeone-routes.yml
```

Add your application routes (example):
```yaml
http:
  routers:
    my-app:
      rule: "Host(`app.example.com`)"
      service: my-app-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt

  services:
    my-app-service:
      loadBalancer:
        servers:
          - url: "http://<CONTROL_PLANE_TAILSCALE_IP>:<APP_PORT>"
```

Restart Traefik:
```bash
cd /etc/traefik
docker compose restart
```

### 3. Deploy Apps to Your Cluster

Deploy applications on your Control Plane - they'll be accessible through the VPS:

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne/scripts/apps

# Example: Deploy Nextcloud
sudo ./install-nextcloud.sh
```

### 4. Verify SSL Certificates

Check that Let's Encrypt certificates are being obtained:

```bash
# ON YOUR VPS:
docker logs traefik -f

# Look for messages like:
# "Domains ["app.example.com"] need ACME certificates generation"
```

Visit your domain - you should see a valid SSL certificate!

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
ssh-keygen -t ed25519 -f ~/.ssh/mynodeone_id_ed25519 -N ''
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
cat ~/mynodeone-join-token.txt
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

