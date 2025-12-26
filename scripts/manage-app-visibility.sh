#!/bin/bash

###############################################################################
# Manage App Public Visibility
# 
# Make apps publicly accessible or private (local-only)
# Handles edge cases, retries, and verification
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_RETRIES=3

# Load cluster config
ACTUAL_HOME="${HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi
if [ -f "$ACTUAL_HOME/.mynodeone/config.env" ]; then
    source "$ACTUAL_HOME/.mynodeone/config.env"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"

# Retry function with exponential backoff
retry_command() {
    local max_attempts="$1"
    shift
    local cmd="$@"
    local attempt=1
    local delay=2
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd" 2>/dev/null; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Verify kubectl access
verify_cluster_access() {
    if ! retry_command 3 "kubectl get nodes"; then
        log_error "Cannot access cluster"
        echo "Please ensure:"
        echo "  1. You're on the control plane OR"
        echo "  2. kubectl is configured to access the cluster"
        return 1
    fi
    return 0
}

# Verify service exists
verify_service_exists() {
    local service_name="$1"
    
    if ! kubectl get configmap -n kube-system service-registry \
        -o jsonpath="{.data.services\.json}" 2>/dev/null | \
        jq -e ".[\"$service_name\"]" &>/dev/null; then
        log_error "Service '$service_name' not found in registry"
        return 1
    fi
    return 0
}

# Verify domain registry exists
verify_domain_registry() {
    if ! kubectl get configmap -n kube-system domain-registry &>/dev/null; then
        log_warn "Domain registry not initialized"
        log_info "Initializing now..."
        
        if bash "$SCRIPT_DIR/lib/multi-domain-registry.sh" init; then
            log_success "Domain registry initialized"
            return 0
        else
            log_error "Failed to initialize domain registry"
            return 1
        fi
    fi
    return 0
}

# Check if VPS nodes are available
check_vps_availability() {
    local vps_count=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq '.vps_nodes | length' 2>/dev/null || echo "0")
    
    if [ "$vps_count" -eq 0 ]; then
        log_warn "No VPS nodes registered"
        echo ""
        echo "To make apps publicly accessible, you need a VPS edge node."
        echo "Install one with: sudo ./scripts/mynodeone → Option 3 (VPS Edge Node)"
        echo ""
        return 1
    fi
    return 0
}

# Check if domains are configured
check_domain_availability() {
    local domain_count=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
        jq '.domains | length' 2>/dev/null || echo "0")
    
    if [ "$domain_count" -eq 0 ]; then
        log_warn "No domains registered"
        echo ""
        echo "To make apps publicly accessible, you need a domain."
        echo "Add one with: sudo ./scripts/add-domain.sh"
        echo ""
        return 1
    fi
    return 0
}

# Make app public
make_public() {
    local service_name="$1"
    local domains="${2:-}"
    local vps_nodes="${3:-}"
    
    log_info "Making '$service_name' publicly accessible..."
    
    # Update service registry to mark as public
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null)
    
    local updated_services=$(echo "$services" | jq \
        --arg service "$service_name" \
        '.[$service].public = true')
    
    if ! kubectl patch configmap service-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"services.json\":\"$(echo "$updated_services" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}" &>/dev/null; then
        log_error "Failed to update service registry"
        return 1
    fi
    
    log_success "Service marked as public in registry"
    
    # Configure routing if domains and VPS provided
    if [ -n "$domains" ] && [ -n "$vps_nodes" ]; then
        log_info "Configuring routing..."
        
        if retry_command 3 "bash '$SCRIPT_DIR/lib/multi-domain-registry.sh' configure-routing \
            '$service_name' '$domains' '$vps_nodes' round-robin"; then
            log_success "Routing configured"
        else
            log_error "Failed to configure routing"
            return 1
        fi
        
        # Call app-specific post-public hook if it exists
        local service_info=$(kubectl get configmap -n kube-system service-registry \
            -o jsonpath="{.data.services\.json}" 2>/dev/null | \
            jq -r ".[\"$service_name\"]")
        local subdomain=$(echo "$service_info" | jq -r '.subdomain')
        local namespace=$(echo "$service_info" | jq -r '.namespace')
        
        # Look for post-public-hook.sh in app directory
        local hook_path="$SCRIPT_DIR/apps/$service_name/post-public-hook.sh"
        if [ -f "$hook_path" ]; then
            log_info "Running app-specific configuration..."
            if bash "$hook_path" "$service_name" "$subdomain" "$domains"; then
                log_success "App-specific configuration completed"
            else
                log_warn "App-specific configuration had issues (check above)"
            fi
        fi
    fi
    
    # Verify configuration in ConfigMap
    sleep 1
    local is_public=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath="{.data.services\.json}" 2>/dev/null | \
        jq -r ".[\"$service_name\"].public" || echo "false")
    
    if [ "$is_public" != "true" ]; then
        log_error "✗ Service not marked as public in ConfigMap"
        return 1
    fi
    
    log_success "✓ Service marked as public in ConfigMap"
    
    # Get service details for verification
    local service_info=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath="{.data.services\.json}" 2>/dev/null | \
        jq -r ".[\"$service_name\"]")
    local subdomain=$(echo "$service_info" | jq -r '.subdomain')
    
    # Wait for Node Agent to sync routes to VPS nodes
    # Node Agents poll every 60s, Config API updates every 30s
    # Total max wait: ~90s, but usually faster
    if [ -n "$vps_nodes" ]; then
        log_info "Waiting for Node Agent to sync routes to VPS nodes..."
        echo "  (Node Agents poll every 60s - this may take up to 90 seconds)"
        echo ""
        
        local max_wait=120  # 2 minutes max
        local poll_interval=10
        local elapsed=0
        local all_synced=false
        
        IFS=',' read -ra VPS_ARRAY <<< "$vps_nodes"
        
        while [ $elapsed -lt $max_wait ]; do
            all_synced=true
            
            for vps_ip in "${VPS_ARRAY[@]}"; do
                vps_ip=$(echo "$vps_ip" | xargs)
                
                # Get VPS SSH user from registry
                local vps_user=$(kubectl get configmap -n kube-system sync-controller-registry \
                    -o jsonpath='{.data.registry\.json}' 2>/dev/null | \
                    jq -r ".vps_nodes[] | select(.ip==\"$vps_ip\") | .ssh_user" || echo "root")
                
                # Check if routes file contains our service
                local route_check="test -f ~/traefik/config/mynodeone-routes.yml && (grep -q '$subdomain:' ~/traefik/config/mynodeone-routes.yml || grep -q '$service_name' ~/traefik/config/mynodeone-routes.yml)"
                
                if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$vps_user@$vps_ip" "$route_check" 2>/dev/null; then
                    all_synced=false
                    break
                fi
            done
            
            if [ "$all_synced" = true ]; then
                break
            fi
            
            echo "  Waiting for sync... (${elapsed}s/${max_wait}s)"
            sleep $poll_interval
            elapsed=$((elapsed + poll_interval))
        done
        
        # Verify final state
        log_info "Verifying routes on VPS nodes..."
        local verification_failed=false
        
        for vps_ip in "${VPS_ARRAY[@]}"; do
            vps_ip=$(echo "$vps_ip" | xargs)
            
            local vps_user=$(kubectl get configmap -n kube-system sync-controller-registry \
                -o jsonpath='{.data.registry\.json}' 2>/dev/null | \
                jq -r ".vps_nodes[] | select(.ip==\"$vps_ip\") | .ssh_user" || echo "root")
            
            log_info "Checking VPS: $vps_ip (user: $vps_user)..."
            
            local route_check="test -f ~/traefik/config/mynodeone-routes.yml && (grep -q '$subdomain:' ~/traefik/config/mynodeone-routes.yml || grep -q '$service_name' ~/traefik/config/mynodeone-routes.yml)"
            
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$vps_user@$vps_ip" "$route_check" 2>/dev/null; then
                log_success "  ✓ Routes synced via Node Agent (subdomain: $subdomain)"
            else
                log_warn "  ⚠ Node Agent sync pending - falling back to SSH sync..."
                
                # Fallback: Force SSH sync for this VPS
                if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$vps_user@$vps_ip" \
                    "cd ~/mynodeone && sudo ./scripts/sync-vps-routes.sh" 2>/dev/null; then
                    log_success "  ✓ SSH sync completed"
                else
                    log_error "  ✗ SSH sync also failed"
                    verification_failed=true
                fi
            fi
            
            # Check if Traefik is running
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$vps_user@$vps_ip" \
                "docker ps | grep -q traefik" 2>/dev/null; then
                log_success "  ✓ Traefik is running"
            else
                log_error "  ✗ Traefik is NOT running"
                verification_failed=true
            fi
        done
        
        if [ "$verification_failed" = true ]; then
            log_error "VPS verification failed - routes may not be accessible"
            echo ""
            echo "Troubleshooting:"
            echo "  1. Check Node Agent status: ssh <user>@<vps-ip> 'systemctl status mynodeone-agent'"
            echo "  2. Check Traefik logs: ssh <user>@<vps-ip> 'docker logs traefik --tail 50'"
            echo "  3. Verify routes file: ssh <user>@<vps-ip> 'cat ~/traefik/config/mynodeone-routes.yml'"
            echo ""
            return 1
        fi
        
        log_success "✓ All VPS nodes verified"
        
        # Test HTTP endpoint accessibility
        log_info "Testing endpoint accessibility..."
        echo "  This may take 30-60 seconds for SSL certificate issuance..."
        
        IFS=',' read -ra DOMAIN_ARRAY <<< "$domains"
        local test_domain="${DOMAIN_ARRAY[0]}"
        local test_url="https://${subdomain}.${test_domain}"
        
        local max_attempts=12
        local attempt=1
        local endpoint_accessible=false
        
        while [ $attempt -le $max_attempts ]; do
            if curl -I -k -m 10 "$test_url" 2>/dev/null | grep -q "HTTP.*[23]0[0-9]"; then
                log_success "✓ Endpoint is accessible: $test_url"
                endpoint_accessible=true
                break
            fi
            
            if [ $attempt -lt $max_attempts ]; then
                echo "  Waiting for SSL certificate... ($attempt/$max_attempts)"
                sleep 5
            fi
            attempt=$((attempt + 1))
        done
        
        if [ "$endpoint_accessible" = false ]; then
            log_warn "⚠ Endpoint not accessible after ${max_attempts} attempts"
            echo ""
            echo "This is normal if:"
            echo "  • DNS records are not yet propagated (can take 5-10 minutes)"
            echo "  • SSL certificate is still being issued (first time only)"
            echo ""
            echo "Check:"
            echo "  1. DNS: dig $subdomain.$test_domain"
            echo "  2. Traefik logs: ssh $vps_user@$vps_ip 'docker logs traefik --tail 50'"
            echo "  3. Try again in 5 minutes: curl -I $test_url"
            echo ""
            # Don't fail here - DNS propagation can take time
        fi
    fi
    
    return 0
}

# Make app private
make_private() {
    local service_name="$1"
    
    log_info "Making '$service_name' private (local-only)..."
    
    # Update service registry to mark as private
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null)
    
    local updated_services=$(echo "$services" | jq \
        --arg service "$service_name" \
        '.[$service].public = false')
    
    if ! kubectl patch configmap service-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"services.json\":\"$(echo "$updated_services" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}" &>/dev/null; then
        log_error "Failed to update service registry"
        return 1
    fi
    
    log_success "Service marked as private in registry"
    
    # Remove from domain routing
    log_info "Removing from public routing..."
    
    local routing=$(kubectl get configmap -n kube-system domain-registry \
        -o jsonpath='{.data.routing\.json}' 2>/dev/null || echo "{}")
    
    local updated_routing=$(echo "$routing" | jq "del(.[\"$service_name\"])")
    
    if kubectl patch configmap domain-registry \
        -n kube-system \
        --type merge \
        -p "{\"data\":{\"routing.json\":\"$(echo "$updated_routing" | sed 's/"/\\"/g' | tr '\n' ' ')\"}}" &>/dev/null; then
        log_success "Removed from routing"
    else
        log_warn "Could not update routing (may not have been configured)"
    fi
    
    # Wait for Node Agent to remove routes from VPS nodes
    # Node Agents poll every 60s - route removal will happen on next sync
    log_info "Waiting for Node Agent to update VPS routes..."
    echo "  (Routes will be removed on next Node Agent sync cycle)"
    sleep 5  # Brief wait - we don't need to wait for full sync for private
    
    # Verify
    sleep 2
    local is_public=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath="{.data.services\.json}" 2>/dev/null | \
        jq -r ".[\"$service_name\"].public" || echo "true")
    
    if [ "$is_public" = "false" ]; then
        log_success "✓ Verified: Service is now private"
        return 0
    else
        log_error "✗ Verification failed: Service still marked as public"
        return 1
    fi
}

# Main interactive mode
main() {
    clear
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Manage App Public Visibility"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Verify cluster access
    if ! verify_cluster_access; then
        exit 1
    fi
    
    log_success "Cluster access verified"
    echo ""
    
    # Get all services
    local services=$(kubectl get configmap -n kube-system service-registry \
        -o jsonpath='{.data.services\.json}' 2>/dev/null || echo "{}")
    
    if [ "$services" = "{}" ]; then
        log_error "No services found in registry"
        echo "Install apps first, then run this script"
        exit 1
    fi
    
    # Display services
    echo "Available services:"
    echo ""
    
    declare -a service_array
    declare -a subdomain_array
    declare -a public_array
    i=1
    
    while IFS='|' read -r service subdomain is_public; do
        local status_marker="🔒 Private"
        [ "$is_public" = "true" ] && status_marker="🌍 Public"
        
        echo "  $i. $service ($subdomain) - $status_marker"
        service_array[$i]="$service"
        subdomain_array[$i]="$subdomain"
        public_array[$i]="$is_public"
        ((i++))
    done < <(echo "$services" | jq -r 'to_entries[] | "\(.key)|\(.value.subdomain)|\(.value.public // false)"')
    
    echo ""
    read -p "Select service number: " service_num
    
    local selected_service="${service_array[$service_num]:-}"
    if [ -z "$selected_service" ]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    local current_status="${public_array[$service_num]:-false}"
    local subdomain="${subdomain_array[$service_num]:-}"
    
    echo ""
    echo "Selected: $selected_service ($subdomain)"
    echo "Current status: $([ "$current_status" = "true" ] && echo "🌍 Public" || echo "🔒 Private (local-only)")"
    echo ""
    
    echo "What do you want to do?"
    echo "  1. Make public (accessible from internet)"
    echo "  2. Make private (local access only)"
    echo "  3. Cancel"
    echo ""
    read -p "Choice: " action_choice
    
    case "$action_choice" in
        1)
            # Make public
            if [ "$current_status" = "true" ]; then
                log_info "Service is already public"
                echo ""
                read -p "Reconfigure routing? (y/n): " reconfig
                [ "$reconfig" != "y" ] && exit 0
            fi
            
            echo ""
            
            # Verify prerequisites
            if ! verify_domain_registry; then
                exit 1
            fi
            
            if ! check_vps_availability; then
                exit 1
            fi
            
            if ! check_domain_availability; then
                exit 1
            fi
            
            # Select domains
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Select Domains"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            declare -a domain_array
            i=1
            while read -r domain; do
                echo "  $i. $domain"
                domain_array[$i]="$domain"
                ((i++))
            done < <(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath='{.data.domains\.json}' 2>/dev/null | jq -r '.domains | keys[]')
            
            echo ""
            echo "Select domains (comma-separated numbers or 'all'):"
            read -p "Selection: " domain_selection
            
            local selected_domains=""
            if [ "$domain_selection" = "all" ]; then
                selected_domains=$(kubectl get configmap -n kube-system domain-registry \
                    -o jsonpath='{.data.domains\.json}' | jq -r '.domains | keys[]' | tr '\n' ',' | sed 's/,$//')
            else
                declare -a domain_list
                IFS=',' read -ra NUMS <<< "$domain_selection"
                for num in "${NUMS[@]}"; do
                    num=$(echo "$num" | xargs)
                    [ -n "${domain_array[$num]:-}" ] && domain_list+=("${domain_array[$num]}")
                done
                selected_domains=$(IFS=','; echo "${domain_list[*]}")
            fi
            
            # Select VPS nodes
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Select VPS Nodes"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            declare -a vps_array
            i=1
            while IFS='|' read -r ip public_ip region; do
                echo "  $i. $ip → $public_ip ($region)"
                vps_array[$i]="$ip"
                ((i++))
            done < <(kubectl get configmap -n kube-system domain-registry \
                -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
                jq -r '.vps_nodes[] | "\(.tailscale_ip)|\(.public_ip)|\(.location)"')
            
            echo ""
            echo "Select VPS nodes (comma-separated numbers or 'all'):"
            read -p "Selection: " vps_selection
            
            local selected_vps=""
            if [ "$vps_selection" = "all" ]; then
                selected_vps=$(kubectl get configmap -n kube-system domain-registry \
                    -o jsonpath='{.data.domains\.json}' | jq -r '.vps_nodes[].tailscale_ip' | tr '\n' ',' | sed 's/,$//')
            else
                declare -a vps_list
                IFS=',' read -ra NUMS <<< "$vps_selection"
                for num in "${NUMS[@]}"; do
                    num=$(echo "$num" | xargs)
                    [ -n "${vps_array[$num]:-}" ] && vps_list+=("${vps_array[$num]}")
                done
                selected_vps=$(IFS=','; echo "${vps_list[*]}")
            fi
            
            echo ""
            if make_public "$selected_service" "$selected_domains" "$selected_vps"; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ Service is Now Public!"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                
                IFS=',' read -ra DOMAINS <<< "$selected_domains"
                for domain in "${DOMAINS[@]}"; do
                    echo "  • https://${subdomain}.${domain}"
                done
                echo ""
                
                log_info "SSL certificates will be automatically obtained"
            else
                log_error "Failed to make service public"
                exit 1
            fi
            ;;
            
        2)
            # Make private
            if [ "$current_status" = "false" ]; then
                log_info "Service is already private"
                exit 0
            fi
            
            echo ""
            log_warn "This will make '$selected_service' accessible only via local network"
            read -p "Continue? (y/n): " confirm
            [ "$confirm" != "y" ] && exit 0
            
            echo ""
            if make_private "$selected_service"; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "  ✅ Service is Now Private!"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "  • http://${subdomain}.${CLUSTER_DOMAIN}.local (local access only)"
                echo ""
            else
                log_error "Failed to make service private"
                exit 1
            fi
            ;;
            
        *)
            log_info "Cancelled"
            exit 0
            ;;
    esac
}

# Run main if no arguments, otherwise support command-line mode
if [ $# -eq 0 ]; then
    main
else
    case "${1:-}" in
        public)
            verify_cluster_access || exit 1
            verify_service_exists "$2" || exit 1
            make_public "$2" "${3:-}" "${4:-}"
            ;;
        private)
            verify_cluster_access || exit 1
            verify_service_exists "$2" || exit 1
            make_private "$2"
            ;;
        *)
            echo "Usage: $0 [public|private] <service-name> [domains] [vps-nodes]"
            echo ""
            echo "Interactive mode:"
            echo "  $0"
            echo ""
            echo "Command-line mode:"
            echo "  $0 public immich"
            echo "  $0 public immich 'curiios.com,vinaysachdeva.com' '100.68.225.92'"
            echo "  $0 private immich"
            exit 1
            ;;
    esac
fi
