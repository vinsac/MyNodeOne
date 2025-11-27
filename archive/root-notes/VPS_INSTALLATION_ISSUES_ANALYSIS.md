# VPS Edge Node Installation Issues - Analysis & Fixes

## Summary of Issues Identified

### 1. ❌ Root SSH Authentication Problem
**Issue:** "[✗] Root SSH FAILED - manage-app-visibility.sh will ask for passwords"

**Root Cause:**
- When running scripts with `sudo`, SSH uses root's SSH keys (~/.ssh/id_rsa for root)
- The automated key setup copies the VPS user's key to control plane user's authorized_keys
- But scripts run with `sudo` need root's keys to be set up

**Why It's Required:**
- `manage-app-visibility.sh` runs with sudo and needs to SSH from control plane → VPS
- Without root SSH keys, every route sync requires password input

**Fix Required:**
- Add explicit root SSH key setup during VPS registration
- Or document that users must run scripts without sudo when possible
- Or configure passwordless sudo for the control plane user

---

### 2. ⚠️ Testing Root SSH
**Issue:** "Why is it testing root SSH?"

**Explanation:**
- The test simulates what `manage-app-visibility.sh` actually does
- That script runs with `sudo` on control plane, so it uses root's SSH keys
- This is a validation check to warn users early if automation won't work

**Is It Expected?** YES
- It's a useful pre-validation to catch SSH issues before they cause problems

---

### 3. 🔒 Passwordless Sudo Messages
**Issue:** "[INFO] Passwordless sudo not available - password required"

**Root Cause:**
- The interactive setup script fetches kubeconfig from control plane
- It checks if passwordless sudo is configured before attempting remote commands
- If not available, it properly prompts for password

**Is It Expected?** YES, IF:
- User hasn't run `setup-control-plane-sudo.sh` on control plane yet
- Or passwordless sudo wasn't configured during control plane setup

**Fix:**
- Control plane setup should offer to configure passwordless sudo earlier
- Or skip the message if password input is successful

---

### 4. 🔑 Multiple Password Prompts (~10 times)
**Issue:** "Had to put password for vinaysachdeva at least 10 times"

**Root Cause:**
The VPS setup script makes many SSH calls to the control plane:
1. Fetching cluster config
2. Registering in domain-registry ConfigMap (multiple operations)
3. Validating registration
4. Installing sync script
5. Each validation check

**Why It Happens:**
- No SSH connection multiplexing configured
- Each SSH command is a separate connection requiring authentication
- Without passwordless sudo OR SSH keys, each needs password

**Fixes Needed:**
1. **SSH ControlMaster** - Reuse connections:
```bash
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h:%p -o ControlPersist=600
```

2. **Batch operations** - Combine multiple kubectl operations into single SSH session

3. **Early validation** - Check SSH setup before proceeding with installation

---

### 5. 🔐 Reverse SSH Verification Failed
**Issue:** "[⚠] ⚠ Reverse SSH verification failed"

**Root Cause:**
- SSH host key for VPS (100.81.223.84) not in control plane's known_hosts
- First connection prompts for host key acceptance
- Script cannot accept it automatically

**Why It Failed:**
- Security feature: SSH requires manual acceptance of new host keys
- The script tries `ssh -o BatchMode=yes` which fails if host key unknown

**Is It Expected?** YES - This is a security feature
- SSH should never auto-accept unknown hosts without user confirmation

**Fix Applied in Current Version:**
The script already handles this with:
- Detection of the failure
- Clear instructions for manual fix
- Prompt to verify after fix

**Better Fix:**
Add host key acceptance earlier in setup:
```bash
ssh -o StrictHostKeyChecking=accept-new user@host 'echo OK'
```

---

### 6. 📋 SSH Host Key Should Be Accepted Early
**Issue:** "User had to run the SSH command during installation as an error"

**Agreed - This Should Be Improved**

**Current Flow:**
1. Setup progresses
2. Reverse SSH fails
3. User manually fixes
4. Setup continues

**Better Flow:**
1. Early check for SSH connectivity
2. Prompt user to accept host key if needed
3. Continue only after verification
4. Setup proceeds smoothly

**Implementation:**
```bash
early_ssh_setup() {
    echo "Testing SSH connectivity..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 user@host 'echo OK' 2>/dev/null; then
        echo "First-time connection to this host. Accept host key?"
        ssh -o StrictHostKeyChecking=accept-new user@host 'echo "✓ SSH setup complete"'
    fi
}
```

---

### 7. ❓ CONTROL_PLANE_IP Not Set
**Issue:** "[✗] CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"

**Analysis:**
Looking at the logs, the config was saved during interactive setup:
```
✓ Configuration saved to: /home/sammy/.mynodeone/config.env
```

But later:
```
[✗] CONTROL_PLANE_IP not set in ~/.mynodeone/config.env
```

**Possible Causes:**
1. The sync script runs as a different user (root via sudo)
2. It's looking in the wrong home directory
3. The variable name mismatch (CONTROL_PLANE_IP vs something else)

**Investigation Needed:**
Check `sync-vps-routes.sh` - likely using `$HOME` instead of `$ACTUAL_HOME`

---

## Priority Fixes

### High Priority (Breaks Automation):
1. **Fix CONTROL_PLANE_IP not found** - Sync script can't work
2. **Reduce password prompts** - Use SSH ControlMaster
3. **Early SSH host key setup** - Better user experience

### Medium Priority (Documented Workarounds Exist):
4. **Root SSH key setup** - Currently requires manual setup
5. **Batch SSH operations** - Combine multiple operations

### Low Priority (Working as Designed):
6. **Passwordless sudo message** - Informational, not blocking

---

## Expected Behavior vs Bugs

### ✅ Expected (Not Bugs):
- Passwordless sudo message (if not configured)
- Root SSH test (validation check)
- Reverse SSH requiring host key acceptance (security)

### ❌ Actual Bugs to Fix:
- CONTROL_PLANE_IP not being read correctly
- Too many password prompts (should be 1-2 max)
- SSH host key check happening late in process

### 🔄 Improvements Needed:
- Early SSH validation with host key acceptance
- Connection multiplexing for fewer password prompts
- Better root SSH key setup automation

---

## Recommended Action Plan

1. **Immediate Fix**: CONTROL_PLANE_IP variable issue in sync-vps-routes.sh
2. **Short-term**: Add SSH ControlMaster to reduce password prompts
3. **Medium-term**: Early SSH setup phase with host key handling
4. **Long-term**: Improve root SSH key automation

---

## Testing Checklist

After fixes, test:
- [ ] Fresh VPS setup with SSH keys already configured
- [ ] Fresh VPS setup without SSH keys (password auth)
- [ ] Fresh VPS setup with passwordless sudo
- [ ] Fresh VPS setup without passwordless sudo
- [ ] Verify CONTROL_PLANE_IP is correctly saved and read
- [ ] Count password prompts (should be ≤2)
- [ ] Verify manage-app-visibility.sh works without passwords (if SSH keys set up)
