# VPS Installation Test Guide

**Date:** 2025-11-09  
**Purpose:** Test automated VPS installation with SSH automation fixes  
**Latest Commits:** e550999 (SSH fix) + 2578b04 (manual fallback)

---

## 🎯 **Testing Strategy**

We're testing the **automated** VPS installation workflow with two important improvements:

1. **Commit e550999:** Fixed remote sudo requiring PTY (`-t` flag)
2. **Commit 2578b04:** Added comprehensive manual SSH setup instructions as fallback

---

## 📋 **Pre-Test Checklist**

### **On VPS**
```bash
# 1. SSH to VPS
ssh sammy@100.93.144.102

# 2. Pull latest code
cd ~/MyNodeOne
git pull origin main

# 3. Verify you have both fixes
git log --oneline -3
# Should show:
# 2578b04 Enhance VPS setup with comprehensive manual SSH fallback
# e550999 CRITICAL FIX: Enable interactive sudo for SSH key generation
# 54cb643 Add final reinstall checklist

# 4. Clean uninstall
sudo ./scripts/uninstall-mynodeone.sh --full --yes

# 5. Verify complete removal
ls -la ~/.mynodeone/  # Should not exist
docker ps             # Should be empty
kubectl get pods 2>&1 # Should fail (no kubectl)
```

---

## 🚀 **Test Procedure**

### **Step 1: Start Installation**

```bash
# On VPS
cd ~/MyNodeOne
sudo ./scripts/mynodeone

# Select: 3 (VPS Edge Node)
# Enter domain: curiios.com
# Control plane IP: 100.67.210.15
# SSH user: vinaysachdeva
```

---

### **Step 2: Watch for NEW Success Indicators**

During installation, you should see these **NEW** messages:

```bash
# ✅ WHAT TO LOOK FOR:

[INFO] Setting up SSH key authentication...
[INFO] Configuring passwordless SSH between VPS and control plane...

# When it runs remote sudo, you SHOULD see:
[sudo] password for vinaysachdeva:  ← Enter password HERE

# Then you should see:
Generating SSH key for root (used by scripts)...
=== ROOT KEY ===
=== USER KEY ===
[✓] Added root SSH key from control plane
[✓] Added vinaysachdeva SSH key from control plane

# At the end:
🔐 Final SSH Connectivity Check
[INFO] Testing end-to-end SSH (required for route sync)...
✅ Root SSH works (scripts will run without password prompts)  ← SUCCESS!
```

---

### **Step 3A: If Automation Works ✅**

You should see:
```
✅ Root SSH works (scripts will run without password prompts)
✓ VPS node registration complete! 🎉
```

**Proceed to Step 4**

---

### **Step 3B: If Automation Fails ❌**

You will see comprehensive manual instructions:

```
❌ Root SSH FAILED - manage-app-visibility.sh will ask for passwords

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🔧 MANUAL SSH SETUP REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[Step-by-step instructions with copy-paste commands]
```

**Follow the on-screen instructions exactly**, then proceed to Step 4.

---

## 🧪 **Step 4: Post-Installation Verification**

After installation completes (whether automated or manual), run these tests:

### **Test 1: Verify Registry Structure**

```bash
# On control plane
ssh vinaysachdeva@100.67.210.15

# Check domain registry
kubectl get cm domain-registry -n kube-system \
  -o jsonpath='{.data.domains\.json}' | jq 'keys'
# Expected: ["domains", "vps_nodes"]

# Check domain exists
kubectl get cm domain-registry -n kube-system \
  -o jsonpath='{.data.domains\.json}' | jq '.domains | keys[]'
# Expected: "curiios.com"

# Check VPS registered
kubectl get cm domain-registry -n kube-system \
  -o jsonpath='{.data.domains\.json}' | jq '.vps_nodes | length'
# Expected: 1
```

---

### **Test 2: Verify SSH Works Without Passwords**

```bash
# Still on control plane

# Test user SSH
ssh -o BatchMode=yes sammy@100.93.144.102 'echo "✓ User SSH works"'
# Expected: ✓ User SSH works (no password)

# Test root SSH (CRITICAL)
sudo ssh -o BatchMode=yes sammy@100.93.144.102 'echo "✓ Root SSH works"'
# Expected: ✓ Root SSH works (no password)
```

---

### **Test 3: Test manage-app-visibility.sh**

```bash
# Still on control plane
cd ~/MyNodeOne
sudo ./scripts/manage-app-visibility.sh

# Expected behavior:
# 1. NO password prompts
# 2. Shows only "curiios.com" in domain list
# 3. Can select domain and push routes without errors
```

---

## 📊 **Test Results Documentation**

### **Scenario 1: Automation Success ✅**

What you saw:
- [ ] Sudo password prompt appeared during installation
- [ ] "Generating SSH key for root..." message
- [ ] "✓ Added root SSH key from control plane"
- [ ] "✅ Root SSH works" at the end
- [ ] No password prompts in manage-app-visibility.sh

**Conclusion:** SSH automation works! The fix (e550999) resolved the PTY issue.

---

### **Scenario 2: Automation Failed, Manual Worked ⚠️**

What you saw:
- [ ] "❌ Root SSH FAILED" message
- [ ] Comprehensive manual instructions displayed
- [ ] Followed manual steps on control plane
- [ ] SSH works after manual setup
- [ ] No password prompts in manage-app-visibility.sh

**Conclusion:** Automation needs more work, but manual fallback is excellent UX.

**Action Items:**
- Document what error occurred during automation
- Check if sudo password was entered correctly
- Check control plane sudo configuration (passwordless vs password-required)

---

### **Scenario 3: Both Failed ❌**

What you saw:
- [ ] "❌ Root SSH FAILED" message
- [ ] Followed manual steps but still asks for passwords

**Debugging:**
```bash
# On control plane
sudo -i

# Check if root key exists
ls -la /root/.ssh/id_ed25519*

# Check if root key is on VPS
ssh sammy@100.93.144.102 "grep 'root@control-plane' ~/.ssh/authorized_keys"

# Manual troubleshooting needed
```

---

## 🐛 **Common Issues & Solutions**

### **Issue 1: "sudo: a terminal is required"**

**Cause:** The `-t` flag isn't working or sudo requires password but can't prompt

**Solution:**
1. Check if control plane user has passwordless sudo
2. If not, the sudo password prompt should appear - enter it
3. If prompt doesn't appear, check SSH configuration

---

### **Issue 2: Root SSH still fails after manual setup**

**Cause:** Root key not properly copied to VPS

**Debug:**
```bash
# On control plane as root
sudo -i
cat /root/.ssh/id_ed25519.pub

# On VPS
cat ~/.ssh/authorized_keys | grep "root@control-plane"
# Should show the same key
```

**Fix:**
```bash
# On control plane
sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub -f sammy@100.93.144.102
```

---

### **Issue 3: Connection refused to VPS**

**Cause:** Tailscale IP not reachable

**Debug:**
```bash
# On control plane
tailscale status | grep 100.93.144.102
ping -c 2 100.93.144.102
```

**Fix:**
- Verify both nodes connected to Tailscale
- Check Tailscale subnet routes

---

## ✅ **Success Criteria**

Installation is successful if ALL of these pass:

- [ ] VPS installation completed without errors
- [ ] Domain registry has correct structure: `["domains", "vps_nodes"]`
- [ ] Domain "curiios.com" is registered in `.domains`
- [ ] VPS is registered in `.vps_nodes`
- [ ] User SSH works without password
- [ ] Root SSH works without password (CRITICAL)
- [ ] `manage-app-visibility.sh` runs without password prompts
- [ ] Routes can be pushed to VPS successfully

---

## 📝 **Report Template**

After testing, please provide this information:

```
VPS INSTALLATION TEST REPORT
============================

Test Date: [DATE]
VPS IP: 100.93.144.102
Control Plane IP: 100.67.210.15

INSTALLATION PHASE
------------------
[ ] Automated SSH setup succeeded
[ ] Automated SSH setup failed (used manual)
[ ] Neither worked

SSH AUTOMATION OBSERVATIONS
---------------------------
- Did sudo password prompt appear? [YES/NO]
- Was "Generating SSH key for root..." shown? [YES/NO]
- Were root keys added to VPS? [YES/NO]
- Did final SSH test pass? [YES/NO]

Error messages (if any):
[PASTE ANY ERRORS]

POST-INSTALLATION TESTS
-----------------------
- Registry structure: [PASS/FAIL]
- Domain registered: [PASS/FAIL]
- VPS registered: [PASS/FAIL]
- User SSH passwordless: [PASS/FAIL]
- Root SSH passwordless: [PASS/FAIL]
- manage-app-visibility.sh: [PASS/FAIL]

OVERALL RESULT
--------------
[ ] Complete Success - Everything automated
[ ] Partial Success - Manual setup needed
[ ] Failed - Needs debugging

NOTES
-----
[Any additional observations]
```

---

## 🎯 **Next Steps Based on Results**

### **If Automation Worked:**
✅ Document the success
✅ Update READY_FOR_REINSTALL.md to confirm
✅ Consider this resolved

### **If Manual Fallback Worked:**
⚠️ Automation needs investigation, but user experience is good
⚠️ Document what failed and why
⚠️ Consider if we can detect and fix automatically

### **If Both Failed:**
❌ Need deeper debugging
❌ Check Tailscale connectivity
❌ Check SSH configuration on both nodes
❌ Check sudo configuration on control plane

---

**Ready to test?** Start with the Pre-Test Checklist! 🚀
