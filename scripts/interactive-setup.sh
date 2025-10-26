#!/bin/bash

###############################################################################
# MyNodeOne Interactive Setup Wizard
# 
# This script helps you configure MyNodeOne for your specific environment
# Run this FIRST before any other scripts
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

CONFIG_DIR="$HOME/.mynodeone"
CONFIG_FILE="$CONFIG_DIR/config.env"

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

prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local value=""
    
    # If UNATTENDED mode is enabled, use default value
    if [ "${UNATTENDED:-0}" = "1" ]; then
        value="$default"
        echo -e "${BLUE}ℹ${NC} $prompt [using default: $default]"
    elif [ -n "$default" ]; then
        read -p "$(echo -e ${GREEN}?${NC}) $prompt [${default}]: " value
        value="${value:-$default}"
    else
        read -p "$(echo -e ${GREEN}?${NC}) $prompt: " value
    fi
    
    # Use printf instead of eval to avoid command injection
    printf -v "$var_name" '%s' "$value"
}

validate_hostname() {
    local name="$1"
    # RFC 1123 hostname validation: lowercase letters, numbers, hyphens, dots
    if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_cluster_name() {
    local name="$1"
    # Kubernetes label value validation
    if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        return 0
    else
        return 1
    fi
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

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID $VERSION_ID"
    else
        echo "unknown"
    fi
}

check_tailscale() {
    if command -v tailscale &> /dev/null; then
        if tailscale status &> /dev/null; then
            TAILSCALE_IP=$(tailscale ip -4 | head -n1)
            return 0
        fi
    fi
    return 1
}

install_tailscale_prompt() {
    print_header "Tailscale Setup"
    
    print_info "Tailscale is required for secure networking between nodes."
    print_info "It creates an encrypted mesh network (like a VPN, but better)."
    echo
    
    if prompt_confirm "Do you want to install Tailscale now?"; then
        print_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        
        echo
        print_info "Now we need to connect to your Tailscale network."
        print_info "This will open a browser window for authentication."
        echo
        
        if prompt_confirm "Ready to authenticate?"; then
            sudo tailscale up
            
            if check_tailscale; then
                print_success "Tailscale connected! Your IP: $TAILSCALE_IP"
                return 0
            else
                print_error "Tailscale connection failed. Please run: sudo tailscale up"
                return 1
            fi
        fi
    else
        print_warning "Skipping Tailscale installation. You'll need to install it manually."
        return 1
    fi
}

welcome() {
    clear
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
    echo -e "${CYAN}Welcome to MyNodeOne Interactive Setup!${NC}"
    echo
    echo "This wizard will help you configure MyNodeOne for your hardware."
    echo "We'll detect your environment and ask a few questions."
    echo
    echo -e "${YELLOW}Note: This wizard should be run on each machine (control plane, workers, VPS).${NC}"
    echo
    
    if ! prompt_confirm "Ready to start?" "y"; then
        echo "Setup cancelled."
        exit 0
    fi
}

detect_environment() {
    print_header "Environment Detection"
    
    # Detect OS
    OS_INFO=$(detect_os)
    print_info "Operating System: $OS_INFO"
    
    # Detect hostname
    HOSTNAME=$(hostname)
    print_info "Hostname: $HOSTNAME"
    
    # Detect resources
    TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    print_info "Resources: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"
    
    # Check for GPUs
    if lspci | grep -i nvidia &> /dev/null; then
        print_info "NVIDIA GPU detected!"
        HAS_GPU=true
    else
        HAS_GPU=false
    fi
    
    # Detect public IP (if any)
    PUBLIC_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "none")
    if [ "$PUBLIC_IP" != "none" ]; then
        print_info "Public IP: $PUBLIC_IP"
    fi
    
    # Check Tailscale
    if check_tailscale; then
        print_success "Tailscale connected: $TAILSCALE_IP"
    else
        print_warning "Tailscale not detected"
        if ! install_tailscale_prompt; then
            print_error "Tailscale is required. Please install manually and re-run this script."
            exit 1
        fi
    fi
    
    echo
}

configure_node_type() {
    print_header "Node Configuration"
    
    echo "What type of node is this?"
    echo
    echo "1) Control Plane (First node, runs Kubernetes master)"
    echo "2) Worker Node (Additional compute node)"
    echo "3) VPS Edge Node (Public-facing reverse proxy)"
    echo "4) Management Workstation (Your laptop/desktop for admin)"
    echo
    
    # In unattended mode, default to control-plane
    if [ "${UNATTENDED:-0}" = "1" ]; then
        NODE_TYPE_NUM="1"
        NODE_TYPE="control-plane"
        NODE_ROLE="Control Plane"
        echo -e "${BLUE}ℹ${NC} Select node type (1-4) [using default: 1]"
        print_success "Node type: $NODE_ROLE"
        echo
        return
    fi
    
    while true; do
        prompt_input "Select node type (1-4)" NODE_TYPE_NUM
        
        case $NODE_TYPE_NUM in
            1)
                NODE_TYPE="control-plane"
                NODE_ROLE="Control Plane"
                break
                ;;
            2)
                NODE_TYPE="worker"
                NODE_ROLE="Worker Node"
                break
                ;;
            3)
                NODE_TYPE="edge"
                NODE_ROLE="VPS Edge Node"
                break
                ;;
            4)
                NODE_TYPE="management"
                NODE_ROLE="Management Workstation"
                break
                ;;
            *)
                print_error "Invalid selection. Please choose 1-4."
                ;;
        esac
    done
    
    print_success "Node type: $NODE_ROLE"
    echo
}

configure_cluster_info() {
    print_header "Cluster Configuration"
    
    prompt_input "Give your cluster a name" CLUSTER_NAME "mynodeone"
    
    # For control plane, this is the node name
    # For workers, we'll ask for control plane IP
    prompt_input "What should we call this node?" NODE_NAME "$HOSTNAME"
    
    # Location/region label
    echo
    echo "ℹ Location helps you identify nodes in multi-location clusters."
    echo "  Examples:"
    echo "    • Home server: 'home', 'basement', 'office'"
    echo "    • Data center: 'toronto', 'newyork', 'aws-us-east'"
    echo "    • VPS provider: 'digitalocean-nyc', 'linode-ca', 'hetzner-de'"
    echo
    echo "  💡 Tip: Use the city name or provider location for VPS nodes"
    echo "          (e.g., 'digitalocean-toronto' or just 'toronto')"
    echo
    prompt_input "Where is this node located?" NODE_LOCATION "home"
    
    if [ "$NODE_TYPE" = "worker" ]; then
        echo
        print_info "Worker nodes need to connect to the control plane."
        print_info "You can find the control plane IP by running: tailscale ip -4"
        echo
        prompt_input "Enter control plane Tailscale IP" CONTROL_PLANE_IP
    fi
    
    if [ "$NODE_TYPE" = "edge" ]; then
        echo
        print_info "Edge nodes route traffic from the internet to your cluster."
        echo
        if [ "$PUBLIC_IP" != "none" ]; then
            prompt_input "Confirm this VPS public IP" VPS_PUBLIC_IP "$PUBLIC_IP"
        else
            prompt_input "Enter this VPS public IP" VPS_PUBLIC_IP
        fi
        
        prompt_input "Enter control plane Tailscale IP" CONTROL_PLANE_IP
        
        echo
        prompt_input "Enter your email for SSL certificates" SSL_EMAIL
    fi
    
    echo
}

configure_storage() {
    # Storage configuration is handled by the main mynodeone script
    # after this wizard completes. The main script will:
    # - Detect available disks
    # - Let you choose which disks to use
    # - Let you choose storage type (Longhorn/MinIO/RAID/Individual)
    # - Automatically format and mount disks
    # 
    # We don't ask for storage details here to avoid confusing users
    # before disks are actually set up.
    
    if [ "$NODE_TYPE" = "control-plane" ] || [ "$NODE_TYPE" = "worker" ]; then
        print_header "Storage Configuration"
        
        echo "Storage setup will happen after this configuration wizard."
        echo
        echo "The main installer will:"
        echo "  1. Detect your available disks"
        echo "  2. Let you choose which disks to use"
        echo "  3. Let you choose storage type:"
        echo "     • Longhorn (recommended for most users)"
        echo "     • MinIO (S3-compatible object storage)"
        echo "     • RAID array (manual redundancy)"
        echo "     • Individual mounts (no redundancy)"
        echo "  4. Automatically format and mount your disks"
        echo
        print_info "You don't need to configure storage paths now."
        print_info "The disk setup wizard will guide you through everything!"
        echo
        
        if prompt_confirm "Ready to proceed?" "y"; then
            # Just continue, storage setup happens in main script
            true
        else
            print_info "You can run this wizard again anytime."
            exit 0
        fi
        
        echo
    fi
}

configure_network() {
    if [ "$NODE_TYPE" = "control-plane" ]; then
        print_header "Network Configuration"
        
        print_info "How many VPS edge nodes will you have?"
        prompt_input "Number of VPS edge nodes" NUM_VPS "0"
        
        if [ "$NUM_VPS" -gt 0 ]; then
            echo
            print_info "Great! You'll need to run this setup wizard on each VPS."
            print_info "The VPS setup will ask for domains to configure."
        fi
        
        echo
    fi
}

configure_apps() {
    if [ "$NODE_TYPE" = "control-plane" ]; then
        print_header "Application Configuration"
        
        echo "We'll optimize your cluster based on what you plan to run."
        echo
        print_info "This helps us:"
        echo "  • Allocate appropriate resources"
        echo "  • Install helpful operators and tools"
        echo "  • Set up performance optimizations"
        echo
        print_warning "Not sure? Just say YES to everything - you can always adjust later!"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        # LLM Configuration
        echo "💬 Large Language Models (LLMs)"
        echo "   Examples: ChatGPT-like models, text generation, AI assistants"
        echo "   Uses: Ollama, llama.cpp, or external APIs (OpenAI, Anthropic)"
        echo
        if prompt_confirm "Plan to run LLMs or AI models?"; then
            ENABLE_LLM=true
            if [ "$HAS_GPU" = true ]; then
                print_success "GPU detected! We'll configure GPU-accelerated LLM support."
                print_info "You'll be able to run larger models faster."
            else
                print_info "No GPU detected. We'll configure CPU-based LLM support."
                print_info "This works for smaller models (7B-13B parameters)."
                print_info "Tip: You can add a GPU later for better performance!"
            fi
        else
            ENABLE_LLM=false
            print_info "Skipping LLM setup. You can enable this later if needed."
        fi
        
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        # Database Configuration
        echo "🗄️  Databases (PostgreSQL, MySQL, MongoDB, Redis, etc.)"
        echo "   Examples: WordPress database, app backend, analytics storage"
        echo "   Uses: Most web applications need a database"
        echo
        print_info "Saying YES will:"
        echo "  • Install database operators (easy deployment)"
        echo "  • Configure persistent storage (your data is safe)"
        echo "  • Set up backup automation"
        echo "  • Optimize for database workloads"
        echo
        print_warning "Recommendation: Say YES unless you're 100% sure you won't need databases."
        echo "               (Most applications need a database!)"
        echo
        if prompt_confirm "Plan to run databases?"; then
            ENABLE_DATABASES=true
            print_success "Database support enabled!"
            print_info "You'll be able to easily deploy PostgreSQL, MySQL, MongoDB, Redis, etc."
        else
            ENABLE_DATABASES=false
            print_info "Skipping database setup. You can enable this later if needed."
        fi
        
        echo
    fi
}

save_configuration() {
    print_header "Saving Configuration"
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_FILE" <<EOF
# MyNodeOne Configuration
# Generated: $(date)
# Node: $NODE_NAME

# Cluster
CLUSTER_NAME="$CLUSTER_NAME"
NODE_NAME="$NODE_NAME"
NODE_TYPE="$NODE_TYPE"
NODE_LOCATION="$NODE_LOCATION"

# Network
TAILSCALE_IP="$TAILSCALE_IP"
EOF

    if [ "$NODE_TYPE" = "worker" ] || [ "$NODE_TYPE" = "edge" ]; then
        cat >> "$CONFIG_FILE" <<EOF
CONTROL_PLANE_IP="$CONTROL_PLANE_IP"
EOF
    fi

    if [ "$NODE_TYPE" = "edge" ]; then
        cat >> "$CONFIG_FILE" <<EOF
VPS_PUBLIC_IP="$VPS_PUBLIC_IP"
SSL_EMAIL="$SSL_EMAIL"
EOF
    fi

    if [ "$NODE_TYPE" = "control-plane" ]; then
        cat >> "$CONFIG_FILE" <<EOF

# Network
NUM_VPS="$NUM_VPS"

# Storage - will be configured by main installer
# LONGHORN_PATH and storage type will be set during disk setup

# Features
ENABLE_LLM="$ENABLE_LLM"
ENABLE_DATABASES="$ENABLE_DATABASES"
HAS_GPU="$HAS_GPU"
EOF
    fi
    
    # Set permissions
    chmod 600 "$CONFIG_FILE"
    
    print_success "Configuration saved to: $CONFIG_FILE"
    echo
}

show_next_steps() {
    print_header "Configuration Complete"
    
    case $NODE_TYPE in
        control-plane)
            echo "✅ Your control plane configuration is saved!"
            echo
            print_info "The installer will now continue automatically with:"
            echo
            echo "  1. Disk detection and setup (if you have additional disks)"
            echo "  2. Control plane installation (K3s, Longhorn, monitoring)"
            echo "  3. Generate join tokens for worker nodes"
            echo
            if [ "$NUM_VPS" -gt 0 ]; then
                print_info "After installation, you'll need to:"
                echo "  • Configure your $NUM_VPS VPS edge node(s)"
                echo "  • Run this setup wizard on each VPS"
            fi
            ;;
        worker)
            echo "Your worker node is configured! Next:"
            echo
            echo "1. Get the join token from your control plane node"
            echo "   (It was displayed after bootstrap, or check /root/mynodeone-join-token.txt)"
            echo
            echo "2. Run the worker node script:"
            echo -e "   ${CYAN}sudo ./scripts/add-worker-node.sh${NC}"
            echo
            echo "3. The script will automatically connect to: $CONTROL_PLANE_IP"
            ;;
        edge)
            echo "Your VPS edge node is configured! Next:"
            echo
            echo "1. Run the edge node setup script:"
            echo -e "   ${CYAN}sudo ./scripts/setup-edge-node.sh${NC}"
            echo
            echo "2. Point your domain DNS A records to: $VPS_PUBLIC_IP"
            echo
            echo "3. Configure application routes in: /etc/traefik/dynamic/"
            ;;
        management)
            echo "Your management workstation is configured! Next:"
            echo
            echo "1. Install kubectl (if not already installed):"
            echo -e "   ${CYAN}curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl${NC}"
            echo -e "   ${CYAN}sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl${NC}"
            echo
            echo "2. Copy kubeconfig from control plane:"
            echo -e "   ${CYAN}scp <control-plane-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config${NC}"
            echo -e "   ${CYAN}# Edit ~/.kube/config and replace 127.0.0.1 with your control plane Tailscale IP${NC}"
            echo
            echo "3. Test connection:"
            echo -e "   ${CYAN}kubectl get nodes${NC}"
            ;;
    esac
    
    echo
    print_info "Your configuration is saved in: $CONFIG_FILE"
    print_info "All MyNodeOne scripts will automatically use this configuration."
    echo
}

main() {
    welcome
    detect_environment
    configure_node_type
    configure_cluster_info
    
    if [ "$NODE_TYPE" != "management" ]; then
        configure_storage
        configure_network
        configure_apps
    fi
    
    save_configuration
    show_next_steps
    
    print_success "Setup complete! 🎉"
    echo
}

# Run main function
main "$@"
