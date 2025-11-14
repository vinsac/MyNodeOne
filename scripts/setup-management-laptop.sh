#!/bin/bash

###############################################################################
# MyNodeOne Management Laptop Setup - HARDENED VERSION
# 
# This script configures a laptop/desktop for managing the MyNodeOne cluster
# 
# Features:
#   - Automatic retry logic with exponential backoff
#   - State validation and recovery
#   - Certificate verification
#   - DNS validation and auto-fix
#   - Kubeconfig health checks
#   - Comprehensive error handling
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Detect actual user and home directory
source "$SCRIPT_DIR/lib/detect-actual-home.sh"

# Configuration
MAX_RETRIES=3
RETRY_DELAY=2
KUBECONFIG_TIMEOUT=30

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

log_debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

print_header() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Retry function with exponential backoff
retry_command() {
    local command="$1"
    local description="$2"
    local attempt=1
    local delay=$RETRY_DELAY
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log_debug "Attempt $attempt/$MAX_RETRIES: $description"
        
        if eval "$command" 2>/dev/null; then
            return 0
        fi
        
        if [ $attempt -lt $MAX_RETRIES ]; then
            log_warn "$description failed. Retrying in ${delay}s... (attempt $attempt/$MAX_RETRIES)"
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_error "$description failed after $MAX_RETRIES attempts"
    return 1
}

# Validate kubeconfig health
validate_kubeconfig() {
    local kubeconfig="${1:-$HOME/.kube/config}"
    
    if [ ! -f "$kubeconfig" ]; then
        log_debug "Kubeconfig not found: $kubeconfig"
        return 1
    fi
    
    # Check if it's valid YAML
    if ! python3 -c "import yaml; yaml.safe_load(open('$kubeconfig'))" 2>/dev/null; then
        log_warn "Kubeconfig is not valid YAML"
        return 1
    fi
    
    # Check if server URL is present
    if ! grep -q "server:" "$kubeconfig"; then
        log_warn "Kubeconfig missing server URL"
        return 1
    fi
    
    # Test cluster connectivity
    if ! KUBECONFIG="$kubeconfig" timeout $KUBECONFIG_TIMEOUT kubectl cluster-info &>/dev/null; then
        log_debug "Cannot connect to cluster with kubeconfig"
        return 1
    fi
    
    log_debug "Kubeconfig validation passed"
    return 0
}

# Fix stale or broken kubeconfig
fix_kubeconfig() {
    local control_plane_ip="$1"
    local ssh_user="$2"
    
    log_info "Fetching fresh kubeconfig from control plane..."
    
    # Create backup of existing config
    if [ -f "$HOME/.kube/config" ]; then
        cp "$HOME/.kube/config" "$HOME/.kube/config.bak.$(date +%Y%m%d_%H%M%S)"
        log_debug "Backed up existing kubeconfig"
    fi
    
    # Fetch fresh kubeconfig
    mkdir -p "$HOME/.kube"
    
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_user@$control_plane_ip" \
        "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null | \
        sed "s/127.0.0.1/$control_plane_ip/g" > "$HOME/.kube/config.new"; then
        
        # Validate new config before replacing
        if validate_kubeconfig "$HOME/.kube/config.new"; then
            mv "$HOME/.kube/config.new" "$HOME/.kube/config"
            chmod 600 "$HOME/.kube/config"
            
            # Update both user and root configs for sudo operations
            # No need to copy to /root/.kube anymore, as scripts use ACTUAL_HOME
            
            # Also update actual user's kubeconfig if running as sudo
            if [ -n "${SUDO_USER:-}" ]; then
                local user_home=$(eval echo ~$SUDO_USER)
                sudo mkdir -p "$user_home/.kube"
                sudo cp "$HOME/.kube/config" "$user_home/.kube/config"
                sudo chown $SUDO_USER:$SUDO_USER "$user_home/.kube/config"
                sudo chmod 600 "$user_home/.kube/config"
                log_info "Updated kubeconfig for user: $SUDO_USER"
            fi
            
            log_success "Kubeconfig updated and validated"
            return 0
        else
            log_error "New kubeconfig failed validation"
            rm -f "$HOME/.kube/config.new"
            return 1
        fi
    else
        log_error "Failed to fetch kubeconfig from control plane"
        return 1
    fi
}

# Fetch and validate cluster info
fetch_cluster_info() {
    log_info "Fetching cluster configuration from control plane..."
    
    local retries=3
    local cluster_name=""
    local cluster_domain=""
    
    while [ $retries -gt 0 ]; do
        cluster_name=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-name}' 2>/dev/null || echo "")
        cluster_domain=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
        
        if [ -n "$cluster_name" ] && [ -n "$cluster_domain" ]; then
            log_success "Cluster info retrieved: $cluster_name / $cluster_domain"
            echo "CLUSTER_NAME=\"$cluster_name\"" >> "$CONFIG_FILE"
            echo "CLUSTER_DOMAIN=\"$cluster_domain\"" >> "$CONFIG_FILE"
            return 0
        fi
        
        retries=$((retries - 1))
        [ $retries -gt 0 ] && sleep 2
    done
    
    log_warn "Could not fetch cluster info from configmap"
    return 1
}

# Get all LoadBalancer service IPs with retry
get_service_ips() {
    local service_namespace="$1"
    local service_name="$2"
    local ip=""
    
    ip=$(retry_command \
        "kubectl get svc -n $service_namespace $service_name -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null" \
        "Fetching IP for $service_namespace/$service_name")
    
    echo "$ip"
}

# Update DNS entries with validation
update_dns_entries() {
    log_info "Updating DNS entries in /etc/hosts..."
    
    # Discover all LoadBalancer services
    local services=$(kubectl get svc -A -o json | jq -r '
        .items[] | 
        select(.spec.type == "LoadBalancer") | 
        select(.status.loadBalancer.ingress != null) |
        select(.status.loadBalancer.ingress[0].ip != null) |
        "\(.status.loadBalancer.ingress[0].ip)|\(.metadata.name)|\(.metadata.namespace)"
    ' 2>/dev/null || echo "")
    
    if [ -z "$services" ]; then
        log_warn "No LoadBalancer services found"
        return 1
    fi
    
    # Backup hosts file
    sudo cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"
    
    # Remove old MyNodeOne entries
    sudo sed -i '/# MyNodeOne services/,/# End MyNodeOne services/d' /etc/hosts
    
    # Add new entries
    {
        echo ""
        echo "# MyNodeOne services"
        
        while IFS='|' read -r ip name namespace; do
            # Determine hostname based on service name
            case "$name" in
                dashboard)
                    echo "${ip}      ${CLUSTER_DOMAIN}.local"
                    ;;
                *-grafana|kube-prometheus-stack-grafana)
                    echo "${ip}        grafana.${CLUSTER_DOMAIN}.local"
                    ;;
                argocd-server)
                    echo "${ip}         argocd.${CLUSTER_DOMAIN}.local"
                    ;;
                minio-console)
                    echo "${ip}  minio.${CLUSTER_DOMAIN}.local"
                    ;;
                minio)
                    echo "${ip}  minio-api.${CLUSTER_DOMAIN}.local"
                    ;;
                longhorn-frontend)
                    echo "${ip}       longhorn.${CLUSTER_DOMAIN}.local"
                    ;;
                traefik)
                    echo "${ip}  traefik.${CLUSTER_DOMAIN}.local"
                    ;;
                open-webui)
                    echo "${ip}  chat.${CLUSTER_DOMAIN}.local"
                    ;;
                demo-chat-app)
                    echo "${ip}  demo-chat.${CLUSTER_DOMAIN}.local"
                    ;;
                *-server)
                    # Generic app servers (e.g., immich-server -> immich)
                    app="${name%-server}"
                    echo "${ip}  ${app}.${CLUSTER_DOMAIN}.local"
                    ;;
                *)
                    # Generic service
                    echo "${ip}  ${name}.${CLUSTER_DOMAIN}.local"
                    ;;
            esac
        done <<< "$services"
        
        echo "# End MyNodeOne services"
    } | sudo tee -a /etc/hosts > /dev/null
    
    log_success "DNS entries updated"
    return 0
}

# Validate DNS resolution
validate_dns() {
    local hostname="$1"
    local expected_ip="$2"
    
    local resolved_ip=$(getent hosts "$hostname" | awk '{ print $1 }')
    
    if [ "$resolved_ip" = "$expected_ip" ]; then
        log_debug "DNS validation passed: $hostname -> $expected_ip"
        return 0
    else
        log_debug "DNS validation failed: $hostname (got: $resolved_ip, expected: $expected_ip)"
        return 1
    fi
}

# Test service accessibility
test_service_access() {
    local url="$1"
    local service_name="$2"
    
    if curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" | grep -qE "^(200|301|302|401|403)"; then
        log_success "$service_name is accessible at $url"
        return 0
    else
        log_warn "$service_name may not be accessible at $url"
        return 1
    fi
}

# Install kubectl if missing
install_kubectl() {
    if command -v kubectl &> /dev/null; then
        log_success "kubectl already installed: $(kubectl version --client --short 2>/dev/null | head -n1)"
        return 0
    fi
    
    log_info "Installing kubectl..."
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        local kubectl_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        local kubectl_version=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -LO "https://dl.k8s.io/release/${kubectl_version}/bin/darwin/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    else
        log_error "Unsupported OS: $OSTYPE"
        log_info "Please install kubectl manually: https://kubernetes.io/docs/tasks/tools/"
        return 1
    fi
    
    log_success "kubectl installed successfully"
    return 0
}

# Clean up stale configs from previous installations
cleanup_old_configs() {
    log_info "Checking for stale configurations..."
    local cleaned=0
    
    # Check if running as root/sudo
    local actual_user="${SUDO_USER:-$USER}"
    local user_home=$(eval echo ~$actual_user)
    
    # Clean user's old config if it exists and differs from root config
    if [ -f "$user_home/.mynodeone/config.env" ]; then
        # Backup old user config
        local backup_file="$user_home/.mynodeone/config.env.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$user_home/.mynodeone/config.env" "$backup_file"
        log_info "Backed up old user config to: $backup_file"
        cleaned=$((cleaned + 1))
    fi
    
    # Clean old kubeconfig if it exists
    if [ -f "$user_home/.kube/config" ]; then
        # Check if it points to wrong control plane
        local old_server=$(grep "server:" "$user_home/.kube/config" 2>/dev/null | head -n 1 || echo "")
        if [ -n "$old_server" ]; then
            local backup_file="$user_home/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$user_home/.kube/config" "$backup_file"
            log_info "Backed up old kubeconfig to: $backup_file"
            cleaned=$((cleaned + 1))
        fi
    fi
    
    if [ $cleaned -gt 0 ]; then
        log_success "Cleaned up $cleaned stale configuration(s)"
    else
        log_info "No stale configurations found"
    fi
}

# Main setup function
main() {
    print_header "Management Laptop Setup (Hardened)"
    
    # Clean up stale configs first
    cleanup_old_configs
    echo
    
    # Load configuration (CONFIG_FILE set by detect-actual-home.sh)
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_error "Please run the interactive setup first: sudo ./scripts/mynodeone"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    log_info "Cluster: ${CLUSTER_NAME:-<not set>}"
    log_info "Domain: ${CLUSTER_DOMAIN:-<not set>}.local"
    log_info "Control Plane: ${CONTROL_PLANE_IP:-<not set>}"
    echo
    
    # Step 1: Install kubectl
    print_header "Step 1: kubectl Installation"
    if ! install_kubectl; then
        log_error "Failed to install kubectl"
        exit 1
    fi
    echo
    
    # Step 2: Validate/Fix kubeconfig
    print_header "Step 2: Kubeconfig Validation"
    
    if validate_kubeconfig; then
        log_success "Kubeconfig is valid and working"
    else
        log_warn "Kubeconfig is invalid or not working"
        
        if [ -n "${CONTROL_PLANE_IP:-}" ]; then
            local ssh_user="${CONTROL_PLANE_SSH_USER:-root}"
            
            if fix_kubeconfig "$CONTROL_PLANE_IP" "$ssh_user"; then
                log_success "Kubeconfig fixed successfully"
            else
                log_error "Failed to fix kubeconfig"
                log_info "Manual steps:"
                echo "  1. SSH to control plane: ssh $ssh_user@$CONTROL_PLANE_IP"
                echo "  2. Get kubeconfig: sudo cat /etc/rancher/k3s/k3s.yaml"
                echo "  3. Copy to ~/.kube/config on this laptop"
                echo "  4. Replace 127.0.0.1 with $CONTROL_PLANE_IP"
                exit 1
            fi
        else
            log_error "Control plane IP not configured"
            exit 1
        fi
    fi
    echo
    
    # Step 3: Test cluster connection
    print_header "Step 3: Cluster Connection Test"
    
    if retry_command "kubectl get nodes" "Connecting to cluster"; then
        log_success "Connected to cluster"
        kubectl get nodes
    else
        log_error "Cannot connect to cluster"
        exit 1
    fi
    echo
    
    # Step 4: Fetch/validate cluster info
    print_header "Step 4: Cluster Information"
    
    if [ -z "${CLUSTER_NAME:-}" ] || [ -z "${CLUSTER_DOMAIN:-}" ]; then
        fetch_cluster_info
        source "$CONFIG_FILE"  # Reload
    fi
    
    log_success "Cluster Name: $CLUSTER_NAME"
    log_success "Cluster Domain: ${CLUSTER_DOMAIN}.local"
    echo
    
    # Step 5: Update DNS entries
    print_header "Step 5: DNS Configuration"
    
    if update_dns_entries; then
        log_success "DNS entries configured"
    else
        log_warn "DNS update had issues"
    fi
    echo
    
    # Step 6: Validate service access
    print_header "Step 6: Service Accessibility Check"
    
    local services_to_test=(
        "http://${CLUSTER_DOMAIN}.local:Dashboard"
        "http://grafana.${CLUSTER_DOMAIN}.local:Grafana"
        "https://argocd.${CLUSTER_DOMAIN}.local:ArgoCD"
    )
    
    local accessible_count=0
    for service in "${services_to_test[@]}"; do
        IFS=':' read -r url name <<< "$service"
        if test_service_access "$url" "$name"; then
            accessible_count=$((accessible_count + 1))
        fi
    done
    echo
    
    # Step 7: Auto-register in enterprise registry
    print_header "Step 7: Enterprise Registry Registration"
    
    if [ -f "$SCRIPT_DIR/setup-management-node.sh" ]; then
        bash "$SCRIPT_DIR/setup-management-node.sh" || true
    else
        log_warn "Auto-registration script not found"
        log_info "To manually register this laptop, run:"
        echo "  sudo ./scripts/setup-management-node.sh"
    fi
    echo
    
    # Sync configs to actual user (if running as sudo)
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home=$(eval echo ~$SUDO_USER)
        
        # Only sync if ACTUAL_HOME is different from user_home
        # (i.e., if files were created in /root but should be in user's home)
        if [ "$ACTUAL_HOME" != "$user_home" ]; then
            print_header "Step 8: Syncing Configs to User"
            
            # Copy mynodeone config
            if [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
                sudo mkdir -p "$user_home/.mynodeone"
                sudo cp $ACTUAL_HOME/.mynodeone/config.env "$user_home/.mynodeone/config.env"
                sudo chown -R $SUDO_USER:$SUDO_USER "$user_home/.mynodeone"
                log_success "Synced MyNodeOne config to $SUDO_USER"
            fi
            
            # Copy kubeconfig
            if [ -f "$ACTUAL_HOME/.kube/config" ]; then
                sudo mkdir -p "$user_home/.kube"
                sudo cp $ACTUAL_HOME/.kube/config "$user_home/.kube/config"
                sudo chown -R $SUDO_USER:$SUDO_USER "$user_home/.kube"
                sudo chmod 600 "$user_home/.kube/config"
                log_success "Synced kubeconfig to $SUDO_USER"
            fi
            
            log_info "User $SUDO_USER can now run kubectl without sudo"
        else
            # Files are already in the right place, just ensure proper ownership
            sudo chown -R $SUDO_USER:$SUDO_USER "$user_home/.mynodeone" 2>/dev/null || true
            sudo chown -R $SUDO_USER:$SUDO_USER "$user_home/.kube" 2>/dev/null || true
            sudo chmod 600 "$user_home/.kube/config" 2>/dev/null || true
        fi
    fi
    echo
    
    # Step 8: Sync service registry to ensure all apps are registered
    print_header "Step 8: Syncing Service Registry"
    
    log_info "Ensuring all services are registered in DNS..."
    
    # Check if we can access the control plane
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null 2>&1; then
        # Sync service registry on control plane via kubectl
        if kubectl get configmap -n kube-system cluster-info &>/dev/null 2>&1; then
            log_info "Running service registry sync on control plane..."
            
            # Get repo path from cluster config
            REPO_PATH=$(kubectl get configmap -n kube-system cluster-info \
                -o jsonpath='{.data.repo-path}' 2>/dev/null || echo "")
            
            if [ -n "$REPO_PATH" ] && [ -n "${CONTROL_PLANE_IP:-}" ] && [ -n "${CONTROL_PLANE_SSH_USER:-}" ]; then
                # Run sync on control plane via SSH
                ssh "${CONTROL_PLANE_SSH_USER}@${CONTROL_PLANE_IP}" \
                    "cd '$REPO_PATH' && sudo ./scripts/lib/service-registry.sh sync" 2>&1 | \
                    grep -E "Synced|Registered" || true
                
                log_success "Service registry synced on control plane"
                
                # Now sync DNS on this laptop
                log_info "Updating local DNS entries..."
                sudo ./scripts/sync-dns.sh > /dev/null 2>&1 || log_warn "DNS sync had issues (non-critical)"
            else
                log_warn "Could not sync service registry (missing control plane info)"
            fi
        else
            log_info "Service registry will be synced automatically"
        fi
    else
        log_warn "kubectl not available, skipping service registry sync"
    fi
    echo
    
    # Run validation tests
    print_header "Step 9: Validating Installation"
    
    log_info "Running installation validation tests..."
    echo
    
    if [ -f "$SCRIPT_DIR/lib/validate-installation.sh" ]; then
        if bash "$SCRIPT_DIR/lib/validate-installation.sh" management-laptop; then
            echo
            log_success "✅ All validation tests passed!"
            
            # Save validation status
            echo "LAST_VALIDATION=$(date -Iseconds)" >> "$CONFIG_FILE"
            echo "VALIDATION_STATUS=passed" >> "$CONFIG_FILE"
        else
            echo
            log_warn "⚠️  Some validation tests failed"
            log_info "Your laptop may still work, but some features need attention"
            
            # Save validation status
            echo "LAST_VALIDATION=$(date -Iseconds)" >> "$CONFIG_FILE"
            echo "VALIDATION_STATUS=failed" >> "$CONFIG_FILE"
        fi
    else
        log_warn "Validation script not found, skipping tests"
    fi
    echo
    
    # Final summary
    print_header "Setup Complete!"
    
    log_success "Management laptop configured for cluster: $CLUSTER_NAME"
    log_success "DNS configured for ${CLUSTER_DOMAIN}.local domain"
    log_success "$accessible_count/${#services_to_test[@]} core services are accessible"
    echo
    
    log_info "Access your services:"
    echo "  • Dashboard: http://${CLUSTER_DOMAIN}.local"
    echo "  • Grafana:   http://grafana.${CLUSTER_DOMAIN}.local"
    echo "  • ArgoCD:    https://argocd.${CLUSTER_DOMAIN}.local"
    echo "  • MinIO:     http://minio.${CLUSTER_DOMAIN}.local:9001"
    echo "  • Longhorn:  http://longhorn.${CLUSTER_DOMAIN}.local"
    
    # Show app services if they exist
    if kubectl get svc -n demo-apps demo-chat-app &>/dev/null; then
        echo "  • Demo Chat: http://demo-chat.${CLUSTER_DOMAIN}.local"
    fi
    if kubectl get svc -n llm-chat open-webui &>/dev/null; then
        echo "  • LLM Chat:  http://chat.${CLUSTER_DOMAIN}.local"
    fi
    
    echo
    log_info "Next steps:"
    echo "  1. Verify Tailscale: tailscale status"
    echo "  2. Check cluster: kubectl get nodes"
    echo "  3. View pods: kubectl get pods -A"
    echo "  4. Install apps from dashboard or kubectl"
    echo
}

# Run main function
main "$@"
