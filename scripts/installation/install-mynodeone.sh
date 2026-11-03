#!/bin/bash

###############################################################################
# MyNodeOne - Main Installation Script
# 
# This is the ONE script users run. It handles everything:
# - System cleanup
# - Interactive configuration
# - Node type selection
# - Automated deployment
# Note: Disk setup now handled by interactive storage installers (Longhorn/MinIO)
###############################################################################

set -euo pipefail

# Parse command-line arguments
CONFIG_FILE_ARG=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --config-file)
            CONFIG_FILE_ARG="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: sudo $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --config-file <path>    Use pre-generated config file (for remote VPS installation)"
            echo "  --help, -h              Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if running as root/sudo
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: This script must be run as root or with sudo"
    echo "Usage: sudo $0"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Detect actual user and their home directory (even when run with sudo)
export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory
    export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Running normally (as root)
    export ACTUAL_HOME="$HOME"
fi

# Cleanup function for interrupt handling
cleanup_on_interrupt() {
    echo
    echo
    print_error "Installation interrupted by user (Ctrl+C)"
    echo
    echo "Check the messages above to see how far it got, then run the script again."
    echo
    exit 130
}

# Set up interrupt handling
trap cleanup_on_interrupt INT TERM

# Helper functions
print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    # If UNATTENDED mode is enabled, use default answer
    if [ "${UNATTENDED:-0}" = "1" ]; then
        response="$default"
        echo -e "${BLUE}ℹ${NC} $prompt [using default: $default]"
    elif [ "$default" = "y" ]; then
        read -p "$(echo -e ${GREEN}?${NC}) $prompt [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$(echo -e ${GREEN}?${NC}) $prompt [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

welcome() {
    clear 2>/dev/null || true
    echo -e "${MAGENTA}"
    cat << "EOF"
   __  ___       _   __          __     ____             
  /  |/  /_  __/ | / /___  ____/ /__  / __ \____  _____ 
 / /|_/ / / / /  |/ / __ \/ __  / _ \/ / / / __ \/ _ \  
/ /  / / /_/ / /|  / /_/ / /_/ /  __/ /_/ / / / /  __/  
/_/  /_/\__, /_/ |_/\____/\__,_/\___/\____/_/ /_/\___/   
       /____/ 
                                                 
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Welcome to MyNodeOne Setup!${NC}"
    echo
    echo "This script will help you set up your private cloud infrastructure."
    echo "It handles everything automatically:"
    echo
    echo "  ✓ System optimization"
    echo "  ✓ Interactive configuration"
    echo "  ✓ Network configuration"
    echo "  ✓ Service installation"
    echo "  ✓ Storage setup (Longhorn/MinIO with disk selection)"
    echo
    echo -e "${YELLOW}Note: This script requires sudo/root access.${NC}"
    echo
    
    # Skip confirmation prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        echo -e "${BLUE}ℹ${NC} UNATTENDED mode enabled, proceeding automatically..."
        echo
        return
    fi
    
    if ! prompt_confirm "Ready to start?" "y"; then
        echo "Setup cancelled."
        exit 0
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_network() {
    print_info "Checking internet connectivity..."
    
    if ! ping -c 1 -W 5 8.8.8.8 &> /dev/null; then
        print_error "No internet connection detected"
        echo
        echo "MyNodeOne requires internet access to download components."
        echo "Please check your network connection and try again."
        echo
        echo "Troubleshooting:"
        echo "  1. Check if network cable is connected"
        echo "  2. Try: ping 8.8.8.8"
        echo "  3. Check firewall settings"
        return 1
    fi
    
    if ! ping -c 1 -W 5 github.com &> /dev/null; then
        print_warning "Can reach internet but not GitHub"
        echo "This might cause issues downloading from GitHub."
        if ! prompt_confirm "Continue anyway?"; then
            return 1
        fi
    fi
    
    print_success "Internet connection OK"
    return 0
}

check_dependencies() {
    print_info "Checking required dependencies..."
    
    local deps=("curl" "wget" "git" "lsblk" "mkfs.ext4" "blkid" "awk" "grep")
    local missing=()
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # Check for python3-yaml (used for YAML validation)
    if ! python3 -c "import yaml" 2>/dev/null; then
        missing+=("python3-yaml")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing required dependencies: ${missing[*]}"
        echo
        echo "Install with:"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y ${missing[*]}"
        return 1
    fi
    
    print_success "All dependencies present"
    return 0
}

check_architecture() {
    print_info "Detecting system architecture..."
    
    local arch=$(uname -m)
    case $arch in
        x86_64)
            print_success "Architecture: x86_64 (AMD64)"
            ;;
        aarch64)
            print_success "Architecture: aarch64 (ARM64)"
            ;;
        armv7l)
            print_success "Architecture: armv7l (ARM)"
            ;;
        *)
            print_warning "Architecture: $arch (may not be fully tested)"
            ;;
    esac
}

check_distro() {
    print_info "Checking Linux distribution..."
    
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        
        if [[ "$ID" == "ubuntu" ]]; then
            if [[ "$VERSION_ID" == "24.04" ]]; then
                print_success "Ubuntu 24.04 LTS detected (recommended)"
            elif [[ "$VERSION_ID" == "22.04" ]]; then
                print_success "Ubuntu 22.04 LTS detected (supported)"
            else
                print_warning "Ubuntu $VERSION_ID detected (not officially tested)"
                if ! prompt_confirm "Continue anyway?"; then
                    exit 1
                fi
            fi
        else
            print_warning "Non-Ubuntu distribution detected: $NAME $VERSION_ID"
            echo "MyNodeOne is optimized for Ubuntu 24.04 LTS."
            if ! prompt_confirm "Continue anyway?"; then
                exit 1
            fi
        fi
    else
        print_warning "Cannot detect distribution"
        if ! prompt_confirm "Continue anyway?"; then
            exit 1
        fi
    fi
}

check_system_resources() {
    print_info "Checking system resources..."
    
    # Check RAM
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    print_info "RAM: ${ram_gb}GB"
    
    # Show recommendations
    echo
    echo "  💡 RAM Recommendations by Node Type:"
    echo "     • Control Plane:    4GB minimum, 8GB+ recommended"
    echo "     • Worker Node:      2GB minimum, 4GB+ recommended"
    echo "     • VPS Edge Node:    1GB minimum, 2GB+ recommended"
    echo "     • Management PC:    2GB minimum"
    echo
    
    if [ "$ram_gb" -lt 2 ]; then
        print_warning "Low RAM detected (${ram_gb}GB). Some node types may not perform well."
        echo "  Consider adding more RAM if you plan to run a Control Plane or Worker node."
    fi
    
    # Check disk space
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    print_info "Available disk space: ${disk_gb}GB"
    
    if [ "$disk_gb" -lt 10 ]; then
        print_warning "Low disk space (${disk_gb}GB available). Consider freeing up space."
        echo "  Recommended: 20GB+ for Control Plane, 10GB+ for other nodes"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    print_info "CPU cores: ${cpu_cores}"
    
    if [ "$cpu_cores" -lt 2 ]; then
        print_warning "Low CPU cores (${cpu_cores}). Performance may be limited."
        echo "  Recommended: 2+ cores for smooth operation"
    fi
    
    echo
    print_success "System resource check complete"
    return 0
}

check_existing_installation() {
    if [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
        print_warning "MyNodeOne appears to be already configured on this machine"
        echo
        echo "Existing configuration found at: $ACTUAL_HOME/.mynodeone/config.env"
        echo
        
        # Load existing config to show what's installed
        source "$ACTUAL_HOME/.mynodeone/config.env"
        if [ -n "${NODE_TYPE:-}" ]; then
            print_info "Current node type: $NODE_TYPE"
        fi
        echo
        
        # In unattended mode, re-run the installation (nothing is removed)
        if [ "${UNATTENDED:-0}" = "1" ]; then
            print_info "UNATTENDED mode: Re-running installation (keeps the existing cluster and its data)"
            # Backup existing config
            cp "$ACTUAL_HOME/.mynodeone/config.env" "$ACTUAL_HOME/.mynodeone/config.env.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
            print_info "Config backed up. Proceeding..."
            return 0
        fi
        
        echo "What would you like to do?"
        echo
        echo "  1) Add/manage a remote node (VPS Edge Node, Worker, or Management Laptop)"
        echo "  2) Reconfigure this node (update configuration, keep existing setup)"
        echo "  3) Re-run installation on this node (keeps the existing cluster and its data)"
        echo "  4) Cancel"
        echo
        read -p "Select option (1-4): " option
        
        case $option in
            1)
                print_success "Proceeding to add/manage a remote node"
                print_info "You'll be prompted to select the node type in the next step"
                echo
                # Set flag to skip local system setup steps
                ADDING_REMOTE_NODE=true
                return 0
                ;;
            2)
                print_info "Reconfiguring this node..."
                return 0
                ;;
            3)
                print_info "This re-runs setup. The existing K3s install, encryption key and data are kept."
                print_info "For a real fresh start, uninstall first: this option does not delete anything."
                if prompt_confirm "Continue?"; then
                    # Backup existing config
                    cp "$ACTUAL_HOME/.mynodeone/config.env" "$ACTUAL_HOME/.mynodeone/config.env.backup-$(date +%Y%m%d-%H%M%S)"
                    print_info "Config backed up. Proceeding..."
                    return 0
                else
                    exit 0
                fi
                ;;
            4)
                print_info "Installation cancelled"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please choose 1-4."
                exit 1
                ;;
        esac
    fi
}

system_cleanup() {
    print_header "System Cleanup & Optimization"
    
    if prompt_confirm "Clean up unnecessary packages?"; then
        print_info "Removing unnecessary packages..."
        
        # WARNING: DO NOT remove snap - it's required for tools like Helm
        # Snap removal can break Firefox, Helm, and other critical tools
        # Keeping snap check disabled for safety
        
        # Remove unnecessary packages
        print_info "Removing unnecessary packages..."
        apt-get autoremove -y
        apt-get autoclean -y
        
        # Clean apt cache
        apt-get clean
        
        # Remove old kernels (keep current + 1)
        print_info "Cleaning old kernels..."
        apt-get autoremove --purge -y
        
        print_success "System cleanup complete"
    else
        print_info "Skipping system cleanup"
    fi
}

# Functions removed - interactive-setup.sh now handles node type selection
# The old flow was confusing (asked twice for node type)

show_documentation_info() {
    print_header "Documentation & Help"
    
    echo "📚 Documentation is available at:"
    echo
    echo "  • Installation Guide: $PROJECT_ROOT/docs/installation/INSTALLATION.md"
    echo "  • Getting Started: $PROJECT_ROOT/docs/guides/GETTING-STARTED.md"
    echo "  • Architecture: $PROJECT_ROOT/docs/architecture/ARCHITECTURE.md"
    echo "  • Operations: $PROJECT_ROOT/docs/guides/ADMIN-GUIDE.md"
    echo "  • FAQ: $PROJECT_ROOT/docs/reference/FAQ.md"
    echo
    echo
}

# Global flag to track if we're adding a remote node (skip local system setup)
ADDING_REMOTE_NODE=false

main() {
    # Export UNATTENDED so child scripts inherit it
    export UNATTENDED="${UNATTENDED:-0}"
    
    # If config file was provided via --config-file, use it and skip interactive setup
    if [ -n "$CONFIG_FILE_ARG" ]; then
        print_info "Using provided config file: $CONFIG_FILE_ARG"
        
        if [ ! -f "$CONFIG_FILE_ARG" ]; then
            print_error "Config file not found: $CONFIG_FILE_ARG"
            exit 1
        fi
        
        # Source the config file
        source "$CONFIG_FILE_ARG"
        export CONFIG_FILE="$CONFIG_FILE_ARG"
        
        # Validate required variables
        if [ -z "${NODE_TYPE:-}" ]; then
            print_error "Invalid config file: NODE_TYPE not set"
            exit 1
        fi
        
        print_success "Config loaded: NODE_TYPE=$NODE_TYPE"
        
        # Skip to installation directly
        SKIP_INTERACTIVE=true
    else
        SKIP_INTERACTIVE=false
    fi
    
    # Show legal disclaimer FIRST (before welcome)
    source "$SCRIPT_DIR/../utils/show-disclaimer.sh"
    
    welcome
    check_root
    
    # If using config file, run pre-flight checks and proceed to installation
    if [ "$SKIP_INTERACTIVE" = true ]; then
        print_header "Pre-Flight Checks"
        check_dependencies || exit 1
        check_architecture
        check_distro
        check_network || exit 1
        check_system_resources || exit 1
        
        # Skip directly to installation
        print_info "Skipping interactive setup (using provided config)"
    else
        # Interactive mode: Get node type FIRST before other checks
        print_header "Node Type Selection"
        print_info "First, let's determine what type of node this will be..."
        echo
        
        # Source helper functions from interactive-setup.sh
        source "$SCRIPT_DIR/interactive-setup.sh"
        
        # Call node type selection function directly
        configure_node_type
        
        # Export NODE_TYPE so it's available for subsequent checks
        export NODE_TYPE
        export NODE_ROLE
        
        # Now run pre-flight checks with node type known
        print_header "Pre-Flight Checks"
        check_dependencies || exit 1
        check_architecture
        check_distro
        check_network || exit 1
        check_system_resources || exit 1
        check_existing_installation
        
        # Skip system cleanup and documentation if we're adding a remote node
        if [ "$ADDING_REMOTE_NODE" = false ]; then
            system_cleanup
            
            # Show documentation FIRST so users know what's coming
            show_documentation_info
        fi
        
        # Continue with rest of interactive setup wizard for remaining configuration
        print_header "Configuration Wizard"
        print_info "Now let's configure the remaining settings for your $NODE_ROLE..."
        echo
        
        if ! prompt_confirm "Ready to continue with configuration?" "y"; then
            print_info "Installation cancelled."
            exit 0
        fi
        
        # Call interactive setup - but skip node type selection since we already did it
        # We'll need to modify interactive-setup.sh to skip node type if NODE_TYPE is set
        bash "$SCRIPT_DIR/interactive-setup.sh"
        
        # Load the configuration created by interactive setup
        export CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        else
            print_error "Configuration file not found after setup wizard. Exiting."
            exit 1
        fi
    fi
    
    # Only show storage setup info for control-plane and worker nodes
    if [ "$NODE_TYPE" = "control-plane" ] || [ "$NODE_TYPE" = "worker" ]; then
        echo
        print_info "💾 Storage Setup:"
        echo "  • Longhorn will prompt for disk selection during installation"
        echo "  • MinIO (optional) will prompt separately for its disks"
        echo "  • You can skip disk setup and use OS disk (works fine for testing)"
        echo
    fi
    
    echo
    print_success "Configuration complete"
    echo
    
    # For management laptops, setup is already complete - skip installation prompt
    if [ "$NODE_TYPE" = "management" ]; then
        print_info "Management laptop setup completed via interactive wizard."
        
        echo
        print_header "Setup Complete"
        print_success "Your MyNodeOne node has been set up successfully 🎉"
        echo
        echo "Next steps:"
        echo "  1. Review credentials in $ACTUAL_HOME/mynodeone-*-credentials.txt"
        echo "  2. Check status: kubectl get nodes"
        echo "  3. Deploy apps: see $PROJECT_ROOT/manifests/examples/README.md (apply one at a time; some need a Secret first)"
        echo
        return 0
    fi
    
    # Proceed with installation for other node types
    if prompt_confirm "Proceed with installation?" "y"; then
        case "$NODE_TYPE" in
            control-plane)
                print_info "Running control plane bootstrap..."
                bash "$PROJECT_ROOT/scripts/installation/bootstrap-control-plane.sh"
                ;;
            worker)
                print_info "Running worker node setup..."
                bash "$PROJECT_ROOT/scripts/nodes/add-worker-node.sh"
                ;;
            edge)
                # VPS Edge Nodes are ONLY installed via orchestration from control plane
                if [ "${VPS_ORCHESTRATED:-false}" != "true" ]; then
                    print_error "VPS Edge Nodes must be installed from the Control Plane"
                    echo
                    print_info "To add a VPS edge node:"
                    print_info "  1. SSH to your control plane"
                    print_info "  2. Run: sudo ./scripts/setup/setup-edge-node.sh"
                    echo
                    exit 1
                fi
                
                # This script is running ON the VPS (orchestrated from control plane)
                print_info "Running VPS Edge Node local installation..."
                echo
                
                # Run the VPS setup script
                bash "$PROJECT_ROOT/scripts/setup/setup-vps-node.sh"
                ;;
            *)
                print_error "Unknown node type: $NODE_TYPE"
                exit 1
                ;;
        esac
        
        echo
        print_header "Installation Complete"
        print_success "Your MyNodeOne node has been set up successfully 🎉"
        echo
        echo "Next steps:"
        echo "  1. Review credentials in $ACTUAL_HOME/mynodeone-*-credentials.txt"
        echo "  2. Check status: kubectl get nodes"
        echo "  3. Deploy apps: see $PROJECT_ROOT/manifests/examples/README.md (apply one at a time; some need a Secret first)"
        echo
    else
        print_info "Installation cancelled. Configuration saved in $CONFIG_FILE"
        print_info "Run this script again to install."
        exit 0
    fi
}

# Run main function
main "$@"
