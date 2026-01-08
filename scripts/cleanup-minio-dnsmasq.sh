#!/bin/bash
###############################################################################
# Cleanup Generic MinIO dnsmasq Entries
# 
# Removes old generic minio/minio-api entries from dnsmasq configuration
# Run this on control plane after fresh install to clean up stale dnsmasq entries
###############################################################################

set -euo pipefail

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# Load configuration
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo "Cleaning up generic MinIO aliases from dnsmasq..."

# Check if dnsmasq config exists
DNSMASQ_CONF="/etc/dnsmasq.d/${CLUSTER_DOMAIN}.conf"
if [ ! -f "$DNSMASQ_CONF" ]; then
    echo "✓ No dnsmasq config found (nothing to clean)"
    exit 0
fi

# Check for generic MinIO entries
if grep -q "address=/minio\.${CLUSTER_DOMAIN}\.local/" "$DNSMASQ_CONF" || \
   grep -q "address=/minio-api\.${CLUSTER_DOMAIN}\.local/" "$DNSMASQ_CONF"; then
    echo "Found generic MinIO entries in dnsmasq, removing..."
    
    # Remove generic MinIO lines
    sed -i '/address=\/minio\.'"${CLUSTER_DOMAIN}"'\.local\//d' "$DNSMASQ_CONF"
    sed -i '/address=\/minio-api\.'"${CLUSTER_DOMAIN}"'\.local\//d' "$DNSMASQ_CONF"
    
    # Restart dnsmasq
    systemctl restart dnsmasq
    
    echo "✓ Generic MinIO aliases removed from dnsmasq"
else
    echo "✓ No generic MinIO aliases found in dnsmasq"
fi

echo ""
echo "Cleaning up generic MinIO aliases from /etc/hosts..."

# Also remove from /etc/hosts if present
if grep -q "minio\.${CLUSTER_DOMAIN}\.local" /etc/hosts || \
   grep -q "minio-api\.${CLUSTER_DOMAIN}\.local" /etc/hosts; then
    sed -i '/minio\.'"${CLUSTER_DOMAIN}"'\.local/d' /etc/hosts
    sed -i '/minio-api\.'"${CLUSTER_DOMAIN}"'\.local/d' /etc/hosts
    echo "✓ Generic MinIO aliases removed from /etc/hosts"
else
    echo "✓ No generic MinIO aliases found in /etc/hosts"
fi

echo ""
echo "Verifying cleanup..."
if getent hosts minio.${CLUSTER_DOMAIN}.local >/dev/null 2>&1; then
    echo "⚠️  WARNING: minio.${CLUSTER_DOMAIN}.local still resolves!"
    echo "   Check for other DNS sources (systemd-resolved, etc.)"
else
    echo "✓ minio.${CLUSTER_DOMAIN}.local no longer resolves"
fi

echo ""
echo "Node-specific MinIO domains still work:"
kubectl get svc -n minio -o name 2>/dev/null | grep minio | while read svc; do
    svcname=$(echo "$svc" | cut -d/ -f2)
    echo "  - ${svcname}.${CLUSTER_DOMAIN}.local"
done

echo ""
echo "✓ Cleanup complete"
