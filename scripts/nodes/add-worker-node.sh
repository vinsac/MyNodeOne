#!/bin/bash

###############################################################################
# MyNodeOne Worker Node Addition Script
# 
# This script adds a new worker node to the MyNodeOne cluster
# Run this on the NEW worker node (e.g., node-002, node-003, etc.)
#
# IMPORTANT: Run ./scripts/installation/interactive-setup.sh first!
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Load configuration
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Please run: ./scripts/installation/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# Export cluster configuration for child scripts
export CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}"
export CLUSTER_NAME="${CLUSTER_NAME:-}"

# K3s version
K3S_VERSION="v1.28.5+k3s1"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities
source "$SCRIPT_DIR/../lib/project-root.sh"
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

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
    
    # Verify configuration
    if [ -z "$TAILSCALE_IP" ] || [ -z "$CONTROL_PLANE_IP" ] || [ -z "$NODE_NAME" ]; then
        log_error "Configuration incomplete. Please run: ./scripts/installation/interactive-setup.sh"
        exit 1
    fi
    
    log_success "Node Name: $NODE_NAME"
    log_success "Tailscale IP: $TAILSCALE_IP"
    log_success "Control Plane: $CONTROL_PLANE_IP"
    
    # Verify we can resolve the node name via our new logic if it already exists
    export_k8s_config || true
    local detected_name=$(get_k8s_node_name 2>/dev/null || echo "")
    if [[ -n "$detected_name" ]] && [[ "$detected_name" != "$NODE_NAME" ]]; then
        log_warn "Identity mismatch: Config says '$NODE_NAME' but cluster sees '$detected_name'"
        log_info "Proceeding with config name: $NODE_NAME"
    fi
    
    log_success "Prerequisites check passed"
}

ensure_tailscale_ready() {
    log_info "Ensuring Tailscale interface is ready..."

    if ! command -v ip &>/dev/null; then
        log_error "ip command not found (iproute2 missing). Install with: sudo apt-get install -y iproute2"
        exit 1
    fi

    if ! command -v tailscale &>/dev/null; then
        log_error "tailscale command not found. Install with: curl -fsSL https://tailscale.com/install.sh | sh"
        exit 1
    fi

    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active tailscaled &>/dev/null; then
            log_error "tailscaled is not running. Start it with: sudo systemctl start tailscaled"
            exit 1
        fi
    else
        log_warn "systemctl not found; skipping tailscaled service check"
    fi

    local attempts=0
    local max_attempts=12
    while [ $attempts -lt $max_attempts ]; do
        if ip link show tailscale0 &>/dev/null; then
            local ts_ip
            ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
            if [ -n "$ts_ip" ]; then
                log_success "Tailscale interface ready: $ts_ip"
                return 0
            fi
        fi

        attempts=$((attempts + 1))
        log_warn "Tailscale interface not ready yet (attempt $attempts/$max_attempts). Waiting..."
        sleep 5
    done

    log_error "Tailscale interface not ready after ${max_attempts} attempts."
    log_error "Run: sudo tailscale up --accept-dns=false"
    exit 1
}

configure_k8s_network_prereqs() {
    log_info "Configuring kernel prerequisites for Kubernetes networking..."

    # Ensure required modules load on boot
    mkdir -p /etc/modules-load.d /etc/sysctl.d
    cat > /etc/modules-load.d/mynodeone-k8s.conf <<'EOF'
br_netfilter
vxlan
EOF

    if command -v modprobe &>/dev/null; then
        modprobe br_netfilter 2>/dev/null || log_warn "Failed to load kernel module br_netfilter"
        modprobe vxlan 2>/dev/null || log_warn "Failed to load kernel module vxlan"
    else
        log_warn "modprobe not found; kernel modules may not load automatically"
    fi

    # Persist sysctl settings for pod networking
    cat > /etc/sysctl.d/99-mynodeone-k8s.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

    if command -v sysctl &>/dev/null; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log_warn "Could not set net.ipv4.ip_forward=1"
        sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || log_warn "Could not set net.bridge.bridge-nf-call-iptables=1"
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || log_warn "Could not set net.bridge.bridge-nf-call-ip6tables=1"
        sysctl --system >/dev/null 2>&1 || log_warn "sysctl --system failed; reboot may be required"
    else
        log_warn "sysctl not found; kernel networking settings may not be applied"
    fi

    log_success "Kernel networking prerequisites configured"
}

configure_k3s_service_dependencies() {
    local service_name="$1"
    log_info "Configuring $service_name to start after Tailscale..."

    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl not found; cannot set service dependencies"
        return 0
    fi

    local drop_in_dir="/etc/systemd/system/${service_name}.service.d"
    mkdir -p "$drop_in_dir"
    cat > "$drop_in_dir/10-tailscale.conf" <<'EOF'
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
EOF

    systemctl daemon-reload
    log_success "$service_name dependency on tailscaled configured"
}

verify_control_plane() {
    log_info "Verifying control plane connectivity..."
    
    # Verify we can reach control plane
    if nc -z -w5 "$CONTROL_PLANE_IP" 6443 2>/dev/null; then
        log_success "Control plane reachable at: $CONTROL_PLANE_IP"
    else
        log_warn "Cannot reach control plane at $CONTROL_PLANE_IP:6443"
        log_warn "Make sure:"
        log_warn "  1. Control plane is running and bootstrapped"
        log_warn "  2. Tailscale is connected on both machines"
        log_warn "  3. K3s is installed and running on control plane"
        log_error "Cannot proceed without control plane connectivity"
        exit 1
    fi
}

get_join_token() {
    log_info "Getting cluster join token..."
    
    echo
    log_info "Please obtain the K3s token from the control plane node ($CONTROL_PLANE_IP)"
    log_info "On the control plane, run: sudo cat /var/lib/rancher/k3s/server/node-token"
    log_info "Or check: $ACTUAL_HOME/mynodeone-join-token.txt"
    echo
    read -p "Enter K3s token: " K3S_TOKEN
    
    if [ -z "$K3S_TOKEN" ]; then
        log_error "Token cannot be empty"
        exit 1
    fi
    
    log_success "Token received"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        pciutils \
        open-iscsi \
        nfs-common \
        util-linux \
        netcat-openbsd \
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
    
    # Allow SSH
    ufw allow 22/tcp comment 'SSH'
    
    # Allow full access on Tailscale interface
    ufw allow in on tailscale0 comment 'Tailscale mesh network'
    
    # Allow Flannel VXLAN for Kubernetes pod-to-pod networking
    # Required for multi-node clusters
    ufw allow 8472/udp comment 'Flannel VXLAN'
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed  # Required for Kubernetes CNI pod routing
    
    # Enable fail2ban for SSH protection
    systemctl enable --now fail2ban
    
    # Defensive programming: Fix SSH permissions
    if [ -d "$ACTUAL_HOME/.ssh" ]; then
        log_info "Ensuring strict SSH permissions..."
        chmod 700 "$ACTUAL_HOME/.ssh"
        if [ -f "$ACTUAL_HOME/.ssh/authorized_keys" ]; then
            chmod 600 "$ACTUAL_HOME/.ssh/authorized_keys"
        fi
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.ssh"
    fi
    
    log_success "Firewall configured (UFW enabled, Kubernetes networking allowed)"
    log_info "Kubernetes pod routing enabled (VXLAN port 8472/UDP, routed policy allow)"
}

join_cluster() {
    log_info "Joining MyNodeOne cluster..."
    
    # Prepare K3s configuration
    mkdir -p /etc/rancher/k3s
    
    cat > /etc/rancher/k3s/config.yaml <<EOF
node-name: "$NODE_NAME"
node-ip: "$TAILSCALE_IP"
flannel-iface: tailscale0
kubelet-arg:
  - "max-pods=250"
EOF
    
    # Install K3s agent
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="$K3S_VERSION" \
        K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -
    
    # Wait for node to be registered
    log_info "Waiting for node to register with cluster..."
    sleep 10
    
    log_success "Successfully joined MyNodeOne cluster"
}

# Configure kubectl on worker node
configure_kubectl_worker() {
    log_info "Configuring kubectl on worker node..."
    
    local KUBECONFIG_DEST="$ACTUAL_HOME/.kube/config"
    
    # 1. Check if kubectl already works (from interactive-setup)
    if [ -f "$KUBECONFIG_DEST" ]; then
        if sudo -u "$ACTUAL_USER" kubectl get nodes &>/dev/null; then
            log_success "Working kubectl configuration already exists, preserving it."
            return 0
        fi
        log_info "Existing kubeconfig found but cluster access failed. Attempting to fix..."
    fi

    # 2. Try to fetch admin k3s.yaml from control plane (most robust)
    if [ -n "${CONTROL_PLANE_IP:-}" ] && [ -n "${CONTROL_PLANE_SSH_USER:-}" ]; then
        log_info "Attempting to fetch admin kubeconfig from control plane ($CONTROL_PLANE_IP)..."
        
        # Check if we have SSH access (ssh-copy-id should have been done)
        if sudo -u "$ACTUAL_USER" ssh -o ConnectTimeout=5 -n "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "sudo cat /etc/rancher/k3s/k3s.yaml" > "$KUBECONFIG_DEST.tmp" 2>/dev/null; then
            # Fix IP address in temp config
            sed -i "s/127.0.0.1/$CONTROL_PLANE_IP/g" "$KUBECONFIG_DEST.tmp"
            
            # Verify the fetched config
            if KUBECONFIG="$KUBECONFIG_DEST.tmp" kubectl get nodes &>/dev/null; then
                mv "$KUBECONFIG_DEST.tmp" "$KUBECONFIG_DEST"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$KUBECONFIG_DEST"
                chmod 600 "$KUBECONFIG_DEST"
                log_success "Admin kubeconfig fetched successfully from control plane."
                return 0
            fi
            rm -f "$KUBECONFIG_DEST.tmp"
        fi
        log_warn "Could not fetch admin kubeconfig via SSH."
    fi

    # 3. Fallback: Generate limited kubeconfig from local certificates
    # K3s agent nodes don't create /etc/rancher/k3s/k3s.yaml
    
    # Create .kube directory
    mkdir -p "$ACTUAL_HOME/.kube"
    
    log_info "Generating fallback kubeconfig from local worker certificates..."
    
    # Wait for K3s agent to be ready
    sleep 5
    
    # Get cluster CA certificate from K3s server
    local CA_CERT_PATH="/var/lib/rancher/k3s/agent/server-ca.crt"
    
    if [ ! -f "$CA_CERT_PATH" ]; then
        log_error "Could not find K3s server CA certificate at $CA_CERT_PATH"
        log_warn "kubectl will not be available on this worker node"
        return 1
    fi
    
    local CA_CERT=$(cat "$CA_CERT_PATH" | base64 -w 0)
    
    # Get client certificate and key for authentication
    local CLIENT_CERT=""
    local CLIENT_KEY=""
    
    if [ -f "/var/lib/rancher/k3s/agent/client-k3s-controller.crt" ] && [ -f "/var/lib/rancher/k3s/agent/client-k3s-controller.key" ]; then
        CLIENT_CERT=$(cat /var/lib/rancher/k3s/agent/client-k3s-controller.crt | base64 -w 0)
        CLIENT_KEY=$(cat /var/lib/rancher/k3s/agent/client-k3s-controller.key | base64 -w 0)
        log_info "Using K3s controller certificates"
    elif [ -f "/var/lib/rancher/k3s/agent/client-admin.crt" ] && [ -f "/var/lib/rancher/k3s/agent/client-admin.key" ]; then
        CLIENT_CERT=$(cat /var/lib/rancher/k3s/agent/client-admin.crt | base64 -w 0)
        CLIENT_KEY=$(cat /var/lib/rancher/k3s/agent/client-admin.key | base64 -w 0)
        log_info "Using K3s admin certificates"
    elif [ -f "/var/lib/rancher/k3s/agent/client-kubelet.crt" ] && [ -f "/var/lib/rancher/k3s/agent/client-kubelet.key" ]; then
        CLIENT_CERT=$(cat /var/lib/rancher/k3s/agent/client-kubelet.crt | base64 -w 0)
        CLIENT_KEY=$(cat /var/lib/rancher/k3s/agent/client-kubelet.key | base64 -w 0)
        log_info "Using K3s kubelet certificates"
    else
        log_error "Could not find K3s client certificates"
        return 1
    fi
    
    # Create kubeconfig
    cat > "$KUBECONFIG_DEST" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_CERT}
    server: https://${CONTROL_PLANE_IP}:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
users:
- name: default
  user:
    client-certificate-data: ${CLIENT_CERT}
    client-key-data: ${CLIENT_KEY}
EOF
    
    # Fix ownership
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.kube"
    
    # Set permissions
    chmod 600 "$KUBECONFIG_DEST"
    
    log_success "Fallback kubeconfig created at $KUBECONFIG_DEST"
    
    # Test kubectl access
    if sudo -u "$ACTUAL_USER" kubectl get nodes &>/dev/null; then
        log_success "kubectl configured successfully on worker node"
    else
        log_warn "kubectl configured but cluster access verification failed"
        log_warn "Limited permissions may cause issues with GPU/Storage setup"
    fi
}

label_node() {
    log_info "Labeling node..."
    
    # Prompt for SSH username (needed for model syncing from control plane)
    echo ""
    echo "For model syncing from control plane, what SSH username should be used?"
    echo "This is the username that will be used to SSH into this node from control plane."
    read -p "SSH username (default: ${ACTUAL_USER}): " SSH_USERNAME
    SSH_USERNAME="${SSH_USERNAME:-${ACTUAL_USER}}"
    
    log_info "SSH username for this node: $SSH_USERNAME"
    
    # This requires kubectl access from control plane
    # We'll save the labels in a file for the admin to apply
    
    # Generate one-liner label command
    LABEL_CMD="kubectl label node $NODE_NAME node-role.kubernetes.io/worker=true mynodeone.io/location=${NODE_LOCATION} mynodeone.io/storage=true mynodeone.io/worker-ip=${TAILSCALE_IP} mynodeone.io/ssh-user=${SSH_USERNAME} --overwrite"
    
    log_info "Run this command on the control plane:"
    echo "  $LABEL_CMD"
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Apply the labels on control plane before continuing!${NC}"
    echo ""
    echo -n "Have you applied the labels on the control plane? [y/N]: "
    read -r labels_applied
    
    if [[ ! "$labels_applied" =~ ^[Yy] ]]; then
        log_warn "Please apply the labels on control plane and run this script again"
        log_info "Labels saved to: $ACTUAL_HOME/mynodeone-node-labels.txt"
        exit 0
    fi
    
    log_success "Labels confirmed - proceeding with installation"
    
    cat > "$ACTUAL_HOME/mynodeone-node-labels.txt" <<EOF
# Apply node labels on the control plane:
$LABEL_CMD
EOF
    
    # Fix ownership (script runs as root via sudo)
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/mynodeone-node-labels.txt"
    
    log_success "Node labels saved to $ACTUAL_HOME/mynodeone-node-labels.txt"
    echo
    
    # Register cluster node in node registry (requires kubectl access from control plane)
    log_info "To register this node in the cluster registry, run this on the CONTROL PLANE:"
    echo ""
    
    cat > "$ACTUAL_HOME/mynodeone-register-node.sh" <<'REGEOF'
#!/bin/bash
# Run this script on the control plane to register the worker node

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

if [ -f "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" ]; then
    source "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh"
    
    # Get node name from kubectl
    K8S_NODE_NAME=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)
    
    if [ -z "$K8S_NODE_NAME" ]; then
        echo "Error: Could not detect worker node name"
        exit 1
    fi
    
    echo "Registering worker node: $K8S_NODE_NAME"
    
    # Get node location from label
    NODE_LOCATION=$(kubectl get node "$K8S_NODE_NAME" -o jsonpath='{.metadata.labels.mynodeone\.io/location}' 2>/dev/null || echo "unknown")
    TAILSCALE_IP=$(kubectl get node "$K8S_NODE_NAME" -o jsonpath='{.metadata.labels.mynodeone\.io/worker-ip}' 2>/dev/null)
    SSH_USER=$(kubectl get node "$K8S_NODE_NAME" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
    
    # Register cluster node
    register_cluster_node \
        --name "$K8S_NODE_NAME" \
        --k8s-node-name "$K8S_NODE_NAME" \
        --role "worker" \
        --location "$NODE_LOCATION" \
        --tailscale-ip "$TAILSCALE_IP" \
        --ssh-user "$SSH_USER"
    
    echo "Worker node registered successfully"
else
    echo "Error: Node registry manager not found"
    exit 1
fi
REGEOF
    
    chmod +x "$ACTUAL_HOME/mynodeone-register-node.sh"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/mynodeone-register-node.sh"
    
    echo "  bash ~/mynodeone-register-node.sh"
    echo ""
    log_info "Run this command on the control plane:"
    echo "  $LABEL_CMD"
}

print_summary() {
    log_success "Worker node successfully added to MyNodeOne"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Worker Node Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Node Information:"
    echo "  Name: $NODE_NAME"
    echo "  IP: $TAILSCALE_IP"
    echo "  Control Plane: $CONTROL_PLANE_IP"
    echo
    echo "Installed Components:"
    echo "  ✓ K3s agent (joined cluster)"
    echo "  ✓ Node Agent (pull-based config sync)"
    
    # Check if Longhorn is actually configured with disks
    if kubectl get nodes.longhorn.io "$NODE_NAME" -n longhorn-system &>/dev/null; then
        echo "  ✓ Longhorn (Storage configured)"
    fi
    
    # Only show NVIDIA if detected
    if lspci | grep -qi nvidia; then
        echo "  ✓ NVIDIA GPU (Driver & Device Plugin)"
    fi
    echo
    
    # Display MinIO credentials if available
    if kubectl get svc minio -n minio &> /dev/null; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🔐 MinIO Credentials (Object Storage)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        local MINIO_USER=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
        local MINIO_PASS=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d 2>/dev/null || echo "See credentials file")
        local MINIO_ENDPOINT=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        local MINIO_CONSOLE=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        
        echo "💾 MINIO (Backup Storage):"
        echo "   S3 API: http://${MINIO_ENDPOINT}:9000"
        echo "   Console: http://${MINIO_CONSOLE}:9001"
        echo "   Username: $MINIO_USER"
        echo "   Password: $MINIO_PASS"
        echo
        echo "   📄 Credentials also saved to: $ACTUAL_HOME/mynodeone-minio-worker-credentials.txt"
        echo
        echo "⚠️  IMPORTANT: Save these credentials to your password manager NOW"
        echo "   Then delete the credentials file for security."
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
    fi
    
    echo "Next Steps:"
    echo "  1. On the control plane node, apply node labels:"
    echo "     See: $ACTUAL_HOME/mynodeone-node-labels.txt on this machine"
    echo
    echo "  2. Set up SSH for model syncing (one-time, 2 minutes):"
    echo "     On control plane: ssh-copy-id $ACTUAL_USER@$TAILSCALE_IP"
    echo "     Then sync models: ./scripts/apps/llmapi/sync-models-to-workers.sh"
    echo
    echo "  3. Verify node status on control plane:"
    echo "     kubectl get nodes"
    echo "     ./scripts/nodes/nodes-status.sh"
    echo
    echo "  4. This node will now receive workloads automatically"
    echo "     vLLM pods will use pre-synced models for instant startup."
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

install_node_agent() {
    log_info "Installing Node Agent for pull-based config sync..."
    
    if [ -f "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" ]; then
        # Get API token from config if available
        API_TOKEN="${API_TOKEN:-}"
        
        # Get SSH user for control plane to enable automatic token fetch
        # Try to get from config or environment
        CP_SSH_USER="${CONTROL_PLANE_USER:-}"
        
        # Call install-config-sync with ssh-user parameter for automatic token fetch
        # Arguments: node-type control-plane-ip api-token node-name ssh-user
        if bash "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" worker "$CONTROL_PLANE_IP" "$API_TOKEN" "$NODE_NAME" "$CP_SSH_USER"; then
            log_success "Node Agent installed"
            log_info "Worker will now pull config updates from control plane"
        else
            log_warn "Node Agent installation had issues"
            log_warn "You can install manually later:"
            log_warn "  sudo ./scripts/lib/install-config-sync.sh worker $CONTROL_PLANE_IP <api-token>"
        fi
    else
        log_warn "Node Agent installer not found, skipping"
    fi
}

setup_model_directories() {
    log_info "Setting up model storage directories..."
    
    # Create directories for hostPath volumes used by LLM API
    mkdir -p /var/lib/llmapi/models/{vllm,llamacpp,embedding}
    mkdir -p /var/lib/vllm-models
    
    # Set proper ownership (pods run as root, but make accessible)
    chown -R root:root /var/lib/llmapi
    chmod -R 755 /var/lib/llmapi
    
    log_success "Model storage directories created"
    log_info "Models can be synced from control plane using:"
    log_info "  ./scripts/apps/llmapi/sync-models-to-workers.sh $NODE_NAME"
}

setup_gpu() {
    # Check for NVIDIA GPU
    if ! lspci 2>/dev/null | grep -qi nvidia; then
        return 0
    fi
    
    log_info "NVIDIA GPU detected on this worker node"
    
    if [ -f "$PROJECT_ROOT/scripts/lib/gpu-setup.sh" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  NVIDIA GPU Detected"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        lspci | grep -i nvidia | head -3
        echo ""
        
        # Interactive GPU setup (will deploy device plugin if kubectl works)
        bash "$PROJECT_ROOT/scripts/lib/gpu-setup.sh"
        GPU_EXIT_CODE=$?
        
        if [ $GPU_EXIT_CODE -eq 2 ]; then
            echo ""
            log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_warn "  REBOOT REQUIRED"
            log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            log_warn "  NVIDIA driver was installed. Please reboot and run this script again."
            log_warn ""
            log_warn "  After reboot, run:"
            log_warn "    sudo $0"
            log_warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            exit 0
        fi
        
        # Update summary to show GPU
        HAS_GPU="true"
    else
        log_warn "GPU setup script not found"
        log_info "You can install GPU support manually later:"
        log_info "  sudo ./scripts/lib/gpu-setup.sh"
    fi
}

install_longhorn() {
    log_info "Installing Longhorn storage (interactive)..."
    
    # Use new interactive installation script
    if [ -f "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh" ]; then
        bash "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh"
    else
        log_warn "Longhorn installation script not found: $PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh"
        log_info "Longhorn should already be available from control plane"
    fi
}

install_minio() {
    log_info "MinIO installation (optional)..."
    log_info "MinIO can be installed from control plane to any node"
    log_info ""
    log_info "To install MinIO on this or any node, run from control plane:"
    log_info "  sudo $PROJECT_ROOT/scripts/storage/minio/install-minio.sh"
    log_info ""
    log_info "The script will:"
    log_info "  - Let you select target node (control plane or worker)"
    log_info "  - Install via SSH if remote node"
    log_info "  - Assign unique MetalLB IP per node"
    log_info "  - Create node-specific .local domain (minio-<nodename>.mynodeone.local)"
    log_info "  - Generate independent credentials per node"
    log_info ""
}

# DISABLED: Auto-scaling replicas conflicts with single-replica architecture
# MyNodeOne uses replica=1 to avoid rebuild storms over Tailscale network
# StorageClass enforces numberOfReplicas=1 for all new PVCs
# See: docs/architecture/STORAGE-ARCHITECTURE-PROMPT.md
#
# scale_longhorn_replicas() {
#     log_info "Scaling Longhorn replica count for redundancy..."
#     
#     # Check if Longhorn is installed
#     if ! kubectl get namespace longhorn-system &>/dev/null; then
#         log_warn "Longhorn not found, skipping replica scaling"
#         return 0
#     fi
#     
#     # Count Longhorn nodes
#     local node_count=$(kubectl get nodes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l)
#     
#     if [ "$node_count" -ge 2 ]; then
#         log_info "Detected $node_count Longhorn nodes, increasing default replica count to 2"
#         
#         # Update default replica count setting
#         kubectl -n longhorn-system patch setting default-replica-count --type=merge \
#             -p '{"value":"2"}' &>/dev/null || \
#         kubectl -n longhorn-system patch setting defaultReplicaCount --type=merge \
#             -p '{"value":"2"}' &>/dev/null || true
#         
#         log_success "Longhorn will now create 2 replicas for new volumes (redundancy across nodes)"
#         log_info "Existing volumes will remain at 1 replica (change manually via Longhorn UI if needed)"
#     else
#         log_warn "Only $node_count Longhorn node(s) detected, keeping replica count at 1"
#     fi
# }

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne Worker Node Addition"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    ensure_tailscale_ready
    verify_control_plane
    
    # GPU setup handled later to allow device plugin deployment if kubectl works
    # setup_gpu
    
    get_join_token
    install_dependencies
    configure_k8s_network_prereqs
    configure_firewall
    configure_k3s_service_dependencies "k3s-agent"
    join_cluster
    setup_model_directories  # Create model storage for LLM API
    
    # Label node and wait for confirmation from control plane
    # This MUST happen before kubectl/Longhorn installation
    label_node
    
    # Configure kubectl - REQUIRED for Longhorn disk configuration
    # Must run after labels are applied on control plane
    configure_kubectl_worker
    
    # Export KUBECONFIG so sub-scripts can access the cluster
    if [ -f "$ACTUAL_HOME/.kube/config" ]; then
        export KUBECONFIG="$ACTUAL_HOME/.kube/config"
        log_info "KUBECONFIG exported: $KUBECONFIG"
    fi
    
    # GPU setup - now that kubectl is ready, device plugin can be deployed
    setup_gpu
    
    # Install storage and services
    install_longhorn  # Interactive Longhorn installation (formats/mounts disks, adds to cluster)
    install_minio     # Shows instructions for K8s-based installation from control plane
    install_node_agent  # Starts heartbeat to control plane
    
    # Install Flannel health monitor (auto-recovery for missing flannel.1 interface)
    if [ -f "$PROJECT_ROOT/scripts/validation/monitor-flannel-health.sh" ]; then
        log_info "Installing Flannel health monitor..."
        bash "$PROJECT_ROOT/scripts/validation/monitor-flannel-health.sh" --install || \
            log_warn "Flannel health monitor installation failed (non-critical)"
    fi
    
    # Run validation tests (after labels are confirmed applied)
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Validating Worker Node Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    if [ -f "$PROJECT_ROOT/scripts/lib/validate-installation.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/validate-installation.sh" worker-node; then
            log_success "Worker node validation passed"
        else
            log_warn "Some validation tests failed (see above)"
        fi
    else
        log_warn "Validation script not found, skipping tests"
    fi
    
    # Run network validation
    if [ -f "$PROJECT_ROOT/scripts/validation/validate-network.sh" ]; then
        log_info "Running network validation..."
        bash "$PROJECT_ROOT/scripts/validation/validate-network.sh" || \
            log_warn "Network validation found issues (see above)"
    fi
    
    echo
    print_summary
}

# Run main function
main "$@"
