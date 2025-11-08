#!/bin/bash

###############################################################################
# Installation Validation Script
# 
# Validates installation success for different node types
# Usage: validate-installation.sh <type>
#   type: control-plane | management-laptop | worker-node | vps-edge
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

print_header() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNED=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    local is_critical="${3:-true}"  # true or false
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo -n "  Testing: $test_name... "
    
    if eval "$test_command" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        if [ "$is_critical" = "true" ]; then
            echo -e "${RED}✗ FAILED${NC}"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            return 1
        else
            echo -e "${YELLOW}⚠ WARNING${NC}"
            TESTS_WARNED=$((TESTS_WARNED + 1))
            return 2
        fi
    fi
}

validate_common() {
    print_header "Common Validation Tests"
    
    # Tailscale
    run_test "Tailscale installed" "command -v tailscale" true
    run_test "Tailscale running" "tailscale status" true
    
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$ts_ip" ]; then
        log_success "Tailscale IP: $ts_ip"
    else
        log_error "Could not get Tailscale IP"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Config file
    run_test "Config file exists" "test -f ~/.mynodeone/config.env || test -f /root/.mynodeone/config.env" true
    
    # Network connectivity
    run_test "Internet connectivity" "ping -c 1 8.8.8.8" false
    
    echo
}

validate_control_plane() {
    print_header "Control Plane Validation"
    
    # Kubernetes
    run_test "kubectl installed" "command -v kubectl" true
    run_test "K3s service running" "systemctl is-active k3s" true
    run_test "Cluster responding" "kubectl cluster-info" true
    run_test "Node is Ready" "kubectl get nodes | grep -w Ready" true
    
    # Core components
    run_test "cert-manager pods running" "kubectl get pods -n cert-manager | grep -q Running" true
    run_test "metallb pods running" "kubectl get pods -n metallb-system | grep -q Running" true
    run_test "traefik pods running" "kubectl get pods -n traefik | grep -q Running" true
    run_test "longhorn pods running" "kubectl get pods -n longhorn-system | grep -q Running" true
    run_test "minio pods running" "kubectl get pods -n minio | grep -q Running" false
    run_test "monitoring pods running" "kubectl get pods -n monitoring | grep -q Running" true
    run_test "argocd pods running" "kubectl get pods -n argocd | grep -q Running" true
    run_test "dashboard pods running" "kubectl get pods -n mynodeone-dashboard | grep -q Running" true
    
    # Service Registry
    run_test "Service registry exists" "kubectl get configmap -n kube-system service-registry" true
    
    local registry_json=$(kubectl get configmap -n kube-system service-registry -o jsonpath='{.data.services\.json}' 2>/dev/null || echo "{}")
    local service_count=$(echo "$registry_json" | jq 'length' 2>/dev/null || echo "0")
    
    if [ "$service_count" -gt 0 ]; then
        log_success "Service registry has $service_count registered services"
        
        # List registered services
        echo
        log_info "Registered services:"
        echo "$registry_json" | jq -r 'to_entries[] | "  • \(.value.subdomain).\(env.CLUSTER_DOMAIN // "minicloud").local → \(.value.ip)"' 2>/dev/null || echo "  (Could not parse services)"
        echo
    else
        log_warn "Service registry is empty or malformed"
        TESTS_WARNED=$((TESTS_WARNED + 1))
    fi
    
    # LoadBalancer IPs assigned
    local lb_count=$(kubectl get svc -A -o json | jq '[.items[] | select(.spec.type=="LoadBalancer") | select(.status.loadBalancer.ingress != null)] | length' 2>/dev/null || echo "0")
    log_info "LoadBalancer services with IPs: $lb_count"
    
    # Storage
    run_test "Longhorn storage class exists" "kubectl get storageclass longhorn" true
    run_test "Default storage class set" "kubectl get storageclass | grep -q '(default)'" true
    
    # Credentials files
    if [ -f /root/mynodeone-join-token.txt ]; then
        log_success "Join token saved (needed for adding nodes)"
    else
        log_warn "Join token file not found"
    fi
    
    echo
}

validate_management_laptop() {
    print_header "Management Laptop Validation"
    
    # kubectl
    run_test "kubectl installed" "command -v kubectl" true
    run_test "kubeconfig exists" "test -f ~/.kube/config" true
    run_test "Cluster connectivity" "kubectl get nodes" true
    
    # Configuration
    if [ -f ~/.mynodeone/config.env ]; then
        source ~/.mynodeone/config.env
        log_success "Config loaded: Cluster '$CLUSTER_NAME' (domain: $CLUSTER_DOMAIN.local)"
    else
        log_error "Config file not found"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # DNS Resolution
    local cluster_domain="${CLUSTER_DOMAIN:-minicloud}"
    
    echo
    log_info "Testing DNS resolution for .local domains..."
    
    local dns_tests=0
    local dns_passed=0
    
    for subdomain in grafana argocd minio longhorn "${cluster_domain}"; do
        dns_tests=$((dns_tests + 1))
        
        # Special case: dashboard is at root domain (e.g., minicloud.local, not minicloud.minicloud.local)
        if [ "$subdomain" = "$cluster_domain" ]; then
            local test_domain="${cluster_domain}.local"
        else
            local test_domain="${subdomain}.${cluster_domain}.local"
        fi
        
        if getent hosts "$test_domain" &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $test_domain"
            dns_passed=$((dns_passed + 1))
        else
            echo -e "  ${RED}✗${NC} $test_domain"
        fi
    done
    
    if [ $dns_passed -eq $dns_tests ]; then
        log_success "All DNS tests passed ($dns_passed/$dns_tests)"
    elif [ $dns_passed -gt 0 ]; then
        log_warn "Partial DNS resolution ($dns_passed/$dns_tests working)"
    else
        log_error "DNS resolution not working"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # HTTP Accessibility
    echo
    log_info "Testing HTTP access to services..."
    
    local http_tests=0
    local http_passed=0
    
    # Test grafana
    local url="http://grafana.${cluster_domain}.local"
    http_tests=$((http_tests + 1))
    if curl -s -f -m 5 "$url" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $url"
        http_passed=$((http_passed + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} $url (may not be ready yet)"
    fi
    
    # Test dashboard (at root domain)
    url="http://${cluster_domain}.local"
    http_tests=$((http_tests + 1))
    if curl -s -f -m 5 "$url" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $url"
        http_passed=$((http_passed + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} $url (may not be ready yet)"
    fi
    
    if [ $http_passed -gt 0 ]; then
        log_success "HTTP access working ($http_passed/$http_tests services reachable)"
    else
        log_warn "Services may still be starting up"
    fi
    
    echo
}

validate_worker_node() {
    print_header "Worker Node Validation"
    
    # Kubernetes
    run_test "kubectl installed" "command -v kubectl" true
    run_test "K3s agent service running" "systemctl is-active k3s-agent" true
    
    # Wait for node registration
    log_info "Checking node registration..."
    local node_name=$(hostname)
    local max_wait=30
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if kubectl get nodes 2>/dev/null | grep -q "$node_name"; then
            log_success "Node '$node_name' is registered in cluster"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    if [ $waited -ge $max_wait ]; then
        log_error "Node not registered after ${max_wait}s"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Node status
    run_test "Node is Ready" "kubectl get nodes $node_name | grep -w Ready" true
    
    # Storage
    run_test "Longhorn components running" "kubectl get pods -n longhorn-system --field-selector spec.nodeName=$node_name | grep -q Running" false
    
    # Cluster connectivity
    run_test "Can reach control plane" "kubectl get nodes -o wide" true
    
    echo
}

validate_vps_edge() {
    print_header "VPS Edge Node Validation"
    
    # Docker and Traefik
    run_test "Docker installed" "command -v docker" true
    run_test "Docker running" "systemctl is-active docker" true
    
    # Check Traefik container
    if docker ps --format '{{.Names}}' | grep -q traefik; then
        log_success "Traefik container running"
        
        # Check Traefik configuration
        if [ -f /etc/traefik/traefik.yml ]; then
            log_success "Traefik configuration found"
        else
            log_warn "Traefik config not found at /etc/traefik/traefik.yml"
        fi
        
        # Check dynamic routes
        if [ -d /etc/traefik/dynamic ]; then
            local route_count=$(find /etc/traefik/dynamic -name "*.yml" | wc -l)
            log_info "Found $route_count route configuration files"
        fi
    else
        log_error "Traefik container not running"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # Domain registry
    run_test "Can reach control plane" "kubectl get nodes" false
    
    if kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        log_success "Domain registry accessible"
        
        local domains=$(kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.domains\.json}' 2>/dev/null || echo "{}")
        local domain_count=$(echo "$domains" | jq 'length' 2>/dev/null || echo "0")
        log_info "Domain registry has $domain_count registered domains"
    else
        log_warn "Domain registry not accessible"
    fi
    
    # Public IP
    local public_ip=$(curl -s -4 ifconfig.me 2>/dev/null || echo "unknown")
    log_info "Public IP: $public_ip"
    
    echo
}

print_summary() {
    print_header "Validation Summary"
    
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    
    if [ $TESTS_WARNED -gt 0 ]; then
        echo -e "Warnings:     ${YELLOW}$TESTS_WARNED${NC}"
    fi
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    fi
    
    echo
    
    if [ $TESTS_FAILED -eq 0 ]; then
        log_success "✅ All critical tests passed!"
        echo
        log_info "Your installation appears to be working correctly."
        
        if [ $TESTS_WARNED -gt 0 ]; then
            echo
            log_warn "Note: $TESTS_WARNED non-critical warnings detected (see above)"
            log_info "These are usually okay and may resolve as services fully start"
        fi
        
        return 0
    else
        log_error "❌ $TESTS_FAILED critical test(s) failed!"
        echo
        log_info "Your installation has issues that need attention."
        log_info "Review the failed tests above and check logs:"
        echo "  • Kubernetes pods: kubectl get pods -A"
        echo "  • K3s logs: journalctl -u k3s -n 100"
        echo "  • System logs: journalctl -xe"
        
        return 1
    fi
}

main() {
    local install_type="${1:-}"
    
    if [ -z "$install_type" ]; then
        echo "Usage: $0 <type>"
        echo "  type: control-plane | management-laptop | worker-node | vps-edge"
        exit 1
    fi
    
    print_header "🔍 MyNodeOne Installation Validation"
    log_info "Validation type: $install_type"
    echo
    
    # Always run common tests
    validate_common
    
    # Run type-specific tests
    case "$install_type" in
        control-plane)
            validate_control_plane
            ;;
        management-laptop)
            validate_management_laptop
            ;;
        worker-node)
            validate_worker_node
            ;;
        vps-edge)
            validate_vps_edge
            ;;
        *)
            log_error "Unknown installation type: $install_type"
            exit 1
            ;;
    esac
    
    # Print summary
    print_summary
    
    # Exit with appropriate code
    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
