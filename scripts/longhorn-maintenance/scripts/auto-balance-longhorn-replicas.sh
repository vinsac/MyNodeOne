#!/bin/bash

###############################################################################
# Auto-Balance Longhorn Replicas (Optional - Use with Caution)
# 
# This script automatically rebalances replicas across disks when imbalance
# is detected. It triggers replica rebuilds which causes I/O load.
# 
# RECOMMENDED: Only run during maintenance windows or off-peak hours
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Configuration
IMBALANCE_THRESHOLD=0.25  # Trigger rebalance if imbalance > 25%
DRY_RUN=${DRY_RUN:-1}     # Default to dry-run mode (set DRY_RUN=0 to actually rebalance)

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Is Kubernetes installed?"
    exit 1
fi

# Check if Longhorn is installed
if ! kubectl get namespace longhorn-system &> /dev/null; then
    log_error "Longhorn is not installed"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    log_error "jq not found. Installing..."
    apt-get update && apt-get install -y jq
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Longhorn Automatic Replica Rebalancing${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    log_warn "Running in DRY-RUN mode (no changes will be made)"
    log_info "To actually rebalance, run: DRY_RUN=0 sudo $0"
    echo
fi

# Get all Longhorn nodes
NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}')

if [ -z "$NODES" ]; then
    log_error "No Longhorn nodes found"
    exit 1
fi

REBALANCE_NEEDED=0

for NODE_NAME in $NODES; do
    log_info "Checking node: $NODE_NAME"
    
    # Get disk status
    DISK_STATUS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json | jq -r '.status.diskStatus // {}')
    
    if [ "$DISK_STATUS" = "{}" ]; then
        log_warn "  No disk status available"
        continue
    fi
    
    # Count disks
    DISK_COUNT=$(echo "$DISK_STATUS" | jq -r 'keys | length')
    
    if [ "$DISK_COUNT" -lt 2 ]; then
        log_info "  Only 1 disk, no rebalancing needed"
        continue
    fi
    
    # Calculate usage ratios
    declare -a usage_ratios=()
    
    echo "$DISK_STATUS" | jq -r 'to_entries[] | @json' | while read -r disk_json; do
        DISK_ID=$(echo "$disk_json" | jq -r '.key')
        STORAGE_MAX=$(echo "$disk_json" | jq -r '.value.storageMaximum')
        STORAGE_SCHEDULED=$(echo "$disk_json" | jq -r '.value.storageScheduled')
        
        if [ "$STORAGE_MAX" -gt 0 ]; then
            USAGE_RATIO=$(awk "BEGIN {printf \"%.6f\", ($STORAGE_SCHEDULED / $STORAGE_MAX)}")
            echo "$USAGE_RATIO" >> /tmp/usage_ratios_$$
        fi
    done
    
    if [ ! -f /tmp/usage_ratios_$$ ]; then
        continue
    fi
    
    # Find min and max usage
    MIN_USAGE=$(sort -n /tmp/usage_ratios_$$ | head -1)
    MAX_USAGE=$(sort -n /tmp/usage_ratios_$$ | tail -1)
    rm -f /tmp/usage_ratios_$$
    
    # Calculate imbalance
    IMBALANCE=$(awk "BEGIN {printf \"%.6f\", ($MAX_USAGE - $MIN_USAGE)}")
    IMBALANCE_PCT=$(awk "BEGIN {printf \"%.1f\", ($IMBALANCE * 100)}")
    
    log_info "  Disk imbalance: ${IMBALANCE_PCT}%"
    
    if awk "BEGIN {exit !($IMBALANCE > $IMBALANCE_THRESHOLD)}"; then
        log_warn "  ⚠️  Imbalance exceeds threshold (${IMBALANCE_THRESHOLD})"
        REBALANCE_NEEDED=1
    else
        log_success "  ✓ Disks are balanced"
    fi
done

echo

if [ "$REBALANCE_NEEDED" -eq 0 ]; then
    log_success "All nodes have balanced disk utilization. No action needed."
    exit 0
fi

log_warn "Imbalance detected. Rebalancing is recommended."
echo

if [ "$DRY_RUN" -eq 1 ]; then
    log_info "DRY-RUN: Would trigger replica rebuild for imbalanced volumes"
    log_info "To actually rebalance, run: DRY_RUN=0 sudo $0"
    echo
    log_warn "⚠️  WARNING: Rebalancing causes I/O load and temporary performance impact"
    log_warn "⚠️  Recommended to run during maintenance windows or off-peak hours"
    exit 0
fi

# Actual rebalancing (only if DRY_RUN=0)
log_warn "Starting replica rebalancing..."
log_warn "This will cause I/O load. Press Ctrl+C within 10 seconds to cancel."
sleep 10

# Trigger replica rebuild by removing and re-adding the last-applied-tolerations annotation
# This forces Longhorn to re-evaluate replica placement
VOLUMES=$(kubectl get volumes -n longhorn-system -o name)

if [ -z "$VOLUMES" ]; then
    log_error "No volumes found"
    exit 1
fi

REBALANCED_COUNT=0
FAILED_COUNT=0

for VOLUME in $VOLUMES; do
    VOLUME_NAME=$(basename "$VOLUME")
    log_info "Rebalancing: $VOLUME_NAME"
    
    if kubectl annotate "$VOLUME" -n longhorn-system longhorn.io/last-applied-tolerations- --overwrite 2>&1; then
        REBALANCED_COUNT=$((REBALANCED_COUNT + 1))
        log_success "  ✓ Triggered rebalance"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_error "  ✗ Failed to trigger rebalance"
    fi
    
    # Small delay to avoid overwhelming the system
    sleep 2
done

echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_success "Rebalancing initiated!"
log_info "  Volumes processed: $REBALANCED_COUNT"
log_info "  Failed: $FAILED_COUNT"
echo
log_info "Longhorn will now rebuild replicas on balanced disks."
log_info "This process may take several minutes to hours depending on data size."
log_info "Monitor progress in Longhorn UI: http://longhorn.minicloud.local"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
