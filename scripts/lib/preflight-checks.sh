#!/bin/bash

###############################################################################
# MyNodeOne Pre-flight Checks Library
#
# This library provides functions to validate prerequisites before installation.
# Source this file in setup scripts to ensure requirements are met.
#
# Usage:
#   source "$(dirname "$0")/lib/preflight-checks.sh"
#   run_preflight_checks "vps" || exit 1
###############################################################################

# Colors for output
PREFLIGHT_RED='\033[0;31m'
PREFLIGHT_GREEN='\033[0;32m'
PREFLIGHT_YELLOW='\033[1;33m'
PREFLIGHT_BLUE='\033[0;34m'
PREFLIGHT_NC='\033[0m'

preflight_log_info() {
    echo -e "${PREFLIGHT_BLUE}[CHECK]${PREFLIGHT_NC} $1"
}

preflight_log_success() {
    echo -e "${PREFLIGHT_GREEN}[✓]${PREFLIGHT_NC} $1"
}

preflight_log_warn() {
    echo -e "${PREFLIGHT_YELLOW}[⚠]${PREFLIGHT_NC} $1"
}

preflight_log_error() {
    echo -e "${PREFLIGHT_RED}[✗]${PREFLIGHT_NC} $1"
}

# Check if control plane is ready for VPS installation
check_control_plane_for_vps() {
    local cp_ip="$1"
    local cp_user="$2"
    local checks_failed=0
    
    preflight_log_info "Checking control plane: $cp_ip"
    echo ""
    
    # 1. Check SSH connectivity
    preflight_log_info "Testing SSH connection..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$cp_user@$cp_ip" 'echo OK' &>/dev/null; then
        preflight_log_success "SSH connection: OK"
    else
        preflight_log_error "SSH connection: FAILED"
        echo "  Fix: ssh-copy-id $cp_user@$cp_ip"
        checks_failed=1
    fi
    
    # 2. Check passwordless sudo for kubectl
    preflight_log_info "Testing passwordless sudo for kubectl..."
    if ssh -o BatchMode=yes "$cp_user@$cp_ip" 'sudo kubectl version --client' &>/dev/null; then
        preflight_log_success "Passwordless sudo: OK"
    else
        preflight_log_error "Passwordless sudo: NOT CONFIGURED"
        echo "  Fix: Run on control plane: sudo ./scripts/setup-control-plane-sudo.sh"
        checks_failed=1
    fi
    
    # 3. Check Kubernetes is running
    preflight_log_info "Testing Kubernetes cluster..."
    if ssh -o BatchMode=yes "$cp_user@$cp_ip" 'sudo kubectl cluster-info' &>/dev/null; then
        preflight_log_success "Kubernetes cluster: RUNNING"
    else
        preflight_log_error "Kubernetes cluster: NOT RUNNING"
        echo "  Fix: Ensure control plane is installed and running"
        checks_failed=1
    fi
    
    # 4. Check cluster-info ConfigMap exists
    preflight_log_info "Checking cluster-info ConfigMap..."
    if ssh -o BatchMode=yes "$cp_user@$cp_ip" \
        'sudo kubectl get configmap cluster-info -n kube-system' &>/dev/null; then
        preflight_log_success "cluster-info ConfigMap: EXISTS"
    else
        preflight_log_warn "cluster-info ConfigMap: NOT FOUND"
        echo "  This will be created during control plane bootstrap"
    fi
    
    return $checks_failed
}

# Check if VPS is ready for installation
check_vps_ready() {
    local cp_ip="$1"
    local cp_user="$2"
    local checks_failed=0
    
    preflight_log_info "Checking VPS readiness..."
    echo ""
    
    # 1. Check Tailscale is connected
    preflight_log_info "Checking Tailscale connection..."
    local vps_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -n "$vps_ip" ]; then
        preflight_log_success "Tailscale connected: $vps_ip"
    else
        preflight_log_error "Tailscale: NOT CONNECTED"
        echo "  Fix: sudo tailscale up"
        checks_failed=1
    fi
    
    # 2. Check SSH key exists
    preflight_log_info "Checking SSH key..."
    if [ -f "$HOME/.ssh/id_ed25519" ] || [ -f "$HOME/.ssh/id_rsa" ]; then
        preflight_log_success "SSH key: EXISTS"
    else
        preflight_log_warn "SSH key: NOT FOUND"
        echo "  Will be generated during installation"
    fi
    
    # 3. Check Docker is installed
    preflight_log_info "Checking Docker..."
    if command -v docker &>/dev/null; then
        preflight_log_success "Docker: INSTALLED"
        
        # Check Docker is running
        if sudo docker ps &>/dev/null; then
            preflight_log_success "Docker daemon: RUNNING"
        else
            preflight_log_error "Docker daemon: NOT RUNNING"
            echo "  Fix: sudo systemctl start docker"
            checks_failed=1
        fi
    else
        preflight_log_warn "Docker: NOT INSTALLED"
        echo "  Will be installed during VPS setup"
    fi
    
    # 4. Check ports are available
    preflight_log_info "Checking port availability..."
    local ports_in_use=()
    
    for port in 80 443; do
        # Only check for LISTENING ports, not outbound connections
        if sudo lsof -i :$port -sTCP:LISTEN &>/dev/null; then
            ports_in_use+=($port)
        fi
    done
    
    if [ ${#ports_in_use[@]} -eq 0 ]; then
        preflight_log_success "Ports 80, 443: AVAILABLE"
    else
        preflight_log_error "Ports in use: ${ports_in_use[*]}"
        echo "  Traefik requires ports 80 and 443 to be free"
        checks_failed=1
    fi
    
    return $checks_failed
}

# Check if management laptop is ready
check_management_laptop_ready() {
    local cp_ip="$1"
    local cp_user="$2"
    local checks_failed=0
    
    preflight_log_info "Checking management laptop readiness..."
    echo ""
    
    # 1. Check kubectl is installed
    preflight_log_info "Checking kubectl..."
    if command -v kubectl &>/dev/null; then
        preflight_log_success "kubectl: INSTALLED"
    else
        preflight_log_error "kubectl: NOT INSTALLED"
        echo "  Fix: Install kubectl from https://kubernetes.io/docs/tasks/tools/"
        checks_failed=1
    fi
    
    # 2. Check SSH to control plane
    preflight_log_info "Testing SSH to control plane..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$cp_user@$cp_ip" 'echo OK' &>/dev/null; then
        preflight_log_success "SSH connection: OK"
    else
        preflight_log_error "SSH connection: FAILED"
        echo "  Fix: ssh-copy-id $cp_user@$cp_ip"
        checks_failed=1
    fi
    
    # 3. Check Tailscale (optional but recommended)
    preflight_log_info "Checking Tailscale..."
    if command -v tailscale &>/dev/null && tailscale ip -4 &>/dev/null; then
        local laptop_ip=$(tailscale ip -4)
        preflight_log_success "Tailscale connected: $laptop_ip"
    else
        preflight_log_warn "Tailscale: NOT CONNECTED (optional)"
        echo "  Recommended: sudo tailscale up"
    fi
    
    return $checks_failed
}

# Check IP conflict in registries
check_ip_conflict() {
    local vps_ip="$1"
    local cp_user="$2"
    local cp_ip="$3"
    
    preflight_log_info "Checking for IP conflicts..."
    
    # Query domain-registry for this IP
    local existing_vps=$(ssh -o BatchMode=yes "$cp_user@$cp_ip" \
        "sudo kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq -r '.vps_nodes[]? | select(.tailscale_ip == \"$vps_ip\") | .hostname'" 2>/dev/null || echo "")
    
    if [ -n "$existing_vps" ] && [ "$existing_vps" != "$(hostname)" ]; then
        preflight_log_error "IP conflict detected!"
        echo "  IP $vps_ip is already registered to: $existing_vps"
        echo ""
        echo "  This usually means:"
        echo "    1. Previous VPS installation wasn't unregistered"
        echo "    2. Tailscale assigned a recycled IP"
        echo ""
        echo "  Fix: Unregister the old VPS:"
        echo "    ./scripts/unregister-vps.sh $vps_ip"
        echo ""
        return 1
    fi
    
    preflight_log_success "No IP conflicts detected"
    return 0
}

# Main preflight check runner
run_preflight_checks() {
    local check_type="$1"  # "vps", "management", "control-plane"
    local cp_ip="${2:-}"
    local cp_user="${3:-$(whoami)}"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 Pre-flight Checks: $check_type"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    local total_failed=0
    
    case "$check_type" in
        vps)
            if [ -z "$cp_ip" ]; then
                preflight_log_error "Control plane IP required for VPS checks"
                return 1
            fi
            
            # Check control plane is ready
            check_control_plane_for_vps "$cp_ip" "$cp_user" || ((total_failed++))
            
            echo ""
            
            # Check VPS is ready
            check_vps_ready "$cp_ip" "$cp_user" || ((total_failed++))
            
            echo ""
            
            # Check for IP conflicts
            local vps_ip=$(tailscale ip -4 2>/dev/null || echo "")
            if [ -n "$vps_ip" ]; then
                check_ip_conflict "$vps_ip" "$cp_user" "$cp_ip" || ((total_failed++))
            fi
            ;;
            
        management)
            if [ -z "$cp_ip" ]; then
                preflight_log_error "Control plane IP required for management laptop checks"
                return 1
            fi
            
            check_management_laptop_ready "$cp_ip" "$cp_user" || ((total_failed++))
            ;;
            
        control-plane)
            preflight_log_info "Checking control plane prerequisites..."
            # Add control plane specific checks here
            ;;
            
        *)
            preflight_log_error "Unknown check type: $check_type"
            return 1
            ;;
    esac
    
    echo ""
    
    if [ $total_failed -eq 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        preflight_log_success "All pre-flight checks passed!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        return 0
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        preflight_log_error "Pre-flight checks failed: $total_failed issue(s) found"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "❌ Installation cannot proceed until issues are resolved."
        echo ""
        echo "📋 Fix the issues listed above and try again."
        echo ""
        return 1
    fi
}

# Export functions if this is being sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f run_preflight_checks
    export -f check_control_plane_for_vps
    export -f check_vps_ready
    export -f check_management_laptop_ready
    export -f check_ip_conflict
fi
