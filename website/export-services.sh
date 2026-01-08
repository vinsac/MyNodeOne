#!/bin/bash
###############################################################################
# Service Registry Exporter
# 
# Runs as sidecar in dashboard pod to export service registry to JSON
# Dashboard JavaScript can then fetch /api/services.json for real-time updates
###############################################################################

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/usr/share/nginx/html/api}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-30}"

echo "[$(date)] Service Registry Exporter starting..."
echo "[$(date)] Output: $OUTPUT_DIR/services.json"
echo "[$(date)] Refresh interval: ${REFRESH_INTERVAL}s"

# Create API directory
mkdir -p "$OUTPUT_DIR"

# Export function
export_services() {
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    if [ "$services" != "{}" ]; then
        # Transform to array format for easier JavaScript consumption
        local services_array=$(echo "$services" | jq -c '[
            to_entries[] | 
            {
                name: .key,
                subdomain: .value.subdomain,
                namespace: .value.namespace,
                service: .value.service,
                ip: .value.ip,
                port: .value.port,
                public: (.value.public // false)
            }
        ]')
        
        # Write to temp file then move (atomic)
        echo "$services_array" > "$OUTPUT_DIR/services.json.tmp"
        mv "$OUTPUT_DIR/services.json.tmp" "$OUTPUT_DIR/services.json"
        
        local count=$(echo "$services_array" | jq 'length')
        echo "[$(date)] Exported $count services"
    else
        echo "[$(date)] No services found in registry"
        echo '[]' > "$OUTPUT_DIR/services.json"
    fi
}

# Initial export
export_services

# Watch loop
while true; do
    sleep "$REFRESH_INTERVAL"
    export_services
done
