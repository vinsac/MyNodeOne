#!/bin/bash

###############################################################################
# MyNodeOne - Error Recovery & Resilience Library
# 
# Auto-recovery functions for handling partial failures
###############################################################################

# Detect and recover from partial K3s installation
recover_k3s_partial_install() {
    local log_file="${1:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking for partial K3s installation..." >> "$log_file"
    
    # Check if K3s binary exists but service isn't running
    if [ -f /usr/local/bin/k3s ] && ! systemctl is-active --quiet k3s; then
        echo "[$(date)] Found partial K3s installation - attempting recovery..." >> "$log_file"
        
        # Try to start the service
        if systemctl start k3s 2>&1 | tee -a "$log_file"; then
            echo "[$(date)] K3s service started successfully" >> "$log_file"
            return 0
        else
            echo "[$(date)] K3s service failed to start - may need reinstall" >> "$log_file"
            return 1
        fi
    fi
    
    return 0
}

# Recover from partial helm repository state
recover_helm_repos() {
    local log_file="${1:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking helm repositories..." >> "$log_file"
    
    if ! command -v helm &> /dev/null; then
        echo "[$(date)] Helm not installed - skipping repo recovery" >> "$log_file"
        return 1
    fi
    
    # Try to update repos with timeout
    echo "[$(date)] Attempting helm repo update..." >> "$log_file"
    if timeout 60 helm repo update >> "$log_file" 2>&1; then
        echo "[$(date)] Helm repos updated successfully" >> "$log_file"
        return 0
    else
        echo "[$(date)] Helm repo update timed out or failed" >> "$log_file"
        
        # Remove corrupted cache
        echo "[$(date)] Clearing helm cache..." >> "$log_file"
        rm -rf ~/.cache/helm ~/.config/helm 2>> "$log_file"
        
        # Try again
        if timeout 60 helm repo update >> "$log_file" 2>&1; then
            echo "[$(date)] Helm repos recovered after cache clear" >> "$log_file"
            return 0
        fi
        
        return 1
    fi
}

# Recover from stuck pods
recover_stuck_pods() {
    local namespace="$1"
    local log_file="${2:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking for stuck pods in namespace: $namespace..." >> "$log_file"
    
    if ! command -v kubectl &> /dev/null; then
        echo "[$(date)] kubectl not available - skipping pod recovery" >> "$log_file"
        return 1
    fi
    
    # Find pods stuck in Pending, ContainerCreating, or CrashLoopBackOff
    local stuck_pods=$(kubectl get pods -n "$namespace" 2>/dev/null | \
        grep -E "Pending|ContainerCreating|Error|CrashLoopBackOff" | \
        awk '{print $1}')
    
    if [ -z "$stuck_pods" ]; then
        echo "[$(date)] No stuck pods found" >> "$log_file"
        return 0
    fi
    
    echo "[$(date)] Found stuck pods:" >> "$log_file"
    echo "$stuck_pods" >> "$log_file"
    
    # Delete stuck pods to trigger recreation
    echo "$stuck_pods" | while read -r pod; do
        if [ -n "$pod" ]; then
            echo "[$(date)] Deleting stuck pod: $pod" >> "$log_file"
            kubectl delete pod "$pod" -n "$namespace" --grace-period=0 --force >> "$log_file" 2>&1
        fi
    done
    
    echo "[$(date)] Stuck pods deleted - waiting for recreation..." >> "$log_file"
    sleep 10
    
    return 0
}

# Recover from failed LoadBalancer IP allocation
recover_loadbalancer_ips() {
    local log_file="${1:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking LoadBalancer services..." >> "$log_file"
    
    if ! command -v kubectl &> /dev/null; then
        return 1
    fi
    
    # Find services stuck in <pending> state
    local pending_services=$(kubectl get svc -A 2>/dev/null | \
        grep LoadBalancer | grep "<pending>" | \
        awk '{print $1 " " $2}')
    
    if [ -z "$pending_services" ]; then
        echo "[$(date)] All LoadBalancer IPs allocated" >> "$log_file"
        return 0
    fi
    
    echo "[$(date)] Found services with pending IPs:" >> "$log_file"
    echo "$pending_services" >> "$log_file"
    
    # Check if MetalLB is running
    if ! kubectl get pods -n metallb-system 2>/dev/null | grep -q "Running"; then
        echo "[$(date)] MetalLB not running - IP allocation will fail" >> "$log_file"
        return 1
    fi
    
    # Restart MetalLB controller to retry IP allocation
    echo "[$(date)] Restarting MetalLB controller..." >> "$log_file"
    kubectl rollout restart deployment -n metallb-system controller >> "$log_file" 2>&1
    
    sleep 15
    
    # Check if IPs are now allocated
    local still_pending=$(kubectl get svc -A 2>/dev/null | \
        grep LoadBalancer | grep "<pending>" | wc -l)
    
    if [ "$still_pending" -eq 0 ]; then
        echo "[$(date)] All LoadBalancer IPs allocated successfully" >> "$log_file"
        return 0
    else
        echo "[$(date)] Still have $still_pending services pending - may need Tailscale route approval" >> "$log_file"
        return 1
    fi
}

# Clean up failed helm releases
cleanup_failed_helm_releases() {
    local namespace="$1"
    local log_file="${2:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking for failed helm releases in $namespace..." >> "$log_file"
    
    if ! command -v helm &> /dev/null; then
        return 1
    fi
    
    # Find failed releases
    local failed_releases=$(helm list -n "$namespace" 2>/dev/null | \
        grep -i "failed\|pending" | awk '{print $1}')
    
    if [ -z "$failed_releases" ]; then
        echo "[$(date)] No failed helm releases found" >> "$log_file"
        return 0
    fi
    
    echo "[$(date)] Found failed releases:" >> "$log_file"
    echo "$failed_releases" >> "$log_file"
    
    # Uninstall failed releases
    echo "$failed_releases" | while read -r release; do
        if [ -n "$release" ]; then
            echo "[$(date)] Uninstalling failed release: $release" >> "$log_file"
            helm uninstall "$release" -n "$namespace" >> "$log_file" 2>&1 || true
        fi
    done
    
    return 0
}

# Recover from disk mount failures
recover_disk_mounts() {
    local log_file="${1:-/tmp/mynodeone-recovery.log}"
    
    echo "[$(date)] Checking disk mounts..." >> "$log_file"
    
    # Check /etc/fstab for MyNodeOne mounts
    if grep -q "mynodeone\|longhorn-disks\|minio-disks" /etc/fstab 2>/dev/null; then
        echo "[$(date)] Found MyNodeOne mounts in fstab" >> "$log_file"
        
        # Try to mount all from fstab
        if mount -a >> "$log_file" 2>&1; then
            echo "[$(date)] All mounts successful" >> "$log_file"
            return 0
        else
            echo "[$(date)] Some mounts failed - check log for details" >> "$log_file"
            return 1
        fi
    fi
    
    return 0
}

# Check system state and auto-recover
auto_recover_system() {
    local log_file="/tmp/mynodeone-recovery-$(date +%Y%m%d-%H%M%S).log"
    
    echo "============================================" | tee "$log_file"
    echo "MyNodeOne Auto-Recovery" | tee -a "$log_file"
    echo "$(date)" | tee -a "$log_file"
    echo "============================================" | tee -a "$log_file"
    echo "" | tee -a "$log_file"
    
    local recovery_needed=false
    
    # 1. Recover K3s if needed
    if ! recover_k3s_partial_install "$log_file"; then
        echo "⚠ K3s recovery needed" | tee -a "$log_file"
        recovery_needed=true
    else
        echo "✓ K3s OK" | tee -a "$log_file"
    fi
    
    # 2. Recover helm repos
    if ! recover_helm_repos "$log_file"; then
        echo "⚠ Helm repos need attention" | tee -a "$log_file"
    else
        echo "✓ Helm repos OK" | tee -a "$log_file"
    fi
    
    # 3. Recover disk mounts
    if ! recover_disk_mounts "$log_file"; then
        echo "⚠ Disk mounts need attention" | tee -a "$log_file"
    else
        echo "✓ Disk mounts OK" | tee -a "$log_file"
    fi
    
    # 4. Check for stuck pods in key namespaces
    for ns in kube-system metallb-system monitoring longhorn-system; do
        if kubectl get namespace "$ns" &> /dev/null; then
            recover_stuck_pods "$ns" "$log_file"
        fi
    done
    
    # 5. Recover LoadBalancer IPs
    if ! recover_loadbalancer_ips "$log_file"; then
        echo "⚠ LoadBalancer IP allocation needs attention" | tee -a "$log_file"
    else
        echo "✓ LoadBalancer IPs OK" | tee -a "$log_file"
    fi
    
    echo "" | tee -a "$log_file"
    echo "============================================" | tee -a "$log_file"
    echo "Recovery complete. Log saved to: $log_file" | tee -a "$log_file"
    echo "============================================" | tee -a "$log_file"
    
    if [ "$recovery_needed" = true ]; then
        return 1
    else
        return 0
    fi
}

# Export functions
export -f recover_k3s_partial_install
export -f recover_helm_repos
export -f recover_stuck_pods
export -f recover_loadbalancer_ips
export -f cleanup_failed_helm_releases
export -f recover_disk_mounts
export -f auto_recover_system
