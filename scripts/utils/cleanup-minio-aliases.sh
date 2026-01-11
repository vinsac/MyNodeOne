#!/bin/bash
###############################################################################
# Cleanup Generic MinIO Aliases
# 
# Removes old generic minio/minio-api/minio-console entries from service registry
# Run this on control plane after fresh install to clean up stale entries
###############################################################################

set -euo pipefail

echo "Cleaning up generic MinIO aliases from service registry..."

# Get current service registry
SERVICES=$(kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')

if [ "$SERVICES" = "{}" ]; then
    echo "✓ No service registry found (nothing to clean)"
    exit 0
fi

# Check for generic aliases
HAS_GENERIC=$(echo "$SERVICES" | jq 'has("minio") or has("minio-api") or has("minio-console")')

if [ "$HAS_GENERIC" = "false" ]; then
    echo "✓ No generic MinIO aliases found"
    exit 0
fi

echo "Found generic MinIO aliases, removing..."

# Remove generic entries
UPDATED=$(echo "$SERVICES" | jq 'del(.minio, .["minio-api"], .["minio-console"])')

# Update ConfigMap
kubectl create configmap service-registry \
    --from-literal=services.json="$UPDATED" \
    --namespace=kube-system \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✓ Generic MinIO aliases removed"
echo ""
echo "Remaining MinIO services:"
kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' | \
    jq -r 'to_entries[] | select(.key | startswith("minio")) | "  - \(.key) → \(.value.subdomain).\(.value.ip // "pending")"'

echo ""
echo "Run DNS sync to update /etc/hosts:"
echo "  sudo ./scripts/sync-dns.sh"
