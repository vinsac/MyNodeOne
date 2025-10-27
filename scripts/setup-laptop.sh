#!/bin/bash

# MyNodeOne Laptop Setup Script
# Configures your laptop to manage the cluster
# No need to access control plane manually!

set -e

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

test_ssh_connection() {
    log_info "Testing SSH connection to control plane..."
    
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" exit 2>/dev/null; then
        log_success "SSH connection successful (passwordless)"
        SSH_NEEDS_PASSWORD=false
    else
        log_warn "SSH requires password or key not configured"
        SSH_NEEDS_PASSWORD=true
        
        echo
        echo "Testing connection with password..."
        if ssh -o ConnectTimeout=5 "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" exit; then
            log_success "SSH connection successful (with password)"
        else
            log_error "Cannot connect to control plane. Please check:"
            echo "  • Tailscale is running on both machines"
            echo "  • IP/hostname is correct: $CONTROL_PLANE_IP"
            echo "  • Username is correct: $CONTROL_PLANE_USER"
            echo "  • SSH is enabled on control plane"
            exit 1
        fi
    fi
}

setup_ssh_key() {
    if [ "$SSH_NEEDS_PASSWORD" = true ]; then
        print_header "SSH Key Setup (Optional but Recommended)"
        
        echo "Would you like to set up passwordless SSH access?"
        echo "This will allow you to manage the cluster without entering password each time."
        echo
        read -p "Set up SSH key? [Y/n]: " -r
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            log_info "Setting up SSH key..."
            
            # Check if SSH key exists
            if [ ! -f ~/.ssh/id_rsa ] && [ ! -f ~/.ssh/id_ed25519 ]; then
                log_info "Generating new SSH key..."
                ssh-keygen -t ed25519 -C "mynodeone-laptop-access" -f ~/.ssh/id_ed25519 -N ""
                log_success "SSH key generated"
            fi
            
            # Copy key to control plane
            log_info "Copying SSH key to control plane..."
            if ssh-copy-id "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP"; then
                log_success "SSH key installed on control plane"
                SSH_NEEDS_PASSWORD=false
            else
                log_warn "SSH key copy failed, will use password authentication"
            fi
        fi
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
    if ssh -t "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" "sudo cp /etc/rancher/k3s/k3s.yaml /tmp/k3s-config.yaml && sudo chmod 644 /tmp/k3s-config.yaml"; then
        echo
        log_info "Downloading kubeconfig via SCP..."
        if scp -q "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP:/tmp/k3s-config.yaml" ~/.kube/config; then
            # Clean up temp file on remote
            ssh "$CONTROL_PLANE_USER@$CONTROL_PLANE_IP" "rm -f /tmp/k3s-config.yaml" 2>/dev/null || true
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
    log_info "Retrieving service IPs..."
    
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_API_IP=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    LONGHORN_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -z "$GRAFANA_IP" ]; then
        log_warn "Services not fully ready yet, will use IPs when available"
        return
    fi
    
    log_success "Service IPs retrieved"
}

setup_local_dns() {
    print_header "Local DNS Setup (Optional)"
    
    echo "Would you like to set up .local domain names for easy access?"
    echo "This allows you to use names like grafana.mynodeone.local instead of IPs."
    echo
    read -p "Set up local DNS? [Y/n]: " -r
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        if [ -z "$GRAFANA_IP" ]; then
            log_warn "Service IPs not available yet. Run this after services are ready:"
            echo "  kubectl get svc -A | grep LoadBalancer"
            echo
            echo "Then add to /etc/hosts manually or re-run this script"
            return
        fi
        
        log_info "Adding entries to /etc/hosts..."
        
        # Backup hosts file
        sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
        
        # Remove old entries
        sudo sed -i.tmp '/# MyNodeOne services/,/# End MyNodeOne services/d' /etc/hosts
        
        # Add new entries
        echo "" | sudo tee -a /etc/hosts > /dev/null
        echo "# MyNodeOne services" | sudo tee -a /etc/hosts > /dev/null
        echo "${GRAFANA_IP}        grafana.mynodeone.local" | sudo tee -a /etc/hosts > /dev/null
        echo "${ARGOCD_IP}         argocd.mynodeone.local" | sudo tee -a /etc/hosts > /dev/null
        echo "${MINIO_CONSOLE_IP}  minio.mynodeone.local" | sudo tee -a /etc/hosts > /dev/null
        echo "${MINIO_API_IP}      minio-api.mynodeone.local" | sudo tee -a /etc/hosts > /dev/null
        echo "${LONGHORN_IP}       longhorn.mynodeone.local" | sudo tee -a /etc/hosts > /dev/null
        echo "# End MyNodeOne services" | sudo tee -a /etc/hosts > /dev/null
        
        log_success "Local DNS configured"
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
        echo "  • Grafana:  http://grafana.mynodeone.local"
        echo "  • ArgoCD:   https://argocd.mynodeone.local"
        echo "  • MinIO:    http://minio.mynodeone.local:9001"
        echo "  • Longhorn: http://longhorn.mynodeone.local"
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

main() {
    print_header "MyNodeOne Laptop Setup"
    
    echo "This script will configure your laptop to manage your MyNodeOne cluster."
    echo "You'll be able to deploy apps, monitor the cluster, and more - all from your laptop!"
    echo
    
    check_requirements
    get_control_plane_info
    test_ssh_connection
    setup_ssh_key
    install_kubectl
    fetch_kubeconfig
    test_cluster_connection
    fetch_service_ips
    setup_local_dns
    install_helpful_tools
    print_summary
}

main "$@"
