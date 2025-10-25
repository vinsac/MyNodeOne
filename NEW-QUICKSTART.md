# NodeZero Quick Start - Interactive Setup

Get your private cloud running in 30 minutes with our interactive wizard!

## What Makes This Easy?

✅ **Interactive Setup Wizard** - Answers all your questions  
✅ **Auto-Detection** - Finds your hardware automatically  
✅ **No Hardcoding** - Works with ANY hardware setup  
✅ **Step-by-Step** - Clear guidance at every step  

## Prerequisites

Before starting, you need:

1. **At least one machine** with Ubuntu 24.04 LTS
   - Can be named anything (toronto-0001, server-1, myserver, etc.)
   - Any amount of RAM/CPU (minimum 4GB RAM recommended)
   - Desktop or Server edition works

2. **Tailscale account** (free)
   - Sign up at https://tailscale.com
   - No configuration needed - scripts handle it

3. **Optional: VPS server(s)** with public IP
   - Any provider (Contabo, DigitalOcean, Hetzner, etc.)
   - Any number (0, 1, 2, or more)
   - Only needed if you want public internet access

4. **Optional: Management laptop/desktop**
   - Your daily driver for deploying apps
   - Any OS with kubectl installed

## Step 1: Interactive Setup (5 minutes per machine)

Run this wizard **on each machine** (control plane, workers, VPS, laptop):

```bash
# Clone the repo
git clone https://github.com/yourusername/nodezero.git
cd nodezero

# Run the interactive wizard
./scripts/interactive-setup.sh
```

### What the Wizard Does

The wizard will:

1. **Detect your environment**
   - OS version
   - Hostname
   - RAM/CPU
   - Public IP (if applicable)
   - GPU (if present)

2. **Install Tailscale** (if needed)
   - Downloads and installs
   - Opens browser for auth
   - Connects to your network

3. **Ask a few questions**
   - What type of node is this?
   - What should we call it?
   - Where is it located?
   - Storage preferences
   - Workload types

4. **Save configuration**
   - Stores in `~/.nodezero/config.env`
   - All scripts automatically use it
   - No manual editing needed!

### Example Session

```
    _   __          __     ______                
   / | / /___  ____/ /__  /__  (_)___  _________
  /  |/ / __ \/ __  / _ \   / / / _ \/ ___/ __ \
 / /|  / /_/ / /_/ /  __/  / /_/  __/ /  / /_/ /
/_/ |_/\____/\__,_/\___/  /___/\___/_/   \____/ 

Welcome to NodeZero Interactive Setup!

? Ready to start? [Y/n] y

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Environment Detection
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ Operating System: ubuntu 24.04
ℹ Hostname: myserver
ℹ Resources: 256GB RAM, 32 CPU cores
✓ Tailscale connected: 100.103.104.109

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Node Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

What type of node is this?

1) Control Plane (First node, runs Kubernetes master)
2) Worker Node (Additional compute node)
3) VPS Edge Node (Public-facing reverse proxy)
4) Management Workstation (Your laptop/desktop for admin)

? Select node type (1-4): 1
✓ Node type: Control Plane

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Cluster Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

? Give your cluster a name [nodezero]: 
? What should we call this node? [myserver]: 
? Where is this node located? (e.g., toronto, newyork, home) [home]: 

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Saving Configuration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✓ Configuration saved to: /home/user/.nodezero/config.env

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Next Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your control plane is configured! Next:

1. Run the bootstrap script:
   sudo ./scripts/bootstrap-control-plane.sh

2. After bootstrap completes, save the join token displayed

3. Configure your VPS edge nodes (if any)

4. Add worker nodes as needed

✓ Setup complete! 🎉
```

## Step 2: Bootstrap Control Plane (20 minutes)

On your **first machine** (the one you configured as "Control Plane"):

```bash
sudo ./scripts/bootstrap-control-plane.sh
```

**What happens:**
- Installs K3s Kubernetes
- Sets up storage (Longhorn + MinIO)
- Deploys monitoring (Prometheus + Grafana + Loki)
- Installs ArgoCD for GitOps
- Configures SSL automation

**Important:** Save these after completion:
- `/root/nodezero-join-token.txt` - For adding workers
- `/root/nodezero-argocd-credentials.txt` - For ArgoCD UI
- `/root/nodezero-minio-credentials.txt` - For S3 storage

## Step 3: Add Worker Nodes (10 minutes each, optional)

For **each additional compute node**:

```bash
# On the new worker machine
./scripts/interactive-setup.sh  # Select option 2 (Worker Node)
sudo ./scripts/add-worker-node.sh
```

The script will ask for the join token from Step 2.

## Step 4: Configure VPS Edge Nodes (10 minutes each, optional)

Only if you want public internet access to your apps:

```bash
# On each VPS
./scripts/interactive-setup.sh  # Select option 3 (VPS Edge Node)
sudo ./scripts/setup-edge-node.sh
```

**Then point your DNS:**
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

| Feature | NodeZero | AWS |
|---------|----------|-----|
| **Setup** | Interactive wizard | Complex console |
| **Cost** | $0-50/month | $500+/month |
| **Configuration** | Automatic | Manual everything |
| **Scaling** | Run one script | Complex auto-scaling groups |
| **SSL** | Automatic | Certificate Manager setup |
| **Monitoring** | Pre-configured | Must configure CloudWatch |
| **Storage** | Included | Pay per GB |

## Next Steps

1. ✅ **Customize your setup** - Edit configs in `~/.nodezero/`
2. ✅ **Deploy more apps** - Use `create-app.sh` or examples
3. ✅ **Add monitoring alerts** - Configure in Grafana
4. ✅ **Set up backups** - Deploy backup CronJob
5. ✅ **Scale up** - Add more nodes as you grow

## Need Help?

- **Documentation:** See `docs/` folder
- **FAQ:** Check `FAQ.md`
- **Issues:** Open on GitHub
- **Configuration:** Stored in `~/.nodezero/config.env`

---

**Ready?** Start with `./scripts/interactive-setup.sh` on your first machine! 🚀
