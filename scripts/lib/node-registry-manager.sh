#!/bin/bash

###############################################################################
# Node Registry Manager - Central Node Registry
#
# Features:
# - ConfigMap as single source of truth
# - Automatic user detection (never assumes root)
# - Validation after every operation
# - Automatic sync between ConfigMap and local cache
# - No assumptions about paths or users
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Detect actual user's home directory
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Running normally
    ACTUAL_HOME="$HOME"
fi

# Detect config directory (never assume location)
detect_config_dir() {
    # Try to find existing config, prioritizing actual user's home
    local possible_dirs=(
        "$ACTUAL_HOME/.mynodeone"
        "$HOME/.mynodeone"
        "/home/$(whoami)/.mynodeone"
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [[ -f "$dir/config.env" ]]; then
            echo "$dir"
            return 0
        fi
    done
    
    # Default to actual user's home
    echo "$ACTUAL_HOME/.mynodeone"
}

CONFIG_DIR=$(detect_config_dir)
REGISTRY_CONFIGMAP="sync-controller-registry"
REGISTRY_NAMESPACE="kube-system"
LOCAL_CACHE="$CONFIG_DIR/node-registry.json"

# Initialize ConfigMap registry (single source of truth)
init_registry() {
    log_info "Initializing central node registry..."
    
    # Check if ConfigMap exists
    if kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" &>/dev/null; then
        log_success "Registry ConfigMap already exists"
        return 0
    fi
    
    # Create empty registry ConfigMap with documented structure
    # 
    # Registry Design:
    # - management_laptops: External dev/admin machines (SSH sync for DNS/config)
    # - vps_nodes: External VPS for public routing (SSH sync for Traefik routes)
    # - worker_nodes: External workers (non-Kubernetes, reserved for future use)
    # - cluster_nodes: Kubernetes cluster members (control-plane + workers)
    #
    # Note: Kubernetes workers are stored in cluster_nodes, NOT worker_nodes.
    # The worker_nodes array is reserved for external workers that are NOT part
    # of the Kubernetes cluster (e.g., Docker Swarm, Nomad, or standalone workers).
    local empty_registry='{
  "management_laptops": [],
  "vps_nodes": [],
  "worker_nodes": [],
  "cluster_nodes": [],
  "metadata": {
    "version": "2.0",
    "last_updated": "'$(date -Iseconds)'",
    "updated_by": "'$(whoami)@$(hostname)'"
  }
}'
    
    kubectl create configmap "$REGISTRY_CONFIGMAP" \
        -n "$REGISTRY_NAMESPACE" \
        --from-literal=registry.json="$empty_registry" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # VALIDATION: Verify ConfigMap was created
    if ! kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" &>/dev/null; then
        log_error "Failed to create registry ConfigMap"
        return 1
    fi
    
    # VALIDATION: Verify data is readable
    local test_read=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    if [[ -z "$test_read" ]]; then
        log_error "ConfigMap created but data is not readable"
        return 1
    fi
    
    log_success "Registry ConfigMap initialized and validated"
    return 0
}

# Sync registry from ConfigMap to local cache
sync_from_configmap() {
    log_info "Syncing registry from ConfigMap..."
    
    # VALIDATION: Check kubectl access
    if ! kubectl version --client &>/dev/null; then
        log_error "kubectl not available or not configured"
        return 1
    fi
    
    # Fetch from ConfigMap
    local registry_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    # VALIDATION: Verify data retrieved
    if [[ -z "$registry_data" ]]; then
        log_warn "ConfigMap is empty or doesn't exist, initializing..."
        init_registry || return 1
        registry_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
            -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    fi
    
    # VALIDATION: Verify JSON is valid
    if ! echo "$registry_data" | jq empty 2>/dev/null; then
        log_error "Registry data is not valid JSON"
        return 1
    fi
    
    # Save to local cache
    # Detect actual user (handle sudo context)
    local actual_user="${SUDO_USER:-$(whoami)}"
    local actual_home
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        actual_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        actual_home="$HOME"
    fi
    
    # Create config directory with correct ownership
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        if [ "$actual_user" != "root" ] && [ "$(whoami)" = "root" ]; then
            chown "$actual_user:$actual_user" "$CONFIG_DIR"
        fi
    fi
    
    # Write registry data
    echo "$registry_data" | jq '.' > "$LOCAL_CACHE"
    
    # Fix ownership if running as root
    if [ "$actual_user" != "root" ] && [ "$(whoami)" = "root" ]; then
        chown "$actual_user:$actual_user" "$LOCAL_CACHE"
    fi
    
    # VALIDATION: Verify local cache is readable
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Failed to write valid JSON to local cache"
        rm -f "$LOCAL_CACHE"
        return 1
    fi
    
    log_success "Registry synced from ConfigMap to local cache"
    return 0
}

# Sync registry from local cache to ConfigMap
sync_to_configmap() {
    log_info "Syncing registry to ConfigMap..."
    
    # VALIDATION: Check local cache exists and is valid
    if [[ ! -f "$LOCAL_CACHE" ]]; then
        log_error "Local cache does not exist: $LOCAL_CACHE"
        return 1
    fi
    
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Local cache contains invalid JSON"
        return 1
    fi
    
    # Update metadata
    local updated_registry=$(jq \
        --arg timestamp "$(date -Iseconds)" \
        --arg updater "$(whoami)@$(hostname)" \
        '.metadata.last_updated = $timestamp | .metadata.updated_by = $updater' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update metadata in registry"
        return 1
    fi
    
    # Backup current ConfigMap before updating
    kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' > "$LOCAL_CACHE.backup.$(date +%s)" 2>/dev/null || true
    
    # Update ConfigMap using patch
    kubectl patch configmap "$REGISTRY_CONFIGMAP" \
        -n "$REGISTRY_NAMESPACE" \
        --type merge \
        -p "{\"data\":{\"registry.json\":$(echo "$updated_registry" | jq -Rs .)}}"
    
    # VALIDATION: Verify update succeeded
    local verify_data=$(kubectl get configmap "$REGISTRY_CONFIGMAP" -n "$REGISTRY_NAMESPACE" \
        -o jsonpath='{.data.registry\.json}' 2>/dev/null || echo "")
    
    if [[ -z "$verify_data" ]]; then
        log_error "ConfigMap update failed - data is empty"
        return 1
    fi
    
    if ! echo "$verify_data" | jq empty 2>/dev/null; then
        log_error "ConfigMap update failed - data is invalid JSON"
        return 1
    fi
    
    # VALIDATION: Verify expected changes are present
    local node_count=$(echo "$verify_data" | jq '[.management_laptops, .vps_nodes, .worker_nodes] | flatten | length')
    log_info "Registry updated in ConfigMap (total nodes: $node_count)"
    
    log_success "Registry synced to ConfigMap and validated"
    return 0
}

# Auto-detect SSH user for a given IP
detect_ssh_user() {
    local target_ip="$1"
    local test_users=("$(whoami)" "root" "$USER" "${SUDO_USER:-}")
    
    log_info "Auto-detecting SSH user for $target_ip..."
    
    # Remove duplicates
    test_users=($(echo "${test_users[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    for user in "${test_users[@]}"; do
        [[ -z "$user" ]] && continue
        
        log_info "  Testing SSH as $user..."
        if timeout 5 ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes \
            "$user@$target_ip" "echo OK" &>/dev/null; then
            log_success "Detected SSH user: $user"
            echo "$user"
            return 0
        fi
    done
    
    log_error "Could not auto-detect SSH user for $target_ip"
    return 1
}

# Register a node in the registry
register_node() {
    local node_type="$1"  # management_laptops, vps_nodes, worker_nodes
    local ip="$2"
    local name="${3:-}"
    local ssh_user="${4:-}"
    local webhook_port="${5:-8080}"
    local repo_path="${6:-}"
    local skip_ssh_validation="${SKIP_SSH_VALIDATION:-false}"
    
    log_info "Registering node: $node_type at $ip..."
    
    # VALIDATION: Check node_type is valid
    if [[ ! "$node_type" =~ ^(management_laptops|vps_nodes|worker_nodes)$ ]]; then
        log_error "Invalid node type: $node_type"
        return 1
    fi
    
    # VALIDATION: Check IP is reachable
    if ! ping -c 1 -W 2 "$ip" &>/dev/null; then
        log_warn "IP $ip is not reachable via ping (may be firewalled)"
    fi
    
    # Auto-detect hostname if not provided
    if [[ -z "$name" ]]; then
        name=$(hostname)
        log_info "Using hostname: $name"
    fi
    
    # Auto-detect SSH user if not provided
    if [[ -z "$ssh_user" ]]; then
        # Check if registering localhost
        local my_ips=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
        local is_localhost=false
        if echo "$my_ips" | grep -q "^${ip}$" || [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "localhost" ]]; then
            is_localhost=true
            ssh_user=$(whoami)
            log_info "Detected localhost - using current user: $ssh_user"
        else
            ssh_user=$(detect_ssh_user "$ip")
            if [[ -z "$ssh_user" ]]; then
                log_error "Failed to detect SSH user and none provided"
                return 1
            fi
        fi
    fi
    
    # VALIDATION: Verify SSH access with detected user (skip for localhost or if explicitly requested)
    local my_ips=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
    local is_localhost=false
    if echo "$my_ips" | grep -q "^${ip}$" || [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "localhost" ]]; then
        is_localhost=true
        log_info "Skipping SSH validation for localhost"
    elif [[ "$skip_ssh_validation" == "true" ]]; then
        log_warn "Skipping SSH validation (SKIP_SSH_VALIDATION=true)"
        log_warn "Ensure SSH access is configured before running sync operations"
    else
        log_info "Validating SSH access as $ssh_user@$ip..."
        if ! timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "$ssh_user@$ip" "echo 'SSH validation successful'" &>/dev/null; then
            log_error "SSH validation failed for $ssh_user@$ip"
            log_error "Cannot register node without working SSH access"
            log_error "Hint: Set SKIP_SSH_VALIDATION=true to register without validation"
            return 1
        fi
        log_success "SSH access validated for $ssh_user@$ip"
    fi
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # Build node entry
    local node_entry=$(jq -n \
        --arg ip "$ip" \
        --arg name "$name" \
        --arg ssh_user "$ssh_user" \
        --argjson webhook_port "$webhook_port" \
        --arg repo_path "$repo_path" \
        --arg timestamp "$(date -Iseconds)" \
        '{
            ip: $ip,
            name: $name,
            ssh_user: $ssh_user,
            webhook_port: $webhook_port,
            repo_path: $repo_path,
            registered: $timestamp,
            last_sync: null,
            status: "active"
        }')
    
    # Remove existing entry for this IP if present
    local updated_registry=$(jq \
        --arg type "$node_type" \
        --arg ip "$ip" \
        --argjson entry "$node_entry" \
        'del(.[$type][] | select(.ip == $ip)) | .[$type] += [$entry]' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update registry with new node"
        return 1
    fi
    
    # Save updated registry to local cache
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    
    # VALIDATION: Verify node was added
    local verify_node=$(jq -r \
        --arg type "$node_type" \
        --arg ip "$ip" \
        '.[$type][] | select(.ip == $ip) | .ssh_user' \
        "$LOCAL_CACHE")
    
    if [[ "$verify_node" != "$ssh_user" ]]; then
        log_error "Node registration validation failed"
        return 1
    fi
    
    # Sync to ConfigMap
    sync_to_configmap || return 1
    
    # FINAL VALIDATION: Read back from ConfigMap to confirm
    sync_from_configmap || return 1
    local final_verify=$(jq -r \
        --arg type "$node_type" \
        --arg ip "$ip" \
        '.[$type][] | select(.ip == $ip) | .ssh_user' \
        "$LOCAL_CACHE")
    
    if [[ "$final_verify" != "$ssh_user" ]]; then
        log_error "Final validation failed - node not in ConfigMap"
        return 1
    fi
    
    log_success "Registered $node_type: $ip ($name) as $ssh_user"
    log_success "✓ Validated in ConfigMap"
    return 0
}

# Get all nodes of a specific type
get_nodes() {
    local node_type="$1"
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # VALIDATION: Check registry is valid
    if ! jq empty "$LOCAL_CACHE" 2>/dev/null; then
        log_error "Registry cache is invalid"
        return 1
    fi
    
    # Get nodes
    jq -r --arg type "$node_type" '.[$type][]' "$LOCAL_CACHE" 2>/dev/null || echo "[]"
}

# Auto-detect hardware information
detect_hardware() {
    local cpu="$(lscpu 2>/dev/null | grep 'Model name' | cut -d: -f2 | xargs || echo 'Unknown')"
    local ram="$(free -h 2>/dev/null | grep Mem | awk '{print $2}' || echo 'Unknown')"
    local gpu="Unknown"
    local os="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Unknown')"
    
    # Detect GPU
    if command -v nvidia-smi &>/dev/null; then
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo 'NVIDIA GPU (details unavailable)')"
    elif lspci 2>/dev/null | grep -i nvidia &>/dev/null; then
        gpu="NVIDIA GPU (nvidia-smi not available)"
    elif lspci 2>/dev/null | grep -i amd.*vga &>/dev/null; then
        gpu="AMD GPU"
    fi
    
    # Return as JSON
    jq -n \
        --arg cpu "$cpu" \
        --arg ram "$ram" \
        --arg gpu "$gpu" \
        --arg os "$os" \
        '{
            cpu: $cpu,
            ram: $ram,
            gpu: $gpu,
            os: $os
        }'
}

# Register or update a cluster node (control plane or worker)
# Usage: register_cluster_node --name <name> --role <role> --location <location> [options]
register_cluster_node() {
    local node_name=""
    local k8s_node_name=""
    local role=""  # control-plane or worker
    local location=""
    local tailscale_ip=""
    local ip=""
    local ssh_user=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                node_name="$2"
                shift 2
                ;;
            --k8s-node-name)
                k8s_node_name="$2"
                shift 2
                ;;
            --role)
                role="$2"
                shift 2
                ;;
            --location)
                location="$2"
                shift 2
                ;;
            --tailscale-ip)
                tailscale_ip="$2"
                shift 2
                ;;
            --ip)
                ip="$2"
                shift 2
                ;;
            --ssh-user)
                ssh_user="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    # VALIDATION: Required fields
    if [[ -z "$node_name" ]]; then
        log_error "--name is required"
        return 1
    fi
    
    if [[ -z "$role" ]]; then
        log_error "--role is required (control-plane or worker)"
        return 1
    fi
    
    if [[ ! "$role" =~ ^(control-plane|worker)$ ]]; then
        log_error "Invalid role: $role (must be control-plane or worker)"
        return 1
    fi
    
    log_info "Registering cluster node: $node_name ($role)..."
    
    # Auto-detect Tailscale IP if not provided
    if [[ -z "$tailscale_ip" ]] && command -v tailscale &>/dev/null; then
        tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "")
        if [[ -n "$tailscale_ip" ]]; then
            log_info "Detected Tailscale IP: $tailscale_ip"
        fi
    fi
    
    # Use Tailscale IP as primary IP if not provided
    if [[ -z "$ip" ]]; then
        ip="$tailscale_ip"
    fi
    
    # Auto-detect SSH user if not provided
    if [[ -z "$ssh_user" ]]; then
        ssh_user="${SUDO_USER:-$(whoami)}"
        log_info "Using SSH user: $ssh_user"
    fi
    
    # Use node_name as k8s_node_name if not provided
    if [[ -z "$k8s_node_name" ]]; then
        k8s_node_name="$node_name"
    fi
    
    # Auto-detect hardware
    local hardware_json=$(detect_hardware)
    
    # Get K3s version if available
    local k3s_version="Unknown"
    if command -v kubectl &>/dev/null; then
        k3s_version=$(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' || echo "Unknown")
    fi
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # Build cluster node entry
    local node_entry=$(jq -n \
        --arg name "$node_name" \
        --arg k8s_name "$k8s_node_name" \
        --arg role "$role" \
        --arg location "$location" \
        --arg ip "$ip" \
        --arg ts_ip "$tailscale_ip" \
        --arg ssh_user "$ssh_user" \
        --arg k3s_version "$k3s_version" \
        --arg timestamp "$(date -Iseconds)" \
        --argjson hardware "$hardware_json" \
        '{
            name: $name,
            k8s_node_name: $k8s_name,
            k8s_node_name_custom: ($name != $k8s_name),
            role: $role,
            location: $location,
            ip: $ip,
            tailscale_ip: $ts_ip,
            tailscale_hostname: ($ts_ip + ".tailscale.net"),
            ssh_user: $ssh_user,
            hardware: $hardware,
            longhorn: {
                enabled: false,
                scheduling_enabled: true,
                disks: [],
                total_capacity: "0"
            },
            minio: {
                enabled: false,
                endpoint: "",
                console: "",
                disk: "",
                capacity: "0",
                mode: "standalone",
                credentials_secret: "minio-credentials",
                namespace: "minio"
            },
            installation: {
                bootstrap_date: $timestamp,
                mynodeone_version: "1.5.0",
                k3s_version: $k3s_version,
                installed_components: []
            },
            registered: $timestamp,
            last_updated: $timestamp,
            status: "active"
        }')
    
    # Remove existing entry for this node name if present
    local updated_registry=$(jq \
        --arg name "$node_name" \
        --argjson entry "$node_entry" \
        'del(.cluster_nodes[] | select(.name == $name)) | .cluster_nodes += [$entry]' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update registry with new cluster node"
        return 1
    fi
    
    # Save updated registry to local cache
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    
    # VALIDATION: Verify node was added
    local verify_node=$(jq -r \
        --arg name "$node_name" \
        '.cluster_nodes[] | select(.name == $name) | .role' \
        "$LOCAL_CACHE")
    
    if [[ "$verify_node" != "$role" ]]; then
        log_error "Cluster node registration validation failed"
        return 1
    fi
    
    # Sync to ConfigMap
    sync_to_configmap || return 1
    
    log_success "Registered cluster node: $node_name ($role) at $ip"
    return 0
}

# Update cluster node with Longhorn configuration
# Usage: update_cluster_node_longhorn --name <name> --disks <disk1,disk2> [--capacity <total>]
update_cluster_node_longhorn() {
    local node_name=""
    local disks_csv=""
    local total_capacity=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                node_name="$2"
                shift 2
                ;;
            --disks)
                disks_csv="$2"
                shift 2
                ;;
            --capacity)
                total_capacity="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    if [[ -z "$node_name" ]]; then
        log_error "--name is required"
        return 1
    fi
    
    log_info "Updating Longhorn configuration for node: $node_name..."
    
    # Sync from ConfigMap
    sync_from_configmap || return 1
    
    # Build disks array from CSV
    local disks_array='[]'
    if [[ -n "$disks_csv" ]]; then
        IFS=',' read -ra DISK_LIST <<< "$disks_csv"
        for disk_path in "${DISK_LIST[@]}"; do
            disk_path=$(echo "$disk_path" | xargs)  # trim whitespace
            local disk_size="Unknown"
            if [[ -b "$disk_path" ]]; then
                disk_size=$(lsblk -b -d -n -o SIZE "$disk_path" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "Unknown")
            fi
            # Extract disk basename for mount point
            local disk_basename=$(basename "$disk_path")
            local mount_point="/mnt/longhorn-disks/disk-${disk_basename}"
            
            disks_array=$(echo "$disks_array" | jq \
                --arg path "$disk_path" \
                --arg size "$disk_size" \
                --arg mount "$mount_point" \
                '. += [{path: $path, size: $size, mount_point: $mount}]')
        done
    fi
    
    # Update node entry
    local updated_registry=$(jq \
        --arg name "$node_name" \
        --argjson disks "$disks_array" \
        --arg capacity "$total_capacity" \
        --arg timestamp "$(date -Iseconds)" \
        '(.cluster_nodes[] | select(.name == $name) | .longhorn) = {
            enabled: true,
            scheduling_enabled: true,
            disks: $disks,
            total_capacity: $capacity
        } | (.cluster_nodes[] | select(.name == $name) | .last_updated) = $timestamp | 
        (.cluster_nodes[] | select(.name == $name) | .installation.installed_components) |= (. + ["longhorn"] | unique)' \
        "$LOCAL_CACHE")
    
    # Save and sync
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    sync_to_configmap || return 1
    
    log_success "Updated Longhorn configuration for $node_name"
    return 0
}

# Update cluster node with MinIO configuration
# Usage: update_cluster_node_minio --name <name> --endpoint <endpoint> --disk <disk> [options]
update_cluster_node_minio() {
    local node_name=""
    local endpoint=""
    local console=""
    local disk=""
    local capacity=""
    local namespace="minio"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                node_name="$2"
                shift 2
                ;;
            --endpoint)
                endpoint="$2"
                shift 2
                ;;
            --console)
                console="$2"
                shift 2
                ;;
            --disk)
                disk="$2"
                shift 2
                ;;
            --capacity)
                capacity="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    if [[ -z "$node_name" ]]; then
        log_error "--name is required"
        return 1
    fi
    
    if [[ -z "$endpoint" ]]; then
        log_error "--endpoint is required"
        return 1
    fi
    
    log_info "Updating MinIO configuration for node: $node_name..."
    
    # Sync from ConfigMap
    sync_from_configmap || return 1
    
    # Auto-generate console endpoint if not provided
    if [[ -z "$console" ]]; then
        console="${endpoint/:9000/:9001}"  # Replace port 9000 with 9001
    fi
    
    # Detect disk capacity if not provided
    if [[ -z "$capacity" ]] && [[ -n "$disk" ]] && [[ -b "$disk" ]]; then
        capacity=$(lsblk -b -d -n -o SIZE "$disk" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "Unknown")
    fi
    
    # Update node entry
    local updated_registry=$(jq \
        --arg name "$node_name" \
        --arg endpoint "$endpoint" \
        --arg console "$console" \
        --arg disk "$disk" \
        --arg capacity "$capacity" \
        --arg namespace "$namespace" \
        --arg timestamp "$(date -Iseconds)" \
        '(.cluster_nodes[] | select(.name == $name) | .minio) = {
            enabled: true,
            endpoint: $endpoint,
            console: $console,
            disk: $disk,
            capacity: $capacity,
            mode: "standalone",
            credentials_secret: "minio-credentials",
            namespace: $namespace
        } | (.cluster_nodes[] | select(.name == $name) | .last_updated) = $timestamp |
        (.cluster_nodes[] | select(.name == $name) | .installation.installed_components) |= (. + ["minio"] | unique)' \
        "$LOCAL_CACHE")
    
    # Save and sync
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    sync_to_configmap || return 1
    
    log_success "Updated MinIO configuration for $node_name"
    return 0
}

# Get cluster node by name
# Usage: get_cluster_node <name>
get_cluster_node() {
    local node_name="$1"
    
    if [[ -z "$node_name" ]]; then
        log_error "Node name is required"
        return 1
    fi
    
    # Sync from ConfigMap
    sync_from_configmap || return 1
    
    # Get node
    jq -r --arg name "$node_name" '.cluster_nodes[] | select(.name == $name)' "$LOCAL_CACHE" 2>/dev/null
}

# List all cluster nodes
# Usage: list_cluster_nodes [--role <role>]
list_cluster_nodes() {
    local role_filter=""
    
    if [[ "${1:-}" == "--role" ]] && [[ -n "${2:-}" ]]; then
        role_filter="$2"
    fi
    
    # Sync from ConfigMap
    sync_from_configmap || return 1
    
    if [[ -n "$role_filter" ]]; then
        jq -r --arg role "$role_filter" '.cluster_nodes[] | select(.role == $role)' "$LOCAL_CACHE" 2>/dev/null
    else
        jq -r '.cluster_nodes[]' "$LOCAL_CACHE" 2>/dev/null
    fi
}

# Get registry statistics
get_stats() {
    sync_from_configmap || return 1
    
    local mgmt_count=$(jq -r '.management_laptops | length' "$LOCAL_CACHE")
    local vps_count=$(jq -r '.vps_nodes | length' "$LOCAL_CACHE")
    local worker_count=$(jq -r '.worker_nodes | length' "$LOCAL_CACHE")
    local cluster_count=$(jq -r '.cluster_nodes | length' "$LOCAL_CACHE")
    local last_updated=$(jq -r '.metadata.last_updated // "never"' "$LOCAL_CACHE")
    local updated_by=$(jq -r '.metadata.updated_by // "unknown"' "$LOCAL_CACHE")
    
    echo "Registry Statistics:"
    echo "  Management Laptops: $mgmt_count"
    echo "  VPS Nodes: $vps_count"
    echo "  Worker Nodes: $worker_count"
    echo "  Cluster Nodes: $cluster_count"
    echo "  Last Updated: $last_updated"
    echo "  Updated By: $updated_by"
}

# Main command handler
main() {
    local command="${1:-}"
    
    case "$command" in
        init)
            init_registry
            ;;
        register)
            shift
            register_node "$@"
            ;;
        get)
            shift
            get_nodes "$@"
            ;;
        sync-from)
            sync_from_configmap
            ;;
        sync-to)
            sync_to_configmap
            ;;
        stats)
            get_stats
            ;;
        register-cluster-node)
            shift
            register_cluster_node "$@"
            ;;
        update-longhorn)
            shift
            update_cluster_node_longhorn "$@"
            ;;
        update-minio)
            shift
            update_minio_config "$@"
            ;;
        get-cluster-node)
            shift
            get_cluster_node "$@"
            ;;
        list-cluster-nodes)
            shift
            list_cluster_nodes "$@"
            ;;
        *)
            cat << 'EOF'
Node Registry Manager - Central Registry with Validation

Usage:
  node-registry-manager.sh <command> [options]

Commands:
  init                          Initialize registry ConfigMap
  register <type> <ip> [name] [ssh_user] [port]
                                Register a node (auto-detects SSH user)
  get <type>                    Get all nodes of type
  sync-from                     Sync from ConfigMap to local cache
  sync-to                       Sync from local cache to ConfigMap
  stats                         Show registry statistics
  
  Cluster Node Commands:
  register-cluster-node --name <name> --role <role> --location <location> [options]
                                Register a cluster node (control-plane or worker)
  update-longhorn --name <name> --disks <disk1,disk2> [--capacity <total>]
                                Update Longhorn configuration for node
  update-minio --name <name> --endpoint <endpoint> --disk <disk> [options]
                                Update MinIO configuration for node
  get-cluster-node <name>       Get cluster node by name
  list-cluster-nodes [--role <role>]
                                List all cluster nodes (optionally filter by role)

Node Types:
  management_laptops, vps_nodes, worker_nodes, cluster_nodes

Examples:
  # Register VPS (auto-detects SSH user)
  node-registry-manager.sh register vps_nodes 100.105.188.46
  
  # Register cluster node (control plane)
  node-registry-manager.sh register-cluster-node \
    --name pc1 --role control-plane --location home --tailscale-ip 100.64.0.2
  
  # Update Longhorn config after installation
  node-registry-manager.sh update-longhorn \
    --name pc1 --disks /dev/sdb,/dev/sdc --capacity 40TB
  
  # Update MinIO config after installation
  node-registry-manager.sh update-minio \
    --name pc1 --endpoint minio-pc1.mynodeone.local:9000 --disk /dev/sdd
  
  # Get cluster node details
  node-registry-manager.sh get-cluster-node pc1
  
  # List all worker nodes
  node-registry-manager.sh list-cluster-nodes --role worker

Features:
  ConfigMap as single source of truth
  Automatic SSH user detection
  Hardware auto-detection (CPU, RAM, GPU, OS)
  Storage metadata tracking (Longhorn + MinIO)
  Validation after every operation
  No assumptions about users or paths
  Automatic rollback on failures
EOF
            exit 1
            ;;
    esac
}

# Register or update a VPS edge node with comprehensive metadata
# Usage: register_vps_node --name <name> --tailscale-ip <ip> --public-ip <ip> [options]
register_vps_node() {
    local node_name=""
    local tailscale_ip=""
    local public_ip=""
    local ssh_user=""
    local location=""
    local provider=""
    local webhook_port="8080"
    local repo_path=""
    local metadata_json=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                node_name="$2"
                shift 2
                ;;
            --tailscale-ip)
                tailscale_ip="$2"
                shift 2
                ;;
            --public-ip)
                public_ip="$2"
                shift 2
                ;;
            --ssh-user)
                ssh_user="$2"
                shift 2
                ;;
            --location)
                location="$2"
                shift 2
                ;;
            --provider)
                provider="$2"
                shift 2
                ;;
            --webhook-port)
                webhook_port="$2"
                shift 2
                ;;
            --repo-path)
                repo_path="$2"
                shift 2
                ;;
            --metadata-json)
                metadata_json="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    # VALIDATION: Required fields
    if [[ -z "$node_name" ]]; then
        log_error "Node name is required (--name)"
        return 1
    fi
    
    if [[ -z "$tailscale_ip" ]]; then
        log_error "Tailscale IP is required (--tailscale-ip)"
        return 1
    fi
    
    if [[ -z "$public_ip" ]]; then
        log_warn "Public IP not provided, using 'unknown'"
        public_ip="unknown"
    fi
    
    # Auto-detect SSH user if not provided
    if [[ -z "$ssh_user" ]]; then
        ssh_user=$(detect_ssh_user "$tailscale_ip" 2>/dev/null || echo "root")
        log_info "Auto-detected SSH user: $ssh_user"
    fi
    
    log_info "Registering VPS node: $node_name ($tailscale_ip)"
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # If metadata JSON is provided, use it; otherwise create basic metadata
    local hardware_json
    local traefik_json
    local installation_json
    
    if [[ -n "$metadata_json" ]]; then
        # Extract components from provided metadata
        hardware_json=$(echo "$metadata_json" | jq -c '.hardware // {}')
        traefik_json=$(echo "$metadata_json" | jq -c '.traefik // {}')
        installation_json=$(echo "$metadata_json" | jq -c '.installation // {}')
        
        # Extract location and provider if not provided
        if [[ -z "$location" ]]; then
            location=$(echo "$metadata_json" | jq -r '.location // "unknown"')
        fi
        if [[ -z "$provider" ]]; then
            provider=$(echo "$metadata_json" | jq -r '.provider // "unknown"')
        fi
    else
        # Create default metadata
        hardware_json='{"cpu":"Unknown","ram":"Unknown","disk":"Unknown","os":"Unknown"}'
        traefik_json='{"enabled":false,"version":"unknown"}'
        installation_json='{"docker_version":"unknown","mynodeone_version":"1.5.0"}'
        
        if [[ -z "$location" ]]; then
            location="unknown"
        fi
        if [[ -z "$provider" ]]; then
            provider="unknown"
        fi
    fi
    
    # Build VPS node entry with comprehensive metadata
    local node_entry=$(jq -n \
        --arg name "$node_name" \
        --arg tailscale_ip "$tailscale_ip" \
        --arg public_ip "$public_ip" \
        --arg ssh_user "$ssh_user" \
        --arg location "$location" \
        --arg provider "$provider" \
        --argjson webhook_port "$webhook_port" \
        --arg repo_path "$repo_path" \
        --argjson hardware "$hardware_json" \
        --argjson traefik "$traefik_json" \
        --argjson installation "$installation_json" \
        --arg timestamp "$(date -Iseconds)" \
        '{
            name: $name,
            ip: $tailscale_ip,
            tailscale_ip: $tailscale_ip,
            tailscale_hostname: ($tailscale_ip + ".tailscale.net"),
            public_ip: $public_ip,
            ssh_user: $ssh_user,
            webhook_port: $webhook_port,
            repo_path: $repo_path,
            role: "edge",
            location: $location,
            provider: $provider,
            hardware: $hardware,
            traefik: $traefik,
            installation: $installation,
            registered: $timestamp,
            last_sync: null,
            last_updated: $timestamp,
            status: "active"
        }')
    
    # Remove existing entry for this IP if present
    local updated_registry=$(jq \
        --arg ip "$tailscale_ip" \
        --argjson entry "$node_entry" \
        'del(.vps_nodes[] | select(.ip == $ip or .tailscale_ip == $ip)) | .vps_nodes += [$entry]' \
        "$LOCAL_CACHE")
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update registry with VPS node"
        return 1
    fi
    
    # Save updated registry to local cache
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    
    # VALIDATION: Verify node was added
    local verify_node=$(jq -r \
        --arg ip "$tailscale_ip" \
        '.vps_nodes[] | select(.ip == $ip or .tailscale_ip == $ip) | .name' \
        "$LOCAL_CACHE")
    
    if [[ "$verify_node" != "$node_name" ]]; then
        log_error "VPS node registration validation failed"
        return 1
    fi
    
    # Sync to ConfigMap
    sync_to_configmap || return 1
    
    # FINAL VALIDATION: Read back from ConfigMap to confirm
    sync_from_configmap || return 1
    local final_verify=$(jq -r \
        --arg ip "$tailscale_ip" \
        '.vps_nodes[] | select(.ip == $ip or .tailscale_ip == $ip) | .name' \
        "$LOCAL_CACHE")
    
    if [[ "$final_verify" != "$node_name" ]]; then
        log_error "Final validation failed - VPS node not in ConfigMap"
        return 1
    fi
    
    log_success "Registered VPS node: $node_name"
    log_success "  Tailscale IP: $tailscale_ip"
    log_success "  Public IP: $public_ip"
    log_success "  Location: $location"
    log_success "  Provider: $provider"
    log_success "✓ Validated in ConfigMap"
    return 0
}

# Update VPS node metadata (for post-installation updates)
# Usage: update_vps_metadata --name <name> --metadata-json <json>
update_vps_metadata() {
    local node_name=""
    local metadata_json=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                node_name="$2"
                shift 2
                ;;
            --metadata-json)
                metadata_json="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    
    # VALIDATION
    if [[ -z "$node_name" ]]; then
        log_error "Node name is required (--name)"
        return 1
    fi
    
    if [[ -z "$metadata_json" ]]; then
        log_error "Metadata JSON is required (--metadata-json)"
        return 1
    fi
    
    log_info "Updating VPS node metadata: $node_name"
    
    # Sync from ConfigMap first
    sync_from_configmap || return 1
    
    # Check if node exists
    local node_exists=$(jq -r \
        --arg name "$node_name" \
        '.vps_nodes[] | select(.name == $name) | .name' \
        "$LOCAL_CACHE")
    
    if [[ "$node_exists" != "$node_name" ]]; then
        log_error "VPS node not found: $node_name"
        return 1
    fi
    
    # Extract metadata components
    local hardware=$(echo "$metadata_json" | jq -c '.hardware // {}')
    local traefik=$(echo "$metadata_json" | jq -c '.traefik // {}')
    local installation=$(echo "$metadata_json" | jq -c '.installation // {}')
    local location=$(echo "$metadata_json" | jq -r '.location // empty')
    local provider=$(echo "$metadata_json" | jq -r '.provider // empty')
    local public_ip=$(echo "$metadata_json" | jq -r '.public_ip // empty')
    
    # Update node entry
    local updated_registry=$(jq \
        --arg name "$node_name" \
        --argjson hardware "$hardware" \
        --argjson traefik "$traefik" \
        --argjson installation "$installation" \
        --arg timestamp "$(date -Iseconds)" \
        '(.vps_nodes[] | select(.name == $name)) |= (
            .hardware = $hardware |
            .traefik = $traefik |
            .installation = $installation |
            .last_updated = $timestamp
        )' \
        "$LOCAL_CACHE")
    
    # Update optional fields if provided
    if [[ -n "$location" ]]; then
        updated_registry=$(echo "$updated_registry" | jq \
            --arg name "$node_name" \
            --arg location "$location" \
            '(.vps_nodes[] | select(.name == $name)).location = $location')
    fi
    
    if [[ -n "$provider" ]]; then
        updated_registry=$(echo "$updated_registry" | jq \
            --arg name "$node_name" \
            --arg provider "$provider" \
            '(.vps_nodes[] | select(.name == $name)).provider = $provider')
    fi
    
    if [[ -n "$public_ip" ]]; then
        updated_registry=$(echo "$updated_registry" | jq \
            --arg name "$node_name" \
            --arg public_ip "$public_ip" \
            '(.vps_nodes[] | select(.name == $name)).public_ip = $public_ip')
    fi
    
    # VALIDATION: Verify jq succeeded
    if ! echo "$updated_registry" | jq empty 2>/dev/null; then
        log_error "Failed to update VPS metadata"
        return 1
    fi
    
    # Save updated registry to local cache
    echo "$updated_registry" | jq '.' > "$LOCAL_CACHE"
    
    # Sync to ConfigMap
    sync_to_configmap || return 1
    
    log_success "Updated VPS node metadata: $node_name"
    return 0
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
