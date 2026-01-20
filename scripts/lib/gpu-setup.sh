# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/project-root.sh" 2>/dev/null || source "$SCRIPT_DIR/../lib/project-root.sh"
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

# Set KUBECONFIG appropriately
export_k8s_config || true # Fallback is fine for host-only setup

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Configuration
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-550}"  # Default driver version
DEVICE_PLUGIN_VERSION="${DEVICE_PLUGIN_VERSION:-v0.14.5}"
REBOOT_REQUIRED=false

###############################################################################
# Detection Functions
###############################################################################

# Check if NVIDIA GPU is present
detect_nvidia_gpu() {
    log_info "[INFO] Running GPU detection with lspci..."
    local gpu_found=$(lspci 2>/dev/null | grep -i "nvidia")
    if [ -n "$gpu_found" ]; then
        log_info "[INFO] GPU found: $gpu_found"
        return 0
    else
        log_warn "[INFO] No NVIDIA GPU found in lspci output"
        return 1
    fi
}

# Get GPU model info
get_gpu_info() {
    lspci 2>/dev/null | grep -i "nvidia" | head -5
}

# Check if NVIDIA driver is installed
is_driver_installed() {
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if container toolkit is installed
is_container_toolkit_installed() {
    if command -v nvidia-ctk &>/dev/null; then
        return 0
    fi
    return 1
}

# Check if device plugin is deployed
is_device_plugin_deployed() {
    if command -v kubectl &>/dev/null; then
        if kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset &>/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Get current driver version
get_driver_version() {
    if is_driver_installed; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1
    else
        echo "not installed"
    fi
}

###############################################################################
# Installation Functions
###############################################################################

# Install NVIDIA driver
install_nvidia_driver() {
    log_step "Installing NVIDIA Driver (version $NVIDIA_DRIVER_VERSION)..."
    
    # Check if already installed
    if is_driver_installed; then
        local current_version
        current_version=$(get_driver_version)
        log_info "NVIDIA driver already installed (version: $current_version)"
        return 0
    fi
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    else
        log_error "Cannot detect OS version"
        return 1
    fi
    
    case "$ID" in
        ubuntu|debian)
            install_driver_ubuntu
            ;;
        fedora|rhel|centos|rocky|almalinux)
            install_driver_rhel
            ;;
        *)
            log_error "Unsupported OS: $ID"
            log_info "Please install NVIDIA driver manually"
            return 1
            ;;
    esac
}

# Install driver on Ubuntu/Debian
install_driver_ubuntu() {
    log_info "Installing on Ubuntu/Debian..."
    
    # Update package list
    apt-get update -qq
    
    # Install ubuntu-drivers tool
    apt-get install -y -qq ubuntu-drivers-common
    
    # Show recommended driver
    log_info "Detecting recommended driver for your GPU..."
    ubuntu-drivers devices 2>/dev/null | grep -i nvidia || true
    
    # Auto-install the recommended driver
    log_info "Installing recommended NVIDIA driver (ubuntu-drivers autoinstall)..."
    if ubuntu-drivers autoinstall; then
        REBOOT_REQUIRED=true
        log_success "NVIDIA driver installed (recommended version)"
    else
        # Fallback to manual install if autoinstall fails
        log_warn "ubuntu-drivers autoinstall failed, trying manual install..."
        apt-get install -y -qq software-properties-common
        if ! grep -q "graphics-drivers" /etc/apt/sources.list.d/* 2>/dev/null; then
            add-apt-repository -y ppa:graphics-drivers/ppa
            apt-get update -qq
        fi
        apt-get install -y nvidia-driver-${NVIDIA_DRIVER_VERSION}
        REBOOT_REQUIRED=true
        log_success "NVIDIA driver installed (version ${NVIDIA_DRIVER_VERSION})"
    fi
}

# Install driver on RHEL/Fedora
install_driver_rhel() {
    log_info "Installing on RHEL/Fedora..."
    
    # Enable EPEL if needed
    if command -v dnf &>/dev/null; then
        dnf install -y epel-release || true
        dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo || \
        dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo || true
        dnf install -y nvidia-driver-${NVIDIA_DRIVER_VERSION} || dnf install -y nvidia-driver
    else
        yum install -y epel-release || true
        yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo || true
        yum install -y nvidia-driver-${NVIDIA_DRIVER_VERSION} || yum install -y nvidia-driver
    fi
    
    REBOOT_REQUIRED=true
    log_success "NVIDIA driver installed"
}

# Install NVIDIA Container Toolkit
install_container_toolkit() {
    log_step "Installing NVIDIA Container Toolkit..."
    
    if is_container_toolkit_installed; then
        log_info "NVIDIA Container Toolkit already installed"
        return 0
    fi
    
    # Detect OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    fi
    
    case "$ID" in
        ubuntu|debian)
            install_toolkit_ubuntu
            ;;
        fedora|rhel|centos|rocky|almalinux)
            install_toolkit_rhel
            ;;
        *)
            log_error "Unsupported OS: $ID"
            return 1
            ;;
    esac
    
    # Configure for containerd (K3s uses containerd)
    configure_containerd
}

# Install toolkit on Ubuntu/Debian
install_toolkit_ubuntu() {
    log_info "Installing Container Toolkit on Ubuntu/Debian..."
    
    # Add NVIDIA repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    
    log_success "NVIDIA Container Toolkit installed"
}

# Install toolkit on RHEL/Fedora
install_toolkit_rhel() {
    log_info "Installing Container Toolkit on RHEL/Fedora..."
    
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
        tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    
    if command -v dnf &>/dev/null; then
        dnf install -y nvidia-container-toolkit
    else
        yum install -y nvidia-container-toolkit
    fi
    
    log_success "NVIDIA Container Toolkit installed"
}

# Configure containerd for GPU support
configure_containerd() {
    log_info "Configuring containerd for GPU support..."
    
    # Check if K3s is installed (uses its own bundled containerd)
    if [ -d "/var/lib/rancher/k3s" ] || systemctl is-active --quiet k3s || systemctl is-active --quiet k3s-agent; then
        log_info "K3s detected - using K3s auto-detection for GPU..."
        
        # K3s bundles its own runc, but nvidia-container-runtime can't find it
        # Create symlink so nvidia runtime can use K3s's runc
        if [ ! -f /usr/bin/runc ] && [ -f /var/lib/rancher/k3s/data/current/bin/runc ]; then
            log_info "Creating runc symlink for nvidia-container-runtime..."
            ln -sf /var/lib/rancher/k3s/data/current/bin/runc /usr/bin/runc
            log_success "runc symlink created"
        elif [ ! -f /usr/bin/runc ]; then
            # Try to find runc in K3s data directory
            local k3s_runc=$(find /var/lib/rancher/k3s/data -name "runc" -type f 2>/dev/null | head -1)
            if [ -n "$k3s_runc" ]; then
                log_info "Creating runc symlink from $k3s_runc..."
                ln -sf "$k3s_runc" /usr/bin/runc
                log_success "runc symlink created"
            else
                log_warn "Could not find runc - nvidia runtime may not work"
            fi
        fi
        
        # K3s v1.28+ auto-detects nvidia-container-runtime and configures containerd
        # Remove any old manual config templates that might cause conflicts
        local k3s_config_tmpl="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
        if [ -f "$k3s_config_tmpl" ]; then
            log_info "Removing old containerd config template (K3s will auto-configure)..."
            rm -f "$k3s_config_tmpl"
        fi
        
        # Verify nvidia-container-runtime is present for K3s to detect
        if [ -f /usr/bin/nvidia-container-runtime ]; then
            log_success "nvidia-container-runtime found - K3s will auto-configure GPU support"
        else
            log_warn "nvidia-container-runtime not found at /usr/bin/nvidia-container-runtime"
            log_warn "GPU support may not work. Check nvidia-container-toolkit installation."
        fi
        
        # Restart K3s (server or agent) to trigger auto-detection
        if systemctl is-active --quiet k3s; then
            log_info "Restarting K3s server to enable GPU auto-detection..."
            systemctl restart k3s
            
            # Wait for K3s to be ready
            sleep 10
            local attempts=0
            while [ $attempts -lt 30 ]; do
                if kubectl get nodes &>/dev/null; then
                    log_success "K3s server restarted with GPU support"
                    return 0
                fi
                sleep 2
                attempts=$((attempts + 1))
            done
            log_warn "K3s taking longer to restart - check with: kubectl get nodes"
        elif systemctl is-active --quiet k3s-agent; then
            log_info "Restarting K3s agent to enable GPU auto-detection..."
            systemctl restart k3s-agent
            sleep 5
            log_success "K3s agent restarted with GPU support"
        fi
    else
        # Standard containerd (not K3s)
        log_info "Configuring standard containerd for GPU..."
        nvidia-ctk runtime configure --runtime=containerd
        
        # Restart containerd
        if systemctl is-active --quiet containerd; then
            systemctl restart containerd
            log_success "containerd restarted with GPU support"
        else
            log_warn "containerd not running - will be configured on next start"
        fi
    fi
}

# Deploy NVIDIA Device Plugin to Kubernetes
deploy_device_plugin() {
    log_step "Deploying NVIDIA Device Plugin to Kubernetes..."
    
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found - skipping device plugin deployment"
        log_info "Run this after K3s is installed: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
        return 0
    fi
    
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_warn "Kubernetes cluster not accessible - skipping device plugin deployment"
        log_info "Run this after cluster is ready: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
        return 0
    fi
    
    if is_device_plugin_deployed; then
        log_info "NVIDIA Device Plugin already deployed"
        return 0
    fi
    
    kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
    
    log_success "NVIDIA Device Plugin deployed"
    log_info "GPU resources will be available as 'nvidia.com/gpu' in pod specs"
}

###############################################################################
# Status and Verification
###############################################################################

# Show GPU status
show_gpu_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                      GPU STATUS REPORT                             "
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    
    # Hardware detection
    echo "Hardware Detection:"
    if detect_nvidia_gpu; then
        echo -e "  ${GREEN}✓${NC} NVIDIA GPU detected"
        get_gpu_info | while read -r line; do
            echo "    $line"
        done
    else
        echo -e "  ${YELLOW}○${NC} No NVIDIA GPU detected"
    fi
    echo ""
    
    # Driver status
    echo "Driver Status:"
    if is_driver_installed; then
        local version
        version=$(get_driver_version)
        echo -e "  ${GREEN}✓${NC} NVIDIA driver installed (version: $version)"
        echo ""
        echo "  GPU Details:"
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | \
            while read -r line; do
                echo "    $line"
            done
    else
        echo -e "  ${RED}✗${NC} NVIDIA driver not installed"
    fi
    echo ""
    
    # Container toolkit status
    echo "Container Toolkit:"
    if is_container_toolkit_installed; then
        echo -e "  ${GREEN}✓${NC} NVIDIA Container Toolkit installed"
    else
        echo -e "  ${RED}✗${NC} NVIDIA Container Toolkit not installed"
    fi
    echo ""
    
    # Kubernetes device plugin
    echo "Kubernetes Device Plugin:"
    if is_device_plugin_deployed; then
        echo -e "  ${GREEN}✓${NC} NVIDIA Device Plugin deployed"
        
        # Check for GPU resources on nodes
        if kubectl get nodes -o json 2>/dev/null | grep -q "nvidia.com/gpu"; then
            echo ""
            echo "  GPU Resources on Nodes:"
            kubectl get nodes -o custom-columns="NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu" 2>/dev/null | \
                grep -v "<none>" | while read -r line; do
                    echo "    $line"
                done
        fi
    else
        echo -e "  ${YELLOW}○${NC} NVIDIA Device Plugin not deployed (or kubectl not available)"
    fi
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
}

# Verify GPU is accessible from containers
verify_gpu_access() {
    log_step "Verifying GPU access from containers..."
    
    if ! is_driver_installed; then
        log_error "NVIDIA driver not installed - cannot verify"
        return 1
    fi
    
    if ! command -v docker &>/dev/null && ! command -v nerdctl &>/dev/null; then
        log_warn "No container runtime found for verification"
        return 0
    fi
    
    # Try with docker first, then nerdctl
    local runtime="docker"
    if ! command -v docker &>/dev/null; then
        runtime="nerdctl"
    fi
    
    log_info "Testing GPU access with $runtime..."
    
    if $runtime run --rm --gpus all nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
        log_success "GPU is accessible from containers"
        return 0
    else
        log_error "GPU not accessible from containers"
        return 1
    fi
}

###############################################################################
# Interactive Setup
###############################################################################

# Ask user if they want GPU setup
prompt_gpu_setup() {
    # Check if GPU is present
    if ! detect_nvidia_gpu; then
        log_info "No NVIDIA GPU detected on this system"
        return 1
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "                      NVIDIA GPU DETECTED                           "
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""
    echo "Found NVIDIA GPU(s):"
    get_gpu_info | while read -r line; do
        echo "  • $line"
    done
    echo ""
    echo "GPU support enables:"
    echo "  • Running LLMs (vLLM, Ollama, text-generation-inference)"
    echo "  • AI/ML workloads (PyTorch, TensorFlow)"
    echo "  • GPU-accelerated applications"
    echo ""
    echo "This will install:"
    echo "  • NVIDIA Driver (on host)"
    echo "  • NVIDIA Container Toolkit (on host)"
    echo "  • NVIDIA Device Plugin (on Kubernetes)"
    echo ""
    
    read -rp "Would you like to enable GPU support? [Y/n] " response
    case "$response" in
        [nN][oO]|[nN])
            log_info "Skipping GPU setup"
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

###############################################################################
# Main Functions
###############################################################################

# Full GPU setup
setup_gpu() {
    local deploy_plugin="${1:-true}"
    
    log_info "Starting NVIDIA GPU setup..."
    echo ""
    
    # Check for GPU
    if ! detect_nvidia_gpu; then
        log_error "No NVIDIA GPU detected"
        return 1
    fi
    
    # Install driver
    install_nvidia_driver
    
    # Check if reboot is needed before continuing
    if [[ "$REBOOT_REQUIRED" == "true" ]] && ! is_driver_installed; then
        echo ""
        log_warn "═══════════════════════════════════════════════════════════════"
        log_warn "  REBOOT REQUIRED"
        log_warn "═══════════════════════════════════════════════════════════════"
        log_warn ""
        log_warn "  NVIDIA driver was installed but requires a reboot."
        log_warn "  After rebooting, run this script again to complete setup:"
        log_warn ""
        log_warn "    sudo $0"
        log_warn ""
        log_warn "═══════════════════════════════════════════════════════════════"
        return 2  # Special exit code for reboot required
    fi
    
    # Install container toolkit
    install_container_toolkit
    
    # Deploy device plugin if requested and on control plane
    if [[ "$deploy_plugin" == "true" ]]; then
        deploy_device_plugin
    fi
    
    echo ""
    log_success "GPU setup complete"
    show_gpu_status
}

# Print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --auto          Auto-detect GPU and install if found"
    echo "  --skip          Skip GPU setup entirely"
    echo "  --check         Check GPU status only (no installation)"
    echo "  --driver-only   Install driver only (no container toolkit)"
    echo "  --toolkit-only  Install container toolkit only (driver already installed)"
    echo "  --no-plugin     Skip Kubernetes device plugin deployment"
    echo "  --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  NVIDIA_DRIVER_VERSION    Driver version to install (default: 550)"
    echo "  DEVICE_PLUGIN_VERSION    K8s device plugin version (default: v0.14.5)"
}

# Main entry point
main() {
    local mode="interactive"
    local deploy_plugin=true
    
    log_info "[INFO] gpu-setup.sh started with args: $@"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto)
                log_info "[INFO] Setting mode to 'auto'"
                mode="auto"
                shift
                ;;
            --skip)
                log_info "GPU setup skipped"
                exit 0
                ;;
            --check)
                show_gpu_status
                exit 0
                ;;
            --driver-only)
                mode="driver-only"
                shift
                ;;
            --toolkit-only)
                mode="toolkit-only"
                shift
                ;;
            --no-plugin)
                deploy_plugin=false
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)"
        exit 1
    fi
    
    log_info "[INFO] Entering mode: $mode"
    
    case "$mode" in
        interactive)
            log_info "[INFO] Interactive mode - prompting user"
            if prompt_gpu_setup; then
                setup_gpu "$deploy_plugin"
            fi
            ;;
        auto)
            log_info "[INFO] Auto mode - detecting GPU"
            if detect_nvidia_gpu; then
                log_info "[INFO] GPU detected - proceeding with setup"
                setup_gpu "$deploy_plugin"
            else
                log_info "No NVIDIA GPU detected - skipping GPU setup"
                log_info "[INFO] Exiting due to no GPU detection"
            fi
            ;;
        driver-only)
            install_nvidia_driver
            ;;
        toolkit-only)
            log_info "Installing NVIDIA Container Toolkit (driver already present)..."
            install_container_toolkit
            if [[ "$deploy_plugin" == "true" ]]; then
                deploy_device_plugin
            fi
            log_success "Container Toolkit setup complete"
            show_gpu_status
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    log_info "[INFO] Script executed directly, calling main"
    main "$@"
else
    log_info "[INFO] Script sourced, functions available"
fi
