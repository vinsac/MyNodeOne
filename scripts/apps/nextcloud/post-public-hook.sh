#!/bin/bash

###############################################################################
# Nextcloud - Post-Public Configuration Hook
# 
# This script is called by manage-app-visibility.sh after making Nextcloud public
# It handles Nextcloud-specific configuration like trusted_domains
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
echo -e "${GREEN}[Nextcloud]${NC} Configuring trusted domains..."

# Add each domain to trusted_domains
IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
for domain in "${DOMAIN_ARRAY[@]}"; do
    FQDN=$(echo "$domain" | xargs)
    
    # Check if already exists
    if kubectl exec -n nextcloud deployment/nextcloud -- \
        su -s /bin/bash www-data -c \
        "php occ config:system:get trusted_domains" 2>/dev/null | grep -q "^${FQDN}$"; then
        echo "  ✓ $FQDN already in trusted domains"
    else
        # Find next available index
        local index=2
        while kubectl exec -n nextcloud deployment/nextcloud -- \
            su -s /bin/bash www-data -c \
            "php occ config:system:get trusted_domains $index" 2>/dev/null | grep -v "not set" &>/dev/null; do
            ((index++))
        done

        if kubectl exec -n nextcloud deployment/nextcloud -- \
            su -s /bin/bash www-data -c \
            "php occ config:system:set trusted_domains $index --value='$FQDN'" &>/dev/null; then
            echo "  ✓ Added $FQDN to trusted domains at index $index"
        else
            echo -e "  ${YELLOW}⚠ Could not add $FQDN (may need manual configuration)${NC}"
        fi
    fi
done

echo -e "${GREEN}[Nextcloud]${NC} Trusted domains configured"
echo ""
