#!/bin/bash

# MyNodeOne LLM Chat Application Deployment
# Deploys Open WebUI with Ollama for local LLM chat

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

check_requirements() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please run this on control plane or laptop with kubectl configured."
        exit 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

deploy_ollama() {
    log_info "Deploying Ollama (LLM backend)..."
    
    # Create namespace
    kubectl create namespace llm-chat --dry-run=client -o yaml | kubectl apply -f -
    
    # Label namespace for Pod Security
    kubectl label namespace llm-chat \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/audit=restricted \
        pod-security.kubernetes.io/warn=restricted \
        --overwrite
    
    # Deploy Ollama
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
  namespace: llm-chat
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: llm-chat
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
          name: http
        volumeMounts:
        - name: data
          mountPath: /home/ollama/.ollama
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "8Gi"
            cpu: "4000m"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0:11434"
        - name: HOME
          value: "/home/ollama"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ollama-data
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: llm-chat
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
    protocol: TCP
  type: ClusterIP
EOF
    
    log_success "Ollama deployed"
}

deploy_open_webui() {
    log_info "Deploying Open WebUI (Chat Interface)..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: llm-chat
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: llm-chat
spec:
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: open-webui
        image: ghcr.io/open-webui/open-webui:main
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: data
          mountPath: /app/backend/data
        env:
        - name: OLLAMA_BASE_URL
          value: "http://ollama:11434"
        - name: WEBUI_SECRET_KEY
          value: "$(openssl rand -base64 32)"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: open-webui-data
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: llm-chat
spec:
  selector:
    app: open-webui
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  type: LoadBalancer
EOF
    
    log_success "Open WebUI deployed"
}

wait_for_deployment() {
    log_info "Waiting for deployments to be ready..."
    
    kubectl wait --for=condition=available --timeout=300s \
        deployment/ollama -n llm-chat || true
    
    kubectl wait --for=condition=available --timeout=300s \
        deployment/open-webui -n llm-chat || true
    
    log_success "Deployments ready"
}

get_access_info() {
    log_info "Retrieving access information..."
    
    # Wait for LoadBalancer IP
    log_info "Waiting for LoadBalancer IP (this may take a minute)..."
    for i in {1..60}; do
        WEBUI_IP=$(kubectl get svc open-webui -n llm-chat -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        if [ -n "$WEBUI_IP" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -z "$WEBUI_IP" ]; then
        log_warn "LoadBalancer IP not assigned yet. Check with: kubectl get svc -n llm-chat"
        WEBUI_IP="<pending>"
    fi
}

download_model() {
    print_header "Download LLM Model"
    
    echo "Would you like to download a language model now?"
    echo
    echo "Available models (size | speed | quality):"
    echo "  1. tinyllama (637MB)     - Fast, basic responses"
    echo "  2. phi3:mini (2.3GB)     - Balanced, good for most tasks"
    echo "  3. llama3.2 (2GB)        - High quality, slower"
    echo "  4. Skip (download later via UI)"
    echo
    read -p "Choose model [1-4, default: 4]: " MODEL_CHOICE
    
    case $MODEL_CHOICE in
        1)
            MODEL_NAME="tinyllama"
            ;;
        2)
            MODEL_NAME="phi3:mini"
            ;;
        3)
            MODEL_NAME="llama3.2"
            ;;
        *)
            log_info "Skipping model download. You can download models via the web UI later."
            return
            ;;
    esac
    
    log_info "Downloading $MODEL_NAME model (this may take several minutes)..."
    
    # Get ollama pod name
    OLLAMA_POD=$(kubectl get pods -n llm-chat -l app=ollama -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$OLLAMA_POD" ]; then
        log_error "Ollama pod not found"
        return
    fi
    
    # Download model
    kubectl exec -n llm-chat $OLLAMA_POD -- ollama pull $MODEL_NAME
    
    log_success "Model $MODEL_NAME downloaded"
}

print_summary() {
    print_header "🎉 LLM Chat Application Deployed Successfully!"
    
    echo
    echo "✅ Components deployed:"
    echo "  • Ollama (LLM backend)"
    echo "  • Open WebUI (Chat interface)"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Access Your Chat Application"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    if [ "$WEBUI_IP" != "<pending>" ]; then
        echo "  URL: http://$WEBUI_IP"
        echo
        echo "  1. Open this URL in your browser (must be on Tailscale)"
        echo "  2. Create your account (first signup becomes admin)"
        echo "  3. Start chatting with your local LLM!"
    else
        echo "  Get IP address: kubectl get svc -n llm-chat open-webui"
        echo "  Then access: http://<EXTERNAL-IP>"
    fi
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📚 Using the Chat App"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "First Time Setup:"
    echo "  1. Navigate to http://$WEBUI_IP in your browser"
    echo "  2. Click 'Sign Up' and create an account"
    echo "  3. First user automatically becomes admin"
    echo
    echo "Download Models (if you skipped earlier):"
    echo "  1. Click your profile icon → Admin Panel"
    echo "  2. Go to 'Settings' → 'Models'"
    echo "  3. Enter model name (e.g., 'phi3:mini') and click download"
    echo "  4. Wait for download to complete"
    echo
    echo "Start Chatting:"
    echo "  1. Select a model from the dropdown"
    echo "  2. Type your question and press Enter"
    echo "  3. Your data stays 100% local!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔧 Management Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Check status:"
    echo "  kubectl get pods -n llm-chat"
    echo
    echo "Download more models:"
    echo "  OLLAMA_POD=\$(kubectl get pods -n llm-chat -l app=ollama -o jsonpath='{.items[0].metadata.name}')"
    echo "  kubectl exec -n llm-chat \$OLLAMA_POD -- ollama pull llama3.2"
    echo
    echo "List downloaded models:"
    echo "  kubectl exec -n llm-chat \$OLLAMA_POD -- ollama list"
    echo
    echo "View logs:"
    echo "  kubectl logs -n llm-chat -l app=open-webui"
    echo "  kubectl logs -n llm-chat -l app=ollama"
    echo
    echo "Remove application:"
    echo "  kubectl delete namespace llm-chat"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  💡 Tips"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "• Smaller models (tinyllama, phi3:mini) work on any hardware"
    echo "• Larger models (llama3.2, mistral) need 8GB+ RAM"
    echo "• Models are cached - download once, use forever"
    echo "• All data stays on your cluster - no external API calls"
    echo "• Open WebUI supports plugins, document upload, and more!"
    echo
}

remove_chat_app() {
    log_warn "Removing LLM Chat application..."
    
    kubectl delete namespace llm-chat
    
    log_success "LLM Chat application removed"
}

main() {
    print_header "MyNodeOne LLM Chat Application Setup"
    
    # Check for remove flag
    if [ "$1" = "remove" ] || [ "$1" = "delete" ]; then
        remove_chat_app
        exit 0
    fi
    
    check_requirements
    deploy_ollama
    deploy_open_webui
    wait_for_deployment
    get_access_info
    download_model
    print_summary
}

main "$@"
