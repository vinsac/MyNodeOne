#!/bin/bash

###############################################################################
# Network Validation Script
#
# Validates Kubernetes networking across all cluster nodes after node addition.
# Checks: Flannel interfaces, UFW configuration, VXLAN connectivity,
#          pod-to-pod networking, DNS resolution, and Longhorn CSI health.
#
# Usage: sudo bash validate-network.sh [--fix]
#   --fix: Attempt to automatically fix detected issues
#
# Run this after adding a worker node to verify multi-node networking.
###############################################################################

set -euo pipefail

# Get script directory and project root
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

# Load configuration
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
CHECKS_RUN=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
FIXES_APPLIED=0

# Options
AUTO_FIX=false
if [[ "${1:-}" == "--fix" ]]; then
    AUTO_FIX=true
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()    { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_fix()     { echo -e "${CYAN}[FIX]${NC} $1"; }

print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  $1"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

run_check() {
    local name="$1"
    local command="$2"
    local critical="${3:-true}"

    CHECKS_RUN=$((CHECKS_RUN + 1))

    if eval "$command" &>/dev/null; then
        log_success "$name"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        if [ "$critical" = "true" ]; then
            log_fail "$name"
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
            return 1
        else
            log_warn "$name"
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
            return 2
        fi
    fi
}

apply_fix() {
    local description="$1"
    local fix_command="$2"

    if [ "$AUTO_FIX" = true ]; then
        log_fix "Applying fix: $description"
        if eval "$fix_command" &>/dev/null; then
            log_success "Fix applied: $description"
            FIXES_APPLIED=$((FIXES_APPLIED + 1))
            return 0
        else
            log_fail "Fix failed: $description"
            return 1
        fi
    else
        log_warn "Fix available (run with --fix): $description"
        echo "    Command: $fix_command"
        return 1
    fi
}

###############################################################################
# Section 1: Local Node Checks (run on current node)
###############################################################################

check_local_node() {
    print_header "Local Node Checks ($(hostname))"

    # Check if this is control plane or worker
    local is_control_plane=false
    if systemctl is-active k3s &>/dev/null; then
        is_control_plane=true
        log_info "Node type: Control Plane"
    elif systemctl is-active k3s-agent &>/dev/null; then
        log_info "Node type: Worker"
    else
        log_fail "Neither k3s nor k3s-agent is running"
        return 1
    fi

    # 1. Flannel interface
    if ! run_check "Flannel interface (flannel.1) exists" "ip link show flannel.1"; then
        if [ "$is_control_plane" = true ]; then
            apply_fix "Restart K3s to recreate Flannel interface" "systemctl restart k3s"
        else
            apply_fix "Restart K3s agent to recreate Flannel interface" "systemctl restart k3s-agent"
        fi
    fi

    # 2. Flannel interface has IP
    if ip link show flannel.1 &>/dev/null; then
        local flannel_ip=$(ip -4 addr show flannel.1 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
        if [ -n "$flannel_ip" ]; then
            log_success "Flannel interface has IP: $flannel_ip"
            CHECKS_RUN=$((CHECKS_RUN + 1))
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        else
            log_fail "Flannel interface has no IP address"
            CHECKS_RUN=$((CHECKS_RUN + 1))
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi
    fi

    # 3. CNI configuration exists
    run_check "Flannel CNI config exists" \
        "test -f /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist"

    # 4. cni0 bridge exists
    run_check "CNI bridge (cni0) exists" "ip link show cni0" false

    # 5. UFW routed policy
    local ufw_default_line=$(ufw status verbose 2>/dev/null | grep "Default:" || echo "")
    CHECKS_RUN=$((CHECKS_RUN + 1))
    if echo "$ufw_default_line" | grep -q "allow (routed)"; then
        log_success "UFW routed policy: allow"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "UFW routed policy is NOT allow (current: $ufw_default_line)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        apply_fix "Set UFW routed policy to allow" "ufw default allow routed && ufw reload"
    fi

    # 6. VXLAN port 8472/UDP allowed in UFW
    CHECKS_RUN=$((CHECKS_RUN + 1))
    if ufw status 2>/dev/null | grep -q "8472/udp.*ALLOW"; then
        log_success "UFW allows VXLAN port 8472/UDP"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "UFW does NOT allow VXLAN port 8472/UDP"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        apply_fix "Allow VXLAN port 8472/UDP in UFW" "ufw allow 8472/udp comment 'Flannel VXLAN' && ufw reload"
    fi

    # 7. VXLAN listener active
    run_check "VXLAN listener on port 8472/UDP" \
        "ss -ulnp | grep -q ':8472 '"

    # 8. Tailscale connected
    run_check "Tailscale is connected" "tailscale status" false
}

###############################################################################
# Section 2: Cross-Node Connectivity (from control plane)
###############################################################################

check_cross_node_connectivity() {
    print_header "Cross-Node Connectivity"

    # Only run from control plane
    if ! systemctl is-active k3s &>/dev/null; then
        log_info "Skipping cross-node checks (not on control plane)"
        return 0
    fi

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # Get all nodes
    local nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)

    if [ -z "$nodes" ]; then
        log_fail "Could not get node list from cluster"
        CHECKS_RUN=$((CHECKS_RUN + 1))
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi

    local node_count=$(echo "$nodes" | wc -l)
    log_info "Cluster has $node_count node(s)"

    if [ "$node_count" -lt 2 ]; then
        log_info "Single-node cluster - cross-node checks not applicable"
        return 0
    fi

    # Check Flannel routes for each remote node
    echo "$nodes" | while IFS=$'\t' read -r node_name node_ip; do
        if [ "$node_name" = "$(hostname)" ]; then
            continue
        fi

        echo
        log_info "Checking connectivity to $node_name ($node_ip)..."

        # 1. Can ping node IP (Tailscale)
        run_check "  Ping $node_name via Tailscale ($node_ip)" \
            "ping -c 1 -W 3 $node_ip" false

        # 2. Check Flannel route exists for remote pod subnet
        CHECKS_RUN=$((CHECKS_RUN + 1))
        if ip route | grep -q "via.*dev flannel.1"; then
            log_success "  Flannel route to remote pod subnet exists"
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        else
            log_fail "  No Flannel route to remote pod subnet"
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi

        # 3. Check remote node UFW (via SSH)
        CHECKS_RUN=$((CHECKS_RUN + 1))
        local ssh_user=""
        # Try to detect SSH user from known patterns
        for try_user in $(whoami) "${ACTUAL_USER}" root; do
            if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "${try_user}@${node_ip}" "echo ok" &>/dev/null; then
                ssh_user="$try_user"
                break
            fi
        done

        if [ -n "$ssh_user" ]; then
            log_success "  SSH access to $node_name as $ssh_user"
            CHECKS_PASSED=$((CHECKS_PASSED + 1))

            # Check remote Flannel
            CHECKS_RUN=$((CHECKS_RUN + 1))
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${node_ip}" "ip link show flannel.1" &>/dev/null; then
                log_success "  Remote Flannel interface exists on $node_name"
                CHECKS_PASSED=$((CHECKS_PASSED + 1))
            else
                log_fail "  Remote Flannel interface MISSING on $node_name"
                CHECKS_FAILED=$((CHECKS_FAILED + 1))
            fi

            # Check remote UFW routed policy
            CHECKS_RUN=$((CHECKS_RUN + 1))
            local remote_ufw=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${node_ip}" "sudo ufw status verbose 2>/dev/null | grep 'Default:'" 2>/dev/null || echo "")
            if echo "$remote_ufw" | grep -q "allow (routed)"; then
                log_success "  Remote UFW routed=allow on $node_name"
                CHECKS_PASSED=$((CHECKS_PASSED + 1))
            else
                log_fail "  Remote UFW routed policy NOT allow on $node_name"
                CHECKS_FAILED=$((CHECKS_FAILED + 1))
                apply_fix "Set UFW routed=allow on $node_name" \
                    "ssh ${ssh_user}@${node_ip} 'sudo ufw default allow routed && sudo ufw reload'"
            fi

            # Check remote VXLAN port
            CHECKS_RUN=$((CHECKS_RUN + 1))
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_user}@${node_ip}" "sudo ufw status | grep -q '8472/udp.*ALLOW'" &>/dev/null; then
                log_success "  Remote VXLAN port 8472/UDP allowed on $node_name"
                CHECKS_PASSED=$((CHECKS_PASSED + 1))
            else
                log_fail "  Remote VXLAN port 8472/UDP NOT allowed on $node_name"
                CHECKS_FAILED=$((CHECKS_FAILED + 1))
                apply_fix "Allow VXLAN port on $node_name" \
                    "ssh ${ssh_user}@${node_ip} 'sudo ufw allow 8472/udp comment \"Flannel VXLAN\" && sudo ufw reload'"
            fi
        else
            log_warn "  Cannot SSH to $node_name ($node_ip) - skipping remote checks"
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
        fi
    done
}

###############################################################################
# Section 3: Kubernetes Networking (from control plane)
###############################################################################

check_kubernetes_networking() {
    print_header "Kubernetes Pod Networking"

    if ! systemctl is-active k3s &>/dev/null; then
        log_info "Skipping Kubernetes checks (not on control plane)"
        return 0
    fi

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # 1. All nodes Ready
    run_check "All nodes are Ready" \
        "test $(kubectl get nodes --no-headers | grep -c ' Ready') -eq $(kubectl get nodes --no-headers | wc -l)"

    # 2. CoreDNS running
    run_check "CoreDNS pods running" \
        "kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -q Running"

    # 3. CoreDNS ClusterIP reachable
    local coredns_ip=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$coredns_ip" ]; then
        log_info "CoreDNS ClusterIP: $coredns_ip"
    fi

    # 4. Longhorn CSI plugin running on all nodes
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local csi_ready=$(kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin --no-headers 2>/dev/null | grep "Running" | wc -l)
    if [ "$csi_ready" -eq "$node_count" ]; then
        log_success "Longhorn CSI plugin running on all $node_count nodes ($csi_ready/$node_count)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "Longhorn CSI plugin NOT running on all nodes ($csi_ready/$node_count)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # 5. Longhorn CSI plugin containers all ready
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local csi_not_ready=$(kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin --no-headers 2>/dev/null | grep -v "3/3" | wc -l)
    if [ "$csi_not_ready" -eq 0 ]; then
        log_success "All Longhorn CSI plugin containers ready (3/3)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "$csi_not_ready CSI plugin pod(s) have containers not ready"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        kubectl get pods -n longhorn-system -l app=longhorn-csi-plugin --no-headers 2>/dev/null | grep -v "3/3" || true
    fi

    # 6. Longhorn manager running on all nodes
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local mgr_ready=$(kubectl get pods -n longhorn-system -l app=longhorn-manager --no-headers 2>/dev/null | grep "Running" | wc -l)
    if [ "$mgr_ready" -eq "$node_count" ]; then
        log_success "Longhorn manager running on all $node_count nodes"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "Longhorn manager NOT running on all nodes ($mgr_ready/$node_count)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # 7. Pod DNS resolution test
    log_info "Testing pod DNS resolution..."
    CHECKS_RUN=$((CHECKS_RUN + 1))
    local dns_result=$(kubectl run network-test-dns --image=busybox:1.35 --restart=Never --rm -i \
        --timeout=30s --command -- sh -c 'nslookup kubernetes.default.svc.cluster.local' 2>/dev/null || echo "FAILED")
    if echo "$dns_result" | grep -q "Address"; then
        log_success "Pod DNS resolution working (kubernetes.default resolves)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "Pod DNS resolution FAILED"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # 8. Cross-node pod connectivity (only if multi-node)
    if [ "$node_count" -gt 1 ]; then
        log_info "Testing cross-node pod connectivity..."

        # Find a pod on a remote node to ping
        local remote_pod_ip=$(kubectl get pods -n longhorn-system -l app=longhorn-manager \
            -o jsonpath='{range .items[*]}{.status.podIP}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
            | grep -v "$(hostname)" | head -1 | awk '{print $1}')

        if [ -n "$remote_pod_ip" ]; then
            CHECKS_RUN=$((CHECKS_RUN + 1))
            local ping_result=$(kubectl run network-test-ping --image=busybox:1.35 --restart=Never --rm -i \
                --timeout=30s --command -- sh -c "ping -c 3 -W 5 $remote_pod_ip" 2>/dev/null || echo "FAILED")
            if echo "$ping_result" | grep -q "bytes from"; then
                log_success "Cross-node pod ping successful (target: $remote_pod_ip)"
                CHECKS_PASSED=$((CHECKS_PASSED + 1))
            else
                log_fail "Cross-node pod ping FAILED (target: $remote_pod_ip)"
                CHECKS_FAILED=$((CHECKS_FAILED + 1))
                echo "    This indicates Flannel VXLAN overlay is not working between nodes"
                echo "    Check: UFW routed policy, VXLAN port 8472/UDP, flannel.1 interface"
            fi
        else
            log_warn "No remote pod found to test cross-node connectivity"
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
        fi
    fi
}

###############################################################################
# Section 4: Storage Health
###############################################################################

check_storage_health() {
    print_header "Storage Health"

    if ! systemctl is-active k3s &>/dev/null; then
        log_info "Skipping storage checks (not on control plane)"
        return 0
    fi

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

    # 1. Longhorn StorageClass exists
    run_check "Longhorn StorageClass exists" \
        "kubectl get storageclass longhorn"

    # 2. Check PVC status
    local total_pvcs=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)
    local bound_pvcs=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -c "Bound" || echo "0")

    CHECKS_RUN=$((CHECKS_RUN + 1))
    if [ "$total_pvcs" -eq "$bound_pvcs" ] && [ "$total_pvcs" -gt 0 ]; then
        log_success "All PVCs are Bound ($bound_pvcs/$total_pvcs)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    elif [ "$total_pvcs" -eq 0 ]; then
        log_info "No PVCs found in cluster"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        log_fail "Not all PVCs are Bound ($bound_pvcs/$total_pvcs)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        kubectl get pvc -A --no-headers 2>/dev/null | grep -v "Bound" || true
    fi

    # 3. Longhorn volumes healthy
    CHECKS_RUN=$((CHECKS_RUN + 1))
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found; skipping Longhorn volume health check"
        log_warn "Install jq with: sudo apt-get install -y jq"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
    else
        local degraded=$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null \
            | jq '[.items[] | select(.status.robustness != "healthy" and .status.robustness != null)] | length' 2>/dev/null || echo "0")
        if [ "$degraded" -eq 0 ]; then
            log_success "All Longhorn volumes healthy"
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        else
            log_warn "$degraded Longhorn volume(s) not in healthy state"
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
        fi
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  MyNodeOne Network Validation"
    echo -e "  Node: $(hostname)"
    echo -e "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    if [ "$AUTO_FIX" = true ]; then
        echo -e "  Mode: ${YELLOW}AUTO-FIX ENABLED${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    check_local_node
    check_cross_node_connectivity
    check_kubernetes_networking
    check_storage_health

    # Summary
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  Results Summary"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "  Checks run:    $CHECKS_RUN"
    echo -e "  ${GREEN}Passed:        $CHECKS_PASSED${NC}"
    echo -e "  ${RED}Failed:        $CHECKS_FAILED${NC}"
    echo -e "  ${YELLOW}Warnings:      $CHECKS_WARNED${NC}"
    if [ "$AUTO_FIX" = true ]; then
        echo -e "  ${CYAN}Fixes applied: $FIXES_APPLIED${NC}"
    fi
    echo

    if [ "$CHECKS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}  NETWORK VALIDATION PASSED${NC}"
        echo
        return 0
    else
        echo -e "${RED}  NETWORK VALIDATION FAILED ($CHECKS_FAILED issue(s))${NC}"
        if [ "$AUTO_FIX" = false ]; then
            echo
            echo "  Run with --fix to attempt automatic fixes:"
            echo "    sudo bash $0 --fix"
        fi
        echo
        return 1
    fi
}

main "$@"
