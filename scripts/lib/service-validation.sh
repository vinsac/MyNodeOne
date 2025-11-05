#!/bin/bash

###############################################################################
# Service Validation Functions
# Comprehensive checks for service health, pods, IPs, and DNS
###############################################################################

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_check() {
    echo -e "${BLUE}[CHECK]${NC} $1" >&2
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1" >&2
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
}

log_warn_check() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Check if pods are running in a namespace
# Usage: verify_pods_running <namespace> <label-selector> <min-replicas>
verify_pods_running() {
    local namespace="$1"
    local label="${2:-}"
    local min_replicas="${3:-1}"
    
    log_check "Checking pods in $namespace${label:+ with label $label}..."
    
    local selector_arg=""
    if [ -n "$label" ]; then
        selector_arg="-l $label"
    fi
    
    # Check if any pods exist
    local pod_count=$(kubectl get pods -n "$namespace" $selector_arg --no-headers 2>/dev/null | wc -l)
    if [ "$pod_count" -eq 0 ]; then
        log_fail "No pods found in $namespace"
        return 1
    fi
    
    # Check if pods are running
    local running_count=$(kubectl get pods -n "$namespace" $selector_arg --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$running_count" -lt "$min_replicas" ]; then
        log_fail "Only $running_count/$min_replicas pods running in $namespace"
        kubectl get pods -n "$namespace" $selector_arg 2>/dev/null | head -10
        return 1
    fi
    
    # Check if any pods are failing
    local failed_count=$(kubectl get pods -n "$namespace" $selector_arg --no-headers 2>/dev/null | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" | wc -l)
    if [ "$failed_count" -gt 0 ]; then
        log_warn_check "$failed_count pod(s) in bad state in $namespace"
        kubectl get pods -n "$namespace" $selector_arg 2>/dev/null | grep -E "Error|CrashLoopBackOff|ImagePullBackOff"
    fi
    
    log_pass "$running_count pod(s) running in $namespace"
    return 0
}

# Check if a service exists and has the expected type
# Usage: verify_service_exists <namespace> <service-name> <expected-type>
verify_service_exists() {
    local namespace="$1"
    local service="$2"
    local expected_type="${3:-}"
    
    log_check "Checking service $namespace/$service..."
    
    if ! kubectl get svc -n "$namespace" "$service" >/dev/null 2>&1; then
        log_fail "Service $namespace/$service does not exist"
        return 1
    fi
    
    if [ -n "$expected_type" ]; then
        local actual_type=$(kubectl get svc -n "$namespace" "$service" -o jsonpath='{.spec.type}' 2>/dev/null)
        if [ "$actual_type" != "$expected_type" ]; then
            log_fail "Service $namespace/$service is type $actual_type, expected $expected_type"
            return 1
        fi
    fi
    
    log_pass "Service $namespace/$service exists"
    return 0
}

# Check if a LoadBalancer service has an external IP
# Usage: verify_loadbalancer_ip <namespace> <service-name>
verify_loadbalancer_ip() {
    local namespace="$1"
    local service="$2"
    
    log_check "Checking LoadBalancer IP for $namespace/$service..."
    
    local ip=$(kubectl get svc -n "$namespace" "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    
    if [ -z "$ip" ]; then
        log_fail "No LoadBalancer IP assigned to $namespace/$service"
        return 1
    fi
    
    log_pass "$namespace/$service has IP: $ip"
    echo "$ip"
    return 0
}

# Check if DNS entry exists in /etc/hosts
# Usage: verify_dns_in_hosts <hostname> <expected-ip>
verify_dns_in_hosts() {
    local hostname="$1"
    local expected_ip="${2:-}"
    
    log_check "Checking /etc/hosts for $hostname..."
    
    if ! grep -q "$hostname" /etc/hosts 2>/dev/null; then
        log_fail "$hostname not found in /etc/hosts"
        return 1
    fi
    
    if [ -n "$expected_ip" ]; then
        if ! grep -F "$hostname" /etc/hosts | grep -Fq "$expected_ip"; then
            local actual_ip=$(grep -F "$hostname" /etc/hosts | awk '{print $1}' | head -1)
            log_fail "$hostname has IP $actual_ip in /etc/hosts, expected $expected_ip"
            return 1
        fi
    fi
    
    log_pass "$hostname found in /etc/hosts"
    return 0
}

# Check if DNS entry exists in dnsmasq config
# Usage: verify_dns_in_dnsmasq <hostname> <expected-ip>
verify_dns_in_dnsmasq() {
    local hostname="$1"
    local expected_ip="${2:-}"
    
    log_check "Checking dnsmasq config for $hostname..."
    
    if [ ! -d /etc/dnsmasq.d ]; then
        log_warn_check "dnsmasq not configured"
        return 0  # Not a failure if dnsmasq isn't used
    fi
    
    if ! grep -r "address=/$hostname/" /etc/dnsmasq.d/ 2>/dev/null | grep -v "^#" >/dev/null; then
        log_fail "$hostname not found in dnsmasq config"
        return 1
    fi
    
    if [ -n "$expected_ip" ]; then
        if ! grep -rF "address=/$hostname/$expected_ip" /etc/dnsmasq.d/ 2>/dev/null | grep -v "^#" >/dev/null; then
            log_fail "$hostname has wrong IP in dnsmasq config"
            return 1
        fi
    fi
    
    log_pass "$hostname found in dnsmasq config"
    return 0
}

# Check if DNS actually resolves
# Usage: verify_dns_resolves <hostname>
verify_dns_resolves() {
    local hostname="$1"
    local expected_ip="${2:-}"
    
    log_check "Checking DNS resolution for $hostname..."
    
    local resolved_ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}')
    
    if [ -z "$resolved_ip" ]; then
        log_fail "$hostname does not resolve"
        return 1
    fi
    
    if [ -n "$expected_ip" ] && [ "$resolved_ip" != "$expected_ip" ]; then
        log_fail "$hostname resolves to $resolved_ip, expected $expected_ip"
        return 1
    fi
    
    log_pass "$hostname resolves to $resolved_ip"
    return 0
}

# Comprehensive check for a service: pods + service + IP + DNS
# Usage: verify_service_complete <namespace> <service-name> <dns-hostname> <cluster-domain>
verify_service_complete() {
    local namespace="$1"
    local service="$2"
    local dns_hostname="$3"
    local cluster_domain="${4:-mycloud}"
    local all_ok=true
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Verifying: $namespace/$service"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 1. Check pods are running
    if ! verify_pods_running "$namespace"; then
        all_ok=false
    fi
    
    # 2. Check service exists
    if ! verify_service_exists "$namespace" "$service" "LoadBalancer"; then
        all_ok=false
    fi
    
    # 3. Check LoadBalancer IP assigned
    local ip=""
    if ip=$(verify_loadbalancer_ip "$namespace" "$service"); then
        # 4. Check DNS entries if we have an IP
        local full_hostname="${dns_hostname}.${cluster_domain}.local"
        
        if ! verify_dns_in_hosts "$full_hostname" "$ip"; then
            all_ok=false
        fi
        
        if ! verify_dns_in_dnsmasq "$full_hostname" "$ip"; then
            all_ok=false
        fi
        
        if ! verify_dns_resolves "$full_hostname" "$ip"; then
            all_ok=false
        fi
    else
        all_ok=false
    fi
    
    echo ""
    if [ "$all_ok" = true ]; then
        log_pass "✅ $namespace/$service is fully operational"
        return 0
    else
        log_fail "❌ $namespace/$service has issues"
        return 1
    fi
}

# Verify all core services
# Usage: verify_all_core_services <cluster-domain>
verify_all_core_services() {
    local cluster_domain="${1:-mycloud}"
    local all_ok=true
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  🔍 COMPREHENSIVE SERVICE VALIDATION"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Check critical services
    local services=(
        "monitoring:kube-prometheus-stack-grafana:grafana"
        "argocd:argocd-server:argocd"
        "minio:minio-console:minio"
        "traefik:traefik:traefik"
        "mynodeone-dashboard:dashboard:dashboard"
    )
    
    for service_spec in "${services[@]}"; do
        IFS=':' read -r namespace service dns_name <<< "$service_spec"
        if ! verify_service_complete "$namespace" "$service" "$dns_name" "$cluster_domain"; then
            all_ok=false
        fi
    done
    
    # Check Longhorn (may be ClusterIP or LoadBalancer)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Verifying: longhorn-system/longhorn-frontend"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if ! verify_pods_running "longhorn-system"; then
        all_ok=false
    fi
    
    local longhorn_type=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.spec.type}' 2>/dev/null)
    if [ "$longhorn_type" = "LoadBalancer" ]; then
        if ! verify_service_complete "longhorn-system" "longhorn-frontend" "longhorn" "$cluster_domain"; then
            all_ok=false
        fi
    else
        log_pass "Longhorn uses $longhorn_type (not LoadBalancer)"
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    if [ "$all_ok" = true ]; then
        log_pass "✅ ALL SERVICES VALIDATED SUCCESSFULLY!"
        echo "═══════════════════════════════════════════════════════════════"
        return 0
    else
        log_fail "❌ SOME SERVICES HAVE ISSUES - SEE ABOVE"
        echo "═══════════════════════════════════════════════════════════════"
        return 1
    fi
}

# Export functions
export -f verify_pods_running
export -f verify_service_exists
export -f verify_loadbalancer_ip
export -f verify_dns_in_hosts
export -f verify_dns_in_dnsmasq
export -f verify_dns_resolves
export -f verify_service_complete
export -f verify_all_core_services
