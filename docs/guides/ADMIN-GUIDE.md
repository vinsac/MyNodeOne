# MyNodeOne Administration Guide

Complete guide for cluster administration, suitable for non-technical users.

## Table of Contents

1. [Admin Tools Overview](#admin-tools-overview)
2. [Command-Line Admin Tool](#command-line-admin-tool)
3. [Web Dashboard](#web-dashboard)
4. [Storage Management](#storage-management)
5. [Common Tasks](#common-tasks)
6. [Cluster Node Management](#cluster-node-management)
7. [Troubleshooting](#troubleshooting)

---

## Admin Tools Overview

MyNodeOne provides three administration methods:

### 1. **Command-Line Admin Tool** (Easiest)
Simple menu-driven interface for common tasks.

```bash
sudo ./scripts/operations/admin.sh
```

### 2. **Web Dashboard** (Most User-Friendly)
Visual interface accessible via web browser.

```bash
sudo ./scripts/setup/setup-admin-dashboard.sh
```

### 3. **kubectl Commands** (Advanced)
Direct Kubernetes CLI access for power users.

---

## Command-Line Admin Tool

### Installation
Already installed! Just run:

```bash
cd /path/to/MyNodeOne
sudo ./scripts/operations/admin.sh
```

### Features

**Main Menu:**
```
  1. View installed apps          - See all running applications
  2. View resource usage          - Check CPU, RAM, storage
  3. View logs                    - Debug application issues
  4. Restart application          - Fix stuck apps
  5. Manage storage              - Expand disk space
  6. Install new app             - Add applications
  7. Cluster health check        - Verify system status
  8. Setup web dashboard         - Enable web UI
  9. Exit
```

### Common Workflows

#### View Application Status
1. Run `sudo ./scripts/operations/admin.sh`
2. Choose option 1 (View installed apps)
3. See all applications with their status

#### Check Resource Usage
1. Run `sudo ./scripts/operations/admin.sh`
2. Choose option 2 (View resource usage)
3. See CPU, RAM, and storage for each node

#### View Application Logs
1. Run `sudo ./scripts/operations/admin.sh`
2. Choose option 3 (View logs)
3. Select the application namespace
4. Select the pod
5. Logs stream in real-time (Ctrl+C to stop)

#### Restart a Stuck Application
1. Run `sudo ./scripts/operations/admin.sh`
2. Choose option 4 (Restart application)
3. Select the application from the list
4. Confirm restart

---

## Web Dashboard

### Setup

```bash
sudo ./scripts/setup/setup-admin-dashboard.sh
```

The script will:
- Install Kubernetes Dashboard
- Create admin account
- Generate access token
- Configure external access
- Update local DNS

### Access

**URL:** `https://dashboard.mynodeone.local` or `https://<external-ip>`

**Login:**
1. Open the dashboard URL
2. Select "Token" authentication
3. Paste the token (saved in `~/.mynodeone/dashboard-token.txt`)
4. Click "Sign In"

### Features

**What You Can Do:**
- View all applications and their status
- Check resource usage (CPU, RAM, storage)
- View logs from any application
- Restart applications
- Scale applications up/down
- 🏥 Monitor cluster health
- View persistent storage
- Manage secrets and configs

### Retrieve Token Later

```bash
kubectl get secret admin-user-token -n kubernetes-dashboard \
  -o jsonpath='{.data.token}' | base64 -d
```

Or check the saved file:
```bash
cat ~/.mynodeone/dashboard-token.txt
```

---

## Storage Management

### Automatic Monitoring

**Setup automatic storage monitoring:**

```bash
# Check storage and suggest expansion if needed
sudo ./scripts/apps/llm-chat/monitor-storage.sh

# Automatically expand when usage > 80%
sudo AUTO_EXPAND=true ./scripts/apps/llm-chat/monitor-storage.sh
```

**Set up as cron job (runs daily):**

```bash
# Add to crontab
crontab -e

# Add this line (checks daily at 2 AM):
0 2 * * * AUTO_EXPAND=true /path/to/MyNodeOne/scripts/apps/llm-chat/monitor-storage.sh >> /var/log/llm-storage-monitor.log 2>&1
```

### Manual Storage Expansion

**For LLM Chat:**

```bash
sudo ./scripts/apps/llm-chat/expand-storage.sh
```
- View current storage usage
- Enter new size (e.g., 500Gi, 1Ti)
- Script automatically resizes

**For Other Apps:**

```bash
# 1. Scale down the deployment
kubectl scale deployment <app-name> -n <namespace> --replicas=0

# 2. Expand the PVC
kubectl patch pvc <pvc-name> -n <namespace> \
  -p '{"spec":{"resources":{"requests":{"storage":"500Gi"}}}}'

# 3. Wait 15 seconds
sleep 15

# 4. Scale back up
kubectl scale deployment <app-name> -n <namespace> --replicas=1
```

### Check Storage Usage

**All storage:**
```bash
kubectl get pvc --all-namespaces
```

**Specific app:**
```bash
kubectl exec -n llm-chat deployment/ollama -- df -h /home/ollama/.ollama
```

---

## Common Tasks

### Install a New Application

**Using Admin Tool:**
```bash
sudo ./scripts/operations/admin.sh
# Choose option 6 (Install new app)
```

**Using App Store:**
```bash
sudo ./scripts/operations/app-store.sh
```

**Direct Installation:**
```bash
sudo ./scripts/apps/install-<app-name>.sh
```

### Check Application Status

```bash
# All apps
kubectl get deployments --all-namespaces

# Specific app
kubectl get pods -n <namespace>

# Detailed status
kubectl describe deployment <app-name> -n <namespace>
```

### View Application Logs

```bash
# Real-time logs
kubectl logs -n <namespace> deployment/<app-name> -f

# Last 100 lines
kubectl logs -n <namespace> deployment/<app-name> --tail=100

# Previous crashed pod
kubectl logs -n <namespace> deployment/<app-name> -p
```

### Restart Application

**Via admin tool:**
```bash
sudo ./scripts/operations/admin.sh
# Choose option 4 (Restart application)
```

**Via kubectl:**
```bash
kubectl rollout restart deployment <app-name> -n <namespace>
```

### Scale Application

**Increase replicas:**
```bash
kubectl scale deployment <app-name> -n <namespace> --replicas=3
```

**Decrease replicas:**
```bash
kubectl scale deployment <app-name> -n <namespace> --replicas=1
```

### Delete Application

```bash
# Delete entire namespace (removes everything)
kubectl delete namespace <namespace>

# Keep data, delete app only
kubectl delete deployment <app-name> -n <namespace>
```

### Update Application

**For apps with update scripts:**
```bash
sudo ./scripts/apps/install-<app-name>.sh
# Choose upgrade option if available
```

**Manual update:**
```bash
# Update image
kubectl set image deployment/<app-name> \
  <container-name>=<new-image>:tag \
  -n <namespace>
```

---

## Cluster Node Management

This section covers how to add or remove nodes from your MyNodeOne cluster.

### Checking Node Status

MyNodeOne uses a heartbeat system to track which nodes are online. Each node runs a Node Agent that reports its status to the control plane.

```bash
# View all nodes and their status (requires sudo to read API token)
sudo ./scripts/nodes/nodes-status.sh
```

Output shows:
- **Node name and type** (laptop, worker, vps)
- **Status**: online (heartbeat < 2 min), stale (2-10 min), offline (> 10 min)
- **Last heartbeat time**
- **Config version** currently applied

### Adding a New Node

To add a new node (such as a VPS, Worker, or another Management Laptop), follow the relevant sections in the [**Installation Guide**](./INSTALLATION.md). The setup scripts will:
1. Install the Node Agent automatically
2. Configure it to connect to your control plane
3. Start sending heartbeats immediately

The node will appear in `sudo ./scripts/nodes/nodes-status.sh` within 60 seconds.

### Permanently Removing a Node

If you permanently decommission a node (e.g., you delete your VPS instance), remove it from both Kubernetes and the sync controller registry:

```bash
# Step 1: Remove from Kubernetes (if it's a K3s node)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>

# Step 2: Remove from sync controller registry
sudo ./scripts/nodes/nodes-status.sh remove <node-name>
```

**Note:** Nodes are never automatically removed. This is a safety measure to prevent accidental removal due to temporary network outages. An offline node will stay in the registry (showing as "offline") until you explicitly remove it.

---

## Troubleshooting

### Application Not Starting

**1. Check pod status:**
```bash
kubectl get pods -n <namespace>
```

**2. View detailed info:**
```bash
kubectl describe pod <pod-name> -n <namespace>
```

**3. Check logs:**
```bash
kubectl logs -n <namespace> <pod-name>
```

**Common issues:**
- **ImagePullBackOff**: Wrong image name or no internet
- **CrashLoopBackOff**: App crashing, check logs
- **Pending**: Insufficient resources or storage

### Out of Storage

**Symptoms:**
- "no space left on device" errors
- Pods stuck in Pending
- Applications not starting

**Solution:**
```bash
# For LLM Chat
sudo ./scripts/apps/llm-chat/expand-storage.sh

# For other apps, see Storage Management section
```

### High CPU/RAM Usage

**Check usage:**
```bash
kubectl top nodes
kubectl top pods -n <namespace>
```

**Solutions:**
- Scale down non-essential apps
- Upgrade resources for specific app
- Add more nodes (for production)

### Application Stuck/Frozen

**Quick fix:**
```bash
# Restart the application
kubectl rollout restart deployment <app-name> -n <namespace>
```

**If that doesn't work:**
```bash
# Force delete pod
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0
```

### Cannot Access Dashboard

**Check dashboard status:**
```bash
kubectl get pods -n kubernetes-dashboard
kubectl get svc -n kubernetes-dashboard
```

**Reinstall if needed:**
```bash
kubectl delete namespace kubernetes-dashboard
sudo ./scripts/setup/setup-admin-dashboard.sh
```

### Lost Admin Token

**Retrieve token:**
```bash
kubectl get secret admin-user-token -n kubernetes-dashboard \
  -o jsonpath='{.data.token}' | base64 -d
```

Or check saved file:
```bash
cat ~/.mynodeone/dashboard-token.txt
```

---

## Best Practices

### Regular Maintenance

**Daily:**
- Check application status
- Review logs for errors

**Weekly:**
- Check resource usage
- Review storage capacity
- Verify backups (if configured)

**Monthly:**
- Update applications
- Clean up unused resources
- Review security

### Storage Management

**Recommendations:**
- Monitor storage usage weekly
- Set up automatic monitoring (cron job)
- Keep 20% free space as buffer
- Clean up unused models/data

### Security

**Best practices:**
- Keep dashboard token secure
- Don't share admin credentials
- Use HTTPS for public access
- Regular security updates

### Backups

**What to backup:**
- Application data (PVCs)
- Configuration files
- Dashboard tokens
- DNS settings

---

## Quick Reference

### Most Used Commands

```bash
# Admin tool
sudo ./scripts/operations/admin.sh

# View all apps
kubectl get deployments --all-namespaces

# View all pods
kubectl get pods --all-namespaces

# View storage
kubectl get pvc --all-namespaces

# View logs
kubectl logs -n <namespace> deployment/<app-name> -f

# Restart app
kubectl rollout restart deployment <app-name> -n <namespace>

# Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Storage expansion (LLM Chat)
sudo ./scripts/apps/llm-chat/expand-storage.sh

# Install app
sudo ./scripts/operations/app-store.sh
```

---

## Getting Help

### Built-in Help

```bash
# Admin tool has built-in help
sudo ./scripts/operations/admin.sh

# Each script has help
./scripts/apps/install-<app-name>.sh --help
```

### Documentation

- **This guide**: Complete admin reference
- **App-specific READMEs**: `scripts/apps/README-<APP>.md`
- **App Store**: [APP-STORE.md](../apps/APP-STORE.md)

### Support

- Check application logs first
- Review this guide for solutions
- Check GitHub issues
- Community support channels

---

## Next Steps

1. **Set up web dashboard** (easiest way to manage):
   ```bash
   sudo ./scripts/setup/setup-admin-dashboard.sh
   ```

2. **Set up storage monitoring** (prevent space issues):
   ```bash
   # Add to crontab for automatic monitoring
   crontab -e
   ```

3. **Bookmark useful commands** from Quick Reference

4. **Install applications** you need:
   ```bash
   sudo ./scripts/operations/app-store.sh
   ```
