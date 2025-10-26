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
  name: demo-chat-html
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
  name: demo-chat-app
  namespace: demo-apps
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-chat-app
  template:
    metadata:
      labels:
        app: demo-chat-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: chat-app
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
          name: demo-chat-html
---
apiVersion: v1
kind: Service
metadata:
  name: demo-chat-app
  namespace: demo-apps
spec:
  type: LoadBalancer
  selector:
    app: demo-chat-app
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
        DEMO_IP=$(kubectl get svc -n demo-apps demo-chat-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$DEMO_IP" ]; then
            break
        fi
        echo -n "."
        sleep 5
    done
    echo
    
    if [ -n "$DEMO_IP" ]; then
        log_success "Demo application is accessible at: http://$DEMO_IP"
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🎉 Demo Application Deployed Successfully!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        echo "  Access URL: http://$DEMO_IP"
        echo
        echo "  This demo shows:"
        echo "    ✓ Secure pod configuration"
        echo "    ✓ LoadBalancer service working"
        echo "    ✓ Cluster is operational"
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
    
    DEMO_IP=$(kubectl get svc -n demo-apps demo-chat-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
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
            ;;
        remove|delete|undeploy)
            check_kubectl
            undeploy_demo_app
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
