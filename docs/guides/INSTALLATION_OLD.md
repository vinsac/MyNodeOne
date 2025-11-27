# MyNodeOne Quick Start - Interactive Setup

Get your private cloud running in 30 minutes with our interactive wizard!

---

## 🌱 Never Used Terminal Before?

**First time with Linux or command line?** → Read **[TERMINAL-BASICS.md](TERMINAL-BASICS.md)** first!

Learn how to:
- Open terminal
- Copy/paste commands
- Understand what each command does
- Fix common mistakes

**Takes 10 minutes, saves hours of confusion!**

---

## What Makes This Easy?

✅ **Interactive Setup Wizard** - Answers all your questions  
✅ **Auto-Detection** - Finds your hardware automatically  
✅ **No Hardcoding** - Works with ANY hardware setup  
✅ **Step-by-Step** - Clear guidance at every step  

## 🎯 Overview: What You'll Do

**MyNodeOne installation has these simple steps:**

1. **Prepare Your Control Plane Machine** ← Start here! (Prerequisites section below)
2. **Download MyNodeOne** (Step 1)
3. **Run the Installation Wizard** (Step 2)
4. **⚠️ MANDATORY: Configure Passwordless Sudo** (Step 3) ← NEW! Do this immediately!
5. **Apply Security Hardening** (Step 4) ← RECOMMENDED, do this right after!
6. **Add More Machines** (Step 5) ← Optional, add workers/VPS later

The core installation (Steps 1-3) gets your control plane running. **Step 4 (passwordless sudo) is MANDATORY before adding VPS or management laptops.** Step 5 (security) is highly recommended before Step 6 (adding more machines).

> ⚠️ **CRITICAL:** If you plan to add VPS edge nodes or management laptops, you **MUST** complete Step 4 (passwordless sudo) first. The installation will fail without it!

---

## Prerequisites: Prepare Your Control Plane Machine

> 🎯 **Start with Your Control Plane (First Node)**
> 
> **What is it?** Your control plane is the "brain" of your cluster - it manages everything.
> 
> **Why start here?** Once your control plane is ready, it can automatically configure any worker nodes you add later via SSH. You only need to manually prepare ONE machine!
> 
> **Which machine?** Your most powerful/reliable machine (recommended: 8GB+ RAM, but 4GB works for learning).

> 💡 **Understanding Command Output:** Not sure if a command worked? Copy the output and ask ChatGPT, Gemini, or Claude: "Did this command succeed?" They can help you understand what you're seeing!

---

### What You Need on Your Control Plane Machine

**Hardware:**
- ✅ At least ONE machine with Ubuntu installed
  - **Recommended:** Ubuntu 24.04 LTS (best tested)
  - **Also works:** Ubuntu 22.04 LTS, Ubuntu 20.04 LTS
  - **New to Ubuntu?** For installation instructions, refer to the [official Ubuntu installation guide](https://ubuntu.com/tutorials/install-ubuntu-desktop) or search "how to install Ubuntu 24.04" on ChatGPT, Gemini, or your preferred AI assistant.
  - Can be named anything (e.g., `node-001`, `server-alpha`, `homelab-01`)
  - Minimum 4GB RAM (8GB+ recommended for control plane)
  - Desktop or Server edition works

**Software to install on this machine:**

### 1. Git - For downloading MyNodeOne
   
   **First, open your terminal:**
   - Press `Ctrl + Alt + T` on Ubuntu Desktop
   - Or see [TERMINAL-BASICS.md](TERMINAL-BASICS.md) for help
   
   **Then run these commands:**
   ```bash
   # Update package list
   sudo apt update
   
   # (Optional) Upgrade system packages - RECOMMENDED for fresh installations
   # WARNING: Skip this on existing/production machines to avoid breaking changes
   # sudo apt upgrade -y
   
   # Install git
   sudo apt install -y git
   ```
   
   **Expected output for successful install:**
   ```
   Reading package lists... Done
   Building dependency tree... Done
   Setting up git (1:2.43.0-1ubuntu7) ...
   ```
   ✅ Look for: `Setting up git` and no error messages
   
   **To verify git installed:**
   ```bash
   git --version
   # Should show: git version 2.43.0 (or similar)
   ```
   
   - For assistance with git installation, consult ChatGPT, Gemini, or search online.

---

### 2. SSH Server - For managing other machines (if you add them later)
   
   **In the same terminal, run:**
   ```bash
   # Install OpenSSH Server:
   sudo apt install -y openssh-server
   
   # Start SSH service (if not already running):
   sudo systemctl start ssh
   
   # Enable SSH to start on boot:
   sudo systemctl enable ssh
   
   # Verify it's running:
   sudo systemctl status ssh
   ```
   
   **Expected output for successful commands:**
   - `sudo apt install -y openssh-server` → Should show `Setting up openssh-server` with no errors
   - `sudo systemctl start ssh` → No output = success! (silence is good here)
   - `sudo systemctl enable ssh` → May show `Synchronizing state...` or nothing = success!
   
   **How to know if it's running:**
   
   ✅ **Good - SSH is running (you'll see):**
   ```
   ● ssh.service - OpenBSD Secure Shell server
        Loaded: loaded (/lib/systemd/system/ssh.service; enabled)
        Active: active (running) since ...
   ```
   Look for: `Active: active (running)` in **green** text
   
   ❌ **Problem - SSH is NOT running (you'll see):**
   ```
   ● ssh.service - OpenBSD Secure Shell server
        Loaded: loaded
        Active: inactive (dead)
   ```
   Look for: `Active: inactive` or any **red** text
   
   **If you see "inactive (dead)":** Go back and run the start/enable commands above
   
   **Press `q` to exit the status screen**
   
   - **Why needed:** When you add worker nodes later, your control plane uses SSH to configure them automatically. Each machine needs SSH server so others can connect to it.
   - **Install on workers too:** When you add more machines, you'll install SSH on them as well (same commands).
   - For SSH troubleshooting, consult ChatGPT, Gemini, or search online.

---

### 3. Tailscale - For secure networking between machines
   
   **In the same terminal, run:**
   ```bash
   # Install curl (if not already installed):
   sudo apt install -y curl
   
   # Install Tailscale:
   curl -fsSL https://tailscale.com/install.sh | sh
   
   # Connect to your Tailscale network:
   sudo tailscale up
   # This will:
   # 1. Open a browser window (or show a URL)
   # 2. Ask you to log in with Google, Microsoft, or GitHub
   # 3. Approve this device on your Tailscale network
   # 4. Assign a 100.x.x.x IP address to this machine
   ```
   
   **Expected outputs:**
   - `sudo apt install -y curl` → Should show `curl is already the newest version` or `Setting up curl`
   - `curl -fsSL https://tailscale.com/install.sh | sh` → Will show installation progress, then `Installation complete!`
   - `sudo tailscale up` → Shows a URL like `https://login.tailscale.com/a/abc123def` - open this in your browser!
   
   **After tailscale up succeeds, you'll see:**
   ```
   Success.
   ```
   ✅ Your machine is now connected to Tailscale!
   - **First time?** Sign up for free at https://tailscale.com before running this
   - **No browser?** Copy the URL shown and open it on another device
   - **Need help with Tailscale?** Ask ChatGPT, Gemini, or see [docs/networking.md](docs/networking.md)
   - **Install on workers too:** When you add more machines, you'll install Tailscale on them as well (same commands).

---

### ✅ Control Plane Machine is Ready!

**You now have:**
- ✅ Ubuntu 24.04 LTS installed
- ✅ Git installed
- ✅ SSH server running
- ✅ Tailscale connected

**What about worker nodes or VPS?**
- 🎯 **Add them later!** The installation wizard will ask if you want to add more machines
- 🎯 **Worker nodes:** Additional machines in your cluster (optional)
- 🎯 **VPS with public IP:** For internet access (optional)
- 🎯 **Management laptop:** Any device with kubectl to deploy apps (optional)

**For now, just focus on your control plane machine!**

> **Need Help?** If you encounter any issues following these steps or understanding the commands, feel free to consult ChatGPT, Gemini, Claude, or other AI assistants for guidance.

---

## 📍 Step 1: Download MyNodeOne (30 seconds)

**On your control plane machine, in your terminal, run:**

```bash
# Clone the repo (choose one method):

# Option 1: HTTPS (easier, no SSH key needed)
git clone https://github.com/vinsac/MyNodeOne.git

# Option 2: SSH (requires SSH key setup)
git clone git@github.com:vinsac/MyNodeOne.git

# Go into the folder:
cd MyNodeOne

# You should now see: yourusername@machine:~/MyNodeOne$
```

**What just happened?**
- ✅ Created a `MyNodeOne` folder in your home directory
- ✅ Downloaded all MyNodeOne code into it
- ✅ Changed into that folder

---

## 🚀 Step 2: Run the Installation Wizard (30 minutes)

**Run this ONE command:**

```bash
sudo ./scripts/mynodeone
```

**What happens next:**
- Asks for your password (it's invisible when you type - normal!)
- Shows welcome screen
- Asks questions about your setup
- Installs everything automatically
- Takes 20-45 minutes

**Just answer the questions and wait!**

**That's it!** The command installs:
- K3s Kubernetes
- Storage (Longhorn + MinIO)
- Monitoring (Prometheus, Grafana, Loki)
- GitOps (ArgoCD)
- SSL automation (Cert-Manager + Traefik)
- Security (firewall, fail2ban)

**After completion:**
- Cluster is ready!
- **IMPORTANT:** Credentials will be displayed in terminal - save them immediately!
- **⚠️ CRITICAL:** The installer will **PAUSE** and wait for you to approve the Tailscale subnet route
  - This step is now interactive - the installer won't continue until you confirm
  - Go to https://login.tailscale.com/admin/machines
  - Find your control plane machine → Edit route settings
  - Enable the subnet route (e.g., `100.118.5.0/24`)
  - Return to the terminal and confirm you've approved it
  - **Why this matters:** Services need this route approved to receive proper IP addresses
  - This enables `.local` domain access from your laptop
- Access services via Tailscale IPs (100.x.x.x addresses shown in output)
- Run `sudo ./scripts/show-credentials.sh` to view all service URLs and credentials

**⚠️ NEXT STEP:** Before adding any VPS or management nodes, proceed to Step 3 (Configure Passwordless Sudo)

---

## 🔐 Step 3: Configure Passwordless Sudo (2 minutes, MANDATORY for VPS/Management)

> **⚠️ CRITICAL: This step is MANDATORY if you plan to add VPS edge nodes or management laptops!**
>
> **Why?** VPS and management nodes need to run commands on the control plane remotely via SSH. Without passwordless sudo, these commands will hang waiting for a password that cannot be provided automatically.
>
> **When to do this:** RIGHT NOW, immediately after control plane installation completes.

**Run this command on your control plane machine:**

```bash
# Either of these commands works:
./scripts/setup-control-plane-sudo.sh
# OR
sudo ./scripts/setup-control-plane-sudo.sh

# The script will prompt for your password when needed
```

> 💡 **Note:** Both commands work identically. The script uses `sudo` internally for privileged operations and will prompt for your password when needed.

**What this does:**
- ✅ Configures passwordless sudo for `kubectl` commands
- ✅ Configures passwordless sudo for MyNodeOne scripts
- ✅ Enables automation from VPS and management nodes
- ✅ Validates configuration with tests
- ✅ Shows clear success/failure messages

**Which nodes need this?**

| Node Type | Needs Passwordless Sudo? | Run This Script? |
|-----------|-------------------------|------------------|
| **Control Plane** | ✅ **YES** | ✅ Run `setup-control-plane-sudo.sh` |
| **VPS Edge Node** | ❌ NO | ❌ Do NOT run this script |
| **Management Laptop** | ❌ NO | ❌ Do NOT run this script |
| **Worker Node** | ❌ NO | ❌ Do NOT run this script |

> 💡 **Remember:** Only the control plane needs passwordless sudo because other nodes connect **TO** it. VPS and management laptops connect to the control plane but nothing connects back to them.

**Expected output:**
```
🔐 MyNodeOne Control Plane - Passwordless Sudo Configuration

[INFO] Configuring passwordless sudo for: yourusername
[✓] Sudoers file installed
[✓] Sudoers syntax verified

[INFO] Testing configuration...

[✓] kubectl passwordless sudo: OK
[✓] Script passwordless sudo: OK
[✓] Remote sudo pattern: OK

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[✓] Passwordless sudo configured successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Verify it worked:**
```bash
# Should run without asking for password:
sudo kubectl version --client
```

**Takes:** ~2 minutes  
**Required:** YES if adding VPS/management nodes, NO if only using control plane  
**Skip if:** You're only running a single control plane and accessing it locally

> 💡 **Security Note:** This allows your user account to run kubectl and MyNodeOne scripts without password prompts. Only do this on trusted machines.

**After this is complete, you can safely add VPS nodes and management laptops!**

---

## 🔒 Step 4: Apply Security Hardening (5 minutes, RECOMMENDED)

> **⚠️ IMPORTANT: Do this AFTER Step 3 (passwordless sudo) and BEFORE adding worker nodes!**
> 
> **Why now?** Security policies apply cluster-wide. Setting them up first ensures all nodes start with proper security from the beginning.

**Run this command on your control plane machine:**

```bash
sudo ./scripts/enable-security-hardening.sh
```

**This enables advanced security features:**
- ✅ Kubernetes audit logging (track all API activity)
- ✅ Secrets encryption at rest (encrypt etcd database)
- ✅ Pod Security Standards (restrict container privileges)
- ✅ Network policies (default deny, explicit allow)
- ✅ Resource quotas (prevent resource exhaustion)
- ✅ Security headers (HSTS, CSP, X-Frame-Options)

**Already Enabled Automatically:**
- ✅ Firewall on all nodes (ufw)
- ✅ fail2ban SSH protection (blocks brute force)
- ✅ Strong 32-char random passwords
- ✅ Encrypted network (Tailscale WireGuard)

**Takes:** ~3-5 minutes  
**Required:** No, but HIGHLY recommended for production use  
**Skip if:** Learning/testing only

> 💡 **Important:** Security hardening is now **prompted during installation**!  
> The installation wizard will ask if you want to enable it. You can also run it manually anytime.

**After hardening is complete, you can now safely add worker nodes!**

---

## Step 5: Add More Machines (Optional)

**Before adding more machines:**
- Complete Step 3 (Passwordless Sudo) - MANDATORY for VPS/management nodes
- Complete Step 4 (Security Hardening) - RECOMMENDED for all deployments
- This ensures security policies apply to all nodes from the start

> **For VPS installations, see the comprehensive prerequisite guide:**  
> **[docs/INSTALLATION_PREREQUISITES.md](../INSTALLATION_PREREQUISITES.md)**

### Want to Add Worker Nodes?

On each additional machine:

```bash
# 1. Install prerequisites (git, SSH, Tailscale) - see Prerequisites section above
# 2. Download MyNodeOne
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
# 3. Run installer
sudo ./scripts/mynodeone
# 4. Select "Worker Node" when asked
# 5. Provide the join token from your control plane (saved in /root/mynodeone-join-token.txt)
```

**After each worker joins:**
- The control plane automatically applies security policies to it
- Network policies, pod security standards, and resource quotas are enforced
- No additional security configuration needed on workers!

### Want Public Internet Access?

**Add VPS Edge Nodes:**

> **MANDATORY PREREQUISITES:** Before installing MyNodeOne on a VPS, you MUST complete these steps:
>
> 1. Control plane installed and running
> 2. Passwordless sudo configured on **control plane** (Step 3 above)
> 3. SSH access from VPS to control plane (ssh-copy-id)
> 4. Tailscale connected on VPS
> 5. Docker installed on VPS
>
> **Complete prerequisite guide:** [docs/INSTALLATION_PREREQUISITES.md](../INSTALLATION_PREREQUISITES.md)

> 💡 **Important:** You do **NOT** need to run `setup-control-plane-sudo.sh` on the VPS! That script is **only** for the control plane. The VPS connects **to** the control plane via SSH, not vice versa.

#### ⚠️ CRITICAL STEP: Exchange SSH Keys (VPS → Control Plane)

**This is the #1 most commonly skipped step!**

Before running ANY pre-flight checks or installation, you MUST exchange SSH keys:

```bash
# On VPS, generate SSH key (if you don't have one):
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy SSH key to control plane:
ssh-copy-id <your-username>@<control-plane-tailscale-ip>

# Example:
ssh-copy-id vinaysachdeva@100.116.16.117

# Test SSH connection (should NOT ask for password):
ssh vinaysachdeva@100.116.16.117 'echo OK'
# Expected output: OK

# CRITICAL TEST: Verify passwordless sudo works remotely:
ssh vinaysachdeva@100.116.16.117 'sudo kubectl version --client'
# Should show version WITHOUT asking for password!
```

**If the last command asks for password:**
- Passwordless sudo is NOT configured on control plane
- Go back to control plane and run: `./scripts/setup-control-plane-sudo.sh`

---

#### Check Prerequisites Before Installation

**From your VPS, verify all prerequisites are met:**

```bash
# Download MyNodeOne first
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Run pre-flight checks (MANDATORY)
./scripts/check-prerequisites.sh vps <control-plane-ip> <ssh-user>

# Example:
./scripts/check-prerequisites.sh vps 100.116.16.117 vinaysachdeva
```

**Expected output if ready:**
```
 Pre-flight Checks: vps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[ ] SSH connection: OK
[ ] Passwordless sudo: OK
[ ] Kubernetes cluster: RUNNING
[ ] Tailscale connected: 100.65.241.25
[ ] Docker: INSTALLED
[ ] Ports 80, 443: AVAILABLE
[ ] No IP conflicts detected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[ ] All pre-flight checks passed!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 Ready to proceed with vps installation!
```

**If ANY check fails:** Fix the issue before proceeding. The installation will fail without proper prerequisites.

#### Security Best Practice: Create Sudo User (RECOMMENDED)

Before installing MyNodeOne on your VPS, create a dedicated sudo user instead of using root:

```bash
# 1. SSH to your VPS as root (or existing user)
ssh root@your-vps-ip

# 2. Create a new user (choose any username, e.g., mynodeone, yourname_vps, etc.)
sudo adduser mynodeone

# 3. Add user to sudo group
sudo usermod -aG sudo mynodeone

# 4. Switch to the new user
su - mynodeone

# 5. Verify sudo access
sudo whoami
# Should output: root
```

**Why this matters:**
- **Security:** Running as root exposes your VPS to greater risk
- **Best Practice:** Industry standard for production servers
- **Safety:** Limits damage from accidental commands
- **Audit Trail:** Easier to track actions with named users

**What the installer does:**
- If running as root, it will **warn you** and give you a chance to create a sudo user
- You can continue as root if needed (for testing), but it's not recommended for production

---

#### Installing MyNodeOne on VPS

On each VPS (as your sudo user):

```bash
# 1. Pre-flight checks MUST pass (see above)
./scripts/check-prerequisites.sh vps <control-plane-ip> <ssh-user>

# 2. Only proceed if all checks pass
sudo ./scripts/mynodeone
# Select option 3 (VPS Edge Node) when prompted
```

**What happens during installation:**
- Pre-flight checks run automatically
- SSH keys exchanged for bidirectional access
- VPS registered in cluster
- IP validated to prevent conflicts
- Traefik installed with certificate management
- Routes synced from control plane

**After installation:**
```bash
# Check certificate status
~/MyNodeOne/scripts/check-certificates.sh [domain]

# Validate DNS before adding domains
~/MyNodeOne/scripts/check-dns-ready.sh yourdomain.com <vps-ip>

# Monitor Traefik logs
sudo docker logs traefik -f
```

### Configure VPS Edge Nodes

**1. Validate DNS before requesting SSL certificates:**

```bash
# Point your DNS to your VPS:
# Type  Name  Value           TTL
# A     @     <your-vps-ip>   3600
# A     *     <your-vps-ip>   3600

# Then verify DNS propagation:
~/MyNodeOne/scripts/check-dns-ready.sh yourdomain.com <your-vps-ip>
```

**2. Check SSL certificate status:**

```bash
# Monitor certificate issuance
~/MyNodeOne/scripts/check-certificates.sh yourdomain.com

# View Traefik logs for certificate events
sudo docker logs traefik | grep -i certificate
```

**Certificate Management:**
- Staging mode (test certificates): Unlimited requests, use for testing
- Production mode (real certificates): Rate limited (5 failures/hour, 50 certs/week)
- Switch modes by editing `/etc/traefik/traefik.yml` on VPS

## Step 6: Setup Management Workstation (5 minutes, optional)

> **PREREQUISITE:** Passwordless sudo must be configured on control plane (Step 3 above)

> 💡 **Important:** You do **NOT** need to run `setup-control-plane-sudo.sh` on your management laptop! That script is **only** for the control plane. The laptop connects **to** the control plane, not vice versa.

On your **laptop/desktop** for deploying apps:

```bash
# 1. Download MyNodeOne
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# 2. (Optional) Check prerequisites
./scripts/check-prerequisites.sh management <control-plane-ip> <ssh-user>

# 3. Run installation
sudo ./scripts/mynodeone
# Select option 4 (Management Workstation) when prompted
```

**What this does automatically:**
- Configures Tailscale to accept subnet routes (enables LoadBalancer access)
- Installs kubectl
- Sets up SSH keys (optional)
- Copies kubeconfig from control plane via SSH
- Configures .local domain names
- Tests the connection
- ✅ Configures Tailscale to accept subnet routes (enables LoadBalancer access)
- ✅ Installs kubectl
- ✅ Sets up SSH keys (optional)
- ✅ Copies kubeconfig from control plane via SSH
- ✅ Configures .local domain names
- ✅ Tests the connection

**What "accept subnet routes" means:**
- **Simple:** Your laptop needs permission to reach cluster LoadBalancer IPs
- **Technical:** Configures Tailscale to accept advertised routes from control plane
- **Result:** You can access services at http://grafana.mynodeone.local etc.

**Prerequisites for management laptop:**
- Tailscale installed and connected
- SSH access to control plane (you'll be prompted for the IP)

**Power users:** You can also run `./scripts/setup-laptop.sh` directly for more control.

## Step 6: Access Your Services

### Via Tailscale (Internal)

**After approving the Tailscale subnet route**, you can access services using easy-to-remember domain names:

```bash
# Access services via .local domains (if subnet route approved):
http://grafana.mynodeone.local       # Monitoring dashboard
https://argocd.mynodeone.local       # GitOps platform
http://minio.mynodeone.local:9001    # Object storage console
http://open-webui.mynodeone.local    # LLM chat interface
```

**Or use direct LoadBalancer IPs:**

```bash
# Get LoadBalancer IPs
kubectl get svc -A | grep LoadBalancer

# Access in browser (from any machine on Tailscale)
# Grafana:  http://<grafana-ip>
# ArgoCD:   https://<argocd-ip>
# MinIO:    http://<minio-ip>
```

**Note:** The `.local` domains only work after:
1. ✅ Control plane installation completed
2. ✅ Tailscale subnet route approved in admin console
3. ✅ Management laptop DNS configured (automatic during setup)

### Via Public Internet (if you configured VPS)

Just visit your domain: `https://yourdomain.com`

SSL certificates are issued automatically!

---

## Step 7: Deploy Your First App

### Option A: Deploy Example LLM (CPU)

```bash
kubectl apply -f manifests/examples/llm-cpu-inference.yaml

# Wait for model download (one-time, ~5-10 min)
kubectl logs -f job/download-llama-model -n ai-workloads

# Check status
kubectl get pods -n ai-workloads

# Access the LLM API
curl http://<service-ip>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Option B: Deploy Full-Stack App

```bash
kubectl apply -f manifests/examples/fullstack-app.yaml
kubectl get pods -n myapp
```

### Option C: Create Your Own App

```bash
./scripts/create-app.sh myapp --domain myapp.com --port 3000
cd myapp
# Customize your code
git push
# ArgoCD auto-deploys!
```


## Common Scenarios

### Scenario 1: Single Machine at Home

**What you have:** 1 powerful machine  
**What to run:**
1. Interactive setup → Control Plane
2. Bootstrap script
3. Deploy apps
4. Access via Tailscale from laptop

**No VPS needed!** Perfect for:
- Development
- Learning Kubernetes
- Running LLMs locally
- Private services

### Scenario 2: Home Server + Laptop

**What you have:** 1 server + 1 laptop  
**What to run:**

Server:
1. Interactive setup → Control Plane
2. Bootstrap script

Laptop:
1. Interactive setup → Management Workstation
2. Install kubectl
3. Deploy apps from laptop

**Access:** Via Tailscale, no public internet exposure

### Scenario 3: Home Server + VPS

**What you have:** 1 home server + 1 VPS  
**What to run:**

Home Server:
1. Interactive setup → Control Plane
2. Bootstrap script

VPS:
1. Interactive setup → VPS Edge Node
2. Edge node script

**Access:** Public via VPS, backend on home server

### Scenario 4: Multiple Servers + VPS

**What you have:** 3 home servers + 2 VPS  
**What to run:**

Server 1:
1. Interactive setup → Control Plane
2. Bootstrap script

Servers 2-3:
1. Interactive setup → Worker Node
2. Worker script

VPS 1-2:
1. Interactive setup → VPS Edge Node
2. Edge node script

**Access:** High availability, load balanced

## Troubleshooting

> 📖 **Comprehensive troubleshooting guide:** [docs/INSTALLATION_PREREQUISITES.md](../INSTALLATION_PREREQUISITES.md#troubleshooting)

### Installation fails with "Passwordless sudo: NOT CONFIGURED"

**This is the #1 cause of VPS installation failures!**

```bash
# Fix: Run on control plane
ssh user@control-plane-ip
cd ~/MyNodeOne
sudo ./scripts/setup-control-plane-sudo.sh

# Verify it works:
sudo kubectl version --client
# Should run without asking for password
```

### Installation fails with "SSH connection: FAILED"

```bash
# Fix: Set up SSH key from VPS to control plane
ssh-copy-id user@control-plane-ip

# Test it works:
ssh user@control-plane-ip 'echo OK'
# Should print OK without asking for password
```

### Installation fails with "IP MISMATCH DETECTED"

```bash
# This means a stale VPS registration exists
# Fix: Unregister the old IP
cd ~/MyNodeOne
./scripts/unregister-vps.sh <old-tailscale-ip>

# Then re-run VPS installation
sudo ./scripts/mynodeone
```

### Certificate not obtained / showing default cert

```bash
# 1. Check DNS is properly configured
~/MyNodeOne/scripts/check-dns-ready.sh yourdomain.com <vps-ip>

# 2. Check certificate status
~/MyNodeOne/scripts/check-certificates.sh yourdomain.com

# 3. Check Traefik logs
sudo docker logs traefik | grep -i certificate

# Common causes:
# - DNS not propagated yet (wait 5-15 minutes)
# - Port 80 blocked by firewall
# - Rate limit hit (use staging mode for testing)
```

### Can't connect to Tailscale

```bash
sudo tailscale up
# Opens browser for authentication
```

### Configuration not found

```bash
# Re-run the setup wizard
sudo ./scripts/mynodeone
```

### Can't reach control plane

```bash
# Check Tailscale connection
tailscale status

# Verify control plane IP
ping <control-plane-ip>

# Check if K3s is running
ssh <control-plane-ip> "sudo systemctl status k3s"
```

### Worker not joining

1. Verify join token is correct
2. Check Tailscale connectivity
3. Ensure control plane port 6443 is reachable

### VPS can't reach home

1. Verify Tailscale on both ends
2. Check firewall rules
3. Test with: `ping <home-server-tailscale-ip>`

## What's Different from Cloud Providers?

| Feature | MyNodeOne | AWS |
|---------|----------|-----|
| **Setup** | Interactive wizard | Complex console |
| **Cost** | $0-50/month | $500+/month |
| **Configuration** | Automatic | Manual everything |
| **Scaling** | Run one script | Complex auto-scaling groups |
| **SSL** | Automatic | Certificate Manager setup |
| **Monitoring** | Pre-configured | Must configure CloudWatch |
| **Storage** | Included | Pay per GB |

## Next Steps

1. ✅ **Customize your setup** - Edit configs in `~/.mynodeone/`
2. ✅ **Deploy more apps** - Use `create-app.sh` or examples
3. ✅ **Add monitoring alerts** - Configure in Grafana
4. ✅ **Set up backups** - Deploy backup CronJob
5. ✅ **Scale up** - Add more nodes as you grow

## Need help?

- **Prerequisites guide:** [INSTALLATION_PREREQUISITES.md](../INSTALLATION_PREREQUISITES.md) ⭐ **must read for VPS**
- **Reliability improvements:** [RELIABILITY_IMPROVEMENTS.md](../RELIABILITY_IMPROVEMENTS.md)
- **Production readiness summary:** [PRODUCTION_READY_SUMMARY.md](../PRODUCTION_READY_SUMMARY.md)
- **Documentation:** see the `docs/` folder
- **FAQ:** see `docs/reference/FAQ.md`
- **Issues:** open on GitHub
- **Configuration:** stored in `~/.mynodeone/config.env`

## Useful Commands

**Pre-installation:**
```bash
# Check VPS prerequisites
./scripts/check-prerequisites.sh vps <control-plane-ip> <user>

# Check management laptop prerequisites
./scripts/check-prerequisites.sh management <control-plane-ip> <user>
```

**Post-installation:**
```bash
# Configure passwordless sudo (control plane)
sudo ./scripts/setup-control-plane-sudo.sh

# Check DNS readiness
./scripts/check-dns-ready.sh yourdomain.com <ip>

# Check SSL certificates
./scripts/check-certificates.sh [domain]

# Unregister stale VPS
./scripts/unregister-vps.sh <old-tailscale-ip>

# Show cluster credentials
sudo ./scripts/show-credentials.sh
```

---

**Ready?** Start with `sudo ./scripts/mynodeone` on your first machine! 🚀
