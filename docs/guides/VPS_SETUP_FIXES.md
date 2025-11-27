# VPS Setup Fixes - Complete Guide

## 🎯 Issues Fixed

### Issue 1: Domain Registry Structure Inconsistency
**Symptom:** Domain selector showed "domains", "vps_nodes", "curiios.com" instead of just "curiios.com"

**Root Cause:**
- Registry had mixed structure:
  ```json
  {
    "domains": {},           ← Empty, should contain domains
    "vps_nodes": [],         ← Being read as a domain name!
    "curiios.com": {...}     ← Domain at root level (wrong!)
  }
  ```

**Fixed Structure:**
```json
{
  "domains": {
    "curiios.com": {...}     ← Domain inside "domains" object ✅
  },
  "vps_nodes": [
    {
      "tailscale_ip": "100.86.188.1",
      "public_ip": "45.8.133.192",
      "location": "contabo-germany"
    }
  ]
}
```

---

### Issue 2: SSH Authentication Failing
**Symptom:** manage-app-visibility.sh asked for password repeatedly and failed

**Root Cause:**
- Scripts run with `sudo` → use **root's** SSH credentials
- During VPS setup, only **user** SSH keys were configured
- Root had no SSH key to VPS

**Fixed:**
- Auto-generate SSH keys for **both** user and root on control plane
- Copy both keys to VPS during installation
- Validate both work before completing setup

---

## 🔧 What Changed

### 1. `scripts/lib/multi-domain-registry.sh`
```bash
# OLD: Domain registered at root level
'.[$domain] = {...}'

# NEW: Domain registered in nested structure
'.domains[$domain] = {...}'

# NEW: Auto-migration from old format
if ! has("domains"); then
    migrate to: {domains: ., vps_nodes: []}
fi
```

### 2. `scripts/manage-app-visibility.sh`
```bash
# OLD: Read all keys as domains (broken!)
jq 'keys[]'

# NEW: Read only from .domains object
jq '.domains | keys[]'

# OLD: Read VPS from separate ConfigMap key
jsonpath='{.data.vps-nodes\.json}'

# NEW: Read VPS from unified structure
jq '.vps_nodes[] | .tailscale_ip'
```

### 3. `scripts/setup-vps-node.sh`

**Added: Automatic Root SSH Key Setup**
```bash
# Ensure root on control plane has SSH key
if ! sudo test -f /root/.ssh/id_ed25519; then
    sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''
fi

# Copy BOTH user and root keys to VPS
echo '=== ROOT KEY ==='
sudo cat /root/.ssh/id_ed25519.pub
echo '=== USER KEY ==='
cat ~/.ssh/id_ed25519.pub
```

**Added: Comprehensive Validation**
```bash
# Validate registry structure
has("domains") and has("vps_nodes")

# Validate SSH for BOTH user and root
ssh user@vps 'echo OK'        # User access
sudo ssh user@vps 'echo OK'   # Root access (used by scripts)

# Final end-to-end test
sudo ssh -o BatchMode=yes sammy@100.86.188.1 'echo OK'
```

---

## 🚀 Upgrade Path

### Option 1: Quick Fix (Current Installation)
Your current installation is already fixed! The manual fixes we did:
- ✅ Fixed domain registry structure
- ✅ Set up root SSH keys

**No action needed!** You can continue using it.

---

### Option 2: Clean Reinstall (Recommended for Testing)
This will verify all fixes work end-to-end from scratch.

**On Control Plane:**
```bash
cd ~/MyNodeOne
git pull origin main

# Should show: ea7173a Fix critical VPS setup issues
git log --oneline -1
```

**On VPS:**
```bash
cd ~/MyNodeOne
git pull origin main

# Clean uninstall
sudo ./scripts/uninstall-mynodeone.sh --full --yes

# Reinstall with fixed scripts
sudo ./scripts/mynodeone
# Select: 3 (VPS Edge Node)
# Enter domain: curiios.com
```

**What You'll See (Improved):**
```
[INFO] Running as user: sammy (via sudo)              ← Correct! ✅
✓ Using actual user 'sammy' for SSH access

[INFO] Setting up reverse SSH access...
Generating SSH key for root (used by scripts)...      ← NEW! ✅
✓ Added root SSH key from control plane               ← NEW! ✅
✓ Added vinaysachdeva SSH key from control plane

[INFO] Validating registry structure...
✓ Registry structure validated (unified format)       ← NEW! ✅

🔐 Final SSH Connectivity Check                        ← NEW! ✅
✅ Root SSH works (scripts will run without password prompts)

Select domains:
  1. curiios.com                                       ← Only shows actual domain! ✅
```

---

## 📋 New Validations

The following checks now run during installation:

### 1. **User Detection Validation**
```
✓ Running as user: sammy (via sudo)
✓ Using actual user 'sammy' for SSH access (not root)
```

### 2. **SSH Key Setup Validation**
```
✓ Added root SSH key from control plane
✓ Added vinaysachdeva SSH key from control plane
✓ Bidirectional SSH verified (user ✓, root ✓)
```

### 3. **Registry Structure Validation**
```
✓ Domain registration verified in ConfigMap
✓ Registry structure validated (unified format)
```

### 4. **Final End-to-End Test**
```
🔐 Final SSH Connectivity Check
[INFO] Testing end-to-end SSH (required for route sync)...
[INFO] This simulates what manage-app-visibility.sh will do...
SSH test from root@control-plane to sammy@VPS successful
✅ Root SSH works (scripts will run without password prompts)
```

---

## 🎯 Expected Behavior After Fixes

### manage-app-visibility.sh
**Before:**
```
Select domains:
  1. curiios.com
  2. domains        ← Wrong!
  3. vps_nodes      ← Wrong!

sammy@100.86.188.1's password: [enter password]
sammy@100.86.188.1's password: [enter password]  ← Keeps asking!
sammy@100.86.188.1's password: [enter password]
[⚠] Attempt 3/3 failed
```

**After:**
```
Select domains:
  1. curiios.com    ← Only actual domain! ✅

[INFO] Pushing sync to 100.86.188.1...
[✓] Synced: 100.86.188.1  ← No password prompt! ✅
```

---

## 🧪 How to Test

### Test 1: Domain Selection
```bash
sudo ./scripts/manage-app-visibility.sh
# Should only show: curiios.com (no "domains", "vps_nodes")
```

### Test 2: SSH Connectivity
```bash
# On control plane
sudo ssh -o BatchMode=yes sammy@100.86.188.1 'echo OK'
# Should output: OK (no password prompt)
```

### Test 3: Route Sync
```bash
sudo ./scripts/lib/sync-controller.sh push
# Should complete without password prompts
```

---

## 📊 Comparison: Before vs After

| Aspect | Before | After |
|--------|--------|-------|
| **Domain List** | Shows structural keys | Only actual domains ✅ |
| **SSH Setup** | Manual, user-only | Automated, user + root ✅ |
| **Password Prompts** | Every sync operation | Never ✅ |
| **Structure Validation** | None | Comprehensive ✅ |
| **Error Detection** | After failure | During install ✅ |
| **Fix Guidance** | Unclear | Clear commands ✅ |

---

## 🎉 Summary

**Both issues are now:**
- ✅ **Root caused** - Architectural inconsistencies identified
- ✅ **Fixed** - Scripts updated with proper logic
- ✅ **Validated** - Comprehensive checks during installation
- ✅ **Tested** - Manual fixes verified on your system
- ✅ **Documented** - Clear upgrade path and testing guide

**Your current installation works!** But a clean reinstall will verify all fixes work end-to-end from scratch and give you confidence for future deployments.

**Commit:** `ea7173a` - Fix critical VPS setup issues: registry structure & SSH automation
