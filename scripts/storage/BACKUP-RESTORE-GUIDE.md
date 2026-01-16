# Velero Backup & Restore Guide

**Quick Reference for MyNodeOne Backup Operations**

---

## Backup Automation

### ✅ Automatic Backups Start After Worker Node Addition

**When backups begin:**
- Backups start **automatically** once worker node is added and MinIO is configured
- No manual intervention required
- Configured by `configure-velero-backup.sh` during worker node addition

**Backup Schedule:**
- **Frequency:** Nightly at 2:00 AM UTC
- **Retention:** 6 months (180 days)
- **Storage:** MinIO on worker node

**Two scheduled backups:**
1. **`nightly-backup`** - Full cluster backup (excludes system namespaces)
2. **`longhorn-pvc-backup`** - PVC and PV backup

---

## Credential Display

### ❌ MinIO Credentials NOT Displayed in Summary (Currently)

**Current Behavior:**
- Control plane summary shows Velero status but NOT MinIO credentials
- MinIO credentials saved to file: `~/mynodeone-minio-worker-credentials.txt` on **worker node**
- File permissions: `600` (owner read/write only)
- File ownership: Actual user on worker node

**What's Displayed:**
```
💾 VELERO (Backup System):
   Status: Installed (backup storage configured when worker joins)
   Backups: Nightly at 2:00 AM UTC → MinIO on worker node
   Retention: 6 months
```

**Where to Find MinIO Credentials:**
1. **On worker node:** `cat ~/mynodeone-minio-worker-credentials.txt`
2. **Kubernetes secret:** `kubectl get secret minio-credentials -n minio -o yaml`
3. **Via kubectl:**
   ```bash
   kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' | base64 -d
   kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' | base64 -d
   ```

**⚠️ Enhancement Needed:**
Worker node summary should display MinIO credentials like control plane displays Grafana/ArgoCD credentials.

---

## Error Handling

### What Happens If MinIO Is Not Available?

**During Worker Node Addition:**
```bash
configure_velero_backup() {
    # Check if MinIO is running
    if ! kubectl get svc minio -n minio &> /dev/null; then
        log_warn "MinIO not found, skipping Velero backup configuration"
        log_warn "Run this after MinIO is installed:"
        log_warn "  sudo $PROJECT_ROOT/scripts/storage/velero/configure-backup.sh"
        return 0
    fi
}
```

**Result:**
- Worker node addition continues successfully
- Velero backup configuration skipped
- User warned with manual command to run later
- No backups until manually configured

**To Fix:**
```bash
sudo ./scripts/storage/velero/configure-backup.sh
```

---

### What Happens If MinIO Disks Are Full?

**⚠️ Current Implementation: NO DISK SPACE MONITORING**

**Issues:**
1. **No quota enforcement** - MinIO will fill disk until 100%
2. **No alerts** - User not notified when space is low
3. **Backup failures** - Velero backups fail silently when disk full
4. **No automatic cleanup** - Old backups retained for 6 months regardless of space

**How to Check Disk Space:**
```bash
# On worker node
df -h /mnt/longhorn-disks/disk-*

# Or via kubectl
kubectl exec -n minio deployment/minio -- df -h
```

**How to Check Backup Status:**
```bash
velero backup get
velero backup describe <backup-name>
velero backup logs <backup-name>
```

**Manual Cleanup:**
```bash
# Delete old backups
velero backup delete <backup-name> --confirm

# Delete backups older than 30 days
velero backup get --output json | jq -r '.items[] | select(.status.completionTimestamp < (now - 2592000 | strftime("%Y-%m-%dT%H:%M:%SZ"))) | .metadata.name' | xargs -I {} velero backup delete {} --confirm
```

**⚠️ Enhancement Needed:**
- Disk space monitoring and alerts
- Automatic cleanup when space low
- MinIO quota configuration
- Velero backup failure notifications

---

## Restore Procedures

### ❌ Restore Is NOT Automated

**Manual Restore Required:**
Disaster recovery requires manual intervention by administrator.

### Basic Restore

**1. List Available Backups:**
```bash
velero backup get
```

**2. Restore from Backup:**
```bash
# Full restore
velero restore create --from-backup <backup-name>

# Restore specific namespace
velero restore create --from-backup <backup-name> --include-namespaces=myapp

# Restore with different namespace
velero restore create --from-backup <backup-name> \
  --namespace-mappings old-ns:new-ns
```

**3. Monitor Restore Progress:**
```bash
# List restores
velero restore get

# Check restore status
velero restore describe <restore-name>

# View logs
velero restore logs <restore-name>
```

---

### Disaster Recovery Scenarios

#### Scenario 1: Single Application Failure

**Problem:** Application namespace corrupted or deleted

**Solution:**
```bash
# Restore just that namespace
velero restore create myapp-restore \
  --from-backup nightly-backup-20260106020000 \
  --include-namespaces=myapp
```

---

#### Scenario 2: Full Cluster Loss

**Problem:** Control plane node failed, need to rebuild cluster

**Prerequisites:**
- Worker node with MinIO still running (has backups)
- OR backups copied to external storage

**Steps:**

**1. Rebuild Control Plane:**
```bash
# On new control plane machine
cd ~/MyNodeOne
sudo ./scripts/installation/bootstrap-control-plane.sh
```

**2. Reinstall Velero:**
```bash
# Velero installed automatically during bootstrap
# Verify installation
kubectl get deployment velero -n velero
```

**3. Reconnect to Existing MinIO:**
```bash
# If worker node still exists with MinIO
sudo ./scripts/nodes/add-worker-node.sh

# This will:
# - Join worker to new cluster
# - Reconnect Velero to existing MinIO
# - Existing backups remain accessible
```

**4. List Available Backups:**
```bash
velero backup get
# Should show all previous backups from MinIO
```

**5. Restore Cluster State:**
```bash
# Restore all application namespaces
velero restore create full-cluster-restore \
  --from-backup nightly-backup-20260106020000 \
  --exclude-namespaces='kube-system,kube-public,kube-node-lease,velero'
```

**6. Verify Restoration:**
```bash
kubectl get pods -A
kubectl get pvc -A
kubectl get svc -A
```

---

#### Scenario 3: Both Control Plane AND Worker Failed

**Problem:** Complete infrastructure loss

**Prerequisites:**
- Backups must be copied to external storage BEFORE failure
- MinIO data exported or synced elsewhere

**⚠️ Current Gap:**
- No automatic external backup sync
- No offsite backup replication
- MinIO only on worker node (single point of failure)

**Mitigation Strategies:**

**Option 1: Manual MinIO Backup**
```bash
# On worker node, periodically copy MinIO data
rsync -avz /mnt/longhorn-disks/disk-*/minio-data/ user@backup-server:/backups/minio/
```

**Option 2: MinIO Replication (Future Enhancement)**
- Configure MinIO bucket replication to external S3
- Requires additional S3-compatible storage (AWS S3, Backblaze B2, etc.)

**Option 3: Velero Backup to Multiple Locations (Future Enhancement)**
- Configure secondary backup location
- Velero supports multiple BackupStorageLocations

---

## Monitoring Backup Health

### Check Backup Status

**List Recent Backups:**
```bash
velero backup get
```

**Check Specific Backup:**
```bash
velero backup describe <backup-name>
```

**View Backup Logs:**
```bash
velero backup logs <backup-name>
```

**Check Backup Schedule:**
```bash
velero schedule get
velero schedule describe nightly-backup
```

---

### Common Backup Failures

**1. MinIO Disk Full**
```
Error: Failed to upload backup: no space left on device
```
**Fix:** Free up space or add more disks to MinIO

**2. MinIO Service Down**
```
Error: Failed to connect to backup location
```
**Fix:** Check MinIO pod status: `kubectl get pods -n minio`

**3. Network Issues**
```
Error: Connection timeout to backup location
```
**Fix:** Check network connectivity between Velero and MinIO

**4. Credentials Invalid**
```
Error: Access denied to backup location
```
**Fix:** Verify credentials: `kubectl get secret cloud-credentials -n velero`

---

## Best Practices

### 1. Regular Backup Verification
```bash
# Weekly: Check that backups are running
velero backup get | grep Completed

# Monthly: Test restore to verify backups work
velero restore create test-restore-$(date +%Y%m%d) \
  --from-backup nightly-backup-latest \
  --include-namespaces=test-namespace
```

### 2. Monitor Disk Space
```bash
# Add to cron (daily check)
df -h /mnt/longhorn-disks/disk-* | awk '$5 > 80 {print "WARNING: Disk "$1" is "$5" full"}'
```

### 3. Document Recovery Procedures
- Keep this guide accessible offline
- Document MinIO credentials in password manager
- Test disaster recovery annually

### 4. External Backup Copy
```bash
# Weekly: Copy critical backups offsite
# Add to cron on worker node
rsync -avz /mnt/longhorn-disks/disk-*/minio-data/velero-backups/ \
  user@backup-server:/backups/mynodeone/
```

---

## Quick Reference Commands

**Backup Operations:**
```bash
# Manual backup
velero backup create manual-backup-$(date +%Y%m%d)

# Backup specific namespace
velero backup create myapp-backup --include-namespaces=myapp

# Backup with TTL
velero backup create temp-backup --ttl 24h
```

**Restore Operations:**
```bash
# List backups
velero backup get

# Restore from backup
velero restore create --from-backup <backup-name>

# Restore specific resources
velero restore create --from-backup <backup-name> \
  --include-resources=deployments,services

# Restore with namespace mapping
velero restore create --from-backup <backup-name> \
  --namespace-mappings prod:staging
```

**Troubleshooting:**
```bash
# Check Velero status
kubectl get pods -n velero
kubectl logs -n velero deployment/velero

# Check backup location
kubectl get backupstoragelocation -n velero
kubectl describe backupstoragelocation default -n velero

# Check MinIO
kubectl get pods -n minio
kubectl get svc -n minio
```

---

## Enhancement Recommendations

### High Priority

1. **Display MinIO Credentials in Worker Summary**
   - Add to `print_summary()` in `add-worker-node.sh`
   - Show MinIO console URL, username, password
   - Prompt user to save to password manager

2. **Disk Space Monitoring**
   - Add disk space checks to backup scripts
   - Alert when space < 20%
   - Automatic cleanup of old backups when space low

3. **Backup Failure Notifications**
   - Monitor Velero backup status
   - Send alerts on backup failures
   - Integration with monitoring stack

### Medium Priority

4. **Automated Restore Testing**
   - Monthly automated restore test
   - Verify backup integrity
   - Report results to monitoring

5. **External Backup Replication**
   - Configure MinIO replication to external S3
   - Or periodic rsync to offsite storage
   - Protect against complete infrastructure loss

6. **Backup Documentation**
   - Add restore procedures to POST_INSTALLATION_GUIDE.md
   - Create disaster recovery runbook
   - Document tested recovery procedures

---

## Related Documentation

- **Installation:** `scripts/storage/README.md`
- **Architecture:** `docs/architecture/STORAGE-ARCHITECTURE.md`
- **Defensive Programming:** `docs/contributing/DEFENSIVE-PROGRAMMING.md`
- **Velero Docs:** https://velero.io/docs/
- **MinIO Docs:** https://min.io/docs/
