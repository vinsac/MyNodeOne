# VPS Quick Start - Your Contabo Server

**Fast track guide for YOUR specific setup**

---

## 🎯 Your Setup

- **VPS:** Contabo
- **IP:** 45.8.133.192
- **OS:** Ubuntu 24.04.3 LTS
- **RAM:** 6GB
- **Storage:** 400GB
- **Access:** SSH only (no GUI)

---

## ⚡ 5-Minute Setup

### 1. Install Tailscale (2 min)

```bash
# On your VPS (you're already SSH'd in):
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**You'll see a URL like:**
```
To authenticate, visit:
  https://login.tailscale.com/a/abc123...
```

**Open that URL on your laptop browser → Log in → Click Connect**

**Verify:**
```bash
tailscale ip -4
# Note this IP! (example: 100.101.102.103)
```

---

### 2. Secure VPS (1 min)

```bash
# Install firewall
sudo apt install -y ufw fail2ban

# Allow SSH (don't lock yourself out!)
sudo ufw allow 22/tcp

# Allow Tailscale
sudo ufw allow 41641/udp

# Enable firewall
sudo ufw enable
```

---

### 3. Install MyNodeOne (15-30 min)

```bash
# Clone repo
cd ~
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne

# Make script executable
chmod +x scripts/bootstrap-control-plane.sh

# Run installation
sudo ./scripts/bootstrap-control-plane.sh
```

**Installation takes 15-30 minutes. Go get coffee! ☕**

---

### 4. Install First App (2 min)

```bash
# After MyNodeOne installs successfully:
cd ~/MyNodeOne
sudo ./scripts/apps/install-immich.sh
```

**Access Immich:**
- From laptop (with Tailscale): `http://100.x.x.x` (use YOUR Tailscale IP)
- Create admin account
- Done!

---

## 🐛 If You Get Errors

### Tell me:

1. **At which step?**
   - During Tailscale install?
   - During MyNodeOne install?
   - During app install?

2. **What's the error message?**
   - Copy the last 20-30 lines of output
   - Or run: `sudo journalctl -u k3s -n 50` and share output

3. **What's the system status?**
   ```bash
   # Check disk space
   df -h
   
   # Check memory
   free -h
   
   # Check if k3s is running
   sudo systemctl status k3s
   ```

---

## 📋 Common Errors & Fixes

### Error: "No external IP for services"

**Symptom:**
```bash
kubectl get svc -A
# Shows <pending> under EXTERNAL-IP
```

**Fix:**
```bash
# Configure MetalLB with your Tailscale IP
TAILSCALE_IP=$(tailscale ip -4)

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${TAILSCALE_IP}/32
EOF

# Wait 30 seconds, then check again
kubectl get svc -A
```

---

### Error: "Can't access apps"

**Fix:**
```bash
# 1. Check Tailscale is working
tailscale status
# Should show "online"

# 2. Get service IP
kubectl get svc -A | grep immich
# Note the EXTERNAL-IP

# 3. Try accessing
curl http://<EXTERNAL-IP>

# 4. From laptop, try browser
# http://<EXTERNAL-IP>
```

---

### Error: "Disk space issues"

**Fix:**
```bash
# Check space
df -h

# If low, clean up
sudo apt autoremove -y
sudo apt autoclean -y

# Remove old logs
sudo journalctl --vacuum-time=3d
```

---

### Error: "Installation hangs"

**Fix:**
```bash
# Check what's happening
sudo journalctl -u k3s -f

# Check pod status
kubectl get pods -A

# If stuck, restart k3s
sudo systemctl restart k3s
```

---

## 🔍 Useful Commands

### Check Everything:

```bash
# Tailscale status
tailscale status

# Kubernetes nodes
kubectl get nodes

# All pods
kubectl get pods -A

# All services
kubectl get svc -A

# Disk space
df -h

# Memory
free -h

# System logs
sudo journalctl -u k3s -n 50
```

### Get Service IPs:

```bash
# List all services with IPs
kubectl get svc -A -o wide

# Or specifically for an app
kubectl get svc -n immich
```

### Restart Services:

```bash
# Restart k3s
sudo systemctl restart k3s

# Restart a pod
kubectl delete pod <pod-name> -n <namespace>
# It will automatically recreate
```

---

## 📱 Access from Phone

1. **Install Tailscale app** (iOS/Android)
2. **Log in** (same account as VPS)
3. **Install Immich app**
4. **Server:** `http://100.x.x.x` (your Tailscale IP)
5. **Done!** Photos backup to your VPS

---

## 💡 Next Steps

After everything works:

1. **Install more apps:**
   ```bash
   sudo ./scripts/app-store.sh
   ```

2. **Install dashboard:**
   ```bash
   cd ~/MyNodeOne/website
   sudo ./deploy-dashboard.sh
   # Access at: http://100.x.x.x:8080
   ```

3. **Set up monitoring:**
   - Grafana: `http://100.x.x.x:3000`
   - Username: admin
   - Password: `kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | base64 -d`

---

## 🆘 Share Your Error

**If you're stuck, share:**

```bash
# Run these commands and share output:

echo "=== Tailscale Status ==="
tailscale status

echo "=== Kubernetes Nodes ==="
kubectl get nodes

echo "=== All Pods ==="
kubectl get pods -A

echo "=== System Resources ==="
df -h
free -h

echo "=== Recent Logs ==="
sudo journalctl -u k3s -n 50
```

**Then tell me which step failed and what the error message was!**

---

## ✅ Success Checklist

- [ ] SSH'd into VPS: `ssh root@45.8.133.192` ✅
- [ ] Tailscale installed and authenticated
- [ ] Tailscale IP obtained (100.x.x.x)
- [ ] Firewall configured
- [ ] MyNodeOne installed (k3s running)
- [ ] First app installed (Immich)
- [ ] Can access app from laptop
- [ ] Can access app from phone

**Ready to help debug! Share the error message you're getting.** 🚀
