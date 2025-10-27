# Demo Application Deployment Guide

**For:** Product Managers, Non-Technical Users, and Anyone Testing MyNodeOne  
**Time Required:** 2 minutes  
**Difficulty:** Easy - Just copy and paste commands

---

## ⚠️ IMPORTANT: Where to Run These Commands

**Run these commands on your CONTROL PLANE machine** (the machine where you installed MyNodeOne)

- ✅ **Control Plane** - YES, run here
- ❌ **Worker Nodes** - NO, don't run here
- ❌ **VPS Edge Nodes** - NO, don't run here
- ❌ **Your Laptop/Desktop** - NO, unless it IS your control plane

**How to identify your Control Plane:**
- It's the machine where you first ran `sudo ./scripts/mynodeone`
- It's the machine that has the `~/.kube/config` file
- When you run `kubectl get nodes`, it shows a node with `control-plane,master` role

---

## 🚀 What is the Demo App?

The demo application is a simple web page that:
- ✅ Proves your Kubernetes cluster is working
- ✅ Shows all security features are active
- ✅ Demonstrates LoadBalancer integration
- ✅ Provides cluster resource information
- ✅ Takes less than 1 minute to deploy

**Perfect for:**
- Testing after installation
- Showing stakeholders the cluster works
- Verifying LoadBalancer assigns IPs correctly
- Demonstrating to team members

---

## 📋 Step-by-Step Deployment

### Step 1: Connect to Your Control Plane

**If you're on your control plane machine:** Skip to Step 2

**If you're on your laptop/desktop:**
```bash
# Connect via SSH (replace with your control plane IP)
ssh username@your-control-plane-ip

# Example:
# ssh ubuntu@192.168.1.100
# or if using Tailscale:
# ssh ubuntu@100.118.5.68
```

### Step 2: Navigate to MyNodeOne Directory

```bash
cd ~/MyNodeOne
```

### Step 3: Deploy the Demo App

Copy and paste this command:
```bash
sudo ./scripts/deploy-demo-app.sh deploy
```

**What you'll see:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Deploying MyNodeOne Demo Application
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Creating demo application namespace...
[INFO] Deploying demo application...
[SUCCESS] Demo application deployed!
[INFO] Waiting for LoadBalancer IP assignment...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🎉 Demo Application Deployed Successfully!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Access URL: http://100.118.5.206

  This demo shows:
    ✓ Secure pod configuration
    ✓ LoadBalancer service working
    ✓ Cluster is operational

  To remove this demo:
    kubectl delete namespace demo-apps

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Step 4: Access the Demo App

1. **Copy the URL** shown in the output (e.g., http://100.118.5.206)
2. **Open it in your web browser**
3. **You must be connected to Tailscale VPN** to access it

**Troubleshooting Access:**
- ❌ Can't connect? → Make sure Tailscale is running on your laptop
- ❌ Still can't connect? → Check if pods are running: `kubectl get pods -n demo-apps`
- ❌ No IP shown? → Wait 30 seconds and check: `kubectl get svc -n demo-apps`

---

## 🗑️ Removing the Demo App

When you're done testing, remove the demo app:

### Quick Removal (Recommended)

```bash
sudo ./scripts/deploy-demo-app.sh remove
```

**What you'll see:**
```
[INFO] Deleting demo application namespace...
[SUCCESS] Demo application removed!
```

### Alternative: Manual Removal

```bash
kubectl delete namespace demo-apps
```

**Note:** This removes everything related to the demo app.

---

## 📊 Checking Demo App Status

To see if the demo app is running:

```bash
sudo ./scripts/deploy-demo-app.sh status
```

**Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Demo Application Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Checking deployment status...

NAME                                READY   STATUS    RESTARTS   AGE
pod/demo-chat-app-7b5d8c9f4-x2k9l   1/1     Running   0          2m

NAME                    TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)        AGE
service/demo-chat-app   LoadBalancer   10.43.1.152   100.118.5.206   80:32165/TCP   2m

Demo app is running at: http://100.118.5.206
```

---

## ❓ Common Questions

### Q: I deployed the demo app but can't access the URL
**A:** Make sure:
1. You're connected to Tailscale VPN on your laptop
2. The pods are running: `kubectl get pods -n demo-apps`
3. The service has an EXTERNAL-IP: `kubectl get svc -n demo-apps`

### Q: Can I deploy this multiple times?
**A:** Yes, but you need to remove it first:
```bash
sudo ./scripts/deploy-demo-app.sh remove
sudo ./scripts/deploy-demo-app.sh deploy
```

### Q: Will this affect my other applications?
**A:** No, the demo app runs in its own namespace (`demo-apps`) and is completely isolated.

### Q: How much resources does it use?
**A:** Very little:
- CPU: 100m (0.1 CPU cores)
- Memory: 128MB
- Storage: None (stateless application)

### Q: Can I customize the demo app?
**A:** Yes! The source is in `manifests/examples/demo-app.yaml`. Edit and re-deploy.

### Q: Is this safe for production clusters?
**A:** Yes, it's just a static web page with proper security contexts. However, remove it when you're done testing.

### Q: Does it store any data?
**A:** No, it's a stateless application. Removing it deletes everything.

---

## 🎯 What's Next After Demo App?

Once you've verified the demo app works, you can:

1. **Deploy Real Applications:**
   - See [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)
   - Try `sudo ./scripts/manage-apps.sh list`

2. **Set Up Monitoring:**
   - Access Grafana: http://100.118.5.203
   - See cluster metrics and logs

3. **Explore Storage:**
   - Access Longhorn UI: http://100.118.5.205
   - View persistent volumes

4. **Try GitOps:**
   - Access ArgoCD: https://100.118.5.204
   - Set up automated deployments

---

## 📞 Need Help?

If something doesn't work:

1. **Check cluster status:**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

2. **View demo app logs:**
   ```bash
   kubectl logs -n demo-apps -l app=demo-chat-app
   ```

3. **Check service status:**
   ```bash
   kubectl describe svc -n demo-apps demo-chat-app
   ```

4. **Read troubleshooting guide:**
   - [docs/troubleshooting.md](docs/troubleshooting.md)

5. **Check if Tailscale is working:**
   ```bash
   tailscale status
   ```

---

## 📝 Summary

| Action | Command | Where to Run |
|--------|---------|--------------|
| **Deploy** | `sudo ./scripts/deploy-demo-app.sh deploy` | Control Plane |
| **Remove** | `sudo ./scripts/deploy-demo-app.sh remove` | Control Plane |
| **Status** | `sudo ./scripts/deploy-demo-app.sh status` | Control Plane |
| **Access** | Open URL in browser | Your Laptop (with Tailscale) |

**Remember:** All commands run on the **Control Plane machine**, but you access the URL from **any device on your Tailscale network**.

---

**Ready to deploy real applications?** Check out [APP_DEPLOYMENT_GUIDE.md](APP_DEPLOYMENT_GUIDE.md)!
