#!/bin/bash

# MyNodeOne Laptop Setup Script
# Configures your laptop to manage the cluster
# No need to access control plane manually!

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/ssh-utils.sh"

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# Load cluster configuration if it exists
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Use configured domain or fallback to mynodeone
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

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
        echo "  sudo tailscale up"
        echo
        echo "Then re-run this script."
        exit 1
    fi
    
    # Check if Tailscale is connected
    if ! tailscale status &> /dev/null; then
        log_error "Tailscale is not running or not connected"
        echo
        echo "Please connect to Tailscale:"
        echo "  sudo tailscale up"
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
        
        sudo tailscale up --accept-routes
        
        if tailscale status --self 2>&1 | grep -q "accept-routes is false"; then
            log_error "Failed to configure Tailscale route acceptance"
            exit 1
        fi
        
        log_success "Tailscale configured to accept subnet routes"
        echo
        echo "✅ Your laptop can now access LoadBalancer services!"
    else
        log_success "Tailscale is already configured correctly"
    fi
}

install_kubectl() {
    print_header "Installing kubectl"
    
    if command -v kubectl &> /dev/null; then
        KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || echo "unknown")
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
        log_info "Downloading kubectl for Linux..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi
    
    log_success "kubectl installed"
}

fetch_kubeconfig() {
    print_header "Fetching Kubernetes Configuration"
    
    log_info "Retrieving kubeconfig from control plane..."
    
    # Create .kube directory
    mkdir -p ~/.kube
    
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
        if scp_with_control -q "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP:/tmp/k3s-config.yaml" ~/.kube/config; then
            # Clean up temp file on remote
            ssh_with_control "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" "rm -f /tmp/k3s-config.yaml" 2>/dev/null || true
            chmod 600 ~/.kube/config
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
        echo "  3. Exit and run: scp $CONTROL_PLANE_USER@$CONTROL_PLANE_IP:/tmp/k3s.yaml ~/.kube/config"
        exit 1
    fi
    
    # Update server address from 127.0.0.1 to control plane IP
    log_info "Configuring kubeconfig to use control plane IP..."
    sed -i "s|https://127.0.0.1:6443|https://$CONTROL_PLANE_IP:6443|g" ~/.kube/config
    log_success "Kubeconfig configured for remote access"
}

test_cluster_connection() {
    log_info "Testing cluster connection..."
    
    if kubectl get nodes &>/dev/null; then
        log_success "Cluster connection successful!"
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
        if [ -f "$SCRIPT_DIR/sync-dns.sh" ]; then
            bash "$SCRIPT_DIR/sync-dns.sh" || {
                log_warn "DNS sync failed, you can retry later with:"
                echo "  sudo $SCRIPT_DIR/sync-dns.sh"
                return
            }
        else
            log_error "DNS sync script not found at: $SCRIPT_DIR/sync-dns.sh"
            log_info "Manual sync: Run 'sudo ./scripts/sync-dns.sh' from MyNodeOne directory"
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
            log_info "Installing helm..."
            curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
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
                K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d '"' -f 4)
                curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | sudo tar xz -C /usr/local/bin k9s
            fi
        fi
        
        log_success "Additional tools installed"
    fi
}

print_summary() {
    print_header "Setup Complete! 🎉"
    
    echo "Your laptop is now configured to manage your MyNodeOne cluster!"
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
    echo "  • View credentials: ssh $CONTROL_PLANE_USER@$CONTROL_PLANE_IP 'sudo /path/to/scripts/show-credentials.sh'"
    echo "  • Deploy demo app:  kubectl apply -f <your-app.yaml>"
    echo "  • Use VS Code/Cursor with Kubernetes extensions"
    echo
    echo "📚 Next Steps:"
    echo "  • Read docs/guides/POST_INSTALLATION_GUIDE.md for detailed examples"
    echo "  • Try AI-assisted development with Cursor or Windsurf"
    echo "  • Deploy your first application!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "💡 Tip: You can now work entirely from your laptop!"
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
    echo "You'll be able to deploy apps, monitor the cluster, and more - all from your laptop!"
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
    print_summary
}

main "$@"
