# MyNodeOne Storage Guide

## Understanding Storage Options

MyNodeOne offers different storage configurations. This guide helps you choose the right one.

---

## 🎯 Quick Decision Guide

### I want to run apps and databases
**→ Choose Longhorn (Option 1)** ✅

Longhorn provides automatic redundancy and works perfectly for:
- Databases (PostgreSQL, MySQL, MongoDB)
- Application file storage
- User uploads
- Persistent volumes for any app

### I want S3-compatible storage (like Amazon S3)
**→ Choose Longhorn first, then install MinIO later** ✅

Why this approach:
- Longhorn handles app storage (databases, files)
- MinIO provides S3 API (backups, media, large files)
- You can install MinIO anytime after initial setup
- Both can coexist perfectly

### I have a single-node setup and want manual control
**→ Choose RAID (Option 3)** 

For users who:
- Want traditional RAID redundancy
- Have experience with mdadm
- Prefer manual configuration

---

## 📊 Storage Option Comparison

| Feature | Longhorn | MinIO | RAID | Individual |
|---------|----------|-------|------|-----------|
| **Best For** | Applications & databases | Object storage (S3) | Single-node redundancy | Testing |
| **Redundancy** | Automatic (multi-node) | None (needs external) | RAID levels | None |
| **Use Case** | Running apps | Backups, media files | Manual control | Temporary |
| **Complexity** | Easy | Medium | Medium | Easy |
| **Recommended?** | ✅ Yes | ⚠️ As secondary | ⚠️ Single-node only | ❌ Testing only |

---

## 🔍 Detailed Explanation

### Option 1: Longhorn Storage (RECOMMENDED)

**What is it?**
Distributed block storage that replicates your data across multiple nodes automatically.

**Perfect for:**
```yaml
# Your app needs persistent storage
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
spec:
  storageClassName: longhorn
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

**Use cases:**
- ✅ PostgreSQL/MySQL databases
- ✅ Application file uploads
- ✅ WordPress media
- ✅ Any app needing disk storage

**Advantages:**
- Automatic redundancy (data survives node failure)
- No manual configuration needed
- Works across all nodes
- Easy to manage via UI

**Disadvantages:**
- Requires network bandwidth for replication
- Slightly slower than local disk (due to replication)

---

### Option 2: MinIO Storage (S3-Compatible)

**What is it?**
Object storage with S3-compatible API (like Amazon S3).

**⚠️ Important:** MinIO is NOT for running applications. It's for S3 storage.

**Perfect for:**
```python
# Storing backups or media files via S3 API
import boto3

s3 = boto3.client('s3',
    endpoint_url='http://minio:9000',
    aws_access_key_id='minioadmin',
    aws_secret_access_key='minioadmin'
)

# Upload backup
s3.upload_file('backup.tar.gz', 'backups', 'db-backup.tar.gz')
```

**Use cases:**
- ✅ Application backups
- ✅ Media file storage (videos, images)
- ✅ Log archival
- ✅ Data lakes

**NOT for:**
- ❌ Database storage (use Longhorn)
- ❌ Application persistent volumes (use Longhorn)

**Why both Longhorn AND MinIO?**
```
Longhorn → For your apps (databases, files)
MinIO   → For S3 storage (backups, media)

They serve different purposes!
```

---

### Option 3: RAID Array

**What is it?**
Traditional RAID (Redundant Array of Independent Disks) - combines multiple disks.

**RAID Levels:**

**RAID 0 (Striping)**
- Performance: ⚡⚡⚡ Fastest
- Redundancy: ❌ None
- Capacity: 100% (all disks)
- Requires: 2+ disks
- Use case: Performance, no data loss concerns

**RAID 1 (Mirroring)**
- Performance: ⚡⚡ Good
- Redundancy: ✅ Full (survives 1 disk failure)
- Capacity: 50% (half of total)
- Requires: 2 disks
- Use case: Single-node redundancy

**RAID 5 (Distributed Parity)**
- Performance: ⚡⚡ Good
- Redundancy: ✅ Survives 1 disk failure
- Capacity: ~75% (depends on disk count)
- Requires: 3+ disks
- Use case: Balance of performance and redundancy

**RAID 10 (Mirrored Stripes)**
- Performance: ⚡⚡⚡ Fastest with redundancy
- Redundancy: ✅ Survives multiple disk failures
- Capacity: 50%
- Requires: 4+ disks
- Use case: Best of both worlds

**When to use RAID:**
- Single-node setup (not multi-node cluster)
- You understand mdadm and RAID management
- You want traditional storage approach

**When NOT to use RAID:**
- Multi-node setup → Use Longhorn instead
- You want automatic management → Use Longhorn

---

### Option 4: Individual Mounts

**What is it?**
Each disk mounted separately, no redundancy.

**Use cases:**
- Testing/development only
- Temporary storage
- You'll manage redundancy manually

**Disadvantages:**
- ❌ No redundancy
- ❌ Disk failure = data loss
- ❌ Not recommended for production

---

## 🎯 Common Scenarios

### Scenario 1: Running a Web App with Database

**Setup:**
- 2-3 nodes (home servers)
- PostgreSQL database
- User file uploads

**Recommendation:**
```
✅ Choose: Longhorn (Option 1)

Why:
- Automatic redundancy for database
- Handles user uploads
- Data survives node failure
- Easy to manage
```

---

### Scenario 2: Need S3 Storage + App Storage

**Setup:**
- Want to store backups in S3
- Also run applications

**Recommendation:**
```
✅ Choose: Longhorn (Option 1) during installation
✅ Install: MinIO later (separate installation)

Why:
- Longhorn for apps
- MinIO for S3 API
- Both coexist perfectly
- Can add MinIO anytime
```

**How to add MinIO later:**
```bash
# After Longhorn is set up
kubectl apply -f manifests/minio/
```

---

### Scenario 3: Single Powerful Server

**Setup:**
- 1 powerful server
- Multiple disks
- Want redundancy

**Recommendation:**
```
✅ Choose: RAID 1 or RAID 5 (Option 3)

Why:
- Disk-level redundancy on single node
- Traditional approach
- Good performance
```

---

## ❓ FAQ

### Can I have BOTH Longhorn AND MinIO?

**Yes!** They serve different purposes:
- **Longhorn:** For application storage (databases, files)
- **MinIO:** For S3-compatible storage (backups, media)

**Recommendation:** Install Longhorn first, add MinIO later if needed.

---

### What's the difference between Longhorn and RAID?

| Feature | Longhorn | RAID |
|---------|----------|------|
| **Works across nodes** | ✅ Yes | ❌ Single node only |
| **Automatic replication** | ✅ Yes | ❌ Manual |
| **Survives node failure** | ✅ Yes | ❌ No (only disk failure) |
| **Complexity** | Easy | Medium |

**Bottom line:** Longhorn is better for multi-node setups, RAID for single-node.

---

### I chose the wrong option! Can I change?

**Yes, but requires reconfiguration:**

1. Backup your data
2. Reinstall MyNodeOne with different storage option
3. Restore data

**Tip:** Start with Longhorn - it's the most flexible!

---

### Do I need to choose storage during installation?

**No!** You can skip disk setup (Option 5) and configure it later.

**However:** It's easier to configure during installation.

---

## 🚀 Recommended Setups

### For Most Users (Multi-Node)
```
✅ Longhorn (Option 1)
```

### For S3 Needs
```
✅ Longhorn (Option 1) + MinIO (install later)
```

### For Single-Node
```
✅ RAID 1 or RAID 5 (Option 3)
OR
✅ Longhorn (still works on single node!)
```

### For Testing Only
```
✅ Individual Mounts (Option 4) or Skip (Option 5)
```

---

## 📖 Additional Resources

- **Longhorn Documentation:** https://longhorn.io/docs
- **MinIO Documentation:** https://min.io/docs
- **RAID Tutorial:** Search "Linux RAID mdadm tutorial"
- **MyNodeOne Operations:** See `docs/operations.md`

---

**Still confused?** Choose **Longhorn (Option 1)** - it works great for 95% of use cases!
