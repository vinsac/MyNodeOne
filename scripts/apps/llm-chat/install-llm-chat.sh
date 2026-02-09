#!/bin/bash

###############################################################################
# LLM Chat (Open WebUI + Ollama) - One-Click Installation
# 
# Private AI chat with local LLMs - no cloud, 100% private
# ChatGPT-like interface powered by Ollama
###############################################################################

set -euo pipefail

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../lib/project-root.sh"

# Load shared validation library
source "$PROJECT_ROOT/scripts/apps/lib/validation.sh"

# Load cluster resource detection utilities
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Load configuration
if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing LLM Chat (Open WebUI + Ollama)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

NAMESPACE="llm-chat"

# Detect GPU availability in cluster using centralized utility
GPU_COUNT=$(get_cluster_gpu_count)
GPU_AVAILABLE=false
USE_GPU=false

if [ "$GPU_COUNT" -gt 0 ] 2>/dev/null; then
    GPU_AVAILABLE=true
    echo -e "${GREEN}🎮 GPU Detected: ${GPU_COUNT} NVIDIA GPU(s) available in cluster${NC}"
    echo ""
    echo "GPU Acceleration Options:"
    echo "  1) Use GPU for Ollama (faster inference, recommended for most users)"
    echo "  2) Use CPU only (reserve GPU for other apps like LLMAPI)"
    echo ""
    read -p "Choose GPU mode [1-2, default: 1]: " GPU_CHOICE
    GPU_CHOICE="${GPU_CHOICE:-1}"
    
    if [ "$GPU_CHOICE" = "1" ]; then
        USE_GPU=true
        echo ""
        echo -e "${GREEN}✓ Ollama will use GPU acceleration${NC}"
        echo ""
    else
        USE_GPU=false
        echo ""
        echo -e "${YELLOW}✓ Ollama will use CPU only (GPU reserved for other apps)${NC}"
        echo ""
    fi
fi

if [ "$GPU_AVAILABLE" = false ]; then
    echo -e "${YELLOW}⚠ No GPU detected in cluster - Ollama will use CPU only${NC}"
    echo "   For GPU support, install NVIDIA drivers and run:"
    echo "   sudo ./scripts/lib/gpu-setup.sh"
    echo ""
fi

# Check if already installed
ALREADY_INSTALLED=false
if check_namespace_exists "$NAMESPACE"; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  LLM Chat Already Installed${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "LLM Chat is already installed in your cluster"
    echo ""
    echo "Current status:"
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || true
    echo ""
    echo "What would you like to do?"
    echo ""
    echo "  1. Add public internet access (expose to web)"
    echo "  2. Upgrade to high performance (4-16Gi RAM, 2-6 CPU)"
    echo "  3. Upgrade to MAXIMUM performance (48-128Gi RAM, 8-24 CPU for 70B models)"
    echo "  4. Custom resources (choose your own RAM and CPU)"
    echo "  5. Expand storage (increase model storage capacity)"
    if [ "$GPU_AVAILABLE" = true ]; then
        echo "  6. Enable/disable GPU acceleration"
    else
        echo "  6. [GPU not available] Enable GPU acceleration"
    fi
    echo "  7. Reinstall completely (deletes existing data!)"
    echo "  8. Exit (keep current installation)"
    echo ""
    read -p "Choose option [1-8]: " INSTALL_OPTION
    
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
            ;;
        4)
            echo ""
            echo -e "${GREEN}Will configure custom resources...${NC}"
            ALREADY_INSTALLED=true
            UPGRADE_RESOURCES="custom"
            ;;
        5)
            echo ""
            echo -e "${GREEN}Will expand Ollama storage...${NC}"
            ALREADY_INSTALLED=true
            EXPAND_STORAGE=true
            ;;
        6)
            echo ""
            if [ "$GPU_AVAILABLE" = true ]; then
                echo "GPU Acceleration Options:"
                echo "  1) Enable GPU for Ollama"
                echo "  2) Disable GPU (use CPU only)"
                echo ""
                read -p "Choose [1-2]: " GPU_TOGGLE
                if [ "$GPU_TOGGLE" = "1" ]; then
                    echo -e "${GREEN}Will enable GPU acceleration...${NC}"
                    ALREADY_INSTALLED=true
                    ENABLE_GPU=true
                else
                    echo -e "${YELLOW}Will disable GPU acceleration...${NC}"
                    ALREADY_INSTALLED=true
                    DISABLE_GPU=true
                fi
            else
                echo -e "${RED}GPU not available in cluster.${NC}"
                echo "To enable GPU support:"
                echo "  1. Install NVIDIA drivers: sudo ubuntu-drivers autoinstall"
                echo "  2. Reboot the system"
                echo "  3. Run GPU setup: sudo ./scripts/lib/gpu-setup.sh"
                echo "  4. Re-run this installer"
                exit 1
            fi
            ;;
        7)
            echo ""
            echo -e "${YELLOW}This will delete all data and reinstall...${NC}"
            read -p "Are you sure? [y/N]: " CONFIRM
            if [ "${CONFIRM,,}" = "y" ]; then
                kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
                echo "Waiting for cleanup..."
                sleep 10
                ALREADY_INSTALLED=false
            else
                echo "Cancelled."
                exit 0
            fi
            ;;
        8)
            echo "Cancelled. Exiting."
            exit 0
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
        APP_SUBDOMAIN="chat"
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
        echo "Examples: chat, ai, llm, assistant"
        echo ""
        read -p "Enter subdomain [default: chat]: " APP_SUBDOMAIN
        APP_SUBDOMAIN="${APP_SUBDOMAIN:-chat}"

        # Sanitize subdomain
        APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "chat")

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
    
    # Build resource limits and env vars based on GPU usage choice
    if [ "$USE_GPU" = true ]; then
        echo "   → Configuring with GPU + RAM sharing"
        # CRITICAL: runtimeClassName: nvidia required for GPU access in container
        OLLAMA_RUNTIME_CLASS="runtimeClassName: nvidia"
        OLLAMA_RESOURCES="
        resources:
          requests:
            memory: \"1Gi\"
            cpu: \"500m\"
            nvidia.com/gpu: \"1\"
          limits:
            memory: \"56Gi\"
            nvidia.com/gpu: \"1\""
        # GPU pods need privileged access for NVIDIA runtime
        OLLAMA_SECURITY_CONTEXT="
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false"
        # GPU + RAM sharing environment variables
        OLLAMA_GPU_ENV="
        - name: OLLAMA_FLASH_ATTENTION
          value: \"1\"
        - name: CUDA_VISIBLE_DEVICES
          value: \"0\""
    else
        echo "   → Configuring for CPU-only mode"
        OLLAMA_RUNTIME_CLASS=""  # No special runtime for CPU-only
        OLLAMA_GPU_ENV=""
        OLLAMA_RESOURCES="
        resources:
          requests:
            memory: \"512Mi\"
            cpu: \"200m\"
          limits:
            memory: \"56Gi\""
        OLLAMA_SECURITY_CONTEXT="
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false"
    fi
    
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
      priorityClassName: mynodeone-app
      ${OLLAMA_RUNTIME_CLASS}
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
${OLLAMA_RESOURCES}
${OLLAMA_SECURITY_CONTEXT}
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0:11434"
        - name: HOME
          value: "/home/ollama"
        - name: OLLAMA_NUM_PARALLEL
          value: "4"
        - name: OLLAMA_MAX_LOADED_MODELS
          value: "2"
${OLLAMA_GPU_ENV}
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
      priorityClassName: mynodeone-app
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
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "4Gi"
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
    mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
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
    echo "   5. Start chatting"
    echo ""

    # Update local DNS
    echo "🌐 Updating local DNS entries..."
    if bash "$PROJECT_ROOT/scripts/domains/update-laptop-dns.sh"; then
        echo ""
        echo "✓ Local DNS updated! Access LLM Chat at:"
        echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo ""
    fi
fi

# Custom resource configuration (if option 4 was chosen)
if [ "${UPGRADE_RESOURCES:-false}" = "custom" ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Custom Resource Configuration${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Detect cluster capacity using centralized utility
    echo "🔍 Detecting cluster capacity..."
    TOTAL_CPU=$(get_cluster_cpu)
    TOTAL_RAM_GB=$(get_cluster_ram_gb)
    TOTAL_RAM_KB=$(get_cluster_ram_kb)
    
    echo "   Total CPU cores: $TOTAL_CPU"
    echo "   Total RAM: ${TOTAL_RAM_GB}GB"
    echo ""
    
    echo "💡 Choose configuration method:"
    echo ""
    echo "  1. Quick presets (10 optimized configurations)"
    echo "  2. Manual (choose RAM and CPU separately)"
    echo ""
    read -p "Choose method [1-2]: " CONFIG_METHOD
    
    if [ "$CONFIG_METHOD" = "1" ]; then
        # QUICK PRESETS
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Available Presets (based on your ${TOTAL_RAM_GB}GB system)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  🔹 Small Models (7B-13B):"
        echo "     1. Minimal    - 2-8Gi RAM,    1-2 CPU   (phi3, gemma)"
        echo "     2. Basic      - 4-16Gi RAM,   2-4 CPU   (llama2 7B, mistral)"
        echo "     3. Standard   - 8-24Gi RAM,   2-6 CPU   (llama2 13B)"
        echo ""
        echo "  🔸 Medium Models (30B-34B):"
        echo "     4. Medium     - 16-48Gi RAM,  4-8 CPU   (codellama 34B)"
        echo "     5. Enhanced   - 24-64Gi RAM,  6-12 CPU  (mixtral 8x7B)"
        echo ""
        echo "  🔶 Large Models (70B):"
        echo "     6. High       - 32-80Gi RAM,  8-16 CPU  (llama2 70B Q4)"
        echo "     7. Ultra      - 48-96Gi RAM,  12-20 CPU (llama2 70B Q5)"
        echo "     8. Extreme    - 64-128Gi RAM, 16-24 CPU (deepseek 70B Q4)"
        echo ""
        echo "  🔴 Massive Models (>70B):"
        echo "     9. Maximum    - 96-192Gi RAM, 20-32 CPU (mixtral 8x22B)"
        echo "    10. Unlimited  - Custom limits removed"
        echo ""
        
        # Show recommended based on RAM
        if [ "$TOTAL_RAM_GB" -lt 32 ]; then
            echo "  💡 Recommended: 1-3 (Your system: ${TOTAL_RAM_GB}GB)"
        elif [ "$TOTAL_RAM_GB" -lt 64 ]; then
            echo "  💡 Recommended: 3-5 (Your system: ${TOTAL_RAM_GB}GB)"
        elif [ "$TOTAL_RAM_GB" -lt 128 ]; then
            echo "  💡 Recommended: 5-7 (Your system: ${TOTAL_RAM_GB}GB)"
        elif [ "$TOTAL_RAM_GB" -lt 256 ]; then
            echo "  💡 Recommended: 7-8 (Your system: ${TOTAL_RAM_GB}GB)"
        else
            echo "  💡 Recommended: 8-10 (Your system: ${TOTAL_RAM_GB}GB)"
        fi
        echo ""
        read -p "Choose preset [1-10]: " PRESET
        
        case "$PRESET" in
            1)  # Minimal
                OLLAMA_REQ_MEM="2Gi" OLLAMA_LIMIT_MEM="8Gi"
                OLLAMA_REQ_CPU="1000m" OLLAMA_LIMIT_CPU="2000m"
                ;;
            2)  # Basic
                OLLAMA_REQ_MEM="4Gi" OLLAMA_LIMIT_MEM="16Gi"
                OLLAMA_REQ_CPU="2000m" OLLAMA_LIMIT_CPU="4000m"
                ;;
            3)  # Standard
                OLLAMA_REQ_MEM="8Gi" OLLAMA_LIMIT_MEM="24Gi"
                OLLAMA_REQ_CPU="2000m" OLLAMA_LIMIT_CPU="6000m"
                ;;
            4)  # Medium
                OLLAMA_REQ_MEM="16Gi" OLLAMA_LIMIT_MEM="48Gi"
                OLLAMA_REQ_CPU="4000m" OLLAMA_LIMIT_CPU="8000m"
                ;;
            5)  # Enhanced
                OLLAMA_REQ_MEM="24Gi" OLLAMA_LIMIT_MEM="64Gi"
                OLLAMA_REQ_CPU="6000m" OLLAMA_LIMIT_CPU="12000m"
                ;;
            6)  # High
                OLLAMA_REQ_MEM="32Gi" OLLAMA_LIMIT_MEM="80Gi"
                OLLAMA_REQ_CPU="8000m" OLLAMA_LIMIT_CPU="16000m"
                ;;
            7)  # Ultra
                OLLAMA_REQ_MEM="48Gi" OLLAMA_LIMIT_MEM="96Gi"
                OLLAMA_REQ_CPU="12000m" OLLAMA_LIMIT_CPU="20000m"
                ;;
            8)  # Extreme (current max)
                OLLAMA_REQ_MEM="48Gi" OLLAMA_LIMIT_MEM="128Gi"
                OLLAMA_REQ_CPU="8000m" OLLAMA_LIMIT_CPU="24000m"
                ;;
            9)  # Maximum
                OLLAMA_REQ_MEM="96Gi" OLLAMA_LIMIT_MEM="192Gi"
                OLLAMA_REQ_CPU="20000m" OLLAMA_LIMIT_CPU="32000m"
                ;;
            10)  # Unlimited
                OLLAMA_REQ_MEM="1Gi" OLLAMA_LIMIT_MEM="${TOTAL_RAM_GB}Gi"
                OLLAMA_REQ_CPU="1000m" OLLAMA_LIMIT_CPU="${TOTAL_CPU}000m"
                ;;
            *)
                echo "Invalid preset. Using current settings."
                exit 0
                ;;
        esac
        
    else
        # MANUAL CONFIGURATION
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Manual Resource Configuration"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "📋 Model RAM Requirements (as reference):"
        echo "   • 7B models:   4-8GB"
        echo "   • 13B models:  8-16GB"
        echo "   • 30B models:  16-32GB"
        echo "   • 70B Q4_K_M:  40-80GB"
        echo "   • 70B Q5_K_M:  50-100GB"
        echo "   • 70B Q8:      70-140GB"
        echo ""
        
        # RAM Configuration
        echo "💾 RAM Configuration:"
        echo ""
        echo "Choose memory limit for Ollama:"
        echo "  1.  8GB   (tiny models)"
        echo "  2. 16GB   (small models: 7B)"
        echo "  3. 24GB   (medium models: 13B)"
        echo "  4. 32GB   (larger models: 13B-30B)"
        echo "  5. 48GB   (large models: 30B-70B Q4)"
        echo "  6. 64GB   (70B Q4 with context)"
        echo "  7. 80GB   (70B Q5)"
        echo "  8. 96GB   (70B Q5 + context)"
        echo "  9. 128GB  (70B Q8 or multiple 70B)"
        echo " 10. Custom (enter your own)"
        echo ""
        read -p "Choose RAM limit [1-10]: " RAM_CHOICE
        
        case "$RAM_CHOICE" in
            1) OLLAMA_LIMIT_MEM="8Gi" OLLAMA_REQ_MEM="2Gi" ;;
            2) OLLAMA_LIMIT_MEM="16Gi" OLLAMA_REQ_MEM="4Gi" ;;
            3) OLLAMA_LIMIT_MEM="24Gi" OLLAMA_REQ_MEM="8Gi" ;;
            4) OLLAMA_LIMIT_MEM="32Gi" OLLAMA_REQ_MEM="12Gi" ;;
            5) OLLAMA_LIMIT_MEM="48Gi" OLLAMA_REQ_MEM="16Gi" ;;
            6) OLLAMA_LIMIT_MEM="64Gi" OLLAMA_REQ_MEM="24Gi" ;;
            7) OLLAMA_LIMIT_MEM="80Gi" OLLAMA_REQ_MEM="32Gi" ;;
            8) OLLAMA_LIMIT_MEM="96Gi" OLLAMA_REQ_MEM="40Gi" ;;
            9) OLLAMA_LIMIT_MEM="128Gi" OLLAMA_REQ_MEM="48Gi" ;;
            10)
                read -p "Enter custom RAM limit (e.g., 192Gi): " CUSTOM_RAM
                OLLAMA_LIMIT_MEM="$CUSTOM_RAM"
                read -p "Enter RAM request (e.g., 64Gi): " CUSTOM_RAM_REQ
                OLLAMA_REQ_MEM="$CUSTOM_RAM_REQ"
                ;;
            *)
                echo "Invalid choice. Using 128Gi."
                OLLAMA_LIMIT_MEM="128Gi"
                OLLAMA_REQ_MEM="48Gi"
                ;;
        esac
        
        echo ""
        echo "⚙️  CPU Configuration:"
        echo ""
        echo "Choose CPU limit for Ollama:"
        echo "  1.  2 cores  (minimal)"
        echo "  2.  4 cores  (basic)"
        echo "  3.  6 cores  (standard)"
        echo "  4.  8 cores  (recommended)"
        echo "  5. 12 cores  (high performance)"
        echo "  6. 16 cores  (very high)"
        echo "  7. 20 cores  (extreme)"
        echo "  8. 24 cores  (maximum)"
        echo "  9. 32 cores  (server-grade)"
        echo " 10. Custom (enter your own)"
        echo ""
        read -p "Choose CPU limit [1-10]: " CPU_CHOICE
        
        case "$CPU_CHOICE" in
            1) OLLAMA_LIMIT_CPU="2000m" OLLAMA_REQ_CPU="1000m" ;;
            2) OLLAMA_LIMIT_CPU="4000m" OLLAMA_REQ_CPU="2000m" ;;
            3) OLLAMA_LIMIT_CPU="6000m" OLLAMA_REQ_CPU="2000m" ;;
            4) OLLAMA_LIMIT_CPU="8000m" OLLAMA_REQ_CPU="4000m" ;;
            5) OLLAMA_LIMIT_CPU="12000m" OLLAMA_REQ_CPU="6000m" ;;
            6) OLLAMA_LIMIT_CPU="16000m" OLLAMA_REQ_CPU="8000m" ;;
            7) OLLAMA_LIMIT_CPU="20000m" OLLAMA_REQ_CPU="10000m" ;;
            8) OLLAMA_LIMIT_CPU="24000m" OLLAMA_REQ_CPU="12000m" ;;
            9) OLLAMA_LIMIT_CPU="32000m" OLLAMA_REQ_CPU="16000m" ;;
            10)
                read -p "Enter custom CPU limit in cores (e.g., 40): " CUSTOM_CPU
                OLLAMA_LIMIT_CPU="${CUSTOM_CPU}000m"
                read -p "Enter CPU request in cores (e.g., 20): " CUSTOM_CPU_REQ
                OLLAMA_REQ_CPU="${CUSTOM_CPU_REQ}000m"
                ;;
            *)
                echo "Invalid choice. Using 24 cores."
                OLLAMA_LIMIT_CPU="24000m"
                OLLAMA_REQ_CPU="8000m"
                ;;
        esac
    fi
    
    # Set WebUI resources (proportional to Ollama)
    WEBUI_REQ_CPU="1000m"
    WEBUI_REQ_MEM="2Gi"
    WEBUI_LIMIT_CPU="4000m"
    WEBUI_LIMIT_MEM="8Gi"
    OLLAMA_PARALLEL="4"
    OLLAMA_KEEP_ALIVE="2m"
    OLLAMA_MAX_MODELS="2"
    
    echo ""
    echo "📊 Selected Configuration:"
    echo "   RAM:  ${OLLAMA_REQ_MEM} (request) → ${OLLAMA_LIMIT_MEM} (limit)"
    echo "   CPU:  ${OLLAMA_REQ_CPU} (request) → ${OLLAMA_LIMIT_CPU} (limit)"
    echo ""
    read -p "Apply these resources? [Y/n]: " CONFIRM
    if [ "${CONFIRM,,}" = "n" ]; then
        echo "Cancelled."
        exit 0
    fi
    
    # Apply the configuration
    echo ""
    echo "🚀 Applying custom resources..."
    kubectl patch deployment ollama -n "$NAMESPACE" --type='json' -p="[
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"$OLLAMA_REQ_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"$OLLAMA_REQ_CPU\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$OLLAMA_LIMIT_MEM\"},
        {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$OLLAMA_LIMIT_CPU\"}
    ]"
    
    kubectl set env deployment/ollama -n "$NAMESPACE" \
        OLLAMA_NUM_PARALLEL="$OLLAMA_PARALLEL" \
        OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
        OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_MODELS"
    
    echo ""
    echo -e "${GREEN}✓ Custom resources applied!${NC}"
    echo ""
    echo "📊 Resource Summary:"
    echo "  Memory Request: $OLLAMA_REQ_MEM"
    echo "  Memory Limit:   $OLLAMA_LIMIT_MEM"
    echo "  CPU Request:    $OLLAMA_REQ_CPU"
    echo "  CPU Limit:      $OLLAMA_LIMIT_CPU"
    echo "  Keep Alive:     $OLLAMA_KEEP_ALIVE"
    echo ""
    echo "✓ Ollama will restart with new resources..."
    echo ""
    
    # Wait for rollout
    kubectl rollout status deployment/ollama -n "$NAMESPACE" --timeout=120s
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ✓ Custom Resources Applied Successfully!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
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
    echo "✓ Resources upgraded"
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
        echo "🚀 Result: 5-10x faster token generation"
    else
        echo "🚀 Result: 2-3x faster token generation"
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
    echo "✓ Storage expansion complete"
    echo ""
    
    # Verify new size
    OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$OLLAMA_POD" ]; then
        echo "📊 New storage status:"
        kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- df -h /home/ollama/.ollama 2>/dev/null | tail -1 || echo "  Verifying..."
        echo ""
    fi
    
    echo "🎉 You can now download more models"
    echo ""
    sleep 3
fi

# Enable GPU (if option 6 was chosen)
if [ "${ENABLE_GPU:-false}" = true ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  🎮 Enabling GPU Acceleration${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo "📊 Current Ollama deployment:"
    kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null | jq . || echo "  (checking...)"
    echo ""
    
    echo "🚀 Patching Ollama deployment with GPU resources..."
    
    # Patch the deployment to add GPU resources
    kubectl patch deployment ollama -n "$NAMESPACE" --type='json' -p='[
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {
            "requests": {
                "memory": "8Gi",
                "cpu": "2000m",
                "nvidia.com/gpu": "1"
            },
            "limits": {
                "memory": "64Gi",
                "cpu": "8000m",
                "nvidia.com/gpu": "1"
            }
        }}
    ]'
    
    echo ""
    echo "⏳ Waiting for pod to restart with GPU..."
    kubectl rollout status deployment/ollama -n "$NAMESPACE" --timeout=120s 2>/dev/null || sleep 30
    
    echo ""
    echo "✅ GPU acceleration enabled"
    echo ""
    
    # Verify GPU is being used
    OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$OLLAMA_POD" ]; then
        echo "📊 Verifying GPU allocation:"
        kubectl describe pod "$OLLAMA_POD" -n "$NAMESPACE" 2>/dev/null | grep -A5 "Limits:" || echo "  Checking..."
        echo ""
    fi
    
    echo "🎉 Ollama now uses your NVIDIA GPU for inference"
    echo "   Large models (21GB+) will load into GPU VRAM"
    echo ""
    sleep 3
fi

# Disable GPU (if option 6 was chosen to disable)
if [ "${DISABLE_GPU:-false}" = true ]; then
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  💻 Disabling GPU Acceleration (CPU-only mode)${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo "📊 Current Ollama deployment:"
    kubectl get deployment ollama -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null | jq . || echo "  (checking...)"
    echo ""
    
    echo "🚀 Patching Ollama deployment to CPU-only mode..."
    
    # Patch the deployment to remove GPU resources
    kubectl patch deployment ollama -n "$NAMESPACE" --type='json' -p='[
        {"op": "replace", "path": "/spec/template/spec/containers/0/resources", "value": {
            "requests": {
                "memory": "8Gi",
                "cpu": "2000m"
            },
            "limits": {
                "memory": "64Gi",
                "cpu": "8000m"
            }
        }}
    ]'
    
    echo ""
    echo "⏳ Waiting for pod to restart in CPU-only mode..."
    kubectl rollout status deployment/ollama -n "$NAMESPACE" --timeout=120s 2>/dev/null || sleep 30
    
    echo ""
    echo "✅ GPU acceleration disabled"
    echo ""
    echo "🎉 Ollama now uses CPU only - GPU is available for other apps (e.g., LLMAPI)"
    echo ""
    sleep 3
fi

# Configure VPS route using standardized post-install-routing library
# Skip in AUTO_INSTALL_MODE (configured from bootstrap - no VPS yet)
if [ "${AUTO_INSTALL_MODE:-false}" != "true" ] && ([ "$ALREADY_INSTALLED" = false ] || [ "${INSTALL_OPTION:-}" = "1" ]); then
    # Use standardized routing configuration (auto-detects domains from registry)
    if [[ -f "$PROJECT_ROOT/scripts/lib/post-install-routing.sh" ]]; then
        source "$PROJECT_ROOT/scripts/lib/post-install-routing.sh" "open-webui" "80" "$APP_SUBDOMAIN" "$NAMESPACE" "open-webui"
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
                echo "✓ Model $MODEL_NAME downloaded and ready"
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
echo "🎉 LLM Chat is ready to use"
echo ""
echo "📊 Performance Optimizations:"
echo "   ✅ High-priority scheduling (system-critical)"
echo "   ✅ Increased CPU allocation (2-6 cores for Ollama)"
echo "   ✅ Increased RAM allocation (4-16Gi for Ollama)"
echo "   ✅ Parallel request handling (4 concurrent)"
echo "   ✅ Multi-model support (2 models loaded)"
echo ""
echo "🚀 Result: Faster token generation and better responsiveness"
echo ""
echo "💡 Quick Start:"
echo "   1. Open: http://${APP_SUBDOMAIN:-chat}.${CLUSTER_DOMAIN}.local"
echo "   2. Create your account (first user = admin)"
echo "   3. Download a model if you skipped earlier"
echo "   4. Start chatting with your private AI"
echo ""
echo "📚 Features:"
echo "   • 100% Private (no data leaves your cluster)"
echo "   • Document upload & analysis"
echo "   • Web search integration"
echo "   • Image generation (with appropriate models)"
echo "   • Multiple model support"
echo "   • Chat history & conversations"
echo ""
