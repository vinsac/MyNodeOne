#!/bin/bash

###############################################################################
# Balance Longhorn Replicas Across Disks
# 
# Checks replica distribution and optionally rebalances them across disks
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
echo -e "${BLUE}  Longhorn Replica Distribution Report${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Get all Longhorn nodes
NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}')

if [ -z "$NODES" ]; then
    log_error "No Longhorn nodes found"
    exit 1
fi

IMBALANCED_NODES=()

for NODE_NAME in $NODES; do
    log_info "Node: $NODE_NAME"
    echo
    
    # Get disk status and spec
    DISK_STATUS=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json | jq -r '.status.diskStatus // {}')
    DISK_SPEC=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json | jq -r '.spec.disks // {}')
    
    if [ "$DISK_STATUS" = "{}" ]; then
        log_warn "  No disk status available"
        continue
    fi
    
    # Count replicas per disk
    declare -A disk_replicas
    declare -A disk_capacity
    declare -A disk_scheduled
    
    # Get disk info
    echo "$DISK_STATUS" | jq -r 'to_entries[] | @json' | while read -r disk_json; do
        DISK_ID=$(echo "$disk_json" | jq -r '.key')
        # Get path from spec, not status
        DISK_PATH=$(echo "$DISK_SPEC" | jq -r ".\"$DISK_ID\".path // \"unknown\"")
        STORAGE_MAX=$(echo "$disk_json" | jq -r '.value.storageMaximum')
        STORAGE_SCHEDULED=$(echo "$disk_json" | jq -r '.value.storageScheduled')
        
        # Count replicas on this disk
        REPLICA_COUNT=$(kubectl get replicas -n longhorn-system -o json | \
            jq -r ".items[] | select(.spec.nodeID==\"$NODE_NAME\" and .spec.diskID==\"$DISK_ID\" and .spec.currentState==\"running\") | .metadata.name" | wc -l)
        
        TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_MAX / 1073741824)}")
        SCHEDULED_GB=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_SCHEDULED / 1073741824)}")
        USAGE_PCT=$(awk "BEGIN {printf \"%.1f\", ($STORAGE_SCHEDULED * 100.0 / $STORAGE_MAX)}")
        
        echo "  Disk: $DISK_PATH"
        echo "    Capacity: ${TOTAL_GB} GB"
        echo "    Scheduled: ${SCHEDULED_GB} GB (${USAGE_PCT}%)"
        echo "    Replicas: $REPLICA_COUNT"
        echo
    done
    
    # Check for imbalance
    DISK_COUNT=$(echo "$DISK_STATUS" | jq -r 'keys | length')
    
    if [ "$DISK_COUNT" -gt 1 ]; then
        # Get min and max replica counts
        REPLICA_COUNTS=$(kubectl get replicas -n longhorn-system -o json | \
            jq -r ".items[] | select(.spec.nodeID==\"$NODE_NAME\" and .spec.currentState==\"running\") | .spec.diskID" | \
            sort | uniq -c | awk '{print $1}')
        
        if [ -n "$REPLICA_COUNTS" ]; then
            MIN_REPLICAS=$(echo "$REPLICA_COUNTS" | sort -n | head -1)
            MAX_REPLICAS=$(echo "$REPLICA_COUNTS" | sort -n | tail -1)
            
            DIFF=$((MAX_REPLICAS - MIN_REPLICAS))
            
            if [ "$DIFF" -gt 5 ]; then
                log_warn "  ⚠️  Imbalance detected: ${DIFF} replica difference between disks"
                IMBALANCED_NODES+=("$NODE_NAME")
            else
                log_success "  ✓ Replica distribution is balanced"
            fi
        fi
    fi
    
    echo
done

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ ${#IMBALANCED_NODES[@]} -gt 0 ]; then
    echo
    log_warn "Imbalanced nodes detected: ${IMBALANCED_NODES[*]}"
    echo
    log_info "Recommendations:"
    log_info "  1. New volumes will automatically use less-utilized disks"
    log_info "  2. To rebalance existing replicas, you can:"
    log_info "     a) Wait for natural rebalancing (when volumes are recreated)"
    log_info "     b) Manually trigger replica rebuild via Longhorn UI"
    log_info "     c) Run: kubectl get volumes -n longhorn-system -o name | xargs -I {} kubectl annotate {} -n longhorn-system longhorn.io/last-applied-tolerations- --overwrite"
    echo
    log_warn "Note: Rebalancing causes I/O load and temporary performance impact"
else
    log_success "All nodes have balanced replica distribution"
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
