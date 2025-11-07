#!/bin/bash

###############################################################################
# Post-Installation Routing Helper
# 
# Uses centralized service registry for DNS and routing
# Called by app install scripts
###############################################################################

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

# Parameters
APP_NAME="$1"
APP_PORT="$2"
SUBDOMAIN="$3"
NAMESPACE="${4:-$APP_NAME}"
SERVICE_NAME="${5:-${APP_NAME}-server}"
MAKE_PUBLIC="${6:-false}"

if [[ -z "$APP_NAME" ]] || [[ -z "$APP_PORT" ]] || [[ -z "$SUBDOMAIN" ]]; then
    echo "Usage: source post-install-routing.sh <app-name> <port> <subdomain> [namespace] [service-name] [public]"
    return 1
fi

# Load configuration
if [[ -f ~/.mynodeone/config.env ]]; then
    source ~/.mynodeone/config.env
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mycloud}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Registering Service: $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Register service in central registry
log_info "Registering in service registry..."

if bash "$SCRIPT_DIR/service-registry.sh" register \
    "$APP_NAME" "$SUBDOMAIN" "$NAMESPACE" "$SERVICE_NAME" "$APP_PORT" "$MAKE_PUBLIC" 2>&1; then
    log_success "Service registered in cluster"
else
    log_warn "Could not register service (kubectl may not be configured)"
fi

# 2. Update local DNS entries on control plane
log_info "Updating local DNS on this machine..."

DNS_ENTRIES=$(bash "$SCRIPT_DIR/service-registry.sh" export-dns "${CLUSTER_DOMAIN}.local" 2>/dev/null || echo "")

if [[ -n "$DNS_ENTRIES" ]]; then
    # Backup /etc/hosts
    sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # Remove old MyNodeOne entries
    sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts 2>/dev/null || true
    
    # Add new entries
    {
        echo ""
        echo "$DNS_ENTRIES"
        echo ""
    } | sudo tee -a /etc/hosts > /dev/null
    
    log_success "Local DNS updated"
fi

# 3. Interactive public access configuration
if [[ -n "$PUBLIC_DOMAIN" ]] || command -v kubectl &>/dev/null; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌍 Public Access Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check if domains are registered
    REGISTERED_DOMAINS=""
    if command -v kubectl &>/dev/null; then
        REGISTERED_DOMAINS=$(kubectl get configmap -n kube-system domain-registry \
            -o jsonpath='{.data.domains\.json}' 2>/dev/null | \
            jq -r 'keys[]' 2>/dev/null || echo "")
    fi
    
    if [[ -n "$REGISTERED_DOMAINS" ]] || [[ -n "$PUBLIC_DOMAIN" ]]; then
        echo "Do you want to make this app publicly accessible from the internet?"
        echo ""
        echo "Options:"
        echo "  1. Yes, make it public (expose via domain)"
        echo "  2. No, keep it local-only (Tailscale VPN access only)"
        echo "  3. Configure later"
        echo ""
        read -p "Choice (1/2/3): " public_choice
        
        case "$public_choice" in
            1)
                # User wants to make it public
                echo ""
                
                # Show available domains
                if [[ -n "$REGISTERED_DOMAINS" ]]; then
                    echo "Available domains:"
                    echo ""
                    
                    declare -a domain_array
                    i=1
                    while read -r domain; do
                        echo "  $i. $domain"
                        domain_array[$i]="$domain"
                        ((i++))
                    done <<< "$REGISTERED_DOMAINS"
                    
                    echo ""
                    echo "Select domains (comma-separated numbers, 'all', or press Enter for all):"
                    read -p "Selection: " domain_selection
                    
                    selected_domains=""
                    if [[ -z "$domain_selection" ]] || [[ "$domain_selection" == "all" ]]; then
                        selected_domains=$(echo "$REGISTERED_DOMAINS" | tr '\n' ',' | sed 's/,$//')
                    else
                        declare -a domain_list
                        IFS=',' read -ra NUMS <<< "$domain_selection"
                        for num in "${NUMS[@]}"; do
                            num=$(echo "$num" | xargs)
                            [[ -n "${domain_array[$num]:-}" ]] && domain_list+=("${domain_array[$num]}")
                        done
                        selected_domains=$(IFS=','; echo "${domain_list[*]}")
                    fi
                    
                elif [[ -n "$PUBLIC_DOMAIN" ]]; then
                    # Use PUBLIC_DOMAIN from config
                    echo "Using domain from config: $PUBLIC_DOMAIN"
                    selected_domains="$PUBLIC_DOMAIN"
                else
                    echo "No domains configured yet."
                    echo ""
                    read -p "Enter your domain (e.g., example.com): " user_domain
                    
                    if [[ -n "$user_domain" ]]; then
                        selected_domains="$user_domain"
                        
                        # Register domain
                        if command -v kubectl &>/dev/null; then
                            bash "$SCRIPT_DIR/multi-domain-registry.sh" register-domain \
                                "$user_domain" "Added during $APP_NAME installation" 2>/dev/null || true
                            log_success "Domain registered: $user_domain"
                        fi
                        
                        # Save to config
                        if ! grep -q "PUBLIC_DOMAIN=" ~/.mynodeone/config.env 2>/dev/null; then
                            echo "PUBLIC_DOMAIN=\"$user_domain\"" >> ~/.mynodeone/config.env
                        fi
                    fi
                fi
                
                # Configure routing if domains selected
                if [[ -n "$selected_domains" ]]; then
                    echo ""
                    log_info "Configuring public access..."
                    
                    # Get VPS nodes
                    VPS_NODES=""
                    if command -v kubectl &>/dev/null; then
                        VPS_NODES=$(kubectl get configmap -n kube-system domain-registry \
                            -o jsonpath='{.data.vps-nodes\.json}' 2>/dev/null | \
                            jq -r 'keys[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
                    fi
                    
                    if [[ -n "$VPS_NODES" ]]; then
                        # Configure routing
                        if bash "$SCRIPT_DIR/multi-domain-registry.sh" configure-routing \
                            "$APP_NAME" "$selected_domains" "$VPS_NODES" "round-robin" 2>/dev/null; then
                            log_success "Public routing configured"
                        fi
                        
                        # Update service to mark as public
                        bash "$SCRIPT_DIR/service-registry.sh" register \
                            "$APP_NAME" "$SUBDOMAIN" "$NAMESPACE" "$SERVICE_NAME" "$APP_PORT" "true" 2>/dev/null || true
                        
                        # Trigger sync
                        if bash "$SCRIPT_DIR/sync-controller.sh" push 2>/dev/null; then
                            log_success "Configuration pushed to VPS nodes"
                        else
                            log_warn "Auto-sync unavailable, use manual sync"
                        fi
                        
                        MAKE_PUBLIC="true"
                    else
                        log_warn "No VPS nodes registered yet"
                        echo ""
                        echo "To complete public access setup:"
                        echo "  1. Install VPS edge node: sudo ./scripts/mynodeone → Option 3"
                        echo "  2. Then run: sudo ./scripts/manage-app-visibility.sh"
                    fi
                fi
                ;;
                
            2)
                log_info "App will be local-only (accessible via Tailscale VPN)"
                MAKE_PUBLIC="false"
                ;;
                
            *)
                log_info "You can configure public access later with:"
                echo "  sudo ./scripts/manage-app-visibility.sh"
                MAKE_PUBLIC="false"
                ;;
        esac
    fi
fi

# 4. Show access URLs
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Service Registered Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Access via:"
echo "   • Local: http://${SUBDOMAIN}.${CLUSTER_DOMAIN}.local"

if [[ "$MAKE_PUBLIC" == "true" ]] && [[ -n "${selected_domains:-}" ]]; then
    IFS=',' read -ra DOMAINS <<< "$selected_domains"
    for domain in "${DOMAINS[@]}"; do
        echo "   • Public: https://${SUBDOMAIN}.${domain}"
    done
fi

echo ""

# 5. Show next steps
if [[ "$MAKE_PUBLIC" != "true" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📡 Accessing Your Service"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "From management laptops (after DNS sync):"
    echo "  cd ~/MyNodeOne && sudo ./scripts/sync-dns.sh"
    echo "  Then open: http://${SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
    echo ""
    
    log_info "To make public later:"
    echo "  sudo ./scripts/manage-app-visibility.sh"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
