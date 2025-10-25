#!/bin/bash

###############################################################################
# NodeZero Control Plane Bootstrap Script
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

# Load configuration
CONFIG_FILE="$HOME/.nodezero/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# K3s version
K3S_VERSION="v1.28.5+k3s1"

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
    
    # Label this node as control plane and worker
    kubectl label node "$NODE_NAME" node-role.kubernetes.io/worker=true --overwrite
    kubectl label node "$NODE_NAME" nodezero.io/location=toronto --overwrite
    kubectl label node "$NODE_NAME" nodezero.io/storage=true --overwrite
    
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
    log_info "Installing Helm..."
    
    if command -v helm &> /dev/null; then
        log_warn "Helm already installed, skipping..."
        return
    fi
    
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_success "Helm installed"
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
    cat > /root/nodezero-minio-credentials.txt <<EOF
MinIO Credentials
=================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
Endpoint: http://$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9000
Console: http://$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9001

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/nodezero-minio-credentials.txt
    
    log_success "MinIO installed"
    log_warn "MinIO credentials saved to /root/nodezero-minio-credentials.txt (chmod 600)"
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
    cat > /root/nodezero-grafana-credentials.txt <<EOF
Grafana Credentials
===================
Username: admin
Password: $GRAFANA_PASSWORD
URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/nodezero-grafana-credentials.txt
    
    log_success "Monitoring stack installed"
    log_warn "Grafana credentials saved to /root/nodezero-grafana-credentials.txt (chmod 600)"
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
    cat > /root/nodezero-argocd-credentials.txt <<EOF
ArgoCD Credentials
==================
Username: admin
Password: $ARGOCD_PASSWORD
URL: https://$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 /root/nodezero-argocd-credentials.txt
    
    log_success "ArgoCD installed"
    log_warn "ArgoCD credentials saved to /root/nodezero-argocd-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

create_cluster_token() {
    log_info "Generating node join token..."
    
    # K3s token for joining worker nodes
    TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    
    cat > /root/nodezero-join-token.txt <<EOF
NodeZero Cluster Join Configuration
====================================
Server URL: https://$TAILSCALE_IP:6443
Token: $TOKEN

To join a worker node, run:
curl -sfL https://get.k3s.io | K3S_URL=https://$TAILSCALE_IP:6443 K3S_TOKEN=$TOKEN sh -

Or use the add-worker-node.sh script (recommended)

WARNING: This token grants access to join nodes to your cluster. Store securely!
EOF
    chmod 600 /root/nodezero-join-token.txt
    
    log_success "Join token saved to /root/nodezero-join-token.txt (chmod 600)"
    log_warn "IMPORTANT: This token grants cluster access. Store securely!"
}

print_summary() {
    log_success "NodeZero control plane bootstrap complete! 🎉"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NodeZero Control Plane Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Cluster Information:"
    echo "  Name: $CLUSTER_NAME"
    echo "  Node: $NODE_NAME"
    echo "  IP: $TAILSCALE_IP"
    echo
    echo "Installed Components:"
    echo "  ✓ K3s (Kubernetes)"
    echo "  ✓ Helm"
    echo "  ✓ cert-manager"
    echo "  ✓ Traefik (Ingress)"
    echo "  ✓ MetalLB (Load Balancer)"
    echo "  ✓ Longhorn (Block Storage)"
    echo "  ✓ MinIO (Object Storage)"
    echo "  ✓ Prometheus + Grafana + Loki (Monitoring)"
    echo "  ✓ ArgoCD (GitOps)"
    echo
    echo "Access Points (via Tailscale):"
    
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending...")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending...")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending...")
    
    echo "  Grafana: http://$GRAFANA_IP (admin/admin)"
    echo "  ArgoCD: https://$ARGOCD_IP (see /root/nodezero-argocd-credentials.txt)"
    echo "  MinIO Console: http://$MINIO_CONSOLE_IP (see /root/nodezero-minio-credentials.txt)"
    echo "  Longhorn: http://$TAILSCALE_IP:30080"
    echo
    echo "Important Files:"
    echo "  Kubeconfig: ~/.kube/config"
    echo "  Join Token: /root/nodezero-join-token.txt"
    echo "  ArgoCD Credentials: /root/nodezero-argocd-credentials.txt"
    echo "  MinIO Credentials: /root/nodezero-minio-credentials.txt"
    echo
    echo "Next Steps:"
    echo "  1. Add worker nodes: sudo ./scripts/add-worker-node.sh"
    echo "  2. Configure VPS edge nodes: sudo ./scripts/setup-edge-node.sh"
    echo "  3. Deploy your first app: ./scripts/create-app.sh my-app"
    echo
    echo "Check cluster status: kubectl get nodes,pods -A"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NodeZero Control Plane Bootstrap"
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
}

# Run main function
main "$@"
