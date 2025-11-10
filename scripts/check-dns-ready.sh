#!/bin/bash

###############################################################################
# Check DNS Propagation for SSL Certificate Readiness
#
# This script checks if DNS is properly configured before requesting
# Let's Encrypt certificates, preventing failures and rate limiting.
#
# Usage: ./check-dns-ready.sh <domain> <expected-ip>
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
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <expected-ip>"
    echo ""
    echo "Example:"
    echo "  $0 demo.curiios.com 45.8.133.192"
    exit 1
fi

DOMAIN="$1"
EXPECTED_IP="$2"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 DNS Readiness Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Domain: $DOMAIN"
echo "Expected IP: $EXPECTED_IP"
echo ""

# Check if dig is available
if ! command -v dig &>/dev/null; then
    log_error "dig command not found. Installing dnsutils..."
    sudo apt-get update && sudo apt-get install -y dnsutils
fi

# Query multiple DNS servers for reliability
DNS_SERVERS=(
    "8.8.8.8"         # Google
    "1.1.1.1"         # Cloudflare
    "208.67.222.222"  # OpenDNS
)

all_match=true
results=()

log_info "Querying DNS servers..."
echo ""

for dns in "${DNS_SERVERS[@]}"; do
    result=$(dig +short "@$dns" "$DOMAIN" A 2>/dev/null | head -n1)
    
    if [ -z "$result" ]; then
        log_warn "DNS server $dns: No A record found"
        results+=("$dns:none")
        all_match=false
    elif [ "$result" = "$EXPECTED_IP" ]; then
        log_success "DNS server $dns: $result ✓"
        results+=("$dns:$result")
    else
        log_error "DNS server $dns: $result (expected $EXPECTED_IP)"
        results+=("$dns:$result")
        all_match=false
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if $all_match; then
    log_success "DNS is properly configured!"
    echo ""
    echo "✅ All DNS servers return: $EXPECTED_IP"
    echo ""
    echo "🔒 SSL Certificate Request Status:"
    echo "   Ready to request Let's Encrypt certificate"
    echo "   Expected success rate: >95%"
    echo ""
    exit 0
else
    log_error "DNS is NOT properly configured!"
    echo ""
    echo "❌ DNS Query Results:"
    for res in "${results[@]}"; do
        IFS=':' read -r server ip <<< "$res"
        echo "   $server → ${ip:-none}"
    done
    echo ""
    echo "⚠️  SSL Certificate Request Status:"
    echo "   Certificate request will FAIL"
    echo "   Let's Encrypt cannot verify domain ownership"
    echo ""
    echo "📋 Required Actions:"
    echo ""
    echo "1. Add A record in your DNS provider:"
    echo "   Type: A"
    echo "   Name: $(echo "$DOMAIN" | sed 's/\.[^.]*\.[^.]*$//')"
    echo "   Value: $EXPECTED_IP"
    echo "   TTL: 300 (5 minutes) or lower for testing"
    echo ""
    echo "2. Wait for DNS propagation (typically 5-15 minutes)"
    echo ""
    echo "3. Re-run this check:"
    echo "   $0 $DOMAIN $EXPECTED_IP"
    echo ""
    echo "4. Once DNS is ready, certificates will be obtained automatically"
    echo ""
    echo "🔍 Check propagation status:"
    echo "   https://dnschecker.org/#A/$DOMAIN"
    echo ""
    exit 1
fi
