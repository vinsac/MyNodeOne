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

**MyNodeOne installation has 3 simple steps:**

1. **Prepare Your Control Plane Machine** ← Start here! (this section)
2. **Download MyNodeOne** (Step 1 below)
3. **Run the Installation Wizard** (Step 2 below)

The wizard will ask if you want to add more machines (workers/VPS) - you can add them later!

---

## Prerequisites: Prepare Your Control Plane Machine

> 🎯 **Start with Your Control Plane (Master Node)**
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
- ✅ At least ONE machine with Ubuntu 24.04 LTS installed
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
- Credentials saved to `/root/mynodeone-*.txt`
- Access monitoring at `https://grafana.mynodeone.local`

---

## 🔗 Step 4: Add More Machines (Optional)

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

### Want Public Internet Access?

**Add VPS Edge Nodes:**

On each VPS:

```bash
# Same process as above, but select "VPS Edge Node"
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/mynodeone
```

### Configure VPS Edge Nodes

**Then point your DNS to your VPS:**
```
Type  Name  Value           TTL
A     @     <your-vps-ip>   3600
A     www   <your-vps-ip>   3600
```

## Step 5: Setup Management Workstation (5 minutes, optional)

On your **laptop/desktop** for deploying apps:

```bash
./scripts/interactive-setup.sh  # Select option 4 (Management Workstation)
```

**Then install kubectl:**
```bash
# Download kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Copy kubeconfig from control plane
scp user@<control-plane-tailscale-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Edit and replace 127.0.0.1 with control plane IP
sed -i 's/127.0.0.1/<control-plane-tailscale-ip>/g' ~/.kube/config

# Test connection
kubectl get nodes
```

## Step 6: Deploy Your First App

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

## 🔒 Security Hardening (Recommended)

After installation, enable additional security features:

```bash
sudo ./scripts/enable-security-hardening.sh
```

This adds:
- ✅ Kubernetes audit logging
- ✅ Secrets encryption at rest
- ✅ Pod Security Standards (restricted)
- ✅ Network policies (default deny)
- ✅ Resource quotas
- ✅ Security headers (HSTS, CSP)

**Already Enabled (Automatic):**
- ✅ Firewall on all nodes
- ✅ fail2ban SSH protection
- ✅ Strong 32-char random passwords
- ✅ Encrypted network (Tailscale)

**Important: Password Management**

1. Save all credentials to a password manager (Bitwarden/1Password)
2. **DO NOT** self-host password manager on MyNodeOne
3. Delete credential files after saving: `sudo rm /root/mynodeone-*.txt`

See `docs/password-management.md` for detailed guide.

---

## Access Your Services

### Via Tailscale (Internal)

From your management workstation:

```bash
# Get service IPs
kubectl get svc -A | grep LoadBalancer

# Access in browser
# Grafana:  http://<grafana-ip>
# ArgoCD:   https://<argocd-ip>
# MinIO:    http://<minio-ip>
```

### Via Public Internet (if you configured VPS)

Just visit your domain: `https://yourdomain.com`

SSL certificates are issued automatically!

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

### Can't connect to Tailscale

```bash
sudo tailscale up
# Opens browser for authentication
```

### Configuration not found

```bash
# Re-run the interactive wizard
./scripts/interactive-setup.sh
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

## Need Help?

- **Documentation:** See `docs/` folder
- **FAQ:** Check `FAQ.md`
- **Issues:** Open on GitHub
- **Configuration:** Stored in `~/.mynodeone/config.env`

---

**Ready?** Start with `./scripts/interactive-setup.sh` on your first machine! 🚀
