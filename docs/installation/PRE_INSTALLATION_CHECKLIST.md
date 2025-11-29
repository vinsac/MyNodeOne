# Pre-Installation Checklist for Clean Reinstall

## 🎯 **Objective**
Ensure a clean, enterprise-grade installation of MyNodeOne with all architectural fixes in place.

---

## ✅ **Pre-Installation Steps**

### **1. Pull Latest Code**
```bash
cd ~/MyNodeOne
git pull origin main
git log --oneline -5

# Verify you have these commits:
# - df9bf26: Phase 2: Update setup scripts
# - 785e220: Phase 1: Enterprise-grade registry
# - 0a9d64a: Fix duplicate HTTP headers
```

### **2. Clean Existing Installation (If Reinstalling)**

**On Control Plane:**
```bash
# Uninstall K3s
/usr/local/bin/k3s-uninstall.sh

# Clean configs
rm -rf ~/.mynodeone
rm -rf ~/.kube

# Keep MyNodeOne repo
cd ~/MyNodeOne && git pull
```

**On Management Laptop:**
```bash
# Clean configs
rm -rf ~/.mynodeone
rm -rf ~/.kube

# Keep MyNodeOne repo
cd ~/MyNodeOne && git pull
```

**On VPS:**
```bash
# Stop services
cd /etc/traefik && docker compose down

# Clean configs
rm -rf ~/.mynodeone
rm -rf /etc/traefik

# Keep MyNodeOne repo
cd ~/MyNodeOne && git pull
```

### **3. Verify Tailscale**

**On All Nodes:**
```bash
tailscale status
# Verify all nodes see each other
```

---

## 🚀 **Installation Order**

### **Step 1: Control Plane** (20-25 minutes)

```bash
cd ~/MyNodeOne
sudo ./scripts/mynodeone

# Selections:
# - Node type: 1 (Control Plane)
# - Cluster name: universe (or your choice)
# - Domain: minicloud (or your choice)
# - VPS count: 2 (or your count)
# - Plan to run LLMs: y
# - Plan to run databases: y
# - Deploy demo app: y
# - Deploy LLM chat: y (optional)
# - Optional security: y
```

**Critical Validation Points:**

1. **Registry Initialization**
   ```
   ✓ service-registry ConfigMap exists
   ✓ domain-registry ConfigMap exists
   ✓ sync-controller-registry ConfigMap exists
   ✓ All registries initialized successfully
   ```

2. **Service Registration**
   ```
   ✓ Registered: grafana → 100.x.x.x
   ✓ Registered: argocd → 100.x.x.x
   ✓ Registered: minio → 100.x.x.x
   ✓ Registered: longhorn → 100.x.x.x
   ✓ Registered: minicloud → 100.x.x.x
   ✓ Registered: demo → 100.x.x.x
   ```

3. **Verify ConfigMaps**
   ```bash
   # Check sync-controller-registry was created
   kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq
   
   # Expected: Empty arrays with metadata
   {
     "management_laptops": [],
     "vps_nodes": [],
     "worker_nodes": [],
     "metadata": {
       "version": "1.0",
       "last_updated": "2025-11-09T...",
       "updated_by": "vinaysachdeva@canada-pc-0001"
     }
   }
   ```

**❌ Stop If:**
- Any registry ConfigMap missing
- Service registration failed
- Validation shows errors

---

### **Step 2: Management Laptop** (5-10 minutes)

```bash
cd ~/MyNodeOne
sudo ./scripts/mynodeone

# Selections:
# - Node type: 4 (Management Workstation)
# - Control plane IP: 100.76.150.5
# - SSH username: vinaysachdeva
```

**Critical Validation Points:**

1. **User Detection**
   ```
   Detected localhost - using current user: vinay
   ```
   ❌ Should NOT say "root"!

2. **Registration Validation**
   ```
   ✓ Registration verified in ConfigMap
   ✓ Registered with user: vinay
   ```

3. **Verify Registration**
   ```bash
   kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq '.management_laptops'
   
   # Expected:
   [
     {
       "ip": "100.86.112.112",
       "name": "vinay-vivobook",
       "ssh_user": "vinay",  # ← MUST be your actual user, NOT root!
       "webhook_port": 8080,
       "registered": "2025-11-09T...",
       "last_sync": null,
       "status": "active"
     }
   ]
   ```

**❌ Stop If:**
- ssh_user shows "root" instead of your actual username
- Registration not verified in ConfigMap
- kubectl not working

---

### **Step 3: VPS Edge Node** (10-15 minutes)

```bash
ssh root@<vps-public-ip>
cd ~/MyNodeOne || (git clone https://github.com/vinsac/MyNodeOne.git && cd MyNodeOne)
git pull origin main

sudo ./scripts/mynodeone

# Selections:
# - Node type: 3 (VPS Edge Node)
# - Domain: curiios.com
# - Control plane IP: 100.76.150.5
# - SSH username: vinaysachdeva
```

**Critical Validation Points:**

1. **User Detection**
   ```
   Detected VPS user: root
   ```
   ✓ This is correct for VPS!

2. **Registration Validation**
   ```
   ✓ Domain registration verified in ConfigMap
   ✓ VPS registration verified in ConfigMap
   ✓ Registered with user: root
   ```

3. **Verify Domain Registration**
   ```bash
   kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' | jq
   
   # Expected:
   {
     "curiios.com": {
       "registered": "2025-11-09T...",
       "description": "VPS edge node domain"
     }
   }
   ```

4. **Verify VPS Registration**
   ```bash
   kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq '.vps_nodes'
   
   # Expected:
   [
     {
       "ip": "100.105.188.46",
       "name": "vmi2161443",
       "ssh_user": "root",  # ← Correct for VPS
       "webhook_port": 8080,
       "registered": "2025-11-09T...",
       "last_sync": null,
       "status": "active"
     }
   ]
   ```

5. **Verify VPS Can Reach LoadBalancer**
   ```bash
   # From VPS
   curl -I http://100.76.150.207:80
   
   # Expected: HTTP/1.1 200 OK
   ```

**❌ Stop If:**
- Domain not in domain-registry
- VPS not in sync-controller-registry
- VPS can't reach LoadBalancer IPs (check Tailscale routes)
- Sync script not installed

---

### **Step 4: Make Demo App Public** (2-3 minutes)

```bash
# From management laptop
cd ~/MyNodeOne
sudo ./scripts/manage-app-visibility.sh

# Selections:
# - Service: 6 (demo)
# - Action: 1 (Make public)
# - Domains: 1 (curiios.com)
# - VPS: 1 (100.105.188.46)
```

**Critical Validation Points:**

1. **Sync Success**
   ```
   [✓] Sync complete: 1 succeeded, 0 failed
   ```
   ❌ Should NOT say "0 succeeded"!

2. **ConfigMap Preservation**
   ```bash
   # Check ALL three fields still present
   kubectl get cm domain-registry -n kube-system -o jsonpath='{.data}' | jq 'keys'
   
   # Expected:
   [
     "domains.json",
     "routing.json",
     "vps-nodes.json"
   ]
   
   # If ANY field is missing, ConfigMap overwrite bug is back!
   ```

3. **Routing Configuration**
   ```bash
   kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.routing\.json}' | jq
   
   # Expected:
   {
     "demo": {
       "domains": ["curiios.com"],
       "vps_nodes": ["100.105.188.46"],
       "strategy": "round-robin",
       "updated": "2025-11-09T..."
     }
   }
   ```

4. **Routes on VPS**
   ```bash
   ssh root@<vps-ip> "cat /etc/traefik/dynamic/mynodeone-routes.yml"
   
   # Expected:
   # - demo-curiios-com router
   # - Backend URL: http://100.76.150.207:80 (LoadBalancer IP)
   # - No duplicate "http:" headers
   ```

5. **Public Access**
   ```bash
   curl -I http://demo.curiios.com
   # Expected: HTTP/1.1 308 Permanent Redirect → https
   
   curl -I https://demo.curiios.com
   # Expected: HTTP/2 200 (after SSL cert issued, ~5 min)
   ```

**❌ Stop If:**
- Sync shows "0 succeeded"
- Any domain-registry field is missing
- Routes not on VPS
- Public access returns 502/404

---

## 🧪 **Post-Installation Validation**

### **Registry Consistency Check**

```bash
# All commands from management laptop

echo "=== 1. Check All Registries Exist ==="
kubectl get cm -n kube-system | grep -E "service-registry|domain-registry|sync-controller-registry"

echo "=== 2. Verify Management Laptop User ==="
kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq -r '.management_laptops[].ssh_user'
# Expected: YOUR USERNAME (not root!)

echo "=== 3. Verify VPS User ==="
kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq -r '.vps_nodes[].ssh_user'
# Expected: root

echo "=== 4. Check Domain Registered ==="
kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' | jq 'has("curiios.com")'
# Expected: true

echo "=== 5. Verify All Fields Preserved ==="
kubectl get cm domain-registry -n kube-system -o jsonpath='{.data}' | jq 'keys'
# Expected: ["domains.json", "routing.json", "vps-nodes.json"]
```

### **Multi-Service Test (ConfigMap Preservation)**

```bash
# Deploy second app
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=LoadBalancer

# Wait for IP
kubectl get svc nginx -w

# Register
./scripts/lib/service-registry.sh register nginx nginx default nginx 80 false

# Make public
sudo ./scripts/manage-app-visibility.sh
# Select nginx → Make public → curiios.com → VPS

# CRITICAL TEST: Check BOTH services preserved
kubectl get cm service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq 'keys'
# Expected: ["demo", "nginx"]
# ❌ FAIL if only ["nginx"] - demo was overwritten!

kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.routing\.json}' | jq 'keys'
# Expected: ["demo", "nginx"]
# ❌ FAIL if only ["nginx"] - demo routing was overwritten!
```

---

## ✅ **Success Criteria**

### **Must Pass:**
- [x] All 3 registry ConfigMaps exist
- [x] Management laptop registered with correct user (not root)
- [x] VPS registered with root user
- [x] Domain registered in domain-registry
- [x] All domain-registry fields preserved after operations
- [x] Sync succeeds with "1 succeeded, 0 failed"
- [x] Routes appear on VPS with correct LoadBalancer IPs
- [x] demo.curiios.com accessible publicly
- [x] Multiple services coexist without overwriting each other

### **Performance Targets:**
- Installation time: < 45 minutes total
- Zero password prompts after initial setup
- All validations pass automatically
- No manual ConfigMap edits required

---

## 🚨 **Common Issues & Fixes**

### **Issue: "0 succeeded" during sync**
**Cause:** Registry not synced or nodes not registered  
**Fix:**
```bash
# Check registry
kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' | jq

# If empty, re-register nodes
./scripts/lib/node-registry-manager.sh register vps_nodes 100.105.188.46 vps1 root
```

### **Issue: Management laptop shows ssh_user: "root"**
**Cause:** Old registration or script error  
**Fix:**
```bash
# Re-register with correct user
kubectl delete cm sync-controller-registry -n kube-system
./scripts/lib/node-registry-manager.sh init
./scripts/lib/node-registry-manager.sh register management_laptops 100.86.112.112 laptop1 vinay
```

### **Issue: ConfigMap field missing after operation**
**Cause:** ConfigMap overwrite bug (should be fixed)  
**Fix:**
```bash
# Check git commits
git log --oneline | head -5
# Must have: df9bf26 (Phase 2) and 785e220 (Phase 1)

# If missing, pull latest
git pull origin main
```

### **Issue: VPS can't reach LoadBalancer IPs**
**Cause:** Tailscale routes not accepted  
**Fix:**
```bash
# On VPS
tailscale up --accept-routes --accept-dns=false
curl -I http://100.76.150.207:80
```

---

## 📊 **Expected Timeline**

| Phase | Duration | Critical? |
|-------|----------|-----------|
| Control Plane Install | 20-25 min | ✅ Yes |
| Management Laptop | 5-10 min | ✅ Yes |
| VPS Setup | 10-15 min | ✅ Yes |
| Make App Public | 2-3 min | ✅ Yes |
| SSL Certificate | 5-10 min | ⏱️ Automatic |
| **Total** | **45-60 min** | |

---

## 🎯 **Ready to Install?**

If you've completed all pre-installation steps and understand the validation points, you're ready to proceed!

```bash
# Start with control plane
cd ~/MyNodeOne
sudo ./scripts/mynodeone
```

**Good luck! 🚀**

---

**Document Last Updated:** 2025-11-09  
**For:** Clean reinstall with Phase 1 & 2 fixes  
**Critical Commits:** df9bf26, 785e220, 0a9d64a
