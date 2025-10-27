#!/bin/bash

# MyNodeOne Client DNS Setup
# Run this on laptops/devices to access services via .local domains

set -e

GRAFANA_IP="100.118.5.203"
ARGOCD_IP="100.118.5.204"
MINIO_CONSOLE_IP="100.118.5.202"
MINIO_API_IP="100.118.5.201"
LONGHORN_IP=""

echo "Setting up mynodeone.local domains..."

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    echo "Detected macOS"
    HOSTS_FILE="/etc/hosts"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    # Windows
    echo "Detected Windows"
    HOSTS_FILE="C:\Windows\System32\drivers\etc\hosts"
else
    # Linux
    echo "Detected Linux"
    HOSTS_FILE="/etc/hosts"
fi

# Backup hosts file
sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Remove old mynodeone entries
sudo sed -i.tmp '/# MyNodeOne services/,/# End MyNodeOne services/d' "$HOSTS_FILE"

# Add new entries
echo "" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# MyNodeOne services" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${GRAFANA_IP}        grafana.mynodeone.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${ARGOCD_IP}         argocd.mynodeone.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${MINIO_CONSOLE_IP}  minio.mynodeone.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${MINIO_API_IP}      minio-api.mynodeone.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "${LONGHORN_IP}       longhorn.mynodeone.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# End MyNodeOne services" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "✅ Local DNS configured!"
echo ""
echo "You can now access services at:"
echo "  • Grafana:  http://grafana.mynodeone.local"
echo "  • ArgoCD:   https://argocd.mynodeone.local"
echo "  • MinIO:    http://minio.mynodeone.local:9001"
echo "  • Longhorn: http://longhorn.mynodeone.local"
echo ""
