# Defensive Programming Audit - Storage Scripts

**Date:** January 6, 2026  
**Auditor:** Cascade AI  
**Scope:** Storage refactor scripts (Velero, MinIO, backup configuration)

---

## Executive Summary

✅ **Overall Assessment:** GOOD - Scripts follow defensive programming patterns well  
⚠️ **Issues Found:** 2 critical, 1 moderate  
🔧 **Fixes Required:** Yes

---

## Critical Issues

### 🔴 CRITICAL #1: File Ownership Pattern Inconsistency

**Location:** `scripts/storage/minio/install-worker.sh:419-420`

**Issue:**
```bash
local ACTUAL_USER="${SUDO_USER:-$(whoami)}"
local ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")
```

**Problem:**
- When script runs via `sudo` from remote management laptop, `$SUDO_USER` gives **management laptop user** (your-username), not **control plane user** (your-username)
- This is the EXACT issue we fixed in LLM API scripts
- Credentials file will be saved to wrong user's home directory
- File ownership will be set to non-existent user on worker node

**Impact:**
- Credentials saved to `/home/your-username/` which doesn't exist on worker node
- File creation fails silently or creates orphaned file
- User cannot find credentials after installation

**Reference:** Memory shows this exact issue was fixed in previous work:
> "Problem: Current scripts detect `$SUDO_USER` which gives management laptop user when running remotely, not control plane user."

**Fix Required:**
Use the established pattern from `lib/detect-actual-home.sh`:
```bash
# Source the standard detection library
source "$SCRIPT_DIR/../../lib/detect-actual-home.sh"
# Then use $ACTUAL_USER and $ACTUAL_HOME which are correctly detected
```

OR implement the full detection pattern:
```bash
# Detect actual user on THIS machine (not remote caller)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Check if SUDO_USER exists on THIS system
    if getent passwd "$SUDO_USER" &>/dev/null; then
        ACTUAL_USER="$SUDO_USER"
        ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        # SUDO_USER doesn't exist here, use current system user
        ACTUAL_USER=$(whoami)
        ACTUAL_HOME="$HOME"
    fi
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi
```

---

### 🔴 CRITICAL #2: Directory Creation Without User Validation

**Location:** `scripts/storage/minio/install-worker.sh:145-160`

**Issue:**
```bash
mkdir -p "$MINIO_DATA_DIR"
chown -R ${MINIO_UID}:${MINIO_GID} "$MINIO_DATA_DIR"
```

**Problem:**
- Hardcoded UID/GID (1000:1000) may not exist on worker node
- No validation that user/group exists before chown
- chown will fail if UID 1000 doesn't exist
- Script exits but leaves directories in inconsistent state

**Impact:**
- MinIO pods fail to start due to permission errors
- Difficult to debug (permissions look OK but user doesn't exist)
- Manual cleanup required

**Fix Required:**
```bash
# Validate or create minio user/group
if ! getent group "$MINIO_GROUP" &>/dev/null; then
    log_info "Creating minio group..."
    groupadd -g $MINIO_GID "$MINIO_GROUP" || log_warn "Group creation failed, using existing GID"
fi

if ! getent passwd "$MINIO_USER" &>/dev/null; then
    log_info "Creating minio user..."
    useradd -u $MINIO_UID -g $MINIO_GID -s /bin/false -d /nonexistent "$MINIO_USER" || log_warn "User creation failed, using existing UID"
fi

# Then do chown
chown -R ${MINIO_USER}:${MINIO_GROUP} "$MINIO_DATA_DIR"
```

---

## Moderate Issues

### 🟡 MODERATE #1: No SSH Usage (Good!)

**Status:** ✅ VERIFIED - No SSH calls in storage scripts

**Finding:**
- Searched all storage scripts for `ssh`, `scp`, `rsync`
- **Result:** No SSH usage found
- Scripts run locally on the node where they're executed
- No remote execution or file transfer

**Why This Matters:**
- Previous issues with SSH key exchange, password prompts
- Storage scripts avoid this complexity entirely
- Good architectural decision

---

## Good Practices Found ✅

### 1. Error Propagation
**Status:** ✅ EXCELLENT

All scripts use:
```bash
set -euo pipefail
```

- `-e`: Exit on error
- `-u`: Exit on undefined variable
- `-o pipefail`: Catch errors in pipes

Functions return proper exit codes:
```bash
if ! check_requirements; then
    log_error "Prerequisites check failed"
    exit 1
fi
```

### 2. Prerequisite Checks
**Status:** ✅ EXCELLENT

All scripts check:
- Root privileges (`$EUID -ne 0`)
- Required commands (`kubectl`, `helm`, `velero`)
- Cluster connectivity
- Dependent services

### 3. Retry Logic
**Status:** ✅ EXCELLENT

```bash
retry_command() {
    local max_attempts=$1
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done
    
    return 1
}
```

Used for:
- Network downloads (Velero CLI)
- Helm repo operations
- External API calls

### 4. Verification Steps
**Status:** ✅ EXCELLENT

All installations followed by verification:
- CLI command availability
- Kubernetes resource existence
- Pod status checks
- Service availability

### 5. Logging and User Feedback
**Status:** ✅ EXCELLENT

Consistent logging with color-coded output:
- `log_info` - Blue
- `log_success` - Green
- `log_warn` - Yellow
- `log_error` - Red

Clear progress indicators and error messages.

### 6. Cleanup on Failure
**Status:** ✅ GOOD

Temporary files cleaned up:
```bash
local TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
# ... operations ...
rm -rf "$TEMP_DIR"
```

Even on failure paths.

### 7. Idempotency
**Status:** ✅ EXCELLENT

Scripts check if already installed:
```bash
if command -v velero &> /dev/null; then
    log_info "Velero CLI already installed"
    return 0
fi
```

Safe to run multiple times.

---

## Security Review

### Credentials Handling
**Status:** ✅ GOOD (with fixes needed)

**Good:**
- Credentials generated with strong randomness
- Stored in Kubernetes secrets
- File permissions set to 600
- Warning to delete file after saving

**Needs Fix:**
- File ownership issue (Critical #1)

### Secrets Management
**Status:** ✅ EXCELLENT

- MinIO credentials in K8s secret `minio-credentials`
- Velero credentials in K8s secret `cloud-credentials`
- No hardcoded credentials
- Proper base64 encoding/decoding

### Network Security
**Status:** ✅ GOOD

- MinIO uses LoadBalancer (Tailscale network only)
- No external exposure
- Credentials required for access

---

## Comparison with Existing Codebase Patterns

### Pattern Consistency Check

✅ **Matches:** `lib/detect-actual-home.sh` pattern (but not used)  
❌ **Differs:** Direct `$SUDO_USER` usage instead of sourcing library  
✅ **Matches:** Error handling pattern from bootstrap scripts  
✅ **Matches:** Logging functions from other scripts  
✅ **Matches:** Retry logic pattern  

---

## Testing Considerations

### What Could Go Wrong

1. **File Ownership (Critical #1)**
   - Test: Run from management laptop via SSH
   - Expected: Credentials saved to wrong user
   - Fix: Implement proper user detection

2. **UID/GID Mismatch (Critical #2)**
   - Test: Worker node without UID 1000
   - Expected: chown fails, MinIO pods fail
   - Fix: Create user/group or validate existence

3. **Disk Detection**
   - Test: Worker with no dedicated disks
   - Expected: Fallback to `/var/lib/minio`
   - Status: ✅ Already handled

4. **Network Failures**
   - Test: Helm repo unreachable
   - Expected: Retry 3 times, then fail gracefully
   - Status: ✅ Already handled

5. **Kubernetes Not Ready**
   - Test: Run before cluster initialized
   - Expected: Prerequisite check fails
   - Status: ✅ Already handled

---

## Recommendations

### Immediate Fixes Required

1. **Fix Critical #1** - File ownership detection
   - Priority: HIGH
   - Impact: Installation failure
   - Effort: 10 minutes

2. **Fix Critical #2** - User/group validation
   - Priority: HIGH
   - Impact: MinIO startup failure
   - Effort: 15 minutes

### Future Enhancements

1. **Standardize User Detection**
   - Create shared library for user detection
   - All scripts source from one place
   - Prevents future inconsistencies

2. **Add Rollback Capability**
   - If installation fails, clean up resources
   - Delete created directories
   - Remove Kubernetes resources

3. **Add Dry-Run Mode**
   - `--dry-run` flag to show what would be done
   - Useful for testing and validation

4. **Add Verbose Mode**
   - `--verbose` flag for debugging
   - Show all commands being executed

---

## Conclusion

The storage scripts demonstrate **good defensive programming** overall:
- Proper error handling
- Prerequisite validation
- Retry logic
- Verification steps
- Clean logging

However, **2 critical issues** must be fixed before production use:
1. File ownership detection (affects credentials)
2. User/group validation (affects MinIO startup)

These are **known patterns** from previous work and have **established fixes** in the codebase.

**Recommendation:** Fix critical issues, then proceed with testing.

---

## Action Items

- [ ] Fix `install-worker.sh` user detection (Critical #1)
- [ ] Fix `install-worker.sh` UID/GID validation (Critical #2)
- [ ] Test on fresh worker node
- [ ] Test from remote management laptop
- [ ] Verify credentials file location
- [ ] Verify MinIO pod startup
- [ ] Document user detection pattern for future scripts
