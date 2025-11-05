# MyNodeOne Reboot Behavior

## Question: Will the cluster start automatically after reboot?

**Answer: YES, after applying the boot-order fix!**

---

## Services That Auto-Start

After a successful installation, these services are configured to start automatically:

| Service | Auto-Start | Purpose |
|---------|-----------|---------|
| **K3s** | ✅ Enabled | Kubernetes cluster |
| **Tailscale** | ✅ Enabled | VPN networking |
| **dnsmasq** | ✅ Enabled | Local DNS server |
| **Avahi** | ✅ Enabled | mDNS (pre-installed) |
| **MetalLB** | ✅ Auto | LoadBalancer (runs in K3s) |
| **Longhorn** | ✅ Auto | Storage (runs in K3s) |

---

## Critical Issue: External USB Drives

### The Problem

If you're using **external USB hard drives** (connected via USB), there's a race condition:

```
Boot Sequence:
1. System starts
2. USB drivers load
3. K3s service starts  ← May happen too early!
4. USB disks detected  ← May happen too late!
5. Disks mounted
6. Longhorn tries to use disks ← FAILS if disks not ready!
```

**Result:** Longhorn fails, pods can't start, cluster is broken after reboot.

### The Fix

**Run this script once:**

```bash
sudo ./scripts/fix-usb-disk-boot.sh
```

**What it does:**
- Creates systemd override for K3s
- Makes K3s wait for disk mounts
- Adds 5-second stabilization delay
- Ensures network is ready (for Tailscale)

**File created:** `/etc/systemd/system/k3s.service.d/wait-for-disks.conf`

### After the Fix

```
Boot Sequence (FIXED):
1. System starts
2. USB drivers load
3. USB disks detected
4. Disks mounted       ← K3s waits here
5. Network ready       ← K3s waits here
6. K3s starts          ← Now safe!
7. Longhorn works      ← Disks are ready!
```

**Result:** ✅ Cluster starts correctly every time!

---

## Boot Order Dependencies

### K3s Service Dependencies (After Fix)

```ini
[Unit]
After=local-fs.target remote-fs.target
After=mnt-longhorn\x2ddisks-disk\x2dsda.mount
After=mnt-longhorn\x2ddisks-disk\x2dsdb.mount
Requires=mnt-longhorn\x2ddisks-disk\x2dsda.mount
Requires=mnt-longhorn\x2ddisks-disk\x2dsdb.mount
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 5
```

**Translation:**
- K3s MUST wait for both Longhorn disks
- K3s SHOULD wait for network
- K3s waits 5 seconds before starting (for stability)

---

## Testing the Fix

### 1. Apply the Fix

```bash
sudo ./scripts/fix-usb-disk-boot.sh
```

### 2. Reboot

```bash
sudo reboot
```

### 3. After Reboot, Verify

**Check K3s started:**
```bash
sudo systemctl status k3s
# Should show: Active: active (running)
```

**Check disks mounted:**
```bash
df -h | grep longhorn
# Should show both disk-sda and disk-sdb mounted
```

**Check Longhorn:**
```bash
sudo kubectl get nodes.longhorn.io -n longhorn-system
# Should show: READY=True, SCHEDULABLE=True
```

**Check all pods:**
```bash
sudo kubectl get pods -A
# All pods should be Running
```

**Check cluster validation:**
```bash
sudo ./scripts/validate-cluster.sh
# Should pass all checks
```

---

## Common Scenarios

### Scenario 1: Normal Reboot

```bash
$ sudo reboot
# Wait 2-3 minutes

$ sudo kubectl get nodes
NAME             STATUS   ROLES                       AGE   VERSION
canada-pc-0001   Ready    control-plane,etcd,master   10h   v1.28.5+k3s1

$ sudo kubectl get pods -A | grep -v Running
# Should be empty (all pods Running)
```

**Result:** ✅ Everything works!

### Scenario 2: Power Loss

```bash
# Power outage happens
# UPS kicks in or system shuts down
# Power restored
# System boots automatically

# After 2-3 minutes:
$ sudo kubectl get nodes
NAME             STATUS   READY
canada-pc-0001   Ready    True

# Cluster recovered automatically!
```

**Result:** ✅ Cluster self-recovers!

### Scenario 3: USB Drive Disconnected

```bash
# Someone unplugs USB drive accidentally
# System still running

$ df -h | grep longhorn
# One or both disks missing!

$ sudo kubectl get pods -n longhorn-system
# Longhorn pods CrashLoopBackOff

# Reconnect USB drive
# Wait 1-2 minutes

$ sudo kubectl get pods -n longhorn-system
# Pods recover automatically!
```

**Result:** ✅ Self-healing (once drives reconnected)!

---

## Boot Time Expectations

### With Internal Drives (SATA/NVMe)

```
Total boot time: 60-90 seconds
├─ BIOS/UEFI: 5-10s
├─ Kernel load: 3-5s
├─ Disk mount: 1-2s
├─ K3s start: 20-30s
└─ All pods ready: 30-40s
```

### With External USB Drives

```
Total boot time: 90-120 seconds
├─ BIOS/UEFI: 5-10s
├─ Kernel load: 3-5s
├─ USB detection: 10-30s  ← Extra time!
├─ Disk mount: 2-5s
├─ K3s start: 20-30s
└─ All pods ready: 40-50s
```

**Key difference:** USB drives add 10-30 seconds for detection.

---

## Monitoring Boot Status

### Watch Boot Progress

```bash
# Terminal 1: Watch systemd boot
sudo journalctl -f -u k3s

# Terminal 2: Watch pods
watch sudo kubectl get pods -A

# Terminal 3: Watch nodes
watch sudo kubectl get nodes
```

### Check What Went Wrong

```bash
# Check K3s service
sudo systemctl status k3s

# Check if disks mounted
df -h | grep longhorn

# Check K3s logs
sudo journalctl -u k3s -n 100

# Check pod events
sudo kubectl get events -A --sort-by='.lastTimestamp'
```

---

## Advanced: Disk Mount Options

### Current /etc/fstab Configuration

```bash
# Check current setup
cat /etc/fstab | grep longhorn
UUID=54dd9fe9...  /mnt/longhorn-disks/disk-sda  ext4  defaults  0  2
UUID=0109b141...  /mnt/longhorn-disks/disk-sdb  ext4  defaults  0  2
```

### Options Explained

| Field | Value | Meaning |
|-------|-------|---------|
| Device | `UUID=...` | ✅ Good! UUID-based (stable) |
| Mount Point | `/mnt/longhorn-disks/...` | Where disk appears |
| Filesystem | `ext4` | File system type |
| Options | `defaults` | Standard mount options |
| Dump | `0` | Don't backup with dump |
| Pass | `2` | Check after root filesystem |

**Why UUID is important:**
- `/dev/sda` can change order (USB order not guaranteed)
- `UUID` is unique to each disk (stable)
- Ensures correct disk goes to correct mount point

---

## Troubleshooting

### Issue: Disks Don't Mount on Boot

**Symptoms:**
```bash
$ df -h | grep longhorn
# No results
```

**Fix:**
```bash
# Mount manually
sudo mount -a

# Check for errors
sudo journalctl -xe | grep mount

# Verify fstab
cat /etc/fstab | grep longhorn

# Test mount
sudo mount /mnt/longhorn-disks/disk-sda
```

### Issue: K3s Starts Before Disks Ready

**Symptoms:**
```bash
$ sudo kubectl get nodes.longhorn.io -n longhorn-system
# Shows disk errors or "DiskNotReady"
```

**Fix:**
```bash
# Apply boot order fix
sudo ./scripts/fix-usb-disk-boot.sh

# Reboot to test
sudo reboot
```

### Issue: Longhorn Pods CrashLoopBackOff

**Symptoms:**
```bash
$ sudo kubectl get pods -n longhorn-system
NAME                            READY   STATUS             RESTARTS
longhorn-manager-xxxxx          0/1     CrashLoopBackOff   5
```

**Fix:**
```bash
# Check if disks are mounted
df -h | grep longhorn

# If not mounted:
sudo mount -a

# Restart Longhorn pods
sudo kubectl delete pods -n longhorn-system -l app=longhorn-manager

# Wait 2-3 minutes
sudo kubectl get pods -n longhorn-system
```

---

## Rollback (If Needed)

### Remove Boot Order Fix

If the fix causes issues (unlikely):

```bash
# Remove the override
sudo rm /etc/systemd/system/k3s.service.d/wait-for-disks.conf

# Reload systemd
sudo systemctl daemon-reload

# Restart K3s
sudo systemctl restart k3s
```

---

## Best Practices

### 1. Always Use UUID in fstab ✅

```bash
# Good (current setup)
UUID=54dd9fe9...  /mnt/longhorn-disks/disk-sda  ext4  defaults  0  2

# Bad (don't do this)
/dev/sda  /mnt/longhorn-disks/disk-sda  ext4  defaults  0  2
```

**Why:** `/dev/sda` can become `/dev/sdb` if boot order changes!

### 2. Label Your Disks 🏷️

```bash
# Add labels for easy identification
sudo e2label /dev/sda LONGHORN-SDA
sudo e2label /dev/sdb LONGHORN-SDB

# Verify
sudo e2label /dev/sda
```

### 3. Test Reboots Regularly 🧪

```bash
# Monthly reboot test
sudo reboot

# After reboot, verify
./scripts/validate-cluster.sh
```

### 4. Monitor Disk Health 📊

```bash
# Check SMART status (if supported over USB)
sudo smartctl -a /dev/sda
sudo smartctl -a /dev/sdb

# Check disk usage
df -h | grep longhorn

# Check Longhorn storage
sudo kubectl get nodes.longhorn.io -n longhorn-system
```

---

## Summary

| Question | Answer |
|----------|--------|
| **Will cluster auto-start?** | ✅ YES (after applying fix) |
| **Do I need the fix?** | ✅ YES (for external USB drives) |
| **What if I skip the fix?** | ⚠️ Cluster may fail on reboot |
| **Can I test it safely?** | ✅ YES (just reboot and check) |
| **Can I roll back?** | ✅ YES (remove override file) |
| **Will data be lost?** | ❌ NO (data safe on disks) |

---

## Quick Commands Reference

```bash
# Apply fix
sudo ./scripts/fix-usb-disk-boot.sh

# Test reboot
sudo reboot

# After reboot, verify
sudo systemctl status k3s
df -h | grep longhorn
sudo kubectl get nodes
./scripts/validate-cluster.sh

# Rollback if needed
sudo rm /etc/systemd/system/k3s.service.d/wait-for-disks.conf
sudo systemctl daemon-reload
```

---

**Key Takeaway:** With external USB drives, the boot-order fix is ESSENTIAL for reliable automatic startup! Apply it once, never worry again.
