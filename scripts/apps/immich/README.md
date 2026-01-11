# Immich - Photo & Video Backup

Automatically backup photos and videos from your phone with AI-powered search and face recognition.

## What You Get

- 📸 Automatic backup from your phone
- 🔍 Search photos by objects, locations, or people
- 👤 Automatic face recognition
- 📱 Mobile apps for iOS and Android
- 🔒 Your photos stay private on your server
- 📦 Unlimited storage (based on your disk space)
- 👨‍👩‍👧‍👦 Share albums with family
- 🎥 Full video support

## Installation

```bash
sudo ./scripts/apps/immich/install-immich.sh
```

During installation, you'll be asked:
- **Subdomain**: Choose a name like `photos`, `immich`, or `pics`
- **Storage Size**: How much space to allocate for photos and videos
- **Public Access**: Whether to access from anywhere or just your home network

## Access

### Local Access
```
http://immich.mynodeone.local
```
(Replace `immich` with your chosen subdomain and `mynodeone` with your cluster domain)

### First-Time Setup

1. Open Immich in your browser
2. Create an admin account (first user becomes admin)
3. Configure your preferences

### Mobile App Setup

1. **Download the app:**
   - iOS: Search "Immich" in the App Store
   - Android: Search "Immich" in the Play Store

2. **Configure the app:**
   - Server URL: `http://immich.mynodeone.local` (or your public domain)
   - Login with your admin credentials
   - Enable background upload
   - Select albums to backup

## Upgrading

To upgrade to a newer version:
```bash
sudo ./scripts/apps/immich/uninstall-immich.sh
sudo ./scripts/apps/immich/install-immich.sh
```

**Your photos are safe** - they won't be deleted during upgrades.

## Storage

### Storage Selection During Installation

During installation, you'll be prompted to choose storage sizes:

**Photo Storage Options:**
- **500Gi** - Good for ~50,000 photos (average 10MB each)
- **1Ti** - Good for ~100,000 photos (recommended default)
- **2Ti** - Good for ~200,000 photos
- **5Ti** - Good for large families or multiple users

**Database Storage Options:**
- **20Gi** - Good for ~50,000 photos (recommended default)
- **50Gi** - Good for ~100,000+ photos
- **100Gi** - Good for very large libraries

You can enter custom sizes during installation (e.g., `3Ti`, `75Gi`).

### Need More Storage?

```bash
sudo ./scripts/apps/immich/expand-storage.sh
```

The script will guide you through expanding your storage space.

## Video Playback Optimization

### Automatic Nightly Processing

If videos buffer when you watch them, set up automatic processing:

```bash
sudo ./scripts/apps/immich/setup-auto-transcode.sh
```

**What it does:**
- Runs every night at 2 AM
- Processes new videos for smooth playback
- No more buffering when watching videos

**Setup:**
1. Open Immich in your browser
2. Go to Account Settings → API Keys
3. Click "New API Key" and name it "Auto Transcode"
4. Copy the key and paste it when the script asks

**Manual trigger:**
```bash
sudo immich-transcode
```

## Common Tasks

### Restart Immich
```bash
kubectl rollout restart deployment/immich-server -n immich
```

### Check if Running
```bash
kubectl get pods -n immich
```

## Access from Anywhere

To access Immich when you're away from home:

```bash
sudo ./scripts/operations/manage-app-visibility.sh
```

## Backup Your Photos

```bash
kubectl exec deployment/immich-postgres -n immich -- \
  pg_dump -U immich immich > immich-backup-$(date +%Y%m%d).sql
```

## If Videos Are Slow

If videos buffer when you watch them:

```bash
sudo ./scripts/apps/immich/tune-performance.sh
```

This will help you allocate more resources for smooth video playback.

## Problems?

### Can't Upload Photos

1. Check the server URL in your mobile app
2. Make sure you're connected to your network

### Running Out of Space

Expand your storage:
```bash
sudo ./scripts/apps/immich/expand-storage.sh
```

### Can't Access Immich

Update your network settings:
```bash
sudo ./scripts/domains/sync-dns.sh
```

## Uninstall

```bash
sudo ./scripts/apps/immich/uninstall-immich.sh
```

**WARNING:** This will delete all photos and data permanently!

## Need Help?

- Official Documentation: https://immich.app/docs
- Community Support: https://discord.gg/immich
