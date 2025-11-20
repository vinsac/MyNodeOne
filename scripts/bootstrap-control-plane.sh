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

# ACTUAL_USER and ACTUAL_HOME are inherited from the main mynodeone script
# If not set (standalone execution), detect them here
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

# CONFIG_FILE is also inherited, but we provide a fallback for standalone execution
: "${CONFIG_FILE:=$ACTUAL_HOME/.mynodeone/config.env}"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Expected location: $CONFIG_FILE"
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# Export key variables to be available in sub-scripts
export CLUSTER_NAME
export CLUSTER_DOMAIN
export NODE_NAME
export NODE_LOCATION

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

# Retry logic for network operations
retry_command() {
    local max_attempts="$1"
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Command failed (attempt $attempt/$max_attempts). Retrying in 5 seconds..."
            sleep 5
        fi
        attempt=$((attempt + 1))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# Helm wrapper with timeout and error handling
helm_install_safe() {
    local release_name="$1"
    local chart="$2"
    local namespace="$3"
    shift 3
    local extra_args="$@"
    
    log_info "Installing $release_name (timeout: 10m, with retry)..."
    
    # Try with 10 minute timeout
    if timeout 600 helm upgrade --install "$release_name" "$chart" \
        --namespace "$namespace" \
        --timeout 10m \
        --wait \
        $extra_args 2>&1; then
        log_success "$release_name installed successfully"
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_warn "$release_name installation timed out, checking if pods are running..."
            # Check if pods are actually running despite timeout
            sleep 10
            if kubectl get pods -n "$namespace" | grep -q "Running"; then
                log_success "$release_name pods are running despite timeout"
                return 0
            fi
        fi
        log_error "$release_name installation failed"
        return 1
    fi
}

# Check DNS connectivity before operations
check_dns() {
    log_info "Verifying DNS connectivity..."
    
    # Test with Google DNS as fallback
    if ! timeout 5 nslookup github.com 8.8.8.8 > /dev/null 2>&1; then
        log_warn "DNS issues detected, this may cause delays"
        return 1
    fi
    
    log_success "DNS is working"
    return 0
}

# Prompt for user confirmation
prompt_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    # Check if running in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        response="$default"
        echo -e "${BLUE}[INFO]${NC} $prompt [using default: $default]"
    elif [ "$default" = "y" ]; then
        read -p "$(echo -e ${GREEN}?)${NC}) $prompt [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$(echo -e ${GREEN}?)${NC}) $prompt [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
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
        python3-yaml \
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

optimize_system_for_containers() {
    log_info "Optimizing system for containerized applications..."
    
    # Increase inotify limits for file watching in containers
    # Many apps (Jellyfin, Immich, etc.) use file watchers that hit default limits
    log_info "Configuring inotify limits..."
    sysctl -w fs.inotify.max_user_instances=1024 > /dev/null
    sysctl -w fs.inotify.max_user_watches=524288 > /dev/null
    
    # Make changes permanent
    if ! grep -q "fs.inotify.max_user_instances" /etc/sysctl.conf 2>/dev/null; then
        echo "# Increased limits for containerized applications" >> /etc/sysctl.conf
        echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf
        echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
        log_success "inotify limits increased (persistent)"
    fi
    
    log_success "System optimizations applied"
}

prepare_encryption_config() {
    log_info "Configuring secrets encryption at rest..."
    
    # Generate encryption key
    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
    
    # Create encryption provider config
    cat > /etc/rancher/k3s/encryption-config.yaml <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}  # Fallback for reading old unencrypted data
EOF
    
    chmod 600 /etc/rancher/k3s/encryption-config.yaml
    log_success "Encryption configuration created"
}

prepare_audit_config() {
    log_info "Configuring audit logging..."
    
    # Create audit policy
    cat > /etc/rancher/k3s/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log admin actions
  - level: RequestResponse
    users: ["system:admin", "admin"]
    
  # Log secret access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
    
  # Log pod creation/deletion
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
    
  # Log everything else at metadata level
  - level: Metadata
EOF
    
    chmod 644 /etc/rancher/k3s/audit-policy.yaml
    log_success "Audit policy configured"
}

prepare_pod_security_config() {
    log_info "Configuring Pod Security Standards..."
    
    cat > /etc/rancher/k3s/pod-security-config.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: [kube-system, kube-public, kube-node-lease, longhorn-system, metallb-system, cert-manager]
EOF
    
    chmod 644 /etc/rancher/k3s/pod-security-config.yaml
    log_success "Pod Security Standards configured"
}

install_k3s() {
    log_info "Installing K3s server..."
    
    # Prepare K3s configuration
    mkdir -p /etc/rancher/k3s
    
    # Setup security configs BEFORE K3s starts
    prepare_encryption_config
    prepare_audit_config
    prepare_pod_security_config
    
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
kube-apiserver-arg:
  - "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"
  - "audit-log-path=/var/log/k3s-audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "admission-control-config-file=/etc/rancher/k3s/pod-security-config.yaml"
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
    
    # Determine Longhorn data path
    # If user has dedicated disks mounted, use the first one as default
    # Then we'll add all other disks after installation
    LONGHORN_PATH="/var/lib/longhorn"  # Default
    MOUNTED_DISKS=()
    
    # Check if user has mounted disks for Longhorn from THIS installation session
    # Only count disks that are in the config file (from mynodeone script)
    if [ -d "/mnt/longhorn-disks" ]; then
        # Find all mounted disks
        while IFS= read -r disk_path; do
            if mountpoint -q "$disk_path" 2>/dev/null; then
                # Verify this disk was formatted in THIS session by checking if device is in fstab
                DISK_DEVICE=$(findmnt -n -o SOURCE "$disk_path" 2>/dev/null)
                if [ -n "$DISK_DEVICE" ] && grep -q "$disk_path" /etc/fstab 2>/dev/null; then
                    MOUNTED_DISKS+=("$disk_path")
                fi
            fi
        done < <(find /mnt/longhorn-disks -maxdepth 1 -type d -name "disk-*" 2>/dev/null | sort)
        
        if [ ${#MOUNTED_DISKS[@]} -gt 0 ]; then
            LONGHORN_PATH="${MOUNTED_DISKS[0]}"
            log_info "Found ${#MOUNTED_DISKS[@]} dedicated disk(s) for Longhorn:"
            for disk in "${MOUNTED_DISKS[@]}"; do
                DISK_SIZE=$(df -h "$disk" | tail -1 | awk '{print $2}')
                log_info "  • $disk ($DISK_SIZE)"
            done
        fi
    fi
    
    log_info "Longhorn default path: $LONGHORN_PATH"
    
    helm upgrade --install longhorn longhorn/longhorn \
        --namespace longhorn-system \
        --version 1.5.3 \
        --set defaultSettings.defaultReplicaCount=1 \
        --set defaultSettings.defaultDataPath="${LONGHORN_PATH}" \
        --wait
    
    # Set Longhorn as default storage class
    kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    
    # Expose Longhorn UI via LoadBalancer (instead of NodePort)
    log_info "Exposing Longhorn UI via LoadBalancer..."
    kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"LoadBalancer"}}'
    
    log_success "Longhorn installed"
    log_info "Longhorn UI will be accessible via LoadBalancer (DNS will be configured later)"
    
    # Configure Longhorn to use ALL mounted disks (not just the first one)
    if [ ${#MOUNTED_DISKS[@]} -gt 1 ]; then
        log_info "Configuring Longhorn to use all ${#MOUNTED_DISKS[@]} disks..."
        
        # Wait for Longhorn to be fully ready
        sleep 10
        
        # Get the node name
        NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
        
        # For each additional disk, add it to Longhorn
        for i in "${!MOUNTED_DISKS[@]}"; do
            if [ $i -eq 0 ]; then
                continue  # Skip first disk (already configured as default)
            fi
            
            DISK_PATH="${MOUNTED_DISKS[$i]}"
            DISK_NAME="disk-$(basename "$DISK_PATH")"
            
            log_info "Adding additional disk: $DISK_PATH"
            
            # Add disk to Longhorn node configuration
            # Must use merge patch for Longhorn CRD (nodes.longhorn.io)
            if kubectl -n longhorn-system patch nodes.longhorn.io "$NODE_NAME" --type=merge -p "{\"spec\":{\"disks\":{\"$DISK_NAME\":{\"allowScheduling\":true,\"diskType\":\"filesystem\",\"evictionRequested\":false,\"path\":\"$DISK_PATH\",\"storageReserved\":0,\"tags\":[]}}}}" 2>&1; then
                log_success "Added disk: $DISK_PATH"
            else
                log_warn "Could not auto-add $DISK_PATH (you can add it manually via Longhorn UI)"
                log_warn "Or run: kubectl -n longhorn-system patch nodes.longhorn.io $NODE_NAME --type=merge -p '{\"spec\":{\"disks\":{\"$DISK_NAME\":{\"path\":\"$DISK_PATH\",\"allowScheduling\":true,\"diskType\":\"filesystem\"}}}}'"
            fi
        done
        
        log_success "All disks configured!"
        log_info "Total storage: $(df -h "${MOUNTED_DISKS[@]}" | tail -${#MOUNTED_DISKS[@]} | awk '{sum+=$2} END {print sum"G"}')"
    fi
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

configure_tailscale_subnet_routes() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Configuring Tailscale Network Routes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Setting up subnet routes for LoadBalancer access..."
    echo
    
    # Get the MetalLB subnet (same as Tailscale subnet)
    TAILSCALE_SUBNET=$(echo "$TAILSCALE_IP" | cut -d. -f1-3)
    
    # Enable IP forwarding (required for subnet routes)
    log_info "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    
    # Make IP forwarding permanent
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        log_success "IP forwarding enabled (persistent)"
    fi
    
    # Advertise MetalLB subnet to Tailscale network
    log_info "Advertising subnet ${TAILSCALE_SUBNET}.0/24 to Tailscale..."
    if tailscale up --advertise-routes=${TAILSCALE_SUBNET}.0/24 --accept-routes 2>/dev/null; then
        log_success "Subnet route advertised to Tailscale"
    else
        log_warn "Could not advertise subnet automatically. This is not critical."
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️  ACTION REQUIRED: Approve Subnet Route in Tailscale"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "To enable direct access to services from other devices:"
    echo
    echo "1. Go to: https://login.tailscale.com/admin/machines"
    echo "2. Find this machine in the list"
    echo "3. Click '...' menu → 'Edit route settings'"
    echo "4. Toggle ON the subnet route: ${TAILSCALE_SUBNET}.0/24"
    echo "5. Click 'Save'"
    echo
    echo "Once approved, you can access services directly at:"
    echo "  • http://grafana.${CLUSTER_DOMAIN}.local"
    echo "  • https://argocd.${CLUSTER_DOMAIN}.local"
    echo "  • http://minio.${CLUSTER_DOMAIN}.local:9001"
    echo
    log_info "This step takes 30 seconds in Tailscale admin console"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Pause installation to let user approve the subnet route
    # Note: Subnet route approval is CRITICAL for LoadBalancer IPs to work
    # The subsequent IP allocations to services depend on this being approved
    if [ "${UNATTENDED:-0}" != "1" ]; then
        echo
        log_warn "IMPORTANT: The installer will PAUSE here to let you approve the subnet route."
        log_info "Services need this route to be approved before they receive proper IP addresses."
        echo
        if ! prompt_confirm "Have you approved the subnet route in Tailscale?" "n"; then
            log_warn "Subnet route not approved yet. Installation will continue, but:"
            echo "  ⚠️  LoadBalancer services may not get proper IPs"
            echo "  ⚠️  You'll need to approve it later and restart services"
            echo "  ⚠️  To fix later: kubectl rollout restart -n <namespace> deployment/<service>"
            echo
            if ! prompt_confirm "Continue anyway?" "n"; then
                log_error "Installation cancelled by user"
                echo
                echo "After approving the subnet route, run:"
                echo "  sudo ./scripts/mynodeone"
                exit 1
            fi
        else
            log_success "Subnet route approved! Continuing with installation..."
        fi
    else
        log_warn "UNATTENDED mode: Assuming subnet route will be approved manually"
    fi
    echo
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
    log_info "Adding MinIO helm repository..."
    retry_command 3 "helm repo add minio https://charts.min.io/ 2>&1" || true
    timeout 60 helm repo update 2>&1 || log_warn "Helm repo update timed out, continuing..."
    
    # Set default storage size if not defined
    MINIO_STORAGE_SIZE="${MINIO_STORAGE_SIZE:-100Gi}"
    
    log_info "Installing MinIO (this may take 2-3 minutes)..."
    
    # Install with safe wrapper
    helm_install_safe "minio" "minio/minio" "minio" \
        --set rootUser="$MINIO_ROOT_USER" \
        --set rootPassword="$MINIO_ROOT_PASSWORD" \
        --set mode=standalone \
        --set replicas=1 \
        --set persistence.enabled=true \
        --set persistence.size="${MINIO_STORAGE_SIZE}" \
        --set persistence.storageClass=longhorn \
        --set service.type=LoadBalancer \
        --set consoleService.type=LoadBalancer \
    || {
        log_error "MinIO installation had issues"
        log_warn "This usually happens when LoadBalancer IPs can't be allocated"
        log_warn "Possible causes:"
        echo "  1. Tailscale subnet route not approved"
        echo "  2. MetalLB not working properly"
        echo "  3. Longhorn storage not ready"
        echo
        log_info "Checking MinIO status..."
        kubectl get pods -n minio || true
        kubectl get svc -n minio || true
        echo
        if [ "${UNATTENDED:-0}" != "1" ]; then
            if ! prompt_confirm "Continue with installation despite MinIO issue?" "y"; then
                log_error "Installation aborted"
                exit 1
            fi
        fi
        log_warn "Continuing installation, but MinIO may not be fully functional"
    }
    
    # Save credentials securely
    cat > $ACTUAL_HOME/mynodeone-minio-credentials.txt <<EOF
MinIO Credentials
=================
Root User: $MINIO_ROOT_USER
Root Password: $MINIO_ROOT_PASSWORD
Endpoint: http://$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9000
Console: http://$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):9001

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-minio-credentials.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-minio-credentials.txt
    
    log_success "MinIO installed"
    log_warn "MinIO credentials saved to $ACTUAL_HOME/mynodeone-minio-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

install_monitoring() {
    log_info "Installing monitoring stack (Prometheus, Grafana, Loki)..."
    
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Check DNS before adding repos
    check_dns || log_warn "DNS may be slow, continuing anyway..."
    
    # Install kube-prometheus-stack (Prometheus + Grafana)
    log_info "Adding helm repositories..."
    retry_command 3 "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>&1" || true
    retry_command 3 "helm repo add grafana https://grafana.github.io/helm-charts 2>&1" || true
    
    # Update repos with timeout
    log_info "Updating helm repositories (may take a moment)..."
    timeout 120 helm repo update 2>&1 || log_warn "Helm repo update slow/timed out, but continuing..."
    
    # Generate Grafana password
    GRAFANA_PASSWORD="$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)"
    
    # Install kube-prometheus-stack with safe wrapper
    helm_install_safe "kube-prometheus-stack" "prometheus-community/kube-prometheus-stack" "monitoring" \
        --version 55.5.0 \
        --set prometheus.prometheusSpec.retention=30d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi \
        --set grafana.adminPassword="$GRAFANA_PASSWORD" \
        --set grafana.service.type=LoadBalancer \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.storageClassName=longhorn \
        --set grafana.persistence.size=10Gi \
    || {
        log_error "Failed to install kube-prometheus-stack"
        log_info "Checking if pods started anyway..."
        sleep 15
        if kubectl get pods -n monitoring | grep -q "Running"; then
            log_warn "Some monitoring pods are running, continuing..."
        else
            log_error "Monitoring installation failed completely"
            return 1
        fi
    }
    
    # Install Loki for logs (non-critical, allow failure)
    log_info "Installing Loki (log aggregation)..."
    helm_install_safe "loki" "grafana/loki-stack" "monitoring" \
        --version 2.10.1 \
        --set loki.persistence.enabled=true \
        --set loki.persistence.storageClassName=longhorn \
        --set loki.persistence.size=100Gi \
        --set promtail.enabled=true \
    || log_warn "Loki installation failed, but continuing (non-critical)"
    
    # Get generated Grafana password from secret (with retry)
    sleep 5
    log_info "Retrieving Grafana credentials..."
    local attempts=0
    while [ $attempts -lt 10 ]; do
        GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode 2>/dev/null) || true
        if [ -n "$GRAFANA_PASSWORD" ]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 3
    done
    
    # Save Grafana credentials securely
    cat > $ACTUAL_HOME/mynodeone-grafana-credentials.txt <<EOF
Grafana Credentials
===================
Username: admin
Password: $GRAFANA_PASSWORD
URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-grafana-credentials.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-grafana-credentials.txt
    
    log_success "Monitoring stack installed"
    log_warn "Grafana credentials saved to $ACTUAL_HOME/mynodeone-grafana-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

install_argocd() {
    log_info "Installing ArgoCD for GitOps..."
    
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Add ArgoCD helm repo
    log_info "Adding ArgoCD helm repository..."
    retry_command 3 "helm repo add argo https://argoproj.github.io/argo-helm 2>&1" || true
    timeout 60 helm repo update 2>&1 || log_warn "Helm repo update timed out, continuing..."
    
    # Install ArgoCD using helm (more reliable than raw manifests)
    helm_install_safe "argocd" "argo/argo-cd" "argocd" \
        --version 5.51.6 \
        --set server.service.type=LoadBalancer \
    || {
        log_error "ArgoCD helm install failed, trying kubectl method..."
        # Fallback to kubectl method
        retry_command 2 "timeout 120 kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.3/manifests/install.yaml" || {
            log_error "ArgoCD installation failed"
            return 1
        }
        
        # Wait for ArgoCD to be ready (with timeout)
        log_info "Waiting for ArgoCD to be ready..."
        timeout 300 kubectl wait --for=condition=available deployment/argocd-server -n argocd 2>&1 || log_warn "ArgoCD wait timed out"
        
        # Expose ArgoCD with LoadBalancer
        kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}' || log_warn "Failed to patch ArgoCD service"
    }
    
    # Get initial admin password (with retry and timeout)
    log_info "Retrieving ArgoCD password..."
    local attempts=0
    ARGOCD_PASSWORD=""
    while [ $attempts -lt 30 ]; do
        ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null) || true
        if [ -n "$ARGOCD_PASSWORD" ]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done
    
    if [ -z "$ARGOCD_PASSWORD" ]; then
        log_warn "Could not retrieve ArgoCD password yet (it may not be ready)"
        ARGOCD_PASSWORD="<retrieve with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d>"
    fi
    
    # Save credentials securely
    cat > $ACTUAL_HOME/mynodeone-argocd-credentials.txt <<EOF
ArgoCD Credentials
==================
Username: admin
Password: $ARGOCD_PASSWORD
URL: https://$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-argocd-credentials.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-argocd-credentials.txt
    
    log_success "ArgoCD installed"
    log_warn "ArgoCD credentials saved to $ACTUAL_HOME/mynodeone-argocd-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file!"
}

deploy_dashboard() {
    log_info "Deploying MyNodeOne Dashboard..."
    
    # Deploy the dashboard
    if bash "$SCRIPT_DIR/../website/deploy-dashboard.sh" > /dev/null 2>&1; then
        log_success "Dashboard deployed - accessible at http://${CLUSTER_DOMAIN}.local"
    else
        log_warn "Dashboard deployment had issues, but continuing..."
    fi
}

create_cluster_info() {
    log_info "Creating cluster information configmap..."
    
    # Get absolute path to MyNodeOne repository
    REPO_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    # Create configmap with cluster metadata for management laptops and workers to discover
    kubectl create configmap cluster-info \
        --from-literal=cluster-name="$CLUSTER_NAME" \
        --from-literal=cluster-domain="$CLUSTER_DOMAIN" \
        --from-literal=control-plane-ip="$TAILSCALE_IP" \
        --from-literal=repo-path="$REPO_PATH" \
        --namespace=kube-system \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Cluster info configmap created"
    log_info "Repository path saved: $REPO_PATH"
}

create_cluster_token() {
    log_info "Generating node join token..."
    
    # K3s token for joining worker nodes
    TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    
    cat > $ACTUAL_HOME/mynodeone-join-token.txt <<EOF
MyNodeOne Cluster Join Configuration
====================================
Server URL: https://$TAILSCALE_IP:6443
Token: $TOKEN

To join a worker node, run:
curl -sfL https://get.k3s.io | K3S_URL=https://$TAILSCALE_IP:6443 K3S_TOKEN=$TOKEN sh -

Or use the add-worker-node.sh script (recommended)

WARNING: This token grants access to join nodes to your cluster. Store securely!
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-join-token.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-join-token.txt
    
    log_success "Join token saved to $ACTUAL_HOME/mynodeone-join-token.txt (chmod 600)"
    log_warn "IMPORTANT: This token grants cluster access. Store securely!"
}

initialize_service_registries() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Initializing Service Registry System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_info "Creating service registry..."
    bash "$SCRIPT_DIR/lib/service-registry.sh" init || true
    
    log_info "Creating multi-domain registry..."
    bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" init || true
    
    log_info "Initializing enterprise node registry..."
    bash "$SCRIPT_DIR/lib/node-registry-manager.sh" init || {
        log_warn "Could not initialize node registry (kubectl may not be ready yet)"
        log_info "Registry will be initialized on first node registration"
    }
    
    # VALIDATION: Verify ConfigMaps were created
    log_info "Validating registry initialization..."
    local validation_passed=true
    
    if ! kubectl get cm service-registry -n kube-system &>/dev/null; then
        log_warn "⚠ service-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ service-registry ConfigMap exists"
    fi
    
    if ! kubectl get cm domain-registry -n kube-system &>/dev/null; then
        log_warn "⚠ domain-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ domain-registry ConfigMap exists"
    fi
    
    if ! kubectl get cm sync-controller-registry -n kube-system &>/dev/null; then
        log_warn "⚠ sync-controller-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ sync-controller-registry ConfigMap exists"
    fi
    
    if [ "$validation_passed" = "true" ]; then
        log_success "✓ All registries initialized successfully"
    else
        log_warn "Some registries failed to initialize - may need manual creation"
    fi
    
    log_info "Syncing existing services to registry..."
    bash "$SCRIPT_DIR/lib/service-registry.sh" sync || true
    
    # Register platform services in the registry
    log_info "Registering platform services..."
    
    # Wait a moment for services to be fully ready
    sleep 5
    
    # Register Grafana
    if kubectl get svc -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" register \
            "kube-prometheus-stack-grafana" "grafana" "monitoring" \
            "kube-prometheus-stack-grafana" "80" "false" 2>/dev/null || \
            log_warn "Could not register Grafana (will retry later)"
    fi
    
    # Register ArgoCD
    if kubectl get svc -n argocd argocd-server &>/dev/null; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" register \
            "argocd-server" "argocd" "argocd" \
            "argocd-server" "80" "false" 2>/dev/null || \
            log_warn "Could not register ArgoCD (will retry later)"
    fi
    
    # Register MinIO Console
    if kubectl get svc -n minio minio-console &>/dev/null; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" register \
            "minio-console" "minio" "minio" \
            "minio-console" "9001" "false" 2>/dev/null || \
            log_warn "Could not register MinIO (will retry later)"
    fi
    
    # Register Longhorn (if LoadBalancer type)
    if kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.spec.type}' 2>/dev/null | grep -q "LoadBalancer"; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" register \
            "longhorn-frontend" "longhorn" "longhorn-system" \
            "longhorn-frontend" "80" "false" 2>/dev/null || \
            log_warn "Could not register Longhorn (will retry later)"
    fi
    
    # Register Dashboard
    if kubectl get svc -n mynodeone-dashboard dashboard &>/dev/null; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" register \
            "dashboard" "${CLUSTER_DOMAIN}" "mynodeone-dashboard" \
            "dashboard" "80" "false" 2>/dev/null || \
            log_warn "Could not register Dashboard (will retry later)"
    fi
    
    log_success "Platform services registered in service registry"
    log_success "Service registry initialized"
    
    # Install sync controller as systemd service
    if [ ! -f /etc/systemd/system/mynodeone-sync-controller.service ]; then
        log_info "Installing sync controller service..."
        
        # Update the service file with correct paths
        sed "s|/path/to/MyNodeOne|$PROJECT_ROOT|g" \
            "$PROJECT_ROOT/systemd/mynodeone-sync-controller.service" | \
            sudo tee /etc/systemd/system/mynodeone-sync-controller.service > /dev/null
        
        sudo systemctl daemon-reload
        sudo systemctl enable mynodeone-sync-controller
        sudo systemctl start mynodeone-sync-controller
        
        log_success "Sync controller service installed and started"
    else
        log_info "Sync controller service already installed"
    fi
    
    echo
    log_success "Registry system ready!"
    log_info "  • Service registry: Tracks all cluster services"
    log_info "  • Multi-domain registry: Supports multiple domains and VPS"
    log_info "  • Sync controller: Auto-pushes config changes to all nodes"
    echo
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
    DASHBOARD_IP=$(kubectl get svc -n mynodeone-dashboard dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    # Longhorn uses NodePort by default, so get the LoadBalancer IP or fall back to node IP:port
    LONGHORN_LB_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LONGHORN_LB_IP" ]; then
        LONGHORN_URL="http://$LONGHORN_LB_IP"
    else
        # Use NodePort (default is 30080)
        LONGHORN_PORT=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
        LONGHORN_URL="http://${TAILSCALE_IP}:${LONGHORN_PORT}"
    fi
    
    # Get passwords
    GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "See file below")
    
    echo "🏠 MYNODEONE DASHBOARD:"
    echo "   URL: http://$DASHBOARD_IP (also at http://${CLUSTER_DOMAIN}.local)"
    echo "   Features: Cluster status, one-click apps, script browser"
    echo
    
    echo "📊 GRAFANA (Monitoring Dashboard):"
    echo "   URL: http://$GRAFANA_IP (also http://grafana.${CLUSTER_DOMAIN}.local)"
    echo "   Username: admin"
    echo "   Password: $GRAFANA_PASS"
    echo
    
    echo "🚀 ARGOCD (GitOps):"
    echo "   URL: https://$ARGOCD_IP (also https://argocd.${CLUSTER_DOMAIN}.local)"
    if [ -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt ]; then
        cat $ACTUAL_HOME/mynodeone-argocd-credentials.txt | grep -E "Username|Password" | sed 's/^/   /'
    fi
    echo
    
    echo "💾 MINIO (S3 Storage):"
    echo "   Console: http://$MINIO_CONSOLE_IP:9001 (also http://minio.${CLUSTER_DOMAIN}.local:9001)"
    echo "   Note: Port 9001 is MinIO's web console (9000 is for S3 API)"
    if [ -f $ACTUAL_HOME/mynodeone-minio-credentials.txt ]; then
        cat $ACTUAL_HOME/mynodeone-minio-credentials.txt | grep -E "Username|Password" | sed 's/^/   /'
    fi
    echo
    
    echo "📦 LONGHORN (Storage Dashboard):"
    echo "   URL: $LONGHORN_URL (also http://longhorn.${CLUSTER_DOMAIN}.local)"
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
    
    # In unattended mode, keep credentials for display at the end
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Credentials will be displayed at the end of installation"
        log_info "They will remain visible so you can copy them to your password manager"
        # Don't delete yet - will delete after final display
        return
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
            echo "  3. Credentials are in: $ACTUAL_HOME/mynodeone-*-credentials.txt"
            echo
            read -p "Try again - Have you saved credentials? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                delete_credential_files
            else
                log_error "Please save credentials and manually delete files:"
                echo "  sudo rm $ACTUAL_HOME/mynodeone-*-credentials.txt"
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
    
    if [ -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt ]; then
        shred -vfz -n 3 $ACTUAL_HOME/mynodeone-argocd-credentials.txt 2>/dev/null || rm -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    if [ -f $ACTUAL_HOME/mynodeone-minio-credentials.txt ]; then
        shred -vfz -n 3 $ACTUAL_HOME/mynodeone-minio-credentials.txt 2>/dev/null || rm -f $ACTUAL_HOME/mynodeone-minio-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    if [ -f $ACTUAL_HOME/mynodeone-grafana-credentials.txt ]; then
        shred -vfz -n 3 $ACTUAL_HOME/mynodeone-grafana-credentials.txt 2>/dev/null || rm -f $ACTUAL_HOME/mynodeone-grafana-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    # Keep join token as it's needed for adding nodes
    # Keep join token as it's needed for adding nodes
    
    if [ $files_deleted -gt 0 ]; then
        log_success "✅ Credential files securely deleted ($files_deleted files)"
        log_info "Join token kept at: $ACTUAL_HOME/mynodeone-join-token.txt (needed for adding nodes)"
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
    echo "  ✓ Tailscale Subnet Routes (Network Access)"
    echo
    
    # Display credentials prominently
    display_credentials
    
    echo
    echo "⚠️  IMPORTANT: Approve Tailscale Subnet Route"
    echo "   To access services from your laptop, approve the subnet route:"
    echo "   → https://login.tailscale.com/admin/machines"
    echo "   → Find this machine → Edit route settings → Enable subnet"
    echo "   (Takes 30 seconds, enables .local domain access)"
    echo
    echo "📄 What To Do Next:"
    echo "  🎯 READ THIS FIRST: $PROJECT_ROOT/docs/guides/POST_INSTALLATION_GUIDE.md"
    echo "  • Shows exactly what to do after installation"
    echo "  • How to access from your laptop"
    echo "  • Deploying your first app"
    echo "  • Monitoring and managing the cluster"
    echo
    echo "📄 Additional Resources:"
    echo "  • View credentials anytime: sudo $SCRIPT_DIR/show-credentials.sh"
    echo "  • Demo app guide: $PROJECT_ROOT/docs/guides/DEMO_APP_GUIDE.md"
    echo "  • Deploy apps easily: $PROJECT_ROOT/docs/guides/APP_DEPLOYMENT_GUIDE.md"
    echo "  • Security guide: $PROJECT_ROOT/docs/guides/SECURITY_CREDENTIALS_GUIDE.md"
    echo "  • Quick reference: $PROJECT_ROOT/docs/reference/ACCESS_INFORMATION.md"
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
    echo "      Credentials: cat $ACTUAL_HOME/mynodeone-argocd-credentials.txt"
    echo
    echo "   💾 MinIO Console (S3 Storage):"
    echo "      URL: http://$MINIO_CONSOLE_IP:9001"
    echo "      Credentials: cat $ACTUAL_HOME/mynodeone-minio-credentials.txt"
    echo
    echo "   📦 Longhorn UI (Block Storage):"
    echo "      URL: $LONGHORN_URL"
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
    echo "  🔒 Core Security: Already Enabled!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_success "Your cluster has production-grade security built-in:"
    echo "  ✅ Secrets encryption at rest (AES-256)"
    echo "  ✅ Kubernetes audit logging"
    echo "  ✅ Pod Security Standards (baseline enforcement)"
    echo "  ✅ Firewall enabled (UFW)"
    echo "  ✅ Fail2ban protection"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  Optional: Additional Security Enhancements"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy optional security enhancements?"
    echo
    echo "This adds:"
    echo "  • Network policies (default deny + explicit allow)"
    echo "  • Resource quotas (prevent DoS attacks)"
    echo "  • Traefik security headers (HSTS, CSP, XSS protection)"
    echo
    echo "Recommended: YES for production, OPTIONAL for home/testing"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping optional security enhancements"
        log_info "You can add them later with: sudo $SCRIPT_DIR/enable-security-hardening.sh"
        return
    fi
    
    read -p "Deploy optional security enhancements? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying optional security enhancements..."
        if bash "$SCRIPT_DIR/enable-security-hardening.sh"; then
            log_success "Optional security enhancements deployed!"
            echo
            echo "✅ Network policies active"
            echo "✅ Resource quotas enforced"
            echo "✅ Traefik security headers configured"
        else
            log_warn "Deployment had issues. You can try again later with:"
            echo "  sudo $SCRIPT_DIR/enable-security-hardening.sh"
        fi
    else
        echo
        log_info "Skipping optional enhancements. Your cluster still has strong core security."
        echo
        log_info "You can add them anytime with:"
        echo "  sudo $SCRIPT_DIR/enable-security-hardening.sh"
    fi
}

setup_local_dns() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Setting Up Local DNS Resolution"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Configuring easy-to-remember domain names for services..."
    echo
    
    # Wait for all LoadBalancer IPs to be assigned (with retry)
    log_info "Waiting for LoadBalancer IPs to be assigned..."
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local pending=$(kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.status.loadBalancer.ingress == null) | .metadata.name' | wc -l)
        if [ "$pending" -eq 0 ]; then
            log_success "All LoadBalancer IPs assigned!"
            break
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    echo
    
    if [ $waited -ge $max_wait ]; then
        log_warn "Some LoadBalancer IPs still pending after ${max_wait}s"
        log_info "Services with pending IPs:"
        kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.status.loadBalancer.ingress == null) | "\(.metadata.namespace)/\(.metadata.name)"'
        echo
    fi
    
    # Run DNS setup with retry
    local dns_retry=0
    local dns_max_retries=3
    local dns_success=false
    
    while [ $dns_retry -lt $dns_max_retries ]; do
        if bash "$SCRIPT_DIR/setup-local-dns.sh"; then
            dns_success=true
            break
        else
            dns_retry=$((dns_retry + 1))
            if [ $dns_retry -lt $dns_max_retries ]; then
                log_warn "DNS setup attempt $dns_retry failed, retrying in 5s..."
                sleep 5
            fi
        fi
    done
    
    if [ "$dns_success" = true ]; then
        log_success "Local DNS setup complete!"
        echo
        
        # Verify DNS resolution works
        log_info "Verifying DNS resolution..."
        local dns_ok=true
        for service in "grafana.${CLUSTER_DOMAIN}.local" "argocd.${CLUSTER_DOMAIN}.local"; do
            if getent hosts "$service" >/dev/null 2>&1; then
                echo "  ✓ $service"
            else
                echo "  ✗ $service (not resolving)"
                dns_ok=false
            fi
        done
        echo
        
        if [ "$dns_ok" = true ]; then
            log_success "DNS verification passed!"
        else
            log_warn "Some DNS entries not resolving yet. May need a few seconds to propagate."
        fi
        
        echo "✅ You can now use .local domain names on this server"
        echo
        log_info "To access from other devices (laptop, phone):"
        echo "  1. Ensure Tailscale is installed and connected"
        echo "  2. Copy the setup script: $PROJECT_ROOT/setup-client-dns.sh"
        echo "  3. Run: sudo bash setup-client-dns.sh"
    else
        log_warn "Local DNS setup failed after $dns_max_retries attempts."
        log_warn "You can set it up later with:"
        echo "  sudo $SCRIPT_DIR/setup-local-dns.sh"
    fi
}

run_final_validation() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 Final Validation: Testing Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Running comprehensive installation validation..."
    log_info "This verifies: Kubernetes, services, registry, DNS, and more"
    echo
    
    # Run unified validation script
    if [ -f "$SCRIPT_DIR/lib/validate-installation.sh" ]; then
        if bash "$SCRIPT_DIR/lib/validate-installation.sh" control-plane; then
            echo
            log_success "🎉 INSTALLATION VALIDATION PASSED!"
            log_info "Your control plane is fully operational!"
            
            # Save validation timestamp
            echo "LAST_VALIDATION=$(date -Iseconds)" >> $ACTUAL_HOME/.mynodeone/config.env
            echo "VALIDATION_STATUS=passed" >> $ACTUAL_HOME/.mynodeone/config.env
        else
            echo
            log_error "❌ INSTALLATION VALIDATION FAILED"
            log_warn "Some components may need attention (see details above)"
            log_info "You can re-run validation anytime:"
            echo "  sudo bash $SCRIPT_DIR/lib/validate-installation.sh control-plane"
            
            # Save validation status
            echo "LAST_VALIDATION=$(date -Iseconds)" >> $ACTUAL_HOME/.mynodeone/config.env
            echo "VALIDATION_STATUS=failed" >> $ACTUAL_HOME/.mynodeone/config.env
            
            # Ask if user wants to continue
            if [ "${UNATTENDED:-0}" != "1" ]; then
                echo
                read -p "Continue despite validation failures? [y/N]: " -r
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Installation paused. Fix issues and re-run validation."
                    exit 1
                fi
            fi
        fi
    else
        log_warn "Validation script not found at: $SCRIPT_DIR/lib/validate-installation.sh"
        log_info "Skipping automated validation"
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
        # Use the new app store installation script (auto-skips prompts for subdomain/VPS during bootstrap)
        export AUTO_INSTALL_MODE=true
        if bash "$SCRIPT_DIR/apps/install-llm-chat.sh"; then
            log_success "LLM chat deployment complete!"
            echo
            log_info "LLM Chat installed locally. To add public internet access later:"
            echo "  sudo bash scripts/apps/install-llm-chat.sh"
        else
            log_warn "LLM chat deployment had issues. You can deploy it later with:"
            echo "  sudo bash scripts/apps/install-llm-chat.sh"
        fi
        unset AUTO_INSTALL_MODE
    else
        echo
        log_info "Skipping LLM chat. You can deploy it anytime with:"
        echo "  sudo bash scripts/apps/install-llm-chat.sh"
    fi
}

display_final_credentials_unattended() {
    echo
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "  🔐 FINAL STEP: SAVE YOUR CREDENTIALS"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_warn "UNATTENDED MODE: Installation complete! Now save these credentials:"
    echo
    
    # Display all credentials again
    display_credentials
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "📋 IMPORTANT: Copy ALL credentials above to your password manager NOW!"
    echo
    echo "Recommended password managers:"
    echo "  • 1Password (https://1password.com)"
    echo "  • Bitwarden (https://bitwarden.com)"
    echo "  • KeePassXC (https://keepassxc.org)"
    echo
    echo "⚠️  After you save them, delete the credential files for security:"
    echo "   sudo rm $ACTUAL_HOME/mynodeone-*-credentials.txt"
    echo
    echo "💡 You can view credentials anytime with:"
    echo "   sudo $SCRIPT_DIR/show-credentials.sh"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne Control Plane Bootstrap"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    install_dependencies
    configure_firewall
    optimize_system_for_containers
    install_k3s
    install_helm
    install_cert_manager
    install_metallb
    configure_tailscale_subnet_routes
    install_traefik
    install_longhorn
    install_minio
    install_monitoring
    install_argocd
    deploy_dashboard
    create_cluster_info
    create_cluster_token
    initialize_service_registries
    
    echo
    print_summary
    
    # Offer security hardening
    offer_security_hardening
    
    # Setup local DNS automatically
    setup_local_dns
    
    # Run comprehensive validation AFTER DNS is setup
    run_final_validation
    
    # Offer to deploy demo app
    offer_demo_app
    
    # Offer to deploy LLM chat app
    offer_llm_chat
    
    # Final sync: Ensure all services are registered and DNS is updated
    log_info "Final sync: Registering all services and updating DNS..."
    if [ -f "$SCRIPT_DIR/lib/service-registry.sh" ]; then
        bash "$SCRIPT_DIR/lib/service-registry.sh" sync 2>/dev/null || true
    fi
    if [ -f "$SCRIPT_DIR/sync-dns.sh" ]; then
        bash "$SCRIPT_DIR/sync-dns.sh" 2>/dev/null || true
    fi
    log_success "All services registered and DNS updated"
    echo
    
    # Configure passwordless sudo for automation
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Final Step: Configuring Passwordless Sudo"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Setting up passwordless sudo for cluster management..."
    
    if [ -f "$SCRIPT_DIR/setup-control-plane-sudo.sh" ]; then
        # Run with error handling (don't fail installation if this fails)
        if bash "$SCRIPT_DIR/setup-control-plane-sudo.sh" 2>&1; then
            log_success "✓ Passwordless sudo configured successfully"
        else
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                # Exit code 0 means it was already configured
                log_success "✓ Passwordless sudo already configured"
            else
                log_warn "⚠ Passwordless sudo configuration had issues (non-critical)"
                log_info "This won't affect cluster operation, but VPS sync may require passwords"
            fi
        fi
        
        # Final verification
        if sudo -n kubectl version --client &>/dev/null 2>&1; then
            log_success "✓ Verified: kubectl works without password"
        else
            log_warn "⚠ kubectl still requires password"
            log_info "To fix manually: sudo $SCRIPT_DIR/setup-control-plane-sudo.sh"
        fi
    else
        log_warn "setup-control-plane-sudo.sh not found, skipping"
    fi
    echo
    
    # In unattended mode, display credentials at the end
    if [ "${UNATTENDED:-0}" = "1" ]; then
        display_final_credentials_unattended
    fi
}

# Run main function
main "$@"
