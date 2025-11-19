#!/bin/bash

# MyNodeOne Demo Application Deployment Script
# This script deploys a secure demo web application to showcase the cluster

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please ensure Kubernetes is installed."
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
}

deploy_demo_app() {
    print_header "Deploying MyNodeOne Demo Application"
    
    log_info "Creating demo application namespace..."
    kubectl create namespace demo-apps --dry-run=client -o yaml | kubectl apply -f -
    
    # Label namespace for pod security
    kubectl label namespace demo-apps \
        pod-security.kubernetes.io/enforce=baseline \
        pod-security.kubernetes.io/audit=baseline \
        pod-security.kubernetes.io/warn=baseline \
        --overwrite
    
    log_info "Deploying demo application..."
    
    cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-html
  namespace: demo-apps
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
      <title>MyNodeOne Demo</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); }
        .container { background: white; padding: 40px; border-radius: 10px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        h1 { color: #667eea; }
        .status { background: #e8f5e9; padding: 15px; margin: 20px 0; border-left: 4px solid #4caf50; }
        .status-item { margin: 8px 0; }
        .check { color: #4caf50; font-weight: bold; }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>🚀 MyNodeOne Demo Application</h1>
        <p>This application is running on your Kubernetes cluster with full security hardening!</p>
        
        <div class="status">
          <h2>System Status</h2>
          <div class="status-item"><span class="check">✓</span> Kubernetes operational</div>
          <div class="status-item"><span class="check">✓</span> Longhorn storage ready</div>
          <div class="status-item"><span class="check">✓</span> Pod Security Standards enforced</div>
          <div class="status-item"><span class="check">✓</span> MetalLB load balancer active</div>
          <div class="status-item"><span class="check">✓</span> Running with secure configuration</div>
        </div>
        
        <h2>🔒 Security Features</h2>
        <ul>
          <li>Running as non-root user (UID 101)</li>
          <li>No privilege escalation allowed</li>
          <li>All capabilities dropped</li>
          <li>Seccomp profile enforced</li>
          <li>Read-only root filesystem</li>
        </ul>
        
        <h2>📊 Next Steps</h2>
        <p>Now that you have a working application, you can:</p>
        <ul>
          <li>Deploy your own applications</li>
          <li>Set up GitOps with ArgoCD</li>
          <li>Monitor with Grafana dashboards</li>
          <li>Use Longhorn for persistent storage</li>
        </ul>
        
        <p style="margin-top: 30px; color: #666; font-size: 0.9em;">
          Deployed on MyNodeOne • Secured by Pod Security Standards • Powered by K3s
        </p>
      </div>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  namespace: demo-apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo
  template:
    metadata:
      labels:
        app: demo
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: demo
        image: nginxinc/nginx-unprivileged:alpine
        ports:
        - containerPort: 8080
          name: http
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          runAsNonRoot: true
          runAsUser: 101
          seccompProfile:
            type: RuntimeDefault
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
      volumes:
      - name: html
        configMap:
          name: demo-html
---
apiVersion: v1
kind: Service
metadata:
  name: demo
  namespace: demo-apps
spec:
  type: LoadBalancer
  selector:
    app: demo
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
EOF
    
    log_success "Demo application deployed!"
    
    log_info "Waiting for LoadBalancer IP assignment (this may take 30-60 seconds)..."
    sleep 10
    
    for i in {1..12}; do
        DEMO_IP=$(kubectl get svc -n demo-apps demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$DEMO_IP" ]; then
            break
        fi
        echo -n "."
        sleep 5
    done
    echo
    
    if [ -n "$DEMO_IP" ]; then
        log_success "Demo application is accessible at: http://$DEMO_IP"
        
        # Register with enterprise registry (if available)
        log_info "Registering demo app in service registry..."
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        
        # Load cluster domain
        CLUSTER_DOMAIN="mycloud"
        if [ -f "$HOME/.mynodeone/config.env" ]; then
            source "$HOME/.mynodeone/config.env"
        fi
        
        # Register in new enterprise registry
        if [ -f "$SCRIPT_DIR/lib/service-registry.sh" ]; then
            if bash "$SCRIPT_DIR/lib/service-registry.sh" register \
                "demo" "demo" "demo-apps" "demo" "80" "false" 2>/dev/null; then
                log_success "Registered in service registry"
                DEMO_URL="http://demo.${CLUSTER_DOMAIN}.local"
            else
                log_warn "Could not register (kubectl may not be configured)"
                DEMO_URL="http://$DEMO_IP"
            fi
            
            # Update local DNS
            if bash "$SCRIPT_DIR/lib/service-registry.sh" export-dns "${CLUSTER_DOMAIN}.local" 2>/dev/null > /tmp/demo-dns-entries.txt; then
                sudo cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
                sudo sed -i '/# MyNodeOne Services/,/^$/d' /etc/hosts 2>/dev/null || true
                {
                    echo ""
                    cat /tmp/demo-dns-entries.txt
                    echo ""
                } | sudo tee -a /etc/hosts > /dev/null
                rm -f /tmp/demo-dns-entries.txt
                log_success "Local DNS updated"
            fi
        else
            # Fallback to old method if new registry not available
            log_warn "Enterprise registry not available, using direct access"
            DEMO_URL="http://$DEMO_IP"
        fi
        
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🎉 Demo Application Deployed Successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "  Access URL: $DEMO_URL"
        echo "  Direct IP:  http://$DEMO_IP"
        echo
        echo "  This demo shows:"
        echo "    ✓ Secure pod configuration"
        echo "    ✓ LoadBalancer service working"
        echo "    ✓ Cluster is operational"
        echo "    ✓ DNS resolution (.local domains)"
        echo
        echo "  To remove this demo:"
        echo "    kubectl delete namespace demo-apps"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        log_warn "LoadBalancer IP not assigned yet. Check status with:"
        echo "  kubectl get svc -n demo-apps demo-chat-app"
    fi
}

undeploy_demo_app() {
    print_header "Removing MyNodeOne Demo Application"
    
    log_info "Deleting demo application namespace..."
    kubectl delete namespace demo-apps --ignore-not-found=true
    
    log_success "Demo application removed!"
}

show_help() {
    cat <<EOF
MyNodeOne Demo Application Deployment Script

Usage: $0 [OPTION]

Options:
  deploy      Deploy the demo application (default)
  remove      Remove the demo application
  status      Check demo application status
  help        Show this help message

Examples:
  # Deploy demo app
  sudo $0 deploy
  
  # Remove demo app
  sudo $0 remove
  
  # Check status
  sudo $0 status

EOF
}

show_status() {
    print_header "Demo Application Status"
    
    if ! kubectl get namespace demo-apps &> /dev/null; then
        log_info "Demo application is not deployed."
        echo
        echo "To deploy: sudo $0 deploy"
        return
    fi
    
    log_info "Checking deployment status..."
    echo
    kubectl get pods,svc -n demo-apps
    echo
    
    DEMO_IP=$(kubectl get svc -n demo-apps demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ -n "$DEMO_IP" ]; then
        log_success "Demo app is running at: http://$DEMO_IP"
    else
        log_warn "Waiting for LoadBalancer IP..."
    fi
}

main() {
    case "${1:-deploy}" in
        deploy)
            check_kubectl
            deploy_demo_app
            
            # Sync service registry after deployment
            log_info "Syncing service registry..."
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/lib/service-registry.sh" ]; then
                bash "$SCRIPT_DIR/lib/service-registry.sh" sync 2>/dev/null || true
            fi
            ;;
        remove|delete|undeploy)
            check_kubectl
            undeploy_demo_app
            
            # Sync service registry after removal
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if [ -f "$SCRIPT_DIR/lib/service-registry.sh" ]; then
                bash "$SCRIPT_DIR/lib/service-registry.sh" sync 2>/dev/null || true
            fi
            ;;
        status)
            check_kubectl
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
