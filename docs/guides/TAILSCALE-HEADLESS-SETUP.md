# Tailscale Headless Setup (VPS/CLI Only)

**Quick guide for setting up Tailscale on servers without GUI**

---

## 🎯 For VPS/Cloud Servers (No Desktop UI)

Your VPS has **no graphical interface** - everything is done via SSH terminal. Here's how to set up Tailscale:

---

## Method 1: Interactive Authentication (Easiest)

### Step 1: Install Tailscale on VPS

```bash
# On your VPS (via SSH):
curl -fsSL https://tailscale.com/install.sh | sh
```

### Step 2: Start Tailscale

```bash
sudo tailscale up
```

### Step 3: Authenticate via Browser

**You'll see output like:**
```
To authenticate, visit:
  https://login.tailscale.com/a/1234567890abcdef
```

**What to do:**
1. **Copy that URL**
2. **Open it on your laptop/phone browser**
3. **Log in to Tailscale** (or create account)
4. **Click "Connect"** to approve the device
5. **Done!** Your VPS is now on Tailscale

### Step 4: Verify Connection

```bash
# On VPS - check Tailscale IP
tailscale ip -4

# Example output: 100.101.102.103

# Check full status
sudo tailscale status

# You should see your VPS listed
```

**That's it!** Your VPS now has a Tailscale IP (100.x.x.x) that you can use to access it and any apps.

---

## Method 2: Auth Key (No Browser Needed)

**For automation or if Method 1 doesn't work:**

### Step 1: Generate Auth Key

**On your laptop:**
1. Go to https://login.tailscale.com/admin/settings/keys
2. Click "Generate auth key"
3. Check "Reusable" and "Ephemeral" (optional)
4. Click "Generate key"
5. **Copy the key** (starts with `tskey-auth-...`)

### Step 2: Use Auth Key on VPS

```bash
# On your VPS:
sudo tailscale up --authkey=tskey-auth-YOUR-KEY-HERE
```

**Done!** No browser needed.

### Step 3: Verify

```bash
tailscale ip -4
sudo tailscale status
```

---

## Method 3: Manual Device Approval

### Step 1: Start Tailscale Without Auth

```bash
sudo tailscale up --force-reauth
```

### Step 2: Approve on Admin Panel

1. Go to https://login.tailscale.com/admin/machines
2. Find your VPS (shows as "waiting for approval")
3. Click "Approve"
4. Done!

---

## 🔍 Checking if Tailscale Works

### From VPS:

```bash
# Get your Tailscale IP
tailscale ip -4

# Example: 100.101.102.103

# Check status
sudo tailscale status

# Ping another device (if you have one)
ping 100.x.x.x
```

### From Your Laptop:

1. **Install Tailscale** on laptop (https://tailscale.com/download)
2. **Log in** with same account
3. **Check status:**
   ```bash
   tailscale status
   ```
4. **Ping your VPS:**
   ```bash
   ping 100.101.102.103  # Use your VPS Tailscale IP
   ```

### From Your Phone:

1. **Install Tailscale app** (iOS/Android)
2. **Log in** with same account
3. **You should see your VPS** in device list
4. **Can now access it** via 100.x.x.x

---

## 🌐 Using Tailscale IPs

### Access VPS via Tailscale:

**SSH (more secure than public IP):**
```bash
# Instead of:
ssh root@45.8.133.192

# Use:
ssh root@100.101.102.103  # Your Tailscale IP
```

**Access apps:**
```bash
# Immich running on VPS
http://100.101.102.103

# Dashboard
http://100.101.102.103:8080

# Any Kubernetes service
http://100.101.102.103:<port>
```

**Benefits:**
- ✅ Encrypted automatically
- ✅ No port forwarding needed
- ✅ Works from anywhere
- ✅ No firewall changes needed
- ✅ Access from phone/laptop/tablet

---

## 🐛 Troubleshooting

### Issue: "tailscale: command not found"

**Fix:** Tailscale not installed
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### Issue: "Login URL doesn't work"

**Fix:** Try auth key method instead (see Method 2 above)

### Issue: "Can't see VPS in device list"

**Fix:** 
```bash
# Restart Tailscale
sudo tailscale down
sudo tailscale up

# Check if running
sudo systemctl status tailscaled
```

### Issue: "Can't ping between devices"

**Fix:**
```bash
# Enable IP forwarding on VPS
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Restart Tailscale
sudo tailscale down
sudo tailscale up
```

### Issue: "Tailscale disconnects"

**Fix:**
```bash
# Enable Tailscale to start on boot
sudo systemctl enable tailscaled
sudo systemctl start tailscaled

# Keep connection alive
sudo tailscale up --accept-routes
```

---

## 🔐 Security Tips

### 1. Disable Key Expiry (Optional)

By default, auth keys expire. To disable:
1. Go to https://login.tailscale.com/admin/settings/keys
2. Generate key with "No expiry" checked

### 2. Use Tailscale ACLs

Control which devices can access what:
1. Go to https://login.tailscale.com/admin/acls
2. Configure access rules
3. Example: Only allow your laptop to SSH to VPS

### 3. Enable MagicDNS (Recommended)

Access devices by name instead of IP:
1. Go to https://login.tailscale.com/admin/dns
2. Enable MagicDNS
3. Access VPS via: `ssh vmi2161443` instead of `ssh 100.x.x.x`

---

## 📱 Mobile Access

### iOS:
1. Install Tailscale from App Store
2. Log in
3. Toggle ON
4. Access VPS via Safari: `http://100.x.x.x`

### Android:
1. Install Tailscale from Play Store
2. Log in
3. Toggle ON
4. Access VPS via Chrome: `http://100.x.x.x`

**Photo backup with Immich:**
1. Install Immich mobile app
2. Server URL: `http://100.x.x.x` (Tailscale IP)
3. Log in
4. Enable auto-backup
5. Photos uploaded to your VPS!

---

## ✅ Quick Verification Checklist

After setup, verify:

- [ ] `tailscale ip -4` shows 100.x.x.x IP
- [ ] `sudo tailscale status` shows "online"
- [ ] Can ping VPS from laptop: `ping 100.x.x.x`
- [ ] Can SSH via Tailscale: `ssh user@100.x.x.x`
- [ ] Can access HTTP: `curl http://100.x.x.x`
- [ ] Visible in admin panel: https://login.tailscale.com/admin/machines
- [ ] Works on phone (if using mobile apps)

---

## 🎯 Summary

**Tailscale on VPS (no GUI):**

1. **Install:** `curl -fsSL https://tailscale.com/install.sh | sh`
2. **Start:** `sudo tailscale up`
3. **Authenticate:** Open URL in browser on ANY device
4. **Done:** VPS has 100.x.x.x IP, accessible from anywhere

**No UI needed! Authentication happens via browser on your laptop/phone.**

**Your VPS is now securely accessible from anywhere via Tailscale!** 🚀
