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
#   --full            Remove everything (configs + data) [Default]
#   --help            Show this help message
###############################################################################

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Default options (Full uninstall by default)
KEEP_CONFIG=false
KEEP_DATA=false
INTERACTIVE=true
REMOVE_TAILSCALE=false

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

Usage: sudo ./scripts/installation/uninstall-mynodeone.sh [OPTIONS]

OPTIONS:
    --keep-config       Keep configuration files (~/.mynodeone/)
    --keep-data         Keep application data (Longhorn volumes, PVCs)
    --full              Remove everything (Default behavior)
    --remove-tailscale  Also remove Tailscale (disconnect from network)
    --yes               Non-interactive mode (auto-confirm)
    --help              Show this help message

EXAMPLES:
    # Full uninstall (Default)
    sudo ./scripts/installation/uninstall-mynodeone.sh

    # Keep config for reinstall
    sudo ./scripts/installation/uninstall-mynodeone.sh --keep-config

    # Keep data but remove cluster
    sudo ./scripts/installation/uninstall-mynodeone.sh --keep-data

    # Complete removal
    sudo ./scripts/installation/uninstall-mynodeone.sh --full

    # Fresh install (remove everything including Tailscale)
    sudo ./scripts/installation/uninstall-mynodeone.sh --full --remove-tailscale --yes

WHAT GETS REMOVED:
    • Kubernetes ConfigMaps (service/domain/sync registries)
    • Kubernetes cluster (K3s)
    • All running pods and services
    • Docker/containerd images
    • Longhorn storage system
    • Systemd services and timers (config API, node agent, sync controller, DNS
      sync, CoreDNS guardian, Flannel health monitor, state backup)
    • Passwordless sudo rules MyNodeOne added (/etc/sudoers.d)
    • VPS Traefik setup (/etc/traefik/)
    • DNS configurations (/etc/hosts, dnsmasq, Avahi)
    • Cron jobs (VPS sync)
    • Tailscale configuration (optional)
    • Config files from all users (root + sudo user)
    • Git repository (~/MyNodeOne/)
    • SSH known_hosts (Tailscale IPs)
    • Registry cache files
    • Docker volumes (Traefik)

WHAT CAN BE KEPT:
    • Configuration files (~/.mynodeone/config.env)
    • Application data (Longhorn volumes)
    • Formatted disks (always kept)
    • State backups in /var/backups/mynodeone (always kept: they may be the last
      copy, and they hold the encryption key, so delete them yourself when done)
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
        --remove-tailscale)
            REMOVE_TAILSCALE=true
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
        elif [ -f "/etc/mynodeone/node-type" ]; then
            node_type=$(cat /etc/mynodeone/node-type 2>/dev/null || echo "unknown")
        elif systemctl is-active --quiet traefik 2>/dev/null && [ ! -d "/var/lib/rancher/k3s" ]; then
            # VPS nodes typically have Traefik but not k3s
            node_type="vps"
        fi
    fi
    
    echo "$node_type"
}

NODE_TYPE=$(detect_node_type)

print_header "MyNodeOne Uninstall"

echo -e "${CYAN}Detected Node Type:${NC} ${MAGENTA}${NODE_TYPE}${NC}"
echo

# Detect actual user and home directory
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

# Load config if it exists
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
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
    echo -e "${YELLOW}⚠️  Full Uninstall Selected (Default)\nThis will remove all configurations and application data.${NC}"
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
    # REMOVE_TAILSCALE is already set by --remove-tailscale flag or defaults to false
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
echo "  • State backups (/var/backups/mynodeone)"
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
    log_info "[1/12] Stopping Kubernetes..."
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
    log_info "[1/12] Keeping Kubernetes cluster (skipped)"
fi
echo

# Removes this node from one list in sync-controller-registry. The update is
# conditional on what was read, and a failed read changes nothing.
unregister_from_sync_registry() {
    local list="$1" ip="$2" rc=0
    sr_read_cm sync-controller-registry registry.json || rc=$?
    case "$rc" in
        0) ;;
        2 | 3) return 0 ;;
        *)
            log_warn "Could not read sync-controller-registry; $ip may still be listed there"
            return 1
            ;;
    esac
    if ! jq -e --arg list "$list" --arg ip "$ip" 'any(.[$list][]?; .ip == $ip)' <<<"$SR_READ_JSON" >/dev/null; then
        return 0
    fi
    if sr_update_cm sync-controller-registry registry.json sync_registry_drop_filter "$list" "$ip"; then
        log_success "Unregistered $ip from sync-controller-registry"
    else
        log_warn "Could not update sync-controller-registry; $ip is still listed there"
        return 1
    fi
}

sync_registry_drop_filter() {
    jq -c --arg list "$1" --arg ip "$2" '.[$list] |= map(select(.ip != $ip))'
}

# Step 2: Clean Kubernetes ConfigMaps (CRITICAL - before removing K3s)
# Only delete ConfigMaps when uninstalling control-plane, not management laptops!
if [ "$REMOVE_K8S" = true ] && [ "$KEEP_CONFIG" = false ] && [ "$NODE_TYPE" = "control-plane" ]; then
    log_info "[2/12] Cleaning Kubernetes ConfigMaps..."
    if command -v kubectl &> /dev/null; then
        # Remove MyNodeOne ConfigMaps (contains registry data)
        kubectl delete configmap service-registry -n kube-system --ignore-not-found=true 2>/dev/null && \
            log_success "Removed service-registry ConfigMap" || true
        kubectl delete configmap domain-registry -n kube-system --ignore-not-found=true 2>/dev/null && \
            log_success "Removed domain-registry ConfigMap" || true
        kubectl delete configmap sync-controller-registry -n kube-system --ignore-not-found=true 2>/dev/null && \
            log_success "Removed sync-controller-registry ConfigMap" || true
        kubectl delete configmap cluster-info -n kube-system --ignore-not-found=true 2>/dev/null && \
            log_success "Removed cluster-info ConfigMap" || true

        if kubectl get storageclass &>/dev/null; then
            for sc in $(kubectl get storageclass -o name 2>/dev/null | grep -E '^storageclass\.storage\.k8s\.io/longhorn($|-)'); do
                kubectl delete "$sc" --ignore-not-found=true 2>/dev/null || true
            done
            log_success "Removed Longhorn StorageClass(es)"
        fi

        for ns in $(kubectl get namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^minio-'); do
            kubectl delete namespace "$ns" --ignore-not-found=true --wait=true 2>/dev/null || true
        done

        for pv in $(kubectl get pv -o name 2>/dev/null | grep -E '^persistentvolume/minio-data-'); do
            kubectl delete "$pv" --ignore-not-found=true 2>/dev/null || true
        done
        
        log_success "ConfigMaps cleaned"
    else
        log_info "kubectl not available, skipping ConfigMap cleanup"
    fi
elif [ "$NODE_TYPE" = "management" ] || [ "$NODE_TYPE" = "vps" ] || [ "$NODE_TYPE" = "worker" ]; then
    log_info "[2/12] Skipping ConfigMap cleanup ($NODE_TYPE - ConfigMaps live on control plane)"
    
    # Unregister this node from the node registry on control plane
    if command -v kubectl &> /dev/null && kubectl cluster-info &>/dev/null; then
        node_ip=$(tailscale ip -4 2>/dev/null || echo "")
        node_name="${NODE_NAME:-$(hostname)}"
        
        if [ -n "$node_ip" ]; then
            log_info "Unregistering $NODE_TYPE from cluster node registry..."
            
            if [ "$NODE_TYPE" = "vps" ]; then
                # purge-vps also takes the node off every route and the sync targets.
                log_info "Removing VPS from the registries..."
                if bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" purge-vps "$node_ip" &>/dev/null; then
                    log_success "Removed VPS ($node_ip) from the registries"
                else
                    log_warn "Could not remove VPS ($node_ip) from the registries. On the control plane run: scripts/domains/multi-domain-registry.sh purge-vps $node_ip"
                fi
            else
                registry_list="management_laptops"
                [ "$NODE_TYPE" = "worker" ] && registry_list="worker_nodes"
                if [ -f "$PROJECT_ROOT/scripts/lib/service-registry-lib.sh" ]; then
                    # shellcheck source=../lib/service-registry-lib.sh
                    source "$PROJECT_ROOT/scripts/lib/service-registry-lib.sh"
                    unregister_from_sync_registry "$registry_list" "$node_ip" || true
                else
                    log_warn "Registry library not found; $node_ip may still be listed in sync-controller-registry"
                fi
            fi

            # Also remove from Config API V2 node registry (if it exists)
            if command -v curl &> /dev/null; then
                # Try to get control plane IP from config
                control_ip=""
                if [ -f "$CONFIG_FILE" ]; then
                    source "$CONFIG_FILE" 2>/dev/null || true
                    control_ip="${CONTROL_PLANE_IP:-}"
                fi
                
                # Try to read API token
                api_token=""
                if [ -f "/etc/mynodeone/api-token" ]; then
                    api_token=$(cat /etc/mynodeone/api-token 2>/dev/null || echo "")
                fi
                
                if [ -n "$control_ip" ] && [ -n "$api_token" ] && [ -n "$node_name" ]; then
                    log_info "Removing from Config API V2 node registry..."
                    curl -X DELETE -H "X-API-Token: $api_token" \
                        "http://${control_ip}:8443/api/v1/nodes/${node_name}" \
                        2>/dev/null && log_success "Removed $node_name from Config API V2" || true
                fi
            fi
        fi
    fi
    if [ "$NODE_TYPE" = "worker" ] && [ "$REMOVE_K8S" = true ] && [ "$KEEP_CONFIG" = false ]; then
        DELETE_CLUSTER_SC=false
        if [ "$INTERACTIVE" = true ]; then
            echo
            read -p "Also delete cluster-scoped Longhorn StorageClass(es)? This affects the whole cluster. [y/N]: " -r
            [[ $REPLY =~ ^[Yy]$ ]] && DELETE_CLUSTER_SC=true
        elif [ "${FORCE_DELETE_CLUSTER_SC:-false}" = "true" ]; then
            DELETE_CLUSTER_SC=true
        fi

        if [ "$DELETE_CLUSTER_SC" = true ] && kubectl get storageclass &>/dev/null; then
            for sc in $(kubectl get storageclass -o name 2>/dev/null | grep -E '^storageclass\.storage\.k8s\.io/longhorn($|-)'); do
                kubectl delete "$sc" --ignore-not-found=true 2>/dev/null || true
            done
            log_success "Removed Longhorn StorageClass(es)"
        fi
    fi
elif [ "$KEEP_CONFIG" = true ]; then
    log_info "[2/12] Keeping ConfigMaps (--keep-config specified)"
else
    log_info "[2/12] Keeping Kubernetes cluster (skipped)"
fi
echo

# Step 3: Backup data if requested
if [ "$REMOVE_K8S" = true ] && [ "$KEEP_DATA" = true ]; then
    log_info "[3/12] Preserving application data..."
    # Data will be kept on Longhorn volumes (disks stay mounted)
    log_success "Data will be preserved on storage disks"
else
    log_info "[3/12] Application data will be removed with cluster"
fi
echo

# Step 4: Remove container images
if [ "$REMOVE_IMAGES" = true ]; then
    log_info "[4/12] Removing container images..."
    if command -v crictl &> /dev/null; then
        crictl rmi --prune 2>/dev/null || true
        log_success "Container images removed"
    else
        log_info "crictl not found, skipping"
    fi
else
    log_info "[4/12] Keeping container images (skipped)"
fi
echo

# Step 5: Uninstall K3s
if [ "$REMOVE_K8S" = true ]; then
    log_info "[5/12] Uninstalling Kubernetes..."
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        log_success "K3s uninstalled"
    elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
        /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
        log_success "K3s agent uninstalled"
    else
        log_warn "K3s uninstall script not found (may not be installed)"
    fi
    
    # Remove Rancher directories (K3s leftovers)
    if [ -d /etc/rancher ]; then
        rm -rf /etc/rancher
        log_success "Removed /etc/rancher/"
    fi
    
    if [ -d /var/lib/rancher ]; then
        rm -rf /var/lib/rancher
        log_success "Removed /var/lib/rancher/"
    fi
    
    # Remove GPU-related symlinks and configs created for K3s
    if [ -L /usr/bin/runc ] && [ "$(readlink /usr/bin/runc)" = "/var/lib/rancher/k3s/data/current/bin/runc" ]; then
        rm -f /usr/bin/runc
        log_success "Removed runc symlink (K3s GPU support)"
    fi
else
    log_info "[5/12] Keeping Kubernetes cluster (skipped)"
fi
echo

# Step 6: Unmount Longhorn disks
log_info "[6/12] Unmounting storage disks..."
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

if [ "$KEEP_DATA" = false ]; then
    if mountpoint -q /mnt/minio 2>/dev/null; then
        umount /mnt/minio 2>/dev/null || umount -l /mnt/minio 2>/dev/null || true
        log_success "Unmounted /mnt/minio"
    fi

    if grep -q "[[:space:]]/mnt/minio[[:space:]]" /etc/fstab 2>/dev/null; then
        cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
        sed -i '/\/mnt\/minio/d' /etc/fstab
        log_success "Removed MinIO fstab entries"
    fi

    if [ -d /mnt/minio ]; then
        rm -rf /mnt/minio 2>/dev/null || true
        log_success "Removed /mnt/minio"
    fi

    if [ -d /var/lib/minio ]; then
        rm -rf /var/lib/minio 2>/dev/null || true
        log_success "Removed /var/lib/minio"
    fi
fi
echo

# Step 7: Disable IP forwarding (if it was enabled)
log_info "[7/12] Disabling IP forwarding..."
if sysctl net.ipv4.ip_forward 2>/dev/null | grep -q "= 1"; then
    sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=0 > /dev/null 2>&1 || true
    log_success "IP forwarding disabled"
    
    # Remove from sysctl.conf
    if grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d_%H%M%S)
        sed -i '/net\.ipv4\.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
        sed -i '/net\.ipv6\.conf\.all\.forwarding/d' /etc/sysctl.conf 2>/dev/null || true
        log_success "Removed IP forwarding from sysctl.conf"
    fi
    
    # Remove from sysctl.d
    if ls /etc/sysctl.d/*.conf &>/dev/null 2>&1; then
        for conf_file in /etc/sysctl.d/*.conf; do
            if grep -q "net.ipv4.ip_forward\|net.ipv6.conf.all.forwarding" "$conf_file" 2>/dev/null; then
                cp "$conf_file" "$conf_file.bak.$(date +%Y%m%d_%H%M%S)"
                sed -i '/net\.ipv4\.ip_forward/d' "$conf_file" 2>/dev/null || true
                sed -i '/net\.ipv6\.conf\.all\.forwarding/d' "$conf_file" 2>/dev/null || true
            fi
        done
        log_success "Removed IP forwarding from sysctl.d"
    fi
else
    log_info "IP forwarding not enabled"
fi
echo

# Removes MyNodeOne's entries from a hosts file and keeps every other line, in the
# same bytes and order. What counts as ours:
#   * A block from a whole-line marker through its own End marker. A block never
#     reaches past the next marker, so one with no End can't borrow another's.
#   * A marker with no End (sync-dns.sh and the node agent write these), plus the
#     entries directly below it: address lines naming only .local hosts, and any
#     comments between them. It stops at a blank line or anything else.
#   * A leftover End marker, and an address line naming only hosts under
#     mynodeone.local or the cluster domain. A line that also names another host, or
#     carries a comment, isn't only ours, so it stays.
# Text after other text on a line is never a marker. awk compares strings, so the
# cluster domain is never read as a regex. Writes in place, not sed -i or a rename:
# /etc/hosts can be a bind mount, where replacing the file fails.
# Usage: remove_mynodeone_hosts_entries <file> [cluster-domain]
remove_mynodeone_hosts_entries() {
    local file="$1" domain="${2:-}" work status=0 no_final_newline=0
    work=$(mktemp -d) || return 1

    if ! cat "$file" >"$work/old"; then
        rm -rf "$work"
        return 1
    fi
    [ -z "$(tail -c 1 "$work/old" | tr -d '\000')" ] || no_final_newline=1

    # NUL bytes go, as in sync-dns.sh: a zero-filled hole is damage, not content.
    if ! tr -d '\000' <"$work/old" |
        HOSTS_DOMAIN="$domain" NO_FINAL_NEWLINE="$no_final_newline" LC_ALL=C awk '
        function comment_text(text) {
            if (text !~ /^[ \t]*#/) return ""
            text = tolower(text)
            sub(/^[ \t]*#[ \t]*/, "", text)
            sub(/[ \t\r]+$/, "", text)
            return text
        }
        # These two give the block a marker belongs to, "-" for a bare one, or "".
        function opens(text,    s) {
            s = comment_text(text)
            if (s == "mynodeone") return "-"
            if (s !~ /^mynodeone (services|apps|dns entries)( [-(].*)?$/) return ""
            sub(/^mynodeone /, "", s)
            sub(/ [-(].*$/, "", s)
            return s
        }
        function closes(text,    s) {
            s = comment_text(text)
            if (s == "end mynodeone") return "-"
            if (s !~ /^end mynodeone (services|apps|dns entries)$/) return ""
            sub(/^end mynodeone /, "", s)
            return s
        }
        function ends_with(s, suffix) {
            return length(s) > length(suffix) && substr(s, length(s) - length(suffix) + 1) == suffix
        }
        function ours(name) {
            return name == "mynodeone.local" || ends_with(name, ".mynodeone.local") ||
                (domain != "" && (name == (domain ".local") || ends_with(name, ("." domain ".local"))))
        }
        # An address, then only names of the kind asked for.
        function host_line(text, only_ours,    f, n, k) {
            n = split(text, f)
            if (n < 2) return 0
            if (f[1] !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !(index(f[1], ":") > 0 && f[1] ~ /^[0-9A-Fa-f:.]+$/)) return 0
            for (k = 2; k <= n; k++) {
                if (only_ours ? !ours(f[k]) : !ends_with(f[k], ".local")) return 0
            }
            return 1
        }
        function matching_end(start, name,    j, c) {
            for (j = start + 1; j <= NR; j++) {
                c = closes(line[j])
                if (c != "" && (c == name || c == "-" || name == "-")) return j
                if (opens(line[j]) != "") return 0
            }
            return 0
        }
        # Comments only count when another entry follows them, so a note someone left
        # just below the block stays.
        function last_entry(start,    j, last) {
            last = start
            for (j = start + 1; j <= NR; j++) {
                if (opens(line[j]) != "" || closes(line[j]) != "") break
                if (host_line(line[j], 0)) last = j
                else if (line[j] !~ /^[ \t]*#/) break
            }
            return last
        }
        BEGIN { domain = ENVIRON["HOSTS_DOMAIN"]; no_final = ENVIRON["NO_FINAL_NEWLINE"] == "1" }
        { line[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (closes(line[i]) != "") continue
                name = opens(line[i])
                if (name != "") {
                    end = matching_end(i, name)
                    i = end ? end : last_entry(i)
                    continue
                }
                if (host_line(line[i], 1)) continue
                if (kept) printf "\n"
                printf "%s", line[i]
                kept = i
            }
            if (kept && !(no_final && kept == NR)) printf "\n"
        }
    ' >"$work/new"; then
        status=1
    elif ! cmp -s "$work/old" "$work/new"; then
        if ! { cat "$work/new" >"$file" && cmp -s "$work/new" "$file"; } 2>/dev/null; then
            cat "$work/old" >"$file" 2>/dev/null || true
            status=1
        fi
    fi

    rm -rf "$work"
    return "$status"
}

# Step 8: Remove DNS configurations
log_info "[8/12] Removing DNS configurations..."

# Remove from /etc/hosts
if [ -f /etc/hosts ]; then
    if ! cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"; then
        log_warn "Could not back up /etc/hosts; leaving it unchanged"
    elif remove_mynodeone_hosts_entries /etc/hosts "${CLUSTER_DOMAIN:-}"; then
        log_success "Removed MyNodeOne's /etc/hosts entries"
    else
        log_warn "Could not update /etc/hosts; see the newest /etc/hosts.bak.* file"
    fi
fi

# Remove ALL domain-specific dnsmasq configs (not just mynodeone*)
# Users can name their clusters anything (base, space, universal, etc.)
if [ -d /etc/dnsmasq.d ]; then
    rm -f /etc/dnsmasq.d/*.conf 2>/dev/null || true
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl restart dnsmasq 2>/dev/null || true
    fi
fi

# Stop and disable dnsmasq if it's in failed state
if systemctl is-failed --quiet dnsmasq 2>/dev/null; then
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    systemctl reset-failed dnsmasq 2>/dev/null || true
    log_success "Stopped and disabled dnsmasq"
fi

# Remove systemd-resolved configuration
if [ -d /etc/systemd/resolved.conf.d ]; then
    rm -f /etc/systemd/resolved.conf.d/*.conf 2>/dev/null || true
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved 2>/dev/null || true
        log_success "Removed systemd-resolved configuration"
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

# Step 9: Remove systemd services and VPS components
log_info "[9/13] Removing systemd services and VPS components..."

# Remove Config API V2 service (control plane)
if [ -f /etc/systemd/system/mynodeone-config-api.service ]; then
    systemctl stop mynodeone-config-api 2>/dev/null || true
    systemctl disable mynodeone-config-api 2>/dev/null || true
    rm -f /etc/systemd/system/mynodeone-config-api.service
    systemctl daemon-reload
    log_success "Removed Config API service"
fi

# Remove Node Agent service (all nodes)
if [ -f /etc/systemd/system/mynodeone-node-agent.service ]; then
    systemctl stop mynodeone-node-agent 2>/dev/null || true
    systemctl disable mynodeone-node-agent 2>/dev/null || true
    rm -f /etc/systemd/system/mynodeone-node-agent.service
    systemctl daemon-reload
    log_success "Removed Node Agent service"
fi

# Remove etc files
if [ -d /etc/mynodeone ]; then
    # Remove files if they exist
    rm -f /etc/mynodeone/nodes-registry.json 2>/dev/null || true
    rm -f /etc/mynodeone/api-token 2>/dev/null || true
    rm -f /etc/mynodeone/agent.env 2>/dev/null || true
    rm -f /etc/mynodeone/.agent.state 2>/dev/null || true
    
    # Remove directory if empty
    if [ -z "$(ls -A /etc/mynodeone 2>/dev/null)" ]; then
        rmdir /etc/mynodeone 2>/dev/null || true
        log_success "Removed /etc/mynodeone/ directory"
    fi
fi

# Remove sync controller service (control plane - legacy V1)
if [ -f /etc/systemd/system/mynodeone-sync-controller.service ]; then
    systemctl stop mynodeone-sync-controller 2>/dev/null || true
    systemctl disable mynodeone-sync-controller 2>/dev/null || true
    rm -f /etc/systemd/system/mynodeone-sync-controller.service
    systemctl daemon-reload
    log_success "Removed sync controller service (legacy V1)"
fi

# Remove local DNS sync timer (control plane)
if [ -f /etc/systemd/system/mynodeone-dns-sync.timer ]; then
    systemctl stop mynodeone-dns-sync.timer 2>/dev/null || true
    systemctl disable mynodeone-dns-sync.timer 2>/dev/null || true
    rm -f /etc/systemd/system/mynodeone-dns-sync.timer
    rm -f /etc/systemd/system/mynodeone-dns-sync.service
    systemctl daemon-reload
    log_success "Removed DNS sync timer"
fi

# Remove external system services enabled during installation
# These services are enabled by bootstrap-control-plane.sh but not MyNodeOne-specific
if systemctl is-enabled --quiet iscsid 2>/dev/null; then
    systemctl stop iscsid 2>/dev/null || true
    systemctl disable iscsid 2>/dev/null || true
    log_success "Stopped and disabled iscsid"
fi

if systemctl is-enabled --quiet fail2ban 2>/dev/null; then
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    log_success "Stopped and disabled fail2ban"
fi

# Remove timers that run as root, the root-owned copies of the scripts they run, and
# the node agent's sandbox drop-in, which would otherwise outlive its unit.
# Usage: remove_mynodeone_host_units [root]   (root is a directory prefix, for tests)
remove_mynodeone_host_units() {
    local root="${1:-}"
    local systemd_dir="$root/etc/systemd/system" name tool

    for name in flannel-health-monitor mynodeone-state-backup mynodeone-local-dns-sync \
        coredns-dns-guardian maintain-dns-config; do
        if [ -f "$systemd_dir/$name.timer" ] || [ -f "$systemd_dir/$name.service" ]; then
            systemctl stop "$name.timer" 2>/dev/null || true
            systemctl disable "$name.timer" 2>/dev/null || true
            systemctl stop "$name.service" 2>/dev/null || true
            rm -f "$systemd_dir/$name.timer" "$systemd_dir/$name.service"
            log_success "Removed $name"
        fi
    done

    for tool in mynodeone-flannel-health mynodeone-state-backup; do
        if [ -f "$root/usr/local/sbin/$tool" ]; then
            rm -f "$root/usr/local/sbin/$tool"
            log_success "Removed /usr/local/sbin/$tool"
        fi
    done

    for tool in mynodeone-node-agent mynodeone-config-api coredns-dns-guardian.sh maintain-dns-config.sh; do
        if [ -f "$root/usr/local/bin/$tool" ]; then
            rm -f "$root/usr/local/bin/$tool"
            log_success "Removed /usr/local/bin/$tool"
        fi
    done

    if [ -d "$systemd_dir/mynodeone-node-agent.service.d" ]; then
        rm -rf "$systemd_dir/mynodeone-node-agent.service.d"
        log_success "Removed Node Agent drop-in"
    fi

    systemctl daemon-reload 2>/dev/null || true

    if [ -d "$root/var/backups/mynodeone" ]; then
        log_warn "Kept state backups in /var/backups/mynodeone. They hold the encryption key and"
        log_warn "the k3s tokens: delete them once you no longer need them."
    fi
}
remove_mynodeone_host_units

# Remove the sudo rules MyNodeOne added, and only those: a file in sudoers.d that has
# since been edited, or that merely has a similar name, is the administrator's.
# Usage: remove_mynodeone_sudoers <user> [sudoers_dir]
remove_mynodeone_sudoers() {
    local user="$1" sudoers_dir="${2:-/etc/sudoers.d}"
    local names=("${user}-nopasswd")
    if [ "${user//./_}" != "$user" ]; then
        names+=("${user//./_}-nopasswd")
    fi

    local name file rule
    for name in "${names[@]}"; do
        file="$sudoers_dir/$name"
        [ -f "$file" ] || continue
        rule=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$file" || true)
        if [ "$rule" = "$user ALL=(ALL) NOPASSWD: ALL" ]; then
            rm -f "$file"
            log_success "Removed passwordless sudo rule: $file"
        else
            log_warn "Left $file in place: it is not the rule MyNodeOne wrote"
        fi
    done

    file="$sudoers_dir/mynodeone"
    if [ -f "$file" ]; then
        if grep -qi 'mynodeone' "$file"; then
            rm -f "$file"
            log_success "Removed MyNodeOne sudo rules: $file"
        else
            log_warn "Left $file in place: it does not look like MyNodeOne's"
        fi
    fi
}
remove_mynodeone_sudoers "$ACTUAL_USER"

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

# Step 10: Remove Tailscale (optional)
if [ "$REMOVE_TAILSCALE" = true ]; then
    log_info "[10/13] Removing Tailscale..."
    if command -v tailscale &> /dev/null || dpkg -l | grep -q tailscale; then
        # Stop Tailscale service
        tailscale down 2>/dev/null || true
        
        # Try official uninstall script first
        if [ -f /usr/bin/tailscale-uninstall.sh ]; then
            /usr/bin/tailscale-uninstall.sh 2>/dev/null || true
        fi
        
        # Purge packages (removes config files too)
        apt-get purge -y tailscale tailscale-archive-keyring 2>/dev/null || true
        dpkg --purge tailscale tailscale-archive-keyring 2>/dev/null || true
        
        # Remove directories
        rm -rf /var/lib/tailscale /etc/tailscale 2>/dev/null || true
        
        log_success "Tailscale completely removed"
    else
        log_info "Tailscale not installed"
    fi
else
    log_info "[10/13] Keeping Tailscale (skipped)"
fi
echo

# Step 11: Remove configuration files (both root and user)
if [ "$KEEP_CONFIG" = false ]; then
    log_info "[11/13] Removing configuration files..."
    
    # Remove root configs
    if [ -d "/root/.mynodeone" ]; then
        rm -rf /root/.mynodeone
        log_success "Removed /root/.mynodeone/"
    fi
    
    if [ -d "/root/.kube" ]; then
        rm -rf /root/.kube
        log_success "Removed /root/.kube/"
    fi
    
    # Remove SSH keys (MyNodeOne specific)
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
        if ls "$user_home/.ssh/mynodeone"* &>/dev/null; then
            rm -f "$user_home/.ssh/mynodeone"*
            log_success "Removed MyNodeOne SSH keys from $user_home/.ssh/"
        fi
    fi
    
    # Remove root SSH keys (used for sync)
    if ls /root/.ssh/id_ed25519* &>/dev/null 2>&1 || ls /root/.ssh/id_rsa* &>/dev/null 2>&1; then
        rm -f /root/.ssh/id_ed25519* /root/.ssh/id_rsa* 2>/dev/null || true
        log_success "Removed root SSH keys"
    fi
    
    # Remove credential files and join tokens
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
        if ls "$user_home/mynodeone-"*".txt" &>/dev/null; then
            rm -f "$user_home/mynodeone-"*".txt"
            log_success "Removed credential files and join tokens"
        fi
        
        # Explicitly remove MinIO credentials if they exist
        if [ -f "$user_home/mynodeone-minio-credentials.txt" ]; then
            rm -f "$user_home/mynodeone-minio-credentials.txt"
            log_success "Removed MinIO credentials from $user_home"
        fi
    fi
    
    # Also check root's home directory
    if ls /root/mynodeone-*.txt &>/dev/null 2>&1; then
        rm -f /root/mynodeone-*.txt
        log_success "Removed root credential files and join tokens"
    fi
    
    if [ -f "/root/mynodeone-minio-credentials.txt" ]; then
        rm -f "/root/mynodeone-minio-credentials.txt"
        log_success "Removed root MinIO credentials"
    fi
    
    # Remove user configs if running as sudo
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
        
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
    log_info "[11/13] Keeping configuration files (skipped)"
fi
echo

# Step 12: Remove Git repository and additional files
if [ "$KEEP_CONFIG" = false ]; then
    log_info "[12/13] Removing Git repository and cache files..."
    
    # Remove MyNodeOne git repository
    for dir in "$HOME/MyNodeOne" "/root/MyNodeOne"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log_success "Removed $dir"
        fi
    done
    
    # Remove user's MyNodeOne directory if running as sudo
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        user_home=$(eval echo ~$SUDO_USER)
        if [ -d "$user_home/MyNodeOne" ]; then
            rm -rf "$user_home/MyNodeOne"
            log_success "Removed $user_home/MyNodeOne"
        fi
    fi
    
    # Remove registry cache files
    for cache_file in ~/.mynodeone/node-registry.json* /root/.mynodeone/node-registry.json*; do
        if [ -f "$cache_file" ]; then
            rm -f "$cache_file"
        fi
    done
    
    # Remove Config API V2 data (if not already removed)
    if [ -f /etc/mynodeone/nodes-registry.json ]; then
        rm -f /etc/mynodeone/nodes-registry.json
        log_success "Removed node registry data"
    fi
    
    if [ -f /etc/mynodeone/api-token ]; then
        rm -f /etc/mynodeone/api-token
        log_success "Removed API token"
    fi
    
    # Remove backup files
    rm -f ~/.mynodeone/*.backup.* /root/.mynodeone/*.backup.* 2>/dev/null || true
    
    # Clean SSH known_hosts (Tailscale IPs)
    if [ -f ~/.ssh/known_hosts ]; then
        sed -i '/^100\./d' ~/.ssh/known_hosts 2>/dev/null || true
        log_success "Cleaned SSH known_hosts (Tailscale IPs)"
    fi
    
    if [ -f /root/.ssh/known_hosts ]; then
        sed -i '/^100\./d' /root/.ssh/known_hosts 2>/dev/null || true
    fi
    
    # Remove Docker volumes (Traefik)
    if command -v docker &> /dev/null; then
        docker volume ls -q 2>/dev/null | grep traefik | xargs -r docker volume rm 2>/dev/null || true
        # Remove any MyNodeOne-related Docker networks
        docker network ls -q 2>/dev/null | grep mynodeone | xargs -r docker network rm 2>/dev/null || true
        # Clean up unused Docker resources
        docker system prune -f 2>/dev/null || true
        log_success "Removed Docker volumes and networks"
    fi
    
    log_success "Additional cleanup completed"
else
    log_info "[12/13] Keeping additional files (--keep-config specified)"
fi
echo

# Step 13: Final verification and cleanup
log_info "[13/13] Final cleanup and verification..."

# Verify critical directories are removed
cleanup_verified=true

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
    echo "   sudo ./scripts/installation/install-mynodeone.sh"
    echo "   (Will use existing configuration)"
else
    echo "   sudo ./scripts/installation/install-mynodeone.sh"
    echo "   (Will ask for configuration)"
fi
echo

echo "🧹 Additional manual cleanup (if needed):"
echo "   • Remove formatted disks data: sudo rm -rf /mnt/longhorn-disks/"
echo "   • Remove Tailscale: sudo apt remove tailscale"
[ -d "/root/.mynodeone" ] && echo "   • Remove root config: sudo rm -rf /root/.mynodeone"
[ -d "$HOME/.mynodeone" ] && echo "   • Remove user config: rm -rf $HOME/.mynodeone"
[ -d "$HOME/MyNodeOne" ] && echo "   • Remove Git repository: rm -rf $HOME/MyNodeOne"
[ -d "/etc/traefik" ] && echo "   • Remove Traefik config: sudo rm -rf /etc/traefik"
echo "   • Verify ConfigMaps removed: kubectl get cm -n kube-system 2>/dev/null"
echo "   • Verify services stopped: sudo systemctl list-units | grep mynodeone"
echo

log_success "Uninstall complete"
echo
