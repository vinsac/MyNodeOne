#!/bin/bash

###############################################################################
# Paperless-ngx - Post-Public Configuration Hook
# 
# This script is called by manage-app-visibility.sh after making Paperless public
# It handles Paperless-specific configuration for ALLOWED_HOSTS and CSRF_TRUSTED_ORIGINS
#
# Usage: post-public-hook.sh <service_name> <full_domains_csv>
###############################################################################

set -euo pipefail

SERVICE_NAME="${1:-}"
DOMAINS="${2:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$SERVICE_NAME" ] || [ -z "$DOMAINS" ]; then
    echo "Usage: $0 <service_name> <full_domains_csv>"
    exit 1
fi

echo ""
echo -e "${GREEN}[Paperless]${NC} Configuring allowed hosts and CSRF trusted origins..."

# Get cluster domain and service info
ACTUAL_HOME="${HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
if [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    source "$ACTUAL_HOME/.mynodeone/config.env"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Get local_name from registry
LOCAL_NAME=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath="{.data.services\.json}" 2>/dev/null | \
    jq -r ".[\"$SERVICE_NAME\"].local_name")

# Build allowed hosts list (start with local access)
ALLOWED_HOSTS="$LOCAL_NAME.${CLUSTER_DOMAIN}.local"
CSRF_ORIGINS="http://$LOCAL_NAME.${CLUSTER_DOMAIN}.local"

# Add each public domain
IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
for domain in "${DOMAIN_ARRAY[@]}"; do
    FQDN=$(echo "$domain" | xargs)
    
    # Add to allowed hosts
    ALLOWED_HOSTS="${ALLOWED_HOSTS},${FQDN}"
    
    # Add to CSRF trusted origins (HTTPS for public domains)
    CSRF_ORIGINS="${CSRF_ORIGINS},https://${FQDN}"
    
    echo "  ✓ Added $FQDN to allowed hosts"
done

# Update Paperless deployment environment variables
NAMESPACE=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath="{.data.services\.json}" 2>/dev/null | \
    jq -r ".[\"$SERVICE_NAME\"].namespace")

if [ -z "$NAMESPACE" ] || [ "$NAMESPACE" = "null" ]; then
    echo -e "  ${YELLOW}⚠ Could not determine namespace${NC}"
    exit 1
fi

# Update PAPERLESS_ALLOWED_HOSTS
if kubectl set env deployment/paperless -n "$NAMESPACE" \
    "PAPERLESS_ALLOWED_HOSTS=${ALLOWED_HOSTS}" &>/dev/null; then
    echo "  ✓ Updated PAPERLESS_ALLOWED_HOSTS"
else
    echo -e "  ${YELLOW}⚠ Could not update PAPERLESS_ALLOWED_HOSTS${NC}"
fi

# Update PAPERLESS_CSRF_TRUSTED_ORIGINS
if kubectl set env deployment/paperless -n "$NAMESPACE" \
    "PAPERLESS_CSRF_TRUSTED_ORIGINS=${CSRF_ORIGINS}" &>/dev/null; then
    echo "  ✓ Updated PAPERLESS_CSRF_TRUSTED_ORIGINS"
else
    echo -e "  ${YELLOW}⚠ Could not update PAPERLESS_CSRF_TRUSTED_ORIGINS${NC}"
fi

echo -e "${GREEN}[Paperless]${NC} Configuration updated"
echo ""
echo "  Allowed hosts: ${ALLOWED_HOSTS}"
echo "  CSRF origins: ${CSRF_ORIGINS}"
echo ""
