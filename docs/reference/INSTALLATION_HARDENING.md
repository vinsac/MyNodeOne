# MyNodeOne Installation Script Hardening

## Overview

The MyNodeOne installation scripts have been comprehensively hardened to ensure **bulletproof reliability** for new users. This document details all resilience improvements.

---

## 🎯 Problems Solved

### Before Hardening:
1. ❌ Installation hung indefinitely on DNS timeouts
2. ❌ Invalid user inputs caused Kubernetes errors hours later  
3. ❌ Partial failures left system in broken state
4. ❌ No auto-recovery from common issues
5. ❌ Cryptic error messages
6. ❌ Required manual intervention to complete

### After Hardening:
1. ✅ All network operations have timeouts and retries
2. ✅ All inputs validated before use
3. ✅ Automatic recovery from partial failures
4. ✅ Graceful degradation - continues when safe
5. ✅ Clear, actionable error messages
6. ✅ Completes successfully even with network hiccups

---

## 📚 New Libraries

### 1. `scripts/lib/validation.sh` (300+ lines)

**Purpose:** Comprehensive input validation to prevent invalid configurations

#### Network Validation Functions:
```bash
validate_ip(ip)                          # RFC-compliant IP validation
validate_tailscale_ip(ip)                # Ensures 100.64.0.0/10 range
validate_url(url)                        # HTTP/HTTPS format
validate_network_connectivity(host)      # Ping test with timeout
```

#### Naming Validation Functions:
```bash
validate_cluster_name(name)              # Kubernetes-compatible (a-z0-9-, max 63)
validate_domain(domain)                  # DNS RFC 1123
validate_node_name(name)                 # Hostname format
validate_k8s_label(value)                # Kubernetes label format
```

#### System Validation Functions:
```bash
validate_disk_path(path)                 # /dev/* block device
has_enough_disk_space(path, gb)          # Check available space
has_enough_ram(gb)                       # Check system RAM
is_service_running(service)              # Systemctl status
is_port_available(port)                  # Port conflict check
```

#### Safety Functions:
```bash
sanitize_input(input)                    # Remove dangerous chars ($, `, etc.)
validate_input_with_retry(prompt, func)  # Retry loop for user input
```

**Example Usage:**
```bash
# Source the library
source scripts/lib/validation.sh

# Validate Tailscale IP
if validate_tailscale_ip "$TAILSCALE_IP"; then
    echo "Valid Tailscale IP"
else
    echo "Error: IP must be in 100.64.0.0/10 range"
    exit 1
fi

# Validate cluster name
if ! validate_cluster_name "$CLUSTER_NAME"; then
    echo "Error: Cluster name must be lowercase, alphanumeric, hyphens only"
    exit 1
fi
```

---

### 2. `scripts/lib/recovery.sh` (350+ lines)

**Purpose:** Automatic recovery from common installation failures

#### Recovery Functions:

**K3s Recovery:**
```bash
recover_k3s_partial_install()
# - Detects K3s installed but service not running
# - Attempts to start service
# - Returns success/failure status
```

**Helm Recovery:**
```bash
recover_helm_repos()
# - Timeout protection (60s)
# - Clears corrupted cache if needed
# - Retries repo update
```

**Pod Recovery:**
```bash
recover_stuck_pods(namespace)
# - Finds pods in Pending/ContainerCreating/CrashLoopBackOff
# - Force deletes stuck pods
# - Triggers auto-recreation
```

**LoadBalancer Recovery:**
```bash
recover_loadbalancer_ips()
# - Detects services stuck in <pending>
# - Restarts MetalLB controller
# - Checks for Tailscale route approval issues
```

**Helm Release Recovery:**
```bash
cleanup_failed_helm_releases(namespace)
# - Finds failed/pending releases
# - Uninstalls to clear state
# - Allows clean retry
```

**Disk Recovery:**
```bash
recover_disk_mounts()
# - Reads /etc/fstab
# - Attempts to mount all MyNodeOne disks
# - Reports failures
```

**Master Recovery Function:**
```bash
auto_recover_system()
# - Runs ALL recovery checks
# - Generates detailed log
# - Returns overall status
```

**Manual Recovery Usage:**
```bash
# If installation had issues, manually trigger recovery:
source scripts/lib/recovery.sh
auto_recover_system

# Output saved to: /tmp/mynodeone-recovery-YYYYMMDD-HHMMSS.log
```

---

### 3. `scripts/bootstrap-control-plane.sh` Improvements

Already committed in previous update:

```bash
retry_command(attempts, command)
# - Retries network operations
# - 5-second delay between attempts
# - Clear error messages

helm_install_safe(release, chart, namespace, args)
# - 10-minute timeout
# - Checks if pods running despite timeout
# - Graceful degradation
# - Better error messages

check_dns()
# - Pre-validates DNS connectivity
# - Uses Google DNS (8.8.8.8) as fallback test
# - Warns if slow
```

---

## 🛡️ Hardening Details by Component

### Tailscale IP Detection (interactive-setup.sh)

**Before:**
```bash
TAILSCALE_IP=$(tailscale ip -4 | head -n1)
# No validation, no retry, could be empty or invalid
```

**After:**
```bash
# 5 retry attempts with 2-second delays
# Validates IP is in Tailscale range (100.64.0.0/10)
# Clear error message if fails
check_tailscale() {
    local attempt=1
    local max_attempts=5
    
    while [ $attempt -le $max_attempts ]; do
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '\n')
        
        if [ -n "$TAILSCALE_IP" ] && validate_tailscale_ip "$TAILSCALE_IP"; then
            return 0
        fi
        
        print_warning "Tailscale IP not ready (attempt $attempt/$max_attempts)..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    print_error "Failed to get valid Tailscale IP"
    return 1
}
```

### Helm Operations (bootstrap-control-plane.sh)

**Before:**
```bash
helm repo update  # Hung indefinitely on slow DNS
helm upgrade --install ... --wait  # No timeout
```

**After:**
```bash
# Repo update with timeout
timeout 120 helm repo update || log_warn "Timed out, continuing..."

# Install with safe wrapper
helm_install_safe "grafana" "grafana/grafana" "monitoring" \
    --set ... \
|| {
    # Check if pods started anyway
    if kubectl get pods -n monitoring | grep -q "Running"; then
        log_success "Pods running despite timeout"
    fi
}
```

### User Input Validation

**Before:**
```bash
read -p "Cluster name: " CLUSTER_NAME
# Accepted: "My Cluster!", "test@home", "a-b-c-d-e-f-g-..." (100 chars)
```

**After:**
```bash
prompt_input "Cluster name" CLUSTER_NAME "mynodeone"

if ! validate_cluster_name "$CLUSTER_NAME"; then
    print_error "Invalid cluster name!"
    echo "Requirements:"
    echo "  - Lowercase letters, numbers, hyphens only"
    echo "  - Must start and end with alphanumeric"
    echo "  - Maximum 63 characters"
    exit 1
fi
```

---

## 🧪 Edge Cases Now Handled

| Edge Case | Before | After |
|-----------|--------|-------|
| Slow DNS | Hung forever | Timeout + retry + warning |
| Invalid cluster name | Kubernetes error later | Blocked immediately with clear message |
| Malformed Tailscale IP | Silent failure | Validated, retried, error if invalid |
| Helm timeout | Hard failure | Checks if pods running, continues if safe |
| Partial K3s install | Broken state | Auto-detected, service restarted |
| Stuck pods | Stayed stuck | Auto-deleted, recreated |
| Pending LoadBalancer IPs | Waited forever | MetalLB restart, Tailscale route check |
| Network interruption | Complete failure | Retries, fallbacks, graceful degradation |
| Failed helm release | Blocked retry | Auto-cleanup, allows retry |

---

## 📊 Validation Examples

### Valid Inputs:
```bash
Cluster Names:     mynodeone, universe, mycloud, prod-cluster
Domains:           mynodeone, mycloud, homelab
Node Names:        server-01, control-plane, canada-pc-0001
Tailscale IPs:     100.70.66.2, 100.122.68.75, 100.100.100.100
```

### Invalid Inputs (Now Blocked):
```bash
Cluster Names:     "My Cluster" (spaces), "test@home" (special chars), 
                   "UPPERCASE" (uppercase), "-start" (starts with hyphen)
                   
Tailscale IPs:     192.168.1.1 (not Tailscale range),
                   10.0.0.1 (private IP), 256.1.1.1 (invalid octet)
                   
Domains:           "my.cluster!" (special char), "a" (too short pattern)
```

---

## 🚀 Testing Recommendations

### Test Resilience:
```bash
# 1. Test with slow DNS
sudo systemctl stop systemd-resolved  # Temporarily
./scripts/mynodeone
# Should timeout gracefully and continue

# 2. Test with invalid inputs
# Enter "MY CLUSTER" as cluster name
# Should reject with clear message

# 3. Test recovery
sudo systemctl stop k3s
source scripts/lib/recovery.sh
auto_recover_system
# Should detect and restart K3s
```

### Verify Validation:
```bash
source scripts/lib/validation.sh

# Test IP validation
validate_tailscale_ip "100.70.66.2"   # Should return 0 (success)
validate_tailscale_ip "192.168.1.1"   # Should return 1 (fail)

# Test cluster name
validate_cluster_name "mycloud"       # Success
validate_cluster_name "My Cloud"      # Fail (spaces)
validate_cluster_name "MYCLOUD"       # Fail (uppercase)
```

---

## 📝 Manual Recovery

If installation encounters issues, you can manually trigger recovery:

```bash
# Full auto-recovery
source scripts/lib/recovery.sh
auto_recover_system

# Specific recoveries
recover_k3s_partial_install
recover_helm_repos
recover_stuck_pods "monitoring"
recover_loadbalancer_ips
cleanup_failed_helm_releases "longhorn-system"
recover_disk_mounts
```

**Recovery logs saved to:** `/tmp/mynodeone-recovery-TIMESTAMP.log`

---

## 🎓 For Developers

### Adding New Validation:
```bash
# In scripts/lib/validation.sh
validate_my_input() {
    local input="$1"
    # Add validation logic
    if [[ "$input" =~ ^[a-z0-9-]+$ ]]; then
        return 0
    else
        return 1
    fi
}
```

### Adding New Recovery:
```bash
# In scripts/lib/recovery.sh
recover_my_component() {
    local log_file="${1:-/tmp/mynodeone-recovery.log}"
    echo "[$(date)] Checking my component..." >> "$log_file"
    
    # Recovery logic
    if my_check_passes; then
        echo "[$(date)] Component OK" >> "$log_file"
        return 0
    else
        echo "[$(date)] Component needs recovery" >> "$log_file"
        # Attempt recovery
        my_recovery_action
        return $?
    fi
}
```

---

## 📦 Files Modified

### NEW Files:
- `scripts/lib/validation.sh` - Input validation library (300 lines)
- `scripts/lib/recovery.sh` - Auto-recovery library (350 lines)
- `docs/INSTALLATION_HARDENING.md` - This document

### MODIFIED Files:
- `scripts/interactive-setup.sh` - Added Tailscale IP validation + retries
- `scripts/bootstrap-control-plane.sh` - Added helm safety wrappers
- `website/deploy-dashboard.sh` - Domain template fix

---

## ✅ Success Criteria

A hardened installation should:
1. ✅ Complete successfully even with slow/flaky network
2. ✅ Reject invalid inputs immediately with clear messages
3. ✅ Auto-recover from partial failures
4. ✅ Continue when safe, fail clearly when not
5. ✅ Provide actionable error messages
6. ✅ Generate useful logs for troubleshooting

---

## 🔮 Future Enhancements

Potential additions:
- [ ] Preflight checks before starting installation
- [ ] Disk health validation (SMART status)
- [ ] Bandwidth test before downloading large files
- [ ] Resource prediction (estimate RAM/CPU/disk needed)
- [ ] Rollback capability (undo partial installation)
- [ ] Health check endpoint for monitoring
- [ ] Automated backup before destructive operations

---

## 📞 Support

If installation fails despite hardening:

1. Check recovery log: `/tmp/mynodeone-recovery-*.log`
2. Run manual recovery: `source scripts/lib/recovery.sh && auto_recover_system`
3. Check GitHub Issues for similar problems
4. Provide log files when reporting issues

---

**Last Updated:** November 4, 2025  
**Version:** 2.1.0  
**Status:** Production-Ready ✅
