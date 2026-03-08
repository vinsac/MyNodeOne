#!/bin/bash

# Health check script for LLMAPI infrastructure
# Detects and fixes common issues like stuck PVCs, unhealthy pods, and storage problems

set -euo pipefail

NAMESPACE="llmapi"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/llmapi/${SCRIPT_NAME}.log"
MONITOR_SCRIPT_PATH="/usr/local/bin/llmapi-health-monitor.sh"
POD_RESTART_THRESHOLD_SECONDS="${POD_RESTART_THRESHOLD_SECONDS:-1800}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$message"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$message" >> "$LOG_FILE" 2>/dev/null || true
}

error() {
    local message="ERROR: $1"
    echo -e "${RED}$message${NC}"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    local message="WARN: $1"
    echo -e "${YELLOW}$message${NC}"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE" 2>/dev/null || true
}

success() {
    local message="SUCCESS: $1"
    echo -e "${GREEN}$message${NC}"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE" 2>/dev/null || true
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        error "jq is not installed or not in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

# Function to force delete stuck PVCs
fix_stuck_pvcs() {
    log "Checking for stuck PVCs in namespace '$NAMESPACE'..."
    
    local stuck_pvcs=$(kubectl get pvc -n "$NAMESPACE" -o json | jq -r '.items[] | select(.status.phase=="Terminating" or .metadata.deletionTimestamp!=null) | .metadata.name')
    
    if [[ -z "$stuck_pvcs" ]]; then
        success "No stuck PVCs found"
        return 0
    fi
    
    warn "Found stuck PVCs: $stuck_pvcs"
    
    for pvc in $stuck_pvcs; do
        log "Attempting to fix PVC: $pvc"
        
        # Get associated PV
        local pv_name=$(kubectl get pvc "$pvc" -n "$NAMESPACE" -o json | jq -r '.spec.volumeName // empty')
        
        # Remove finalizers from PVC
        log "Removing finalizers from PVC: $pvc"
        kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":null}}' --type=merge || {
            warn "Failed to patch PVC $pvc"
            continue
        }
        
        # Remove finalizers from PV if it exists
        if [[ -n "$pv_name" ]]; then
            log "Removing finalizers from PV: $pv_name"
            kubectl patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge || {
                warn "Failed to patch PV $pv_name"
            }
        fi
        
        # Force delete PVC
        log "Force deleting PVC: $pvc"
        kubectl delete pvc "$pvc" -n "$NAMESPACE" --force --grace-period=0 || {
            warn "Failed to force delete PVC $pvc"
        }
        
        success "Fixed PVC: $pvc"
    done
}

# Function to check and fix pod issues
fix_pod_issues() {
    log "Checking for pod issues in namespace '$NAMESPACE'..."
    
    # Check for pods in problematic states
    local problematic_pods=$(kubectl get pods -n "$NAMESPACE" -o json | jq -r '.items[] | select(.status.phase!="Running" or (.status.containerStatuses[]? | select(.ready==false))) | .metadata.name')
    
    if [[ -z "$problematic_pods" ]]; then
        success "All pods are healthy"
        return 0
    fi
    
    warn "Found problematic pods: $problematic_pods"
    
    for pod in $problematic_pods; do
        local pod_status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o json | jq -r '.status.phase')
        local pod_age=$(kubectl get pod "$pod" -n "$NAMESPACE" -o json | jq -r '.metadata.creationTimestamp')
        
        log "Pod: $pod, Status: $pod_status, Age: $pod_age"
        
        # Get pod events
        log "Recent events for pod $pod:"
        kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' | tail -5 | tee -a "$LOG_FILE"
        
        # Check if pod is stuck beyond configured threshold (default: 30 minutes)
        local pod_age_seconds=$(date -d "$pod_age" +%s 2>/dev/null || echo 0)
        local current_seconds=$(date +%s)
        local age_diff=$((current_seconds - pod_age_seconds))
        
        if [[ $age_diff -gt $POD_RESTART_THRESHOLD_SECONDS ]]; then
            warn "Pod $pod has been problematic for more than $((POD_RESTART_THRESHOLD_SECONDS / 60)) minutes, attempting restart..."
            
            # Get deployment name
            local deployment=$(kubectl get pod "$pod" -n "$NAMESPACE" -o json | jq -r '.metadata.ownerReferences[]? | select(.kind=="ReplicaSet") | .name' | sed 's/[a-f0-9-]*$//')
            
            if [[ -n "$deployment" ]]; then
                log "Restarting deployment: $deployment"
                kubectl rollout restart deployment/"$deployment" -n "$NAMESPACE" || {
                    warn "Failed to restart deployment $deployment"
                }
                success "Initiated restart for deployment: $deployment"
            else
                log "Deleting pod $pod directly"
                kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 || {
                    warn "Failed to delete pod $pod"
                }
            fi
        fi
    done
}

# Function to check storage classes and Longhorn
check_storage_health() {
    log "Checking storage health..."
    
    # Check if Longhorn is healthy
    local longhorn_pods
    longhorn_pods=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}')
    local longhorn_total
    longhorn_total=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | wc -l)
    
    log "Longhorn pods: $longhorn_pods/$longhorn_total running"
    
    if [[ $longhorn_pods -lt $((longhorn_total - 1)) ]]; then
        warn "Some Longhorn pods are not running"
        kubectl get pods -n longhorn-system | tee -a "$LOG_FILE"
    else
        success "Longhorn is healthy"
    fi
    
    # Check storage classes
    if ! kubectl get storageclass longhorn &> /dev/null; then
        error "Longhorn storage class not found"
        return 1
    else
        success "Longhorn storage class is available"
    fi
}

# Function to check LLMAPI specific services
check_llmapi_services() {
    log "Checking LLMAPI services..."
    
    local services=("redis" "gateway" "embedding" "llmapi-postgres")
    
    for service in "${services[@]}"; do
        # Special handling for different label patterns
        if [[ "$service" == "gateway" ]]; then
            local pods=$(kubectl get pods -n "$NAMESPACE" -l app="llmapi-gateway" -o json | jq -r '.items[].metadata.name')
        elif [[ "$service" == "llmapi-postgres" ]]; then
            local pods=$(kubectl get pods -n "$NAMESPACE" -l app="llmapi-postgres" -o json | jq -r '.items[].metadata.name')
        else
            local pods=$(kubectl get pods -n "$NAMESPACE" -l app="$service" -o json | jq -r '.items[].metadata.name')
        fi
        
        if [[ -z "$pods" ]]; then
            error "No pods found for service: $service"
            continue
        fi
        
        local healthy=true
        for pod in $pods; do
            # Special handling for container name mapping
            local container_name="$service"
            if [[ "$service" == "gateway" ]]; then
                container_name="gateway"
            elif [[ "$service" == "llmapi-postgres" ]]; then
                container_name="postgres"
            fi
            
            local ready=$(kubectl get pod "$pod" -n "$NAMESPACE" -o json | jq -r '.status.containerStatuses[]? | select(.name=="'$container_name'") | .ready // false')
            
            if [[ "$ready" != "true" ]]; then
                error "Pod $pod for service $service is not ready"
                healthy=false
            fi
        done
        
        if [[ "$healthy" == "true" ]]; then
            success "Service $service is healthy"
        fi
    done
}

# Function to create monitoring systemd service (optional)
create_monitor_service() {
    if [[ "$EUID" -ne 0 ]]; then
        warn "Not running as root, skipping systemd service creation"
        return 0
    fi
    
    # Ensure log directory is writable
    mkdir -p /var/log/llmapi
    chown root:root /var/log/llmapi
    chmod 755 /var/log/llmapi
    
    log "Installing monitor script to $MONITOR_SCRIPT_PATH"
    cp "$0" "$MONITOR_SCRIPT_PATH"
    chmod +x "$MONITOR_SCRIPT_PATH"

    log "Creating systemd service for LLMAPI health monitoring..."
    
    cat > /etc/systemd/system/llmapi-health-monitor.service << EOF
[Unit]
Description=LLMAPI Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $MONITOR_SCRIPT_PATH
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/llmapi-health-monitor.timer << EOF
[Unit]
Description=Run LLMAPI Health Monitor every 5 minutes
Requires=llmapi-health-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable llmapi-health-monitor.timer
    systemctl start llmapi-health-monitor.timer
    
    success "Created and started LLMAPI health monitor timer (runs every 5 minutes)"
}

# Main execution
main() {
    log "Starting LLMAPI health check..."
    
    check_kubectl
    
    # Run all checks
    fix_stuck_pvcs
    fix_pod_issues
    check_storage_health
    check_llmapi_services
    
    # Optionally create monitoring service
    if [[ "${1:-}" == "--install-monitor" ]]; then
        create_monitor_service
    fi
    
    success "LLMAPI health check completed"
    log "Log saved to: $LOG_FILE"
}

# Run main function with all arguments
main "$@"
