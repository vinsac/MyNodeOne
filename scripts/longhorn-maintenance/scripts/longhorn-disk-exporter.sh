#!/bin/bash

###############################################################################
# Longhorn Disk Metrics Exporter for Prometheus
# 
# Exports Longhorn disk utilization metrics in Prometheus format
# Run this via cron or as a systemd service
###############################################################################

set -euo pipefail

# Metrics output file (for node-exporter textfile collector)
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/longhorn_disk_balance.prom"

# Create metrics directory if it doesn't exist
mkdir -p "$METRICS_DIR"

# Temporary file for atomic writes
TEMP_FILE="${METRICS_FILE}.$$"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "# ERROR: kubectl not found" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$METRICS_FILE"
    exit 1
fi

# Check if Longhorn is installed
if ! kubectl get namespace longhorn-system &> /dev/null 2>&1; then
    echo "# ERROR: Longhorn not installed" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$METRICS_FILE"
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "# ERROR: jq not found" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$METRICS_FILE"
    exit 1
fi

# Start metrics file
cat > "$TEMP_FILE" << 'EOF'
# HELP longhorn_disk_capacity_bytes Total capacity of Longhorn disk in bytes
# TYPE longhorn_disk_capacity_bytes gauge
# HELP longhorn_disk_scheduled_bytes Scheduled storage on Longhorn disk in bytes
# TYPE longhorn_disk_scheduled_bytes gauge
# HELP longhorn_disk_reserved_bytes Reserved storage on Longhorn disk in bytes
# TYPE longhorn_disk_reserved_bytes gauge
# HELP longhorn_disk_available_bytes Available storage on Longhorn disk in bytes
# TYPE longhorn_disk_available_bytes gauge
# HELP longhorn_disk_usage_ratio Usage ratio of Longhorn disk (0.0 to 1.0)
# TYPE longhorn_disk_usage_ratio gauge
# HELP longhorn_disk_replica_count Number of replicas on Longhorn disk
# TYPE longhorn_disk_replica_count gauge
# HELP longhorn_disk_schedulable Whether disk is schedulable (1=yes, 0=no)
# TYPE longhorn_disk_schedulable gauge
# HELP longhorn_node_disk_imbalance_ratio Imbalance ratio between disks on a node (0.0 = balanced, 1.0 = max imbalance)
# TYPE longhorn_node_disk_imbalance_ratio gauge
EOF

# Get all Longhorn nodes
NODES=$(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$NODES" ]; then
    echo "# No Longhorn nodes found" >> "$TEMP_FILE"
    mv "$TEMP_FILE" "$METRICS_FILE"
    exit 0
fi

for NODE_NAME in $NODES; do
    # Get node spec (disk configuration)
    NODE_SPEC=$(kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system -o json 2>/dev/null || echo "{}")
    
    if [ "$NODE_SPEC" = "{}" ]; then
        continue
    fi
    
    # Get disk status and spec
    DISK_STATUS=$(echo "$NODE_SPEC" | jq -r '.status.diskStatus // {}')
    DISK_SPEC=$(echo "$NODE_SPEC" | jq -r '.spec.disks // {}')
    
    if [ "$DISK_STATUS" = "{}" ]; then
        continue
    fi
    
    # Track min/max usage for imbalance calculation
    declare -a usage_ratios=()
    
    # Process each disk
    echo "$DISK_STATUS" | jq -r 'to_entries[] | @json' | while read -r disk_json; do
        DISK_ID=$(echo "$disk_json" | jq -r '.key')
        # Get path from spec, not status
        DISK_PATH=$(echo "$DISK_SPEC" | jq -r ".\"$DISK_ID\".path // \"unknown\"")
        STORAGE_MAX=$(echo "$disk_json" | jq -r '.value.storageMaximum')
        STORAGE_SCHEDULED=$(echo "$disk_json" | jq -r '.value.storageScheduled')
        STORAGE_AVAILABLE=$(echo "$disk_json" | jq -r '.value.storageAvailable')
        
        # Get reserved space from spec
        STORAGE_RESERVED=$(echo "$DISK_SPEC" | jq -r ".\"$DISK_ID\".storageReserved // 0")
        
        # Get schedulable status
        SCHEDULABLE=$(echo "$DISK_SPEC" | jq -r ".\"$DISK_ID\".allowScheduling // false")
        SCHEDULABLE_INT=0
        [ "$SCHEDULABLE" = "true" ] && SCHEDULABLE_INT=1
        
        # Calculate usage ratio
        USAGE_RATIO=0
        if [ "$STORAGE_MAX" -gt 0 ]; then
            USAGE_RATIO=$(awk "BEGIN {printf \"%.6f\", ($STORAGE_SCHEDULED / $STORAGE_MAX)}")
        fi
        
        # Count replicas on this disk
        REPLICA_COUNT=$(kubectl get replicas -n longhorn-system -o json 2>/dev/null | \
            jq -r ".items[] | select(.spec.nodeID==\"$NODE_NAME\" and .spec.diskID==\"$DISK_ID\" and .spec.currentState==\"running\") | .metadata.name" | wc -l)
        
        # Sanitize disk path for label (replace / with _)
        DISK_LABEL=$(echo "$DISK_PATH" | sed 's/\//_/g')
        
        # Output metrics
        cat >> "$TEMP_FILE" << EOF
longhorn_disk_capacity_bytes{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $STORAGE_MAX
longhorn_disk_scheduled_bytes{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $STORAGE_SCHEDULED
longhorn_disk_reserved_bytes{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $STORAGE_RESERVED
longhorn_disk_available_bytes{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $STORAGE_AVAILABLE
longhorn_disk_usage_ratio{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $USAGE_RATIO
longhorn_disk_replica_count{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $REPLICA_COUNT
longhorn_disk_schedulable{node="$NODE_NAME",disk="$DISK_ID",path="$DISK_PATH"} $SCHEDULABLE_INT
EOF
        
        usage_ratios+=("$USAGE_RATIO")
    done
    
    # Calculate imbalance ratio for this node
    if [ ${#usage_ratios[@]} -gt 1 ]; then
        # Find min and max usage
        MIN_USAGE=$(printf '%s\n' "${usage_ratios[@]}" | sort -n | head -1)
        MAX_USAGE=$(printf '%s\n' "${usage_ratios[@]}" | sort -n | tail -1)
        
        # Calculate imbalance (difference between max and min)
        IMBALANCE=$(awk "BEGIN {printf \"%.6f\", ($MAX_USAGE - $MIN_USAGE)}")
        
        echo "longhorn_node_disk_imbalance_ratio{node=\"$NODE_NAME\"} $IMBALANCE" >> "$TEMP_FILE"
    fi
done

# Atomically replace metrics file
mv "$TEMP_FILE" "$METRICS_FILE"

exit 0
