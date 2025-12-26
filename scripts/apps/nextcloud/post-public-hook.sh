#!/bin/bash

###############################################################################
# Nextcloud - Post-Public Configuration Hook
# 
# This script is called by manage-app-visibility.sh after making Nextcloud public
# It handles Nextcloud-specific configuration like trusted_domains
#
# Usage: post-public-hook.sh <service_name> <subdomain> <domains_csv>
###############################################################################

set -euo pipefail

SERVICE_NAME="${1:-}"
SUBDOMAIN="${2:-}"
DOMAINS="${3:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -z "$SERVICE_NAME" ] || [ -z "$SUBDOMAIN" ] || [ -z "$DOMAINS" ]; then
    echo "Usage: $0 <service_name> <subdomain> <domains_csv>"
    exit 1
fi

echo ""
echo -e "${GREEN}[Nextcloud]${NC} Configuring trusted domains..."

# Get current trusted domains count
CURRENT_COUNT=$(kubectl exec -n nextcloud deployment/nextcloud -- \
    su -s /bin/bash www-data -c \
    "php occ config:system:get trusted_domains" 2>/dev/null | wc -l || echo "2")

# Start adding from index 2 (0=localhost, 1=local domain)
DOMAIN_INDEX=2

# Add each domain to trusted_domains
IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
for domain in "${DOMAIN_ARRAY[@]}"; do
    domain=$(echo "$domain" | xargs)
    FQDN="${SUBDOMAIN}.${domain}"
    
    # Check if already exists
    if kubectl exec -n nextcloud deployment/nextcloud -- \
        su -s /bin/bash www-data -c \
        "php occ config:system:get trusted_domains" 2>/dev/null | grep -q "^${FQDN}$"; then
        echo "  ✓ $FQDN already in trusted domains"
    else
        if kubectl exec -n nextcloud deployment/nextcloud -- \
            su -s /bin/bash www-data -c \
            "php occ config:system:set trusted_domains $DOMAIN_INDEX --value='$FQDN'" &>/dev/null; then
            echo "  ✓ Added $FQDN to trusted domains"
            ((DOMAIN_INDEX++))
        else
            echo -e "  ${YELLOW}⚠ Could not add $FQDN (may need manual configuration)${NC}"
        fi
    fi
done

echo -e "${GREEN}[Nextcloud]${NC} Trusted domains configured"
echo ""
