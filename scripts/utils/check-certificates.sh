#!/bin/bash

###############################################################################
# Check SSL Certificate Status on VPS
#
# This script checks the status of Let's Encrypt certificates managed by
# Traefik, helping diagnose certificate issuance issues.
#
# Usage: ./check-certificates.sh [domain]
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

DOMAIN="${1:-}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔒 SSL Certificate Status Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if acme.json exists
ACME_FILE="/etc/traefik/acme.json"

if [ ! -f "$ACME_FILE" ]; then
    log_error "acme.json not found at $ACME_FILE"
    echo ""
    echo "This file stores Let's Encrypt certificates."
    echo "It should be created during Traefik setup."
    echo ""
    echo "Fix: Ensure Traefik is installed correctly"
    exit 1
fi

log_success "acme.json found"

# Check permissions
PERMS=$(stat -c %a "$ACME_FILE")
if [ "$PERMS" = "600" ]; then
    log_success "Permissions correct: $PERMS"
else
    log_error "Wrong permissions: $PERMS (should be 600)"
    echo ""
    echo "Fix: sudo chmod 600 $ACME_FILE"
    echo ""
fi

# Check file size
SIZE=$(stat -c %s "$ACME_FILE")
if [ "$SIZE" -eq 0 ]; then
    log_warn "acme.json is empty (no certificates yet)"
    HAS_CERTS=false
elif [ "$SIZE" -lt 100 ]; then
    log_warn "acme.json is very small ($SIZE bytes)"
    HAS_CERTS=false
else
    log_info "acme.json size: $SIZE bytes"
    HAS_CERTS=true
fi

echo ""

# Check if jq is available
if ! command -v jq &>/dev/null; then
    log_warn "jq not installed, cannot parse certificate details"
    echo ""
    echo "Install: sudo apt-get install -y jq"
    echo ""
    HAS_JQ=false
else
    HAS_JQ=true
fi

if $HAS_CERTS && $HAS_JQ; then
    log_info "Installed Certificates:"
    echo ""
    
    # Parse certificate data
    CERT_COUNT=$(sudo jq -r '.letsencrypt.Certificates // [] | length' "$ACME_FILE" 2>/dev/null || echo "0")
    
    if [ "$CERT_COUNT" -eq 0 ]; then
        log_warn "No certificates found in acme.json"
        echo ""
    else
        # List all certificates
        sudo jq -r '.letsencrypt.Certificates[] | "  ✓ \(.domain.main) (expires: \(.expires[:10]))"' "$ACME_FILE" 2>/dev/null
        echo ""
        log_success "Total certificates: $CERT_COUNT"
        echo ""
        
        # Check specific domain if provided
        if [ -n "$DOMAIN" ]; then
            log_info "Checking certificate for: $DOMAIN"
            
            CERT_EXISTS=$(sudo jq -r --arg domain "$DOMAIN" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .domain.main' "$ACME_FILE" 2>/dev/null || echo "")
            
            if [ -n "$CERT_EXISTS" ]; then
                log_success "Certificate found for $DOMAIN"
                
                # Get expiration date
                EXPIRES=$(sudo jq -r --arg domain "$DOMAIN" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .expires' "$ACME_FILE" 2>/dev/null)
                echo "  Expires: $EXPIRES"
                
                # Check if near expiration (within 30 days)
                if [ -n "$EXPIRES" ]; then
                    EXPIRE_EPOCH=$(date -d "${EXPIRES:0:10}" +%s 2>/dev/null || echo "0")
                    NOW_EPOCH=$(date +%s)
                    DAYS_LEFT=$(( ($EXPIRE_EPOCH - $NOW_EPOCH) / 86400 ))
                    
                    if [ "$DAYS_LEFT" -lt 30 ]; then
                        log_warn "Certificate expires in $DAYS_LEFT days (renewal needed)"
                    else
                        log_success "Certificate valid for $DAYS_LEFT days"
                    fi
                fi
            else
                log_error "No certificate found for $DOMAIN"
                echo ""
                echo "Certificate may still be pending issuance."
                echo "Check Traefik logs below for details."
            fi
            echo ""
        fi
    fi
fi

# Check Traefik container status
log_info "Traefik Container Status:"
echo ""

if sudo docker ps --format '{{.Names}}\t{{.Status}}' | grep -q traefik; then
    sudo docker ps --format '  ✓ {{.Names}}: {{.Status}}' | grep traefik
    log_success "Traefik is running"
else
    log_error "Traefik container not running"
    echo ""
    echo "Fix: cd /etc/traefik && sudo docker compose up -d"
    exit 1
fi

echo ""

# Check recent Traefik logs for certificate-related events
log_info "Recent Certificate Events (from Traefik logs):"
echo ""

if sudo docker logs traefik --tail 100 2>&1 | grep -i "certificate\|acme\|letsencrypt" | tail -n 10 | grep -q .; then
    sudo docker logs traefik --tail 100 2>&1 | grep -i "certificate\|acme\|letsencrypt\|error" | tail -n 10 | sed 's/^/  /'
else
    echo "  (No recent certificate events)"
fi

echo ""

# Check for common errors
log_info "Checking for Common Issues:"
echo ""

ERROR_COUNT=0

# Check for rate limit errors
if sudo docker logs traefik --tail 200 2>&1 | grep -qi "rate limit\|too many"; then
    log_error "Rate limit detected in logs"
    echo "  Let's Encrypt has rate limits:"
    echo "  • 5 failed attempts per hour"
    echo "  • 50 certificates per week per domain"
    echo "  • Use staging mode for testing"
    ((ERROR_COUNT++))
fi

# Check for DNS validation errors
if sudo docker logs traefik --tail 200 2>&1 | grep -qi "no such host\|dns\|resolution"; then
    log_error "DNS resolution errors detected"
    echo "  Domain may not be resolving correctly"
    echo "  Check: dig yourdomain.com"
    ((ERROR_COUNT++))
fi

# Check for HTTP challenge errors
if sudo docker logs traefik --tail 200 2>&1 | grep -qi "challenge\|404\|connection refused"; then
    log_error "HTTP challenge errors detected"
    echo "  Let's Encrypt cannot reach port 80"
    echo "  Check firewall: sudo ufw status"
    ((ERROR_COUNT++))
fi

if [ $ERROR_COUNT -eq 0 ]; then
    log_success "No common issues detected"
fi

echo ""

# Test actual HTTPS connection if domain provided
if [ -n "$DOMAIN" ]; then
    log_info "Testing HTTPS Connection to $DOMAIN..."
    echo ""
    
    # Try to connect and check certificate
    CERT_INFO=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null || echo "")
    
    if [ -n "$CERT_INFO" ]; then
        if echo "$CERT_INFO" | grep -qi "TRAEFIK DEFAULT CERT"; then
            log_error "Using Traefik default (self-signed) certificate"
            echo ""
            echo "Let's Encrypt certificate not obtained yet."
            echo ""
            echo "Common causes:"
            echo "  1. DNS not propagated (check: dig $DOMAIN)"
            echo "  2. Port 80 blocked (check: sudo ufw status)"
            echo "  3. Rate limit hit (wait 1 hour)"
            echo "  4. Domain validation failed (check Traefik logs)"
        else
            log_success "Valid SSL certificate detected"
            echo "$CERT_INFO" | sed 's/^/  /'
        fi
    else
        log_error "Could not connect to $DOMAIN:443"
        echo "  Ensure domain is accessible and firewall allows HTTPS"
    fi
    echo ""
fi

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Summary:"
echo ""

if $HAS_CERTS && [ "$CERT_COUNT" -gt 0 ]; then
    log_success "Certificate system operational ($CERT_COUNT certificates)"
elif ! $HAS_CERTS; then
    log_warn "No certificates obtained yet"
    echo ""
    echo "Next steps:"
    echo "  1. Ensure DNS is configured: ./check-dns-ready.sh <domain> <ip>"
    echo "  2. Add domain routes: ./sync-vps-routes.sh"
    echo "  3. Wait 5-10 minutes for certificate issuance"
    echo "  4. Check again: $0 <domain>"
else
    log_info "Certificate system ready, waiting for domains"
fi

echo ""
log_info "For detailed troubleshooting:"
echo "  • View full logs: sudo docker logs traefik -f"
echo "  • Check DNS: dig +short yourdomain.com"
echo "  • Test connectivity: curl -I http://yourdomain.com"
echo "  • Manual certificate check: openssl s_client -connect yourdomain.com:443"
echo ""
