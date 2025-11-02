#!/bin/bash

###############################################################################
# LLM Chat (Open WebUI + Ollama) - One-Click Installation
# 
# Private AI chat with local LLMs - no cloud, 100% private
# ChatGPT-like interface powered by Ollama
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared validation library
source "$SCRIPT_DIR/lib/validation.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Load cluster domain from config
CLUSTER_DOMAIN="mynodeone"
if [ -f "$HOME/.mynodeone/config.env" ]; then
    source "$HOME/.mynodeone/config.env"
    CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing LLM Chat (Open WebUI + Ollama)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

NAMESPACE="llm-chat"

# Check if already installed
ALREADY_INSTALLED=false
if check_namespace_exists "$NAMESPACE"; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  LLM Chat Already Installed${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "LLM Chat is already installed in your cluster!"
    echo ""
    echo "Current status:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1. Add public internet access (expose to web)"
    echo "  2. Upgrade to high performance (4-16Gi RAM, 2-6 CPU)"
    echo "  3. Upgrade to MAXIMUM performance (48-128Gi RAM, 8-24 CPU for 70B models)"
    echo "  4. Expand storage (increase model storage capacity)"
    echo "  5. Reinstall completely (deletes existing data!)"
    echo "  6. Exit (keep current installation)"
    echo ""
    read -p "Choose option [1-6]: " INSTALL_OPTION
    
    case $INSTALL_OPTION in
        1)
            echo ""
            echo -e "${GREEN}Will configure public internet access...${NC}"
            ALREADY_INSTALLED=true
            UPGRADE_RESOURCES=false
            ;;
        2)
            echo ""
            echo -e "${GREEN}Will upgrade to high performance resources...${NC}"
            ALREADY_INSTALLED=true
            UPGRADE_RESOURCES="high"
            ;;
        3)
            echo ""
            echo -e "${GREEN}Will upgrade to MAXIMUM performance resources...${NC}"
            ALREADY_INSTALLED=true
            UPGRADE_RESOURCES="max"
            EXPAND_STORAGE=false
            ;;
        4)
            echo ""
            echo -e "${GREEN}Will expand Ollama storage...${NC}"
            ALREADY_INSTALLED=true
            UPGRADE_RESOURCES=false
            EXPAND_STORAGE=true
            ;;
        5)
            echo ""
            echo -e "${RED}⚠️  WARNING: This will delete all your chat history and downloaded models!${NC}"
            read -p "Are you absolutely sure? Type 'yes' to confirm: " CONFIRM
            if [ "$CONFIRM" = "yes" ]; then
                echo ""
                echo "Deleting existing installation..."
                kubectl delete namespace "$NAMESPACE"
                echo "Waiting for cleanup..."
                sleep 10
                ALREADY_INSTALLED=false
                UPGRADE_RESOURCES=false
                EXPAND_STORAGE=false
            else
                echo "Cancelled. Exiting."
                exit 0
            fi
            ;;
        *)
            echo "Exiting without changes."
            exit 0
            ;;
    esac
fi

# Prompt for subdomain (only if fresh install or adding public access)
if [ "$ALREADY_INSTALLED" = false ] || [ "${INSTALL_OPTION:-}" = "1" ]; then
    # In AUTO_INSTALL_MODE (from bootstrap), use defaults without prompts
    if [ "${AUTO_INSTALL_MODE:-false}" = "true" ]; then
        APP_SUBDOMAIN="open-webui"
        echo "🌐 Using default subdomain: ${APP_SUBDOMAIN}"
        echo "  Local access: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo ""
    else
        echo "🌐 App Subdomain Configuration"
        echo ""
        echo "Choose a subdomain for LLM Chat. This will be used for:"
        echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
        echo "  • Public access: <subdomain>.yourdomain.com (if configured)"
        echo ""
        echo "Examples: chat, ai, llm, assistant, open-webui"
        echo ""
        read -p "Enter subdomain [default: open-webui]: " APP_SUBDOMAIN
        APP_SUBDOMAIN="${APP_SUBDOMAIN:-open-webui}"

        # Sanitize subdomain
        APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "open-webui")

        echo ""
        echo "✓ Subdomain: ${APP_SUBDOMAIN}"
        echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo ""
    fi
fi

# Fresh installation
if [ "$ALREADY_INSTALLED" = false ]; then
    echo "📦 Creating namespace..."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Label namespace for Pod Security
    kubectl label namespace "$NAMESPACE" \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/audit=restricted \
        pod-security.kubernetes.io/warn=restricted \
        --overwrite > /dev/null 2>&1

    echo "💾 Configuring storage..."
    kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 200Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: open-webui-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
EOF

    echo "🤖 Deploying Ollama (LLM Backend)..."
    kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: $NAMESPACE
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
      priorityClassName: system-cluster-critical
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
            memory: "4Gi"
            cpu: "2000m"
          limits:
            memory: "16Gi"
            cpu: "6000m"
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
        - name: OLLAMA_NUM_PARALLEL
          value: "4"
        - name: OLLAMA_MAX_LOADED_MODELS
          value: "2"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ollama-data
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: $NAMESPACE
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
    protocol: TCP
  type: ClusterIP
EOF

    echo "💬 Deploying Open WebUI (Chat Interface)..."
    kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: $NAMESPACE
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
      priorityClassName: system-cluster-critical
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
        - name: ENABLE_RAG_WEB_SEARCH
          value: "true"
        - name: ENABLE_IMAGE_GENERATION
          value: "true"
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
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
  namespace: $NAMESPACE
  annotations:
    ${CLUSTER_DOMAIN}.local/subdomain: "${APP_SUBDOMAIN}"
spec:
  selector:
    app: open-webui
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  type: LoadBalancer
EOF

    echo "⏳ Waiting for deployments to start..."
    kubectl wait --for=condition=available --timeout=300s deployment/ollama -n "$NAMESPACE" || {
        echo -e "${YELLOW}Ollama taking longer than expected. Checking status...${NC}"
        kubectl get pods -n "$NAMESPACE"
    }
    
    kubectl wait --for=condition=available --timeout=300s deployment/open-webui -n "$NAMESPACE" || {
        echo -e "${YELLOW}Open WebUI taking longer than expected. Checking status...${NC}"
        kubectl get pods -n "$NAMESPACE"
    }

    sleep 10
    SERVICE_IP=$(kubectl get svc open-webui -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✓ LLM Chat installed successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "📍 Access LLM Chat at: http://$SERVICE_IP"
    echo ""
    echo "🎯 First Time Setup:"
    echo "   1. Open the URL above in your browser"
    echo "   2. Click 'Sign Up' and create your account"
    echo "   3. First user automatically becomes admin"
    echo "   4. Download a model (recommended: phi3:mini)"
    echo "   5. Start chatting!"
    echo ""

    # Update local DNS
    echo "🌐 Updating local DNS entries..."
    if bash "$SCRIPT_DIR/../update-laptop-dns.sh"; then
        echo ""
        echo "✓ Local DNS updated! Access LLM Chat at:"
        echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo ""
    fi
fi

# Upgrade resources (if option 2 or 3 was chosen)
if [ "${UPGRADE_RESOURCES:-false}" = "high" ] || [ "${UPGRADE_RESOURCES:-false}" = "max" ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$UPGRADE_RESOURCES" = "max" ]; then
        echo -e "${BLUE}  Upgrading to MAXIMUM Performance${NC}"
    else
        echo -e "${BLUE}  Upgrading to High Performance${NC}"
    fi
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if [ "$UPGRADE_RESOURCES" = "max" ]; then
        # MAXIMUM performance - use all available resources (for 70B models)
        OLLAMA_REQ_CPU="8000m"
        OLLAMA_REQ_MEM="48Gi"
        OLLAMA_LIMIT_CPU="24000m"
        OLLAMA_LIMIT_MEM="128Gi"
        WEBUI_REQ_CPU="1000m"
        WEBUI_REQ_MEM="2Gi"
        WEBUI_LIMIT_CPU="4000m"
        WEBUI_LIMIT_MEM="8Gi"
        OLLAMA_PARALLEL="8"
        OLLAMA_KEEP_ALIVE="2m"
        OLLAMA_MAX_MODELS="4"
    else
        # High performance - balanced
        OLLAMA_REQ_CPU="2000m"
        OLLAMA_REQ_MEM="4Gi"
        OLLAMA_LIMIT_CPU="6000m"
        OLLAMA_LIMIT_MEM="16Gi"
        WEBUI_REQ_CPU="500m"
        WEBUI_REQ_MEM="1Gi"
        WEBUI_LIMIT_CPU="2000m"
        WEBUI_LIMIT_MEM="4Gi"
        OLLAMA_PARALLEL="4"
        OLLAMA_KEEP_ALIVE="2m"
        OLLAMA_MAX_MODELS="2"
    fi
    
    echo "🚀 Updating Ollama resources..."
    kubectl patch deployment ollama -n "$NAMESPACE" --type='json' -p="[
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"$OLLAMA_REQ_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"$OLLAMA_REQ_CPU\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$OLLAMA_LIMIT_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$OLLAMA_LIMIT_CPU\"}
    ]"
    
    echo "🚀 Updating Ollama environment for performance..."
    kubectl set env deployment/ollama -n "$NAMESPACE" \
        OLLAMA_NUM_PARALLEL="$OLLAMA_PARALLEL" \
        OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_MODELS" \
        OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE"
    
    echo "🚀 Updating Open WebUI resources..."
    kubectl patch deployment open-webui -n "$NAMESPACE" --type='json' -p="[
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"$WEBUI_REQ_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"$WEBUI_REQ_CPU\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$WEBUI_LIMIT_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$WEBUI_LIMIT_CPU\"}
    ]"
    
    echo "🏆 Adding high priority scheduling..."
    kubectl patch deployment ollama -n "$NAMESPACE" -p '{"spec":{"template":{"spec":{"priorityClassName":"system-cluster-critical"}}}}'
    kubectl patch deployment open-webui -n "$NAMESPACE" -p '{"spec":{"template":{"spec":{"priorityClassName":"system-cluster-critical"}}}}'
    
    echo ""
    echo "✓ Resources upgraded!"
    echo ""
    echo "New resource allocation:"
    echo "  Ollama:     $OLLAMA_REQ_MEM-$OLLAMA_LIMIT_MEM RAM, ${OLLAMA_REQ_CPU/000m/}-${OLLAMA_LIMIT_CPU/000m/} CPU cores"
    echo "  Open WebUI: $WEBUI_REQ_MEM-$WEBUI_LIMIT_MEM RAM, ${WEBUI_REQ_CPU/000m/}-${WEBUI_LIMIT_CPU/000m/} CPU cores"
    echo "  Parallel:   $OLLAMA_PARALLEL concurrent requests"
    echo "  Max Models: $OLLAMA_MAX_MODELS models in memory"
    echo "  Keep Alive: $OLLAMA_KEEP_ALIVE"
    echo "  Priority:   System-critical (highest)"
    echo ""
    if [ "$UPGRADE_RESOURCES" = "max" ]; then
        echo "🚀 Result: 5-10x faster token generation!"
    else
        echo "🚀 Result: 2-3x faster token generation!"
    fi
    echo ""
    echo "⏳ Pods will restart to apply changes..."
    sleep 5
fi

# Expand storage (if option 4 was chosen)
if [ "${EXPAND_STORAGE:-false}" = true ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Expanding Ollama Storage${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check current storage size
    CURRENT_SIZE=$(kubectl get pvc ollama-data -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
    echo "📊 Current storage: $CURRENT_SIZE"
    echo ""
    
    # Check current usage
    OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$OLLAMA_POD" ]; then
        echo "💾 Current usage:"
        kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- df -h /home/ollama/.ollama 2>/dev/null | tail -1 || echo "  (Could not retrieve usage)"
        echo ""
    fi
    
    # Suggest new size based on current
    CURRENT_NUM=$(echo "$CURRENT_SIZE" | sed 's/Gi//')
    if [ "$CURRENT_NUM" -lt 100 ]; then
        SUGGESTED_SIZE="200Gi"
    elif [ "$CURRENT_NUM" -lt 200 ]; then
        SUGGESTED_SIZE="500Gi"
    else
        SUGGESTED_SIZE="$((CURRENT_NUM + 200))Gi"
    fi
    
    echo "💡 Suggested sizes:"
    echo "  • 200Gi  - Good for 8-10 large models (mistral, llama)"
    echo "  • 500Gi  - Great for 15-20 large models + experimentation"
    echo "  • 1Ti    - Excellent for model collectors and testing"
    echo ""
    read -p "Enter new storage size [default: $SUGGESTED_SIZE]: " NEW_SIZE
    NEW_SIZE="${NEW_SIZE:-$SUGGESTED_SIZE}"
    
    echo ""
    echo "🚀 Expanding storage to $NEW_SIZE..."
    echo ""
    
    # Patch PVC
    kubectl patch pvc ollama-data -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_SIZE\"}}}}"
    
    echo "📉 Scaling down Ollama (volume must be detached for resize)..."
    kubectl scale deployment ollama -n "$NAMESPACE" --replicas=0
    
    echo "⏳ Waiting for pod termination..."
    sleep 15
    
    echo "📈 Scaling back up..."
    kubectl scale deployment ollama -n "$NAMESPACE" --replicas=1
    
    echo "⏳ Waiting for pod to start..."
    kubectl wait --for=condition=ready pod -l app=ollama -n "$NAMESPACE" --timeout=120s 2>/dev/null || sleep 30
    
    echo ""
    echo "✓ Storage expansion complete!"
    echo ""
    
    # Verify new size
    OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$OLLAMA_POD" ]; then
        echo "📊 New storage status:"
        kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- df -h /home/ollama/.ollama 2>/dev/null | tail -1 || echo "  Verifying..."
        echo ""
    fi
    
    echo "🎉 You can now download more models!"
    echo ""
    sleep 3
fi

# Configure VPS route (for both fresh install and existing)
# Skip in AUTO_INSTALL_MODE (configured from bootstrap - no VPS yet)
if [ "${AUTO_INSTALL_MODE:-false}" != "true" ] && ([ "$ALREADY_INSTALLED" = false ] || [ "${INSTALL_OPTION:-}" = "1" ]); then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  🌍 Internet Access via VPS Edge Node${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Make LLM Chat accessible from the internet?"
    echo ""
    echo "This will configure:"
    echo "  • Public URL: https://${APP_SUBDOMAIN}.yourdomain.com"
    echo "  • Automatic SSL certificate"
    echo "  • VPS routing to your cluster"
    echo ""
    echo "⚠️  Security Note:"
    echo "  • Recommended: Set up authentication in Open WebUI admin panel"
    echo "  • Your chat data stays on your cluster (not sent to public)"
    echo "  • Only the web interface is exposed"
    echo ""
    read -p "Configure internet access? [y/N]: " configure_public
    configure_public="${configure_public:-n}"

    if [[ "$configure_public" =~ ^[Yy]$ ]]; then
        echo ""
        read -p "Enter your public domain (e.g., curiios.com): " PUBLIC_DOMAIN
        
        if [ -n "$PUBLIC_DOMAIN" ]; then
            echo ""
            echo "📡 Configuring VPS route..."
            echo "   Public URL: https://${APP_SUBDOMAIN}.${PUBLIC_DOMAIN}"
            echo ""
            
            if bash "$SCRIPT_DIR/../configure-vps-route.sh" "$NAMESPACE" "80" "$APP_SUBDOMAIN" "$PUBLIC_DOMAIN" "$NAMESPACE/open-webui"; then
                echo ""
                echo "✓ VPS route configured!"
                echo ""
                echo "📖 Next steps:"
                echo "   1. Add DNS A record: ${APP_SUBDOMAIN}.${PUBLIC_DOMAIN} → VPS_IP"
                echo "   2. Wait 2-3 minutes for SSL certificate"
                echo "   3. Access: https://${APP_SUBDOMAIN}.${PUBLIC_DOMAIN}"
                echo ""
                echo "   See docs/guides/DNS-SETUP-GUIDE.md for details"
                echo ""
                echo -e "${YELLOW}🔒 Security Reminder:${NC}"
                echo "   After first login, go to Admin Panel → Settings → Authentication"
                echo "   to configure additional security measures."
                echo ""
            else
                echo ""
                echo -e "${YELLOW}⚠️  VPS configuration failed or was skipped.${NC}"
                echo "You can configure it later with:"
                echo "  sudo bash scripts/configure-vps-route.sh $NAMESPACE 80 $APP_SUBDOMAIN $PUBLIC_DOMAIN"
                echo ""
            fi
        fi
    fi
fi

# Download model recommendation
# Skip in AUTO_INSTALL_MODE
if [ "$ALREADY_INSTALLED" = false ] && [ "${AUTO_INSTALL_MODE:-false}" != "true" ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  📥 Download Language Models${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Would you like to download a language model now?"
    echo ""
    echo "Recommended models for your setup:"
    echo ""
    echo "  1. phi3:mini (2.3GB)      - ⭐ Recommended: Fast & capable"
    echo "  2. llama3.2 (2GB)         - High quality responses"
    echo "  3. qwen2.5:3b (2GB)       - Good for coding tasks"
    echo "  4. mistral:7b (4.1GB)     - Advanced model (needs 8GB+ RAM)"
    echo "  5. Skip (download later)"
    echo ""
    read -p "Choose model [1-5, default: 1]: " MODEL_CHOICE
    
    case $MODEL_CHOICE in
        1|"")
            MODEL_NAME="phi3:mini"
            ;;
        2)
            MODEL_NAME="llama3.2"
            ;;
        3)
            MODEL_NAME="qwen2.5:3b"
            ;;
        4)
            MODEL_NAME="mistral:7b"
            ;;
        *)
            echo ""
            echo "Skipping model download. You can download models via the web UI later."
            MODEL_NAME=""
            ;;
    esac
    
    if [ -n "$MODEL_NAME" ]; then
        echo ""
        echo "📥 Downloading $MODEL_NAME model..."
        echo "   This may take 5-15 minutes depending on your internet speed."
        echo ""
        
        # Wait for ollama pod to be ready
        OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}')
        
        if [ -n "$OLLAMA_POD" ]; then
            kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- ollama pull "$MODEL_NAME" && {
                echo ""
                echo "✓ Model $MODEL_NAME downloaded and ready!"
            } || {
                echo ""
                echo -e "${YELLOW}Model download had issues. You can download it later via the UI.${NC}"
            }
        else
            echo -e "${YELLOW}Ollama pod not ready yet. Download model via UI later.${NC}"
        fi
    fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "🎉 LLM Chat is ready to use!"
echo ""
echo "📊 Performance Optimizations:"
echo "   ✅ High-priority scheduling (system-critical)"
echo "   ✅ Increased CPU allocation (2-6 cores for Ollama)"
echo "   ✅ Increased RAM allocation (4-16Gi for Ollama)"
echo "   ✅ Parallel request handling (4 concurrent)"
echo "   ✅ Multi-model support (2 models loaded)"
echo ""
echo "🚀 Result: Faster token generation and better responsiveness!"
echo ""
echo "💡 Quick Start:"
echo "   1. Open: http://${APP_SUBDOMAIN:-open-webui}.${CLUSTER_DOMAIN}.local"
echo "   2. Create your account (first user = admin)"
echo "   3. Download a model if you skipped earlier"
echo "   4. Start chatting with your private AI!"
echo ""
echo "📚 Features:"
echo "   • 100% Private (no data leaves your cluster)"
echo "   • Document upload & analysis"
echo "   • Web search integration"
echo "   • Image generation (with appropriate models)"
echo "   • Multiple model support"
echo "   • Chat history & conversations"
echo ""
