#!/bin/bash

###############################################################################
# Multi-Node Installation Test Script
#
# Comprehensive end-to-end test that validates a multi-node MyNodeOne cluster
# is fully functional. Tests networking, storage, DNS, and workload scheduling
# across all nodes.
#
# Usage: sudo bash test-multinode.sh
#
# Run this from the control plane after adding worker nodes to verify
# the entire cluster is working correctly before deploying workloads.
#
# Exit codes:
#   0 - All tests passed
#   1 - Critical tests failed
#   2 - Some non-critical tests failed
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

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

CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
CRITICAL_FAIL=0

# Test namespace for ephemeral resources
TEST_NS="multinode-test"
CLEANUP_ITEMS=()

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass()    { echo -e "${GREEN}[PASS]${NC} $1"; TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); }
log_crit()    { echo -e "${RED}[CRIT]${NC} $1"; TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); CRITICAL_FAIL=$((CRITICAL_FAIL+1)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; TOTAL=$((TOTAL+1)); WARNED=$((WARNED+1)); }
log_section() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_info "Cleaning up test resources..."
    kubectl delete namespace "$TEST_NS" --ignore-not-found=true --timeout=30s &>/dev/null || true
    for item in "${CLEANUP_ITEMS[@]}"; do
        eval "$item" &>/dev/null || true
    done
    log_info "Cleanup complete"
}

trap cleanup EXIT

###############################################################################
# Pre-flight Checks
###############################################################################

preflight() {
    log_section "Pre-flight Checks"

    # Must be on control plane
    if ! systemctl is-active k3s &>/dev/null; then
        log_crit "This script must be run on the control plane (k3s not active)"
        exit 1
    fi

    # kubectl must work
    if ! kubectl cluster-info &>/dev/null; then
        log_crit "kubectl cannot reach the cluster"
        exit 1
    fi

    # Must have multiple nodes
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    if [ "$node_count" -lt 2 ]; then
        log_crit "Multi-node test requires at least 2 nodes (found: $node_count)"
        echo "    Add a worker node first: sudo bash scripts/nodes/add-worker-node.sh"
        exit 1
    fi

    log_pass "Control plane accessible"
    log_pass "Cluster has $node_count nodes"

    # All nodes must be Ready
    local ready_count=$(kubectl get nodes --no-headers | grep -c " Ready")
    if [ "$ready_count" -eq "$node_count" ]; then
        log_pass "All $node_count nodes are Ready"
    else
        log_crit "Only $ready_count/$node_count nodes are Ready"
        kubectl get nodes
        exit 1
    fi

    # Create test namespace
    kubectl create namespace "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    log_info "Created test namespace: $TEST_NS"
}

###############################################################################
# Test 1: Node Infrastructure
###############################################################################

test_node_infrastructure() {
    log_section "Test 1: Node Infrastructure"

    local nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

    echo "$nodes" | while IFS=$'\t' read -r name ip; do
        log_info "Checking node: $name ($ip)"

        # Flannel interface
        if [ "$name" = "$(hostname)" ]; then
            # Local check
            if ip link show flannel.1 &>/dev/null; then
                log_pass "  $name: flannel.1 interface exists"
            else
                log_crit "  $name: flannel.1 interface MISSING"
            fi
        else
            # Remote check via SSH
            local ssh_user=""
            for try_user in "${ACTUAL_USER}" root; do
                if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "${try_user}@${ip}" "echo ok" &>/dev/null; then
                    ssh_user="$try_user"
                    break
                fi
            done

            if [ -n "$ssh_user" ]; then
                if ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${ip}" "ip link show flannel.1" &>/dev/null; then
                    log_pass "  $name: flannel.1 interface exists"
                else
                    log_crit "  $name: flannel.1 interface MISSING"
                fi

                # UFW checks
                local ufw_out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${ip}" "sudo ufw status verbose 2>/dev/null" 2>/dev/null || echo "")
                if echo "$ufw_out" | grep -q "allow (routed)"; then
                    log_pass "  $name: UFW routed=allow"
                else
                    log_fail "  $name: UFW routed policy NOT allow"
                fi

                if echo "$ufw_out" | grep -q "8472/udp.*ALLOW"; then
                    log_pass "  $name: UFW allows VXLAN 8472/UDP"
                else
                    log_fail "  $name: UFW does NOT allow VXLAN 8472/UDP"
                fi
            else
                log_warn "  $name: Cannot SSH ($ip) - skipping remote checks"
            fi
        fi
    done
}

###############################################################################
# Test 2: Flannel Overlay Connectivity
###############################################################################

test_flannel_connectivity() {
    log_section "Test 2: Flannel Overlay Connectivity"

    # Get pod subnets for each node from Flannel routes
    local route_count=$(ip route | grep -c "via.*dev flannel.1" || echo "0")
    local expected=$(($(kubectl get nodes --no-headers | wc -l) - 1))

    if [ "$route_count" -ge "$expected" ]; then
        log_pass "Flannel routes present for $route_count remote node(s)"
    else
        log_fail "Missing Flannel routes ($route_count/$expected)"
        ip route | grep flannel || true
    fi
}

###############################################################################
# Test 3: Cross-Node Pod Communication
###############################################################################

test_cross_node_pod_communication() {
    log_section "Test 3: Cross-Node Pod Communication"

    local nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    local node_array=()
    while IFS= read -r n; do
        node_array+=("$n")
    done <<< "$nodes"

    if [ ${#node_array[@]} -lt 2 ]; then
        log_warn "Need at least 2 nodes for cross-node test"
        return
    fi

    local node1="${node_array[0]}"
    local node2="${node_array[1]}"

    log_info "Deploying test pods on $node1 and $node2..."

    # Deploy ping server on node2
    kubectl apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ping-server
  namespace: $TEST_NS
  labels:
    app: ping-server
spec:
  nodeName: $node2
  containers:
  - name: server
    image: busybox:1.35
    command: ["sleep", "300"]
  terminationGracePeriodSeconds: 1
EOF

    # Deploy ping client on node1
    kubectl apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ping-client
  namespace: $TEST_NS
  labels:
    app: ping-client
spec:
  nodeName: $node1
  containers:
  - name: client
    image: busybox:1.35
    command: ["sleep", "300"]
  terminationGracePeriodSeconds: 1
EOF

    # Wait for pods to be ready
    log_info "Waiting for test pods to start..."
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local ready=$(kubectl get pods -n "$TEST_NS" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [ "$ready" -ge 2 ]; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done

    if [ $waited -ge $max_wait ]; then
        log_fail "Test pods did not start within ${max_wait}s"
        kubectl get pods -n "$TEST_NS" 2>/dev/null
        return
    fi

    log_pass "Test pods running on $node1 and $node2"

    # Get server pod IP
    local server_ip=$(kubectl get pod -n "$TEST_NS" ping-server -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ -z "$server_ip" ]; then
        log_fail "Could not get server pod IP"
        return
    fi

    log_info "Server pod IP: $server_ip (on $node2)"

    # Test 3a: Ping from client to server (cross-node)
    local ping_result=$(kubectl exec -n "$TEST_NS" ping-client -- ping -c 3 -W 5 "$server_ip" 2>/dev/null || echo "FAILED")
    if echo "$ping_result" | grep -q "bytes from"; then
        local avg_time=$(echo "$ping_result" | grep "avg" | sed 's/.*= //' | cut -d'/' -f2 || echo "?")
        log_pass "Cross-node pod ping: $node1 -> $node2 (avg ${avg_time}ms)"
    else
        log_crit "Cross-node pod ping FAILED: $node1 -> $node2"
        echo "    This means Flannel VXLAN overlay is broken"
        echo "    Check: UFW routed policy, VXLAN port 8472/UDP, flannel.1 on both nodes"
    fi

    # Test 3b: DNS resolution from pod
    local dns_result=$(kubectl exec -n "$TEST_NS" ping-client -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null || echo "FAILED")
    if echo "$dns_result" | grep -q "Address"; then
        log_pass "Pod DNS resolution: kubernetes.default resolves"
    else
        log_fail "Pod DNS resolution FAILED from $node1"
    fi

    # Test 3c: DNS resolution from pod on other node
    local dns_result2=$(kubectl exec -n "$TEST_NS" ping-server -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null || echo "FAILED")
    if echo "$dns_result2" | grep -q "Address"; then
        log_pass "Pod DNS resolution from $node2: kubernetes.default resolves"
    else
        log_fail "Pod DNS resolution FAILED from $node2"
    fi
}

###############################################################################
# Test 4: Longhorn Storage Across Nodes
###############################################################################

test_longhorn_storage() {
    log_section "Test 4: Longhorn Storage"

    # CSI plugin on all nodes
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local csi_running=$(kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin --no-headers 2>/dev/null | grep -c "Running" || echo "0")

    if [ "$csi_running" -eq "$node_count" ]; then
        log_pass "Longhorn CSI plugin running on all $node_count nodes"
    else
        log_crit "Longhorn CSI plugin NOT running on all nodes ($csi_running/$node_count)"
        kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin 2>/dev/null
    fi

    # CSI all containers ready
    local csi_not_ready=$(kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin --no-headers 2>/dev/null | grep -v "3/3" | wc -l)
    if [ "$csi_not_ready" -eq 0 ]; then
        log_pass "All CSI plugin containers ready (3/3)"
    else
        log_fail "$csi_not_ready CSI plugin pod(s) have unready containers"
    fi

    # Manager on all nodes
    local mgr_running=$(kubectl get pods -n longhorn-system -l app=longhorn-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    if [ "$mgr_running" -eq "$node_count" ]; then
        log_pass "Longhorn manager running on all $node_count nodes"
    else
        log_fail "Longhorn manager NOT running on all nodes ($mgr_running/$node_count)"
    fi

    # Test PVC provisioning on non-control-plane node
    local worker_node=$(kubectl get nodes --no-headers | grep -v "control-plane" | head -1 | awk '{print $1}')
    if [ -z "$worker_node" ]; then
        worker_node=$(kubectl get nodes --no-headers | tail -1 | awk '{print $1}')
    fi

    log_info "Testing PVC provisioning (targeting $worker_node)..."

    kubectl apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: $TEST_NS
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage
  namespace: $TEST_NS
spec:
  nodeName: $worker_node
  containers:
  - name: writer
    image: busybox:1.35
    command: ["sh", "-c", "echo 'multinode-test-ok' > /data/test.txt && cat /data/test.txt && sleep 60"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
  terminationGracePeriodSeconds: 1
EOF

    # Wait for PVC to bind
    log_info "Waiting for PVC to bind..."
    local max_wait=90
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local pvc_status=$(kubectl get pvc -n "$TEST_NS" test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$pvc_status" = "Bound" ]; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done

    if [ "$pvc_status" = "Bound" ]; then
        log_pass "PVC provisioned and bound on $worker_node (${waited}s)"
    else
        log_crit "PVC failed to bind after ${max_wait}s (status: $pvc_status)"
        kubectl describe pvc -n "$TEST_NS" test-pvc 2>/dev/null | tail -5
        return
    fi

    # Wait for pod to run and verify write
    log_info "Waiting for storage test pod..."
    waited=0
    while [ $waited -lt 60 ]; do
        local pod_status=$(kubectl get pod -n "$TEST_NS" test-storage -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$pod_status" = "Running" ] || [ "$pod_status" = "Succeeded" ]; then
            break
        fi
        sleep 3
        waited=$((waited + 3))
    done

    if [ "$pod_status" = "Running" ] || [ "$pod_status" = "Succeeded" ]; then
        local data=$(kubectl exec -n "$TEST_NS" test-storage -- cat /data/test.txt 2>/dev/null || echo "")
        if [ "$data" = "multinode-test-ok" ]; then
            log_pass "PVC read/write verified on $worker_node"
        else
            log_fail "PVC write verification failed (got: '$data')"
        fi
    else
        log_fail "Storage test pod did not reach Running state (status: $pod_status)"
    fi
}

###############################################################################
# Test 5: Service Connectivity Across Nodes
###############################################################################

test_service_connectivity() {
    log_section "Test 5: Service Connectivity Across Nodes"

    local nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    local node_array=()
    while IFS= read -r n; do
        node_array+=("$n")
    done <<< "$nodes"

    local node1="${node_array[0]}"
    local node2="${node_array[1]}"

    # Deploy a simple service on node1, access from node2
    kubectl apply -f - <<EOF &>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: svc-backend
  namespace: $TEST_NS
  labels:
    app: svc-test
spec:
  nodeName: $node1
  containers:
  - name: server
    image: busybox:1.35
    command: ["sh", "-c", "while true; do echo -e 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' | nc -l -p 8080; done"]
    ports:
    - containerPort: 8080
  terminationGracePeriodSeconds: 1
---
apiVersion: v1
kind: Service
metadata:
  name: svc-test
  namespace: $TEST_NS
spec:
  selector:
    app: svc-test
  ports:
  - port: 80
    targetPort: 8080
  type: ClusterIP
EOF

    # Wait for backend pod
    log_info "Waiting for service backend pod..."
    local waited=0
    while [ $waited -lt 30 ]; do
        if kubectl get pod -n "$TEST_NS" svc-backend -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ $waited -ge 30 ]; then
        log_fail "Service backend pod did not start"
        return
    fi

    log_pass "Service backend running on $node1"

    # Get ClusterIP
    local cluster_ip=$(kubectl get svc -n "$TEST_NS" svc-test -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    log_info "Service ClusterIP: $cluster_ip"

    # Test access from node2 via a pod
    local svc_result=$(kubectl run svc-client -n "$TEST_NS" --image=busybox:1.35 --restart=Never --rm -i \
        --overrides="{\"spec\":{\"nodeName\":\"$node2\"}}" --timeout=30s \
        --command -- sh -c "wget -q -O- -T 5 http://$cluster_ip:80" 2>/dev/null || echo "FAILED")

    if echo "$svc_result" | grep -q "ok"; then
        log_pass "Cross-node ClusterIP service access: $node2 -> $node1 service"
    else
        log_fail "Cross-node ClusterIP service access FAILED"
        echo "    Pod on $node2 could not reach ClusterIP $cluster_ip on $node1"
    fi

    # Test access via DNS name
    local dns_svc_result=$(kubectl run svc-dns-client -n "$TEST_NS" --image=busybox:1.35 --restart=Never --rm -i \
        --overrides="{\"spec\":{\"nodeName\":\"$node2\"}}" --timeout=30s \
        --command -- sh -c "wget -q -O- -T 5 http://svc-test.$TEST_NS.svc.cluster.local:80" 2>/dev/null || echo "FAILED")

    if echo "$dns_svc_result" | grep -q "ok"; then
        log_pass "Cross-node service DNS access: svc-test.$TEST_NS.svc.cluster.local"
    else
        log_fail "Cross-node service DNS access FAILED"
    fi
}

###############################################################################
# Test 6: Local DNS Resolution
###############################################################################

test_local_dns() {
    log_section "Test 6: Local DNS Resolution"

    local cluster_domain="${CLUSTER_DOMAIN:-mynodeone}"

    # Test on control plane
    for subdomain in grafana argocd longhorn; do
        local fqdn="${subdomain}.${cluster_domain}.local"
        if getent hosts "$fqdn" &>/dev/null; then
            log_pass "Local DNS: $fqdn resolves"
        else
            log_warn "Local DNS: $fqdn does NOT resolve"
        fi
    done

    # Test HTTP access
    local grafana_url="http://grafana.${cluster_domain}.local"
    if curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$grafana_url" 2>/dev/null | grep -qE "200|302"; then
        log_pass "HTTP access: $grafana_url reachable"
    else
        log_warn "HTTP access: $grafana_url not reachable"
    fi
}

###############################################################################
# Results
###############################################################################

print_results() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Multi-Node Test Results${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Total tests:     $TOTAL"
    echo -e "  ${GREEN}Passed:          $PASSED${NC}"
    echo -e "  ${RED}Failed:          $FAILED${NC}"
    echo -e "  ${YELLOW}Warnings:        $WARNED${NC}"
    echo -e "  ${RED}Critical fails:  $CRITICAL_FAIL${NC}"
    echo

    if [ "$CRITICAL_FAIL" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}MULTI-NODE TEST: CRITICAL FAILURES${NC}"
        echo
        echo "  Critical issues must be resolved before deploying workloads."
        echo "  Run network validation: sudo bash $SCRIPT_DIR/validate-network.sh --fix"
        echo
        return 1
    elif [ "$FAILED" -gt 0 ]; then
        echo -e "  ${YELLOW}${BOLD}MULTI-NODE TEST: PASSED WITH ISSUES${NC}"
        echo
        echo "  Non-critical issues detected. Cluster may work but some features"
        echo "  may be degraded. Review warnings above."
        echo
        return 2
    else
        echo -e "  ${GREEN}${BOLD}MULTI-NODE TEST: ALL PASSED${NC}"
        echo
        echo "  Cluster is fully functional across all nodes."
        echo "  Safe to deploy workloads to any node."
        echo
        return 0
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}MyNodeOne Multi-Node Installation Test${NC}"
    echo -e "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  Host: $(hostname)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    test_node_infrastructure
    test_flannel_connectivity
    test_cross_node_pod_communication
    test_longhorn_storage
    test_service_connectivity
    test_local_dns
    print_results
}

main "$@"
