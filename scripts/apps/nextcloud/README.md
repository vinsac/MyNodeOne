# Nextcloud - Cloud Storage

Your own cloud storage for files, photos, calendar, and contacts.

## What You Get

- ☁️ File storage and sync across devices
- 📱 Mobile apps for iOS and Android
- 🖥️ Desktop sync for Windows, Mac, Linux
- 📂 Share files with links or specific users
- 📸 Photo gallery with automatic organization
- 📅 Calendar sync (CalDAV)
- 👥 Contact sync (CardDAV)
- 📝 Document editing (with Collabora or OnlyOffice)
- 💬 Video calls and chat (with Talk app)

## Installation

```bash
sudo ./scripts/apps/nextcloud/install-nextcloud.sh
```

During installation, you'll be asked:
- **Subdomain**: Choose a name like `cloud`, `nextcloud`, or `files`
- **File Storage**: How much space for your files (default: 100Gi)
- **Database Storage**: How much space for metadata (default: 10Gi)
- **Public Access**: Whether to access from anywhere or just your home network

### Storage Selection

**File Storage:**
- **100Gi** - Good for personal use (~10,000 files)
- **500Gi** - Good for small family (recommended)
- **1Ti** - Good for large family or small team
- **2Ti+** - Good for teams or extensive media libraries

**Database Storage:**
- **10Gi** - Good for personal use (recommended)
- **20Gi** - Good for families or small teams
- **50Gi** - Good for large teams

## Access

### Local Access
```
http://nextcloud.minicloud.local
```
(Replace `nextcloud` with your chosen subdomain and `minicloud` with your cluster domain)

### First-Time Setup

1. Open Nextcloud in your browser
2. Log in with admin credentials (shown during installation)
3. Skip recommended apps for now
4. Install apps you need from Settings → Apps

**Save your admin password!** You can retrieve it later:
```bash
kubectl get secret nextcloud-admin -n nextcloud -o jsonpath='{.data.admin-password}' | base64 -d
```

## Mobile Apps

### iOS
1. Download "Nextcloud" from App Store
2. Enter server URL: `http://nextcloud.minicloud.local` (or your public domain)
3. Log in with your credentials
4. Enable auto-upload for photos

### Android
1. Download "Nextcloud" from Play Store
2. Enter server URL and log in
3. Enable auto-upload for photos

## Storage Management

### Need More Storage?

Run the storage expansion script:
```bash
sudo ./scripts/apps/nextcloud/expand-storage.sh
```

You can expand:
- **File storage** - For more photos, documents, videos
- **Database storage** - For more users, apps, metadata

The script will:
1. Show current storage usage
2. Recommend new sizes
3. Safely expand without downtime
4. No pod restart required

## Desktop Sync

Download from: https://nextcloud.com/install/#install-clients

Available for:
- Windows 10/11
- macOS 10.14+
- Linux

## Recommended Apps

Install from Settings → Apps:

**Essential:**
- **Calendar** - Sync calendar with devices
- **Contacts** - Sync contacts with devices
- **Photos** - Beautiful photo gallery
- **Activity** - Track file changes

**Optional:**
- **Collabora Online** - Edit office documents
- **Talk** - Video calls and chat
- **Mail** - Email client
- **Notes** - Note taking
- **Bookmarks** - Bookmark manager

## Common Tasks

### Restart Nextcloud
```bash
kubectl rollout restart deployment/nextcloud -n nextcloud
```

### Check if Running
```bash
kubectl get pods -n nextcloud
```

### View Logs
```bash
kubectl logs -f deployment/nextcloud -n nextcloud
```

## Access from Anywhere

To access Nextcloud when you're away from home:

```bash
sudo ./scripts/manage-app-visibility.sh
```

**Note:** SSL certificate may take 2-3 minutes to issue. This is normal.

## Problems?

### Can't Log In

Retrieve your admin password:
```bash
kubectl get secret nextcloud-admin -n nextcloud -o jsonpath='{.data.admin-password}' | base64 -d
```

### Trusted Domain Error

Add your domain to trusted list:
```bash
kubectl exec -n nextcloud deployment/nextcloud -- \
  su -s /bin/bash www-data -c \
  "php occ config:system:set trusted_domains 2 --value='yourdomain.com'"
```

### Can't Upload Large Files

Increase PHP limits:
```bash
kubectl set env deployment/nextcloud -n nextcloud \
  PHP_MEMORY_LIMIT=2G \
  PHP_UPLOAD_LIMIT=16G
```

### Slow Performance

Check resources:
```bash
kubectl top pods -n nextcloud
kubectl logs -f deployment/nextcloud -n nextcloud
```

## Uninstall

```bash
sudo ./scripts/apps/nextcloud/uninstall-nextcloud.sh
```

**WARNING:** This will delete all files and data permanently!

## Need Help?

- Official Documentation: https://docs.nextcloud.com/
- Community Forum: https://help.nextcloud.com/
