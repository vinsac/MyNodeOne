# VPS Fresh Installation Guide

**Purpose:** Complete clean slate for VPS reinstallation  
**When to use:** Testing, troubleshooting, or fresh deployments  
**Time:** 5-10 minutes

---

## 🎯 **Overview**

This guide walks you through a **complete fresh installation** of MyNodeOne on a VPS, including:
- ✅ Removing old MyNodeOne installation
- ✅ Disconnecting from Tailscale (optional but recommended)
- ✅ Reconnecting to Tailscale with clean state
- ✅ Fresh MyNodeOne installation
- ✅ Verification tests

---

## 📋 **Prerequisites**

Before starting, ensure you have:
- [ ] SSH access to VPS (via public IP or existing Tailscale)
- [ ] SSH access to control plane
- [ ] VPS public IP address
- [ ] Control plane Tailscale IP (e.g., 100.67.210.15)
- [ ] Latest MyNodeOne code on VPS

---

## 🚀 **Method 1: Complete Fresh Install (Recommended)**

### **Step 1: Access VPS**

```bash
# Use public IP to access VPS (not Tailscale)
ssh sammy@<VPS_PUBLIC_IP>

# Example:
ssh sammy@45.8.133.192
```

### **Step 2: Update MyNodeOne Code**

```bash
cd ~/MyNodeOne
git pull origin main

# Verify you have latest fixes
git log --oneline -5
# Should show recent commits including SSH fixes
```

### **Step 3: Complete Uninstall (Including Tailscale)**

```bash
# Remove EVERYTHING including Tailscale connection
sudo ./scripts/uninstall-mynodeone.sh --full --remove-tailscale --yes

# This will:
# ✅ Remove all MyNodeOne components
# ✅ Remove Kubernetes cluster
# ✅ Remove config files
# ✅ Disconnect from Tailscale network
# ✅ Clean up registries and caches
```

### **Step 4: Verify Clean State**

```bash
# Check MyNodeOne removed
ls -la ~/.mynodeone/          # Should not exist
docker ps                     # Should be empty
kubectl get nodes 2>&1        # Should fail

# Check Tailscale disconnected
tailscale status              # Should show "not running" or "logged out"
```

### **Step 5: Reconnect to Tailscale**

```bash
# Start Tailscale (if package removed, reinstall first)
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Connect to your Tailnet
sudo tailscale up

# This will show a URL like:
# https://login.tailscale.com/a/xxxxx
# Open in browser and authenticate

# Wait a few seconds, then verify
tailscale status

# Should show your devices including control plane
# Example:
# canada-pc      vinaysachdeva@  100.67.210.15  ...
# vmi2161443     sammy@          100.93.144.102 ...
```

### **Step 6: Verify Tailscale Connectivity**

```bash
# Ping control plane
ping -c 2 100.67.210.15
# Should get responses

# Test SSH (will ask for password, that's OK)
ssh -o ConnectTimeout=5 vinaysachdeva@100.67.210.15 'echo OK'
# Should print: OK (after entering password)

# If timeout, troubleshoot Tailscale before proceeding
```

### **Step 7: Run Fresh Installation**

```bash
cd ~/MyNodeOne
sudo ./scripts/mynodeone

# Select: 3 (VPS Edge Node)
# Enter domain: your-domain.com
# Control plane IP: 100.67.210.15
# SSH user: vinaysachdeva
```

### **Step 8: During Installation - Password Prompts**

You'll be prompted for passwords **twice**:

```bash
# Prompt 1: SSH password (initial connection test)
vinaysachdeva@100.67.210.15's password: [ENTER PASSWORD]

# Prompt 2: Sudo password (SSH key generation)
[sudo] password for vinaysachdeva: [ENTER PASSWORD]

# Then everything proceeds automatically
```

### **Step 9: Watch for Success Indicators**

```bash
✅ Expected success messages:

[✓] SSH connection successful
[✓] Kubeconfig retrieved
[✓] Cluster info retrieved
[✓] Added root SSH key from control plane
[✓] Added vinaysachdeva SSH key from control plane
✅ Root SSH works (scripts will run without password prompts)
✓ VPS node registration complete! 🎉
```

---

## 🚀 **Method 2: Quick Fresh Install (Keep Tailscale)**

If Tailscale is working fine and you just want to reinstall MyNodeOne:

### **All-in-One Commands:**

```bash
# SSH to VPS
ssh sammy@<VPS_PUBLIC_IP>

# Update, uninstall (keep Tailscale), reinstall
cd ~/MyNodeOne && \
git pull origin main && \
sudo ./scripts/uninstall-mynodeone.sh --full --yes && \
sudo ./scripts/mynodeone
```

---

## ✅ **Post-Installation Verification**

After installation completes, verify everything works:

### **On Control Plane:**

```bash
# SSH to control plane
ssh vinaysachdeva@100.67.210.15

# Test 1: Check registries
kubectl get cm domain-registry -n kube-system \
  -o jsonpath='{.data.domains\.json}' | jq 'keys'
# Expected: ["domains", "vps_nodes"]

# Test 2: Root SSH to VPS (CRITICAL)
sudo ssh -o BatchMode=yes sammy@100.93.144.102 'echo OK'
# Expected: OK (no password prompt!)

# Test 3: Run manage-app-visibility.sh
cd ~/MyNodeOne
sudo ./scripts/manage-app-visibility.sh
# Expected: No password prompts, shows your domain
```

---

## 🐛 **Troubleshooting**

### **Issue 1: Tailscale Connection Timeout**

**Symptom:**
```
ssh: connect to host 100.67.210.15 port 22: Connection timed out
```

**Fix:**
```bash
# On VPS, check Tailscale status
tailscale status

# If not connected
sudo tailscale up

# Verify control plane is visible
tailscale status | grep canada-pc
```

---

### **Issue 2: SSH Password Prompt Not Showing**

**Symptom:**
```
[⚠] Passwordless SSH failed, you may be prompted for password
[✗] Cannot connect to control plane  (No password prompt shown)
```

**Fix:**
- Ensure you have latest code (commit cf9f594 or later)
- Verify Tailscale connectivity first
- Try SSH manually: `ssh vinaysachdeva@100.67.210.15`

---

### **Issue 3: Root SSH Still Asks for Passwords**

**Symptom:**
```
❌ Root SSH FAILED
```

**Fix:**
Follow the on-screen manual SSH setup instructions, or see `docs/VPS_PRE_INSTALLATION_SSH_SETUP.md`

---

## 📊 **Fresh Installation Timeline**

| Step | Description | Time | User Action |
|------|-------------|------|-------------|
| 1-2 | Access VPS, update code | 1 min | SSH + git pull |
| 3 | Uninstall | 2-3 min | Run command, wait |
| 4 | Verify clean state | 30 sec | Check commands |
| 5-6 | Reconnect Tailscale | 1-2 min | Auth in browser |
| 7 | Start installation | 1 min | Answer prompts |
| 8 | Enter passwords | 30 sec | Type passwords (2x) |
| 9 | Wait for completion | 3-5 min | Watch output |
| 10 | Verify | 1 min | Test commands |
| **Total** | | **10-15 min** | Mostly automated |

---

## ✅ **Success Checklist**

Installation is successful when ALL of these are true:

- [ ] VPS uninstalled cleanly (no errors)
- [ ] Tailscale connected (can ping control plane)
- [ ] Installation completed without errors
- [ ] Domain registered in cluster
- [ ] VPS registered in cluster
- [ ] Root SSH works without password
- [ ] manage-app-visibility.sh works without password
- [ ] Can push routes to VPS successfully

---

## 🎯 **Key Commands Reference**

### **Complete Fresh Install:**
```bash
sudo ./scripts/uninstall-mynodeone.sh --full --remove-tailscale --yes
sudo tailscale up
sudo ./scripts/mynodeone
```

### **Quick Reinstall (Keep Tailscale):**
```bash
sudo ./scripts/uninstall-mynodeone.sh --full --yes
sudo ./scripts/mynodeone
```

### **Verification:**
```bash
# On control plane
sudo ssh -o BatchMode=yes sammy@100.93.144.102 'echo OK'
sudo ./scripts/manage-app-visibility.sh
```

---

## 📚 **Related Documentation**

- `VPS_INSTALLATION_TEST_GUIDE.md` - Detailed testing procedures
- `VPS_PRE_INSTALLATION_SSH_SETUP.md` - Optional SSH pre-setup
- `READY_FOR_REINSTALL.md` - Pre-installation checklist
- `VPS_SETUP_FIXES.md` - Technical details of fixes

---

## 💡 **Tips**

1. **Use Public IP for Initial Access**
   - Don't rely on Tailscale when doing fresh install
   - Access VPS via public IP first

2. **Verify Tailscale Before Installation**
   - `ping 100.67.210.15` should work
   - SSH should connect (even if asking for password)

3. **Watch for Password Prompts**
   - You should see 2 password prompts during install
   - If you don't, something is wrong

4. **Manual Fallback is OK**
   - If automation fails, follow on-screen instructions
   - Manual SSH setup takes 5 minutes

5. **Test After Installation**
   - Always verify root SSH works
   - Always test manage-app-visibility.sh
   - Catch issues early!

---

**Ready for fresh installation?** Start with Method 1, Step 1! 🚀
