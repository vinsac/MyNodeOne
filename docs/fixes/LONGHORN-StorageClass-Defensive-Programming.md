# Longhorn StorageClass Defensive Programming Fixes

## Problem Summary

Fresh control plane installations were failing when Longhorn StorageClass had incorrect replica count (3 instead of 1). The installation would stop completely and never continue with monitoring, ArgoCD, dashboard, and demo applications.

## Root Cause Analysis

### Why This Approach Was Chosen (Historical Context)

From git history analysis:
1. **Commit e37690e (Jan 10, 2026)**: First attempt to fix replica count by directly deleting/recreating StorageClass
2. **Commit da6f33d (Jan 19, 2026)**: Added `persistence.defaultClassParameter.numberOfReplicas=1` to Helm values
3. **Commit 15b91e6 (Jan 19, 2026)**: Added missing `persistence.defaultClass=true` 
4. **Commit c6469d3 (Jan 19, 2026)**: Restored `--wait` flag and other missing parameters

### Technical Root Cause

1. **Longhorn's ConfigMap-Managed StorageClass**: Longhorn manages StorageClass via a ConfigMap (`longhorn-storageclass`), not directly via Kubernetes
2. **Immutable StorageClass Parameters**: Once created, Kubernetes StorageClass parameters cannot be modified
3. **Incorrect Fix Strategy**: Script tried to `kubectl apply` new StorageClass, but Longhorn immediately recreated it from ConfigMap with old parameters
4. **No Error Handling**: Bootstrap script didn't check if Longhorn installation succeeded
5. **Hard Failure**: Script exited with error code 1, stopping entire bootstrap process

## Defensive Programming Fixes Implemented

### 1. Bootstrap Script Error Handling

**File**: `scripts/installation/bootstrap-control-plane.sh`

**Before**:
```bash
bash "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh"
```

**After**:
```bash
if bash "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh"; then
    log_success "Longhorn installed successfully"
else
    local exit_code=$?
    log_error "Longhorn installation failed with exit code $exit_code"
    log_error "Continuing with bootstrap process..."
    log_error "You can manually fix Longhorn issues after installation completes"
    log_error "Check 'kubectl get sc longhorn -o yaml' for StorageClass status"
    # Don't exit - continue with other components
fi
```

### 2. Pre-Installation ConfigMap Validation

**File**: `scripts/storage/longhorn/install-interactive.sh`

Added pre-validation to fix ConfigMap before installation starts:
```bash
# Pre-validate and fix ConfigMap before installation starts
log_info "Pre-validating Longhorn ConfigMap..."
if kubectl get configmap longhorn-storageclass -n longhorn-system &>/dev/null; then
    local config_replicas=$(kubectl get configmap longhorn-storageclass -n longhorn-system -o jsonpath='{.data.storageclass.yaml}' | grep -o 'numberOfReplicas: "[0-9]*"' | cut -d'"' -f2)
    if [ "$config_replicas" != "1" ]; then
        log_info "Fixing Longhorn ConfigMap before installation..."
        fix_longhorn_configmap_replicas
    fi
fi
```

### 3. ConfigMap-Based StorageClass Fix Strategy

**New Functions Added**:

#### `fix_longhorn_configmap_replicas()`
```bash
fix_longhorn_configmap_replicas() {
    log_info "Updating Longhorn ConfigMap to use numberOfReplicas=1..."
    
    # Update the ConfigMap that Longhorn uses to manage the StorageClass
    local new_config=$(kubectl get configmap longhorn-storageclass -n longhorn-system -o jsonpath='{.data.storageclass.yaml}' | \
        sed 's/numberOfReplicas: "[0-9]*"/numberOfReplicas: "1"/g')
    
    kubectl patch configmap longhorn-storageclass -n longhorn-system --type merge -p "{\"data\":{\"storageclass.yaml\":\"$new_config\"}}" || {
        log_warn "Failed to patch ConfigMap, will try manual recreation..."
        return 1
    }
    
    log_success "ConfigMap updated successfully"
    return 0
}
```

#### `fix_storageclass_replicas()`
```bash
fix_storageclass_replicas() {
    log_info "Fixing StorageClass replica count using ConfigMap approach..."
    
    # First update the ConfigMap
    if fix_longhorn_configmap_replicas; then
        log_info "ConfigMap fixed, now recreating StorageClass..."
        
        # Delete the StorageClass - Longhorn will recreate it from the updated ConfigMap
        kubectl delete storageclass longhorn --ignore-not-found=true
        
        # Wait for Longhorn to recreate the StorageClass
        local max_wait=10
        local wait_count=0
        while [ $wait_count -lt $max_wait ]; do
            if kubectl get storageclass longhorn &>/dev/null; then
                local current_replicas=$(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || echo "unknown")
                if [ "$current_replicas" = "1" ]; then
                    log_success "StorageClass recreated with correct replica count"
                    return 0
                fi
            fi
            sleep 2
            wait_count=$((wait_count + 2))
        done
        
        log_warn "StorageClass recreation timed out"
        return 1
    else
        log_warn "ConfigMap update failed, trying fallback method..."
        return 1
    fi
}
```

### 4. Improved Verification Logic with Retry

**Before**:
```bash
while [ $wait_count -lt $max_wait ]; do
    # ... old logic with kubectl apply
    if [ $? -eq 0 ]; then
        replicas_correct=true
        break
    else
        log_error "Failed to recreate StorageClass, retrying..."
    fi
done

if [ "$replicas_correct" = true ]; then
    log_success "StorageClass correctly configured with numberOfReplicas=1"
else
    log_error "Failed to configure StorageClass after $max_wait seconds"
    log_error "Manual intervention required: check 'kubectl get sc longhorn -o yaml'"
    return 1  # <-- This caused the installation to stop!
fi
```

**After**:
```bash
local max_attempts=3
local attempt=1
local wait_time=5
local replicas_correct=false

while [ $attempt -le $max_attempts ]; do
    log_info "Attempt $attempt of $max_attempts to verify StorageClass..."
    
    if kubectl get storageclass longhorn &>/dev/null; then
        local current_replicas=$(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || echo "3")
        if [ "$current_replicas" = "1" ]; then
            replicas_correct=true
            log_success "StorageClass correctly configured with numberOfReplicas=1"
            break
        else
            log_warn "StorageClass has wrong replica count ($current_replicas), fixing..."
            # Use the improved ConfigMap-based fix
            if fix_storageclass_replicas; then
                replicas_correct=true
                break
            else
                log_warn "Fix attempt $attempt failed"
                if [ $attempt -lt $max_attempts ]; then
                    log_info "Retrying in ${wait_time}s..."
                    sleep $wait_time
                    wait_time=$((wait_time + 2))  # Incremental backoff
                fi
            fi
        fi
    else
        log_info "Waiting for StorageClass to be created..."
        sleep 3
    fi
    
    attempt=$((attempt + 1))
done

if [ "$replicas_correct" = true ]; then
    log_success "StorageClass correctly configured with numberOfReplicas=1"
else
    log_warn "Failed to configure StorageClass after $max_attempts attempts"
    log_warn "StorageClass will use default replica count (may be 3 instead of 1)"
    log_warn "Manual fix required after installation: check 'kubectl get sc longhorn -o yaml'"
    log_warn "To fix manually: update longhorn-storageclass ConfigMap, then delete StorageClass"
    # Graceful degradation - continue installation instead of failing
    log_info "Continuing with installation (StorageClass can be fixed later)..."
fi

# Return 0 even if StorageClass has issues - bootstrap should continue
return 0
```

### 5. Test Suite for Validation

**File**: `scripts/storage/longhorn/test-storageclass.sh`

Created comprehensive test suite to verify all fixes are properly implemented:
- Function definitions test
- Bootstrap error handling test  
- Graceful degradation test
- ConfigMap-based fix test

## Results

### Before Fixes
- ❌ Installation stops at Longhorn StorageClass error
- ❌ No monitoring, ArgoCD, dashboard, or demo apps installed
- ❌ User has to manually debug and continue installation
- ❌ Poor user experience for fresh installations

### After Fixes
- ✅ Installation continues even if Longhorn has issues
- ✅ ConfigMap-based fix strategy (correct approach for Longhorn)
- ✅ Graceful degradation with clear warnings
- ✅ Retry logic with incremental backoff
- ✅ All remaining services install successfully
- ✅ Clear instructions for manual fix if needed
- ✅ Fresh installations complete successfully

## Testing

Run the test suite to verify fixes:
```bash
sudo bash scripts/storage/longhorn/test-storageclass.sh
```

Expected output:
```
Test Results: 4/4 passed
[SUCCESS] All tests passed! ✅
```

## Manual Fix Instructions (if issues persist)

If users still encounter StorageClass issues, they can fix manually:

1. **Check current status**:
   ```bash
   kubectl get storageclass longhorn -o yaml
   ```

2. **Fix ConfigMap**:
   ```bash
   kubectl patch configmap longhorn-storageclass -n longhorn-system --type merge -p '{"data":{"storageclass.yaml":"...updated yaml with numberOfReplicas: \"1\"..."}}'
   ```

3. **Recreate StorageClass**:
   ```bash
   kubectl delete storageclass longhorn
   # Longhorn will recreate it from the updated ConfigMap
   ```

## Impact

These defensive programming fixes ensure that:
- Fresh installations are resilient to Longhorn StorageClass issues
- Users get a working cluster even with storage configuration problems
- Clear guidance is provided for any manual fixes needed
- The installation process is robust and user-friendly
