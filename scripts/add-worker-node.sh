#!/bin/bash

###############################################################################
# MyNodeOne Worker Node Addition Script
# 
# This script adds a new worker node to the MyNodeOne cluster
# Run this on the NEW worker node (e.g., node-002, node-003, etc.)
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
    echo "Please run: ./scripts/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

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
        log_error "Configuration incomplete. Please run: ./scripts/interactive-setup.sh"
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
    
    cat > "$ACTUAL_HOME/mynodeone-node-labels.txt" <<EOF
# Apply node labels on the control plane:
$LABEL_CMD
EOF
    
    # Fix ownership (script runs as root via sudo)
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/mynodeone-node-labels.txt"
    
    log_success "Node labels saved to $ACTUAL_HOME/mynodeone-node-labels.txt"
    echo
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
    echo
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
    echo "     ./scripts/nodes-status.sh"
    echo
    echo "  4. This node will now receive workloads automatically!"
    echo "     vLLM pods will use pre-synced models for instant startup."
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

install_node_agent() {
    log_info "Installing Node Agent for pull-based config sync..."
    
    if [ -f "$SCRIPT_DIR/lib/install-config-sync.sh" ]; then
        # Get API token from config if available
        API_TOKEN="${API_TOKEN:-}"
        
        # Get SSH user for control plane to enable automatic token fetch
        # Try to get from config or environment
        CP_SSH_USER="${CONTROL_PLANE_USER:-}"
        
        # Call install-config-sync with ssh-user parameter for automatic token fetch
        # Arguments: node-type control-plane-ip api-token node-name ssh-user
        if bash "$SCRIPT_DIR/lib/install-config-sync.sh" worker "$CONTROL_PLANE_IP" "$API_TOKEN" "$NODE_NAME" "$CP_SSH_USER"; then
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
    
    if [ -f "$SCRIPT_DIR/lib/gpu-setup.sh" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  NVIDIA GPU Detected"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        lspci | grep -i nvidia | head -3
        echo ""
        
        # Interactive GPU setup (no device plugin - that's on control plane)
        bash "$SCRIPT_DIR/lib/gpu-setup.sh" --no-plugin
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

disable_longhorn_on_worker() {
    log_info "Configuring Longhorn to use control plane only..."
    
    # Wait for Longhorn to be ready
    log_info "Waiting for Longhorn to initialize on control plane..."
    sleep 10
    
    # Get this worker node's name
    local WORKER_NODE_NAME=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$WORKER_NODE_NAME" ]; then
        log_warn "Could not detect worker node name, skipping Longhorn configuration"
        return 0
    fi
    
    log_info "Worker node name: $WORKER_NODE_NAME"
    
    # Wait for Longhorn node CRD to be created
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get nodes.longhorn.io "$WORKER_NODE_NAME" -n longhorn-system &> /dev/null; then
            log_success "Longhorn node CRD found"
            break
        fi
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "Longhorn node CRD not found after ${max_attempts} attempts"
            log_warn "Longhorn may not be installed or not ready yet"
            return 0
        fi
        
        log_info "Waiting for Longhorn node CRD... (attempt $attempt/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done
    
    # Disable scheduling on this worker node
    log_info "Disabling Longhorn scheduling on worker node..."
    
    if kubectl -n longhorn-system patch nodes.longhorn.io "$WORKER_NODE_NAME" \
        --type=merge -p '{"spec":{"allowScheduling":false}}' 2>&1; then
        log_success "Longhorn scheduling disabled on worker node"
        log_info "Longhorn will only use control plane for storage"
    else
        log_warn "Could not disable Longhorn scheduling on worker"
        log_warn "You can do this manually via Longhorn UI or:"
        log_warn "  kubectl -n longhorn-system patch nodes.longhorn.io $WORKER_NODE_NAME --type=merge -p '{\"spec\":{\"allowScheduling\":false}}'"
    fi
}

install_minio_worker() {
    log_info "Installing MinIO object storage on worker node..."
    
    # Call modular MinIO worker installation script
    if [ -f "$SCRIPT_DIR/storage/install-minio-worker.sh" ]; then
        if bash "$SCRIPT_DIR/storage/install-minio-worker.sh"; then
            log_success "MinIO installed successfully on worker node"
        else
            log_error "MinIO installation failed"
            log_warn "Object storage will not be available"
            log_warn "You can install manually later:"
            log_warn "  sudo $SCRIPT_DIR/storage/install-minio-worker.sh"
        fi
    else
        log_error "MinIO installation script not found: $SCRIPT_DIR/storage/install-minio-worker.sh"
        log_warn "Skipping MinIO installation"
    fi
}

configure_velero_backup() {
    log_info "Configuring Velero backup to use MinIO..."
    
    # Check if Velero is installed
    if ! kubectl get deployment velero -n velero &> /dev/null; then
        log_warn "Velero not found on control plane"
        log_warn "Backups will not be configured"
        log_warn "Install Velero on control plane first"
        return 0
    fi
    
    # Check if MinIO is running
    if ! kubectl get svc minio -n minio &> /dev/null; then
        log_warn "MinIO not found, skipping Velero backup configuration"
        log_warn "Run this after MinIO is installed:"
        log_warn "  sudo $SCRIPT_DIR/storage/configure-velero-backup.sh"
        return 0
    fi
    
    # Call modular Velero backup configuration script
    if [ -f "$SCRIPT_DIR/storage/configure-velero-backup.sh" ]; then
        if bash "$SCRIPT_DIR/storage/configure-velero-backup.sh"; then
            log_success "Velero backup configured successfully"
            log_info "Nightly backups scheduled: 2:00 AM UTC"
            log_info "Retention: 6 months"
        else
            log_error "Velero backup configuration failed"
            log_warn "You can configure manually later:"
            log_warn "  sudo $SCRIPT_DIR/storage/configure-velero-backup.sh"
        fi
    else
        log_error "Velero backup configuration script not found: $SCRIPT_DIR/storage/configure-velero-backup.sh"
        log_warn "Skipping Velero backup configuration"
    fi
}

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
    label_node
    disable_longhorn_on_worker  # Configure Longhorn to use control plane only
    install_minio_worker  # Install MinIO on worker with local disks
    configure_velero_backup  # Configure Velero to backup to MinIO
    install_node_agent
    
    # Run validation tests
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Validating Worker Node Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    if [ -f "$SCRIPT_DIR/lib/validate-installation.sh" ]; then
        if bash "$SCRIPT_DIR/lib/validate-installation.sh" worker-node; then
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
