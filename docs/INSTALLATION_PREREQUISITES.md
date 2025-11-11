# MyNodeOne Installation Prerequisites

**⚠️ IMPORTANT:** Complete these prerequisites BEFORE running any installation scripts.

---

## 🎯 **Quick Reference**

| Node Type | Prerequisites | Verification Command |
|-----------|---------------|---------------------|
| **Control Plane** | None - install first | `kubectl get nodes` |
| **Management Laptop** | SSH to control plane | `ssh user@control-plane 'echo OK'` |
| **VPS Edge Node** | SSH + Passwordless Sudo | See checklist below |

---

## 📋 **VPS Edge Node Prerequisites (CRITICAL)**

VPS installation has the most prerequisites. Complete ALL steps below:

### ✅ **Checklist**

#### **1. Control Plane Must Be Running**
```bash
# Verify from control plane:
kubectl get nodes
# Should show: Ready

kubectl get pods -A
# Should show: All Running
```

#### **2. Passwordless Sudo MUST Be Configured**
**This is the #1 cause of installation failures!**

**On Control Plane, run:**
```bash
cd ~/MyNodeOne
# Either command works:
./scripts/setup-control-plane-sudo.sh
# OR: sudo ./scripts/setup-control-plane-sudo.sh
```

**Verify it works:**
```bash
# Should NOT ask for password:
sudo kubectl version --client
```

**Why this is required:**
- VPS needs to query cluster via SSH
- Commands run as: `ssh user@control-plane 'sudo kubectl get ...'`
- If sudo asks for password, automation hangs

#### **3. SSH Access From VPS → Control Plane**
**On VPS, set up SSH key:**
```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy key to control plane
ssh-copy-id user@<control-plane-ip>
```

**Verify it works:**
```bash
# Should connect WITHOUT asking for password:
ssh user@<control-plane-ip> 'echo OK'
```

#### **4. Tailscale Must Be Connected**
```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to your Tailnet
sudo tailscale up

# Verify connection
tailscale ip -4
# Should show: 100.x.x.x
```

#### **5. Docker Must Be Installed**
```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Log out and back in, then verify:
docker ps
# Should show: Container list (may be empty)
```

---

## 🔍 **Pre-Installation Verification**

Run this command BEFORE installing VPS:

```bash
cd ~/MyNodeOne
./scripts/check-prerequisites.sh vps <control-plane-ip> [ssh-user]
```

**Example:**
```bash
./scripts/check-prerequisites.sh vps 100.67.210.15 vinaysachdeva
```

**Expected Output:**
```
🔍 Pre-flight Checks: vps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[✓] SSH connection: OK
[✓] Passwordless sudo: OK
[✓] Kubernetes cluster: RUNNING
[✓] cluster-info ConfigMap: EXISTS
[✓] Tailscale connected: 100.65.241.25
[✓] Docker: INSTALLED
[✓] Docker daemon: RUNNING
[✓] Ports 80, 443: AVAILABLE
[✓] No IP conflicts detected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[✓] All pre-flight checks passed!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Ready to proceed with vps installation!
```

**If ANY check fails, DO NOT proceed with installation!**

---

## 📖 **Detailed Setup Instructions**

### **Passwordless Sudo Setup (Step-by-Step)**

This is the most critical prerequisite.

#### **On Control Plane:**

1. **Log in to control plane:**
   ```bash
   ssh user@control-plane-ip
   ```

2. **Clone or pull MyNodeOne:**
   ```bash
   cd ~/MyNodeOne
   git pull  # If already installed
   # OR
   git clone https://github.com/vinsac/MyNodeOne.git ~/MyNodeOne
   ```

3. **Run the sudo setup script:**
   ```bash
   # Either command works:
   ./scripts/setup-control-plane-sudo.sh
   # OR: sudo ./scripts/setup-control-plane-sudo.sh
   ```

4. **Verify it worked:**
   ```bash
   sudo kubectl version --client
   # Should show version WITHOUT asking for password
   ```

5. **Test remote access pattern:**
   ```bash
   # From another machine (VPS or laptop):
   ssh user@control-plane-ip 'sudo kubectl version --client'
   # Should work without password prompt
   ```

#### **What This Does:**

Creates `/etc/sudoers.d/mynodeone` with:
```bash
# Allow kubectl without password
user ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/kubectl

# Allow MyNodeOne scripts without password
user ALL=(ALL) NOPASSWD: /home/user/MyNodeOne/scripts/*.sh
```

---

### **SSH Key Setup (Step-by-Step)**

#### **Option A: Automatic (Recommended)**

The VPS installation script will attempt to set up SSH keys automatically.
However, you must first ensure passwordless access FROM VPS TO control plane.

**On VPS:**
```bash
# Generate key if needed
[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy to control plane (will ask for password ONCE)
ssh-copy-id user@control-plane-ip

# Test (should NOT ask for password)
ssh user@control-plane-ip 'echo OK'
```

#### **Option B: Manual (If automatic fails)**

**1. Generate SSH key on VPS:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
```

**2. Copy public key to control plane:**
```bash
# Get the public key:
cat ~/.ssh/id_ed25519.pub

# On control plane, add to authorized_keys:
echo "<paste-public-key>" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**3. Set up reverse SSH (Control Plane → VPS):**

**On Control Plane (as your user):**
```bash
# Generate key if needed
[ ! -f ~/.ssh/id_ed25519 ] && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''

# Copy to VPS
ssh-copy-id user@vps-tailscale-ip
```

**On Control Plane (as root - for script access):**
```bash
# Generate root key if needed
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ''

# Get root's public key
sudo cat /root/.ssh/id_ed25519.pub

# On VPS, add to your authorized_keys:
echo "<paste-root-public-key>" >> ~/.ssh/authorized_keys
```

---

## 🚨 **Common Mistakes to Avoid**

### **1. Skipping Passwordless Sudo Setup**
❌ **Problem:** Installation hangs waiting for password  
✅ **Solution:** Run `setup-control-plane-sudo.sh` BEFORE VPS install

### **2. Using Wrong SSH User**
❌ **Problem:** SSH keys for user A, but installing as user B  
✅ **Solution:** Use same user for SSH setup and installation

### **3. Not Testing Before Installing**
❌ **Problem:** Prerequisites not verified, installation fails  
✅ **Solution:** Run `check-prerequisites.sh` first

### **4. Forgetting Reverse SSH**
❌ **Problem:** VPS installs, but routes don't sync  
✅ **Solution:** Ensure Control Plane → VPS SSH works (script does this)

### **5. Docker Not in User Group**
❌ **Problem:** `docker ps` requires sudo  
✅ **Solution:** `sudo usermod -aG docker $USER` and re-login

---

## 🎯 **Installation Order**

**ALWAYS follow this order:**

```
1. Control Plane Installation
   └─> Installs Kubernetes, applications
   └─> Creates cluster-info ConfigMap
   └─> NO prerequisites

2. ⚠️ CRITICAL STEP ⚠️
   └─> Run: ./scripts/setup-control-plane-sudo.sh
   └─> Verify: sudo kubectl version (no password prompt)

3. Management Laptop (Optional)
   └─> Prerequisites: SSH to control plane
   └─> Run: check-prerequisites.sh management <cp-ip>
   └─> Install: ./scripts/mynodeone → Option 4

4. VPS Edge Node(s)
   └─> Prerequisites: ALL items in checklist above
   └─> Run: check-prerequisites.sh vps <cp-ip>
   └─> Install: ./scripts/mynodeone → Option 3
```

---

## ✅ **Verification Tests**

Run these tests to ensure prerequisites are met:

### **Test 1: SSH Access**
```bash
# From VPS:
ssh user@control-plane-ip 'echo OK'
# Expected: OK (no password prompt)
```

### **Test 2: Passwordless Sudo**
```bash
# From VPS:
ssh user@control-plane-ip 'sudo kubectl version --client'
# Expected: Version output (no password prompt)
```

### **Test 3: Tailscale**
```bash
# On VPS:
tailscale ip -4
# Expected: 100.x.x.x
```

### **Test 4: Docker**
```bash
# On VPS:
docker ps
# Expected: Container list (no sudo required)
```

### **Test 5: Ports Available**
```bash
# On VPS:
sudo lsof -i :80
sudo lsof -i :443
# Expected: No output (ports free)
```

---

## 🆘 **Troubleshooting**

### **Pre-flight Check Fails: "SSH connection: FAILED"**

**Cause:** SSH key not set up

**Fix:**
```bash
ssh-copy-id user@control-plane-ip
ssh user@control-plane-ip 'echo OK'
```

---

### **Pre-flight Check Fails: "Passwordless sudo: NOT CONFIGURED"**

**Cause:** Most common issue! Sudo setup not run.

**Fix:**
```bash
ssh user@control-plane-ip
cd ~/MyNodeOne
./scripts/setup-control-plane-sudo.sh
exit

# Verify:
ssh user@control-plane-ip 'sudo kubectl version --client'
```

---

### **Pre-flight Check Fails: "Tailscale: NOT CONNECTED"**

**Cause:** Tailscale not installed or not connected

**Fix:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4
```

---

### **Pre-flight Check Fails: "Ports in use: 80, 443"**

**Cause:** Another web server running

**Fix:**
```bash
# Find what's using the ports:
sudo lsof -i :80
sudo lsof -i :443

# Stop the service:
sudo systemctl stop apache2  # or nginx, etc.
sudo systemctl disable apache2
```

---

## 📚 **Additional Resources**

- **SSH Key Setup:** https://www.ssh.com/academy/ssh/keygen
- **Tailscale Setup:** https://tailscale.com/kb/1017/install/
- **Docker Installation:** https://docs.docker.com/engine/install/
- **Sudoers File:** https://www.sudo.ws/docs/man/sudoers.man/

---

## 🎓 **Understanding Why These Are Required**

### **Why Passwordless Sudo?**
- VPS queries cluster via: `ssh user@cp 'sudo kubectl get ...'`
- If sudo prompts for password, SSH connection hangs
- Automation cannot provide interactive passwords
- Solution: Configure sudo to not ask password for kubectl

### **Why Bidirectional SSH?**
- VPS → Control Plane: VPS queries cluster data
- Control Plane → VPS: Control plane syncs routes to VPS
- Both directions must be passwordless for automation

### **Why Tailscale?**
- Secure VPN for private cluster communication
- Allows VPS to talk to control plane without public IPs
- Automatic encryption and authentication
- Dynamic DNS for services

### **Why Pre-flight Checks?**
- Catch problems BEFORE installation starts
- Clear error messages instead of cryptic failures
- Saves hours of debugging time
- Ensures consistent successful installations

---

## ✨ **Summary: The Golden Rule**

```
┌─────────────────────────────────────────────────────┐
│  NEVER start VPS installation until:                │
│                                                      │
│  ✅ setup-control-plane-sudo.sh has been run       │
│  ✅ check-prerequisites.sh passes ALL tests        │
│  ✅ Manual verification tests succeed              │
│                                                      │
│  Following this rule = 95% installation success!    │
└─────────────────────────────────────────────────────┘
```

---

**Document Version:** 1.0  
**Last Updated:** November 10, 2025  
**Status:** Mandatory Reading Before Installation
