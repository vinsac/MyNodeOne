# MyNodeOne Beginner's Guide
## Your Personal Cloud Made Simple

> **Who is this for?** Anyone who wants their own Netflix, Google Photos, or password manager without paying monthly fees to big tech companies. No coding or IT experience needed!

---

## 🎯 What is MyNodeOne?

Think of MyNodeOne as **your personal app store** - like the App Store on iPhone or Google Play on Android - except:
- ✅ All apps run on **YOUR hardware** (not someone else's server)
- ✅ **One-time setup** (no monthly subscriptions)
- ✅ **Complete privacy** (your data never leaves your home)
- ✅ **Professional apps** (same quality as Netflix, Spotify, etc.)

---

## 📱 What Can You Actually Do With It?

### Replace These Services:

| Instead of Paying For... | Install This (Free) | Savings/Year |
|--------------------------|---------------------|--------------|
| Netflix ($240/year) | **Jellyfin** | $240 |
| Google Photos ($100/year) | **Immich** | $100 |
| 1Password ($36/year) | **Vaultwarden** | $36 |
| Dropbox ($120/year) | **Nextcloud** | $120 |
| Slack ($96/year) | **Mattermost** | $96 |
| Minecraft Realm ($80/year) | **Minecraft Server** | $80 |
| **TOTAL SAVINGS** | | **$672/year** |

**Your Cost:** Old laptop/mini PC you already own + $5/month electricity = **$60/year**

**Net Savings: $612/year** 💰

---

## 🚀 How Does Installation Work?

### The Super Simple Version:

```
Step 1: Install MyNodeOne (one command, 30 minutes)
   ↓
Step 2: Open http://mynodeone.local in your browser
   ↓
Step 3: Click on an app you want (like Jellyfin for movies)
   ↓
Step 4: Copy the command shown
   ↓
Step 5: Paste it in your terminal and press Enter
   ↓
Step 6: Wait 5 minutes while it installs
   ↓
Step 7: Open the app in your browser - it's ready to use!
```

**That's it!** No configuration files, no code, no complicated setup.

---

## 📦 Apps You Can Install (Explained Simply)

### 🎬 Media & Entertainment

#### **Jellyfin** - Your Personal Netflix
**What it does:** Stream your movies and TV shows to any device
**Why you want it:** 
- Watch your movie collection on your TV, phone, or laptop
- No monthly fees unlike Netflix/Hulu
- Automatic artwork and descriptions for all your movies

**How to use:**
1. Install with: `sudo ./scripts/apps/install-jellyfin.sh`
2. Open the URL shown (like http://jellyfin.mynodeone.local)
3. Create your account (first user becomes admin)
4. Add your movie folders (like /media/Movies)
5. Download Jellyfin app on your phone/TV
6. Watch anywhere in your home!

**Perfect for:** Families with large movie collections, cord-cutters

**Access:** http://jellyfin.mynodeone.local

---

#### **Minecraft Server** - Host Your Own Game
**What it does:** Run a Minecraft server for you and your friends
**Why you want it:**
- Play with friends without paying for Realms ($8/month)
- Full control over mods, settings, world
- Always online, even when your computer is off

**How to use:**
1. Install with: `sudo ./scripts/apps/install-minecraft.sh`
2. Note the server address (like mynodeone.local:25565)
3. Open Minecraft → Multiplayer → Add Server
4. Enter the address → Play!

**Perfect for:** Kids, gamers, friend groups

**Access:** minecraft.mynodeone.local:25565

---

### 📸 Photos & Files

#### **Immich** - Your Personal Google Photos
**What it does:** Automatically backup all photos from your phone
**Why you want it:**
- Never lose photos if you lose your phone
- Unlimited storage (not 15GB limit like Google)
- AI face recognition - search "beach" or "birthday"
- Share albums with family
- Keep your private photos PRIVATE

**How to use:**
1. Install with: `sudo ./scripts/apps/install-immich.sh`
2. Open the URL (like http://immich.mynodeone.local)
3. Create your account
4. Download Immich app from App Store or Play Store
5. Open app → Settings → Server URL → Enter the address
6. Enable auto-upload
7. Your photos backup automatically!

**Perfect for:** Everyone with a smartphone

**Access:** http://immich.mynodeone.local

---

#### **Nextcloud** - Your Personal Dropbox
**What it does:** Store and sync files across all your devices
**Why you want it:**
- Replace Dropbox/Google Drive/OneDrive
- Unlimited storage (based on your hard drive)
- Share files with family via links
- Edit documents in browser
- Calendar and contacts sync

**How to use:**
1. Install with: `sudo ./scripts/apps/install-nextcloud.sh`
2. Open URL and create account
3. Download Nextcloud app on phone/computer
4. Files automatically sync like Dropbox

**Perfect for:** Families, small teams, anyone tired of "storage full" messages

**Access:** http://nextcloud.mynodeone.local

---

### 🔐 Security & Privacy

#### **Vaultwarden** - Your Personal Password Manager
**What it does:** Securely store all your passwords
**Why you want it:**
- One strong password to remember instead of 100
- Generate strong passwords automatically
- Auto-fill passwords on websites
- Access on all devices (phone, laptop, tablet)
- Cheaper than 1Password/Dashlane

**How to use:**
1. Install with: `sudo ./scripts/apps/install-vaultwarden.sh`
2. **SAVE THE ADMIN TOKEN** shown (very important!)
3. Open URL (like http://vaultwarden.mynodeone.local)
4. Create your account with a STRONG master password
5. Install Bitwarden extension in Chrome/Firefox
6. Install Bitwarden app on phone
7. Configure extension/app to use your server URL
8. Start saving passwords!

**Perfect for:** Everyone (seriously, everyone needs this)

**Access:** http://vaultwarden.mynodeone.local

---

### 💬 Communication

#### **Mattermost** - Your Personal Slack
**What it does:** Team chat with channels, direct messages, file sharing
**Why you want it:**
- Free team chat (Slack charges $8/person/month)
- Video calls included
- Unlimited message history
- Private - your company chats stay in-house

**How to use:**
1. Install with: `sudo ./scripts/apps/install-mattermost.sh`
2. Open URL and create first account (becomes admin)
3. Create teams and invite people
4. Download mobile/desktop apps
5. Configure to use your server

**Perfect for:** Small businesses, families, gaming clans

**Access:** http://mattermost.mynodeone.local

---

### 🏠 Dashboard & Organization

#### **Homepage** - Beautiful Dashboard
**What it does:** One page to access all your apps
**Why you want it:**
- Bookmarks to all your self-hosted apps
- See status of all services at a glance
- Customizable with widgets
- Looks professional

**How to use:**
1. Install with: `sudo ./scripts/apps/install-homepage.sh`
2. Open URL
3. Customize layout in settings
4. Set as browser homepage

**Perfect for:** Power users running many apps

**Access:** http://homepage.mynodeone.local

---

## 🌐 How Do You Access Apps?

### 🎉 Every App Gets Its Own Easy Address!

**The Magic:** When you install an app, it automatically gets a simple web address:

```
App Name          →  Web Address
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Jellyfin          →  http://jellyfin.mynodeone.local
Immich            →  http://immich.mynodeone.local
Vaultwarden       →  http://vaultwarden.mynodeone.local
Nextcloud         →  http://nextcloud.mynodeone.local
Mattermost        →  http://mattermost.mynodeone.local
Minecraft Server  →  minecraft.mynodeone.local:25565
```

**No IP addresses to remember!** Just type the app name + `.mynodeone.local`

### Option 1: From Your Laptop/Desktop (Works Immediately!)

After running the DNS setup script, access from any browser:

**Example:** After installing Jellyfin
1. Open Chrome/Safari/Firefox
2. Type: `http://jellyfin.mynodeone.local`
3. Press Enter
4. Jellyfin loads instantly!

**Works on:**
- ✅ Your laptop (with DNS setup complete)
- ✅ Your desktop computer
- ✅ Any device that ran `setup-client-dns.sh`

### Option 2: From Your Phone/Tablet (Install Tailscale - 5 Minutes!)

**📱 IMPORTANT: Mobile devices need Tailscale to access your apps**

**Why?** Apps run on a private Tailscale network for security. Your phone needs to join this network.

**Setup (One-Time, 5 Minutes):**

1. **Install Tailscale app**
   - iPhone: App Store → Search "Tailscale"
   - Android: Play Store → Search "Tailscale"

2. **Login**
   - Open Tailscale app
   - Login with the SAME account you used for MyNodeOne
   - Tap "Connect"

3. **Done!** Now open Safari/Chrome on phone:
   - Type: `http://jellyfin.mynodeone.local`
   - Works perfectly!

**What Tailscale Does:**
- Creates secure VPN connection (encrypted)
- Free for personal use
- Lets your phone access your private cloud
- Works from anywhere (home, coffee shop, vacation)

**Bonus:** Once Tailscale is installed, you can access your apps from ANYWHERE:
- ✅ At home on WiFi
- ✅ On mobile data
- ✅ At coffee shop
- ✅ On vacation
- ✅ At work
- ✅ Literally anywhere with internet!

### Option 3: Public Access (Advanced, Not Recommended for Beginners)
For services you want to share with people NOT on your Tailscale:
- Set up custom domain (like jellyfin.yourfamily.com)
- Requires VPS edge node (~$5/month)
- See EDGE_NODE_GUIDE.md
- Security considerations apply!

---

## 🎓 Step-by-Step: Your First App (Jellyfin)

### What You'll Need:
- ✅ MyNodeOne already installed (completed bootstrap-control-plane.sh)
- ✅ Laptop connected to same network
- ✅ Some movie files (MP4, MKV, etc.)

### Steps:

#### 1. Install Jellyfin (2 minutes)
```bash
# SSH into your MyNodeOne machine
ssh user@mynodeone

# Run the installation command
sudo ./scripts/apps/install-jellyfin.sh
```

**What happens:**
- Script downloads Jellyfin
- Creates storage space
- Assigns it a web address
- Shows you where to access it

#### 2. Open Jellyfin in Browser (1 minute)
```
The script will show something like:
"Access Jellyfin at: http://jellyfin.mynodeone.local"

Copy that URL and open it in your web browser
```

#### 3. Setup Wizard (5 minutes)
1. **Language:** Select your language
2. **User Account:** 
   - Username: Choose anything (like "admin" or your name)
   - Password: Pick a strong password
3. **Media Libraries:**
   - Click "Add Media Library"
   - Type: Movies
   - Folder: Click "+" and select where your movies are
   - Click OK
4. **Remote Access:** Skip this for now
5. **Finish!**

#### 4. Add Your Movies (varies)
**Copy movies to your MyNodeOne machine:**

**Option A: USB Drive**
```bash
# Plug USB drive into MyNodeOne
# Copy files
sudo cp -r /media/usb/Movies/* /var/lib/longhorn/jellyfin/media/
```

**Option B: Network Share**
```bash
# From your laptop, use file browser:
# Navigate to: smb://mynodeone.local/jellyfin
# Drag and drop movie files
```

Jellyfin automatically scans and adds them!

#### 5. Install Tailscale on Your Phone (Required!)
**Before using mobile apps, install Tailscale:**

**On iPhone:**
1. App Store → Search "Tailscale" → Install
2. Open Tailscale → Login (same account as MyNodeOne)
3. Tap "Connect"

**On Android:**
1. Play Store → Search "Tailscale" → Install
2. Open Tailscale → Login (same account as MyNodeOne)
3. Tap "Connect"

**✅ Done!** Your phone can now access your MyNodeOne apps.

#### 6. Install Mobile Apps
**On iPhone:**
- App Store → Search "Jellyfin" → Install
- Open app → Add Server → Enter: http://jellyfin.mynodeone.local
- Login with your account
- Start watching!

**On Android:**
- Play Store → Search "Jellyfin" → Install  
- Same steps as iPhone

**📱 Tip:** Keep Tailscale running in the background for best experience.

#### 7. Watch on TV
**Smart TV/Roku/Fire TV:**
- Install Jellyfin app from TV's app store
- Enter server address
- Login and enjoy!

**🎉 Done! You now have your personal Netflix!**

---

## 📱 Mobile Apps for Your Self-Hosted Services

| Service | iOS App | Android App | How Good? |
|---------|---------|-------------|-----------|
| Immich | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐⭐⭐ Excellent | Better than Google Photos! |
| Jellyfin | ⭐⭐⭐⭐ Great | ⭐⭐⭐⭐ Great | Smooth streaming |
| Vaultwarden | ⭐⭐⭐⭐⭐ Perfect | ⭐⭐⭐⭐⭐ Perfect | Use official Bitwarden app |
| Nextcloud | ⭐⭐⭐⭐ Great | ⭐⭐⭐⭐ Great | Auto file upload |
| Mattermost | ⭐⭐⭐⭐⭐ Excellent | ⭐⭐⭐⭐⭐ Excellent | Like native Slack |
| Minecraft | ⭐⭐⭐⭐⭐ Perfect | ⭐⭐⭐⭐⭐ Perfect | Official Minecraft app |

---

## ❓ Common Questions

### "Is this legal?"
**Yes!** You're running software on your own hardware. It's like running Microsoft Word on your laptop - completely legal. The apps are open source and free to use.

### "Will Netflix/Google know?"
**No.** You're not connecting to their services. These are completely separate apps that you control.

### "What if something breaks?"
Each app is isolated. If Jellyfin breaks, your photos in Immich are fine. You can always:
```bash
# Uninstall broken app
kubectl delete namespace jellyfin

# Reinstall fresh
sudo ./scripts/apps/install-jellyfin.sh
```

### "Can I access from outside my home?"
**Yes!** Install Tailscale app on your phone (free):
1. Install Tailscale on phone
2. Login with same account
3. Access apps anywhere with full encryption

### "Do I need to know Linux?"
**No!** You need to know how to:
- Copy and paste commands
- Press Enter
- That's it!

### "What if I mess up?"
You literally can't break anything permanently:
- Wrong command? Nothing happens
- Delete something? Data is backed up
- Want to start over? Reinstall takes 30 minutes

### "How much does this cost?"
**Hardware:** Old laptop/mini PC you probably have ($0-$200)
**Electricity:** ~$5/month
**Internet:** You already have this
**Software:** FREE (all apps are open source)

**Monthly cost: ~$5**

Compare to:
- Netflix + Google Photos + Dropbox + 1Password = $40/month
- **Savings: $35/month = $420/year**

---

## 🆘 Troubleshooting for Beginners

### Problem: "Can't access http://jellyfin.mynodeone.local"

**Solution:**
```bash
# On your MyNodeOne machine, run:
sudo ./scripts/setup-local-dns.sh

# On your laptop, download and run:
# The setup-client-dns.sh file (generated by above command)
sudo bash setup-client-dns.sh
```

This sets up the ".local" addresses.

---

### Problem: "App installed but can't login"

**Solution:** Check the installation output - it shows username and password.

Or run:
```bash
# See all credentials
sudo ./scripts/show-credentials.sh
```

---

### Problem: "Out of storage"

**Solution:**
```bash
# Check storage
kubectl get pv

# If full, add more disk space or delete old apps:
kubectl delete namespace <old-app-name>
```

---

### Problem: "App is slow"

**Solution:** Check resources:
```bash
# See what's using resources
kubectl top nodes
kubectl top pods -A
```

Might need to:
- Add more RAM to your machine
- Add a worker node (another computer)

---

## 🎯 Next Steps

### Week 1: Get Comfortable
- [ ] Install Jellyfin and watch a movie
- [ ] Install Immich and backup your photos
- [ ] Install Vaultwarden and save some passwords

### Week 2: Add More
- [ ] Install Nextcloud and sync files
- [ ] Install Homepage for a nice dashboard
- [ ] Invite family members to your services

### Week 3: Go Mobile
- [ ] Install mobile apps
- [ ] Set up Tailscale for remote access
- [ ] Share Jellyfin with family

### Month 2: Advanced
- [ ] Set up automatic backups
- [ ] Add a second machine (worker node)
- [ ] Explore more apps in the store

---

## 💡 Real-World Examples

### Example 1: Family Media Server
**Sarah's Setup:**
- Old laptop (2016, $0)
- 2TB external hard drive ($60)
- Installed: Jellyfin + Immich + Homepage
- **Result:** Family of 4 canceled Netflix, backs up 50,000 photos
- **Savings: $360/year**

### Example 2: Small Business
**Mike's Coffee Shop:**
- Mini PC ($150)
- Installed: Mattermost + Nextcloud
- **Result:** Team communication, file sharing, no monthly fees
- **Savings: $150/month = $1,800/year**

### Example 3: Student
**Alex's Dorm Setup:**
- Old gaming PC (repurposed)
- Installed: Vaultwarden + Gitea + Minecraft
- **Result:** Secure passwords, code projects, Minecraft with friends
- **Savings: $200/year + priceless learning**

---

## 📚 Resources

### Video Guides (Coming Soon)
- [ ] MyNodeOne Installation
- [ ] Installing Your First App
- [ ] Mobile App Setup
- [ ] Troubleshooting Common Issues

### Written Guides
- [APP-STORE.md](APP-STORE.md) - Complete app catalog
- [INSTALLATION.md](INSTALLATION.md) - Installation details
- [FAQ.md](FAQ.md) - Frequently asked questions

### Community
- GitHub Discussions: Ask questions
- Issue Tracker: Report problems
- Discord: Chat with other users (coming soon)

---

## 🎉 You've Got This!

Remember: **Every expert was once a beginner.**

- You don't need to understand Kubernetes
- You don't need to know Docker
- You don't need to write code
- You just need to copy, paste, and press Enter

**Welcome to the world of self-hosting! 🚀**

---

*Last Updated: October 2024*
*Questions? Open an issue on GitHub!*
