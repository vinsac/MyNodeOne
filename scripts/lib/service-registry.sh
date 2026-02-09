#!/bin/bash

###############################################################################
# Central Service Registry
# 
# Manages a centralized registry of all services in Kubernetes
# Single source of truth for DNS and routing configuration
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/project-root.sh" 2>/dev/null || source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null

# Source K8s utilities for robust KUBECONFIG detection
source "$PROJECT_ROOT/scripts/lib/k8s-utils.sh"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Initialize registry configmap if it doesn't exist
init_registry() {
    if ! kubectl get configmap -n kube-system service-registry &>/dev/null; then
        log_info "Creating service registry..."
        
        kubectl create configmap service-registry \
            -n kube-system \
            --from-literal=services.json='{}'
        
        log_success "Service registry created"
    fi
}

# Register a new service in the registry
# Usage: register_service <name> <local_name> <namespace> <service> <port> <public>
register_service() {
    local name="$1"
    local local_name="$2"
    local namespace="$3"
    local service="$4"
    local port="$5"
    local public="${6:-false}"
    
    log_info "Registering service: $name"
    
    # Get LoadBalancer IP
    local ip=$(kubectl get svc -n "$namespace" "$service" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$ip" ]]; then
        log_error "Could not get LoadBalancer IP for $service"
        return 1
    fi
    
    # Get current registry
    local registry=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    # Add/update service entry
    registry=$(echo "$registry" | jq \
        --arg name "$name" \
        --arg local_name "$local_name" \
        --arg namespace "$namespace" \
        --arg service "$service" \
        --arg ip "$ip" \
        --arg port "$port" \
        --arg public "$public" \
        '.[$name] = {
            local_name: $local_name,
            namespace: $namespace,
            service: $service,
            ip: $ip,
            port: ($port | tonumber),
            public: ($public == "true"),
            updated: now | todate
        }')
    
    # Update configmap using patch to preserve other fields
    kubectl patch configmap service-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"services.json\":\"$(echo "$registry" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}"
    
    log_success "Registered: $local_name → $ip"
    
    return 0
}

# Get all services from registry
get_all_services() {
    kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}'
}

# Get specific service from registry
get_service() {
    local name="$1"
    
    get_all_services | jq -r ".\"$name\" // empty"
}

# Sync registry with actual cluster state
# Discovers all LoadBalancer services and updates registry
sync_registry() {
    # Relax error handling for this function to handle partial failures
    set +e
    
    log_info "Syncing service registry with cluster state..."
    
    init_registry
    
    # Get current registry to preserve existing public flags
    local registry=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    # Get all LoadBalancer services
    local services=$(kubectl get svc --all-namespaces \
        -o json | jq -r '
        .items[] | 
        select(.spec.type == "LoadBalancer") |
        select(.status.loadBalancer.ingress != null) |
        select(.status.loadBalancer.ingress[0].ip != null) |
        {
            name: .metadata.name,
            namespace: .metadata.namespace,
            ip: .status.loadBalancer.ingress[0].ip,
            port: .spec.ports[0].port
        } | @json')
    
    if [[ -z "$services" ]]; then
        log_info "No LoadBalancer services found"
        return 0
    fi
    
    # Count total services found
    local total=$(echo "$services" | wc -l)
    log_info "Found $total LoadBalancer services"
    
    local count=0
    local failed=0
    while IFS= read -r svc; do
        # Skip empty lines
        [[ -z "$svc" ]] && continue
        
        local name=$(echo "$svc" | jq -r '.name' 2>/dev/null || echo "")
        local namespace=$(echo "$svc" | jq -r '.namespace' 2>/dev/null || echo "")
        local ip=$(echo "$svc" | jq -r '.ip' 2>/dev/null || echo "")
        local port=$(echo "$svc" | jq -r '.port' 2>/dev/null || echo "")
        
        # Skip if parsing failed
        if [[ -z "$name" ]] || [[ -z "$namespace" ]]; then
            log_info "Skipping malformed service entry"
            ((failed++))
            continue
        fi
        
        # Skip if IP is null or empty
        if [[ -z "$ip" ]] || [[ "$ip" == "null" ]]; then
            log_info "Skipping $namespace/$name (no IP yet)"
            ((failed++))
            continue
        fi
        
        # Check if service has subdomain annotation
        # Try multiple annotation formats for compatibility:
        # 1. ${CLUSTER_DOMAIN}.local/subdomain (new dynamic format)
        # 2. mynodeone.io/subdomain (legacy format)
        local cluster_domain=$(kubectl get configmap -n kube-system cluster-info \
            -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "mynodeone")
        
        local annotation=$(kubectl get svc -n "$namespace" "$name" \
            -o jsonpath="{.metadata.annotations.${cluster_domain}\.local/subdomain}" 2>/dev/null || echo "")
        
        # Fallback to legacy annotation if not found
        if [[ -z "$annotation" ]]; then
            annotation=$(kubectl get svc -n "$namespace" "$name" \
                -o jsonpath='{.metadata.annotations.mynodeone\.io/subdomain}' 2>/dev/null || echo "")
        fi
        
        # Determine local_name based on annotation or service name mapping
        local local_name=""
        local k8s_service_name="$name"
        if [[ -n "$annotation" ]]; then
            local_name="$annotation"
        else
            # Map common service names to friendly local_names
            case "$name" in
                dashboard)
                    local_name="dashboard"
                    ;;
                open-webui)
                    local_name="chat"
                    ;;
                demo)
                    local_name="demo"
                    ;;
                demo-chat-app)
                    local_name="demo-chat"
                    ;;
                argocd-server)
                    local_name="argocd"
                    ;;
                kube-prometheus-stack-grafana)
                    local_name="grafana"
                    ;;
                minio-console-*)
                    # Node-specific MinIO console: minio-console-canada-pc-0001 -> minio-console-canada-pc-0001
                    local_name="$name"
                    ;;
                minio-console)
                    # MinIO console without node suffix - derive from namespace
                    # namespace: minio-canada-pc-0001 -> registry key: minio-console-canada-pc-0001
                    local node_suffix="${namespace#minio-}"
                    name="minio-console-${node_suffix}"
                    local_name="$name"
                    ;;
                minio-*)
                    # Node-specific MinIO API: minio-canada-pc-0001 -> minio-canada-pc-0001
                    local_name="$name"
                    ;;
                minio)
                    # MinIO API without node suffix - derive from namespace
                    # namespace: minio-canada-pc-0001 -> registry key: minio-canada-pc-0001
                    local node_suffix="${namespace#minio-}"
                    name="minio-${node_suffix}"
                    local_name="$name"
                    ;;
                longhorn-frontend)
                    local_name="longhorn"
                    ;;
                longhorn)
                    # Longhorn manager API — use distinct name to avoid collision with longhorn-frontend
                    local_name="longhorn-api"
                    ;;
                traefik)
                    local_name="traefik"
                    ;;
                *-server)
                    local_name="${name%-server}"
                    ;;
                *-frontend)
                    local_name="${name%-frontend}"
                    ;;
                *)
                    local_name="$name"
                    ;;
            esac
        fi
        
        # Check if service already exists and preserve its public flag
        local existing_public=$(echo "$registry" | jq -r --arg name "$name" '.[$name].public // false' 2>/dev/null)
        
        # Register service (preserve existing public flag)
        if register_service "$name" "$local_name" "$namespace" "$k8s_service_name" "$port" "$existing_public" 2>&1 | grep -q "Registered"; then
            ((count++))
        else
            log_info "Failed to register $namespace/$name"
            ((failed++))
        fi
    done <<< "$services"
    
    log_success "Synced $count services"
    if [[ $failed -gt 0 ]]; then
        log_info "Skipped/Failed: $failed services"
    fi
    
    # Clean up stale entries (services that no longer exist in cluster)
    cleanup_stale_entries
    
    # Restore strict error handling
    set -e
}

# Remove registry entries for services that no longer exist in the cluster
cleanup_stale_entries() {
    log_info "Checking for stale registry entries..."
    
    # Get current registry entries
    local registry=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo '{}')
    
    if [[ "$registry" == "{}" ]]; then
        return 0
    fi
    
    # Get list of registered service names
    local registered_names=$(echo "$registry" | jq -r 'keys[]' 2>/dev/null)
    
    if [[ -z "$registered_names" ]]; then
        return 0
    fi
    
    local removed=0
    local new_registry="$registry"
    
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        
        # Get namespace and service name from registry entry
        local namespace=$(echo "$registry" | jq -r --arg name "$name" '.[$name].namespace // empty' 2>/dev/null)
        local service=$(echo "$registry" | jq -r --arg name "$name" '.[$name].service // empty' 2>/dev/null)
        
        if [[ -z "$namespace" ]] || [[ -z "$service" ]]; then
            continue
        fi
        
        # Check if service still exists in cluster (use actual service name, not registry key)
        if ! kubectl get svc -n "$namespace" "$service" &>/dev/null; then
            log_info "Removing stale entry: $name (service $namespace/$service no longer exists)"
            new_registry=$(echo "$new_registry" | jq --arg name "$name" 'del(.[$name])')
            ((removed++))
        fi
    done <<< "$registered_names"
    
    # Update registry if entries were removed
    if [[ $removed -gt 0 ]]; then
        # Use kubectl create --dry-run + apply to handle JSON escaping properly
        kubectl create configmap service-registry \
            -n kube-system \
            --from-literal="services.json=$(echo "$new_registry" | jq -c '.')" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "Removed $removed stale entries from registry"
    else
        log_info "No stale entries found"
    fi
}

# Export registry to DNS format for /etc/hosts
export_dns() {
    # Try to get domain from config if not provided
    local domain="${1:-}"
    if [ -z "$domain" ]; then
        local actual_home="${HOME}"
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            actual_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        fi
        if [ -f "$actual_home/.mynodeone/config.env" ]; then
            source "$actual_home/.mynodeone/config.env"
            domain="${CLUSTER_DOMAIN:-mynodeone}.local"
        else
            domain="mynodeone.local"
        fi
    fi
    
    local services=$(get_all_services)
    
    if [[ "$services" == "{}" ]]; then
        return 0
    fi
    
    echo "# MyNodeOne Services - Auto-generated on $(date)"
    echo "$services" | jq -r --arg domain "$domain" '
        to_entries[] |
        select(.value.ip != null) |
        if .value.local_name == "" then
            "\(.value.ip)\t\($domain)"
        elif .value.local_name == "dashboard" then
            "\(.value.ip)\t\(.value.local_name).\($domain)\n\(.value.ip)\t\($domain)"
        else
            "\(.value.ip)\t\(.value.local_name).\($domain)"
        end
    '
}

# Main command dispatcher
export_k8s_config || true

case "${1:-}" in
    init)
        init_registry
        ;;
    register)
        shift
        register_service "$@"
        ;;
    sync)
        sync_registry
        ;;
    export-dns)
        export_dns "$2"
        ;;
    show)
        show_registry
        ;;
    *)
        cat << 'EOF'
Service Registry - Clean Separation Architecture

Usage:
  service-registry.sh <command> [options]

Commands:
  init                          Initialize service registry ConfigMap
  register <name> <local_name> <namespace> <service> <port> <public>
                               Register a new service
  sync                         Sync registry with cluster state (discovers LoadBalancer services)
  export-dns [domain]          Export DNS entries for /etc/hosts (uses local_name)
  show                         Show all registered services

Notes:
  - local_name drives .local DNS only (e.g., chat -> chat.mynodeone.local)
  - Public routing is managed separately via domain-registry / manage-app-visibility.sh
  - Dashboard service gets both dashboard.DOMAIN and bare DOMAIN entries

Examples:
  service-registry.sh sync                          # Discover and register all services
  service-registry.sh export-dns                    # Uses CLUSTER_DOMAIN from config
  service-registry.sh export-dns mynodeone.local    # Explicit domain
  service-registry.sh show                          # Display registry contents

EOF
        exit 1
        ;;
esac
