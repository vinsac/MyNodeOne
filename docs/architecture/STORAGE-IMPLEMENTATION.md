# Storage Architecture Implementation - Confirmed Requirements

## Final Confirmed Requirements ✅

### 1. Velero Backup Schedule
- **Schedule:** Nightly at 2:00 AM UTC
- **Strategy:** Incremental backups (Velero determines when full backups needed)
- **Retention:** Last 6 months

### 2. Velero Installation Timing
- Install during control plane bootstrap
- Configure backup storage location when worker node joins

### 3. MinIO Namespace
- Use `minio` namespace (not `minio-worker`)

### 4. Control Plane MinIO Removal
- **Remove** MinIO installation from bootstrap-control-plane.sh
- Velero installed during control plane bootstrap
- Velero backup configuration happens when worker joins

### 5. Disk Detection Pattern
- Use **exact same pattern** as Longhorn disk detection
- Reference: `bootstrap-control-plane.sh` lines 1038-1130
- MinIO detects and uses ALL available disks on worker node
- Do NOT format disk with OS

### 6. Code Quality Requirements
- Make code modular wherever possible
- Follow defensive programming: Install → Verify → Retry → Check → Fallback → Error reporting

## Implementation Plan

### Phase 1: Create Modular Scripts
1. `scripts/storage/install-velero.sh` - Velero installation
2. `scripts/storage/install-minio-worker.sh` - MinIO worker installation with disk detection
3. `scripts/storage/configure-velero-backup.sh` - Configure Velero backup to MinIO

### Phase 2: Modify Bootstrap Scripts
1. `bootstrap-control-plane.sh`:
   - Remove `install_minio()` call
   - Add `install_velero()` call
   - Add Longhorn node restrictions (control-plane-only)

2. `add-worker-node.sh`:
   - Add MinIO installation with disk detection
   - Add Longhorn scheduling disable on worker
   - Add Velero backup configuration trigger

### Phase 3: Testing & Validation
1. Test fresh control plane installation
2. Test worker node addition
3. Test Velero backup/restore
4. Verify Longhorn stays on control plane
5. Verify MinIO on worker with all disks

## Implementation Status

- [x] Requirements confirmed
- [ ] Create Velero installation script
- [ ] Create MinIO worker installation script
- [ ] Create Velero backup configuration script
- [ ] Modify bootstrap-control-plane.sh
- [ ] Modify add-worker-node.sh
- [ ] Test and validate
- [ ] Update documentation
