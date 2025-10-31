# DNS Setup Guide for MyNodeOne

**Complete guide to setting up your domain name for MyNodeOne**

**For non-technical users** - Step-by-step with screenshots and examples

---

## 🎯 What You Need

Before starting:
- [ ] A domain name (example: `yourname.com`)
- [ ] Your VPS public IP address (from installation output)
- [ ] Access to your domain registrar account

**Don't have a domain?** See "How to Buy a Domain" below.

---

## 📖 Table of Contents

1. [Understanding DNS](#understanding-dns)
2. [Finding Your VPS IP](#finding-your-vps-ip)
3. [DNS Setup by Provider](#dns-setup-by-provider)
   - [Namecheap](#namecheap)
   - [GoDaddy](#godaddy)
   - [Cloudflare](#cloudflare)
   - [Google Domains](#google-domains)
   - [Other Providers](#other-providers)
4. [Setting Up Subdomains](#setting-up-subdomains)
5. [Verifying DNS](#verifying-dns)
6. [Troubleshooting](#troubleshooting)
7. [How to Buy a Domain](#how-to-buy-a-domain)

---

## 🔍 Understanding DNS (Simple Explanation)

**DNS = Internet's Phone Book**

When you type `google.com` in your browser, DNS translates it to an IP address (like `142.250.180.46`).

**For MyNodeOne:**
- Your domain: `photos.yourname.com`
- Points to: Your VPS IP (`45.8.133.192`)
- Result: People can visit `photos.yourname.com` instead of `45.8.133.192`

**What is an A Record?**
- **A Record** = Address Record
- Links your domain name to an IP address
- Example: `photos.yourname.com` → `45.8.133.192`

**What is a subdomain?**
- Main domain: `yourname.com`
- Subdomain: `photos.yourname.com`, `jellyfin.yourname.com`
- Each subdomain can point to different services

---

## 🔢 Finding Your VPS IP

Your VPS public IP was shown during installation. To find it again:

### Method 1: From Installation Output

Look for this line in your installation output:
```
Public IP: 45.8.133.192
```

### Method 2: Command on VPS

```bash
# SSH into your VPS, then run:
curl ifconfig.me
```

### Method 3: From VPS Provider

- Log into Contabo/DigitalOcean/Hetzner dashboard
- Find your server
- Look for "IPv4 Address" or "Public IP"

**Write it down!** You'll need this for DNS setup.

Example: `45.8.133.192`

---

## 🌐 DNS Setup by Provider

Choose your domain registrar below and follow the steps.

### Namecheap

**Step 1: Log In**
1. Go to https://namecheap.com
2. Click "Sign In" (top right)
3. Enter your username and password

**Step 2: Go to Domain List**
1. Click "Account" → "Dashboard"
2. Click "Domain List" in sidebar
3. Find your domain (e.g., `yourname.com`)

**Step 3: Manage DNS**
1. Click "Manage" button next to your domain
2. Click "Advanced DNS" tab

**Step 4: Add A Record**
1. Click "Add New Record"
2. Fill in:
   ```
   Type: A Record
   Host: @ (for main domain) or photos (for subdomain)
   Value: 45.8.133.192 (your VPS IP)
   TTL: Automatic (or 300)
   ```
3. Click "Save Changes" (green checkmark)

**Example for Immich photos:**
```
Type: A Record
Host: photos
Value: 45.8.133.192
TTL: 300
```

**Result:** `photos.yourname.com` → Your VPS

---

### GoDaddy

**Step 1: Log In**
1. Go to https://godaddy.com
2. Click "Sign In" (top right)
3. Enter your credentials

**Step 2: My Products**
1. Click your profile icon → "My Products"
2. Find "Domains"
3. Click "DNS" next to your domain

**Step 3: Add A Record**
1. Scroll to "Records" section
2. Click "Add" button
3. Fill in:
   ```
   Type: A
   Name: @ (for main domain) or photos (for subdomain)
   Value: 45.8.133.192
   TTL: 600 seconds
   ```
4. Click "Save"

**Example:**
```
Type: A
Name: photos
Value: 45.8.133.192
TTL: 600
```

---

### Cloudflare

**Step 1: Log In**
1. Go to https://cloudflare.com
2. Click "Log In"
3. Enter email and password

**Step 2: Select Domain**
1. Click on your domain from the list
2. Click "DNS" in the top menu

**Step 3: Add A Record**
1. Click "Add record"
2. Fill in:
   ```
   Type: A
   Name: @ (for root) or photos (for subdomain)
   IPv4 address: 45.8.133.192
   Proxy status: DNS only (gray cloud)
   TTL: Auto
   ```
3. Click "Save"

**IMPORTANT:** Turn OFF the orange cloud (Cloudflare proxy) for now:
- Click the orange cloud icon → It turns gray
- This is required for Let's Encrypt SSL certificates

**Example:**
```
Type: A
Name: photos
IPv4: 45.8.133.192
Proxy: DNS only (gray cloud)
```

---

### Google Domains

**Step 1: Log In**
1. Go to https://domains.google.com
2. Sign in with Google account

**Step 2: Select Domain**
1. Click "My domains"
2. Click on your domain

**Step 3: Go to DNS**
1. Click "DNS" in left sidebar
2. Scroll to "Custom resource records"

**Step 4: Add A Record**
1. Fill in:
   ```
   Name: @ (for root) or photos (for subdomain)
   Type: A
   TTL: 5 (minutes)
   Data: 45.8.133.192
   ```
2. Click "Add"

**Example:**
```
Name: photos
Type: A
TTL: 5
Data: 45.8.133.192
```

---

### Other Providers

**General Steps (works for most providers):**

1. **Log into your domain registrar**
   - Namecheap, GoDaddy, Hover, etc.

2. **Find DNS settings**
   - Usually called:
     - "DNS Management"
     - "DNS Settings"
     - "Manage DNS"
     - "Advanced DNS"

3. **Add an A Record**
   - Type: `A` or `A Record`
   - Name/Host: `@` (root) or `photos` (subdomain)
   - Value/Points to: `45.8.133.192` (your VPS IP)
   - TTL: `300` or `Automatic`

4. **Save changes**

---

## 📌 Setting Up Subdomains

For each app, you'll create a subdomain:

**Popular App Subdomains:**

| App | Suggested Subdomain | Example |
|-----|-------------------|---------|
| Immich (Photos) | `photos` | `photos.yourname.com` |
| Jellyfin (Media) | `jellyfin` or `media` | `jellyfin.yourname.com` |
| Vaultwarden (Passwords) | `vault` or `passwords` | `vault.yourname.com` |
| Nextcloud (Files) | `cloud` or `files` | `cloud.yourname.com` |
| Dashboard | `dashboard` or `home` | `dashboard.yourname.com` |

**How to Add a Subdomain:**

Same process as adding A record, but change the "Name/Host":

```
Type: A Record
Host: photos (instead of @)
Value: 45.8.133.192 (same VPS IP)
TTL: 300
```

**Add one subdomain per app you install.**

---

## ✅ Verifying DNS

After adding DNS records, verify they work:

### Method 1: Online Tool (Easiest)

1. Go to https://dnschecker.org
2. Enter your domain: `photos.yourname.com`
3. Select "A" record type
4. Click "Search"
5. Should show your VPS IP: `45.8.133.192`

**Wait 5-15 minutes** if it doesn't show immediately.

### Method 2: Command Line

**On Mac/Linux:**
```bash
dig photos.yourname.com

# Look for:
# photos.yourname.com. 300 IN A 45.8.133.192
```

**On Windows:**
```cmd
nslookup photos.yourname.com

# Look for:
# Address: 45.8.133.192
```

### Method 3: Ping Test

```bash
ping photos.yourname.com

# Should show: PING photos.yourname.com (45.8.133.192)
```

---

## 🐛 Troubleshooting

### Problem: DNS not resolving after 30 minutes

**Solutions:**

1. **Check DNS record is correct**
   - Log into domain registrar
   - Verify A record exists
   - Confirm IP is correct

2. **Check TTL setting**
   - Lower TTL = faster updates
   - Set to 300 (5 minutes)

3. **Try different DNS checker**
   - https://dnschecker.org
   - https://mxtoolbox.com/DNSLookup.aspx
   - https://www.whatsmydns.net

4. **Flush DNS cache on your computer**
   
   **Mac:**
   ```bash
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   ```
   
   **Windows:**
   ```cmd
   ipconfig /flushdns
   ```
   
   **Linux:**
   ```bash
   sudo systemd-resolve --flush-caches
   ```

### Problem: "DNS_PROBE_FINISHED_NXDOMAIN" error

**Meaning:** Domain doesn't exist or DNS not configured

**Solutions:**
1. Verify domain is active (not expired)
2. Check DNS records are saved
3. Wait longer (can take up to 48 hours, usually 5-15 minutes)

### Problem: Points to wrong IP

**Solution:**
1. Delete old A record
2. Add new A record with correct IP
3. Wait 5-15 minutes

### Problem: Cloudflare shows SSL error

**Solution:**
1. Turn OFF Cloudflare proxy (gray cloud)
2. Wait 5 minutes
3. Try again
4. After SSL works, you can turn proxy back ON

---

## 💰 How to Buy a Domain

**Recommended Registrars:**

### 1. Namecheap (Recommended)
- **Cost:** $10-15/year
- **Website:** https://namecheap.com
- **Pros:** Cheap, easy to use, free privacy protection

**Steps:**
1. Go to namecheap.com
2. Search for your desired domain
3. Add to cart
4. Create account
5. Pay ($10-15/year)
6. Done!

### 2. Cloudflare (Cheapest)
- **Cost:** $9-10/year (at-cost pricing)
- **Website:** https://cloudflare.com
- **Pros:** Cheapest, includes DNS, CDN, SSL

**Requirements:**
- Need to transfer domain (can't register new)
- Or use Cloudflare Registrar

### 3. Google Domains
- **Cost:** $12/year
- **Website:** https://domains.google.com
- **Pros:** Simple, integrated with Google

### 4. Porkbun
- **Cost:** $8-12/year
- **Website:** https://porkbun.com
- **Pros:** Very cheap, good support

**Choosing a Domain Name:**

**Good practices:**
- ✅ Keep it short
- ✅ Easy to spell
- ✅ Use `.com` (most popular)
- ✅ Personal: `yourname.com`
- ✅ Generic: `mycloud.com`, `familyphotos.com`

**Avoid:**
- ❌ Hard to spell names
- ❌ Weird TLDs (`.xyz`, `.info`, etc.)
- ❌ Trademarked names

---

## 🎯 Complete Example

**Scenario:** You want to host Immich photos on `photos.example.com`

### Step 1: Get Your VPS IP
```bash
# On VPS:
curl ifconfig.me
# Result: 45.8.133.192
```

### Step 2: Add DNS Record

**On Namecheap:**
```
Type: A Record
Host: photos
Value: 45.8.133.192
TTL: 300
```

### Step 3: Verify DNS
```bash
# Wait 5 minutes, then:
dig photos.example.com

# Should show:
# photos.example.com. 300 IN A 45.8.133.192
```

### Step 4: Configure VPS Route

**On control plane (where apps run):**
```bash
cd ~/MyNodeOne
sudo ./scripts/configure-vps-route.sh immich 3001 photos example.com
```

This automatically configures:
- Traefik routing
- HTTPS redirect
- Let's Encrypt SSL certificate

### Step 5: Wait & Visit

**Wait 5-10 minutes for:**
- DNS propagation
- SSL certificate generation

**Then visit:**
```
https://photos.example.com
```

**Done!** 🎉

---

## 📋 Quick Reference Card

**Print this for easy reference:**

```
┌─────────────────────────────────────────────┐
│ DNS SETUP QUICK REFERENCE                   │
├─────────────────────────────────────────────┤
│                                             │
│ Type:  A Record                             │
│ Name:  photos (or @ for root)               │
│ Value: YOUR_VPS_IP                          │
│ TTL:   300                                  │
│                                             │
│ Common Subdomains:                          │
│  • photos → Immich                          │
│  • jellyfin → Jellyfin                      │
│  • vault → Vaultwarden                      │
│  • cloud → Nextcloud                        │
│  • dashboard → Dashboard                    │
│                                             │
│ Verify: dnschecker.org                      │
│ Wait: 5-15 minutes                          │
│                                             │
└─────────────────────────────────────────────┘
```

---

## 🆘 Still Stuck?

### Getting Help:

1. **Check DNS Status:**
   - https://dnschecker.org
   - Enter your domain
   - See if IP is correct

2. **Common Issues:**
   - Wrong IP address → Update DNS record
   - Old cache → Flush DNS cache
   - Not saved → Check registrar settings

3. **Ask for Help:**
   - Open GitHub issue: https://github.com/vinsac/MyNodeOne/issues
   - Include:
     - Domain name
     - VPS IP
     - DNS checker screenshot
     - Error message

---

## ✅ Success Checklist

After DNS setup:

- [ ] A record created for each subdomain
- [ ] Points to correct VPS IP
- [ ] DNS checker shows correct IP
- [ ] Can ping domain (shows VPS IP)
- [ ] Waited 5-15 minutes
- [ ] VPS route configured (via script)
- [ ] Can access via HTTPS

**Your apps are now accessible from anywhere!** 🚀

---

**Next:** Configure VPS routes for your apps using `configure-vps-route.sh`
