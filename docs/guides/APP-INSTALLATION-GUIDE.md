# Application Installation Guide

Complete guide for installing applications on MyNodeOne with error handling and edge cases covered.

---

## 📋 Prerequisites

### **Required Before Installing Any App:**

1. **Control Plane Installed**
   ```bash
   sudo ./scripts/bootstrap-control-plane.sh
   ```

2. **Kubectl Working**
   ```bash
   kubectl get nodes
   # Should show your node(s)
   ```

3. **Longhorn Storage Available**
   ```bash
   kubectl get storageclass longhorn
   # Should show longhorn storage class
   ```

4. **(Optional) VPS Edge Node for Public Access**
   ```bash
   # Check if configured
   cat ~/.mynodeone/config.env | grep VPS_EDGE_IP
   ```

---

## 🚀 Installation Process

### **Step 1: Run Installation Script**

#### **Immich (Photos)**
```bash
sudo ./scripts/apps/install-immich.sh
```

#### **Jellyfin (Media Server)**
```bash
sudo ./scripts/apps/install-jellyfin.sh
```

### **Step 2: Answer Configuration Questions**

The script will prompt for:

#### **Question 1: Subdomain**
```
Enter subdomain [default: immich]: photos
```

**Rules:**
- Lowercase only
- Alphanumeric and hyphens only
- Cannot start with hyphen
- Will be sanitized automatically

**Examples:**
- ✅ `photos`, `gallery`, `pics`, `my-photos`
- ❌ `Photos` (will be lowercased to `photos`)
- ❌ `-photos` (invalid, will use default)
- ❌ `photo$` (special chars removed → `photo`)

#### **Question 2: Public Domain** (Optional)
```
Configure public access? [Y/n]: y
Enter your public domain (e.g., curiios.com): curiios.com
```

**Note:** Press `n` to skip public access setup

### **Step 3: Wait for Installation**

Typical installation time: **2-3 minutes**

The script will:
1. ✅ Validate prerequisites
2. ✅ Create namespace
3. ✅ Configure storage
4. ✅ Deploy application
5. ✅ Wait for pods to start
6. ✅ Update local DNS
7. ✅ Configure VPS route (if requested)

---

## 🛡️ Error Handling

### **What The Scripts Check Automatically:**

#### **1. kubectl Available**
```
Error: kubectl not found. Please install Kubernetes first.
Run: sudo ./scripts/bootstrap-control-plane.sh
```

**Fix:** Install control plane first

#### **2. Cluster Accessible**
```
Error: Cannot connect to Kubernetes cluster.
Please ensure:
  • K3s is running: systemctl status k3s
  • KUBECONFIG is set: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**Fix:** 
```bash
# Check if K3s is running
sudo systemctl status k3s

# Set kubeconfig (if needed)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

#### **3. Storage Available**
```
Warning: Longhorn storage class not found.
Installation may fail without persistent storage.
Continue anyway? [y/N]:
```

**Fix:** Install Longhorn first (included in bootstrap-control-plane.sh)

#### **4. Invalid Subdomain**
```
Error: Invalid subdomain. Using default: immich
```

**Automatic Fix:** Script uses default subdomain

#### **5. VPS Not Reachable**
```
[ERROR] Cannot reach VPS at 100.101.92.95. Check Tailscale connection.
```

**Fix:**
```bash
# Check Tailscale status
tailscale status

# Ping VPS
ping 100.101.92.95
```

---

## 🔍 Validation After Installation

### **Check Pods Running**
```bash
# For Immich
kubectl get pods -n immich

# For Jellyfin
kubectl get pods -n jellyfin

# Expected: All pods should show "Running"
```

### **Check Service Has IP**
```bash
# For Immich
kubectl get svc -n immich immich-server

# For Jellyfin
kubectl get svc -n jellyfin jellyfin

# Expected: EXTERNAL-IP should show (e.g., 100.118.5.207)
```

### **Test Local Access**
```bash
# Replace <subdomain> with your chosen subdomain
curl -I http://<subdomain>.mynodeone.local

# Expected: HTTP/1.1 200 OK or HTTP/1.1 302 Found
```

### **Test Public Access** (If VPS Configured)
```bash
# Replace with your domain
curl -I https://<subdomain>.yourdomain.com

# Expected: HTTP/2 200 or HTTP/2 302
```

---

## 🔧 Edge Cases & Solutions

### **Edge Case 1: Pod Stuck in Pending**

**Symptom:**
```bash
kubectl get pods -n immich
# immich-server-xxx   0/1     Pending   0          5m
```

**Cause:** Not enough resources or storage

**Solution:**
```bash
# Check pod events
kubectl describe pod -n immich <pod-name>

# Check available storage
kubectl get pvc -n immich

# Check node resources
kubectl describe nodes
```

### **Edge Case 2: Pod CrashLoopBackOff**

**Symptom:**
```bash
kubectl get pods -n jellyfin
# jellyfin-xxx   0/1     CrashLoopBackOff   3          2m
```

**Cause:** Usually inotify limits (should be fixed by bootstrap script)

**Solution:**
```bash
# Check logs
kubectl logs -n jellyfin <pod-name>

# If inotify error, verify limits on control plane
kubectl debug node/<node-name> -it --image=alpine -- chroot /host cat /proc/sys/fs/inotify/max_user_instances

# Should be 1024, not 128
```

### **Edge Case 3: No LoadBalancer IP Assigned**

**Symptom:**
```bash
kubectl get svc -n immich
# immich-server   LoadBalancer   10.43.x.x   <pending>   80:30xxx/TCP
```

**Cause:** MetalLB not configured

**Solution:**
```bash
# Check MetalLB
kubectl get pods -n metallb-system

# Re-run control plane bootstrap if needed
sudo ./scripts/bootstrap-control-plane.sh
```

### **Edge Case 4: DNS Not Working Locally**

**Symptom:**
```bash
ping photos.mynodeone.local
# ping: cannot resolve photos.mynodeone.local
```

**Solution:**
```bash
# Re-run DNS update
sudo ./scripts/update-laptop-dns.sh

# Verify entry added
cat /etc/hosts | grep photos.mynodeone.local
```

### **Edge Case 5: VPS Shows 502 Bad Gateway**

**Symptom:** `https://photos.yourdomain.com` returns 502

**Cause:** VPS route misconfigured or service not reachable

**Solution:**
```bash
# Verify service is running
kubectl get svc -n immich immich-server

# Check VPS route
ssh root@<vps-ip> "cat /etc/traefik/dynamic/immich.yml"

# Should show: http://<control-plane-ip>:<nodeport>
# Example: http://100.118.5.68:30948

# Reconfigure if needed
sudo ./scripts/configure-vps-route.sh immich 80 photos yourdomain.com
```

### **Edge Case 6: Empty Subdomain Input**

**Symptom:** User enters special characters only (e.g., `!!!`)

**Automatic Fix:** Script sanitizes and falls back to default

### **Edge Case 7: Subdomain Starts with Hyphen**

**Symptom:** User enters `-photos`

**Automatic Fix:** Script detects and uses default

### **Edge Case 8: Very Long Subdomain**

**Symptom:** User enters 100 character subdomain

**Result:** Works, but DNS may have issues. Recommend keeping under 63 characters.

### **Edge Case 9: SSL Shows "TRAEFIK DEFAULT CERT"**

**Symptom:** Immediately after installation, HTTPS shows invalid certificate

**Cause:** Let's Encrypt needs 30-60 seconds to issue certificate (THIS IS NORMAL!)

**Expected Timeline:**
- **0-30 seconds:** "TRAEFIK DEFAULT CERT" (temporary)
- **30-60 seconds:** Let's Encrypt HTTP-01 challenge
- **60+ seconds:** Valid Let's Encrypt certificate

**Solution: WAIT!** This is automatic.

**If persists after 2 minutes:**
```bash
# Restart Traefik
ssh root@<vps-ip> "docker restart traefik"

# Wait 60 seconds
sleep 60

# Verify certificate
echo | openssl s_client -servername <subdomain>.curiios.com \
  -connect <subdomain>.curiios.com:443 2>/dev/null | \
  openssl x509 -noout -issuer

# Should show: issuer=C = US, O = Let's Encrypt
```

**Important:** Don't check certificate immediately after installation. Wait 2 minutes for Let's Encrypt to complete.

---

## 📊 Success Checklist

After installation, verify (in this order):

- [ ] All pods show `Running` status
- [ ] Service has LoadBalancer IP assigned
- [ ] Local DNS resolves: `ping <subdomain>.mynodeone.local`
- [ ] Local access works: `curl http://<subdomain>.mynodeone.local`
- [ ] (If VPS) Public DNS resolves: `nslookup <subdomain>.yourdomain.com`
- [ ] (If VPS) Public access works: `curl https://<subdomain>.yourdomain.com`
- [ ] (If VPS) **WAIT 2 MINUTES** for Let's Encrypt certificate
- [ ] (If VPS) SSL certificate valid: Check in browser (green padlock)

**⏱️ Important:** SSL certificates take 30-60 seconds to issue. Don't check immediately after installation!

---

## 🔄 Reinstallation

If you need to reinstall an app:

```bash
# Delete namespace (removes all data!)
kubectl delete namespace immich

# Wait for deletion to complete
kubectl get namespaces | grep immich
# Should return nothing

# Run installation script again
sudo ./scripts/apps/install-immich.sh
```

**Warning:** This deletes all data! Back up first if needed.

---

## 🎯 Quick Troubleshooting Commands

```bash
# Check all pods
kubectl get pods --all-namespaces

# Check services
kubectl get svc --all-namespaces

# Check persistent volumes
kubectl get pvc --all-namespaces

# Check storage class
kubectl get storageclass

# Check DNS entries
cat /etc/hosts | grep mynodeone.local

# Test VPS connectivity
ping <vps-ip>

# Check Traefik on VPS
ssh root@<vps-ip> "docker logs traefik --tail 50"
```

---

## 📚 Related Documentation

- [APP-STORE.md](../reference/APP-STORE.md) - Available applications
- [README-JELLYFIN.md](../../scripts/apps/README-JELLYFIN.md) - Jellyfin specific guide
- [HYBRID-TROUBLESHOOTING.md](HYBRID-TROUBLESHOOTING.md) - VPS & networking issues
- [DNS-SETUP-GUIDE.md](DNS-SETUP-GUIDE.md) - DNS configuration

---

## 💡 Best Practices

### **1. Test Locally First**
Always verify local access works before configuring public access.

### **2. Choose Descriptive Subdomains**
Use clear names like `photos`, `movies`, `vault` instead of cryptic abbreviations.

### **3. Monitor Resource Usage**
```bash
kubectl top nodes
kubectl top pods -n immich
```

### **4. Regular Backups**
Back up persistent volumes regularly, especially for critical apps.

### **5. Update DNS After Changes**
If you change subdomains or reinstall, run:
```bash
sudo ./scripts/update-laptop-dns.sh
```

---

## 🆘 Getting Help

If you encounter issues not covered here:

1. **Check logs:**
   ```bash
   kubectl logs -n <namespace> <pod-name>
   ```

2. **Describe resources:**
   ```bash
   kubectl describe pod -n <namespace> <pod-name>
   kubectl describe svc -n <namespace> <service-name>
   ```

3. **Check events:**
   ```bash
   kubectl get events -n <namespace> --sort-by='.lastTimestamp'
   ```

4. **Review documentation:**
   - Check app-specific README in `scripts/apps/`
   - Review troubleshooting guides in `docs/guides/`

---

**Your apps should install smoothly with zero manual fixes!** 🎉
