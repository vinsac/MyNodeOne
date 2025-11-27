# MyNodeOne Quick Start Guide
## Get Your First App Running in 10 Minutes

> **Perfect for:** Complete beginners who want to jump right in

---

## ⚡ Super Fast Track

### Step 1: Access Your Dashboard (30 seconds)
```
Open your browser and go to:
http://mynodeone.local
```

You'll see a beautiful dashboard with your cluster status and available apps.

---

### Step 2: Pick Your First App (30 seconds)

**Want Netflix?** → Install Jellyfin  
**Want Google Photos?** → Install Immich  
**Want Password Manager?** → Install Vaultwarden

Let's say you want **Jellyfin** (personal Netflix)...

---

### Step 3: Install the App (5 minutes)

**On your laptop:**
```bash
# Connect to your MyNodeOne machine
ssh user@mynodeone

# Run ONE command:
sudo ./scripts/apps/install-jellyfin.sh

# Wait 5 minutes while it installs
# (Go make coffee ☕)
```

**What's happening?**
- Downloading Jellyfin
- Setting up storage
- Creating your server
- Assigning it a web address

---

### Step 4: Open Your App (10 seconds)

```
Open browser, go to:
http://jellyfin.mynodeone.local
```

**That's it!** You now have a Netflix-like media server!

---

### Step 5: Complete Setup (3 minutes)

Follow the setup wizard:
1. Choose language
2. Create your account (username + password)
3. Add media folders
4. Done!

---

## 📱 Use on Your Phone

### ⚠️ IMPORTANT: Install Tailscale First!

**Your phone needs Tailscale to access your apps.**

**Why?** Apps run on a secure private network. Tailscale connects your phone to this network.

### Step 1: Install Tailscale (5 minutes, one-time)
- **iPhone:** App Store → Search "Tailscale" → Install
- **Android:** Play Store → Search "Tailscale" → Install
- Open app → Login (same account as MyNodeOne) → Connect
- ✅ Done! Phone can now access your cloud

### Step 2: Download the Jellyfin App
- **iPhone:** App Store → Search "Jellyfin"
- **Android:** Play Store → Search "Jellyfin"

### Step 3: Connect to Your Server
1. Open Jellyfin app
2. Add server
3. Enter: `http://jellyfin.mynodeone.local`
4. Login
5. Watch from anywhere - home, vacation, anywhere!

**💡 Tailscale is free and works everywhere (WiFi, mobile data, etc.)**

---

## 🎯 What's Next?

### Week 1: Get Comfortable
```bash
# Install photo backup (Google Photos replacement)
sudo ./scripts/apps/install-immich.sh
# Access: http://immich.mynodeone.local

# Install password manager
sudo ./scripts/apps/install-vaultwarden.sh
# Access: http://vaultwarden.mynodeone.local
```

### Week 2: Go Mobile
1. **Install Tailscale on phone** (required - see instructions above)
2. Download mobile apps from App Store/Play Store
3. Point them to `http://appname.mynodeone.local`
4. Use from anywhere - WiFi, mobile data, vacation!

### Week 3: Advanced Features
1. Install more apps from the app store
2. Set up automatic backups
3. Invite family members (they need Tailscale too)
4. Explore monitoring with Grafana

---

## 🔗 All App Addresses

After installation, apps are accessible at:

| App | Address | What It Does |
|-----|---------|--------------|
| **Dashboard** | `http://mynodeone.local` | Control center |
| **Jellyfin** | `http://jellyfin.mynodeone.local` | Media streaming |
| **Immich** | `http://immich.mynodeone.local` | Photo backup |
| **Vaultwarden** | `http://vaultwarden.mynodeone.local` | Password manager |
| **Nextcloud** | `http://nextcloud.mynodeone.local` | File storage |
| **Homepage** | `http://homepage.mynodeone.local` | App dashboard |
| **Mattermost** | `http://mattermost.mynodeone.local` | Team chat |
| **Minecraft** | `minecraft.mynodeone.local:25565` | Game server |

**Pattern:** `http://[appname].mynodeone.local`

---

## 🆘 Something Not Working?

### Can't access http://jellyfin.mynodeone.local?

**Fix DNS:**
```bash
# On MyNodeOne machine:
sudo ./scripts/setup-local-dns.sh

# On your laptop:
# Download the setup-client-dns.sh file from MyNodeOne
# Then run:
sudo bash setup-client-dns.sh
```

### App won't start?

**Check status:**
```bash
kubectl get pods -n jellyfin
# Replace 'jellyfin' with your app name
```

**See logs:**
```bash
kubectl logs -f deployment/jellyfin -n jellyfin
```

### Forgot your password?

**View credentials:**
```bash
sudo ./scripts/show-credentials.sh
```

---

## 💡 Tips for Success

### 1. Start Small
- Install 1-2 apps first
- Get comfortable using them
- Then add more

### 2. Use Mobile Apps
- Most apps have excellent mobile clients
- Download from official app stores
- Much better experience than mobile browsers

### 3. Bookmark Your Addresses
- Create bookmarks for your apps
- Or set `http://mynodeone.local` as homepage

### 4. Share with Family
- Family members can access apps too
- Just give them the web address
- They create their own accounts

### 5. Regular backups
- Longhorn (your storage system) has automatic snapshots
- You should still back up important data manually
- See [storage-guide.md](../storage-guide.md) and [operations.md](../operations.md) for storage and backup considerations

---

## 📚 Learn More

**For beginners:**
- [BEGINNER-GUIDE.md](BEGINNER-GUIDE.md) - comprehensive guide for non-technical users

**App details:**
- [APP-STORE.md](APP-STORE.md) - complete app catalog and features

**Troubleshooting:**
- [FAQ](../reference/FAQ.md) - common questions
- [troubleshooting.md](../troubleshooting.md) - fix common issues

**Advanced:**
- [INSTALLATION.md](INSTALLATION.md) - installation details
- [architecture.md](../architecture.md) - how it works

---

## 🎉 You're Ready!

**Remember:**
1. Open `http://mynodeone.local` → See available apps
2. Run install command → Wait 5 minutes  
3. Open `http://appname.mynodeone.local` → Start using!

**No coding. No configuration files. Just copy, paste, and go!**

---

**Questions?** Open an issue on GitHub or see the FAQ!

**Happy Self-Hosting! 🚀**
