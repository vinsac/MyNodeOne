#!/bin/bash

###############################################################################
# Quarterly Longhorn Maintenance
# 
# Automated maintenance script that runs every 3 months to:
# 1. Fix disk reservations
# 2. Check and rebalance replicas if needed
# 3. Log results for review
#
# This script is designed to run unattended via cron
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/mynodeone"
LOG_FILE="$LOG_DIR/longhorn-maintenance-$(date +%Y%m%d-%H%M%S).log"
IMBALANCE_THRESHOLD=0.30  # Trigger rebalance if imbalance > 30%

# Create log directory
mkdir -p "$LOG_DIR"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

# Start maintenance
{
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Quarterly Longhorn Maintenance"
    echo "  Started: $(date)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
} | tee -a "$LOG_FILE"

# Check prerequisites
if [ "$EUID" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found"
    exit 1
fi

if ! kubectl get namespace longhorn-system &> /dev/null 2>&1; then
    log_error "Longhorn is not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found"
    exit 1
fi

# ============================================================================
# STEP 1: Fix Disk Reservations
# ============================================================================

log_info "STEP 1: Checking disk reservations..."
echo | tee -a "$LOG_FILE"

RESERVATION_FIXED=0

# Get all Longhorn nodes
NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODES" ]; then
    log_warn "No Longhorn nodes found"
else
    for NODE_NAME in $NODES; do
        log_info "Checking node: $NODE_NAME" | tee -a "$LOG_FILE"
        
        # Get disk configuration
        DISKS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json 2>/dev/null | jq -r '.spec.disks // {}')
        
        if [ "$DISKS" = "{}" ]; then
            log_warn "  No disks configured on this node" | tee -a "$LOG_FILE"
            continue
        fi
        
        # Process each disk
        echo "$DISKS" | jq -r 'to_entries[] | @json' | while read -r disk_json; do
            DISK_NAME=$(echo "$disk_json" | jq -r '.key')
            DISK_PATH=$(echo "$disk_json" | jq -r '.value.path')
            STORAGE_RESERVED=$(echo "$disk_json" | jq -r '.value.storageReserved // 0')
            
            # Get disk status
            DISK_STATUS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json 2>/dev/null | \
                jq -r ".status.diskStatus.\"$DISK_NAME\" // {}")
            
            if [ "$DISK_STATUS" = "{}" ]; then
                continue
            fi
            
            STORAGE_MAX=$(echo "$DISK_STATUS" | jq -r '.storageMaximum // 0')
            
            if [ "$STORAGE_MAX" -eq 0 ]; then
                continue
            fi
            
            # Calculate optimal reservation
            OPTIMAL_RESERVED=0
            if awk "BEGIN {exit !($STORAGE_MAX > 1099511627776)}"; then
                # Disk > 1TB: 5% reservation
                OPTIMAL_RESERVED=$(awk "BEGIN {printf \"%.0f\", ($STORAGE_MAX * 0.05)}")
            else
                # Disk < 1TB: 10% reservation
                OPTIMAL_RESERVED=$(awk "BEGIN {printf \"%.0f\", ($STORAGE_MAX * 0.10)}")
            fi
            
            # Check if adjustment needed
            TOLERANCE=$((1 * 1073741824))  # 1GB tolerance
            
            if [ "$STORAGE_RESERVED" -gt $((OPTIMAL_RESERVED + TOLERANCE)) ]; then
                RESERVED_GB=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_RESERVED / 1073741824)}")
                OPTIMAL_GB=$(awk "BEGIN {printf \"%.1f\", ($OPTIMAL_RESERVED / 1073741824)}")
                
                log_warn "  Disk $DISK_PATH: Excessive reservation (${RESERVED_GB}GB)" | tee -a "$LOG_FILE"
                log_info "  Reducing to optimal: ${OPTIMAL_GB}GB" | tee -a "$LOG_FILE"
                
                if kubectl -n longhorn-system patch nodes.longhorn.io "$NODE_NAME" --type=merge \
                    -p "{\"spec\":{\"disks\":{\"$DISK_NAME\":{\"storageReserved\":$OPTIMAL_RESERVED}}}}" >> "$LOG_FILE" 2>&1; then
                    
                    SAVED_GB=$(awk "BEGIN {printf \"%.1f\", (($STORAGE_RESERVED - $OPTIMAL_RESERVED) / 1073741824)}")
                    log_success "  Fixed! Freed up ${SAVED_GB}GB" | tee -a "$LOG_FILE"
                    RESERVATION_FIXED=$((RESERVATION_FIXED + 1))
                else
                    log_error "  Failed to update reservation" | tee -a "$LOG_FILE"
                fi
            fi
        done
    done
fi

if [ "$RESERVATION_FIXED" -gt 0 ]; then
    log_success "Fixed $RESERVATION_FIXED disk(s) with excessive reservation" | tee -a "$LOG_FILE"
else
    log_success "All disk reservations are optimal" | tee -a "$LOG_FILE"
fi

echo | tee -a "$LOG_FILE"

# ============================================================================
# STEP 2: Check Replica Balance
# ============================================================================

log_info "STEP 2: Checking replica balance..." | tee -a "$LOG_FILE"
echo | tee -a "$LOG_FILE"

NEEDS_REBALANCE=0
MAX_IMBALANCE=0

for NODE_NAME in $NODES; do
    log_info "Checking node: $NODE_NAME" | tee -a "$LOG_FILE"
    
    # Get disk status and spec
    NODE_JSON=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json 2>/dev/null || echo "{}")
    DISK_STATUS=$(echo "$NODE_JSON" | jq -r '.status.diskStatus // {}')
    DISK_SPEC=$(echo "$NODE_JSON" | jq -r '.spec.disks // {}')
    
    if [ "$DISK_STATUS" = "{}" ]; then
        continue
    fi
    
    # Count disks
    DISK_COUNT=$(echo "$DISK_STATUS" | jq -r 'keys | length')
    
    if [ "$DISK_COUNT" -lt 2 ]; then
        log_info "  Only 1 disk, no rebalancing needed" | tee -a "$LOG_FILE"
        continue
    fi
    
    # Calculate usage ratios
    rm -f /tmp/usage_ratios_$$
    
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
    
    log_info "  Disk imbalance: ${IMBALANCE_PCT}%" | tee -a "$LOG_FILE"
    
    # Track max imbalance
    if awk "BEGIN {exit !($IMBALANCE > $MAX_IMBALANCE)}"; then
        MAX_IMBALANCE=$IMBALANCE
    fi
    
    if awk "BEGIN {exit !($IMBALANCE > $IMBALANCE_THRESHOLD)}"; then
        log_warn "  ⚠️  Imbalance exceeds threshold (${IMBALANCE_THRESHOLD})" | tee -a "$LOG_FILE"
        NEEDS_REBALANCE=1
    else
        log_success "  ✓ Disks are balanced" | tee -a "$LOG_FILE"
    fi
done

echo | tee -a "$LOG_FILE"

# ============================================================================
# STEP 3: Rebalance if Needed
# ============================================================================

if [ "$NEEDS_REBALANCE" -eq 0 ]; then
    log_success "All nodes have balanced disk utilization. No rebalancing needed." | tee -a "$LOG_FILE"
else
    log_warn "Disk imbalance detected (${MAX_IMBALANCE}). Starting automatic rebalancing..." | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    # Trigger replica rebuild
    VOLUMES=$(kubectl get volumes -n longhorn-system -o name 2>/dev/null || echo "")
    
    if [ -z "$VOLUMES" ]; then
        log_error "No volumes found" | tee -a "$LOG_FILE"
    else
        REBALANCED_COUNT=0
        FAILED_COUNT=0
        
        for VOLUME in $VOLUMES; do
            VOLUME_NAME=$(basename "$VOLUME")
            
            if kubectl annotate "$VOLUME" -n longhorn-system longhorn.io/last-applied-tolerations- --overwrite >> "$LOG_FILE" 2>&1; then
                REBALANCED_COUNT=$((REBALANCED_COUNT + 1))
            else
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            
            # Small delay to avoid overwhelming the system
            sleep 2
        done
        
        log_success "Rebalancing initiated for $REBALANCED_COUNT volume(s)" | tee -a "$LOG_FILE"
        if [ "$FAILED_COUNT" -gt 0 ]; then
            log_warn "Failed to rebalance $FAILED_COUNT volume(s)" | tee -a "$LOG_FILE"
        fi
    fi
fi

echo | tee -a "$LOG_FILE"

# ============================================================================
# Summary
# ============================================================================

{
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Maintenance Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disk reservations fixed: $RESERVATION_FIXED"
    echo "  Rebalancing triggered: $([ "$NEEDS_REBALANCE" -eq 1 ] && echo "Yes" || echo "No")"
    echo "  Max disk imbalance: $(awk "BEGIN {printf \"%.1f\", ($MAX_IMBALANCE * 100)}")%"
    echo "  Completed: $(date)"
    echo "  Log file: $LOG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} | tee -a "$LOG_FILE"

# Keep only last 12 maintenance logs (3 years worth)
find "$LOG_DIR" -name "longhorn-maintenance-*.log" -type f | sort -r | tail -n +13 | xargs -r rm

exit 0
