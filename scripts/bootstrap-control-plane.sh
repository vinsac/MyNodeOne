#!/bin/bash

###############################################################################
# MyNodeOne Control Plane Bootstrap Script
# 
# This script sets up the control plane node with:
# - K3s server (lightweight Kubernetes)
# - Helm package manager
# - Cert-Manager for SSL certificates
# - Traefik ingress controller
# - Longhorn distributed storage
# - MinIO object storage
# - Prometheus + Grafana + Loki monitoring
# - ArgoCD for GitOps
#
# IMPORTANT: Run ./scripts/interactive-setup.sh first!
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load configuration
CONFIG_FILE="$HOME/.mynodeone/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# K3s version
K3S_VERSION="v1.28.5+k3s1"

# Set kubeconfig for K3s (so kubectl and helm work)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Generic failsafe installation function
# Usage: install_tool_failsafe "tool_name" "snap_package" "curl_script_url" "version" "binary_url_template"
install_tool_failsafe() {
    local TOOL_NAME=$1
    local SNAP_PACKAGE=$2
    local CURL_SCRIPT=$3
    local VERSION=$4
    local BINARY_URL_TEMPLATE=$5
    
    log_info "Installing $TOOL_NAME..."
    
    # Check if already installed
    if command -v "$TOOL_NAME" &> /dev/null; then
        local CURRENT_VERSION=$("$TOOL_NAME" version --short 2>/dev/null || "$TOOL_NAME" --version 2>/dev/null || echo "unknown")
        log_warn "$TOOL_NAME already installed ($CURRENT_VERSION), skipping..."
        return 0
    fi
    
    log_info "Attempting $TOOL_NAME installation with multiple fallback methods..."
    
    # Method 1: Try snap (if available)
    if [ -n "$SNAP_PACKAGE" ] && command -v snap &> /dev/null; then
        log_info "Method 1: Trying snap installation..."
        if snap install "$SNAP_PACKAGE" --classic 2>/dev/null; then
            log_success "$TOOL_NAME installed via snap"
            return 0
        else
            log_warn "Snap installation failed, trying next method..."
        fi
    fi
    
    # Method 2: Official script (if provided)
    if [ -n "$CURL_SCRIPT" ]; then
        log_info "Method 2: Trying official installation script..."
        if curl -fsSL "$CURL_SCRIPT" | bash; then
            log_success "$TOOL_NAME installed via official script"
            return 0
        else
            log_warn "Official script failed, trying next method..."
        fi
    fi
    
    # Method 3: Direct binary download (if template provided)
    if [ -n "$BINARY_URL_TEMPLATE" ]; then
        log_info "Method 3: Trying direct binary download..."
        
        local ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l) ARCH="arm" ;;
        esac
        
        local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        local BINARY_URL=$(echo "$BINARY_URL_TEMPLATE" | sed "s/\${VERSION}/$VERSION/g" | sed "s/\${ARCH}/$ARCH/g" | sed "s/\${OS}/$OS/g")
        
        if curl -fsSL "$BINARY_URL" -o "/tmp/${TOOL_NAME}.tar.gz"; then
            tar -zxvf "/tmp/${TOOL_NAME}.tar.gz" -C /tmp
            # Find the binary (might be in subdirectory)
            find /tmp -name "$TOOL_NAME" -type f -executable -exec mv {} /usr/local/bin/ \;
            chmod +x "/usr/local/bin/$TOOL_NAME"
            rm -rf "/tmp/${TOOL_NAME}.tar.gz" /tmp/${OS}-${ARCH}
            log_success "$TOOL_NAME installed via direct binary download"
            return 0
        else
            log_error "Direct binary download failed"
        fi
    fi
    
    # All methods failed
    log_error "CRITICAL: All $TOOL_NAME installation methods failed!"
    return 1
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
        log_warn "This script is tested on Ubuntu 24.04 LTS"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check Tailscale
    if ! command -v tailscale &> /dev/null; then
        log_error "Tailscale not found. Please install Tailscale first:"
        log_error "  curl -fsSL https://tailscale.com/install.sh | sh"
        exit 1
    fi
    
    if [ -z "$TAILSCALE_IP" ]; then
        log_error "Tailscale is not connected. Please run: sudo tailscale up"
        exit 1
    fi
    
    log_success "Tailscale IP: $TAILSCALE_IP"
    
    # Check disk space (at least 50GB free)
    AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
    if [ "$AVAILABLE_SPACE" -lt 52428800 ]; then  # 50GB in KB
        log_warn "Less than 50GB free disk space available"
    fi
    
    log_success "Prerequisites check passed"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        open-iscsi \
        nfs-common \
        util-linux \
        ufw \
        fail2ban
    
    # Enable and start iSCSI (required for Longhorn)
    systemctl enable --now iscsid
    
    log_success "Dependencies installed"
}

configure_firewall() {
    log_info "Configuring firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH (critical - don't lock yourself out!)
    ufw allow 22/tcp comment 'SSH'
    
    # Allow full access on Tailscale interface
    ufw allow in on tailscale0 comment 'Tailscale mesh network'
    
    # Allow K3s API server (only from Tailscale)
    # Note: K3s already binds to Tailscale IP
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Enable fail2ban for SSH brute force protection
    systemctl enable --now fail2ban
    
    log_success "Firewall configured (UFW enabled, Tailscale allowed)"
    log_warn "SSH and Tailscale traffic allowed. All other incoming traffic blocked."
}

install_k3s() {
    log_info "Installing K3s server..."
    
    # Prepare K3s configuration
    mkdir -p /etc/rancher/k3s
    
    cat > /etc/rancher/k3s/config.yaml <<EOF
cluster-init: true
write-kubeconfig-mode: "0600"
node-name: "$NODE_NAME"
node-ip: "$TAILSCALE_IP"
flannel-iface: tailscale0
tls-san:
  - "$TAILSCALE_IP"
  - "$NODE_NAME"
  - "127.0.0.1"
disable:
  - traefik  # We'll install Traefik separately with custom config
  - servicelb  # We'll use MetalLB
disable-cloud-controller: true
kubelet-arg:
  - "max-pods=250"
EOF
    
    # Install K3s
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
    
    # Wait for K3s to be ready
    log_info "Waiting for K3s to be ready..."
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    # Wait for THIS node to register (can take 10-30 seconds)
    log_info "Waiting for node '$NODE_NAME' to register with Kubernetes..."
    WAIT_COUNT=0
    until kubectl get node "$NODE_NAME" &> /dev/null; do
        sleep 3
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -gt 20 ]; then
            log_error "Node $NODE_NAME did not register after 60 seconds"
            log_info "Current nodes:"
            kubectl get nodes
            exit 1
        fi
        echo -n "."
    done
    echo ""
    log_success "Node $NODE_NAME is registered!"
    
    # Label this node as control plane and worker
    kubectl label node "$NODE_NAME" node-role.kubernetes.io/worker=true --overwrite
    kubectl label node "$NODE_NAME" mynodeone.io/location=${NODE_LOCATION:-unknown} --overwrite
    kubectl label node "$NODE_NAME" mynodeone.io/storage=true --overwrite
    
    log_success "K3s installed successfully"
    
    # Save kubeconfig for regular user
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
            mkdir -p "$USER_HOME/.kube"
            cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
            chmod 600 "$USER_HOME/.kube/config"
            chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
            log_success "Kubeconfig saved to $USER_HOME/.kube/config"
        fi
    fi
}

install_helm() {
    # Helm installation with multiple failsafe methods
    # 1. Snap (if available)
    # 2. Official get-helm-3 script (RECOMMENDED)
    # 3. Direct binary download (ultimate fallback)
    
    log_info "Installing Helm with failsafe methods..."
    
    # Check if already installed
    if command -v helm &> /dev/null; then
        HELM_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
        log_warn "Helm already installed ($HELM_VERSION), skipping..."
        return 0
    fi
    
    local success=false
    
    # Method 1: Try snap (if available)
    if command -v snap &> /dev/null; then
        log_info "Method 1: Trying snap installation..."
        if snap install helm --classic 2>/dev/null; then
            log_success "Helm installed via snap"
            success=true
        else
            log_warn "Snap installation failed, trying next method..."
        fi
    fi
    
    # Method 2: Official get-helm-3 script (RECOMMENDED)
    if [ "$success" = false ]; then
        log_info "Method 2: Trying official Helm installation script..."
        if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null; then
            log_success "Helm installed via official script"
            success=true
        else
            log_warn "Official script failed, trying next method..."
        fi
    fi
    
    # Method 3: Direct binary download (ultimate fallback)
    if [ "$success" = false ]; then
        log_info "Method 3: Trying direct binary download..."
        
        local HELM_VERSION="v3.13.3"
        local ARCH=$(uname -m)
        
        case $ARCH in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l) ARCH="arm" ;;
        esac
        
        local HELM_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
        
        if curl -fsSL "$HELM_URL" -o /tmp/helm.tar.gz 2>/dev/null; then
            tar -zxf /tmp/helm.tar.gz -C /tmp 2>/dev/null
            mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
            chmod +x /usr/local/bin/helm
            rm -rf /tmp/helm.tar.gz /tmp/linux-${ARCH}
            log_success "Helm installed via direct binary download"
            success=true
        else
            log_error "Direct binary download failed"
        fi
    fi
    
    # Check final result
    if [ "$success" = false ]; then
        log_error "CRITICAL: All Helm installation methods failed!"
        log_error "Attempted methods:"
        log_error "  1. Snap (if available)"
        log_error "  2. Official get-helm-3 script"
        log_error "  3. Direct binary download"
        echo
        log_error "Please install Helm manually:"
        log_error "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
        echo
        return 1
    fi
    
    # Verify installation
    if command -v helm &> /dev/null; then
        local INSTALLED_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
        log_success "Helm successfully installed: $INSTALLED_VERSION"
        return 0
    else
        log_error "Helm installation verification failed"
        return 1
    fi
}

install_cert_manager() {
    log_info "Installing cert-manager..."
    
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version v1.13.3 \
        --set installCRDs=true \
        --wait
    
    log_success "cert-manager installed"
}

install_longhorn() {
    log_info "Installing Longhorn storage..."
    
    # Install Longhorn dependencies
    apt-get install -y open-iscsi util-linux
    systemctl enable --now iscsid
    
    # Create Longhorn namespace
    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Longhorn
    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    
    # Set default LONGHORN_PATH if not defined
    LONGHORN_PATH="${LONGHORN_PATH:-/mnt/longhorn-disks}"
    
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version 1.5.3 \
        --set defaultSettings.defaultReplicaCount=1 \
        --set defaultSettings.defaultDataPath="${LONGHORN_PATH}" \
        --wait
    
    # Set Longhorn as default storage class
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    log_success "Longhorn installed"
    log_info "Longhorn UI will be available at: http://$TAILSCALE_IP:30080 (via NodePort)"
}

install_metallb() {
    log_info "Installing MetalLB load balancer..."
    
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add metallb https://metallb.github.io/metallb
    helm repo update
    
    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --wait
    
    # Configure IP address pool (using Tailscale subnet)
    TAILSCALE_SUBNET=$(echo "$TAILSCALE_IP" | cut -d. -f1-3)
    
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: metallb-system
spec:
  addresses:
  - ${TAILSCALE_SUBNET}.200-${TAILSCALE_SUBNET}.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tailscale-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - tailscale-pool
EOF
    
    log_success "MetalLB installed"
}

install_traefik() {
    log_info "Installing Traefik ingress controller..."
    
    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        --version 26.0.0 \
        --set ports.web.port=80 \
        --set ports.websecure.port=443 \
        --set ports.websecure.tls.enabled=true \
        --set service.type=LoadBalancer \
        --wait
    
    log_success "Traefik installed"
}

install_minio() {
    log_info "Installing MinIO object storage..."
    
    kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
    
    # Generate strong random credentials
    MINIO_ROOT_USER="admin"
    MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)
    
    # Create secret
    kubectl create secret generic minio-credentials \
        --from-literal=rootUser="$MINIO_ROOT_USER" \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
        --namespace minio \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Install MinIO
    helm repo add minio https://charts.min.io/
    helm repo update
    
    # Set default storage size if not defined
    MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-100Gi}"
    
    helm upgrade --install minio minio/minio \
        --namespace minio \
        --set rootUser="$MINIO_ROOT_USER" \
        --set rootPassword="$MINIO_ROOT_PASSWORD" \
        --set mode=standalone \
        --set replicas=1 \
        --set persistence.enabled=true \
        --set persistence.size="${MINIO_STORAGE_SIZE}" \
        --set persistence.storageClass=longhorn \
        --set service.type=LoadBalancer \
        --set consoleService.type=LoadBalancer \
        --wait
    
    # Save credentials securely
    cat > /root/mynodeone-minio-credentials.txt <<EOF
MinIO Credentials
=================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
Endpoint: http://$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9000
Console: http://$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9001

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/mynodeone-minio-credentials.txt
    
    log_success "MinIO installed"
    log_warn "MinIO credentials saved to /root/mynodeone-minio-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

install_monitoring() {
    log_info "Installing monitoring stack (Prometheus, Grafana, Loki)..."
    
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Install kube-prometheus-stack (Prometheus + Grafana)
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --version 55.5.0 \
        --set prometheus.prometheusSpec.retention=30d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi \
        --set grafana.adminPassword="$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)" \
        --set grafana.service.type=LoadBalancer \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.storageClassName=longhorn \
        --set grafana.persistence.size=10Gi \
        --wait
    
    # Install Loki for logs
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    helm upgrade --install loki grafana/loki-stack \
        --namespace monitoring \
        --version 2.10.1 \
        --set loki.persistence.enabled=true \
        --set loki.persistence.storageClassName=longhorn \
        --set loki.persistence.size=100Gi \
        --set promtail.enabled=true \
        --wait
    
    # Get generated Grafana password from secret
    sleep 5
    GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
    
    # Save Grafana credentials securely
    cat > /root/mynodeone-grafana-credentials.txt <<EOF
Grafana Credentials
===================
Username: admin
Password: $GRAFANA_PASSWORD
URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/mynodeone-grafana-credentials.txt
    
    log_success "Monitoring stack installed"
    log_warn "Grafana credentials saved to /root/mynodeone-grafana-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

install_argocd() {
    log_info "Installing ArgoCD for GitOps..."
    
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Install ArgoCD
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.3/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    
    # Expose ArgoCD with LoadBalancer
    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
    
    # Get initial admin password
    ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    # Save credentials securely
    cat > /root/mynodeone-argocd-credentials.txt <<EOF
ArgoCD Credentials
==================
Username: admin
Password: $ARGOCD_PASSWORD
URL: https://$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/mynodeone-argocd-credentials.txt
    
    log_success "ArgoCD installed"
    log_warn "ArgoCD credentials saved to /root/mynodeone-argocd-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

create_cluster_token() {
    log_info "Generating node join token..."
    
    # K3s token for joining worker nodes
    TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    
    cat > /root/mynodeone-join-token.txt <<EOF
MyNodeOne Cluster Join Configuration
====================================
Server URL: https://$TAILSCALE_IP:6443
Token: $TOKEN

To join a worker node, run:
curl -sfL https://get.k3s.io | K3S_URL=https://$TAILSCALE_IP:6443 K3S_TOKEN=$TOKEN sh -

Or use the add-worker-node.sh script (recommended)

WARNING: This token grants access to join nodes to your cluster. Store securely!
EOF
    chmod 600 /root/mynodeone-join-token.txt
    
    log_success "Join token saved to /root/mynodeone-join-token.txt (chmod 600)"
    log_warn "IMPORTANT: This token grants cluster access. Store securely!"
}

display_credentials() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 IMPORTANT: YOUR SERVICE CREDENTIALS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "⚠️  SAVE THESE CREDENTIALS NOW - They won't be shown again!"
    echo
    
    # Get IPs
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    LONGHORN_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "$TAILSCALE_IP:30080")
    
    # Get passwords
    GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "See file below")
    
    echo "📊 GRAFANA (Monitoring Dashboard):"
    echo "   URL: http://$GRAFANA_IP"
    echo "   Username: admin"
    echo "   Password: $GRAFANA_PASS"
    echo
    
    echo "🚀 ARGOCD (GitOps):"
    echo "   URL: https://$ARGOCD_IP"
    if [ -f /root/mynodeone-argocd-credentials.txt ]; then
        cat /root/mynodeone-argocd-credentials.txt | grep -E "Username|Password" | sed 's/^/   /'
    fi
    echo
    
    echo "💾 MINIO (S3 Storage):"
    echo "   Console: http://$MINIO_CONSOLE_IP:9001"
    if [ -f /root/mynodeone-minio-credentials.txt ]; then
        cat /root/mynodeone-minio-credentials.txt | grep -E "Username|Password" | sed 's/^/   /'
    fi
    echo
    
    echo "📦 LONGHORN (Storage Dashboard):"
    echo "   URL: http://$LONGHORN_IP"
    echo "   Authentication: None (protected by Tailscale VPN)"
    echo
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📝 CRITICAL SECURITY STEP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "⚠️  IMPORTANT: Save these credentials NOW!"
    echo
    echo "🔐 SAVE TO PASSWORD MANAGER:"
    echo "   Install on YOUR LAPTOP (not this machine):"
    echo "   • 1Password (https://1password.com) - Paid, best UX"
    echo "   • Bitwarden (https://bitwarden.com) - Free & Open Source"
    echo "   • KeePassXC (https://keepassxc.org) - Free, Offline"
    echo
    echo "📋 ACTION: Copy ALL credentials above to your password manager NOW"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # In unattended mode, don't prompt - just wait briefly
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_warn "UNATTENDED mode: Credentials displayed above. Save them before they're deleted!"
        sleep 10
        delete_credential_files
    else
        echo
        echo "⏱️  Take your time to save the credentials above."
        echo
        read -p "Have you saved ALL credentials to your password manager? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            delete_credential_files
        else
            echo
            log_error "Installation cannot proceed without confirming credential storage!"
            log_error "For security, credential files MUST be deleted."
            echo
            echo "Options:"
            echo "  1. Save credentials now and re-run this confirmation"
            echo "  2. View credentials again: sudo $SCRIPT_DIR/show-credentials.sh"
            echo "  3. Credentials are in: /root/mynodeone-*-credentials.txt"
            echo
            read -p "Try again - Have you saved credentials? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                delete_credential_files
            else
                log_error "Please save credentials and manually delete files:"
                echo "  sudo rm /root/mynodeone-*-credentials.txt"
                echo
                log_warn "WARNING: Leaving credential files on disk is a security risk!"
                return 1
            fi
        fi
    fi
    
    echo
    echo "📖 Next steps:"
    echo "   • Change default passwords (first login to each service)"
    echo "   • Full security guide: cat $PROJECT_ROOT/SECURITY_CREDENTIALS_GUIDE.md"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

delete_credential_files() {
    log_info "Securely deleting credential files..."
    
    local files_deleted=0
    
    if [ -f /root/mynodeone-argocd-credentials.txt ]; then
        shred -vfz -n 3 /root/mynodeone-argocd-credentials.txt 2>/dev/null || rm -f /root/mynodeone-argocd-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    if [ -f /root/mynodeone-minio-credentials.txt ]; then
        shred -vfz -n 3 /root/mynodeone-minio-credentials.txt 2>/dev/null || rm -f /root/mynodeone-minio-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    if [ -f /root/mynodeone-grafana-credentials.txt ]; then
        shred -vfz -n 3 /root/mynodeone-grafana-credentials.txt 2>/dev/null || rm -f /root/mynodeone-grafana-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    # Keep join token as it's needed for adding nodes
    # Don't delete: /root/mynodeone-join-token.txt
    
    if [ $files_deleted -gt 0 ]; then
        log_success "✅ Credential files securely deleted ($files_deleted files)"
        log_info "Join token kept at: /root/mynodeone-join-token.txt (needed for adding nodes)"
    else
        log_warn "No credential files found to delete"
    fi
}

print_summary() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🎉 MyNodeOne Control Plane Installed Successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Installed Components:"
    echo "  ✓ K3s Kubernetes"
    echo "  ✓ Helm"
    echo "  ✓ cert-manager (Certificate Management)"
    echo "  ✓ MetalLB (Load Balancer)"
    echo "  ✓ Traefik (Ingress Controller)"
    echo "  ✓ Longhorn (Distributed Storage)"
    echo "  ✓ MinIO (Object Storage)"
    echo "  ✓ Prometheus + Grafana + Loki (Monitoring)"
    echo "  ✓ ArgoCD (GitOps)"
    echo
    
    # Display credentials prominently
    display_credentials
    
    echo
    echo "📄 What To Do Next:"
    echo "  🎯 READ THIS FIRST: $PROJECT_ROOT/POST_INSTALLATION_GUIDE.md"
    echo "  • Shows exactly what to do after installation"
    echo "  • How to access from your laptop"
    echo "  • Deploying your first app"
    echo "  • Monitoring and managing the cluster"
    echo
    echo "📄 Additional Resources:"
    echo "  • View credentials anytime: sudo $SCRIPT_DIR/show-credentials.sh"
    echo "  • Demo app guide: $PROJECT_ROOT/DEMO_APP_GUIDE.md"
    echo "  • Deploy apps easily: $PROJECT_ROOT/APP_DEPLOYMENT_GUIDE.md"
    echo "  • Security guide: $PROJECT_ROOT/SECURITY_CREDENTIALS_GUIDE.md"
    echo "  • Quick reference: $PROJECT_ROOT/ACCESS_INFORMATION.md"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "🎯 WHAT TO DO NEXT:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Your control plane is running! Here's what to do next:"
    echo
    
    # Show VPS setup if configured
    if [ "${VPS_COUNT:-0}" -gt 0 ]; then
        echo "📡 STEP 1: Configure Your VPS Edge Node(s)"
        echo "   You said you have $VPS_COUNT VPS node(s) for public internet access."
        echo
        echo "   On EACH VPS machine, run:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ cd ~/MyNodeOne                                              │"
        echo "   │ sudo ./scripts/mynodeone                                    │"
        echo "   │ # Select 'VPS Edge Node' when asked                        │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
        echo "   This will:"
        echo "     • Install Tailscale and join your VPN"
        echo "     • Set up reverse proxy (Caddy with auto-HTTPS)"
        echo "     • Configure domains for public access"
        echo
    fi
    
    echo "📊 STEP ${VPS_COUNT:+2}: Verify Your Cluster is Healthy"
    echo "   Check that all components are running:"
    echo "   ┌─────────────────────────────────────────────────────────────┐"
    echo "   │ kubectl get nodes                                           │"
    echo "   │ kubectl get pods -A                                         │"
    echo "   └─────────────────────────────────────────────────────────────┘"
    echo
    echo "   All pods should be 'Running' or 'Completed' within 5-10 minutes."
    echo
    
    echo "🌐 STEP ${VPS_COUNT:+3}: Access Web Dashboards"
    echo "   These are available via Tailscale (100.x.x.x addresses):"
    echo
    echo "   📊 Grafana (Metrics & Logs):"
    echo "      URL: http://$GRAFANA_IP"
    echo "      Username: admin"
    echo "      Password: Run this command to get it:"
    echo "      kubectl get secret -n monitoring kube-prometheus-stack-grafana \\"
    echo "        -o jsonpath=\"{.data.admin-password}\" | base64 -d && echo"
    echo
    echo "   🚀 ArgoCD (GitOps Deployments):"
    echo "      URL: https://$ARGOCD_IP"
    echo "      Credentials: cat /root/mynodeone-argocd-credentials.txt"
    echo
    echo "   💾 MinIO Console (S3 Storage):"
    echo "      URL: http://$MINIO_CONSOLE_IP:9001"
    echo "      Credentials: cat /root/mynodeone-minio-credentials.txt"
    echo
    echo "   📦 Longhorn UI (Block Storage):"
    echo "      URL: http://$LONGHORN_IP"
    echo "      (No authentication required - protected by Tailscale VPN)"
    echo
    echo "   📘 For complete access information, see:"
    echo "      cat $PROJECT_ROOT/ACCESS_INFORMATION.md"
    echo
    
    echo "🚀 STEP ${VPS_COUNT:+4}: Deploy Your First Application"
    echo "   Example: Deploy a test web app"
    echo "   ┌─────────────────────────────────────────────────────────────┐"
    echo "   │ # Create a simple nginx deployment                          │"
    echo "   │ kubectl create deployment nginx --image=nginx               │"
    echo "   │ kubectl expose deployment nginx --port=80 --type=LoadBalancer│"
    echo "   │                                                              │"
    echo "   │ # Check the external IP assigned                            │"
    echo "   │ kubectl get svc nginx                                       │"
    echo "   │                                                              │"
    echo "   │ # Access via browser: http://<EXTERNAL-IP>                  │"
    echo "   └─────────────────────────────────────────────────────────────┘"
    echo
    
    # Show LLM-specific guidance if enabled
    if [ "${RUN_LLMS:-false}" = "true" ]; then
        echo "🤖 BONUS: Run LLMs (You enabled AI support!)"
        echo "   Deploy Ollama for local LLM hosting:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ # Install Ollama on Kubernetes                              │"
        echo "   │ kubectl create namespace ollama                             │"
        echo "   │ # See: docs/ollama-deployment.md for full guide             │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
    fi
    
    # Show database guidance if enabled
    if [ "${RUN_DATABASES:-false}" = "true" ]; then
        echo "🗄️  BONUS: Deploy Databases (You enabled database support!)"
        echo "   Easy database deployment with operators:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ # PostgreSQL example                                        │"
        echo "   │ kubectl create namespace postgres                           │"
        echo "   │ # See: docs/database-examples.md for guides                 │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
    fi
    
    echo "📚 MORE RESOURCES:"
    echo "   • Getting Started Guide: $PROJECT_ROOT/GETTING-STARTED.md"
    echo "   • Operations Guide: $PROJECT_ROOT/docs/operations.md"
    echo "   • FAQ: $PROJECT_ROOT/FAQ.md"
    echo "   • Troubleshooting: $PROJECT_ROOT/docs/troubleshooting.md"
    echo
    echo "💡 HELPFUL COMMANDS:"
    echo "   kubectl get all -A              # See everything"
    echo "   kubectl logs -n <ns> <pod>      # View pod logs"
    echo "   kubectl describe node <name>    # Node details"
    echo "   k9s                              # Terminal UI (if installed)"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "🎉 CONGRATULATIONS! Your MyNodeOne cluster is ready!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

offer_security_hardening() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔒 Recommended: Enable Security Hardening"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to enable additional security features?"
    echo
    echo "This will configure:"
    echo "  ✅ Secrets encryption at rest (encrypts passwords in etcd)"
    echo "  ✅ Enhanced audit logging"
    echo "  ✅ Pod Security Standards (restrict unsafe containers)"
    echo
    echo "⚠️  Note: This will restart K3s once (takes ~30 seconds)"
    echo
    echo "Recommended: YES for production, OPTIONAL for testing"
    echo
    
    # Skip prompt in unattended mode - auto-enable for production
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Auto-enabling security hardening"
        bash "$SCRIPT_DIR/enable-security-hardening.sh"
        return
    fi
    
    read -p "Enable security hardening? [Y/n]: " -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo
        log_info "Enabling security hardening..."
        if bash "$SCRIPT_DIR/enable-security-hardening.sh"; then
            log_success "Security hardening enabled!"
            echo
            echo "✅ Secrets are now encrypted at rest"
            echo "✅ Pod Security Standards enforced"
            echo "✅ Enhanced audit logging active"
        else
            log_warn "Security hardening had issues. You can enable it later with:"
            echo "  sudo $SCRIPT_DIR/enable-security-hardening.sh"
        fi
    else
        echo
        log_info "Skipping security hardening. You can enable it anytime with:"
        echo "  sudo $SCRIPT_DIR/enable-security-hardening.sh"
        echo
        log_warn "⚠️  Without encryption, secrets are stored as base64 (not encrypted)"
    fi
}

offer_local_dns() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Optional: Setup Local DNS (.local domains)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to set up easy-to-remember domain names?"
    echo
    echo "Instead of IP addresses (e.g., http://100.118.5.203), you can use:"
    echo "  • http://grafana.mynodeone.local"
    echo "  • http://argocd.mynodeone.local"
    echo "  • http://minio.mynodeone.local"
    echo
    echo "This also creates a setup script for your laptop!"
    echo
    echo "Recommended: YES (makes services easier to access)"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Setting up local DNS automatically"
        bash "$SCRIPT_DIR/setup-local-dns.sh"
        return
    fi
    
    read -p "Set up local DNS? [Y/n]: " -r
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo
        log_info "Setting up local DNS..."
        if bash "$SCRIPT_DIR/setup-local-dns.sh"; then
            log_success "Local DNS setup complete!"
            echo
            echo "✅ You can now use .local domain names"
            echo "📄 Laptop setup script created: $PROJECT_ROOT/setup-client-dns.sh"
        else
            log_warn "Local DNS setup had issues. You can set it up later with:"
            echo "  sudo $SCRIPT_DIR/setup-local-dns.sh"
        fi
    else
        echo
        log_info "Skipping local DNS. You can set it up anytime with:"
        echo "  sudo $SCRIPT_DIR/setup-local-dns.sh"
    fi
}

offer_demo_app() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🚀 Optional: Deploy Demo Application"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy a demo web application to test your cluster?"
    echo
    echo "This will deploy a secure demo app that showcases:"
    echo "  • Proper Pod Security Standards compliance"
    echo "  • LoadBalancer service integration"
    echo "  • Working storage and networking"
    echo
    echo "You can remove it anytime with: kubectl delete namespace demo-apps"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping demo app deployment"
        return
    fi
    
    read -p "Deploy demo app now? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying demo application..."
        if bash "$SCRIPT_DIR/deploy-demo-app.sh" deploy; then
            log_success "Demo app deployment complete!"
        else
            log_warn "Demo app deployment had issues. You can deploy it later with:"
            echo "  sudo $SCRIPT_DIR/deploy-demo-app.sh"
        fi
    else
        echo
        log_info "Skipping demo app. You can deploy it anytime with:"
        echo "  sudo $SCRIPT_DIR/deploy-demo-app.sh"
    fi
}

offer_llm_chat() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🤖 Optional: Deploy LLM Chat Application"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy a local AI chat application?"
    echo
    echo "This deploys Open WebUI + Ollama for:"
    echo "  • 100% local AI chat (no cloud API needed)"
    echo "  • Your data stays on your cluster"
    echo "  • ChatGPT-like interface"
    echo "  • Multiple LLM models available"
    echo
    echo "Requirements: 4GB+ RAM available, 50GB+ storage"
    echo
    echo "You can remove it anytime with: kubectl delete namespace llm-chat"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping LLM chat deployment"
        return
    fi
    
    read -p "Deploy LLM chat app now? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying LLM chat application..."
        if bash "$SCRIPT_DIR/deploy-llm-chat.sh"; then
            log_success "LLM chat deployment complete!"
        else
            log_warn "LLM chat deployment had issues. You can deploy it later with:"
            echo "  sudo $SCRIPT_DIR/deploy-llm-chat.sh"
        fi
    else
        echo
        log_info "Skipping LLM chat. You can deploy it anytime with:"
        echo "  sudo $SCRIPT_DIR/deploy-llm-chat.sh"
    fi
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne Control Plane Bootstrap"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    install_dependencies
    configure_firewall
    install_k3s
    install_helm
    install_cert_manager
    install_metallb
    install_traefik
    install_longhorn
    install_minio
    install_monitoring
    install_argocd
    create_cluster_token
    
    echo
    print_summary
    
    # Offer security hardening
    offer_security_hardening
    
    # Offer local DNS setup
    offer_local_dns
    
    # Offer to deploy demo app
    offer_demo_app
    
    # Offer to deploy LLM chat app
    offer_llm_chat
}

# Run main function
main "$@"
