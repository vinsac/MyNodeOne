# Single Disk Setup Guide

## Overview

**Can I use MyNodeOne with only one disk (the OS disk)?**

**YES!** MyNodeOne works perfectly fine on machines with only one disk. This is common for:
- Old laptops
- Mini PCs
- Raspberry Pis
- Budget home servers
- Most consumer hardware

---

## What Happens During Installation

### If You Have Multiple Disks

The installer will:
1. ✅ Detect your additional disks (excluding OS disk for safety)
2. ✅ Ask you to choose which disks to use
3. ✅ Ask you to choose storage type (Longhorn/MinIO/RAID/Individual)
4. ✅ Automatically format and mount your chosen disks
5. ✅ Configure storage to use these dedicated disks

**Example:**
```
Found 2 SAFE disks for storage:
  ✓ /dev/sda (1TB)
  ✓ /dev/sdb (1TB)

? Do you want to set up these disks? [y/N]: y

[Full disk setup wizard runs...]
```

---

### If You Have Only One Disk (OS Disk)

The installer will:
1. ✅ Detect that only the OS disk exists
2. ✅ Show a clear warning about implications
3. ✅ **Automatically configure storage to use a directory on your OS disk**
4. ✅ Continue with installation without requiring manual intervention

**What You'll See:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Disk Detection
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ℹ OS (Ubuntu) is installed on: /dev/sda
⚠ This disk will be EXCLUDED from storage setup for safety

⚠ No additional disks detected for storage setup.

ℹ Single-disk configuration detected.
  Storage will be configured automatically using:
  /var/lib/longhorn
  
  This is SAFE and works well for:
    ✅ Home labs and learning
    ✅ Development environments
    ✅ Low-traffic applications
    ✅ Machines with 500GB+ free space
  
  Limitations:
    ⚠ Storage limited to OS disk free space
    ⚠ Performance may be lower (OS + apps on same disk)
    ⚠ No redundancy (if disk fails, data is lost)
  
  You can add more disks later!

? Proceed with single-disk setup? [y/N]: y

[Installation continues automatically...]
```

---

## How Storage Works on Single Disk

### Storage Location

**Longhorn will use:** `/var/lib/longhorn`

**This directory will store:**
- All persistent volumes (databases, file uploads, etc.)
- Application data
- Kubernetes persistent volume claims

**How it works:**
- Longhorn creates volumes in `/var/lib/longhorn/replicas/`
- These are regular files on your OS disk
- Kubernetes mounts them into containers
- Applications see them as separate disks

### Example

If you run a PostgreSQL database with 10GB storage:

```
Your OS disk (500GB total):
  ├─ / (OS and system files): 50GB
  ├─ /var/lib/longhorn/replicas/pvc-postgres-vol-1: 10GB ← Database
  ├─ /home (your files): 100GB
  └─ Free space: 340GB
```

**It just works!** Your database thinks it has a dedicated 10GB disk.

---

## Performance Considerations

### Single Disk Performance

| Aspect | Single Disk | Multiple Disks |
|--------|-------------|----------------|
| **Installation** | ✅ Easier, automatic | Requires disk setup |
| **Cost** | ✅ $0 extra | Need additional disks |
| **Speed** | ⚠️ Shared I/O | ✅ Dedicated I/O |
| **Redundancy** | ❌ None | ✅ Replication across disks |
| **Capacity** | Limited to free space | Total of all disks |

### Is Single Disk Fast Enough?

**For most home users: YES!**

**Works well for:**
- ✅ Personal websites (WordPress, Ghost, etc.)
- ✅ Home automation (Home Assistant, etc.)
- ✅ Media servers (Plex, Jellyfin)
- ✅ Development/testing
- ✅ Learning Kubernetes
- ✅ Small databases (< 10 concurrent users)

**May struggle with:**
- ⚠️ High-traffic production websites (100+ concurrent users)
- ⚠️ Large databases with heavy writes
- ⚠️ Multiple I/O-intensive applications running simultaneously
- ⚠️ Video transcoding + database + web server all at once

---

## Capacity Planning

### How Much Space Do You Need?

**Minimum Requirements:**
- OS installation: ~20GB
- Kubernetes components: ~10GB
- MyNodeOne services: ~5GB
- **Buffer for applications: 50GB+**

**Total minimum: 100GB free space**

**Recommended:**
- 256GB+ SSD for good performance
- 500GB+ for comfortable growth
- 1TB+ for multiple applications

### Example Usage

**500GB Laptop Disk:**
```
Total: 500GB
  ├─ OS + System: 50GB
  ├─ MyNodeOne: 15GB
  ├─ Applications:
  │   ├─ WordPress: 20GB
  │   ├─ PostgreSQL: 30GB
  │   └─ MinIO (file storage): 100GB
  ├─ Buffer: 50GB
  └─ Available: 235GB for growth
```

---

## Upgrading Later

### Can I Add Disks Later?

**YES! It's easy:**

1. **Add physical disk to your machine**
   - Plug in USB drive, or
   - Install internal HDD/SSD

2. **Run disk setup wizard**
   ```bash
   cd ~/MyNodeOne
   sudo ./scripts/add-storage-disk.sh
   ```

3. **Choose migration option**
   - Keep data on OS disk + use new disk for new volumes
   - OR migrate existing data to new disks

4. **Longhorn automatically uses new space**
   - New volumes use additional disks
   - Better performance
   - More capacity

### Migration Example

**Before (single disk):**
```
OS Disk (500GB):
  - OS: 50GB
  - Longhorn: 150GB
  - Free: 300GB
```

**After adding 1TB disk:**
```
OS Disk (500GB):
  - OS: 50GB
  - Old Longhorn data: 150GB (can migrate)
  - Free: 300GB

New Disk (1TB):
  - New Longhorn volumes: automatically use this
  - Better performance ✅
  - More space ✅
```

---

## Best Practices for Single Disk

### 1. Monitor Disk Space

```bash
# Check free space
df -h /

# Should keep at least 20% free
# Example: 500GB disk = keep 100GB free
```

### 2. Set Resource Limits

When deploying apps, set storage limits:

```yaml
# Good - sets a 10GB limit
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  resources:
    requests:
      storage: 10Gi  # ← Prevents unlimited growth
```

### 3. Regular Cleanup

```bash
# Clean up old container images
kubectl get pods --all-namespaces | grep Completed
kubectl delete pod <completed-pods>

# Clean Docker images
docker system prune -a
```

### 4. Backup Important Data

Since there's no redundancy:

```bash
# Backup to external drive or cloud
# Example: backup PostgreSQL
kubectl exec -n default postgres-0 -- pg_dump mydb > backup.sql
```

---

## Troubleshooting

### "Disk full" Errors

**Symptom:** Pods fail to start, "no space left on device"

**Solution:**
```bash
# 1. Check space
df -h /

# 2. Clean up if needed
docker system prune -a -f

# 3. Delete unused PVCs
kubectl get pvc --all-namespaces
kubectl delete pvc <unused-pvc>

# 4. If critically low, add a disk
sudo ./scripts/add-storage-disk.sh
```

### Slow Performance

**Symptom:** Applications are slow

**Solutions:**
1. **Check if disk is HDD:** SSDs are 10x faster
   ```bash
   lsblk -d -o name,rota
   # rota=1 means HDD (slow)
   # rota=0 means SSD (fast)
   ```

2. **Reduce concurrent I/O:**
   - Don't run video encoding while database is busy
   - Spread out backup jobs
   - Use cache where possible

3. **Upgrade to SSD:**
   - Clone OS to SSD
   - Or add SSD as additional disk

---

## Real-World Examples

### Example 1: Budget Home Lab

**Hardware:**
- Old laptop with 256GB SSD
- 8GB RAM
- Dual-core CPU

**What works:**
- ✅ WordPress site (personal blog)
- ✅ Home Assistant
- ✅ Nextcloud (5GB of files)
- ✅ Pi-hole DNS

**Performance:** Good! SSD makes it snappy.

---

### Example 2: Development Machine

**Hardware:**
- Desktop with 1TB NVMe SSD
- 32GB RAM
- 6-core CPU

**What works:**
- ✅ Multiple development databases
- ✅ GitLab CE
- ✅ Testing environments
- ✅ CI/CD pipelines

**Performance:** Excellent! Fast CPU + NVMe = great experience.

---

### Example 3: Media Server

**Hardware:**
- Mini PC with 128GB SSD + USB 4TB HDD
- 16GB RAM
- Quad-core CPU

**Setup:**
- OS on 128GB SSD
- Add 4TB HDD as additional disk during setup
- Longhorn uses HDD for media storage

**What works:**
- ✅ Plex server (4TB of movies on HDD)
- ✅ PostgreSQL (on SSD for speed)
- ✅ Web UI (on SSD for speed)

**Performance:** Perfect! Right tool for the job.

---

## Summary

### ✅ Single Disk is FINE for:
- Home labs and learning
- Development environments
- Personal projects
- Low-traffic applications
- Most home server uses

### ⚠️ Consider Multiple Disks for:
- Production applications
- High-traffic websites
- Large databases
- Data redundancy requirements
- I/O-intensive workloads

### 🎯 Bottom Line

**Don't let a single disk stop you from using MyNodeOne!**

- ✅ Installation is **automatic** on single disk
- ✅ It **just works** without manual configuration
- ✅ Perfect for **99% of home users**
- ✅ You can **add disks later** anytime
- ✅ Great for **learning** Kubernetes

**Most home machines have one disk, and MyNodeOne handles this perfectly!**

---

## Next Steps

1. **Install MyNodeOne** - it auto-configures for single disk
2. **Use it!** - works great for most applications
3. **Monitor disk space** - keep 20% free
4. **Add disks later** if needed - easy upgrade path

**Questions?** See [FAQ](reference/FAQ.md) or open an issue on GitHub.
