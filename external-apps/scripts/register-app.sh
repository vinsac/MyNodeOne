#!/bin/bash

###############################################################################
# Register External App with MyNodeOne
# 
# Helper script for external apps to integrate with MyNodeOne infrastructure
# without being part of the MyNodeOne repository
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default values
APP_NAME=""
APP_SUBDOMAIN=""
APP_NAMESPACE=""
APP_SERVICE=""
APP_PORT="80"
MAKE_PUBLIC="false"
AUTO_DNS="true"

usage() {
    cat << EOF
Register External App with MyNodeOne

Usage:
  $(basename "$0") --name <name> --subdomain <subdomain> --namespace <namespace> --service <service> [options]

Required:
  --name <name>           Application name (for registry)
  --subdomain <subdomain> Subdomain for DNS (e.g., 'myapp' -> myapp.mynodeone.local)
  --namespace <namespace> Kubernetes namespace
  --service <service>     Kubernetes service name

Optional:
  --port <port>           Service port (default: 80)
  --public                Make app publicly accessible (default: false)
  --no-dns               Skip automatic DNS sync (default: auto-sync)
  --help                  Show this help message

Examples:
  # Register a simple web app
  $(basename "$0") \\
    --name myapp \\
    --subdomain myapp \\
    --namespace myapp \\
    --service myapp-frontend

  # Register an API with custom port
  $(basename "$0") \\
    --name myapi \\
    --subdomain api \\
    --namespace myapi \\
    --service myapi-backend \\
    --port 8080

  # Register and make public immediately
  $(basename "$0") \\
    --name mysaas \\
    --subdomain mysaas \\
    --namespace mysaas \\
    --service mysaas-web \\
    --public

EOF
    exit 1
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            APP_NAME="$2"
            shift 2
            ;;
        --subdomain)
            APP_SUBDOMAIN="$2"
            shift 2
            ;;
        --namespace)
            APP_NAMESPACE="$2"
            shift 2
            ;;
        --service)
            APP_SERVICE="$2"
            shift 2
            ;;
        --port)
            APP_PORT="$2"
            shift 2
            ;;
        --public)
            MAKE_PUBLIC="true"
            shift
            ;;
        --no-dns)
            AUTO_DNS="false"
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$APP_NAME" ]] || [[ -z "$APP_SUBDOMAIN" ]] || [[ -z "$APP_NAMESPACE" ]] || [[ -z "$APP_SERVICE" ]]; then
    log_error "Missing required parameters"
    usage
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registering External App with MyNodeOne"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "App Name:    $APP_NAME"
log_info "Subdomain:   $APP_SUBDOMAIN"
log_info "Namespace:   $APP_NAMESPACE"
log_info "Service:     $APP_SERVICE"
log_info "Port:        $APP_PORT"
log_info "Public:      $MAKE_PUBLIC"
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster."
    echo "Please ensure:"
    echo "  • KUBECONFIG is set correctly"
    echo "  • You have access to the cluster"
    exit 1
fi

# Check if service exists
log_info "Checking if service exists..."
if ! kubectl get svc -n "$APP_NAMESPACE" "$APP_SERVICE" &> /dev/null; then
    log_error "Service '$APP_SERVICE' not found in namespace '$APP_NAMESPACE'"
    echo "Please deploy your application first with:"
    echo "  kubectl apply -f your-app.yaml"
    exit 1
fi

# Check if service has LoadBalancer type
SERVICE_TYPE=$(kubectl get svc -n "$APP_NAMESPACE" "$APP_SERVICE" -o jsonpath='{.spec.type}')
if [[ "$SERVICE_TYPE" != "LoadBalancer" ]]; then
    log_warn "Service type is '$SERVICE_TYPE', not 'LoadBalancer'"
    echo "MyNodeOne expects LoadBalancer services for routing."
    read -p "Continue anyway? [y/N]: " continue_choice
    if [[ ! "$continue_choice" =~ ^[Yy] ]]; then
        exit 1
    fi
fi

# Wait for LoadBalancer IP
log_info "Waiting for LoadBalancer IP assignment..."
for i in {1..30}; do
    LB_IP=$(kubectl get svc -n "$APP_NAMESPACE" "$APP_SERVICE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "$LB_IP" ]]; then
        break
    fi
    
    if [[ $i -eq 30 ]]; then
        log_error "Timeout waiting for LoadBalancer IP"
        echo "Check MetalLB configuration:"
        echo "  kubectl get pods -n metallb-system"
        exit 1
    fi
    
    sleep 2
done

log_success "LoadBalancer IP: $LB_IP"
echo ""

# Register with service registry
log_info "Registering with MyNodeOne service registry..."

if [[ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]]; then
    if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "$APP_NAME" "$APP_SUBDOMAIN" "$APP_NAMESPACE" "$APP_SERVICE" "$APP_PORT" "$MAKE_PUBLIC"; then
        log_success "Service registered successfully"
    else
        log_error "Failed to register service"
        exit 1
    fi
else
    log_error "service-registry.sh not found"
    echo "Expected location: $PROJECT_ROOT/scripts/lib/service-registry.sh"
    exit 1
fi

# Update DNS
if [[ "$AUTO_DNS" == "true" ]]; then
    echo ""
    log_info "Updating DNS configuration..."
    
    if [[ -f "$PROJECT_ROOT/scripts/sync-dns.sh" ]]; then
        if bash "$PROJECT_ROOT/scripts/sync-dns.sh" 2>&1 | grep -q "DNS"; then
            log_success "Local DNS updated"
        else
            log_warn "DNS sync completed with warnings"
        fi
    else
        log_warn "sync-dns.sh not found, skipping DNS update"
    fi
    
    # Sync to all nodes
    log_info "Syncing to all cluster nodes..."
    if [[ -f "$PROJECT_ROOT/scripts/lib/sync-controller.sh" ]]; then
        bash "$PROJECT_ROOT/scripts/lib/sync-controller.sh" push &>/dev/null || true
        log_success "Configuration synced to nodes"
    fi
fi

# Get cluster domain
CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info \
    -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "mynodeone")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  Registration Complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "Your app is now integrated with MyNodeOne"
echo ""
echo "📍 Access Information:"
echo "   Local URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo "   IP Address: $LB_IP"
echo ""

if [[ "$MAKE_PUBLIC" == "true" ]]; then
    echo "🌐 Public Access:"
    echo "   Your app is marked as public"
    echo "   Configure domain routing with:"
    echo "   sudo $PROJECT_ROOT/scripts/operations/manage-app-visibility.sh"
    echo ""
else
    echo "🔒 Private Access:"
    echo "   Your app is currently private (local network only)"
    echo "   To enable public access, run:"
    echo "   sudo $PROJECT_ROOT/scripts/operations/manage-app-visibility.sh"
    echo ""
fi

echo "🔧 Management Commands:"
echo "   View all services:"
echo "   kubectl get configmap -n kube-system service-registry -o yaml"
echo ""
echo "   Update registration:"
echo "   bash $(basename "$0") --name $APP_NAME --subdomain $APP_SUBDOMAIN \\"
echo "     --namespace $APP_NAMESPACE --service $APP_SERVICE"
echo ""
echo "   Remove registration:"
echo "   # (Deleting the namespace will auto-cleanup)"
echo "   kubectl delete namespace $APP_NAMESPACE"
echo ""

log_success "Setup complete! 🎉"
echo ""
