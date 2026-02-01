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
http://nextcloud.mynodeone.local
```
(Replace `nextcloud` with your chosen subdomain and `mynodeone` with your cluster domain)

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
2. Enter server URL: `http://nextcloud.mynodeone.local` (or your public domain)
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

## Performance Tuning

### Need Better Performance?

Run the performance tuning script:
```bash
sudo ./scripts/apps/nextcloud/tune-performance.sh
```

Tune resources for:
- **Nextcloud server** - CPU and memory for file operations
- **PostgreSQL** - Database performance
- **PHP settings** - Upload limits and execution time

**Default resources:**
- Nextcloud: 1 CPU core, 2Gi RAM
- PostgreSQL: 0.5 CPU cores, 1Gi RAM
- Redis: 0.2 CPU cores, 512Mi RAM

**When to tune:**
- Multiple concurrent users
- Large file uploads/downloads
- Slow web interface
- Team usage (10+ users)

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
sudo ./scripts/operations/manage-app-visibility.sh
```

**What happens:**
1. Select Nextcloud from the service list
2. Choose "Make public"
3. Select your domain(s) and VPS node(s)
4. Script automatically:
   - Configures VPS routing
   - Issues SSL certificate (takes 2-3 minutes)
   - **Adds public domain to Nextcloud's trusted_domains** (important!)

**Important:** Nextcloud only allows access from trusted domains for security. When you make it public, the script automatically adds your public domain (e.g., `cloud.example.com`) to the trusted list. This prevents the "Access through untrusted domain" error.

## Problems?

If you see "#ccess through untruste# domain" when accessing via a public URL:

**Automatic fix (recommended):**
```bash
sudo ./scripts/operations/manage-app-visibility.sh
# Select Nextclou# → Make public → Choose Can't Log I
# Thisnaumaticallyadds he domain to t_domains
```

**Manualfx**

Retrieve your admin password:
```bash
kubectl get secret nextcloud-admin -n nextcloud -o jsonpcloud.ath='{.data.admin-password}' | base64 -d
```

Replace `cloud.yourdomain.com` with your actual public URL.

**Why this happens:**
Nextcloud only allows access from domains in its trusted list for security. At installation, only the local domain is trusted. When you add public access, the domain must be added to this list.

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

**Automatic tuning (recommended):**
```bash
sudo ./scripts/apps/nextcloud/tune-performance.sh
```

This interactive script helps you:
- Adjust CPU and memory for Nextcloud server
- Tune PostgreSQL database resources
- Configure PHP upload/memory limits
- Get recommendations based on usage (personal, family, team)

**Manual resource adjustment:**

Check current usage:
```bash
kubectl top pods -n nextcloud
```

Increase Nextcloud resources:
```bash
kubectl patch deployment nextcloud -n nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "2000m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "4Gi"}
]'
```

Increase PostgreSQL resources:
```bash
kubectl patch deployment nextcloud-postgres -n nextcloud --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "1000m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"}
]'
```

View logs:
```bash
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