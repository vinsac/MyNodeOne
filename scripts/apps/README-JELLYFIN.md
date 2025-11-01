# Jellyfin Installation - One-Click Setup

**Jellyfin** is an open-source media server (Netflix/Plex alternative) that lets you stream movies, TV shows, music, and photos to any device.

---

## ✨ One-Click Installation

### **Prerequisites**
- MyNodeOne cluster installed and running
- kubectl configured
- (Optional) VPS edge node for internet access

### **Install Command**
```bash
sudo ./scripts/apps/install-jellyfin.sh
```

**Installation time:** ~2 minutes

---

## 📋 What Happens Automatically

The script handles everything for you:

### **1. Subdomain Configuration**
```
Choose a subdomain for Jellyfin. This will be used for:
  • Local access: <subdomain>.mynodeone.local
  • Public access: <subdomain>.yourdomain.com (if VPS configured)

Examples: media, jellyfin, movies, tv

Enter subdomain [default: jellyfin]: media
```

**Result:**
- Local: `http://media.mynodeone.local`
- Public: `https://media.curiios.com`

### **2. Kubernetes Deployment**
- ✅ Creates dedicated namespace (`jellyfin`)
- ✅ Configures persistent storage (50GB config + 500GB media)
- ✅ Deploys Jellyfin container
- ✅ Creates LoadBalancer service with NodePort
- ✅ Adds subdomain annotation for DNS discovery

### **3. Local DNS Update**
- ✅ Automatically adds entry to `/etc/hosts`
- ✅ Works on management laptop and any Tailscale device
- ✅ Format: `<subdomain>.mynodeone.local`

### **4. VPS Route Configuration (Optional)**
If VPS edge node is configured:
- ✅ Auto-detects control plane IP
- ✅ Auto-detects NodePort
- ✅ Configures Traefik route
- ✅ Requests Let's Encrypt SSL certificate
- ✅ Sets up HTTPS redirect

---

## 🎯 What Makes This "One-Click"

### **No Manual Configuration Needed**

#### **❌ Old Way (Manual)**
```bash
# 1. Manually set inotify limits
sudo sysctl -w fs.inotify.max_user_instances=1024
echo "fs.inotify.max_user_instances=1024" | sudo tee -a /etc/sysctl.conf

# 2. Manually find service IP and port
kubectl get svc -n jellyfin

# 3. Manually create VPS route with wrong IP
# (LoadBalancer IP doesn't work from VPS!)

# 4. Manually update DNS
# 5. Manually fix SSL certificate
# 6. Manually restart everything
```

#### **✅ New Way (Automated)**
```bash
sudo ./scripts/apps/install-jellyfin.sh
# Answer 2 questions:
#   1. Subdomain? (e.g., "media")
#   2. Public domain? (e.g., "curiios.com")
# Done! Everything works.
```

---

## 🔧 Behind the Scenes

### **System Optimizations** (in `bootstrap-control-plane.sh`)
```bash
# Automatically applied during cluster setup
fs.inotify.max_user_instances=1024  # Prevents container crashes
fs.inotify.max_user_watches=524288  # Supports file watching apps
```

**Why needed:** Jellyfin uses file watchers for media library updates. Default Linux limits (128) are too low for containers.

### **VPS Route Intelligence** (in `configure-vps-route.sh`)
```bash
# Auto-detection logic:
1. Get control plane Tailscale IP from Kubernetes
   → kubectl get nodes -o jsonpath='{...InternalIP...}'

2. Get service NodePort (not LoadBalancer IP!)
   → kubectl get svc -n jellyfin jellyfin -o jsonpath='{...nodePort}'

3. Configure Traefik: http://<control-plane-ip>:<nodeport>
   → VPS can reach this over Tailscale
```

**Why needed:** LoadBalancer IPs (e.g., 100.118.5.208) are only accessible within cluster network. VPS needs NodePort on control plane's Tailscale IP.

### **DNS Discovery** (in `update-laptop-dns.sh`)
```bash
# Reads Kubernetes annotation:
annotations:
  mynodeone.local/subdomain: "media"

# Generates DNS entry:
100.118.5.208    media.mynodeone.local    # jellyfin/jellyfin
```

**Why needed:** Consistent subdomain across local and public access.

---

## 🚀 Post-Installation

### **Access Jellyfin**

#### **Local Network (via Tailscale)**
```
http://media.mynodeone.local
```

#### **Internet (via VPS)**
```
https://media.curiios.com
```

### **First-Time Setup**
1. Open the URL in your browser
2. Follow the setup wizard
3. Create admin account
4. Add media libraries
5. (Optional) Configure hardware transcoding

### **Mobile Apps**
- **iOS:** Search "Jellyfin" in App Store
- **Android:** Search "Jellyfin" in Play Store

**Server URL:** `http://media.mynodeone.local` (or `https://media.curiios.com`)

---

## 📁 Storage

### **Default Allocation**
- **Config:** 50GB (Longhorn PVC)
- **Media:** 500GB (Longhorn PVC)

### **Adjust Storage**
Edit the script before running:
```bash
STORAGE_CONFIG="50Gi"   # Change as needed
STORAGE_MEDIA="500Gi"   # Adjust for your library size
```

### **Access Storage**
```bash
# List volumes
kubectl get pvc -n jellyfin

# Storage path in container
/config  → Jellyfin configuration
/media   → Your media files (movies, TV, music)
```

---

## 🔍 Troubleshooting

### **Issue: Pod CrashLoopBackOff**

**Symptom:**
```bash
kubectl get pods -n jellyfin
# jellyfin-xxx   0/1     CrashLoopBackOff
```

**Cause:** inotify limits too low

**Fix:** (Applied automatically in new installations)
```bash
# On control plane node:
kubectl debug node/canada-pc-0001 -it --image=alpine -- chroot /host sh -c "
  sysctl -w fs.inotify.max_user_instances=1024
  sysctl -w fs.inotify.max_user_watches=524288
  echo 'fs.inotify.max_user_instances=1024' >> /etc/sysctl.conf
  echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
"

# Restart pod
kubectl delete pod -n jellyfin --all
```

---

### **Issue: Local DNS Not Working**

**Symptom:**
```bash
ping media.mynodeone.local
# ping: cannot resolve media.mynodeone.local
```

**Fix:**
```bash
# Update DNS
sudo ./scripts/update-laptop-dns.sh

# Verify
cat /etc/hosts | grep media.mynodeone.local
```

---

### **Issue: VPS Shows 502 Bad Gateway**

**Symptom:** `https://media.curiios.com` shows 502 error

**Cause:** VPS route pointing to wrong backend

**Fix:** Re-run VPS configuration (now auto-detects NodePort)
```bash
sudo ./scripts/configure-vps-route.sh jellyfin 80 media curiios.com
```

**Verify backend:**
```bash
ssh root@<vps-ip> "cat /etc/traefik/dynamic/jellyfin.yml"
# Should show: http://<control-plane-ip>:<nodeport>
# Example: http://100.118.5.68:31185
```

---

### **Issue: SSL Certificate Shows "TRAEFIK DEFAULT CERT"**

**Symptom:** Browser shows invalid certificate immediately after installation

**Cause:** Let's Encrypt certificate not issued yet (THIS IS NORMAL for new domains!)

**Expected Timeline:**
- **0-30 seconds:** Shows "TRAEFIK DEFAULT CERT" (temporary)
- **30-60 seconds:** Let's Encrypt completes HTTP-01 challenge
- **60+ seconds:** Valid Let's Encrypt certificate active

**Fix:** **Just wait!** This is automatic and takes 30-60 seconds.

**If still showing default cert after 2 minutes:**
```bash
# Restart Traefik to trigger new certificate request
ssh root@<vps-ip> "docker restart traefik"

# Wait 60 seconds, then verify
sleep 60
echo | openssl s_client -servername media.curiios.com \
  -connect media.curiios.com:443 2>/dev/null | \
  openssl x509 -noout -subject -issuer

# Should show:
# subject=CN = media.curiios.com
# issuer=C = US, O = Let's Encrypt, CN = R12
```

**Important:** Don't panic if you see "TRAEFIK DEFAULT CERT" right after installation. This is expected and will automatically resolve within 1-2 minutes as Let's Encrypt issues your certificate.

---

## 📊 Management Commands

### **View Logs**
```bash
kubectl logs -f deployment/jellyfin -n jellyfin
```

### **Restart Jellyfin**
```bash
kubectl rollout restart deployment/jellyfin -n jellyfin
```

### **Check Status**
```bash
kubectl get all -n jellyfin
```

### **Access Configuration**
```bash
kubectl exec -it deployment/jellyfin -n jellyfin -- bash
cd /config
ls -la
```

### **Uninstall**
```bash
kubectl delete namespace jellyfin
```

**Note:** This deletes all data! Back up first if needed.

---

## 🎬 Example Use Cases

### **Family Media Server**
```
1. Install Jellyfin: sudo ./scripts/apps/install-jellyfin.sh
2. Subdomain: "movies"
3. Public domain: "smith-family.com"
4. Result: https://movies.smith-family.com
5. Share with family worldwide!
```

### **Home Media Library**
```
1. Install Jellyfin: sudo ./scripts/apps/install-jellyfin.sh
2. Subdomain: "media"
3. Skip VPS setup (local only)
4. Result: http://media.mynodeone.local
5. Stream on local network
```

### **Personal Netflix**
```
1. Install Jellyfin: sudo ./scripts/apps/install-jellyfin.sh
2. Subdomain: "flix"
3. Public domain: "mydomain.com"
4. Result: https://flix.mydomain.com
5. Access from anywhere!
```

---

## 🔒 Security Notes

### **HTTPS (Public Access)**
- ✅ Automatic Let's Encrypt SSL
- ✅ HTTPS redirect enabled
- ✅ Certificate auto-renewal

### **Authentication**
- ✅ Jellyfin requires login by default
- ✅ Create strong admin password
- ✅ Use different passwords for each user

### **Network Isolation**
- ✅ Namespace isolation in Kubernetes
- ✅ Tailscale VPN for internal access
- ✅ VPS acts as secure gateway for public access

---

## 📚 Related Documentation

- [APP-STORE.md](../../docs/reference/APP-STORE.md) - All available apps
- [HYBRID-TROUBLESHOOTING.md](../../docs/guides/HYBRID-TROUBLESHOOTING.md) - VPS & SSL issues
- [DNS-SETUP-GUIDE.md](../../docs/guides/DNS-SETUP-GUIDE.md) - DNS configuration

---

## ✅ Success Checklist

After installation, verify:

- [ ] Pod is running: `kubectl get pods -n jellyfin`
- [ ] Service has IP: `kubectl get svc -n jellyfin`
- [ ] Local DNS works: `ping media.mynodeone.local`
- [ ] Local access works: `curl http://media.mynodeone.local`
- [ ] (If VPS) Public DNS points to VPS: `nslookup media.curiios.com`
- [ ] (If VPS) HTTPS works: `curl https://media.curiios.com`
- [ ] (If VPS) SSL certificate valid: Check in browser (green padlock)

**All green? Perfect! Enjoy your personal media server! 🎉**
