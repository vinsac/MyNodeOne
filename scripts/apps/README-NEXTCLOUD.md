# Nextcloud - Cloud Storage Platform

Complete cloud storage and collaboration platform - self-hosted alternative to Google Drive, Dropbox, and Microsoft 365.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [One-Click Installation](#one-click-installation)
- [Admin Credentials](#admin-credentials)
- [Access Methods](#access-methods)
- [SSL Certificate Timing](#ssl-certificate-timing)
- [First-Time Setup](#first-time-setup)
- [Mobile & Desktop Apps](#mobile--desktop-apps)
- [Recommended Apps](#recommended-apps)
- [Troubleshooting](#troubleshooting)
- [Management](#management)

---

## 🌟 Overview

Nextcloud is a comprehensive cloud storage and collaboration platform that gives you complete control over your data.

**What it replaces:**
- Google Drive (file storage)
- Google Photos (photo backup)
- Google Calendar (calendar sync)
- Google Contacts (contact sync)
- Gmail (mail client via app)
- Zoom (video calls via Talk app)
- Office 365 (document editing via Collabora/OnlyOffice)

**Technology Stack:**
- **Application:** Nextcloud 28 (Apache + PHP 8.2)
- **Database:** PostgreSQL 15
- **Cache:** Redis 7
- **Storage:** Longhorn persistent volumes

---

## ✨ Features

### **Core Features:**
- ☁️ **File Storage & Sync** - Upload, download, sync across devices
- 📱 **Mobile Apps** - iOS & Android with auto-upload
- 🖥️ **Desktop Clients** - Windows, macOS, Linux sync
- 📂 **File Sharing** - Share with links or specific users
- 📸 **Photo Gallery** - Automatic photo organization
- 📅 **Calendar** - CalDAV sync with all devices
- 👥 **Contacts** - CardDAV contact management
- 📝 **Document Editing** - Collabora Online or OnlyOffice
- 💬 **Video Calls** - Talk app for calls & chat
- 📧 **Email Client** - Built-in mail app

### **Advanced Features:**
- 🔒 **End-to-End Encryption** - Encrypt sensitive files
- 👥 **User Management** - Multiple users, groups, permissions
- 📊 **Activity Monitoring** - Track file changes
- 🔄 **Version Control** - Restore previous file versions
- 🗂️ **External Storage** - Connect S3, SMB, FTP, WebDAV
- 🔐 **Two-Factor Authentication** - TOTP, U2F security keys
- 📱 **Automatic Photo Upload** - From mobile devices
- 🔍 **Full-Text Search** - Find files by content

---

## 🚀 One-Click Installation

### **Prerequisites:**
- Kubernetes cluster running (K3s)
- Longhorn storage configured
- kubectl configured and accessible

### **Install Command:**
```bash
sudo bash scripts/apps/install-nextcloud.sh
```

### **Installation Prompts:**

#### **1. Subdomain:**
```
Choose a subdomain for Nextcloud:
Examples: cloud, nextcloud, files, drive

Enter subdomain [default: nextcloud]: cloud
```
This will create:
- Local: `http://cloud.mynodeone.local`
- Public: `https://cloud.yourdomain.com`

#### **2. Public Access (Optional):**
```
Configure internet access? [Y/n]: y
Enter your public domain: example.com
```

### **What Gets Deployed:**

| Component | Image | Storage | Purpose |
|-----------|-------|---------|---------|
| Nextcloud | nextcloud:28-apache | 100Gi | Main application |
| PostgreSQL | postgres:15-alpine | 10Gi | Database |
| Redis | redis:7-alpine | - | Caching |

### **Resource Requirements:**
- **CPU:** ~350m (burst to 1.7 cores)
- **RAM:** ~1-3.5Gi
- **Storage:** ~110Gi (expandable)

---

## 🔐 Admin Credentials

### **During Installation:**

The installation script automatically:
1. Generates a secure random admin password
2. Displays it in the terminal output:
```
🔐 Admin Credentials:
   Username: admin
   Password: JD9BFkNweK2QnqQA

⚠️  IMPORTANT: Save your admin password!
   You can also retrieve it later with:
   kubectl get secret nextcloud-admin -n nextcloud -o jsonpath='{.data.admin-password}' | base64 -d
```

### **Retrieve Later:**

If you lose the password, retrieve it with:
```bash
# Get admin password
kubectl get secret nextcloud-admin -n nextcloud \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo

# Or view all secrets
kubectl get secrets -n nextcloud
kubectl describe secret nextcloud-admin -n nextcloud
```

### **Reset Admin Password:**

If needed, reset the password:
```bash
# Using occ command
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ user:resetpassword admin"
```

---

## 🌐 Access Methods

### **Local Access (Internal Network):**

```
http://nextcloud.mynodeone.local
```

**Features:**
- ✅ No SSL required (local network)
- ✅ Fast direct access to cluster
- ✅ No external dependencies
- ✅ Works immediately after installation

**DNS:** Automatically configured in `/etc/hosts`

### **Public Access (Internet):**

```
https://nextcloud.yourdomain.com
```

**Features:**
- ✅ Automatic SSL via Let's Encrypt
- ✅ Secure HTTPS encryption
- ✅ Access from anywhere
- ✅ Required for mobile apps (outside network)

**Requirements:**
1. VPS edge node configured
2. DNS A record: `nextcloud.yourdomain.com → VPS_IP`
3. Wait 1-3 minutes for SSL certificate

---

## 🔒 SSL Certificate Timing

### **Important: Certificate Issuance Delay**

When you configure public access, you may see **"TRAEFIK DEFAULT CERT"** for the first 1-3 minutes.

**This is completely normal!** Here's what happens:

| Time | What's Happening | What You See |
|------|------------------|--------------|
| 0-30s | VPS route created, Traefik sees new domain | Default cert |
| 30-90s | Let's Encrypt HTTP-01 challenge in progress | Default cert |
| 90-180s | Certificate issued and installed | Valid cert ✅ |

### **Why the Delay?**

1. **DNS Propagation:** Let's Encrypt must verify domain ownership
2. **HTTP-01 Challenge:** Traefik must respond to Let's Encrypt challenge
3. **Certificate Generation:** Let's Encrypt issues and signs certificate
4. **Certificate Installation:** Traefik loads new certificate

### **What To Do:**

✅ **DO:**
- Install Nextcloud normally
- Configure DNS A record
- **Wait 2-3 minutes** before checking certificate
- Refresh browser after waiting

❌ **DON'T:**
- Check certificate immediately (< 1 minute)
- Panic if you see default cert initially
- Try to "fix" anything before 3 minutes

### **Verify Certificate:**

After 2-3 minutes, check:
```bash
echo | openssl s_client -servername nextcloud.yourdomain.com \
  -connect nextcloud.yourdomain.com:443 2>/dev/null | \
  openssl x509 -noout -subject -issuer
```

**Expected output:**
```
subject=CN = nextcloud.yourdomain.com
issuer=C = US, O = Let's Encrypt, CN = R13
```

### **If Certificate Doesn't Issue After 5 Minutes:**

1. **Check DNS:**
   ```bash
   dig +short nextcloud.yourdomain.com
   # Should return your VPS public IP
   ```

2. **Check VPS connectivity:**
   ```bash
   curl -I https://nextcloud.yourdomain.com
   ```

3. **Restart Traefik on VPS:**
   ```bash
   ssh root@YOUR_VPS_IP
   docker restart traefik
   ```

4. **Check Traefik logs:**
   ```bash
   ssh root@YOUR_VPS_IP
   docker logs traefik --tail 100 | grep -i error
   ```

---

## 🎯 First-Time Setup

### **1. Access Nextcloud**

Open in browser:
- Local: `http://nextcloud.mynodeone.local`
- Public: `https://nextcloud.yourdomain.com`

### **2. Log In**

```
Username: admin
Password: [from installation output]
```

### **3. Skip Recommended Apps (For Now)**

- Click **"Skip"** or **"Install later"**
- We'll install specific apps next

### **4. Install Essential Apps**

Go to: **Settings** → **Apps** → **Browse**

**Recommended:**
- ✅ **Calendar** - Sync calendar with devices
- ✅ **Contacts** - Sync contacts with devices
- ✅ **Photos** - Beautiful photo gallery
- ✅ **Files External Storage** - Connect external storage
- ✅ **Activity** - Track file changes

**Optional:**
- 📝 **Collabora Online** - Office documents (requires separate server)
- 📝 **OnlyOffice** - Alternative office suite
- 💬 **Talk** - Video calls & chat
- 📧 **Mail** - Email client
- 🎵 **Music** - Music player
- 📚 **Bookmarks** - Bookmark manager

### **5. Configure Settings**

**Basic Settings:**
```
Settings → Administration → Basic settings
- Email server (for notifications)
- Background jobs (use Cron)
- Default language & locale
```

**Security:**
```
Settings → Security
- Enable two-factor authentication
- Set up brute-force protection
- Configure session timeout
```

### **6. Create Regular Users**

**Don't use admin account for daily use!**

Create a regular user:
```
Settings → Users → + Create user
- Username: yourname
- Display name: Your Name
- Password: [secure password]
- Groups: [optional]
```

Then log out and log in with your regular account.

---

## 📱 Mobile & Desktop Apps

### **Mobile Apps:**

#### **iOS:**
1. Open **App Store**
2. Search: **"Nextcloud"**
3. Install official Nextcloud app
4. Configure:
   - Server URL: `https://nextcloud.yourdomain.com`
   - Username: `yourname`
   - Password: `[your password]`
5. Enable **"Auto upload"** for photos

#### **Android:**
1. Open **Google Play Store**
2. Search: **"Nextcloud"**
3. Install official Nextcloud app
4. Configure same as iOS
5. Enable **"Auto upload"** for photos

**Features:**
- 📸 Automatic photo backup
- 📂 File sync and offline access
- 📅 Calendar sync
- 👥 Contact sync
- 🔒 End-to-end encryption
- 📱 Upload from camera

### **Desktop Sync Clients:**

#### **Download:**
https://nextcloud.com/install/#install-clients

#### **Supported Platforms:**
- Windows 10/11
- macOS 10.14+
- Linux (AppImage, deb, rpm)

#### **Setup:**
1. Install desktop client
2. Enter server URL: `https://nextcloud.yourdomain.com`
3. Log in with credentials
4. Choose folders to sync
5. Files sync automatically

**Features:**
- 🔄 Two-way sync
- 🌐 Selective sync (choose folders)
- 📂 Virtual files (on-demand download)
- 🔒 End-to-end encryption
- 📊 Activity monitoring
- ⚡ Fast sync engine

---

## 🔧 Recommended Apps

### **Productivity:**

#### **Collabora Online** (Office Documents)
- Edit Word, Excel, PowerPoint files
- Real-time collaboration
- Requires: Separate CODE server

**Install:**
```bash
# Option 1: Built-in CODE server (simple but slow)
Settings → Apps → Office & text → Collabora Online - Built-in CODE Server

# Option 2: Dedicated server (fast, recommended)
# Deploy Collabora CODE separately, then install Collabora Online app
```

#### **OnlyOffice** (Alternative Office Suite)
- Edit office documents
- Better Microsoft Office compatibility
- Requires: Separate OnlyOffice Document Server

### **Communication:**

#### **Talk** (Video Calls & Chat)
- One-on-one video calls
- Group conversations
- Screen sharing
- File sharing in chat

**Install:**
```
Settings → Apps → Social & communication → Talk
```

#### **Mail** (Email Client)
- Read and send emails
- Connect IMAP/SMTP accounts
- Unified inbox

### **Media:**

#### **Photos** (Photo Gallery)
- Timeline view
- Albums and favorites
- Face recognition
- Maps (with GPS data)

#### **Music** (Music Player)
- Stream music files
- Playlists
- Album covers

### **Organization:**

#### **Notes** (Note Taking)
- Rich text notes
- Markdown support
- Categories and tags

#### **Bookmarks** (Bookmark Manager)
- Save web bookmarks
- Organize with tags
- Browser extensions

### **Security:**

#### **End-to-End Encryption**
- Encrypt sensitive folders
- Client-side encryption
- Zero-knowledge

---

## 🐛 Troubleshooting

### **Issue 1: Local Domain Redirects to Public Domain**

**Symptom:**
```
http://nextcloud.mynodeone.local → redirects to → https://nextcloud.yourdomain.com
```

**Cause:** OVERWRITEHOST configuration forcing redirects

**Fix:**
```bash
# Remove OVERWRITEHOST from Nextcloud config
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ config:system:delete overwritehost"

# Remove OVERWRITEPROTOCOL to allow HTTP locally
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ config:system:delete overwriteprotocol"
```

### **Issue 2: "TRAEFIK DEFAULT CERT" After 10+ Minutes**

**Symptom:** SSL certificate still shows Traefik default after long wait

**Fix:**
```bash
# 1. Verify DNS is correct
dig +short nextcloud.yourdomain.com
# Should return your VPS public IP

# 2. Restart Traefik to trigger certificate request
ssh root@YOUR_VPS_IP
docker restart traefik

# 3. Wait 2-3 minutes and verify
echo | openssl s_client -servername nextcloud.yourdomain.com \
  -connect nextcloud.yourdomain.com:443 2>/dev/null | \
  openssl x509 -noout -subject -issuer
```

### **Issue 3: "Trusted Domain Error"**

**Symptom:**
```
Access through untrusted domain

You are accessing the server from an untrusted domain.
```

**Fix:**
```bash
# Add domain to trusted list
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c \
  "php occ config:system:set trusted_domains 2 --value='yourdomain.com'"

# Verify trusted domains
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ config:system:get trusted_domains"
```

### **Issue 4: Slow Performance**

**Check resources:**
```bash
# View pod resources
kubectl top pods -n nextcloud

# View logs for errors
kubectl logs -f deployment/nextcloud -n nextcloud
kubectl logs -f deployment/nextcloud-postgres -n nextcloud
kubectl logs -f deployment/nextcloud-redis -n nextcloud
```

**Optimize:**
```bash
# Enable Redis memory cache
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c \
  "php occ config:system:set redis host --value='nextcloud-redis'"

# Run maintenance mode tasks
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ maintenance:repair"
```

### **Issue 5: Can't Upload Large Files**

**Fix PHP limits:**
```bash
# Edit deployment to add environment variables
kubectl set env deployment/nextcloud -n nextcloud \
  PHP_MEMORY_LIMIT=2G \
  PHP_UPLOAD_LIMIT=16G
```

### **Issue 6: Database Locked**

**Symptom:** "Database is locked" errors

**Fix:**
```bash
# Run database maintenance
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ db:add-missing-indices"

kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ db:convert-filecache-bigint"
```

---

## 🔧 Management

### **View Logs:**
```bash
# Nextcloud application logs
kubectl logs -f deployment/nextcloud -n nextcloud

# PostgreSQL logs
kubectl logs -f deployment/nextcloud-postgres -n nextcloud

# Redis logs
kubectl logs -f deployment/nextcloud-redis -n nextcloud

# All pods
kubectl logs -f -l app=nextcloud -n nextcloud --all-containers
```

### **Restart Nextcloud:**
```bash
# Restart just Nextcloud
kubectl rollout restart deployment/nextcloud -n nextcloud

# Restart everything
kubectl rollout restart deployment -n nextcloud
```

### **Check Status:**
```bash
# View all resources
kubectl get all -n nextcloud

# View pods
kubectl get pods -n nextcloud

# View services
kubectl get svc -n nextcloud

# View persistent volumes
kubectl get pvc -n nextcloud

# Detailed pod info
kubectl describe pod -l app=nextcloud -n nextcloud
```

### **Access Shell:**
```bash
# Nextcloud container
kubectl exec -it deployment/nextcloud -n nextcloud -- bash

# Run occ commands
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c "php occ [command]"

# Examples:
# - php occ user:list
# - php occ files:scan --all
# - php occ maintenance:mode --on
# - php occ maintenance:mode --off
```

### **Backup Data:**
```bash
# Create backup of Nextcloud data
kubectl exec -n nextcloud deployment/nextcloud -- \
  tar -czf /tmp/nextcloud-backup.tar.gz /var/www/html

# Copy backup to local machine
kubectl cp nextcloud/[pod-name]:/tmp/nextcloud-backup.tar.gz ./nextcloud-backup.tar.gz

# Backup database
kubectl exec -n nextcloud deployment/nextcloud-postgres -- \
  pg_dump -U nextcloud nextcloud > nextcloud-db-backup.sql
```

### **Restore Data:**
```bash
# Stop Nextcloud
kubectl scale deployment nextcloud -n nextcloud --replicas=0

# Restore files
kubectl cp ./nextcloud-backup.tar.gz nextcloud/[pod-name]:/tmp/
kubectl exec -n nextcloud deployment/nextcloud -- \
  tar -xzf /tmp/nextcloud-backup.tar.gz -C /

# Restore database
cat nextcloud-db-backup.sql | kubectl exec -i -n nextcloud deployment/nextcloud-postgres -- \
  psql -U nextcloud nextcloud

# Start Nextcloud
kubectl scale deployment nextcloud -n nextcloud --replicas=1
```

### **Upgrade Nextcloud:**
```bash
# Update image to new version
kubectl set image deployment/nextcloud -n nextcloud \
  nextcloud=nextcloud:29-apache

# Or edit deployment
kubectl edit deployment nextcloud -n nextcloud
# Change: image: nextcloud:28-apache → nextcloud:29-apache

# Nextcloud will automatically run upgrade scripts
```

### **Uninstall:**
```bash
# Delete everything (including data!)
kubectl delete namespace nextcloud

# Or keep data and just remove apps
kubectl delete deployment --all -n nextcloud
kubectl delete service --all -n nextcloud
# PVCs remain for later use
```

---

## 📚 Additional Resources

### **Official Documentation:**
- Nextcloud Docs: https://docs.nextcloud.com/
- Admin Manual: https://docs.nextcloud.com/server/latest/admin_manual/
- User Manual: https://docs.nextcloud.com/server/latest/user_manual/

### **Community:**
- Forum: https://help.nextcloud.com/
- GitHub: https://github.com/nextcloud/server

### **Apps:**
- App Store: https://apps.nextcloud.com/
- Featured Apps: https://nextcloud.com/athome/

---

## 🎉 Summary

Nextcloud provides:
- ✅ Complete cloud storage solution
- ✅ Calendar and contact sync
- ✅ Photo backup and organization
- ✅ Document editing capabilities
- ✅ Video calls and chat
- ✅ Email client
- ✅ Full control over your data
- ✅ Privacy and security

**Your data, your rules!** 🚀

---

**Last Updated:** November 1, 2025
