#!/bin/bash

###############################################################################
# DNS Validation and Health Check Functions
# Proactive validation to ensure DNS is configured correctly
###############################################################################

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_dns_ok() {
    echo -e "${GREEN}[DNS OK]${NC} $1"
}

log_dns_warn() {
    echo -e "${YELLOW}[DNS WARN]${NC} $1"
}

log_dns_error() {
    echo -e "${RED}[DNS ERROR]${NC} $1"
}

# Wait for a LoadBalancer service to get an external IP
# Usage: wait_for_loadbalancer_ip <namespace> <service-name> <max-wait-seconds>
wait_for_loadbalancer_ip() {
    local namespace="$1"
    local service="$2"
    local max_wait="${3:-120}"
    local waited=0
    
    echo -n "Waiting for $namespace/$service LoadBalancer IP"
    
    while [ $waited -lt $max_wait ]; do
        local ip=$(kubectl get svc -n "$namespace" "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        
        if [ -n "$ip" ]; then
            echo ""
            log_dns_ok "$namespace/$service got IP: $ip"
            echo "$ip"
            return 0
        fi
        
        echo -n "."
        sleep 3
        waited=$((waited + 3))
    done
    
    echo ""
    log_dns_error "$namespace/$service didn't get IP after ${max_wait}s"
    return 1
}

# Verify DNS resolution for a hostname
# Usage: verify_dns_resolution <hostname> <expected-ip>
verify_dns_resolution() {
    local hostname="$1"
    local expected_ip="$2"
    
    local resolved_ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}')
    
    if [ -z "$resolved_ip" ]; then
        log_dns_error "$hostname - NOT RESOLVING"
        return 1
    fi
    
    if [ -n "$expected_ip" ] && [ "$resolved_ip" != "$expected_ip" ]; then
        log_dns_error "$hostname - WRONG IP (got $resolved_ip, expected $expected_ip)"
        return 1
    fi
    
    log_dns_ok "$hostname -> $resolved_ip"
    return 0
}

# Check for dangerous wildcard DNS entries
# Usage: check_for_dns_wildcards <domain>
check_for_dns_wildcards() {
    local domain="$1"
    local has_wildcards=false
    
    # Check dnsmasq configs
    if [ -d /etc/dnsmasq.d ]; then
        # Look for patterns like: address=/domain.local/IP (without subdomain)
        if grep -r "^address=/${domain}.local/" /etc/dnsmasq.d/ 2>/dev/null | grep -v "^#" | grep -v "/[a-z-]*\.${domain}\.local/"; then
            log_dns_warn "Found potential wildcard DNS entry in dnsmasq config!"
            log_dns_warn "This can cause undefined subdomains to resolve incorrectly"
            has_wildcards=true
        fi
    fi
    
    if [ "$has_wildcards" = true ]; then
        return 1
    fi
    
    return 0
}

# Test DNS with random hostname to ensure wildcards don't exist
# Usage: test_dns_no_wildcard <domain>
test_dns_no_wildcard() {
    local domain="$1"
    local random_host="test-undefined-$(date +%s).${domain}.local"
    
    if getent hosts "$random_host" >/dev/null 2>&1; then
        log_dns_error "Wildcard DNS detected! Random hostname '$random_host' resolves"
        log_dns_error "This is a security issue - undefined subdomains should NOT resolve"
        return 1
    fi
    
    log_dns_ok "No wildcard DNS detected (random hostnames correctly fail)"
    return 0
}

# Comprehensive DNS health check
# Usage: dns_health_check <cluster-domain>
dns_health_check() {
    local cluster_domain="${1:-mycloud}"
    local all_ok=true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 DNS Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check critical services
    echo "Checking core service DNS resolution..."
    for service in "grafana" "argocd" "minio"; do
        if ! verify_dns_resolution "${service}.${cluster_domain}.local"; then
            all_ok=false
        fi
    done
    echo ""
    
    # Check for wildcards
    echo "Checking for DNS security issues..."
    if ! check_for_dns_wildcards "$cluster_domain"; then
        all_ok=false
    fi
    
    if ! test_dns_no_wildcard "$cluster_domain"; then
        all_ok=false
    fi
    echo ""
    
    # Summary
    if [ "$all_ok" = true ]; then
        log_dns_ok "All DNS checks passed! ✅"
        return 0
    else
        log_dns_warn "Some DNS checks failed - review above"
        return 1
    fi
}

# Export functions for use in other scripts
export -f wait_for_loadbalancer_ip
export -f verify_dns_resolution
export -f check_for_dns_wildcards
export -f test_dns_no_wildcard
export -f dns_health_check
