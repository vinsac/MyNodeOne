#!/bin/bash

###############################################################################
# LLM API Service - One-Click Installation
# 
# Production-ready OpenAI-compatible LLM API with:
# - vLLM for GPU inference (continuous batching)
# - llama.cpp for CPU/RAM overflow and large models
# - Ollama for dynamic model loading and experimentation
# - Dedicated embedding service
# - Rate limiting, priority queuing, usage metering
# - Web Admin UI for model management
#
# DOCUMENTATION:
# - Architecture: scripts/apps/llmapi/ARCHITECTURE.md
# - Quick start: scripts/apps/llmapi/README.md
# - Public access configuration: docs/APP-PUBLIC-ACCESS.md
# - After installation, you'll be asked if you want to make this app public
# - You can change visibility anytime: sudo ./scripts/manage-app-visibility.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

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

# Get cluster domain
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "mynodeone")
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

NAMESPACE="llmapi"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing LLM API Service${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# =============================================================================
# Prerequisites Check
# =============================================================================

echo "🔍 Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found. Please install Kubernetes first.${NC}"
    exit 1
fi

if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster.${NC}"
    exit 1
fi

# Install aria2 for fast multi-threaded model downloads
if ! command -v aria2c &> /dev/null; then
    echo "📥 Installing aria2 for fast model downloads..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq aria2
        echo -e "${GREEN}✓ aria2 installed${NC}"
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y -q aria2
        echo -e "${GREEN}✓ aria2 installed${NC}"
    elif command -v yum &> /dev/null; then
        sudo yum install -y -q aria2
        echo -e "${GREEN}✓ aria2 installed${NC}"
    else
        echo -e "${YELLOW}⚠ Could not install aria2 automatically. Downloads may be slower.${NC}"
    fi
fi

# Check for GPU
GPU_AVAILABLE=false
GPU_COUNT=0
if kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | grep -q "[0-9]"; then
    GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' | paste -sd+ | bc 2>/dev/null || echo "1")
    if [ "$GPU_COUNT" -gt 0 ] 2>/dev/null; then
        GPU_AVAILABLE=true
    fi
fi

# Check for Longhorn
if ! kubectl get storageclass longhorn &> /dev/null; then
    echo -e "${YELLOW}Warning: Longhorn storage class not found.${NC}"
    read -p "Continue anyway? [y/N]: " continue_without_storage
    if [[ "$continue_without_storage" != "y" ]]; then
        exit 1
    fi
fi

# Get system resources
TOTAL_RAM_KB=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.memory}' | sed 's/Ki//')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
TOTAL_CPU=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')

echo ""
echo "📊 Cluster Resources Detected:"
echo "   • CPU Cores: $TOTAL_CPU"
echo "   • RAM: ${TOTAL_RAM_GB}GB"
if [ "$GPU_AVAILABLE" = true ]; then
    echo -e "   • GPUs: ${GREEN}${GPU_COUNT} NVIDIA GPU(s)${NC}"
else
    echo -e "   • GPUs: ${YELLOW}None detected${NC}"
fi
echo ""

# =============================================================================
# Check for Pre-Downloaded Models
# =============================================================================

# Default pre-download directory
PRE_DOWNLOAD_DIR="${LLM_MODEL_DIR:-/var/lib/llmapi/models}"
PRE_DOWNLOADED_VLLM=""
PRE_DOWNLOADED_LLAMACPP=""
PRE_DOWNLOADED_EMBEDDING=""

if [[ -d "$PRE_DOWNLOAD_DIR" ]]; then
    echo "📦 Checking for pre-downloaded models in $PRE_DOWNLOAD_DIR..."
    
    # Check for vLLM models
    if [[ -d "$PRE_DOWNLOAD_DIR/vllm" ]] && [[ -n "$(ls -A "$PRE_DOWNLOAD_DIR/vllm" 2>/dev/null)" ]]; then
        for model_dir in "$PRE_DOWNLOAD_DIR/vllm"/*/; do
            if [[ -d "$model_dir" ]]; then
                model_name=$(basename "$model_dir")
                # Check for actual model files (safetensors) - search recursively
                safetensors_count=$(find "$model_dir" -name "*.safetensors" -type f 2>/dev/null | wc -l)
                if [[ "$safetensors_count" -gt 0 ]]; then
                    # Calculate size by summing safetensors files
                    model_bytes=$(find "$model_dir" -name "*.safetensors" -type f -exec stat -c%s {} + 2>/dev/null | awk '{s+=$1}END{print s}')
                    if [[ -n "$model_bytes" ]] && [[ "$model_bytes" -gt 0 ]]; then
                        model_size=$(echo "$model_bytes" | awk '{printf "%.1fG", $1/1024/1024/1024}')
                    else
                        model_size=$(du -sh "$model_dir" 2>/dev/null | cut -f1)
                    fi
                    echo -e "   ${GREEN}✓ vLLM: $model_name ($model_size, $safetensors_count files)${NC}"
                    PRE_DOWNLOADED_VLLM="$model_dir"
                else
                    # Debug: show what's in the directory
                    file_count=$(find "$model_dir" -type f 2>/dev/null | wc -l)
                    echo -e "   ${YELLOW}⚠ vLLM: $model_name (no .safetensors files, has $file_count other files)${NC}"
                fi
            fi
        done
    fi
    
    # Check for llama.cpp models
    if [[ -d "$PRE_DOWNLOAD_DIR/llamacpp" ]]; then
        for gguf_file in "$PRE_DOWNLOAD_DIR/llamacpp"/*.gguf; do
            if [[ -f "$gguf_file" ]]; then
                filename=$(basename "$gguf_file")
                filesize=$(du -h "$gguf_file" 2>/dev/null | cut -f1)
                echo -e "   ${GREEN}✓ llama.cpp: $filename ($filesize)${NC}"
                PRE_DOWNLOADED_LLAMACPP="$gguf_file"
            fi
        done
    fi
    
    # Check for embedding models
    if [[ -d "$PRE_DOWNLOAD_DIR/embedding" ]]; then
        for gguf_file in "$PRE_DOWNLOAD_DIR/embedding"/*.gguf; do
            if [[ -f "$gguf_file" ]]; then
                filename=$(basename "$gguf_file")
                filesize=$(du -h "$gguf_file" 2>/dev/null | cut -f1)
                echo -e "   ${GREEN}✓ Embedding: $filename ($filesize)${NC}"
                PRE_DOWNLOADED_EMBEDDING="$gguf_file"
            fi
        done
    fi
    
    if [[ -z "$PRE_DOWNLOADED_VLLM" ]] && [[ -z "$PRE_DOWNLOADED_LLAMACPP" ]] && [[ -z "$PRE_DOWNLOADED_EMBEDDING" ]]; then
        echo -e "   ${YELLOW}No pre-downloaded models found${NC}"
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  Models Not Pre-Downloaded${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "LLM models are large (10-50GB) and downloading them during"
        echo "installation can be slow and may cause pod timeouts."
        echo ""
        echo "Pre-downloading is recommended because:"
        echo "  • Uses aria2c with 16 parallel connections (5-10x faster)"
        echo "  • Models persist in /var/lib/llmapi/models/ across reinstalls"
        echo "  • Can resume interrupted downloads"
        echo ""
        echo "Options:"
        echo "  1) Download models now (recommended)"
        echo "  2) Continue without pre-downloading (slower, may timeout)"
        echo "  3) Exit and download manually"
        echo ""
        read -p "Choose an option [1/2/3]: " download_choice
        case "$download_choice" in
            1)
                echo ""
                echo "🚀 Launching model download manager..."
                echo ""
                "$SCRIPT_DIR/download-models.sh"
                # Re-check for downloaded models
                if [[ -d "$PRE_DOWNLOAD_DIR/vllm" ]] && [[ -n "$(ls -A "$PRE_DOWNLOAD_DIR/vllm" 2>/dev/null)" ]]; then
                    for model_dir in "$PRE_DOWNLOAD_DIR/vllm"/*/; do
                        [[ -d "$model_dir" ]] && PRE_DOWNLOADED_VLLM="$model_dir"
                    done
                fi
                if [[ -d "$PRE_DOWNLOAD_DIR/llamacpp" ]]; then
                    for gguf_file in "$PRE_DOWNLOAD_DIR/llamacpp"/*.gguf; do
                        [[ -f "$gguf_file" ]] && PRE_DOWNLOADED_LLAMACPP="$gguf_file"
                    done
                fi
                if [[ -d "$PRE_DOWNLOAD_DIR/embedding" ]]; then
                    for gguf_file in "$PRE_DOWNLOAD_DIR/embedding"/*.gguf; do
                        [[ -f "$gguf_file" ]] && PRE_DOWNLOADED_EMBEDDING="$gguf_file"
                    done
                fi
                echo ""
                echo "Continuing with installation..."
                ;;
            2)
                echo ""
                echo -e "${YELLOW}⚠️  Continuing without pre-downloaded models.${NC}"
                echo "   Models will be downloaded by pods during startup (slower)."
                echo ""
                ;;
            3)
                echo ""
                echo "To download models manually, run:"
                echo "  sudo $SCRIPT_DIR/download-models.sh"
                echo ""
                echo "Then re-run this installation script."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Exiting.${NC}"
                exit 1
                ;;
        esac
    fi
    echo ""
else
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  Models Not Pre-Downloaded${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "LLM models are large (10-50GB) and downloading them during"
    echo "installation can be slow and may cause pod timeouts."
    echo ""
    echo "Pre-downloading is recommended because:"
    echo "  • Uses aria2c with 16 parallel connections (5-10x faster)"
    echo "  • Models persist in /var/lib/llmapi/models/ across reinstalls"
    echo "  • Can resume interrupted downloads"
    echo ""
    echo "Options:"
    echo "  1) Download models now (recommended)"
    echo "  2) Continue without pre-downloading (slower, may timeout)"
    echo "  3) Exit and download manually"
    echo ""
    read -p "Choose an option [1/2/3]: " download_choice
    case "$download_choice" in
        1)
            echo ""
            echo "🚀 Launching model download manager..."
            echo ""
            # Create the directory first
            sudo mkdir -p "$PRE_DOWNLOAD_DIR"
            "$SCRIPT_DIR/download-models.sh"
            # Re-check for downloaded models
            if [[ -d "$PRE_DOWNLOAD_DIR/vllm" ]] && [[ -n "$(ls -A "$PRE_DOWNLOAD_DIR/vllm" 2>/dev/null)" ]]; then
                for model_dir in "$PRE_DOWNLOAD_DIR/vllm"/*/; do
                    [[ -d "$model_dir" ]] && PRE_DOWNLOADED_VLLM="$model_dir"
                done
            fi
            if [[ -d "$PRE_DOWNLOAD_DIR/llamacpp" ]]; then
                for gguf_file in "$PRE_DOWNLOAD_DIR/llamacpp"/*.gguf; do
                    [[ -f "$gguf_file" ]] && PRE_DOWNLOADED_LLAMACPP="$gguf_file"
                done
            fi
            if [[ -d "$PRE_DOWNLOAD_DIR/embedding" ]]; then
                for gguf_file in "$PRE_DOWNLOAD_DIR/embedding"/*.gguf; do
                    [[ -f "$gguf_file" ]] && PRE_DOWNLOADED_EMBEDDING="$gguf_file"
                done
            fi
            echo ""
            echo "Continuing with installation..."
            ;;
        2)
            echo ""
            echo -e "${YELLOW}⚠️  Continuing without pre-downloaded models.${NC}"
            echo "   Models will be downloaded by pods during startup (slower)."
            echo ""
            ;;
        3)
            echo ""
            echo "To download models manually, run:"
            echo "  sudo $SCRIPT_DIR/download-models.sh"
            echo ""
            echo "Then re-run this installation script."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Exiting.${NC}"
            exit 1
            ;;
    esac
    echo ""
fi

# =============================================================================
# Check for Existing Installation and Cached Models
# =============================================================================

EXISTING_INSTALL=false
CACHED_MODELS=""

if kubectl get namespace llmapi &>/dev/null; then
    EXISTING_INSTALL=true
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Existing Installation Detected${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Check for cached models in PVCs
    echo "📦 Checking for cached models..."
    
    # Check vLLM models
    VLLM_MODEL_CACHED=$(kubectl exec -n llmapi statefulset/vllm -- ls -la /models 2>/dev/null | grep -v "^total" | head -5 || echo "")
    if [ -n "$VLLM_MODEL_CACHED" ]; then
        echo -e "   ${GREEN}✓ vLLM models cached${NC}"
        CACHED_MODELS="vllm"
    fi
    
    # Check llama.cpp models  
    LLAMACPP_MODEL_CACHED=$(kubectl exec -n llmapi deploy/llamacpp -c llamacpp -- ls -la /models 2>/dev/null | grep "\.gguf" | head -3 || echo "")
    if [ -n "$LLAMACPP_MODEL_CACHED" ]; then
        echo -e "   ${GREEN}✓ llama.cpp GGUF models cached${NC}"
        CACHED_MODELS="${CACHED_MODELS} llamacpp"
    fi
    
    # Check Ollama models
    OLLAMA_MODELS=$(kubectl exec -n llmapi deploy/ollama -- du -sh /root/.ollama/models 2>/dev/null | cut -f1 || echo "0")
    if [ "$OLLAMA_MODELS" != "0" ] && [ -n "$OLLAMA_MODELS" ]; then
        echo -e "   ${GREEN}✓ Ollama models cached (~${OLLAMA_MODELS})${NC}"
        CACHED_MODELS="${CACHED_MODELS} ollama"
    fi
    
    echo ""
    echo "Options:"
    echo "  1. Upgrade/Reconfigure (keeps cached models)"
    echo "  2. Fresh install (deletes everything including models)"
    echo "  3. Cancel"
    echo ""
    read -p "Choose option [1-3, default: 1]: " INSTALL_OPTION
    INSTALL_OPTION="${INSTALL_OPTION:-1}"
    
    case "$INSTALL_OPTION" in
        1)
            echo -e "   ${GREEN}✓ Keeping cached models${NC}"
            ;;
        2)
            echo -e "   ${YELLOW}⚠ Deleting namespace and all data...${NC}"
            kubectl delete namespace llmapi --timeout=120s 2>/dev/null || true
            EXISTING_INSTALL=false
            CACHED_MODELS=""
            ;;
        3)
            echo "Installation cancelled."
            exit 0
            ;;
    esac
    echo ""
fi

# =============================================================================
# Configuration
# =============================================================================

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Subdomain
echo "🌐 Choose a subdomain for the LLM API:"
echo "   Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo ""
read -p "Enter subdomain [default: llmapi]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-llmapi}"
APP_SUBDOMAIN=$(echo "$APP_SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')
if [ -z "$APP_SUBDOMAIN" ]; then
    APP_SUBDOMAIN="llmapi"
fi
echo ""

# Deployment mode
echo "🚀 Choose deployment mode:"
echo ""
echo "  1. Full Stack (recommended)"
echo "     • vLLM on GPU for fast inference"
echo "     • llama.cpp on CPU for overflow/large models"
echo "     • Dedicated embedding service"
echo ""
echo "  2. GPU Only"
echo "     • vLLM only (requires GPU)"
echo "     • Best for real-time inference"
echo ""
echo "  3. CPU Only"
echo "     • llama.cpp only (no GPU required)"
echo "     • Good for large models with high RAM"
echo ""
echo "  4. Minimal"
echo "     • Embedding service only"
echo "     • For document indexing/RAG"
echo ""

if [ "$GPU_AVAILABLE" = true ]; then
    read -p "Choose mode [1-4, default: 1]: " DEPLOY_MODE
    DEPLOY_MODE="${DEPLOY_MODE:-1}"
else
    echo -e "${YELLOW}Note: No GPU detected. Options 1 and 2 will skip vLLM.${NC}"
    read -p "Choose mode [1-4, default: 3]: " DEPLOY_MODE
    DEPLOY_MODE="${DEPLOY_MODE:-3}"
fi
echo ""

# Model selection for vLLM
VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct-AWQ"
VLLM_MODEL_NAME="qwen2.5-14b"
if [ "$GPU_AVAILABLE" = true ] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]); then
    echo "🤖 Choose primary GPU model (vLLM):"
    echo ""
    echo "  Popular Models (AWQ quantized for fast GPU inference):"
    echo "  1. Qwen2.5-14B (AWQ) - Best balance of quality and speed (~10GB VRAM)"
    echo "  2. Qwen2.5-7B        - Faster, good for autocomplete (~6GB VRAM)"
    echo "  3. Mistral-7B        - Fast, general purpose (~6GB VRAM)"
    echo "  4. CodeLlama-34B (AWQ) - Best for coding tasks (~20GB VRAM)"
    echo ""
    echo "  Custom Model:"
    echo "  5. Enter your own HuggingFace model ID"
    echo ""
    echo -e "  ${BLUE}Browse models: https://huggingface.co/models?library=vllm${NC}"
    echo ""
    read -p "Choose model [1-5, default: 1]: " MODEL_CHOICE
    MODEL_CHOICE="${MODEL_CHOICE:-1}"
    
    case "$MODEL_CHOICE" in
        1)
            VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct-AWQ"
            VLLM_MODEL_NAME="qwen2.5-14b"
            ;;
        2)
            VLLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
            VLLM_MODEL_NAME="qwen2.5-7b"
            ;;
        3)
            VLLM_MODEL="mistralai/Mistral-7B-Instruct-v0.3"
            VLLM_MODEL_NAME="mistral-7b"
            ;;
        4)
            VLLM_MODEL="TheBloke/CodeLlama-34B-Instruct-AWQ"
            VLLM_MODEL_NAME="codellama-34b"
            ;;
        5)
            echo ""
            echo "  Enter the HuggingFace model ID (e.g., Qwen/Qwen2.5-7B-Instruct)"
            echo "  Find models at: https://huggingface.co/models?library=vllm"
            read -p "  Model ID: " VLLM_MODEL
            echo ""
            echo "  Enter a short name for API calls (e.g., qwen-7b, my-model)"
            read -p "  API name: " VLLM_MODEL_NAME
            # Validate
            if [ -z "$VLLM_MODEL" ]; then
                echo -e "${YELLOW}No model entered, using default Qwen2.5-14B${NC}"
                VLLM_MODEL="Qwen/Qwen2.5-14B-Instruct-AWQ"
                VLLM_MODEL_NAME="qwen2.5-14b"
            fi
            ;;
    esac
    echo ""
fi

# Model selection for llama.cpp
LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
LLAMACPP_MODEL_FILE="Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "🧠 Choose CPU/RAM model (llama.cpp - GGUF format):"
    echo ""
    echo "  Large Models (best quality, need high RAM):"
    echo "  1. Llama-3.1-70B (Q4_K_M) - ~45GB RAM, excellent quality"
    echo "  2. Llama-3.1-70B (Q5_K_M) - ~55GB RAM, higher quality"
    echo "  3. Mixtral-8x7B (Q4_K_M)  - ~30GB RAM, fast MoE architecture"
    echo ""
    echo "  Medium Models (good balance):"
    echo "  4. Qwen2.5-14B (Q4_K_M)   - ~10GB RAM, same as GPU model (overflow capacity)"
    echo "  5. Qwen2.5-14B (Q8_0)     - ~16GB RAM, higher quality version"
    echo ""
    echo "  Smaller Models (faster, lower RAM):"
    echo "  6. Llama-3.1-8B (Q8)      - ~10GB RAM, fast and good quality"
    echo ""
    echo "  Custom Model:"
    echo "  7. Enter your own GGUF URL from HuggingFace"
    echo ""
    echo -e "  ${BLUE}Browse GGUF models: https://huggingface.co/models?library=gguf${NC}"
    echo ""
    read -p "Choose model [1-7, default: 1]: " CPU_MODEL_CHOICE
    CPU_MODEL_CHOICE="${CPU_MODEL_CHOICE:-1}"
    
    case "$CPU_MODEL_CHOICE" in
        1)
            LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
            LLAMACPP_MODEL_FILE="Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
            ;;
        2)
            LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q5_K_M.gguf"
            LLAMACPP_MODEL_FILE="Meta-Llama-3.1-70B-Instruct-Q5_K_M.gguf"
            ;;
        3)
            LLAMACPP_MODEL_URL="https://huggingface.co/TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF/resolve/main/mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"
            LLAMACPP_MODEL_FILE="mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"
            ;;
        4)
            # Qwen2.5-14B Q4 - same model as GPU vLLM, provides overflow capacity
            LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"
            LLAMACPP_MODEL_FILE="qwen2.5-14b-instruct-q4_k_m.gguf"
            ;;
        5)
            # Qwen2.5-14B Q8 - higher quality version
            LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q8_0.gguf"
            LLAMACPP_MODEL_FILE="qwen2.5-14b-instruct-q8_0.gguf"
            ;;
        6)
            LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
            LLAMACPP_MODEL_FILE="Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
            ;;
        7)
            echo ""
            echo "  Enter the full URL to the GGUF file"
            echo "  Example: https://huggingface.co/TheBloke/Llama-2-13B-GGUF/resolve/main/llama-2-13b.Q4_K_M.gguf"
            echo "  Find models at: https://huggingface.co/models?library=gguf"
            read -p "  GGUF URL: " LLAMACPP_MODEL_URL
            # Extract filename from URL
            LLAMACPP_MODEL_FILE=$(basename "$LLAMACPP_MODEL_URL")
            echo "  Detected filename: $LLAMACPP_MODEL_FILE"
            read -p "  Override filename? [press Enter to keep]: " CUSTOM_FILENAME
            if [ -n "$CUSTOM_FILENAME" ]; then
                LLAMACPP_MODEL_FILE="$CUSTOM_FILENAME"
            fi
            # Validate
            if [ -z "$LLAMACPP_MODEL_URL" ]; then
                echo -e "${YELLOW}No URL entered, using default Llama-3.1-70B${NC}"
                LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
                LLAMACPP_MODEL_FILE="Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
            fi
            ;;
    esac
    echo ""
fi

# Determine llama.cpp model name for API (derive from filename)
LLAMACPP_MODEL_NAME=""
if [ -n "$LLAMACPP_MODEL_FILE" ]; then
    # Convert filename to API-friendly name: lowercase, remove .gguf, replace special chars
    LLAMACPP_MODEL_NAME=$(echo "$LLAMACPP_MODEL_FILE" | sed 's/\.gguf$//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
fi

# Check if same model family is used for GPU and CPU (enables overflow)
OVERFLOW_MODELS=""
if [ "$DEPLOY_MODE" = "1" ] && [ "$GPU_AVAILABLE" = true ]; then
    # Check if both are Qwen2.5-14B variants
    if [[ "$VLLM_MODEL_NAME" == "qwen2.5-14b" ]] && [[ "$LLAMACPP_MODEL_FILE" == *"qwen2.5-14b"* ]]; then
        OVERFLOW_MODELS="${VLLM_MODEL_NAME}:${LLAMACPP_MODEL_NAME}"
        echo -e "${GREEN}✓ Overflow enabled: ${VLLM_MODEL_NAME} → ${LLAMACPP_MODEL_NAME}${NC}"
        echo "   When GPU is overloaded, requests will automatically route to CPU"
        echo ""
    fi
fi

# Default quotas
echo "📊 Default API quotas for new keys:"
read -p "Tokens per day [default: 100000]: " DEFAULT_TOKENS
DEFAULT_TOKENS="${DEFAULT_TOKENS:-100000}"
read -p "Requests per minute [default: 60]: " DEFAULT_RPM
DEFAULT_RPM="${DEFAULT_RPM:-60}"
echo ""

# HuggingFace Token (optional but recommended for faster downloads)
HF_TOKEN=""
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "🔑 HuggingFace Token (recommended for faster model downloads):"
    echo ""
    echo "   A HuggingFace token removes rate limits and enables gated models."
    echo "   Get a free token at: https://huggingface.co/settings/tokens"
    echo "   (Leave empty to skip - downloads will be slower)"
    echo ""
    read -p "Enter HuggingFace token [optional]: " HF_TOKEN
    if [ -n "$HF_TOKEN" ]; then
        echo -e "   ${GREEN}✓ Token provided - downloads will be faster${NC}"
    else
        echo -e "   ${YELLOW}⚠ No token - downloads may be rate-limited${NC}"
    fi
    echo ""
fi

# Confirm
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Deployment Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "   Subdomain: ${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo "   Mode: $(case $DEPLOY_MODE in 1) echo 'Full Stack';; 2) echo 'GPU Only';; 3) echo 'CPU Only';; 4) echo 'Minimal';; esac)"
if [ "$GPU_AVAILABLE" = true ] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]); then
    echo "   GPU Model: $VLLM_MODEL_NAME"
fi
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "   CPU Model: $LLAMACPP_MODEL_FILE"
fi
echo "   Default Quota: ${DEFAULT_TOKENS} tokens/day, ${DEFAULT_RPM} req/min"
echo ""
read -p "Proceed with installation? [Y/n]: " CONFIRM
if [ "${CONFIRM,,}" = "n" ]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# =============================================================================
# Installation
# =============================================================================

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Components${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Generate secure admin password
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
echo "🔐 Generated admin password: $ADMIN_PASSWORD"
echo "   (Save this! You'll need it to access the Admin UI)"
echo ""

# Create namespace
echo "📦 Creating namespace..."
kubectl apply -f "$SCRIPT_DIR/manifests/namespace.yaml"

# Deploy RBAC for gateway (allows model changes from Admin UI)
echo "🔐 Deploying gateway RBAC..."
kubectl apply -f "$SCRIPT_DIR/manifests/gateway-rbac.yaml"

# =============================================================================
# Copy Pre-Downloaded Models to PVCs (if available)
# =============================================================================

copy_predownloaded_models() {
    local model_type="$1"
    local source_path="$2"
    local pvc_name="$3"
    
    if [[ -z "$source_path" ]] || [[ ! -e "$source_path" ]]; then
        return 0
    fi
    
    echo "   📦 Copying pre-downloaded $model_type model to PVC..."
    
    # First, ensure the PVC exists by applying the manifest
    case "$model_type" in
        vllm)
            kubectl apply -f "$SCRIPT_DIR/manifests/vllm.yaml" --dry-run=server -o yaml 2>/dev/null | grep -q "PersistentVolumeClaim" && \
            kubectl apply -f <(kubectl apply -f "$SCRIPT_DIR/manifests/vllm.yaml" --dry-run=client -o yaml 2>/dev/null | grep -A20 "kind: PersistentVolumeClaim") 2>/dev/null || true
            ;;
        llamacpp)
            kubectl apply -f "$SCRIPT_DIR/manifests/llamacpp.yaml" --dry-run=server -o yaml 2>/dev/null | grep -q "PersistentVolumeClaim" && \
            kubectl apply -f <(kubectl apply -f "$SCRIPT_DIR/manifests/llamacpp.yaml" --dry-run=client -o yaml 2>/dev/null | grep -A20 "kind: PersistentVolumeClaim") 2>/dev/null || true
            ;;
    esac
    
    # Wait for PVC to be bound
    echo "   ⏳ Waiting for PVC $pvc_name to be ready..."
    kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/$pvc_name -n $NAMESPACE --timeout=120s 2>/dev/null || {
        echo -e "   ${YELLOW}⚠ PVC not ready, will download during deployment${NC}"
        return 0
    }
    
    # Create a temporary pod to copy files
    local copy_pod="model-copy-$$"
    
    cat <<COPYPOD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $copy_pod
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: copy
    image: busybox
    command: ["sleep", "300"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: models
      mountPath: /models
    resources:
      requests:
        memory: "64Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "500m"
  volumes:
  - name: models
    persistentVolumeClaim:
      claimName: $pvc_name
COPYPOD
    
    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/$copy_pod -n $NAMESPACE --timeout=60s 2>/dev/null || {
        kubectl delete pod $copy_pod -n $NAMESPACE --force --grace-period=0 2>/dev/null || true
        echo -e "   ${YELLOW}⚠ Copy pod failed to start, will download during deployment${NC}"
        return 0
    }
    
    # Copy files
    echo "   📤 Copying files (this may take a while for large models)..."
    if [[ -d "$source_path" ]]; then
        # Directory (vLLM model)
        kubectl cp "$source_path" "$NAMESPACE/$copy_pod:/models/" 2>/dev/null || {
            echo -e "   ${YELLOW}⚠ Copy failed, will download during deployment${NC}"
        }
    else
        # Single file (GGUF)
        kubectl cp "$source_path" "$NAMESPACE/$copy_pod:/models/$(basename "$source_path")" 2>/dev/null || {
            echo -e "   ${YELLOW}⚠ Copy failed, will download during deployment${NC}"
        }
    fi
    
    # Cleanup
    kubectl delete pod $copy_pod -n $NAMESPACE --force --grace-period=0 2>/dev/null || true
    
    echo -e "   ${GREEN}✓ Pre-downloaded model copied to PVC${NC}"
}

# Copy pre-downloaded models if available
if [[ -n "$PRE_DOWNLOADED_VLLM" ]] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]); then
    copy_predownloaded_models "vllm" "$PRE_DOWNLOADED_VLLM" "vllm-models"
fi

if [[ -n "$PRE_DOWNLOADED_LLAMACPP" ]] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]); then
    copy_predownloaded_models "llamacpp" "$PRE_DOWNLOADED_LLAMACPP" "llamacpp-models"
fi

# Deploy Redis
echo "🔴 Deploying Redis..."
kubectl apply -f "$SCRIPT_DIR/manifests/redis.yaml"

# Build and deploy gateway (using inline image for now)
echo "🌐 Deploying API Gateway..."

# Determine model names for gateway config
LLAMACPP_MODEL_API_NAME="${LLAMACPP_MODEL_FILE%.gguf}"
LLAMACPP_MODEL_API_NAME=$(echo "$LLAMACPP_MODEL_API_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Update gateway config with custom settings
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-config
  namespace: $NAMESPACE
data:
  REDIS_URL: "redis://redis:6379/0"
  VLLM_URLS: "http://vllm-0.vllm:8000"
  LLAMACPP_URL: "http://llamacpp:8080"
  EMBEDDING_URL: "http://embedding:8080"
  LLAMACPP_MODEL_NAME: "${LLAMACPP_MODEL_NAME:-llama-cpu}"
  EMBEDDING_MODEL_NAME: "embedding"
  DEFAULT_REQUESTS_PER_MINUTE: "$DEFAULT_RPM"
  DEFAULT_TOKENS_PER_DAY: "$DEFAULT_TOKENS"
  ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
  OLLAMA_URL: "http://ollama:11434"
  LAZY_LOAD_ENABLED: "true"
  LAZY_LOAD_BACKEND: "ollama"
  # Overflow: route from GPU to CPU when overloaded (empty = disabled)
  OVERFLOW_MODELS: "${OVERFLOW_MODELS}"
  OVERFLOW_THRESHOLD: "8"
EOF

# Create ConfigMap with gateway Python code
echo "📄 Creating gateway code ConfigMap..."
kubectl create configmap gateway-code -n $NAMESPACE \
    --from-file=main.py="$SCRIPT_DIR/gateway/main.py" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy gateway using Python image with code from ConfigMap
cat <<'EOF' | sed "s/\$NAMESPACE/$NAMESPACE/g" | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: $NAMESPACE
  labels:
    app: llmapi-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llmapi-gateway
  template:
    metadata:
      labels:
        app: llmapi-gateway
    spec:
      serviceAccountName: gateway
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
      - name: install-deps
        image: python:3.11-slim
        command: ["/bin/sh", "-c"]
        args:
        - |
          pip install --target=/app/deps fastapi uvicorn httpx redis pydantic prometheus-client python-multipart kubernetes --quiet
        volumeMounts:
        - name: app-deps
          mountPath: /app/deps
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
      containers:
      - name: gateway
        image: python:3.11-slim
        ports:
        - containerPort: 8000
          name: http
        command: ["/bin/sh", "-c"]
        args:
        - |
          export PYTHONPATH=/app/deps
          cd /app && python -m uvicorn main:app --host 0.0.0.0 --port 8000
        env:
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        envFrom:
        - configMapRef:
            name: gateway-config
        volumeMounts:
        - name: gateway-code
          mountPath: /app/main.py
          subPath: main.py
        - name: app-deps
          mountPath: /app/deps
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: false
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 60
          periodSeconds: 5
      volumes:
      - name: gateway-code
        configMap:
          name: gateway-code
      - name: app-deps
        emptyDir: {}
EOF

# Create gateway service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: llmapi
  namespace: $NAMESPACE
  annotations:
    mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
spec:
  selector:
    app: llmapi-gateway
  ports:
  - port: 80
    targetPort: 8000
    name: http
  type: LoadBalancer
EOF

# Deploy vLLM if GPU available and mode requires it
if [ "$GPU_AVAILABLE" = true ] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]); then
    echo "🚀 Deploying vLLM (GPU backend)..."
    
    # Create HuggingFace token secret if provided
    if [ -n "$HF_TOKEN" ]; then
        echo "   Creating HuggingFace token secret..."
        kubectl create secret generic hf-token -n $NAMESPACE \
            --from-literal=token="$HF_TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    # Pre-pull vLLM image to avoid Docker Hub rate limits during deployment
    VLLM_IMAGE="vllm/vllm-openai:v0.6.6.post1"
    echo "   📥 Pre-pulling vLLM image (this may take a few minutes)..."
    echo "      Image: $VLLM_IMAGE"
    
    # Try to pull image via containerd (K3s uses containerd)
    if command -v ctr &> /dev/null; then
        if sudo ctr -n k8s.io image pull "docker.io/$VLLM_IMAGE" 2>/dev/null; then
            echo -e "   ${GREEN}✓ vLLM image pulled successfully${NC}"
        else
            echo -e "   ${YELLOW}⚠ Image pre-pull failed - will retry during deployment${NC}"
        fi
    else
        echo "   ⏳ Image will be pulled during deployment..."
    fi
    
    # Update vLLM config with selected model
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-config
  namespace: $NAMESPACE
data:
  MODEL_NAME: "$VLLM_MODEL"
  SERVED_MODEL_NAME: "$VLLM_MODEL_NAME"
  MAX_MODEL_LEN: "16384"
  GPU_MEMORY_UTILIZATION: "0.90"
  MAX_NUM_SEQS: "32"
  QUANTIZATION: "awq"
  ENABLE_CHUNKED_PREFILL: "true"
  ENFORCE_EAGER: "false"
EOF

    # Deploy vLLM StatefulSet
    kubectl apply -f "$SCRIPT_DIR/manifests/vllm.yaml"
else
    echo "⏭️  Skipping vLLM (no GPU or not selected)"
fi

# Deploy llama.cpp if mode requires it
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "🧠 Deploying llama.cpp (CPU backend)..."
    
    # Create HuggingFace token secret if provided and not already created
    if [ -n "$HF_TOKEN" ]; then
        kubectl create secret generic hf-token -n $NAMESPACE \
            --from-literal=token="$HF_TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    # Update llama.cpp config with selected model
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: llamacpp-config
  namespace: $NAMESPACE
data:
  MODEL_URL: "$LLAMACPP_MODEL_URL"
  MODEL_FILE: "$LLAMACPP_MODEL_FILE"
  CONTEXT_SIZE: "32768"
  BATCH_SIZE: "4096"
  THREADS: "16"
  GPU_LAYERS: "0"
  PARALLEL: "4"
  CHAT_TEMPLATE: "llama3"
EOF

    kubectl apply -f "$SCRIPT_DIR/manifests/llamacpp.yaml"
else
    echo "⏭️  Skipping llama.cpp (not selected)"
fi

# Deploy embedding service
echo "📐 Deploying embedding service..."
kubectl apply -f "$SCRIPT_DIR/manifests/embedding.yaml"

# Deploy Ollama (flexible model management)
echo "🦙 Deploying Ollama (dynamic model loading)..."
kubectl apply -f "$SCRIPT_DIR/manifests/ollama.yaml"

# =============================================================================
# Wait for deployments with retries and diagnostics
# =============================================================================

echo ""
echo "⏳ Waiting for components to start..."

# Helper function to wait for deployment with retries and diagnostics
wait_for_deployment() {
    local name="$1"
    local type="$2"  # deployment or statefulset
    local timeout="$3"
    local desc="$4"
    
    echo "   ⏳ $desc..."
    
    if kubectl wait --for=condition=available --timeout=${timeout}s ${type}/${name} -n "$NAMESPACE" 2>/dev/null; then
        echo -e "   ${GREEN}✓ $name is ready${NC}"
        return 0
    else
        echo -e "   ${YELLOW}⚠ $name not ready after ${timeout}s - checking status...${NC}"
        
        # Show pod status
        echo "   Pod status:"
        kubectl get pods -n "$NAMESPACE" -l app=${name} --no-headers 2>/dev/null | while read line; do
            echo "      $line"
        done
        
        # Show recent events
        echo "   Recent events:"
        kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name=${name} \
            --sort-by='.lastTimestamp' 2>/dev/null | tail -3 | while read line; do
            echo "      $line"
        done
        
        # For gateway, show init container logs if present
        if [ "$name" = "gateway" ]; then
            local pod=$(kubectl get pods -n "$NAMESPACE" -l app=llmapi-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [ -n "$pod" ]; then
                echo "   Init container logs (last 10 lines):"
                kubectl logs -n "$NAMESPACE" "$pod" -c install-deps --tail=10 2>/dev/null | while read line; do
                    echo "      $line"
                done
            fi
        fi
        
        return 1
    fi
}

# Wait for Redis first (required by gateway)
if ! wait_for_deployment "redis" "deployment" "120" "Starting Redis"; then
    echo -e "${RED}   ✗ Redis failed to start. Check logs: kubectl logs -n $NAMESPACE deploy/redis${NC}"
fi

# Wait for Gateway (may take time for pip install in initContainer)
if ! wait_for_deployment "gateway" "deployment" "600" "Starting Gateway (installing dependencies)"; then
    echo -e "${YELLOW}   Gateway still initializing. This is normal on first install.${NC}"
    echo "   Monitor progress: kubectl logs -n $NAMESPACE deploy/gateway -c install-deps -f"
fi

# Wait for vLLM if deployed (model download can take 10-30 minutes)
if [ "$GPU_AVAILABLE" = true ] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]); then
    echo ""
    echo "   📥 vLLM model download may take 10-30 minutes for first install..."
    if ! kubectl wait --for=condition=available --timeout=60s statefulset/vllm -n "$NAMESPACE" 2>/dev/null; then
        echo -e "   ${YELLOW}vLLM is downloading model. Monitor: kubectl logs -n $NAMESPACE statefulset/vllm -f${NC}"
    else
        echo -e "   ${GREEN}✓ vLLM is ready${NC}"
    fi
fi

# Wait for llama.cpp if deployed (model download can take 5-15 minutes)
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo ""
    echo "   📥 llama.cpp model download may take 5-15 minutes for first install..."
    if ! kubectl wait --for=condition=available --timeout=60s deployment/llamacpp -n "$NAMESPACE" 2>/dev/null; then
        echo -e "   ${YELLOW}llama.cpp is downloading model. Monitor: kubectl logs -n $NAMESPACE deploy/llamacpp -c model-downloader -f${NC}"
    else
        echo -e "   ${GREEN}✓ llama.cpp is ready${NC}"
    fi
fi

# Wait for embedding service
wait_for_deployment "embedding" "deployment" "120" "Starting Embedding service" || true

# Wait for Ollama
wait_for_deployment "ollama" "deployment" "120" "Starting Ollama" || true

# Get service IP with retry
echo ""
echo "🔍 Getting service IP..."
for i in {1..5}; do
    SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$SERVICE_IP" ]; then
        break
    fi
    SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [ -n "$SERVICE_IP" ]; then
        break
    fi
    sleep 2
done
SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
fi

# =============================================================================
# Create initial API key (with retries)
# =============================================================================

echo ""
echo "🔑 Creating initial API key..."

# Generate API key
API_KEY_ID=$(openssl rand -hex 16)
API_KEY="sk-mynodeone-${API_KEY_ID}"

# Store in Redis via kubectl exec (with retries)
API_KEY_CREATED=false
for attempt in {1..5}; do
    if kubectl exec -n "$NAMESPACE" deploy/redis -- redis-cli SET "apikey:${API_KEY}" \
        "{\"name\":\"default\",\"requests_per_minute\":${DEFAULT_RPM},\"tokens_per_day\":${DEFAULT_TOKENS},\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        2>/dev/null; then
        API_KEY_CREATED=true
        break
    fi
    echo "   Waiting for Redis... (attempt $attempt/5)"
    sleep 3
done

if [ "$API_KEY_CREATED" = false ]; then
    echo -e "${YELLOW}   Could not create API key in Redis. You can create one later via Admin UI.${NC}"
fi

# Save API key to file
mkdir -p "$ACTUAL_HOME/.mynodeone"
echo "$API_KEY" > "$ACTUAL_HOME/.mynodeone/llmapi-key"
chmod 600 "$ACTUAL_HOME/.mynodeone/llmapi-key"

# =============================================================================
# DNS Registration
# =============================================================================

echo ""
echo "🌐 Registering service..."

if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "llmapi" "$APP_SUBDOMAIN" "$NAMESPACE" "llmapi" "80" "false" 2>/dev/null || true
fi

if [ -f "$PROJECT_ROOT/scripts/sync-dns.sh" ]; then
    sudo bash "$PROJECT_ROOT/scripts/sync-dns.sh" --quiet 2>/dev/null || true
fi

# =============================================================================
# Status Summary
# =============================================================================

echo ""
echo "📊 Component Status:"
echo "─────────────────────────────────────────────────────"

# Check each component
check_component() {
    local name="$1"
    local selector="$2"
    local status=$(kubectl get pods -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    local ready=$(kubectl get pods -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    
    if [ "$status" = "Running" ] && [ "$ready" = "True" ]; then
        echo -e "   ${GREEN}✓${NC} $name: Running"
    elif [ "$status" = "Running" ]; then
        echo -e "   ${YELLOW}◐${NC} $name: Starting (containers initializing)"
    elif [ "$status" = "Pending" ]; then
        echo -e "   ${YELLOW}◯${NC} $name: Pending (waiting for resources)"
    elif [ "$status" = "NotFound" ]; then
        echo -e "   ${BLUE}○${NC} $name: Not deployed"
    else
        echo -e "   ${RED}✗${NC} $name: $status"
    fi
}

check_component "Redis" "app=redis"
check_component "Gateway" "app=llmapi-gateway"
[ "$GPU_AVAILABLE" = true ] && ([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ]) && check_component "vLLM (GPU)" "app=vllm"
([ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]) && check_component "llama.cpp (CPU)" "app=llamacpp"
check_component "Embedding" "app=embedding"
check_component "Ollama" "app=llmapi-ollama"

echo "─────────────────────────────────────────────────────"

# =============================================================================
# Success
# =============================================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ LLM API Service Installed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access the API at:"
echo "   • Direct: http://$SERVICE_IP"
echo "   • Local:  http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""
echo "🔑 Your API Key:"
echo "   $API_KEY"
echo "   (saved to ~/.mynodeone/llmapi-key)"
echo ""
echo "🧪 Test the API:"
echo ""
echo "   # List models"
echo "   curl -H \"Authorization: Bearer \$API_KEY\" \\"
echo "        http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1/models"
echo ""
echo "   # Chat completion"
echo "   curl -H \"Authorization: Bearer \$API_KEY\" \\"
echo "        -H \"Content-Type: application/json\" \\"
echo "        -d '{\"model\":\"$VLLM_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}' \\"
echo "        http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1/chat/completions"
echo ""
echo "📚 Python/OpenAI SDK:"
echo ""
echo "   from openai import OpenAI"
echo "   client = OpenAI("
echo "       base_url=\"http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1\","
echo "       api_key=\"$API_KEY\""
echo "   )"
echo ""
echo "🎛️  Admin UI:"
echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/admin"
echo ""
echo "   Login Credentials (HTTP Basic Auth):"
echo "   • Username: admin (or any username)"
echo "   • Password: $ADMIN_PASSWORD"
echo ""
echo "   Features:"
echo "   • Download/manage Ollama models"
echo "   • Change vLLM/llama.cpp models + context/memory settings"
echo "   • Start/stop llama.cpp (free RAM when not needed)"
echo "   • Manage API keys and view usage"
echo ""
echo "🔧 Management:"
echo "   • Status:  ./scripts/apps/llmapi/monitor-llmapi.sh"
echo "   • Keys:    ./scripts/apps/llmapi/manage-keys.sh"
echo "   • Scale:   ./scripts/apps/llmapi/scale-backends.sh"
echo ""
echo "📖 Documentation: scripts/apps/llmapi/ARCHITECTURE.md"
echo ""

# Note about model download
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo -e "${YELLOW}⚠️  Note: Models are downloading in the background.${NC}"
    echo "   This may take 10-60 minutes depending on model size."
    echo ""
fi

echo "🔧 Troubleshooting Commands:"
echo "   # Check all pods"
echo "   kubectl get pods -n $NAMESPACE"
echo ""
echo "   # View gateway logs (if API not responding)"
echo "   kubectl logs -n $NAMESPACE deploy/gateway -c gateway -f"
echo ""
echo "   # View model download progress"
echo "   kubectl logs -n $NAMESPACE statefulset/vllm -f         # vLLM"
echo "   kubectl logs -n $NAMESPACE deploy/llamacpp -c model-downloader -f  # llama.cpp"
echo ""
echo "   # Restart a component"
echo "   kubectl rollout restart deployment/gateway -n $NAMESPACE"
echo ""

# =============================================================================
# Public Access Configuration
# =============================================================================

# Automatically configure routing and ask about public access
if [[ -f "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" ]]; then
    source "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" "llmapi" "80" "$APP_SUBDOMAIN" "$NAMESPACE" "llmapi"
fi
