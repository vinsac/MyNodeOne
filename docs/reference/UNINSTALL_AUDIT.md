# Uninstall Script Audit Report

**Date:** 2025-11-09  
**Script:** `scripts/uninstall-mynodeone.sh`  
**Status:** 🔴 **CRITICAL GAPS FOUND**

---

## 🚨 Critical Issues Found

### **Issue 1: ConfigMaps Not Deleted** 🔴 CRITICAL

**Problem:** Kubernetes ConfigMaps persist after uninstall, including registries with potentially corrupted data.

**Impact:**
- Old domain-registry schema would persist
- service-registry entries remain
- sync-controller-registry nodes remain
- cluster-info ConfigMap remains

**Risk:** Reinstalling would use old/corrupted ConfigMaps instead of fresh ones!

**Missing Cleanup:**
```bash
❌ service-registry (kube-system)
❌ domain-registry (kube-system)
❌ sync-controller-registry (kube-system)
❌ cluster-info (default)
❌ All application ConfigMaps
```

---

### **Issue 2: Git Repository Not Removed** 🟡 HIGH

**Problem:** `~/MyNodeOne/` directory not explicitly cleaned

**Impact:**
- Old scripts remain
- Local modifications persist
- Unclear what version will be used on reinstall

**Missing Cleanup:**
```bash
❌ ~/MyNodeOne/ directory
❌ /root/MyNodeOne/ directory
```

---

### **Issue 3: SSH Known Hosts Not Cleaned** 🟡 MEDIUM

**Problem:** SSH known_hosts entries for cluster nodes remain

**Impact:**
- Fingerprint warnings on reinstall
- Potential connection issues if IPs reused

**Missing Cleanup:**
```bash
❌ ~/.ssh/known_hosts (Tailscale IP entries)
❌ /root/.ssh/known_hosts
```

---

### **Issue 4: Registry Cache Files Not Removed** 🟡 MEDIUM

**Problem:** Local registry cache files not cleaned

**Impact:**
- Stale registry data in local files
- Potential sync issues

**Missing Cleanup:**
```bash
❌ ~/.mynodeone/node-registry.json
❌ ~/.mynodeone/*.backup.*
❌ /root/.mynodeone/node-registry.json
```

---

### **Issue 5: Docker Volumes Not Explicitly Removed** 🟢 LOW

**Problem:** Docker volumes for Traefik/Let's Encrypt may persist

**Impact:**
- Old SSL certificates remain
- Acme.json persists

**Missing Cleanup:**
```bash
⚠️  /etc/traefik/acme.json
⚠️  Docker volumes (traefik_*)
```

---

## What Currently Gets Cleaned ✅

| Item | Status | Location |
|------|--------|----------|
| K3s cluster | ✅ Removed | /usr/local/bin/k3s |
| Longhorn | ✅ Removed | /var/lib/longhorn |
| DNS configs | ✅ Removed | /etc/hosts, dnsmasq |
| Systemd services | ✅ Removed | mynodeone-sync-controller |
| Traefik directory | ✅ Removed | /etc/traefik/ |
| Cron jobs | ✅ Removed | VPS sync cron |
| Config files | ✅ Removed | ~/.mynodeone/, ~/.kube/ |
| Tailscale | ⚠️ Optional | Can be removed |

---

## What's Missing ❌

| Item | Risk Level | Impact |
|------|------------|--------|
| **ConfigMaps** | 🔴 Critical | Old schema persists |
| Git repository | 🟡 High | Old scripts remain |
| SSH known_hosts | 🟡 Medium | Connection warnings |
| Registry caches | 🟡 Medium | Stale data |
| Docker volumes | 🟢 Low | Old certs remain |
| Backup files | 🟢 Low | Disk space |

---

## Recommended Fixes

### Fix 1: Add ConfigMap Cleanup (CRITICAL)

```bash
# Before removing K3s, clean ConfigMaps
if command -v kubectl &> /dev/null; then
    log_info "Cleaning Kubernetes ConfigMaps..."
    
    # Remove MyNodeOne ConfigMaps
    kubectl delete configmap service-registry -n kube-system --ignore-not-found=true
    kubectl delete configmap domain-registry -n kube-system --ignore-not-found=true
    kubectl delete configmap sync-controller-registry -n kube-system --ignore-not-found=true
    kubectl delete configmap cluster-info -n default --ignore-not-found=true
    
    log_success "ConfigMaps cleaned"
fi
```

### Fix 2: Add Git Repository Cleanup

```bash
# Remove git repository
if [ "$KEEP_CONFIG" = false ]; then
    for dir in "$HOME/MyNodeOne" "/root/MyNodeOne"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log_success "Removed $dir"
        fi
    done
fi
```

### Fix 3: Add SSH Known Hosts Cleanup

```bash
# Clean SSH known_hosts for Tailscale IPs
if [ -f ~/.ssh/known_hosts ]; then
    sed -i '/^100\./d' ~/.ssh/known_hosts 2>/dev/null || true
    log_success "Cleaned SSH known_hosts"
fi

if [ -f /root/.ssh/known_hosts ]; then
    sed -i '/^100\./d' /root/.ssh/known_hosts 2>/dev/null || true
fi
```

### Fix 4: Add Registry Cache Cleanup

```bash
# Remove registry cache files
rm -f ~/.mynodeone/node-registry.json* 2>/dev/null || true
rm -f /root/.mynodeone/node-registry.json* 2>/dev/null || true
rm -f ~/.mynodeone/*.backup.* 2>/dev/null || true
rm -f /root/.mynodeone/*.backup.* 2>/dev/null || true
```

### Fix 5: Add Docker Volume Cleanup

```bash
# Remove Docker volumes
if command -v docker &> /dev/null; then
    docker volume ls -q | grep traefik | xargs -r docker volume rm 2>/dev/null || true
    log_success "Removed Docker volumes"
fi
```

---

## Test Plan

### Before Fix
```bash
# Run current uninstall
sudo ./scripts/uninstall-mynodeone.sh --full --yes

# Check what remains
kubectl get cm -n kube-system | grep -E "service-registry|domain-registry|sync-controller"
# Expected: ConfigMaps still exist ❌

ls -la ~/MyNodeOne/
# Expected: Directory still exists ❌
```

### After Fix
```bash
# Run fixed uninstall
sudo ./scripts/uninstall-mynodeone.sh --full --yes

# Verify cleanup
kubectl get cm -n kube-system 2>/dev/null
# Expected: Connection refused (K3s removed) ✅

ls -la ~/MyNodeOne/
# Expected: Directory not found ✅

ls -la ~/.mynodeone/
# Expected: Directory not found ✅
```

---

## Proposed Uninstall Order (Fixed)

```
1. Detect node type
2. Ask user preferences
3. ✅ Stop services
4. **NEW: Clean ConfigMaps (before removing K3s)**
5. ✅ Remove K3s/Kubernetes
6. ✅ Remove Longhorn
7. ✅ Remove DNS configs
8. ✅ Remove systemd services
9. ✅ Remove Tailscale (optional)
10. ✅ Remove config files
11. **NEW: Clean SSH known_hosts**
12. **NEW: Remove Git repository**
13. **NEW: Clean Docker volumes**
14. ✅ Final verification
```

---

## Summary

**Current State:** 🔴 **INCOMPLETE**
- Leaves critical ConfigMaps with potentially corrupted data
- Old scripts remain in place
- Stale SSH and cache entries

**Recommended:** 🟢 **APPLY ALL FIXES**
- Ensures truly clean slate
- Prevents old schema from persisting
- Eliminates all remnants

**Priority:** 🔴 **HIGH - Fix before recommending reinstall**

Without ConfigMap cleanup, reinstalling could reuse the old domain-registry structure we just fixed!
