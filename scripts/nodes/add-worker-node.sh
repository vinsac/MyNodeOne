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
    log_success "Prerequisites check passed"
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
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
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
    
    log_success "Firewall configured (UFW enabled)"
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
    
    log_success "Successfully joined MyNodeOne cluster!"
}

# Configure kubectl on worker node
configure_kubectl_worker() {
    log_info "Configuring kubectl on worker node..."
    
    # K3s agent nodes don't create /etc/rancher/k3s/k3s.yaml (only server nodes do)
    # We need to generate kubeconfig manually for worker nodes
    
    local KUBECONFIG_DEST="$ACTUAL_HOME/.kube/config"
    
    # Create .kube directory
    mkdir -p "$ACTUAL_HOME/.kube"
    
    # Generate kubeconfig for worker node
    log_info "Generating kubeconfig for worker node..."
    
    # Wait for K3s agent to be ready
    sleep 5
    
    # Get cluster CA certificate from K3s server
    # The server-ca.crt is the certificate authority for the K3s API server
    local CA_CERT=""
    local CA_CERT_PATH="/var/lib/rancher/k3s/agent/server-ca.crt"
    
    if [ ! -f "$CA_CERT_PATH" ]; then
        log_error "Could not find K3s server CA certificate at $CA_CERT_PATH"
        log_warn "kubectl will not be available on this worker node"
        return 1
    fi
    
    CA_CERT=$(cat "$CA_CERT_PATH" | base64 -w 0)
    
    # Get client certificate and key for authentication
    # Try multiple certificate locations
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
        log_warn "Attempted paths:"
        log_warn "  - /var/lib/rancher/k3s/agent/client-k3s-controller.{crt,key}"
        log_warn "  - /var/lib/rancher/k3s/agent/client-admin.{crt,key}"
        log_warn "  - /var/lib/rancher/k3s/agent/client-kubelet.{crt,key}"
        
        # Try alternative: copy kubeconfig from control plane
        log_info "Alternative: Copy kubeconfig from control plane:"
        log_info "  scp ${CONTROL_PLANE_IP}:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
        log_info "  sed -i 's/127.0.0.1/${CONTROL_PLANE_IP}/g' ~/.kube/config"
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
    
    log_success "Kubeconfig created at $KUBECONFIG_DEST"
    
    # Test kubectl access
    if sudo -u "$ACTUAL_USER" kubectl get nodes &>/dev/null; then
        log_success "kubectl configured successfully on worker node"
        log_info "Worker can now access cluster for MinIO credential sharing"
    else
        log_warn "kubectl configured but cluster access verification failed"
        log_warn "MinIO installation may need manual credential configuration"
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
    
    echo "Worker node registered successfully!"
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
    log_success "Worker node successfully added to MyNodeOne!"
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
    echo "  ✓ MinIO (Object Storage for backups)"
    echo "  ✓ Velero (Backup system configured)"
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
        echo "⚠️  IMPORTANT: Save these credentials to your password manager NOW!"
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
    echo "  4. This node will now receive workloads automatically!"
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
        
        # Interactive GPU setup (no device plugin - that's on control plane)
        bash "$PROJECT_ROOT/scripts/lib/gpu-setup.sh" --no-plugin
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
    verify_control_plane
    
    # GPU setup early (may require reboot before continuing)
    setup_gpu
    
    get_join_token
    install_dependencies
    configure_firewall
    join_cluster
    setup_model_directories  # Create model storage for LLM API
    
    # Label node and wait for confirmation from control plane
    # This MUST happen before kubectl/Longhorn installation
    label_node
    
    # Configure kubectl - REQUIRED for Longhorn disk configuration
    # Must run after labels are applied on control plane
    configure_kubectl_worker
    
    # Install storage and services
    install_longhorn  # Interactive Longhorn installation (formats/mounts disks, adds to cluster)
    install_minio     # Shows instructions for K8s-based installation from control plane
    install_node_agent  # Starts heartbeat to control plane
    
    # Run validation tests (after labels are confirmed applied)
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Validating Worker Node Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    if [ -f "$PROJECT_ROOT/scripts/lib/validate-installation.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/validate-installation.sh" worker-node; then
            log_success "Worker node validation passed!"
        else
            log_warn "Some validation tests failed (see above)"
        fi
    else
        log_warn "Validation script not found, skipping tests"
    fi
    
    echo
    print_summary
}

# Run main function
main "$@"
