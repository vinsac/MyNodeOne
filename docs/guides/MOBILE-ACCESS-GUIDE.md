# Mobile Access Guide for MyNodeOne
## How to Access Your Apps from Your Phone/Tablet

---

## 🎯 Quick Answer

**To use MyNodeOne apps on your phone, you MUST install Tailscale.**

**Why?** Your apps run on a secure private network. Tailscale connects your phone to this network.

**Time:** 5 minutes one-time setup  
**Cost:** Free for personal use  
**Benefit:** Access your apps from ANYWHERE (home, vacation, coffee shop)

---

## 📱 Step-by-Step Setup

### Step 1: Install Tailscale App (2 minutes)

**iPhone:**
1. Open App Store
2. Search "Tailscale"
3. Tap "Get" / "Install"
4. Wait for installation

**Android:**
1. Open Play Store
2. Search "Tailscale"
3. Tap "Install"
4. Wait for installation

### Step 2: Connect to Your Network (1 minute)

1. **Open Tailscale app**
2. **Tap "Get Started"** or "Sign In"
3. **Choose login method:**
   - Use the SAME method you used for MyNodeOne
   - Examples: Google, Microsoft, GitHub, Email
4. **Tap "Connect"**
5. **Allow VPN configuration** when prompted
   - iOS: Tap "Allow" on VPN permission dialog
   - Android: Tap "OK" on VPN connection request

**✅ Done!** Your phone is now connected to your private cloud.

### Step 3: Test Access (1 minute)

1. **Open Safari (iPhone) or Chrome (Android)**
2. **Type:** `http://mynodeone.local`
3. **Press Enter/Go**
4. **You should see:** Your MyNodeOne dashboard!

**If it works:** Congratulations! You can now access all your apps.  
**If it doesn't work:** See troubleshooting section below.

---

## 📲 Installing Mobile Apps

Now that Tailscale is set up, you can install and use mobile apps for your services.

### Example: Immich (Photo Backup)

**What you'll do:**
- Install Immich app on phone
- Point it to your MyNodeOne server
- Photos automatically backup to your personal cloud!

**Step-by-Step:**

1. **Download Immich App**
   - iPhone: App Store → "Immich"
   - Android: Play Store → "Immich"

2. **Open Immich App**
   - Tap "Server URL"

3. **Enter Server Address**
   - Type: `http://immich.mynodeone.local`
   - Tap "Connect" or "Next"

4. **Create Account or Login**
   - If first time: Create account
   - If already created: Login

5. **Enable Auto-Upload**
   - Grant photo permissions
   - Enable "Background Upload"
   - Choose which albums to backup

**🎉 Done!** Photos now backup automatically to YOUR cloud, not Google!

---

### Example: Jellyfin (Media Streaming)

**What you'll do:**
- Install Jellyfin app on phone
- Connect to your media server
- Watch your movies/TV shows anywhere!

**Step-by-Step:**

1. **Download Jellyfin App**
   - iPhone: App Store → "Jellyfin"
   - Android: Play Store → "Jellyfin"

2. **Open Jellyfin App**
   - Tap "Add Server"

3. **Enter Server Address**
   - Type: `http://jellyfin.mynodeone.local`
   - Tap "Connect"

4. **Login**
   - Enter your username and password

5. **Start Watching!**
   - Browse your media library
   - Download for offline viewing
   - Cast to TV

**🎉 Done!** Your personal Netflix, accessible anywhere!

---

### Example: Vaultwarden (Password Manager)

**What you'll do:**
- Install official Bitwarden app
- Point it to your Vaultwarden server
- Access passwords anywhere!

**Step-by-Step:**

1. **Download Bitwarden App** (NOT Vaultwarden!)
   - iPhone: App Store → "Bitwarden"
   - Android: Play Store → "Bitwarden"

2. **Open Bitwarden App**
   - Before logging in, tap Settings ⚙️ (top left)

3. **Configure Self-Hosted**
   - Tap "Self-hosted"
   - Server URL: `http://vaultwarden.mynodeone.local`
   - Tap "Save"

4. **Create Account or Login**
   - If first time: Create account
   - If already created: Login with master password

5. **Enable Auto-Fill**
   - iOS: Settings → Passwords → AutoFill Passwords → Bitwarden
   - Android: Settings → AutoFill → Bitwarden

**🎉 Done!** Your passwords sync across all devices, privately!

---

## 🌍 How Tailscale Works

### The Simple Explanation

**Without Tailscale:**
```
Your Phone → ❌ Can't reach MyNodeOne
(Different networks, private IPs, no access)
```

**With Tailscale:**
```
Your Phone → ✅ Secure encrypted tunnel → MyNodeOne
(Same virtual network, works from anywhere)
```

### What Tailscale Actually Does

1. **Creates Virtual Network**
   - All your devices join a private mesh network
   - Each device gets a special IP (100.x.x.x)

2. **Encrypts All Traffic**
   - Uses WireGuard (military-grade encryption)
   - Even on public WiFi, your data is safe

3. **Works Everywhere**
   - Home WiFi ✅
   - Mobile data (4G/5G) ✅
   - Coffee shop WiFi ✅
   - Hotel WiFi ✅
   - Airport WiFi ✅

4. **No Port Forwarding**
   - Your router stays secure
   - No firewall changes needed
   - Works behind NAT

---

## 🔒 Security & Privacy

### Is Tailscale Safe?

**Yes!** Here's why:

- ✅ **Open Source:** Code is public, independently audited
- ✅ **End-to-End Encrypted:** Tailscale can't see your data
- ✅ **No Data Collection:** Your traffic doesn't go through Tailscale servers
- ✅ **Industry Standard:** Uses WireGuard (state-of-the-art VPN)
- ✅ **Zero Trust:** Each device must be explicitly authorized

### What Does Tailscale See?

**They CAN see:**
- Your device list (names you choose)
- Last connection times

**They CANNOT see:**
- Your actual data/traffic
- What apps you're using
- Your files or photos
- Passwords or credentials

**Your data goes DIRECTLY from phone → MyNodeOne.** Tailscale just helps them find each other.

### Cost

**Personal Use: FREE**
- Up to 100 devices
- Unlimited traffic
- All features

**Business Use: Paid plans available**
- Not relevant for home/personal use

---

## 🆘 Troubleshooting

### Problem: "Can't connect to http://mynodeone.local"

**Check #1: Is Tailscale Connected?**
```
Open Tailscale app
Look for "Connected" status
If "Disconnected": Tap to reconnect
```

**Check #2: Are you on the same Tailscale account?**
```
Tailscale app → Settings → Check email/account
Must be SAME account as MyNodeOne uses
If different: Logout and login with correct account
```

**Check #3: Is MyNodeOne online?**
```
In Tailscale app, look for MyNodeOne device
Should show as "Online"
If offline: Check if MyNodeOne machine is powered on
```

---

### Problem: "Tailscale won't connect"

**Fix #1: Reinstall VPN Profile**
```
iPhone:
1. Settings → General → VPN & Device Management
2. Remove Tailscale VPN profile
3. Re-open Tailscale app
4. Tap "Connect" → Allow new profile

Android:
1. Settings → Network → VPN
2. Remove Tailscale
3. Re-open Tailscale app
4. Tap "Connect" → Allow
```

**Fix #2: Check Network**
```
Try switching between WiFi and mobile data
Some public WiFi blocks VPNs
Use mobile data to test
```

**Fix #3: Update App**
```
App Store/Play Store → Updates
Update Tailscale to latest version
```

---

### Problem: "Mobile app can't find server"

**Check #1: Tailscale is running**
```
Swipe down (notifications)
Should see "Tailscale connected" or similar
If not: Open Tailscale app and connect
```

**Check #2: Correct server URL**
```
Common mistakes:
❌ https://immich.mynodeone.local (wrong - no https)
❌ http://immich.mynodeone.com (wrong - .com not .local)
✅ http://immich.mynodeone.local (correct!)

Double-check the exact URL from installation output
```

**Check #3: DNS resolution**
```
Open Safari/Chrome on phone
Try: http://mynodeone.local
If that works, DNS is fine
If not, wait 5 minutes and try again (DNS propagation)
```

---

### Problem: "Works at home but not on mobile data"

**This is normal if Tailscale is OFF!**

**Check:**
```
Open Tailscale app
Is it connected? 
If "Disconnected": Tap to connect
```

**Background App Refresh (iPhone):**
```
Settings → General → Background App Refresh
Enable for Tailscale
This keeps VPN connected
```

**Battery Optimization (Android):**
```
Settings → Apps → Tailscale
Battery → Unrestricted
Prevents Android from killing Tailscale
```

---

## 💡 Pro Tips

### 1. Keep Tailscale Running
```
Don't force-quit Tailscale app
Let it run in background
Uses minimal battery (<2%)
Ensures instant access to apps
```

### 2. Use On-Demand VPN (iOS)
```
Tailscale app → Settings
Enable "On Demand"
Automatically connects when needed
Disconnects when not in use
```

### 3. Create Widgets (if available)
```
Tailscale widget shows connection status
Quick access to connect/disconnect
Add to home screen for convenience
```

### 4. Share Access with Family
```
Family members need:
1. Tailscale account (can be their own OR shared)
2. Access granted from admin console
3. Their own accounts on your apps

You control who can access what!
```

### 5. Monitor Battery Usage
```
Tailscale uses ~1-2% battery per day
If higher: Check for app updates
Modern phones handle VPNs efficiently
```

---

## 📊 Data Usage

**Good News: Minimal!**

### Tailscale Overhead
- **Connection:** ~1-5KB when connecting
- **Keep-Alive:** ~10-20KB per hour when idle
- **Active Use:** ~2-5% overhead on your data

### Example Scenarios

**Photo Backup (Immich):**
```
Uploading 100 photos (500MB):
Data used: 510MB (2% overhead)
```

**Streaming Movie (Jellyfin):**
```
2-hour movie (4GB):
Data used: 4.1GB (2.5% overhead)
```

**Password Sync (Vaultwarden):**
```
Syncing 500 passwords:
Data used: <1MB
```

**The overhead is negligible for normal use!**

---

## 🎉 Success! What Now?

### You Can Now:

✅ **Access dashboard from anywhere**
- `http://mynodeone.local`

✅ **Use mobile apps**
- Immich: Photo backup
- Jellyfin: Stream media
- Bitwarden: Password manager
- Nextcloud: File sync
- Mattermost: Team chat

✅ **Share with family**
- Create accounts for them
- They install Tailscale
- Everyone has private cloud access!

✅ **Work remotely**
- Access from office/school
- Encrypted and secure
- No corporate restrictions

---

## 📚 Related Guides

- **[BEGINNER-GUIDE.md](BEGINNER-GUIDE.md)** - Complete beginner's tutorial
- **[QUICK-START.md](QUICK-START.md)** - 10-minute quick start
- **[ACCESS-CHEAT-SHEET.md](ACCESS-CHEAT-SHEET.md)** - All URLs and commands
- **[APP-STORE.md](APP-STORE.md)** - Available applications

---

## ❓ Common Questions

**Q: Do I need Tailscale on every device?**  
A: Yes, every mobile device and laptop needs it. Your MyNodeOne control plane already has it.

**Q: Can I use a different VPN?**  
A: Technically yes, but NOT recommended. MyNodeOne is designed for Tailscale. Other VPNs require complex configuration.

**Q: Does Tailscale drain my battery?**  
A: Minimal impact (~1-2% per day). Modern phones handle VPNs efficiently.

**Q: Can I access without Tailscale?**  
A: On desktop/laptop with DNS setup: Yes. On mobile: No, Tailscale is required.

**Q: Is my data going through Tailscale's servers?**  
A: No! Data goes directly from your phone to MyNodeOne. Tailscale just coordinates the connection.

**Q: Can I share access with friends?**  
A: Yes! They install Tailscale and you grant access via admin console.

**Q: What if I forget to turn on Tailscale?**  
A: Apps won't connect. Just open Tailscale and tap "Connect". Takes 2 seconds.

---

**Enjoy your private cloud from anywhere in the world! 🌍✨**
