# What To Do After Installation

**Congratulations!** 🎉 Your MyNodeOne cluster is installed. This guide shows you exactly what to do next.

---

## 📍 Where Are You Now?

You just ran the installation on your **control plane machine**. This machine is now the "brain" of your cluster.

**Your control plane machine:**
- ✅ Has Kubernetes running
- ✅ Has all services installed (Grafana, ArgoCD, MinIO, Longhorn)
- ✅ Is connected to Tailscale VPN
- ✅ Can be accessed from any device on your Tailscale network

---

## 🎯 Quick Reference: What Can You Do?

| What You Want | Where To Do It | How |
|--------------|----------------|-----|
| **Deploy apps** | Control plane OR laptop | [See below](#deploying-applications) |
| **Monitor cluster** | Any device (via browser) | [Access Grafana](#monitoring-your-cluster) |
| **View logs** | Any device (via browser) | [Access Grafana](#viewing-logs) |
| **Manage storage** | Any device (via browser) | [Access Longhorn](#managing-storage) |
| **GitOps deployments** | Laptop (push to Git) | [Use ArgoCD](#gitops-with-argocd) |
| **Access from laptop** | Laptop | [Setup kubectl](#accessing-from-your-laptop) |

---

## 🖥️ Accessing Your Cluster

### Option 1: From Control Plane (Direct)

You're already on the control plane! You can run kubectl commands directly:

```bash
# Check cluster status
kubectl get nodes

# See all pods
kubectl get pods -A

# View services
kubectl get svc -A
```

### Option 2: From Your Laptop (Recommended for Daily Use)

**Why use your laptop?**
- Use modern tools like VS Code, Cursor, Windsurf
- AI-assisted coding and deployment
- Don't need to keep control plane machine nearby
- More comfortable for development
- **No need to manually copy files!** - Automated setup script

#### Easy Way: Automated Setup (Recommended)

**Option A: Using interactive setup** (if you have MyNodeOne repo on laptop):

```bash
cd MyNodeOne
sudo ./scripts/mynodeone

# Choose option 4: "Management Workstation"
# This automatically runs setup-laptop.sh
```

**Option B: Direct script** (quick method):

```bash
# If you have the MyNodeOne repo on your laptop
cd MyNodeOne
sudo bash scripts/setup-laptop.sh
```

**Option C: Download directly** (no repo needed):

```bash
# Download setup script
wget https://raw.githubusercontent.com/vinsac/MyNodeOne/main/scripts/setup-laptop.sh

# Run it
sudo bash setup-laptop.sh
```

**All three options do the same thing** - they run the automated laptop setup script.

**2. Follow the prompts:**
- Enter control plane Tailscale IP (e.g., 100.118.5.201)
- Enter SSH username (default: your current username)
- Optionally set up SSH key for passwordless access
- Script will:
  - ✅ Install kubectl
  - ✅ Fetch kubeconfig automatically via SSH
  - ✅ Test cluster connection
  - ✅ Optionally set up .local domain names
  - ✅ Optionally install k9s and helm

**3. Done!** Start using kubectl from your laptop.

**What the script does:**
- ✅ Checks and configures Tailscale to accept subnet routes (automatic!)
- ✅ Connects to control plane via SSH over Tailscale
- ✅ Installs kubectl if not present
- ✅ Fetches kubeconfig from control plane
- ✅ Configures .local domain names in /etc/hosts
- ✅ Tests cluster connection
- ✅ No need to access control plane manually

**What "accept subnet routes" means:**
- **Simple:** Your laptop needs permission to reach the cluster's LoadBalancer IPs
- **Technical:** Configures Tailscale client to accept advertised routes from control plane
- Sets up everything automatically

#### Manual Way (If Script Doesn't Work)

<details>
<summary>Click to expand manual steps</summary>

**Step 1: Install kubectl**

**On Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install -y kubectl
```

**On macOS:**
```bash
brew install kubectl
```

**On Windows (in WSL):**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

**Step 2: Get kubeconfig via SSH (no control plane access needed!)**

```bash
# SSH to control plane and copy kubeconfig
ssh your-user@100.x.x.x "cat ~/.kube/config" > ~/.kube/config
chmod 600 ~/.kube/config
```

**If that doesn't work:**
```bash
# If kubeconfig requires sudo
ssh -t your-user@100.x.x.x "sudo cat /root/.kube/config" > ~/.kube/config
chmod 600 ~/.kube/config
```

**Step 3: Test connection**

```bash
kubectl get nodes
```

</details>

**Troubleshooting:**
- ❌ "connection refused" → Make sure Tailscale is running on your laptop
- ❌ "cannot connect to control plane" → Check Tailscale IP: `tailscale status`
- ❌ "authentication failed" → Re-run setup-laptop.sh
- ❌ "Permission denied (publickey)" → Setup script will configure SSH key

---

## 📊 Monitoring Your Cluster

### Access Grafana (Metrics & Dashboards)

1. **Get Grafana URL and credentials:**
   ```bash
   # On control plane
   sudo ./scripts/show-credentials.sh
   ```

2. **Open Grafana in your browser:**
   - URL: `http://100.x.x.x` (shown in output)
   - Username: `admin`
   - Password: (shown in output)

3. **What you'll see:**
   - 📊 Cluster Overview - CPU, RAM, disk usage
   - 🖥️ Node Metrics - Per-machine stats
   - 📦 Pod Metrics - Container resource usage
   - 💾 Storage Metrics - Longhorn volumes
   - 🔍 Application Logs - Loki integration

**Popular Dashboards:**
- **Kubernetes / Compute Resources / Cluster** - Overall cluster health
- **Node Exporter / Nodes** - Machine-level details
- **Longhorn** - Storage performance

**Learning Resources:**
- Grafana Basics: https://grafana.com/docs/grafana/latest/getting-started/
- YouTube: Search "Grafana tutorial for beginners"
- Ask ChatGPT/Claude: "How do I create a Grafana dashboard?"

### Viewing Logs

**In Grafana:**
1. Click "Explore" (compass icon) on left sidebar
2. Select "Loki" from dropdown at top
3. Query examples:
   ```
   # All logs from a namespace
   {namespace="demo-apps"}
   
   # Logs from specific app
   {app="my-app"}
   
   # Error logs only
   {namespace="demo-apps"} |= "error"
   ```

**From Command Line:**
```bash
# View pod logs
kubectl logs -n <namespace> <pod-name>

# Follow logs in real-time
kubectl logs -f -n <namespace> <pod-name>

# All pods with a label
kubectl logs -n <namespace> -l app=my-app
```

---

## 💾 Managing Storage

### Access Longhorn UI

1. **Get Longhorn URL:**
   ```bash
   sudo ./scripts/show-credentials.sh
   ```

2. **Open in browser:**
   - URL: `http://100.x.x.x`
   - No login required (protected by Tailscale)

3. **What you can do:**
   - View all volumes
   - See storage usage
   - Create backups
   - Monitor replicas
   - Check node storage

**Learning Longhorn:**
- Docs: https://longhorn.io/docs/
- YouTube: "Longhorn Kubernetes storage tutorial"

### Access MinIO (S3 Storage)

1. **Get MinIO credentials:**
   ```bash
   sudo ./scripts/show-credentials.sh
   ```

2. **Open MinIO Console:**
   - URL: `http://100.x.x.x:9001`
   - Login with credentials shown

3. **What you can do:**
   - Create buckets
   - Upload files
   - Set access policies
   - Monitor usage
   - Generate access keys for apps

**MinIO CLI (Optional):**
```bash
# Install mc (MinIO client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Configure
mc alias set myminio http://100.x.x.x:9000 <access-key> <secret-key>

# Use it
mc ls myminio
mc mb myminio/my-bucket
mc cp myfile.txt myminio/my-bucket/
```

---

## 🚀 Deploying Applications

### Method 1: Deploy Demo App (Easiest - Start Here!)

**Purpose:** Verify everything works

```bash
# On control plane
sudo ./scripts/deploy-demo-app.sh deploy
```

**What this does:**
- Deploys a simple web app
- Gets a Tailscale IP (LoadBalancer)
- Shows cluster is working
- Demonstrates Pod Security Standards

**Access it:**
- URL shown after deployment (e.g., `http://100.x.x.x`)
- Open in any browser on Tailscale network

**Remove when done:**
```bash
sudo ./scripts/deploy-demo-app.sh remove
```

**Full guide:** [DEMO_APP_GUIDE.md](DEMO_APP_GUIDE.md)

### Method 2: One-Click Common Apps

**Purpose:** Deploy databases, caches quickly

```bash
# See available apps
sudo ./scripts/manage-apps.sh list

# Deploy PostgreSQL
sudo ./scripts/manage-apps.sh deploy postgresql

# Deploy Redis
sudo ./scripts/manage-apps.sh deploy redis

# Deploy MySQL
sudo ./scripts/manage-apps.sh deploy mysql

# Check status
sudo ./scripts/manage-apps.sh status

# Remove an app
sudo ./scripts/manage-apps.sh remove postgresql
```

**Full guide:** [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)

### Method 3: Deploy Your Own App

**Using kubectl:**

```bash
# Create a deployment
kubectl create deployment my-app --image=nginx:alpine

# Expose it with LoadBalancer (gets Tailscale IP)
kubectl expose deployment my-app --port=80 --type=LoadBalancer

# Check the IP
kubectl get svc my-app
```

**Using YAML manifests:**

```bash
# Create app.yaml
kubectl apply -f app.yaml

# View it
kubectl get pods
kubectl get svc
```

**Full guide:** [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)

### Method 4: Deploy Local AI Chat (LLM)

**Purpose:** Run ChatGPT-like AI chat 100% locally on your cluster

```bash
# Deploy Open WebUI + Ollama
sudo ./scripts/deploy-llm-chat.sh
```

**What this does:**
- Deploys Open WebUI (ChatGPT-like interface)
- Deploys Ollama (runs LLM models)
- Prompts to download an AI model
- Gets a LoadBalancer IP for access

**Access it:**
- URL shown after deployment (e.g., `http://100.x.x.x`)
- Or if DNS enabled: `http://chat.mynodeone.local`
- Create account (first user = admin)
- Start chatting!

**Available models:**
- tinyllama (637MB) - Fast, basic
- phi3:mini (2.3GB) - Balanced
- llama3.2 (2GB) - High quality
- Many more available

**Why this is cool:**
- ✅ 100% local - no cloud APIs
- ✅ Your data never leaves your cluster
- ✅ No API costs
- ✅ Works offline
- ✅ Multiple models available
- ✅ ChatGPT-like interface

**Requirements:**
- 4GB+ RAM available
- 50GB+ storage for models
- Patience for model downloads

**Remove when done:**
```bash
kubectl delete namespace llm-chat
```

### Method 5: GitOps with ArgoCD (Advanced)

**Purpose:** Deploy apps automatically when you push to Git

1. **Access ArgoCD:**
   ```bash
   sudo ./scripts/show-credentials.sh  # Get URL and credentials
   ```

2. **Open ArgoCD UI** in browser

3. **Connect your Git repository:**
   - Click "New App"
   - Enter Git repo URL
   - Specify path to Kubernetes manifests
   - Click "Create"

4. **ArgoCD automatically deploys!**

**Learning ArgoCD:**
- Docs: https://argo-cd.readthedocs.io/
- YouTube: "ArgoCD tutorial"
- Our guide: [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)

---

## 🎮 Using AI-Assisted Development (Cursor, Windsurf, etc.)

**Perfect for:** Non-technical users, developers who want to move fast

### Setup for AI Coding

1. **Install kubectl on your laptop** (see above)
2. **Copy kubeconfig** (see above)
3. **Install your AI coding tool:**
   - Cursor: https://cursor.sh
   - Windsurf: https://www.codeium.com/windsurf
   - GitHub Copilot: https://github.com/features/copilot

### Example: Ask AI to Deploy an App

**In Cursor or Windsurf:**

```
You: "Create a Kubernetes deployment for a Node.js app with PostgreSQL database"

AI: [Generates YAML files]

You: kubectl apply -f deployment.yaml

AI: [Shows you the commands]
```

**Tips:**
- AI tools can generate Kubernetes manifests for you
- Ask them to explain what each part does
- Use `kubectl explain <resource>` to learn more
- AI can debug errors: paste error messages and ask for help

---

## 🌐 Accessing Services From Anywhere

### Current Setup: Tailscale VPN + Subnet Routes

**What you have now:**
- All services accessible via LoadBalancer IPs (100.x.x.x addresses)
- Secure by default (Tailscale encrypted mesh network)
- **Subnet routes configured** during control plane installation

### ⚠️ Important: Approve Tailscale Subnet Route (One-Time, 30 Seconds)

During control plane installation, MyNodeOne automatically configured Tailscale to advertise the LoadBalancer IP range. **You just need to approve it once:**

**1. Go to Tailscale Admin Console:**
```
https://login.tailscale.com/admin/machines
```

**2. Find your control plane machine in the list**

**3. Click the "..." menu → "Edit route settings"**

**4. Toggle ON the subnet route:** `100.118.5.0/24` (or your subnet)

**5. Click "Save"**

✅ **Done!** Now all devices on your Tailscale network can access services directly.

### Easy-to-Remember Domain Names (.local)

**After approving the Tailscale subnet route**, you can access services using friendly domain names:

```bash
# Access from any device on Tailscale:
http://grafana.mynodeone.local       # Monitoring dashboard
https://argocd.mynodeone.local       # GitOps platform  
http://minio.mynodeone.local:9001    # Object storage console
http://open-webui.mynodeone.local    # LLM chat interface
```

**How this works:**
- ✅ Control plane configures `.local` domains during installation
- ✅ Management laptop setup automatically adds DNS entries to `/etc/hosts`
- ✅ No manual configuration needed on your laptop
- ✅ Works immediately after subnet route approval

**For additional devices (phones, tablets):**

**Option A: Use Direct IPs** (Simplest)
```bash
# Just use the LoadBalancer IPs shown in credentials
http://100.118.5.203  # Grafana
```

**Option B: Add .local domains manually**
Edit `/etc/hosts` on that device:
```bash
# Linux/macOS/Android (with Termux)
sudo nano /etc/hosts

# Add these lines (get IPs from: sudo ./scripts/show-credentials.sh):
100.118.5.203  grafana.mynodeone.local
100.118.5.204  argocd.mynodeone.local
100.118.5.202  minio.mynodeone.local
```

**To access from any device:**
1. Install Tailscale on that device
2. Login to your Tailscale account
3. Access services via IPs or .local domains (if configured)

### Future: Add Public Domain (Optional)

**Want your apps accessible without VPN?** You can:

1. Get a VPS with public IP ($5-15/month)
2. Run edge node setup
3. Point your domain to VPS (e.g., myapp.yourdomain.com)
4. SSL certificates auto-configured

**Guide:** [docs/networking.md](docs/networking.md)

---

## 🔧 Common Tasks

### Add More Machines (Workers)

```bash
# On control plane, get join command
cat /root/mynodeone-join-token.txt

# On new machine, run join command shown
sudo k3s agent --server https://... --token ...
```

**Or use the helper script:**
```bash
sudo ./scripts/add-worker-node.sh
```

**Full guide:** [docs/scaling.md](docs/scaling.md)

### Check Cluster Health

```bash
# Node status
kubectl get nodes

# Pod status (all namespaces)
kubectl get pods -A

# Services and their IPs
kubectl get svc -A

# Storage volumes
kubectl get pv,pvc -A

# Resource usage
kubectl top nodes
kubectl top pods -A
```

### Update Passwords

**Grafana:**
1. Login to Grafana
2. Click profile icon → Preferences
3. Change Password tab

**MinIO:**
1. Login to MinIO console
2. Identity → Users
3. Create new user with admin policy
4. Delete old admin user

**ArgoCD:**
```bash
# From control plane or laptop with kubectl
argocd account update-password
```

### Backup Important Data

**Kubernetes manifests:**
```bash
# Save all your deployments
kubectl get all -A -o yaml > my-cluster-backup.yaml
```

**Longhorn snapshots:**
1. Open Longhorn UI
2. Select volume
3. Click "Take Snapshot"
4. Schedule recurring snapshots

**MinIO buckets:**
```bash
# Use mc command
mc mirror myminio/my-bucket /backups/my-bucket
```

---

## 📚 Learning Resources

### Understanding Tools

| Tool | What It Does | Learn More |
|------|--------------|------------|
| **Kubernetes** | Container orchestration | https://kubernetes.io/docs/tutorials/ |
| **kubectl** | Command-line tool | https://kubernetes.io/docs/reference/kubectl/ |
| **Grafana** | Monitoring dashboards | https://grafana.com/docs/ |
| **Prometheus** | Metrics collection | https://prometheus.io/docs/introduction/overview/ |
| **Longhorn** | Block storage | https://longhorn.io/docs/ |
| **MinIO** | Object storage (S3) | https://min.io/docs/ |
| **ArgoCD** | GitOps deployment | https://argo-cd.readthedocs.io/ |
| **Traefik** | Ingress/routing | https://doc.traefik.io/traefik/ |

### YouTube Channels (Beginner-Friendly)

- **TechWorld with Nana** - Kubernetes & DevOps tutorials
- **NetworkChuck** - Fun, beginner-friendly tech tutorials
- **Jeff Geerling** - Homelab and self-hosting
- **LearnLinuxTV** - Linux and container tutorials

### AI Assistants (Use Them!)

**Ask ChatGPT, Claude, or Gemini:**
- "Explain Kubernetes pods like I'm 10 years old"
- "How do I deploy a web app to Kubernetes?"
- "What's the difference between Deployment and StatefulSet?"
- "Debug this kubectl error: [paste error]"

---

## 🆘 Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -A

# Describe pod (shows events/errors)
kubectl describe pod <pod-name> -n <namespace>

# View logs
kubectl logs <pod-name> -n <namespace>
```

**Common issues:**
- Image pull errors → Check internet connection
- CrashLoopBackOff → Check logs for application errors
- Pending status → Check if nodes have resources

### Can't Access Services

**Most Common Issue: Tailscale Not Accepting Routes**

If you get "connection timeout" or can't reach services at 100.x.x.x IPs:

```bash
# Check if routes are being accepted
tailscale status --self

# If you see "accept-routes is false" warning:
sudo tailscale up --accept-routes

# Test connectivity
curl -I http://grafana.mynodeone.local
```

**What This Means:**
- **Simple:** Your laptop needs permission to reach cluster LoadBalancer IPs
- **Technical:** Control plane advertises subnet routes; laptop must accept them
- **Fix:** Run `sudo tailscale up --accept-routes` on your laptop

**Full Checklist:**
- ✅ Is Tailscale running on your laptop? `tailscale status`
- ✅ Is laptop accepting routes? Should NOT show "accept-routes is false" warning
- ✅ Was the subnet route approved in Tailscale admin? Check at https://login.tailscale.com/admin/machines
- ✅ Are you using the correct IP from `show-credentials.sh`?
- ✅ Is the service showing an EXTERNAL-IP? `kubectl get svc -A`
- ✅ Try from control plane first (to isolate network issues)

```bash
# Check service has IP
kubectl get svc -A | grep LoadBalancer

# If pending, check MetalLB
kubectl get pods -n metallb-system

# Check Tailscale health
tailscale status --self
# Should NOT show "accept-routes is false" warning

# Test from control plane (SSH in)
ssh user@control-plane-ip
curl -I http://100.118.5.203  # Should work from control plane
```

### Cluster Slow or Unresponsive

```bash
# Check node resources
kubectl top nodes

# Check which pods are using resources
kubectl top pods -A --sort-by=memory
kubectl top pods -A --sort-by=cpu

# Check storage
kubectl get pv,pvc -A
```

**Common causes:**
- Out of disk space → Check Longhorn UI
- Out of memory → Scale down or add nodes
- Too many pods → Review what's running

---

## 🎯 Next Steps Roadmap

### Week 1: Learn the Basics
- [ ] Deploy demo app
- [ ] Access all web UIs (Grafana, MinIO, Longhorn, ArgoCD)
- [ ] Set up kubectl on your laptop
- [ ] Deploy one real application

### Week 2: Get Comfortable
- [ ] Try AI-assisted deployment (Cursor/Windsurf)
- [ ] Create custom Grafana dashboard
- [ ] Set up GitOps with ArgoCD
- [ ] Add monitoring for your app

### Month 1: Expand
- [ ] Add worker node
- [ ] Deploy database-backed application
- [ ] Set up automated backups
- [ ] Configure custom domain (if desired)

### Ongoing
- [ ] Monitor cluster health weekly
- [ ] Rotate credentials every 90 days
- [ ] Keep learning - try new applications
- [ ] Join Kubernetes community forums

---

## 💬 Getting Help

### Documentation
- **Quick Start:** [DEMO_APP_GUIDE.md](DEMO_APP_GUIDE.md)
- **Deployment Guide:** [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)
- **Demo App:** [DEMO_APP_GUIDE.md](DEMO_APP_GUIDE.md)
- **Security:** [SECURITY_CREDENTIALS_GUIDE.md](SECURITY_CREDENTIALS_GUIDE.md)
- **FAQ:** [FAQ.md](../reference/FAQ.md) - 50+ common questions answered

### Community
- GitHub Issues: https://github.com/vinsac/MyNodeOne/issues
- Kubernetes Slack: https://kubernetes.slack.com
- Reddit: r/kubernetes, r/selfhosted

### AI Assistants
- ChatGPT, Claude, Gemini - Great for explaining concepts
- GitHub Copilot - Code generation and debugging
- Always available, instant answers!

---

## 📋 Checklist: What You Should Do Now

**Immediate (Today):**
- [ ] Run `sudo ./scripts/show-credentials.sh` and save credentials to password manager
- [ ] Delete credential files: `sudo rm /root/mynodeone-*-credentials.txt`
- [ ] Access Grafana and change admin password
- [ ] Deploy demo app to verify cluster works
- [ ] Set up kubectl on your laptop (if using laptop for management)

**This Week:**
- [ ] Read [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)
- [ ] Deploy one real application
- [ ] Explore Grafana dashboards
- [ ] Learn basic kubectl commands

**This Month:**
- [ ] Set up GitOps with ArgoCD
- [ ] Configure backups (Longhorn snapshots, MinIO mirror)
- [ ] Add worker node (if you have another machine)
- [ ] Join Kubernetes community forums

---

## 🎉 You're Ready!

Your private cloud is running! You have:

✅ Kubernetes cluster operational  
✅ Monitoring and logging (Grafana)  
✅ Storage systems (Longhorn + MinIO)  
✅ Secure networking (Tailscale)  
✅ GitOps platform (ArgoCD)  
✅ All tools for AI-assisted development

**Start with the demo app, then explore!** Every expert was once a beginner. 🚀

---

**Questions?** Check [FAQ.md](FAQ.md) or ask ChatGPT/Claude: "I just installed MyNodeOne, help me [your goal]"
