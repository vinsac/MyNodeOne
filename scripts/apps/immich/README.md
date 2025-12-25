# Immich - Self-Hosted Photo & Video Backup

A self-hosted Google Photos alternative with AI-powered search, face recognition, and automatic mobile backup.

## Features

- 📸 **Automatic Photo Backup** - Upload photos/videos from your phone automatically
- 🤖 **AI-Powered Search** - Search by objects, locations, people, and dates
- 👤 **Face Recognition** - Automatically group photos by people
- 📱 **Mobile Apps** - Native iOS and Android apps with background upload
- 🔒 **Privacy First** - Your photos stay on your infrastructure
- 📦 **Original Quality** - No compression, unlimited storage (limited by your disk)
- 👨‍👩‍👧‍👦 **Album Sharing** - Share albums with family and friends
- 🎥 **Video Support** - Full support for video backup and playback

## Installation

### Prerequisites

- Kubernetes cluster (K3s) running
- Longhorn storage class configured
- At least 1TB of available storage recommended

### Quick Install

```bash
sudo ./scripts/apps/immich/install-immich.sh
```

The installer will:
1. Check for the latest Immich version from GitHub
2. Prompt for a subdomain (default: `immich`)
3. Deploy PostgreSQL with vector extensions
4. Deploy Redis for caching
5. Deploy Immich server
6. Configure local DNS access
7. Optionally configure public access via VPS

### Installation Options

During installation, you'll be asked:
- **Subdomain**: Choose a subdomain like `photos`, `immich`, or `pics`
- **Public Access**: Whether to make the app accessible from the internet

## Access

### Local Access
```
http://immich.minicloud.local
```
(Replace `immich` with your chosen subdomain and `minicloud` with your cluster domain)

### First-Time Setup

1. Open Immich in your browser
2. Create an admin account (first user becomes admin)
3. Configure your preferences

### Mobile App Setup

1. **Download the app:**
   - iOS: Search "Immich" in the App Store
   - Android: Search "Immich" in the Play Store

2. **Configure the app:**
   - Server URL: `http://immich.minicloud.local` (or your public domain)
   - Login with your admin credentials
   - Enable background upload
   - Select albums to backup

## Version Management

The installation script automatically checks for the latest Immich version from GitHub and uses it. This ensures you always get:
- Latest features and improvements
- Security patches
- Bug fixes

To upgrade to a newer version:
```bash
# Uninstall current version
sudo ./scripts/apps/immich/uninstall-immich.sh

# Reinstall (will fetch latest version)
sudo ./scripts/apps/immich/install-immich.sh
```

**Note:** Your photos are stored in persistent volumes and will be preserved during upgrades.

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

### Current Storage Allocation

Check your current storage:
```bash
kubectl get pvc -n immich
```

View detailed storage information:
```bash
kubectl describe pvc immich-photos -n immich
kubectl describe pvc immich-postgres -n immich
```

### Expanding Storage

#### Option 1: Use the Automated Script (Recommended)

```bash
sudo ./scripts/apps/immich/expand-storage.sh
```

The script will:
1. Show current storage allocation
2. Let you choose what to expand (photos, database, or both)
3. Provide size recommendations
4. Safely expand the storage
5. Handle pod restarts if needed

#### Option 2: Manual Expansion

To increase photo storage manually:
```bash
kubectl patch pvc immich-photos -n immich -p '{"spec":{"resources":{"requests":{"storage":"2Ti"}}}}'
```

To increase database storage manually:
```bash
kubectl patch pvc immich-postgres -n immich -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
# Restart database to apply changes
kubectl rollout restart deployment/immich-postgres -n immich
```

**Note:** Longhorn automatically handles volume expansion. The pods may restart during the expansion process.

## Management

### View Logs
```bash
kubectl logs -f deployment/immich-server -n immich
```

### Restart Service
```bash
kubectl rollout restart deployment/immich-server -n immich
```

### Check Status
```bash
kubectl get pods -n immich
kubectl get svc -n immich
```

### Database Access
```bash
# Get database password
kubectl get secret immich-secrets -n immich -o jsonpath='{.data.DB_PASSWORD}' | base64 -d

# Connect to database
kubectl exec -it deployment/immich-postgres -n immich -- psql -U immich -d immich
```

## Public Access

To make Immich accessible from the internet:

```bash
sudo ./scripts/manage-app-visibility.sh
```

This allows you to:
- Access photos from anywhere
- Upload photos while traveling
- Share with family remotely

See `docs/APP-PUBLIC-ACCESS.md` for more details.

## Backup & Restore

### Backup Photos
Photos are stored in the `immich-photos` PersistentVolume. To backup:

```bash
# Find the volume path
kubectl get pv -n immich

# Backup using Longhorn UI or CLI
# Or use Velero for full cluster backups
```

### Backup Database
```bash
# Export database
kubectl exec deployment/immich-postgres -n immich -- \
  pg_dump -U immich immich > immich-backup-$(date +%Y%m%d).sql
```

### Restore Database
```bash
# Restore from backup
kubectl exec -i deployment/immich-postgres -n immich -- \
  psql -U immich immich < immich-backup-20241224.sql
```

## Performance Optimization

### Video Playback Issues

If you experience buffering or stuttering during video playback:

**Quick Fix - Use the Performance Tuning Script:**
```bash
sudo ./scripts/apps/immich/tune-performance.sh
```

This script will help you:
- Increase CPU/memory allocation for transcoding
- Enable GPU acceleration (if available)
- Optimize transcoding settings

### Why Videos Buffer (Unlike Google Photos)

**Root Cause:** Real-time transcoding requires significant CPU power.

Google Photos pre-transcodes all videos at multiple quality levels using massive server infrastructure. Immich transcodes on-demand, which requires:
- **CPU Power**: 4K video transcoding needs 6-8+ CPU cores
- **Memory**: 12-16GB for smooth transcoding
- **Time**: First playback may be slow while transcoding

**Solutions:**

1. **Pre-transcode videos** (recommended):
   - Go to Admin Panel > Jobs
   - Run "Transcode Videos" job
   - This creates optimized versions for instant playback

2. **Increase resources** (if videos still buffer):
   ```bash
   sudo ./scripts/apps/immich/tune-performance.sh
   ```

3. **Use GPU acceleration** (best performance):
   - Requires NVIDIA GPU on control plane
   - Dramatically speeds up transcoding
   - Configure via tune-performance.sh script

4. **Record videos in H.264** (prevention):
   - Change phone camera settings to H.264 instead of HEVC
   - H.264 plays directly without transcoding
   - Better browser compatibility

### Resource Requirements by Use Case

| Use Case | CPU | Memory | Notes |
|----------|-----|--------|-------|
| Photos only | 2-4 cores | 4-8GB | Minimal transcoding |
| Photos + occasional video | 4-6 cores | 8-12GB | Default config |
| Regular video viewing | 6-8 cores | 12-16GB | Recommended |
| Multiple users + 4K | 8-12 cores | 16-24GB | Heavy use |
| With GPU acceleration | 2-4 cores | 8-12GB | GPU does transcoding |

## Troubleshooting

### Photos Not Uploading

1. Check mobile app server URL is correct
2. Verify network connectivity
3. Check Immich server logs:
   ```bash
   kubectl logs -f deployment/immich-server -n immich
   ```

### Face Recognition Not Working

Face recognition requires:
- Sufficient CPU/memory resources
- Time to process existing photos
- Check ML service logs

### Out of Storage

1. Check available storage:
   ```bash
   kubectl get pvc -n immich
   ```
2. Expand PVC (see Storage section above)
3. Or delete old/unwanted photos from Immich UI

### Service Not Accessible

1. Check pod status:
   ```bash
   kubectl get pods -n immich
   ```
2. Verify service has LoadBalancer IP:
   ```bash
   kubectl get svc immich-server -n immich
   ```
3. Update DNS:
   ```bash
   sudo ./scripts/sync-dns.sh
   ```

## Uninstall

```bash
sudo ./scripts/apps/immich/uninstall-immich.sh
```

**WARNING:** This will delete all photos and data permanently!

## Resources

- **Official Documentation**: https://immich.app/docs
- **GitHub Repository**: https://github.com/immich-app/immich
- **Discord Community**: https://discord.gg/immich

## Architecture

### Components

- **Immich Server**: Main application server (Node.js/TypeScript)
- **PostgreSQL**: Database with pgvecto-rs for vector search
- **Redis**: Caching and job queue
- **Machine Learning**: AI features (face recognition, object detection)

### Resource Requirements

- **Immich Server**: 2-8GB RAM, 1-4 CPU cores
- **PostgreSQL**: 512MB-2GB RAM, 0.25-1 CPU cores
- **Redis**: 128MB-512MB RAM, 0.1-0.5 CPU cores

### Network Ports

- **2283**: Immich server (exposed as port 80 via LoadBalancer)
- **5432**: PostgreSQL (internal only)
- **6379**: Redis (internal only)

## Security

- Database credentials are auto-generated and stored in Kubernetes secrets
- First user becomes admin - create this account immediately after installation
- Consider enabling 2FA in Immich settings
- Use HTTPS for public access (configured automatically via VPS routing)

## Performance Tips

1. **Enable hardware acceleration** (if available) for video transcoding
2. **Adjust thumbnail quality** in settings to balance quality vs. storage
3. **Schedule ML jobs** during off-peak hours
4. **Monitor resource usage** and adjust limits as needed

## Comparison with Google Photos

| Feature | Immich | Google Photos |
|---------|--------|---------------|
| Storage | Unlimited (your disk) | 15GB free, then paid |
| Privacy | Full control | Google has access |
| AI Search | ✅ | ✅ |
| Face Recognition | ✅ | ✅ |
| Cost | Infrastructure only | $1.99-$9.99/month |
| Mobile Apps | ✅ | ✅ |
| Sharing | ✅ | ✅ |

## License

Immich is licensed under the AGPL-3.0 license.
