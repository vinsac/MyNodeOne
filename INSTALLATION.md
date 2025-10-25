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

## Prerequisites

Before starting, you need:

1. **At least one machine** with Ubuntu 24.04 LTS
   - **New to Ubuntu?** For installation instructions, refer to the [official Ubuntu installation guide](https://ubuntu.com/tutorials/install-ubuntu-desktop) or search "how to install Ubuntu 24.04" on ChatGPT, Gemini, or your preferred AI assistant.
   - Can be named anything (e.g., `node-001`, `server-alpha`, `homelab-01`, etc.)
   - Any amount of RAM/CPU (minimum 4GB RAM recommended)
   - Desktop or Server edition works

2. **Git installed** on your machine
   ```bash
   # Update package list
   sudo apt update
   
   # (Optional) Upgrade system packages - RECOMMENDED for fresh installations
   # WARNING: Skip this on existing/production machines to avoid breaking changes
   # sudo apt upgrade -y
   
   # Install git
   sudo apt install -y git
   ```
   - For assistance with git installation, consult ChatGPT, Gemini, or search online.

3. **SSH Server installed** (required for worker nodes and remote management)
   ```bash
   # Install OpenSSH Server:
   sudo apt install -y openssh-server
   
   # Verify it's running:
   sudo systemctl status ssh
   ```
   - **Why needed:** Control plane uses SSH to configure worker nodes
   - For SSH troubleshooting, consult ChatGPT, Gemini, or search online.

4. **Tailscale installed** on your machine
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
   - **First time?** Sign up for free at https://tailscale.com before running this
   - **No browser?** Copy the URL shown and open it on another device
   - **Need help with Tailscale?** Ask ChatGPT, Gemini, or see [docs/networking.md](docs/networking.md)

5. **Optional: VPS server(s)** with public IP
   - Any provider (Contabo, DigitalOcean, Hetzner, etc.)
   - Any number (0, 1, 2, or more)
   - Only needed if you want public internet access

6. **Optional: Management laptop/desktop**
   - Your daily driver for deploying apps
   - Any OS with kubectl installed

> **Need Help?** If you encounter any issues following these steps or understanding the commands, feel free to consult ChatGPT, Gemini, Claude, or other AI assistants for guidance.

## 📍 Step 1: Prepare Your Machine (5 minutes)

### Which Machine?
**Run these commands on your control plane machine** (the most powerful one you have).

### Where to Run Commands?
**Open terminal on your Ubuntu machine:**
- Press `Ctrl + Alt + T` (or see [TERMINAL-BASICS.md](TERMINAL-BASICS.md))

### What Directory?
**Your home directory is fine!** When you open terminal, you're usually at `/home/yourusername/` - perfect!

---

## 🔽 Step 2: Download MyNodeOne (30 seconds)

**Run these commands in your terminal:**

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
- Created a `MyNodeOne` folder in your home directory
- Downloaded all MyNodeOne code into it
- Changed into that folder

---

## 🚀 Step 3: Run Installation Wizard (30 minutes)

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
