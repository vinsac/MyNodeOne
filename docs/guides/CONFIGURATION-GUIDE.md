# Configuration Guide - How MyNodeOne Uses Your Settings

**Understanding Configuration in MyNodeOne**

---

## 🎯 Overview

MyNodeOne is designed to be **shared, forked, and used by anyone** without modifying code. All user-specific configuration is stored in **your config file**, never hardcoded in scripts.

---

## 📁 Your Configuration File

### **Location:**
```bash
~/.mynodeone/config.env
```

### **Created By:**
```bash
./scripts/interactive-setup.sh
```

### **Contents Example:**
```bash
# User-specific settings (YOURS, not hardcoded!)
SSL_EMAIL=john.doe@company.com
DOMAIN=mycompany.com
VPS_PUBLIC_IP=45.8.133.192
VPS_EDGE_IP=100.101.92.95
CONTROL_PLANE_IP=100.118.5.68
TAILSCALE_IP=100.118.5.68
NODE_TYPE=control-plane
CLUSTER_NAME=mynodeone
ENABLE_GPU=false
```

---

## 🔑 Key Settings Explained

### **SSL_EMAIL**
- **Purpose:** Email for Let's Encrypt SSL certificates
- **Format:** Valid email address (e.g., `admin@company.com`)
- **Used By:** VPS Traefik setup
- **Example:** `SSL_EMAIL=devops@acme.com`

**How it works:**
```bash
# Script loads your config
source ~/.mynodeone/config.env

# Then uses it to generate Traefik config
cat > /etc/traefik/traefik.yml <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: ${SSL_EMAIL}  # Expands to YOUR email
EOF
```

**Result:** Traefik gets configured with `admin@company.com` (not a hardcoded email!)

---

### **DOMAIN**
- **Purpose:** Your domain name
- **Format:** Domain without protocol (e.g., `example.com`)
- **Used By:** DNS configuration, routing setup
- **Example:** `DOMAIN=mycompany.com`

---

### **VPS_PUBLIC_IP**
- **Purpose:** Public IP of your VPS edge node
- **Format:** IPv4 address (e.g., `45.8.133.192`)
- **Used By:** DNS instructions, routing verification
- **Example:** `VPS_PUBLIC_IP=45.8.133.192`

---

### **CONTROL_PLANE_IP**
- **Purpose:** Tailscale IP of your control plane
- **Format:** Tailscale IPv4 (e.g., `100.x.x.x`)
- **Used By:** Routing, proxy setup, monitoring
- **Example:** `CONTROL_PLANE_IP=100.118.5.68`

---

## ✅ Nothing is Hardcoded

### **What This Means:**

**Company A:**
```bash
# ~/.mynodeone/config.env
SSL_EMAIL=admin@companyA.com
DOMAIN=companyA.io
VPS_PUBLIC_IP=1.2.3.4
```
**Result:** All configs use Company A's settings ✅

**Company B:**
```bash
# ~/.mynodeone/config.env
SSL_EMAIL=devops@companyB.net
DOMAIN=companyB.com
VPS_PUBLIC_IP=5.6.7.8
```
**Result:** All configs use Company B's settings ✅

**Personal User:**
```bash
# ~/.mynodeone/config.env
SSL_EMAIL=john@personal.email
DOMAIN=johndoe.com
VPS_PUBLIC_IP=9.10.11.12
```
**Result:** All configs use personal settings ✅

---

## 🔄 How Configuration Works

### **Step 1: Initial Setup**
```bash
# You run:
sudo ./scripts/interactive-setup.sh

# Script asks for YOUR settings:
"Enter your email for SSL certificates: "
"Enter your domain name: "
"Enter your VPS IP: "

# Creates: ~/.mynodeone/config.env with YOUR answers
```

### **Step 2: Scripts Load Config**
```bash
# Every setup script starts with:
CONFIG_FILE="$HOME/.mynodeone/config.env"
source "$CONFIG_FILE"

# Now ${SSL_EMAIL}, ${DOMAIN}, etc. contain YOUR values
```

### **Step 3: Scripts Use Your Values**
```bash
# Example: VPS setup script
cat > /etc/traefik/traefik.yml <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: ${SSL_EMAIL}      # YOUR email from config
      storage: /etc/traefik/acme.json
EOF

# Result: File contains YOUR actual email, not ${SSL_EMAIL}
```

### **Step 4: Verification**
```bash
# Check what was actually written:
ssh root@YOUR_VPS 'grep email /etc/traefik/traefik.yml'

# Output:
email: your-actual-email@example.com  # ✅ Your email!
# NOT:
email: ${SSL_EMAIL}                   # ❌ Would be wrong!
```

---

## 🛡️ Security & Privacy

### **Your Config File is Private**

**Location:** `~/.mynodeone/config.env`
- ✅ Stored in your home directory
- ✅ Not committed to git
- ✅ Not shared publicly
- ✅ Specific to your machine

### **Included in .gitignore:**
```bash
# From .gitignore
.mynodeone/
*.env
config.env
```

**This means:** You can fork the repo and your config stays private!

---

## 🔧 Advanced Configuration

### **Environment Variables (Optional)**

You can also set variables before running scripts:

```bash
# Method 1: Export before running
export SSL_EMAIL=admin@example.com
export DOMAIN=example.com
sudo ./scripts/setup-edge-node.sh

# Method 2: Inline
SSL_EMAIL=admin@example.com sudo ./scripts/setup-edge-node.sh
```

But **interactive-setup.sh** is recommended for most users.

---

## 📋 Configuration Checklist

Before running setup scripts, ensure:

- [ ] You've run `./scripts/interactive-setup.sh`
- [ ] File `~/.mynodeone/config.env` exists
- [ ] `SSL_EMAIL` is set to YOUR email
- [ ] `DOMAIN` is set to YOUR domain
- [ ] IP addresses are correct for YOUR infrastructure
- [ ] No hardcoded values in scripts (verify with `grep`)

**Verification Command:**
```bash
# Check your config
cat ~/.mynodeone/config.env | grep -E "SSL_EMAIL|DOMAIN|VPS_PUBLIC_IP"

# Should show YOUR values, not placeholders!
```

---

## 🐛 Common Issues

### **Issue 1: ${SSL_EMAIL} Appearing Literally**

**Symptom:**
```bash
# On VPS:
cat /etc/traefik/traefik.yml | grep email
# Output: email: ${SSL_EMAIL}  # Wrong! ❌
```

**Cause:** Config not loaded or variable not expanded

**Solution:**
```bash
# 1. Check config exists
ls -la ~/.mynodeone/config.env

# 2. Check it has your email
cat ~/.mynodeone/config.env | grep SSL_EMAIL

# 3. Re-run setup with correct heredoc syntax (no single quotes)
cat > file <<EOF   # ✅ Correct - expands variables
# NOT:
cat > file <<'EOF' # ❌ Wrong - doesn't expand
```

### **Issue 2: Different Config on Different Machines**

**Symptom:** Settings work on one machine but not another

**Cause:** Each machine has its own `~/.mynodeone/config.env`

**Solution:**
```bash
# Copy config to other machine:
scp ~/.mynodeone/config.env user@other-machine:~/.mynodeone/

# Or re-run interactive setup on that machine
```

### **Issue 3: Config Not Found**

**Symptom:**
```bash
Error: Configuration not found!
Please run: ./scripts/interactive-setup.sh first
```

**Solution:**
```bash
# Run the interactive setup
./scripts/interactive-setup.sh

# This creates ~/.mynodeone/config.env
```

---

## 📚 Related Documentation

- **[HYBRID-SETUP-GUIDE.md](HYBRID-SETUP-GUIDE.md)** - Complete setup walkthrough
- **[VPS-INSTALLATION.md](VPS-INSTALLATION.md)** - VPS configuration
- **[HYBRID-TROUBLESHOOTING.md](HYBRID-TROUBLESHOOTING.md)** - Issue 2.4: SSL email problems

---

## ✅ Summary

**Key Takeaways:**

1. ✅ **All configuration is user-specific** (stored in `~/.mynodeone/config.env`)
2. ✅ **No hardcoded values** in scripts
3. ✅ **Multi-user/multi-team friendly** (each user has own config)
4. ✅ **Scripts use variable expansion** to insert YOUR values
5. ✅ **Config file is private** (gitignored, not shared)
6. ✅ **Verification is easy** (check config file and generated configs)

**Example Verification:**
```bash
# Step 1: Check your config
cat ~/.mynodeone/config.env
# Shows: SSL_EMAIL=yourname@example.com

# Step 2: Check it was used
ssh root@VPS 'grep email /etc/traefik/traefik.yml'
# Shows: email: yourname@example.com

# ✅ If both match → Configuration working correctly!
```

---

**Questions?** Open an issue on GitHub or check the troubleshooting guide!
