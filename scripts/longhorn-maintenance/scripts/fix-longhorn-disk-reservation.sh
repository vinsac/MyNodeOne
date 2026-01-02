#!/bin/bash

###############################################################################
# Fix Longhorn Disk Reservation
# 
# Automatically fixes excessive disk reservation on Longhorn disks
# Reduces default 30% reservation to 5% for large disks (>1TB)
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
echo -e "${BLUE}  Fix Longhorn Disk Reservation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Get all Longhorn nodes
NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}')

if [ -z "$NODES" ]; then
    log_error "No Longhorn nodes found"
    exit 1
fi

FIXED_COUNT=0
SKIPPED_COUNT=0

for NODE_NAME in $NODES; do
    log_info "Checking node: $NODE_NAME"
    
    # Get disk configuration
    DISKS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json | jq -r '.spec.disks // {}')
    
    if [ "$DISKS" = "{}" ]; then
        log_warn "  No disks configured on this node"
        continue
    fi
    
    # Process each disk
    echo "$DISKS" | jq -r 'to_entries[] | @json' | while read -r disk_json; do
        DISK_NAME=$(echo "$disk_json" | jq -r '.key')
        DISK_PATH=$(echo "$disk_json" | jq -r '.value.path')
        STORAGE_RESERVED=$(echo "$disk_json" | jq -r '.value.storageReserved // 0')
        
        # Get disk status to find actual capacity
        DISK_STATUS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json | \
            jq -r ".status.diskStatus.\"$DISK_NAME\" // {}")
        
        if [ "$DISK_STATUS" = "{}" ]; then
            log_warn "  Disk $DISK_NAME: No status available yet (Longhorn initializing)"
            continue
        fi
        
        STORAGE_MAX=$(echo "$DISK_STATUS" | jq -r '.storageMaximum // 0')
        
        if [ "$STORAGE_MAX" -eq 0 ]; then
            log_warn "  Disk $DISK_NAME: Storage maximum is 0, skipping"
            continue
        fi
        
        # Calculate reservation percentage
        RESERVED_PCT=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_RESERVED * 100.0 / $STORAGE_MAX)}")
        RESERVED_GB=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_RESERVED / 1073741824)}")
        TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_MAX / 1073741824)}")
        
        log_info "  Disk: $DISK_NAME"
        log_info "    Path: $DISK_PATH"
        log_info "    Total: ${TOTAL_GB} GB"
        log_info "    Reserved: ${RESERVED_GB} GB (${RESERVED_PCT}%)"
        
        # Determine optimal reservation
        # For disks > 1TB: 5% reservation
        # For disks < 1TB: 10% reservation
        OPTIMAL_RESERVED=0
        
        if awk "BEGIN {exit !($STORAGE_MAX > 1099511627776)}"; then
            # Disk > 1TB: 5% reservation
            OPTIMAL_RESERVED=$(awk "BEGIN {printf \"%.0f\", ($STORAGE_MAX * 0.05)}")
            OPTIMAL_PCT="5"
        else
            # Disk < 1TB: 10% reservation
            OPTIMAL_RESERVED=$(awk "BEGIN {printf \"%.0f\", ($STORAGE_MAX * 0.10)}")
            OPTIMAL_PCT="10"
        fi
        
        OPTIMAL_GB=$(awk "BEGIN {printf \"%.1f\", ($OPTIMAL_RESERVED / 1073741824)}")
        
        # Check if adjustment needed (if current reservation > optimal + 1GB tolerance)
        TOLERANCE=$((1 * 1073741824))  # 1GB
        
        if [ "$STORAGE_RESERVED" -gt $((OPTIMAL_RESERVED + TOLERANCE)) ]; then
            log_warn "    → Excessive reservation detected!"
            log_info "    → Optimal: ${OPTIMAL_GB} GB (${OPTIMAL_PCT}%)"
            log_info "    → Fixing..."
            
            # Update disk reservation
            if kubectl -n longhorn-system patch nodes.longhorn.io "$NODE_NAME" --type=merge \
                -p "{\"spec\":{\"disks\":{\"$DISK_NAME\":{\"storageReserved\":$OPTIMAL_RESERVED}}}}"; then
                
                SAVED_GB=$(awk "BEGIN {printf \"%.1f\", (($STORAGE_RESERVED - $OPTIMAL_RESERVED) / 1073741824)}")
                log_success "    ✓ Fixed! Freed up ${SAVED_GB} GB"
                FIXED_COUNT=$((FIXED_COUNT + 1))
            else
                log_error "    ✗ Failed to update reservation"
            fi
        else
            log_success "    ✓ Reservation is optimal"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        fi
        
        echo
    done
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_success "Summary:"
log_info "  Disks fixed: $FIXED_COUNT"
log_info "  Disks already optimal: $SKIPPED_COUNT"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$FIXED_COUNT" -gt 0 ]; then
    echo
    log_info "Longhorn will now start using the freed space automatically."
    log_info "New volumes will be scheduled across all disks."
fi
