#!/bin/bash

###############################################################################
# MyNodeOne Uninstall Script
# 
# Safely removes MyNodeOne from any node type:
#   - Control Plane
#   - Worker Node
#   - Management Laptop
#   - VPS Edge Node
#
# Options:
#   --keep-config     Keep configuration files for reinstall
#   --keep-data       Keep application data (PVCs)
#   --full            Remove everything (configs + data)
#   --help            Show this help message
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

# Default options
KEEP_CONFIG=false
KEEP_DATA=false
INTERACTIVE=true

print_header() {
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
MyNodeOne Uninstall Script

Usage: sudo ./scripts/uninstall-mynodeone.sh [OPTIONS]

OPTIONS:
    --keep-config       Keep configuration files (~/.mynodeone/)
    --keep-data         Keep application data (Longhorn volumes, PVCs)
    --full              Remove everything (default if no options)
    --yes               Non-interactive mode (auto-confirm)
    --help              Show this help message

EXAMPLES:
    # Interactive uninstall (asks what to keep)
    sudo ./scripts/uninstall-mynodeone.sh

    # Keep config for reinstall
    sudo ./scripts/uninstall-mynodeone.sh --keep-config

    # Keep data but remove cluster
    sudo ./scripts/uninstall-mynodeone.sh --keep-data

    # Complete removal
    sudo ./scripts/uninstall-mynodeone.sh --full

WHAT GETS REMOVED:
    • Kubernetes cluster (K3s)
    • All running pods and services
    • Docker/containerd images
    • Longhorn storage system
    • Systemd services (sync-controller)
    • VPS Traefik setup (/etc/traefik/)
    • DNS configurations (/etc/hosts, dnsmasq, Avahi)
    • Cron jobs (VPS sync)
    • Tailscale configuration (optional)
    • Config files from all users (root + sudo user)

WHAT CAN BE KEPT:
    • Configuration files (~/.mynodeone/config.env)
    • Application data (Longhorn volumes)
    • Formatted disks (always kept)
    • Tailscale installation (always kept)

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-config)
            KEEP_CONFIG=true
            shift
            ;;
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
        --full)
            KEEP_CONFIG=false
            KEEP_DATA=false
            shift
            ;;
        --yes|-y)
            INTERACTIVE=false
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    log_error "This script must be run as root or with sudo"
    echo "Usage: sudo $0"
    exit 1
fi

# Detect node type
detect_node_type() {
    local node_type="unknown"
    
    if [ -f "$HOME/.mynodeone/config.env" ]; then
        source "$HOME/.mynodeone/config.env"
        node_type="${NODE_TYPE:-unknown}"
    fi
    
    # Try to detect from running services
    if [ "$node_type" = "unknown" ]; then
        if systemctl is-active --quiet k3s 2>/dev/null; then
            if kubectl get nodes 2>/dev/null | grep -q "control-plane"; then
                node_type="control-plane"
            else
                node_type="worker"
            fi
        elif command -v kubectl &> /dev/null; then
            node_type="management"
        fi
    fi
    
    echo "$node_type"
}

NODE_TYPE=$(detect_node_type)

print_header "MyNodeOne Uninstall"

echo -e "${CYAN}Detected Node Type:${NC} ${MAGENTA}${NODE_TYPE}${NC}"
echo

# Load config if it exists
CONFIG_FILE="$HOME/.mynodeone/config.env"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "Configuration found:"
    echo "  • Cluster: ${CLUSTER_NAME:-N/A}"
    echo "  • Domain: ${CLUSTER_DOMAIN:-N/A}.local"
    echo "  • Node: ${NODE_NAME:-N/A}"
else
    echo "No configuration file found"
fi
echo

# Interactive prompts if not set via arguments
if [ "$INTERACTIVE" = true ] && [ "$KEEP_CONFIG" = false ] && [ "$KEEP_DATA" = false ]; then
    echo -e "${YELLOW}⚠️  What would you like to remove?${NC}"
    echo
    
    read -p "Remove Kubernetes cluster and all apps? [Y/n]: " -r
    REMOVE_K8S=true
    [[ $REPLY =~ ^[Nn]$ ]] && REMOVE_K8S=false
    
    if [ "$REMOVE_K8S" = true ]; then
        read -p "Delete application data (photos, videos, etc.)? [y/N]: " -r
        [[ $REPLY =~ ^[Yy]$ ]] && KEEP_DATA=false || KEEP_DATA=true
    fi
    
    read -p "Delete MyNodeOne configuration files? [y/N]: " -r
    [[ $REPLY =~ ^[Yy]$ ]] && KEEP_CONFIG=false || KEEP_CONFIG=true
    
    read -p "Remove Docker/container images? [Y/n]: " -r
    REMOVE_IMAGES=true
    [[ $REPLY =~ ^[Nn]$ ]] && REMOVE_IMAGES=false
    
    read -p "Remove Tailscale? [y/N]: " -r
    REMOVE_TAILSCALE=false
    [[ $REPLY =~ ^[Yy]$ ]] && REMOVE_TAILSCALE=true
    
    echo
else
    REMOVE_K8S=true
    REMOVE_IMAGES=true
    REMOVE_TAILSCALE=false
fi

# Summary
print_header "Uninstall Summary"

echo "The following will be removed:"
echo
[ "$REMOVE_K8S" = true ] && echo "  ✓ Kubernetes cluster (K3s)"
[ "$REMOVE_K8S" = true ] && [ "$KEEP_DATA" = false ] && echo "  ✓ Application data (PVCs, volumes)"
[ "$REMOVE_IMAGES" = true ] && echo "  ✓ Container images"
[ "$KEEP_CONFIG" = false ] && echo "  ✓ Configuration files"
[ "$REMOVE_TAILSCALE" = true ] && echo "  ✓ Tailscale"
echo "  ✓ DNS configurations"
echo "  ✓ System modifications"
echo

echo "The following will be kept:"
echo
[ "$KEEP_CONFIG" = true ] && echo "  • Configuration files (~/.mynodeone/)"
[ "$KEEP_DATA" = true ] && echo "  • Application data"
[ "$REMOVE_TAILSCALE" = false ] && echo "  • Tailscale installation"
echo "  • Formatted disks (unmounted)"
echo

if [ "$INTERACTIVE" = true ]; then
    echo -e "${RED}⚠️  This action cannot be undone!${NC}"
    echo
    read -p "Continue with uninstall? [y/N]: " -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        exit 0
    fi
fi

# Start uninstall
print_header "Starting Uninstall"

# Step 1: Stop K3s
if [ "$REMOVE_K8S" = true ]; then
    log_info "[1/8] Stopping Kubernetes..."
    if systemctl is-active --quiet k3s 2>/dev/null; then
        systemctl stop k3s 2>/dev/null || true
        log_success "K3s stopped"
    elif systemctl is-active --quiet k3s-agent 2>/dev/null; then
        systemctl stop k3s-agent 2>/dev/null || true
        log_success "K3s agent stopped"
    else
        log_info "K3s not running"
    fi
else
    log_info "[1/8] Keeping Kubernetes cluster (skipped)"
fi
echo

# Step 2: Backup data if requested
if [ "$REMOVE_K8S" = true ] && [ "$KEEP_DATA" = true ]; then
    log_info "[2/8] Preserving application data..."
    # Data will be kept on Longhorn volumes (disks stay mounted)
    log_success "Data will be preserved on storage disks"
else
    log_info "[2/8] Application data will be removed with cluster"
fi
echo

# Step 3: Remove container images
if [ "$REMOVE_IMAGES" = true ]; then
    log_info "[3/8] Removing container images..."
    if command -v crictl &> /dev/null; then
        crictl rmi --prune 2>/dev/null || true
        log_success "Container images removed"
    else
        log_info "crictl not found, skipping"
    fi
else
    log_info "[3/8] Keeping container images (skipped)"
fi
echo

# Step 4: Uninstall K3s
if [ "$REMOVE_K8S" = true ]; then
    log_info "[4/8] Uninstalling Kubernetes..."
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        log_success "K3s uninstalled"
    elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
        log_success "K3s agent uninstalled"
    else
        log_info "K3s not installed"
    fi
else
    log_info "[4/8] Keeping Kubernetes cluster (skipped)"
fi
echo

# Step 5: Unmount Longhorn disks
log_info "[5/8] Unmounting storage disks..."
if [ -d /mnt/longhorn-disks ]; then
    for mount in /mnt/longhorn-disks/disk-*; do
        if mountpoint -q "$mount" 2>/dev/null; then
            umount "$mount" 2>/dev/null || umount -l "$mount" 2>/dev/null || true
            log_success "Unmounted $mount"
        fi
    done
    
    # Remove fstab entries
    if grep -q "longhorn-disks" /etc/fstab 2>/dev/null; then
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
        sed -i '/mnt\/longhorn-disks/d' /etc/fstab
        log_success "Removed fstab entries"
    fi
else
    log_info "No Longhorn disks found"
fi
echo

# Step 6: Remove DNS configurations
log_info "[6/8] Removing DNS configurations..."

# Remove from /etc/hosts
if grep -q "# MyNodeOne" /etc/hosts 2>/dev/null; then
    cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d_%H%M%S)
    sed -i '/# MyNodeOne/,/# End MyNodeOne/d' /etc/hosts
    log_success "Removed /etc/hosts entries"
fi

# Remove dnsmasq configs
if [ -d /etc/dnsmasq.d ]; then
    rm -f /etc/dnsmasq.d/*-apps.conf 2>/dev/null || true
    rm -f /etc/dnsmasq.d/mynodeone*.conf 2>/dev/null || true
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl restart dnsmasq 2>/dev/null || true
    fi
fi

# Remove Avahi configs
if [ -f /etc/avahi/services/mynodeone.service ]; then
    rm -f /etc/avahi/services/mynodeone.service
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        systemctl restart avahi-daemon 2>/dev/null || true
    fi
fi

log_success "DNS configurations removed"
echo

# Step 7: Remove systemd services and VPS components
log_info "[7/10] Removing systemd services and VPS components..."

# Remove sync controller service (control plane)
if [ -f /etc/systemd/system/mynodeone-sync-controller.service ]; then
    systemctl stop mynodeone-sync-controller 2>/dev/null || true
    systemctl disable mynodeone-sync-controller 2>/dev/null || true
    rm -f /etc/systemd/system/mynodeone-sync-controller.service
    systemctl daemon-reload
    log_success "Removed sync controller service"
fi

# Remove VPS Traefik setup
if [ -d /etc/traefik ]; then
    log_info "Detected VPS Traefik installation..."
    
    # Stop docker compose
    if [ -f /etc/traefik/docker-compose.yml ]; then
        (cd /etc/traefik && docker compose down 2>/dev/null) || true
        log_success "Stopped Traefik containers"
    fi
    
    # Remove Traefik directory
    if [ "$KEEP_CONFIG" = false ]; then
        rm -rf /etc/traefik
        log_success "Removed /etc/traefik/"
    else
        log_info "Keeping /etc/traefik/ (--keep-config specified)"
    fi
fi

# Remove VPS sync cron jobs
if crontab -l 2>/dev/null | grep -q "sync-vps-routes.sh"; then
    crontab -l 2>/dev/null | grep -v "sync-vps-routes.sh" | crontab -
    log_success "Removed VPS sync cron jobs"
fi

log_success "Services and VPS components cleaned up"
echo

# Step 8: Remove Tailscale (optional)
if [ "$REMOVE_TAILSCALE" = true ]; then
    log_info "[8/10] Removing Tailscale..."
    if command -v tailscale &> /dev/null; then
        tailscale down 2>/dev/null || true
        if [ -f /usr/bin/tailscale-uninstall.sh ]; then
            /usr/bin/tailscale-uninstall.sh 2>/dev/null || true
        else
            apt-get remove -y tailscale 2>/dev/null || true
        fi
        log_success "Tailscale removed"
    else
        log_info "Tailscale not installed"
    fi
else
    log_info "[8/10] Keeping Tailscale (skipped)"
fi
echo

# Step 9: Remove configuration files (both root and user)
if [ "$KEEP_CONFIG" = false ]; then
    log_info "[9/10] Removing configuration files..."
    
    # Remove root configs
    if [ -d "/root/.mynodeone" ]; then
        rm -rf /root/.mynodeone
        log_success "Removed /root/.mynodeone/"
    fi
    
    if [ -d "/root/.kube" ]; then
        rm -rf /root/.kube
        log_success "Removed /root/.kube/"
    fi
    
    # Remove user configs if running as sudo
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local user_home=$(eval echo ~$SUDO_USER)
        
        if [ -d "$user_home/.mynodeone" ]; then
            rm -rf "$user_home/.mynodeone"
            log_success "Removed $user_home/.mynodeone/ (user: $SUDO_USER)"
        fi
        
        if [ -d "$user_home/.kube" ]; then
            if [ "$INTERACTIVE" = true ]; then
                read -p "Remove kubectl config for user $SUDO_USER? [y/N]: " -r
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    rm -rf "$user_home/.kube"
                    log_success "Removed $user_home/.kube/"
                fi
            fi
        fi
    fi
    
    # Also clean current user if different from root and SUDO_USER
    if [ "$HOME" != "/root" ] && [ "$USER" != "${SUDO_USER:-}" ]; then
        if [ -d "$HOME/.mynodeone" ]; then
            rm -rf "$HOME/.mynodeone"
            log_success "Removed $HOME/.mynodeone/"
        fi
    fi
    
    log_success "Configuration files removed"
else
    log_info "[9/10] Keeping configuration files (skipped)"
fi
echo

# Step 10: Final verification and cleanup
log_info "[10/10] Final cleanup and verification..."

# Verify critical directories are removed
local cleanup_verified=true

if [ "$KEEP_CONFIG" = false ]; then
    [ -d "/root/.mynodeone" ] && cleanup_verified=false && log_warn "⚠ /root/.mynodeone still exists"
    [ -n "${SUDO_USER:-}" ] && [ -d "$(eval echo ~$SUDO_USER)/.mynodeone" ] && cleanup_verified=false && log_warn "⚠ User .mynodeone still exists"
fi

if [ "$REMOVE_K8S" = true ]; then
    [ -f /usr/local/bin/k3s ] && cleanup_verified=false && log_warn "⚠ K3s binary still exists"
fi

if [ "$cleanup_verified" = true ]; then
    log_success "All cleanup verified"
else
    log_warn "Some items may require manual removal"
fi
echo

# Final cleanup
print_header "Cleanup Complete"

if [ "$REMOVE_K8S" = true ]; then
    log_success "Kubernetes cluster removed"
fi

if [ "$KEEP_DATA" = true ]; then
    log_warn "Application data preserved on storage disks"
    echo "  Location: /mnt/longhorn-disks/"
    echo "  Note: Disks are unmounted but data is intact"
fi

if [ "$KEEP_CONFIG" = true ]; then
    log_warn "Configuration files preserved"
    echo "  Location: $HOME/.mynodeone/"
    echo "  Note: You can reinstall using the same configuration"
fi

echo
print_header "Uninstall Summary"

echo "✓ MyNodeOne has been uninstalled from this ${NODE_TYPE} node"
echo

if [ "$KEEP_CONFIG" = true ] || [ "$KEEP_DATA" = true ]; then
    echo "📁 Preserved items:"
    [ "$KEEP_CONFIG" = true ] && echo "   • Configuration: $HOME/.mynodeone/"
    [ "$KEEP_DATA" = true ] && echo "   • Data: /mnt/longhorn-disks/ (unmounted)"
    echo
fi

echo "🔄 To reinstall MyNodeOne:"
if [ "$KEEP_CONFIG" = true ]; then
    echo "   sudo ./scripts/mynodeone"
    echo "   (Will use existing configuration)"
else
    echo "   sudo ./scripts/mynodeone"
    echo "   (Will ask for configuration)"
fi
echo

echo "🧹 Additional manual cleanup (if needed):"
echo "   • Remove formatted disks data: sudo rm -rf /mnt/longhorn-disks/"
echo "   • Remove Tailscale: sudo apt remove tailscale"
[ -d "/root/.mynodeone" ] && echo "   • Remove root config: sudo rm -rf /root/.mynodeone"
[ -d "$HOME/.mynodeone" ] && echo "   • Remove user config: rm -rf $HOME/.mynodeone"
[ -d "/etc/traefik" ] && echo "   • Remove Traefik config: sudo rm -rf /etc/traefik"
echo "   • Verify services stopped: sudo systemctl list-units | grep mynodeone"
echo

log_success "Uninstall complete!"
echo
