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

**Add a VPS with a public IP to make your apps accessible from the internet.**

---

## What is a VPS Edge Node?

- **Public Gateway**: A cheap cloud server that acts as a secure entry point to your cluster.
- **Reverse Proxy**: It routes public internet traffic back to your home control plane through a secure tunnel.
- **Auto-HTTPS**: Automatically gets and renews SSL/TLS certificates for your domains.
- **Providers**: Works with any cloud provider (Contabo, Hetzner, DigitalOcean, Linode, etc.).

---

## Prerequisites

### On Your Control Plane:

- ✅ **Section 1 Complete**: You must have a fully installed and running Control Plane.
- ✅ **Tailscale IP Ready**: You need the Tailscale IP of your Control Plane.
  ```bash
  # On Control Plane, run this to get the IP:
  tailscale ip -4
  ```

### On Your VPS:

1.  **Provision a Fresh VPS**
    - ✅ Ubuntu 24.04 LTS (or 22.04/20.04).
    - ✅ At least 1GB RAM, 1 CPU core.
    - ✅ A **public IPv4 address** is required.

2.  **Create a Sudo User (Important Security Step)**
    - For security, **do not use the `root` user** for the MyNodeOne setup. Connect to your new VPS as `root` one time to create a new, dedicated user.
    - This new user will be used in the `setup-edge-node.sh` command.

    ```bash
    # ON YOUR NEW VPS (connect as root):

    # 1. Create the new user (e.g., 'sammy')
    adduser sammy

    # 2. Add the user to the 'sudo' group to grant admin privileges
    usermod -aG sudo sammy

    # 3. Log out from root and log back in as your new user to continue
    exit
    ```
    - From now on, all commands on the VPS should be run as this new user (`sammy` in this example).

3.  **Install Tailscale on the VPS**
    ```bash
    # SSH into your new VPS (as your new sudo user, e.g., 'sammy')

    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    # Start Tailscale and authenticate
    sudo tailscale up
    ```
    - Follow the URL it provides to authenticate in your browser.
    - Verify it's connected: `tailscale status`

--- 

## Installation Steps (The Easy Way)

This entire process is automated by a single script that you run **from your Control Plane**.

### Step 1: Run the `setup-edge-node.sh` Script

Log into your **Control Plane** machine. Navigate to the `MyNodeOne` directory and run the following command, replacing the user and IP with your VPS details.

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne
sudo ./scripts/setup-edge-node.sh <vps_username>@<vps_public_ip>
```

**Example:**
```bash
sudo ./scripts/setup-edge-node.sh sammy@45.8.133.192
```

### Step 2: Follow the Prompts

The script will guide you through the setup:

1.  **Enter Your Domains**: When prompted, enter the public domain(s) you want to point to your cluster (e.g., `app.my-domain.com`). Caddy will handle SSL for them.
2.  **Password Prompt**: You will be asked for the VPS user's password once to allow the script to copy its SSH key.

### What the Script Does Automatically

- **Copies SSH Key**: Securely copies the control plane's public key to the VPS, enabling passwordless access for management.
- **Installs Software**: Installs `caddy` (for reverse proxying) and other tools on the VPS.
- **Hardens Security**: Configures the VPS firewall and SSH for better security.
- **Establishes Reverse Tunnel**: Starts a persistent, self-healing reverse SSH tunnel from the control plane to the VPS.
- **Registers the Node**: Adds the VPS to the cluster's registry so it receives automatic updates.

> **Important Security Note:** This process is designed to be run from the Control Plane for a critical security reason. The Control Plane initiates the connection outwards to the VPS. This ensures your Control Plane is never exposed to the public internet, dramatically reducing the system's attack surface. For a more detailed explanation, please read our [Architecture Overview](./../reference/ARCHITECTURE-OVERVIEW.md).

### Alternative Installation Methods

#### Using the Interactive Wizard

If you prefer a guided setup, you can use the main `mynodeone` interactive script instead of the direct `setup-edge-node.sh` script. Both achieve the same result.

```bash
# ON YOUR CONTROL PLANE:
cd ~/MyNodeOne
sudo ./scripts/mynodeone
```
- When prompted, select **Option 3: VPS Edge Node** and follow the questions.

#### From a Management Laptop (Advanced)

If you have already set up a Management Laptop (Section 3), you can trigger the VPS installation remotely without needing to SSH into the Control Plane first.

```bash
# Run this command FROM YOUR MANAGEMENT LAPTOP
ssh <your-user>@<control-plane-ip> 'cd ~/MyNodeOne && sudo ./scripts/setup-edge-node.sh <vps_user>@<vps_public_ip>'
```
- This command logs into your Control Plane and executes the setup script from there, providing a convenient way to manage your entire cluster from one place.

--- 

## ✅ VPS Edge Node Installation Complete!

**What you have now:**
- ✅ A secure public entry point for your cluster.
- ✅ An active reverse tunnel routing traffic back to your control plane.
- ✅ Automatic SSL for your domains.

**Next Steps:**
- **Point Your DNS**: In your domain registrar, create an **A record** for your domain pointing to your VPS's public IP address.
- **Deploy an App**: Use the app store scripts in `scripts/apps/` to deploy an application and make it public.

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

