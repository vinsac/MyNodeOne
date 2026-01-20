#!/bin/bash

# MyNodeOne Laptop Setup Script
# Configures your laptop to manage the cluster
# No need to access control plane manually!

set -euo pipefail

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Source shared detection utility
source "$PROJECT_ROOT/scripts/lib/detect-actual-home.sh"
# Source SSH utilities for ControlMaster support
source "$PROJECT_ROOT/scripts/lib/ssh-utils.sh"
# Source K8s utilities for robust detection
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

# Load cluster configuration if it exists
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Use configured domain or fallback to mynodeone
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

# Tool versions (pinned for reproducible installs)
KUBECTL_VERSION="v1.28.5"
HELM_VERSION="v3.15.3"
K9S_VERSION="v0.32.5"

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
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    if [ "$default" = "y" ]; then
        read -p "$(echo -e ${GREEN}?${NC}) $prompt [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$(echo -e ${GREEN}?${NC}) $prompt [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"
    
    read -p "$(echo -e ${GREEN}?${NC}) $prompt [$default]: " response
    export "$var_name"="${response:-$default}"
}

check_requirements() {
    log_info "Checking requirements..."
    
    # Check if running on Linux/macOS/WSL
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
        log_error "Please run this script in WSL (Windows Subsystem for Linux) on Windows"
        log_info "Install WSL: https://docs.microsoft.com/en-us/windows/wsl/install"
        exit 1
    fi
    
    # Check for ssh
    if ! command -v ssh &> /dev/null; then
        log_error "ssh not found. Installing..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_info "SSH should be pre-installed on macOS"
        else
            sudo apt-get update && sudo apt-get install -y openssh-client
        fi
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found. Installing..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v brew &> /dev/null; then
                brew install jq
            fi
        else
            sudo apt-get update && sudo apt-get install -y jq
        fi
    fi
    
    log_success "Requirements check passed"
}

get_control_plane_info() {
    print_header "Control Plane Information"
    
    echo "This script will set up your laptop to manage your MyNodeOne cluster."
    echo
    echo "We need to connect to your control plane machine to retrieve configuration."
    echo
    
    # Get control plane Tailscale IP or hostname
    read -p "Enter your control plane Tailscale IP or hostname (e.g., 100.118.5.201): " CONTROL_PLANE_IP
    
    if [ -z "$CONTROL_PLANE_IP" ]; then
        log_error "Control plane IP/hostname is required"
        exit 1
    fi
    
    # Get username (default to current user or ubuntu)
    read -p "Enter SSH username on control plane [default: $USER]: " CONTROL_PLANE_USER
    CONTROL_PLANE_USER=${CONTROL_PLANE_USER:-$USER}
    
    log_info "Will connect to: $CONTROL_PLANE_USER@$CONTROL_PLANE_IP"
}

configure_tailscale_routes() {
    print_header "Configuring Tailscale Network Access"
    
    log_info "Checking Tailscale configuration..."
    
    # Check if Tailscale is installed
    if ! command -v tailscale &> /dev/null; then
        log_error "Tailscale is not installed on this laptop"
        echo
        echo "Please install Tailscale first:"
        echo "  curl -fsSL https://tailscale.com/install.sh | sh"
        echo "  sudo tailscale up --accept-dns=false"
        echo
        echo "Then re-run this script."
        exit 1
    fi
    
    # Check if Tailscale is connected
    if ! tailscale status &> /dev/null; then
        log_error "Tailscale is not running or not connected"
        echo
        echo "Please connect to Tailscale:"
        echo "  sudo tailscale up --accept-dns=false"
        echo
        echo "Then re-run this script."
        exit 1
    fi
    
    # Check if accepting routes
    if tailscale status --self 2>&1 | grep -q "accept-routes is false"; then
        log_info "Configuring Tailscale to accept subnet routes..."
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  What This Means (Simple Explanation)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "Your control plane advertises service IPs to your laptop"
        echo "through Tailscale. To access these services, your laptop"
        echo "needs permission to 'accept' these routes."
        echo
        echo "This is like telling your laptop: 'Trust the paths from"
        echo "the control plane to reach services at 100.x.x.x addresses.'"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        # Use --accept-dns=false to prevent DNS takeover issues
        sudo tailscale up --accept-routes --accept-dns=false
        
        if tailscale status --self 2>&1 | grep -q "accept-routes is false"; then
            log_error "Failed to configure Tailscale route acceptance"
            exit 1
        fi
        
        log_success "Tailscale configured to accept subnet routes (DNS managed by system)"
        echo
        echo "✅ Your laptop can now access LoadBalancer services"
    else
        log_success "Tailscale is already configured correctly"
    fi
}

install_kubectl() {
    print_header "Installing kubectl"
    
    if command -v kubectl &> /dev/null; then
        if command -v jq &>/dev/null; then
            KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // .gitVersion // "unknown"')
        else
            KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || echo "unknown")
        fi
        log_success "kubectl already installed: $KUBECTL_VERSION"
        return
    fi
    
    log_info "Installing kubectl..."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install kubectl
        else
            log_info "Downloading kubectl for macOS..."
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
        fi
    else
        # Linux
        log_info "Downloading kubectl ${KUBECTL_VERSION} for Linux..."
        curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi
    
    log_success "kubectl installed"
}

fetch_kubeconfig() {
    print_header "Fetching Kubernetes Configuration"
    
    log_info "Retrieving kubeconfig from control plane..."
    
    # Create .kube directory in actual home
    mkdir -p "$ACTUAL_HOME/.kube"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.kube" 2>/dev/null || true
    
    # Check if we already have a working kubeconfig (e.g. from fetch-cluster-info.sh)
    if [ -f "$ACTUAL_HOME/.kube/config" ]; then
        log_info "Found existing kubeconfig at $ACTUAL_HOME/.kube/config"
        log_info "Testing existing connection..."
        if KUBECONFIG="$ACTUAL_HOME/.kube/config" kubectl get nodes &>/dev/null; then
            log_success "Existing cluster connection is working"
            return 0
        fi
        log_warn "Existing kubeconfig is not working, will re-fetch"
    fi
    
    # K3s stores kubeconfig at /etc/rancher/k3s/k3s.yaml (requires sudo)
    echo
    echo "Fetching K3s kubeconfig (requires sudo on control plane)..."
    echo "You may be prompted for the sudo password on the control plane."
    echo
    
    # Better approach: Copy file to temp location with sudo, then scp it
    log_info "Copying kubeconfig to temporary location on control plane..."
    echo "Note: You'll be prompted for the sudo password on the control plane."
    echo
    
    # Use -t to allocate pseudo-terminal for sudo password prompt, but keep it simple
    if ssh_with_control -t "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s-config.yaml && sudo chmod 644 /tmp/k3s-config.yaml"; then
        echo
        log_info "Downloading kubeconfig via SCP..."
        if scp_with_control -q "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP:/tmp/k3s-config.yaml" "$ACTUAL_HOME/.kube/config"; then
            # Clean up temp file on remote
            ssh_with_control "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" "rm -f /tmp/k3s-config.yaml" 2>/dev/null || true
            chmod 600 "$ACTUAL_HOME/.kube/config"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.kube/config" 2>/dev/null || true
            log_success "Kubeconfig retrieved successfully"
        else
            log_error "Failed to download kubeconfig via SCP"
            exit 1
        fi
    else
        echo
        log_error "Failed to access kubeconfig on control plane"
        echo
        echo "Troubleshooting:"
        echo "  • Ensure K3s is installed on control plane"
        echo "  • Check file exists: ssh $CONTROL_PLANE_USER@$CONTROL_PLANE_IP 'sudo ls -l /etc/rancher/k3s/k3s.yaml'"
        echo "  • Verify user '$CONTROL_PLANE_USER' has sudo access"
        echo "  • Try manually: ssh $CONTROL_PLANE_USER@$CONTROL_PLANE_IP 'sudo cat /etc/rancher/k3s/k3s.yaml'"
        echo
        echo "Manual steps to fix:"
        echo "  1. SSH to control plane: ssh $CONTROL_PLANE_USER@$CONTROL_PLANE_IP"
        echo "  2. Copy kubeconfig: sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml && sudo chmod 644 /tmp/k3s.yaml"
        echo "  3. Exit and run: scp $CONTROL_PLANE_USER@$CONTROL_PLANE_IP:/tmp/k3s.yaml $ACTUAL_HOME/.kube/config"
        exit 1
    fi
    
    # Update server address from 127.0.0.1 to control plane IP
    log_info "Configuring kubeconfig to use control plane IP..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|https://127.0.0.1:6443|https://$CONTROL_PLANE_IP:6443|g" "$ACTUAL_HOME/.kube/config"
    else
        sed -i "s|https://127.0.0.1:6443|https://$CONTROL_PLANE_IP:6443|g" "$ACTUAL_HOME/.kube/config"
    fi
    log_success "Kubeconfig configured for remote access"
}

test_cluster_connection() {
    log_info "Testing cluster connection..."
    
    # Use robust detection to handle root/user confusion
    export_k8s_config || {
        log_error "Kubeconfig not found. Please ensure it was retrieved correctly."
        exit 1
    }
    
    if kubectl get nodes &>/dev/null; then
        log_success "Cluster connection successful"
        echo
        kubectl get nodes
    else
        log_error "Cannot connect to cluster"
        echo
        echo "Troubleshooting:"
        echo "  • Ensure Tailscale is running on this laptop"
        echo "  • Check if you're connected to the same Tailscale network"
        echo "  • Verify: tailscale status"
        exit 1
    fi
}

fetch_service_ips() {
    # Deprecated: Service IPs are now managed by service registry
    # Kept for backwards compatibility but does nothing
    :
}

setup_local_dns() {
    print_header "Local DNS Setup"
    
    echo "Setting up .local domain names for easy access..."
    echo "This allows you to use names like grafana.${CLUSTER_DOMAIN}.local instead of IPs."
    echo
    read -p "Set up local DNS? [Y/n]: " -r
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        log_info "Syncing DNS from service registry..."
        
        # Use centralized DNS sync script
        if [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
            bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" || {
                log_warn "DNS sync failed, you can retry later with:"
                echo "  sudo ./scripts/domains/sync-dns.sh"
                return
            }
        else
            log_error "DNS sync script not found at: $PROJECT_ROOT/scripts/domains/sync-dns.sh"
            log_info "Manual sync: Run 'sudo ./scripts/domains/sync-dns.sh' from MyNodeOne directory"
            return
        fi
        
        log_success "Local DNS configured from service registry"
        log_info "All services (platform + apps) are now accessible via .local domains"
        USE_LOCAL_DNS=true
    else
        USE_LOCAL_DNS=false
    fi
}

install_helpful_tools() {
    print_header "Additional Tools (Optional)"
    
    echo "Would you like to install helpful Kubernetes tools?"
    echo "  • k9s - Terminal UI for Kubernetes"
    echo "  • helm - Kubernetes package manager"
    echo
    read -p "Install additional tools? [Y/n]: " -r
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        # Install helm
        if ! command -v helm &> /dev/null; then
            log_info "Installing helm ${HELM_VERSION}..."
            if [[ "$OSTYPE" == "darwin"* ]]; then
                if command -v brew &> /dev/null; then
                    brew install helm
                else
                    log_info "Downloading helm ${HELM_VERSION} for macOS..."
                    local HELM_OS="darwin"
                    local HELM_ARCH="amd64"
                    curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz"
                    tar -zxf "helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz"
                    sudo mv "${HELM_OS}-${HELM_ARCH}/helm" /usr/local/bin/helm
                    sudo chmod +x /usr/local/bin/helm
                    rm -rf "helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz" "${HELM_OS}-${HELM_ARCH}"
                fi
            else
                log_info "Downloading helm ${HELM_VERSION} for Linux..."
                local HELM_OS="linux"
                local HELM_ARCH="amd64"
                curl -LO "https://get.helm.sh/helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz"
                tar -zxf "helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz"
                sudo mv "${HELM_OS}-${HELM_ARCH}/helm" /usr/local/bin/helm
                sudo chmod +x /usr/local/bin/helm
                rm -rf "helm-${HELM_VERSION}-${HELM_OS}-${HELM_ARCH}.tar.gz" "${HELM_OS}-${HELM_ARCH}"
            fi
        fi
        
        # Install k9s
        if ! command -v k9s &> /dev/null; then
            log_info "Installing k9s..."
            if [[ "$OSTYPE" == "darwin"* ]]; then
                if command -v brew &> /dev/null; then
                    brew install k9s
                fi
            else
                # Linux
                log_info "Installing k9s ${K9S_VERSION}..."
                curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | sudo tar xz -C /usr/local/bin k9s
            fi
        fi
        
        log_success "Additional tools installed"
    fi
}

register_laptop_with_cluster() {
    local control_plane_user="$1"
    local control_plane_ip="$2"
    
    print_header "Management Laptop Registration"
    
    # Get laptop details
    local tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "")
    local hostname=$(hostname)
    local username="$ACTUAL_USER"
    
    if [ -z "$tailscale_ip" ]; then
        log_warn "Tailscale not detected - skipping registration"
        log_info "Install Tailscale to enable automatic DNS sync"
        return 1
    fi
    
    log_info "Laptop Details:"
    echo "  • Tailscale IP: $tailscale_ip"
    echo "  • Hostname: $hostname"
    echo "  • Username: $username"
    echo ""
    
    log_info "Registering with control plane..."
    echo ""
    
    # Check if we already have the path saved in config
    local control_plane_repo_path="${CONTROL_PLANE_REPO_PATH:-}"
    
    if [ -z "$control_plane_repo_path" ]; then
        # Try to get authoritative path from cluster configmap first
        log_info "Fetching MyNodeOne path from cluster config..."
        
        control_plane_repo_path=$(ssh_with_control "$control_plane_user@$control_plane_ip" \
            "sudo kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.repo-path}' 2>/dev/null" || echo "")
        
        if [ -n "$control_plane_repo_path" ]; then
            log_success "Found authoritative path from cluster: $control_plane_repo_path"
        else
            # Fallback: search filesystem
            log_info "No path in cluster config, searching filesystem..."
            
            control_plane_repo_path=$(ssh_with_control "$control_plane_user@$control_plane_ip" \
                "find /root /home -maxdepth 3 -type d -name MyNodeOne 2>/dev/null | head -n 1" 2>/dev/null)
            
            if [ -z "$control_plane_repo_path" ]; then
                log_warn "Could not auto-detect MyNodeOne path on control plane"
                log_info "Trying standard locations..."
                
                for path in ~/MyNodeOne /root/MyNodeOne /opt/MyNodeOne; do
                    if ssh_with_control "$control_plane_user@$control_plane_ip" "[ -d '$path' ]" 2>/dev/null; then
                        control_plane_repo_path="$path"
                        break
                    fi
                done
            fi
            
            if [ -n "$control_plane_repo_path" ]; then
                log_success "Found MyNodeOne at: $control_plane_repo_path"
            fi
        fi
        
        if [ -n "$control_plane_repo_path" ]; then
            # Save the path for future use
            if ! grep -q "CONTROL_PLANE_REPO_PATH" ~/.mynodeone/config.env 2>/dev/null; then
                echo "CONTROL_PLANE_REPO_PATH=\"$control_plane_repo_path\"" >> ~/.mynodeone/config.env
                log_info "Saved repo path to config for future use"
            fi
        else
            log_warn "Could not find MyNodeOne on control plane"
            log_info "Skipping registry registration (can be done manually later)"
            return 1
        fi
    fi
    
    if [ -n "$control_plane_repo_path" ]; then
        log_info "Using MyNodeOne at: $control_plane_repo_path"
        
        # Get laptop's repo path
        local laptop_repo_path="$PROJECT_ROOT"
        log_info "Laptop repo path: $laptop_repo_path"
        
        # Register using node registry manager
        log_info "Registering in enterprise registry..."
        ssh_with_control "$control_plane_user@$control_plane_ip" \
            "cd '$control_plane_repo_path' && sudo SKIP_SSH_VALIDATION=true '$control_plane_repo_path/scripts/lib/node-registry-manager.sh' register management_laptops \
            $tailscale_ip $hostname $username 8080 '$laptop_repo_path'" 2>&1 | grep -v "Warning: Permanently added"
        
        if [ $? -eq 0 ]; then
            log_success "Laptop registered in sync controller"
            
            # Validate registration in ConfigMap
            log_info "Validating registration..."
            local laptop_check=$(ssh_with_control "$control_plane_user@$control_plane_ip" \
                "sudo kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' 2>/dev/null | jq -r '.management_laptops[] | select(.ip==\"$tailscale_ip\") | .ssh_user'" 2>/dev/null || echo "")
            
            if [ "$laptop_check" = "$username" ]; then
                log_success "✓ Registration verified in ConfigMap"
                log_success "✓ Registered with user: $laptop_check"
            else
                log_warn "⚠ Could not verify registration (expected user: $username, got: ${laptop_check:-none})"
            fi
        else
            log_error "Registration failed"
            return 1
        fi
    fi
    
    # Install node agent for heartbeat and visibility
    echo ""
    log_info "Installing node agent for cluster visibility..."
    if [ -f "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" ]; then
        # Fetch API token from control plane
        local api_token=$(ssh_with_control "$control_plane_user@$control_plane_ip" \
            "sudo cat /etc/mynodeone/api-token 2>/dev/null" 2>/dev/null || echo "")
        
        if [ -n "$api_token" ]; then
            sudo "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" \
                --control-plane-ip "$control_plane_ip" \
                --node-type laptop \
                --node-name "$hostname" \
                --api-token "$api_token" \
                --poll-interval 60
            
            if [ $? -eq 0 ]; then
                log_success "Node agent installed - laptop will appear in nodes-status"
            else
                log_warn "Node agent installation failed - laptop won't appear in nodes-status"
                log_warn "You can install it manually later with:"
                log_warn "  sudo $PROJECT_ROOT/scripts/installation/install-node-agent.sh --control-plane-ip $control_plane_ip"
            fi
        else
            log_warn "Could not fetch API token - skipping node agent installation"
            log_warn "Install manually later with:"
            log_warn "  sudo $PROJECT_ROOT/scripts/installation/install-node-agent.sh --control-plane-ip $control_plane_ip --ssh-user $control_plane_user"
        fi
    else
        log_warn "Node agent installer not found - skipping"
    fi
    
    # Run initial DNS sync
    echo ""
    log_info "Running initial sync..."
    # Pass ACTUAL_USER and ACTUAL_HOME to sudo so sync-dns.sh uses correct config
    sudo ACTUAL_USER="$ACTUAL_USER" ACTUAL_HOME="$ACTUAL_HOME" "$PROJECT_ROOT/scripts/domains/sync-dns.sh"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ Management Laptop Configured"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_success "What's configured:"
    echo "  • Registered in control plane registry"
    echo "  • Node agent installed (sends heartbeats)"
    echo "  • DNS entries configured in /etc/hosts"
    echo "  • kubectl access to cluster"
    echo "  • Access services via .local domains"
    echo "  • Automatic DNS sync enabled"
    echo ""
    
    log_info "How auto-sync works:"
    echo "  • When apps are installed, control plane pushes DNS updates"
    echo "  • Your laptop receives updates automatically via SSH"
    echo "  • New services become accessible within ~10 seconds"
    echo ""
    
    log_info "Check your laptop status:"
    echo "  ssh <control-plane-user>@<control-plane-ip> 'cd ~/MyNodeOne && ./scripts/nodes/nodes-status.sh'"
    echo ""
    
    log_info "Manual sync (if needed):"
    echo "  sudo $PROJECT_ROOT/scripts/domains/sync-dns.sh"
    echo ""
    
    # Show current services
    local local_domain="${CLUSTER_DOMAIN:-mynodeone}.local"
    local service_count=$(grep "$local_domain" /etc/hosts 2>/dev/null | wc -l)
    if [ -z "$service_count" ]; then
        service_count=0
    fi
    log_info "Currently configured services: $service_count"
    echo ""
    
    if [ "$service_count" -gt 0 ]; then
        echo "Available services:"
        grep "$local_domain" /etc/hosts | awk '{print "  • http://" $2}' | sort
        echo ""
    fi
    
    log_success "Management laptop registration complete! 🎉"
    echo ""
}

print_summary() {
    print_header "Setup Complete! 🎉"
    
    echo "Your laptop is now configured to manage your MyNodeOne cluster"
    echo
    echo "✅ kubectl installed and configured"
    echo "✅ Cluster connection tested"
    if [ "$USE_LOCAL_DNS" = true ]; then
        echo "✅ Local DNS configured (.local domains)"
    fi
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🎯 What You Can Do Now"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "📊 Access Web UIs (in your browser):"
    if [ "$USE_LOCAL_DNS" = true ]; then
        echo "  • Grafana:  http://grafana.${CLUSTER_DOMAIN}.local"
        echo "  • ArgoCD:   https://argocd.${CLUSTER_DOMAIN}.local"
        echo "  • MinIO:    http://minio.${CLUSTER_DOMAIN}.local:9001"
        echo "  • Longhorn: http://longhorn.${CLUSTER_DOMAIN}.local"
    else
        if [ -n "$GRAFANA_IP" ]; then
            echo "  • Grafana:  http://$GRAFANA_IP"
            echo "  • ArgoCD:   https://$ARGOCD_IP"
            echo "  • MinIO:    http://$MINIO_CONSOLE_IP:9001"
            echo "  • Longhorn: http://$LONGHORN_IP"
        else
            echo "  • Run: kubectl get svc -A | grep LoadBalancer"
            echo "  • Use the EXTERNAL-IP addresses shown"
        fi
    fi
    echo
    echo "💻 Manage Cluster (from terminal):"
    echo "  • View nodes:       kubectl get nodes"
    echo "  • View all pods:    kubectl get pods -A"
    echo "  • View services:    kubectl get svc -A"
    echo "  • Terminal UI:      k9s"
    echo
    echo "🚀 Deploy Applications:"
    echo "  • View credentials: ssh $CONTROL_PLANE_USER@$CONTROL_PLANE_IP 'sudo /path/to/scripts/utils/show-credentials.sh'"
    echo "  • Deploy demo app:  kubectl apply -f <your-app.yaml>"
    echo "  • Use VS Code/Cursor with Kubernetes extensions"
    echo
    echo "📚 Next Steps:"
    echo "  • Read docs/guides/POST_INSTALLATION_GUIDE.md for detailed examples"
    echo "  • Try AI-assisted development with Cursor or Windsurf"
    echo "  • Deploy your first application"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "💡 Tip: You can now work entirely from your laptop"
    echo "   No need to SSH into the control plane for daily tasks."
    echo
}

configure_passwordless_sudo() {
    log_info "Configuring passwordless sudo for automation..."
    
    # Use ACTUAL_USER which correctly detects the real user even when running with sudo
    local current_user="$ACTUAL_USER"
    
    # Check if already configured
    if sudo -n true 2>/dev/null; then
        log_success "Passwordless sudo already configured for $current_user"
        return 0
    fi
    
    log_info "Setting up passwordless sudo for user: $current_user"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Passwordless Sudo Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This allows MyNodeOne scripts to run without password prompts."
    echo "You'll be prompted for your sudo password ONE LAST TIME."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Create sudoers rule
    echo "$current_user ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${current_user}-nopasswd" > /dev/null
    sudo chmod 0440 "/etc/sudoers.d/${current_user}-nopasswd"
    
    # Verify it works
    if sudo -n true 2>/dev/null; then
        log_success "Passwordless sudo configured successfully"
    else
        log_warn "Could not verify passwordless sudo, continuing anyway..."
    fi
    echo ""
}

main() {
    print_header "MyNodeOne Laptop Setup"
    
    echo "This script will configure your laptop to manage your MyNodeOne cluster."
    echo "You'll be able to deploy apps, monitor the cluster, and more - all from your laptop"
    echo
    
    check_requirements

    log_info "Ensuring correct home directory permissions for user: $ACTUAL_USER..."
    sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME"
    log_success "Home directory permissions verified."
    echo

    configure_passwordless_sudo
    configure_tailscale_routes
    get_control_plane_info

    # Set up SSH multiplexing for fewer password prompts
    log_info "Validating SSH connectivity to control plane..."
    if ! validate_ssh_early "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP" "control plane"; then
        log_error "Cannot establish SSH connection to control plane. Please check the IP and username."
        exit 1
    fi

    log_info "Setting up SSH connection multiplexing..."
    setup_ssh_control_master "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP"

    # Ensure the ControlMaster socket is cleaned up on exit
    trap "cleanup_ssh_control_master '$CONTROL_PLANE_USER' '$CONTROL_PLANE_IP'" EXIT
    install_kubectl
    fetch_kubeconfig
    test_cluster_connection
    fetch_service_ips
    setup_local_dns
    install_helpful_tools
    
    # Register laptop for automated DNS sync if requested
    print_header "Cluster Registration"
    echo "Would you like to register this laptop for automated DNS updates?"
    echo "This enables the control plane to push new .local domains automatically."
    echo
    if prompt_confirm "Register laptop for auto-sync?" "y"; then
        # Use existing SSH ControlMaster for registration
        log_info "Registering laptop in cluster registry..."
        
        # Call the integrated registration function
        register_laptop_with_cluster "$CONTROL_PLANE_USER" "$CONTROL_PLANE_IP"
    fi

    # Finalizing Permissions
    print_header "Finalizing Permissions"
    log_info "Ensuring correct ownership for config files..."
    sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.mynodeone" 2>/dev/null || true
    sudo chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.kube" 2>/dev/null || true
    sudo chmod 600 "$ACTUAL_HOME/.kube/config" 2>/dev/null || true
    log_success "Permissions finalized for user '$ACTUAL_USER'"
    echo

    print_summary
}

main "$@"
