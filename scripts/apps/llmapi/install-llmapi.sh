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

# Load cluster resource detection utilities
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"

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

# Check for GPU using centralized utility
GPU_COUNT=$(get_cluster_gpu_count)
GPU_AVAILABLE=false
if [ "$GPU_COUNT" -gt 0 ] 2>/dev/null; then
    GPU_AVAILABLE=true
fi

# Check for Longhorn
if ! kubectl get storageclass longhorn &> /dev/null; then
    echo -e "${YELLOW}Warning: Longhorn storage class not found.${NC}"
    read -p "Continue anyway? [y/N]: " continue_without_storage
    if [[ "$continue_without_storage" != "y" ]]; then
        exit 1
    fi
fi

# Get system resources using centralized utility
TOTAL_CPU=$(get_cluster_cpu)
TOTAL_RAM_GB=$(get_cluster_ram_gb)
TOTAL_RAM_KB=$(get_cluster_ram_kb)

echo ""
print_cluster_resources
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
    
    # Always offer download options, regardless of existing models
    echo ""
    if [[ -z "$PRE_DOWNLOADED_VLLM" ]] && [[ -z "$PRE_DOWNLOADED_LLAMACPP" ]] && [[ -z "$PRE_DOWNLOADED_EMBEDDING" ]]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠️  No Models Pre-Downloaded${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "LLM models are large (10-50GB) and downloading them during"
        echo "installation can be slow and may cause pod timeouts."
    else
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}  Model Download Options${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "Found some models, but you may want to download additional ones:"
        if [[ -n "$PRE_DOWNLOADED_VLLM" ]]; then
            echo "  ✅ GPU models (vLLM) - available"
        else
            echo "  ❌ GPU models (vLLM) - missing"
        fi
        if [[ -n "$PRE_DOWNLOADED_LLAMACPP" ]]; then
            echo "  ✅ CPU models (llama.cpp) - available"  
        else
            echo "  ❌ CPU models (llama.cpp) - missing"
        fi
        if [[ -n "$PRE_DOWNLOADED_EMBEDDING" ]]; then
            echo "  ✅ Embedding models - available"
        else
            echo "  ❌ Embedding models - missing"
        fi
    fi
    echo ""
    echo "Pre-downloading benefits:"
    echo "  • Uses aria2c with 16 parallel connections (5-10x faster)"
    echo "  • Models persist in /var/lib/llmapi/models/ across reinstalls"
    echo "  • Can resume interrupted downloads"
    echo "  • Download different model sizes/quantizations"
    echo ""
    echo "Options:"
    echo "  1) Download additional models (recommended)"
    echo "  2) Continue with current models"
    echo "  3) Exit and download manually"
    echo ""
    read -p "Choose an option [1/2/3]: " download_choice
        case "$download_choice" in
            1)
                echo ""
                echo "🚀 Launching model download manager..."
                echo ""
                sudo "$SCRIPT_DIR/download-models.sh"
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
    case "$download_choice" in
        1)
            echo ""
            echo "🚀 Launching model download manager..."
            echo ""
            # Create the directory first
            sudo mkdir -p "$PRE_DOWNLOAD_DIR"
            sudo "$SCRIPT_DIR/download-models.sh"
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
# Default to Qwen2.5-14B (same as vLLM) for consistent responses across backends
LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
LLAMACPP_MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "🧠 Choose CPU/RAM model (llama.cpp - GGUF format):"
    echo ""
    echo -e "  ${GREEN}Recommended (same as GPU for consistent responses):${NC}"
    echo "  1. Qwen2.5-14B (Q4_K_M)   - ~10GB RAM, matches GPU model ⭐"
    echo "  2. Qwen2.5-14B (Q8_0)     - ~16GB RAM, higher quality version"
    echo ""
    echo "  Alternative Models:"
    echo "  3. Llama-3.1-8B (Q8)      - ~10GB RAM, fast and good quality"
    echo "  4. Llama-3.1-70B (Q4_K_M) - ~45GB RAM, excellent quality"
    echo "  5. Mixtral-8x7B (Q4_K_M)  - ~30GB RAM, fast MoE architecture"
    echo ""
    echo "  Custom Model:"
    echo "  6. Enter your own GGUF URL from HuggingFace"
    echo ""
    echo -e "  ${BLUE}Browse GGUF models: https://huggingface.co/models?library=gguf${NC}"
    echo ""
    read -p "Choose model [1-6, default: 1]: " CPU_MODEL_CHOICE
    CPU_MODEL_CHOICE="${CPU_MODEL_CHOICE:-1}"
    
    case "$CPU_MODEL_CHOICE" in
        1)
            # Qwen2.5-14B Q4 - same model as GPU vLLM (recommended)
            LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
            LLAMACPP_MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
            ;;
        2)
            # Qwen2.5-14B Q8 - higher quality version
            LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q8_0.gguf"
            LLAMACPP_MODEL_FILE="Qwen2.5-14B-Instruct-Q8_0.gguf"
            ;;
        3)
            LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
            LLAMACPP_MODEL_FILE="Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
            ;;
        4)
            LLAMACPP_MODEL_URL="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
            LLAMACPP_MODEL_FILE="Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
            ;;
        5)
            LLAMACPP_MODEL_URL="https://huggingface.co/TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF/resolve/main/mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"
            LLAMACPP_MODEL_FILE="mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"
            ;;
        6)
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
                echo -e "${YELLOW}No URL entered, using default Qwen2.5-14B${NC}"
                LLAMACPP_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf"
                LLAMACPP_MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
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

# Horizontal scaling info
if [ "$DEPLOY_MODE" = "1" ] && [ "$GPU_AVAILABLE" = true ]; then
    echo -e "${GREEN}✓ Horizontal scaling enabled${NC}"
    echo "   Requests route to: GPU → CPU (least-loaded backend)"
    echo "   Tip: Use same model family on GPU and CPU for consistent responses"
    echo ""
fi

# Default quotas
echo "📊 Default API quotas for new keys:"
read -p "Tokens per day [default: 100000]: " DEFAULT_TOKENS
DEFAULT_TOKENS="${DEFAULT_TOKENS:-100000}"
read -p "Requests per minute [default: 60]: " DEFAULT_RPM
DEFAULT_RPM="${DEFAULT_RPM:-60}"
echo ""

# Load centralized HF token management
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hf-token.sh"

# HuggingFace Token (optional but recommended for faster downloads)
HF_TOKEN=""
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "2" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo "🔑 HuggingFace Token (recommended for faster model downloads):"
    echo ""
    
    # Try to get existing token first
    if HF_TOKEN=$(get_hf_token false); then
        echo -e "   ${GREEN}✓ Using existing token (${HF_TOKEN:0:8}...)${NC}"
        echo "   To change or remove: ./lib/hf-token.sh set|delete"
    else
        echo "   A HuggingFace token removes rate limits and enables gated models."
        echo "   Get a free token at: https://huggingface.co/settings/tokens"
        echo "   (Leave empty to skip - downloads will be slower)"
        echo ""
        read -p "Enter HuggingFace token [optional]: " user_token
        if [ -n "$user_token" ]; then
            if [[ "$user_token" == hf_* ]]; then
                HF_TOKEN="$user_token"
                save_token "$HF_TOKEN"
                echo -e "   ${GREEN}✓ Token saved and will be reused in future installations${NC}"
            else
                echo -e "   ${YELLOW}⚠ Invalid token format (should start with 'hf_')${NC}"
                HF_TOKEN=""
            fi
        else
            echo -e "   ${YELLOW}⚠ No token - downloads may be rate-limited${NC}"
        fi
    fi
fi
echo ""

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

# Create namespace
echo "📦 Creating namespace and PriorityClasses..."
kubectl apply -f "$SCRIPT_DIR/../lib/priorityclass.yaml" 2>/dev/null || true
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
    
    # Wait for PVC to be bound with retry logic
    echo "   ⏳ Waiting for PVC $pvc_name to be ready..."
    
    local retry_count=0
    local max_retries=5
    local timeout=240  # 4 minutes per attempt (up to 20 minutes total)
    
    while [ $retry_count -lt $max_retries ]; do
        # Add detailed logging about PVC status
        echo "   🔍 Checking PVC status (attempt $((retry_count + 1))/$max_retries)..."
        local pvc_status=$(kubectl get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        echo "      PVC $pvc_name status: $pvc_status"
        
        if [ "$pvc_status" = "Bound" ]; then
            echo -e "   ${GREEN}✓ PVC $pvc_name is ready${NC}"
            break
        elif [ "$pvc_status" = "Pending" ]; then
            echo "      PVC is pending - waiting for storage provisioner..."
            # Check storage class and conditions
            kubectl describe pvc $pvc_name -n $NAMESPACE 2>/dev/null | grep -E "(StorageClass|Events|Conditions)" || true
        elif [ "$pvc_status" = "NotFound" ]; then
            echo "      PVC doesn't exist yet - this may be a timing issue"
            kubectl get pvc -n $NAMESPACE 2>/dev/null || echo "      No PVCs found in namespace"
        fi
        
        if kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/$pvc_name -n $NAMESPACE --timeout=${timeout}s 2>/dev/null; then
            echo -e "   ${GREEN}✓ PVC $pvc_name is ready${NC}"
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "   ⏳ PVC not ready, retrying ($retry_count/$max_retries) in 30 seconds..."
                sleep 30
            else
                echo -e "   ${YELLOW}⚠ PVC not ready after $max_retries attempts ($(($max_retries * $timeout / 60)) minutes total)${NC}"
                echo -e "   ${BLUE}💡 You can copy models later using: $SCRIPT_DIR/copy-predownloaded-models.sh${NC}"
                return 0
            fi
        fi
    done
    
    # Create a temporary pod to receive copied files (no hostPath needed)
    local copy_pod="model-copy-$model_type-$$"
    
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
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: copy
    image: busybox:1.35
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: false
      runAsNonRoot: true
      runAsUser: 1000
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
        ephemeral-storage: "5Gi"
      limits:
        memory: "4Gi"
        cpu: "2000m"
        ephemeral-storage: "150Gi"
  volumes:
  - name: models
    persistentVolumeClaim:
      claimName: $pvc_name
COPYPOD
    
    # Wait for pod to be ready
    kubectl wait --for=condition=Ready pod/$copy_pod -n $NAMESPACE --timeout=120s 2>/dev/null || {
        kubectl delete pod $copy_pod -n $NAMESPACE --force --grace-period=0 2>/dev/null || true
        echo -e "   ${YELLOW}⚠ Copy pod failed to start, will download during deployment${NC}"
        return 0
    }
    
    # Copy files using proven tar+pipe method (PodSecurity compliant)
    echo "   📤 Copying files (this may take a while for large models)..."
    
    local copy_success=false
    local copy_start_time=$(date +%s)
    
    # Map user selection to actual model files/directories and determine source path
    local target_model=""
    local actual_source_path=""
    
    if [[ "$model_type" == "vllm" ]]; then
        # Map VLLM_MODEL_NAME to actual directory name in /var/lib/llmapi/models/vllm/
        case "$VLLM_MODEL_NAME" in
            "qwen2.5-14b") target_model="qwen2.5-14b-awq" ;;
            "qwen2.5-7b") target_model="qwen2.5-7b-instruct" ;;
            "mistral-7b") target_model="mistral-7b-instruct" ;;
            "codellama-34b") target_model="codellama-34b-awq" ;;
            *) target_model="$VLLM_MODEL_NAME" ;;  # Fallback to exact name
        esac
        actual_source_path="/var/lib/llmapi/models/vllm/$target_model"
        echo "   🎯 Selected vLLM model: $VLLM_MODEL_NAME -> $target_model"
    elif [[ "$model_type" == "llamacpp" ]]; then
        # Use exact LLAMACPP_MODEL_FILE name
        target_model="$LLAMACPP_MODEL_FILE"
        actual_source_path="/var/lib/llmapi/models/llamacpp/$target_model"
        echo "   🎯 Selected llamacpp model: $target_model"
    else
        target_model="$(basename "$source_path")"
        actual_source_path="$source_path"
    fi
    
    # Verify the selected model exists and determine file structure
    local model_files=()
    if [[ "$model_type" == "vllm" ]]; then
        # vLLM models are always directories
        if [[ ! -d "$actual_source_path" ]]; then
            echo -e "   ${YELLOW}⚠ Selected vLLM model directory not found: $actual_source_path${NC}"
            echo "   📋 Available vLLM models:"
            ls -la "$(dirname "$actual_source_path")" 2>/dev/null | head -10 || echo "   Directory not found"
            echo -e "   ${YELLOW}⚠ Copy failed, will download during deployment${NC}"
            return 0
        fi
    elif [[ "$model_type" == "llamacpp" ]]; then
        # GGUF models can be single file or multiple files
        local base_model_name="${target_model%.*}"  # Remove .gguf extension
        local model_dir="$(dirname "$actual_source_path")"
        
        # Look for exact file first (case-sensitive)
        if [[ -f "$actual_source_path" ]]; then
            model_files=("$actual_source_path")
        else
            # Look for case-insensitive match first
            mapfile -t model_files < <(find "$model_dir" -iname "${target_model}" 2>/dev/null | head -1)
            
            # If no exact match, look for multi-part files (case-insensitive)
            if [[ ${#model_files[@]} -eq 0 ]]; then
                mapfile -t model_files < <(find "$model_dir" -iname "${base_model_name}*.gguf" 2>/dev/null | sort)
            fi
        fi
        
        if [[ ${#model_files[@]} -eq 0 ]]; then
            echo -e "   ${YELLOW}⚠ Selected llamacpp model not found: $target_model${NC}"
            echo "   📋 Available GGUF models:"
            ls -la "$model_dir"/*.gguf 2>/dev/null | head -10 || echo "   No GGUF files found"
            echo -e "   ${YELLOW}⚠ Copy failed, will download during deployment${NC}"
            return 0
        fi
        
        if [[ ${#model_files[@]} -gt 1 ]]; then
            echo "   📚 Detected multi-file GGUF model: ${#model_files[@]} parts"
        fi
    fi
    
    if [[ "$model_type" == "vllm" ]]; then
        # vLLM models (always directories with multiple files)
        local dir_size=$(du -sh "$actual_source_path" | cut -f1)
        echo "   📁 Copying vLLM directory: $target_model ($dir_size)"
        echo "   ⏳ Using tar+pipe method for reliable transfer..."
        
        # Create target directory first
        kubectl exec $copy_pod -n $NAMESPACE -- mkdir -p /models 2>/dev/null
        
        # Use tar+pipe method that worked perfectly for vLLM
        if command -v pv >/dev/null 2>&1; then
            # With progress monitoring
            if tar -cf - -C "$(dirname "$actual_source_path")" "$(basename "$actual_source_path")" | \
               pv -s $(du -sb "$actual_source_path" | cut -f1) | \
               kubectl exec -i $copy_pod -n $NAMESPACE -- tar -xf - -C /models 2>/dev/null; then
                copy_success=true
                echo "   ✓ vLLM directory copied successfully"
            else
                echo -e "   ${YELLOW}⚠ vLLM directory copy failed${NC}"
            fi
        else
            # Without progress monitoring
            if tar -cf - -C "$(dirname "$actual_source_path")" "$(basename "$actual_source_path")" | \
               kubectl exec -i $copy_pod -n $NAMESPACE -- tar -xf - -C /models 2>/dev/null; then
                copy_success=true
                echo "   ✓ vLLM directory copied successfully"
            else
                echo -e "   ${YELLOW}⚠ vLLM directory copy failed${NC}"
            fi
        fi
    else
        # GGUF models (single file OR multiple files)
        local total_size=0
        for file in "${model_files[@]}"; do
            total_size=$((total_size + $(stat -c%s "$file")))
        done
        local human_size=$(numfmt --to=iec --suffix=B $total_size)
        
        if [[ ${#model_files[@]} -eq 1 ]]; then
            echo "   📄 Copying single GGUF file: $target_model ($human_size)"
        else
            echo "   � Copying multi-part GGUF model: $target_model (${#model_files[@]} parts, $human_size total)"
        fi
        echo "   ⏳ Using tar+pipe method for large files..."
        
        # Create target directory first
        kubectl exec $copy_pod -n $NAMESPACE -- mkdir -p /models 2>/dev/null
        
        # Create tar archive of all model files
        local tar_args=()
        local base_dir="$(dirname "${model_files[0]}")"
        for file in "${model_files[@]}"; do
            tar_args+=("$(basename "$file")")
        done
        
        # Use tar for GGUF files to avoid kubectl exec streaming limits
        if command -v pv >/dev/null 2>&1; then
            # With progress monitoring
            if tar -cf - -C "$base_dir" "${tar_args[@]}" | \
               pv -s $total_size | \
               kubectl exec -i $copy_pod -n $NAMESPACE -- tar -xf - -C /models 2>/dev/null; then
                copy_success=true
                echo "   ✓ GGUF model copied successfully"
            else
                echo -e "   ${YELLOW}⚠ GGUF model copy failed${NC}"
            fi
        else
            # Without progress monitoring  
            if tar -cf - -C "$base_dir" "${tar_args[@]}" | \
               kubectl exec -i $copy_pod -n $NAMESPACE -- tar -xf - -C /models 2>/dev/null; then
                copy_success=true
                echo "   ✓ GGUF model copied successfully"
            else
                echo -e "   ${YELLOW}⚠ GGUF model copy failed${NC}"
            fi
        fi
    fi
    
    local copy_end_time=$(date +%s)
    local copy_duration=$((copy_end_time - copy_start_time))
    echo "   ⏱️ Copy operation took ${copy_duration}s"
    
    # Verify copy
    if [ "$copy_success" = true ]; then
        echo "   🔍 Verifying copied files..."
        kubectl exec $copy_pod -n $NAMESPACE -- ls -la /models/ 2>/dev/null || true
        echo -e "   ${GREEN}✓ Pre-downloaded model copied to PVC${NC}"
    else
        echo -e "   ${YELLOW}⚠ Copy failed, will download during deployment${NC}"
    fi
    
    # Cleanup
    kubectl delete pod $copy_pod -n $NAMESPACE --force --grace-period=0 2>/dev/null || true
}

# Note: Model copying will happen AFTER PVCs are created during service deployment

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
  EMBEDDING_MODEL_FILE: "nomic-embed-text-v1.5.Q8_0.gguf"
  DEFAULT_REQUESTS_PER_MINUTE: "$DEFAULT_RPM"
  DEFAULT_TOKENS_PER_DAY: "$DEFAULT_TOKENS"
  OLLAMA_URL: "http://ollama:11434"
  LAZY_LOAD_ENABLED: "true"
  LAZY_LOAD_BACKEND: "ollama"
  # Horizontal scaling: route to least-loaded backend (GPU → CPU)
  HORIZONTAL_SCALING: "true"
  MAX_INFLIGHT_PER_BACKEND: "32"
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
    
    # Setup predownload directory for pre-downloaded models
    # Init container will check /predownload first before downloading
    if [[ -n "$PRE_DOWNLOADED_VLLM" ]]; then
        echo ""
        echo "   📦 Setting up pre-downloaded vLLM models..."
        
        # Create predownload directory (mounted as hostPath in init container)
        vllm_predownload="/var/lib/llmapi/models/vllm"
        sudo mkdir -p "$vllm_predownload"
        
        # Fix permissions on existing models (in case they were downloaded by user)
        if [ -d "/var/lib/llmapi/models" ]; then
            echo "   🔧 Ensuring correct permissions on model directory..."
            sudo chown -R root:root /var/lib/llmapi/models 2>/dev/null || true
        fi
        
        # Check if model needs to be copied or is already in place
        if [ -d "$PRE_DOWNLOADED_VLLM" ]; then
            model_name=$(basename "$PRE_DOWNLOADED_VLLM")
            destination="$vllm_predownload/$model_name"
            
            # Normalize paths by removing trailing slashes for comparison
            source_normalized="${PRE_DOWNLOADED_VLLM%/}"
            dest_normalized="${destination%/}"
            
            # Check if model is already in the correct location
            if [ "$source_normalized" = "$dest_normalized" ]; then
                # Model is already in hostPath, just verify it
                model_size=$(du -sh "$PRE_DOWNLOADED_VLLM" 2>/dev/null | cut -f1)
                echo -e "   ${GREEN}✓ Model already in hostPath: $model_name ($model_size)${NC}"
                echo "   💡 Init container will copy this to PVC (~2 min startup)"
            else
                # Model is in a different location, copy it
                echo "   📁 Copying $model_name to $vllm_predownload..."
                if sudo cp -r "$PRE_DOWNLOADED_VLLM" "$vllm_predownload/" 2>/dev/null; then
                    copied_size=$(du -sh "$destination" 2>/dev/null | cut -f1)
                    echo -e "   ${GREEN}✓ Model staged for init container ($copied_size)${NC}"
                    echo "   💡 Init container will copy this to PVC (~2 min startup)"
                else
                    echo -e "   ${YELLOW}⚠ Failed to copy model to predownload${NC}"
                    echo "   💡 vLLM will download directly from HuggingFace (~5 min)"
                fi
            fi
        fi
        
        # Automatically label and sync models to worker nodes if any exist
        echo ""
        echo "   🔄 Checking for worker nodes to sync models..."
        worker_nodes=$(kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        
        if [[ -n "$worker_nodes" ]]; then
            echo "   📡 Found worker nodes: $worker_nodes"
            
            # Auto-label worker nodes with Tailscale IPs and SSH usernames (required for SSH sync)
            echo "   🏷️  Labeling worker nodes with Tailscale IPs and SSH usernames..."
            for node in $worker_nodes; do
                # Check if node already has worker-ip label
                existing_ip=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.mynodeone\.io/worker-ip}' 2>/dev/null)
                existing_user=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
                
                if [[ -n "$existing_ip" && -n "$existing_user" ]]; then
                    echo "      ✓ $node already labeled: $existing_ip (user: $existing_user)"
                else
                    # Get Tailscale IP for this node
                    ts_ip=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName == \"$node\") | .TailscaleIPs[0]" 2>/dev/null)
                    
                    if [[ -n "$ts_ip" && "$ts_ip" != "null" ]]; then
                        # Label with IP if not already set
                        if [[ -z "$existing_ip" ]]; then
                            kubectl label node "$node" mynodeone.io/worker-ip="$ts_ip" --overwrite 2>/dev/null
                        fi
                        
                        # Check if SSH username is configured
                        if [[ -z "$existing_user" ]]; then
                            echo -e "      ${YELLOW}⚠ $node needs SSH username label for model sync${NC}"
                            echo "      💡 Set SSH user label: kubectl label node $node mynodeone.io/ssh-user=<USERNAME>"
                            echo "      💡 Then set up SSH keys: ssh-copy-id <username>@$ts_ip"
                            echo "      💡 This should have been done during worker node setup (add-worker-node.sh)"
                        else
                            echo "      ✓ $node labeled: $ts_ip (user: $existing_user)"
                        fi
                    else
                        echo -e "      ${YELLOW}⚠ Could not detect Tailscale IP for $node${NC}"
                        echo "      💡 Manual label: kubectl label node $node mynodeone.io/worker-ip=<TAILSCALE_IP> mynodeone.io/ssh-user=<USERNAME>"
                    fi
                fi
            done
            
            echo "   ✅ Worker nodes labeled."
            
            # Prompt for model sync strategy
            echo ""
            echo "   ❓ Model Provisioning Strategy for Workers:"
            echo "      1) Sync from Control Plane (Faster if cached, requires SSH)"
            echo "      2) Download from HuggingFace (Simpler, no SSH dependency)"
            read -p "      Select option [1/2] (default: 2): " SYNC_OPT
            SYNC_OPT=${SYNC_OPT:-2}
            
            if [[ "$SYNC_OPT" == "1" ]]; then
                echo "   🚀 Syncing models to workers..."
                
                # Defensive: Fix SSH permissions on workers before syncing
                echo "      🛡️  Verifying worker SSH permissions..."
                for node in $worker_nodes; do
                    # Get info from labels
                    node_ip=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.mynodeone\.io/worker-ip}' 2>/dev/null)
                    node_user=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.mynodeone\.io/ssh-user}' 2>/dev/null)
                    
                    if [[ -n "$node_ip" && -n "$node_user" ]]; then
                        echo "         • Fixing permissions on $node ($node_user@$node_ip)..."
                        # Run the fix command
                        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$node_user@$node_ip" \
                            "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && sudo chown -R $node_user:$node_user ~/.ssh" || \
                            echo "         ⚠️  Could not auto-fix permissions for $node (SSH failed)"
                    fi
                done

                # Run sync script with full output for debugging
                echo ""
                if "$SCRIPT_DIR/sync-models-to-workers.sh"; then
                    echo ""
                    echo -e "   ${GREEN}✓ Models synced to worker nodes${NC}"
                    echo "   💡 Workers will use local models (~2 min startup)"
                else
                    echo ""
                    echo -e "   ${YELLOW}⚠ Model sync failed or incomplete${NC}"
                    echo "   💡 Workers will download from HuggingFace if needed (~5-10 min)"
                    echo "   💡 To retry sync: ./scripts/apps/llmapi/sync-models-to-workers.sh"
                fi
                echo ""
            else
                echo "   ⬇️  Workers will download models from HuggingFace on startup."
                echo "   💡 This may take 5-10 minutes per node depending on internet speed."
            fi
        else
            echo "   💡 No worker nodes found - single node deployment"
        fi
    else
        # Create empty predownload directory for future model placement
        sudo mkdir -p /var/lib/llmapi/models/vllm 2>/dev/null || true
        echo ""
        echo "   💡 No pre-downloaded models provided"
        echo "   💡 vLLM will download from HuggingFace on first start (~5-10 min)"
        echo "   💡 To use pre-download: ./scripts/apps/llmapi/download-models.sh"
    fi
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
    
    # Copy pre-downloaded models after PVC creation
    if [[ -n "$PRE_DOWNLOADED_LLAMACPP" ]]; then
        echo ""
        echo "   📦 Copying pre-downloaded llamacpp model to PVC..."
        if copy_predownloaded_models "llamacpp" "$PRE_DOWNLOADED_LLAMACPP" "llamacpp-models"; then
            echo "   💡 Pre-copied model detected. Init container will skip download automatically."
            echo "   📄 Model file: $LLAMACPP_MODEL_FILE"
        fi
    fi
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
# Prometheus + Grafana Monitoring Integration
# =============================================================================

echo ""
echo "📊 Setting up Prometheus + Grafana monitoring..."

# Check if monitoring namespace exists
if kubectl get namespace monitoring &>/dev/null; then
    echo "   ✓ Monitoring namespace found"
    
    # Wait for gateway service to be created first
    sleep 5
    
    # Create secret with Prometheus API key for metrics scraping (created later in script)
    # This will be created after API keys are generated
    
    # Deploy ServiceMonitor for Prometheus scraping
    echo "   Deploying ServiceMonitor for Prometheus..."
    kubectl apply -f "$SCRIPT_DIR/manifests/servicemonitor.yaml" 2>/dev/null || \
        echo "   ⚠ ServiceMonitor deployment will be retried after API keys are created"
    
    # Deploy Grafana dashboard
    echo "   Deploying Grafana dashboard..."
    kubectl apply -f "$SCRIPT_DIR/manifests/grafana-dashboard-configmap.yaml"
    
    echo "   ✓ Monitoring integration configured"
    echo "   Access Grafana dashboard: 'LLM API Gateway'"
else
    echo "   ⚠ Monitoring namespace not found - skipping Prometheus/Grafana integration"
    echo "   Install kube-prometheus-stack to enable monitoring"
fi

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
    # Check if vLLM pod is already running
    if kubectl get pods -n "$NAMESPACE" -l app=vllm --field-selector=status.phase=Running 2>/dev/null | grep -q vllm; then
        echo -e "   ${GREEN}✓ vLLM is ready${NC}"
    elif kubectl wait --for=condition=available --timeout=60s statefulset/vllm -n "$NAMESPACE" 2>/dev/null; then
        echo -e "   ${GREEN}✓ vLLM is ready${NC}"
    else
        echo "   📥 vLLM model download may take 10-30 minutes for first install..."
        echo -e "   ${YELLOW}vLLM is downloading model. Monitor: kubectl logs -n $NAMESPACE statefulset/vllm -f${NC}"
    fi
fi

# Wait for llama.cpp if deployed (model download can take 5-15 minutes)
if [ "$DEPLOY_MODE" = "1" ] || [ "$DEPLOY_MODE" = "3" ]; then
    echo ""
    # Check if llama.cpp pod is already running
    if kubectl get pods -n "$NAMESPACE" -l app=llamacpp --field-selector=status.phase=Running 2>/dev/null | grep -q llamacpp; then
        echo -e "   ${GREEN}✓ llama.cpp is ready${NC}"
    elif kubectl wait --for=condition=available --timeout=60s deployment/llamacpp -n "$NAMESPACE" 2>/dev/null; then
        echo -e "   ${GREEN}✓ llama.cpp is ready${NC}"
    else
        echo "   📥 llama.cpp model download may take 5-15 minutes for first install..."
        echo -e "   ${YELLOW}llama.cpp is downloading model. Monitor: kubectl logs -n $NAMESPACE deploy/llamacpp -c model-downloader -f${NC}"
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
# Create initial API keys (with retries)
# =============================================================================

echo ""
echo "🔑 Creating API keys..."

# Helper function to create API key
create_api_key() {
    local name="$1"
    local scopes="$2"
    local rpm="$3"
    local tokens="$4"
    
    local key_id=$(openssl rand -hex 16)
    local api_key="sk-mynodeone-${key_id}"
    local created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Convert comma-separated scopes to JSON array
    local scopes_json=$(echo "$scopes" | sed 's/,/","/g' | sed 's/^/["/;s/$/"]/')
    
    # Store in Redis with retries
    for i in {1..5}; do
        if kubectl exec -n "$NAMESPACE" deploy/redis -- redis-cli SET "apikey:${api_key}" \
            "{\"name\":\"$name\",\"scopes\":$scopes_json,\"requests_per_minute\":$rpm,\"tokens_per_day\":$tokens,\"created_at\":\"$created_at\"}" \
            &>/dev/null; then
            echo "$api_key"
            return 0
        fi
        sleep 2
    done
    
    return 1
}

# Generate 3 API keys with different scopes
ADMIN_KEY=$(create_api_key "admin-ui" "admin" 1000 10000000)
PROMETHEUS_KEY=$(create_api_key "prometheus" "metrics" 100 1000000)
API_KEY=$(create_api_key "default" "inference" 100 1000000)

if [ -n "$ADMIN_KEY" ] && [ -n "$PROMETHEUS_KEY" ] && [ -n "$API_KEY" ]; then
    echo -e "${GREEN}✓ API keys created${NC}"
    
    # Save keys to files
    mkdir -p ~/.mynodeone
    echo "$ADMIN_KEY" > ~/.mynodeone/llmapi-admin-key
    echo "$PROMETHEUS_KEY" > ~/.mynodeone/llmapi-prometheus-key
    echo "$API_KEY" > ~/.mynodeone/llmapi-key
    chmod 600 ~/.mynodeone/llmapi-admin-key
    chmod 600 ~/.mynodeone/llmapi-prometheus-key
    chmod 600 ~/.mynodeone/llmapi-key
    echo "   (saved to ~/.mynodeone/llmapi-admin-key, llmapi-prometheus-key, llmapi-key)"
    
    # Create Kubernetes secret for Prometheus scraping
    if kubectl get namespace monitoring &>/dev/null; then
        echo "   Creating Prometheus bearer token secret..."
        kubectl create secret generic llmapi-prometheus-token -n $NAMESPACE \
            --from-literal=token="$PROMETHEUS_KEY" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        # Now deploy/update ServiceMonitor with the secret
        kubectl apply -f "$SCRIPT_DIR/manifests/servicemonitor.yaml"
    fi
else
    echo -e "${YELLOW}⚠ Failed to create some API keys in Redis${NC}"
    echo "   You can create them manually:"
    echo "   ./scripts/apps/llmapi/manage-keys.sh create --name 'admin' --scopes 'admin'"
    echo "   ./scripts/apps/llmapi/manage-keys.sh create --name 'prometheus' --scopes 'metrics'"
    echo "   ./scripts/apps/llmapi/manage-keys.sh create --name 'default' --scopes 'inference'"
fi

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
echo "🔑 API Keys Generated:"
echo ""
echo "   1. Admin Key (admin scope - for Admin UI):"
echo "      $ADMIN_KEY"
echo "      Access: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/admin"
echo ""
echo "   2. Prometheus Key (metrics scope - for monitoring):"
echo "      $PROMETHEUS_KEY"
echo "      Endpoints: /metrics, /health/backends"
echo ""
echo "   3. Default Key (inference scope - for LLM API):"
echo "      $API_KEY"
echo "      Endpoints: /v1/chat/completions, /v1/embeddings, /v1/models"
echo ""
echo "   Keys saved to: ~/.mynodeone/llmapi-*-key"
echo ""
echo "🧪 Test the API:"
echo ""
echo "   # List models"
echo "   curl -H \"Authorization: Bearer $API_KEY\" \\"
echo "        http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1/models"
echo ""
echo "   # Chat completion"
echo "   curl -H \"Authorization: Bearer $API_KEY\" \\"
echo "        -H \"Content-Type: application/json\" \\"
echo "        -d '{\"model\":\"$VLLM_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}' \\"
echo "        http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1/chat/completions"
echo ""
echo "   # Check metrics (requires prometheus key)"
echo "   curl -H \"Authorization: Bearer $PROMETHEUS_KEY\" \\"
echo "        http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/metrics"
echo ""
echo "📚 Python/OpenAI SDK:"
echo ""
echo "   from openai import OpenAI"
echo "   client = OpenAI("
echo "       base_url=\"http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/v1\","
echo "       api_key=\"$API_KEY\"  # inference key"
echo "   )"
echo ""
echo "🎛️  Admin UI:"
echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local/admin"
echo ""
echo "   Authentication: Add header \"Authorization: Bearer $ADMIN_KEY\""
echo "   (Old HTTP Basic Auth removed - use admin API key instead)"
echo ""
echo "   Features:"
echo "   • Download/manage Ollama models"
echo "   • Change vLLM/llama.cpp models + context/memory settings"
echo "   • Start/stop llama.cpp (free RAM when not needed)"
echo "   • Manage API keys and view usage"
echo "   • View key scopes and permissions"
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
