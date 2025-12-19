#!/bin/bash

###############################################################################
# LLM API Model Management
# 
# Add, remove, and configure models for the LLM API service.
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="llmapi"

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list              List configured models"
    echo "  add-vllm          Add a model to vLLM (GPU)"
    echo "  add-llamacpp      Add a model to llama.cpp (CPU)"
    echo "  add-embedding     Add an embedding model"
    echo "  remove            Remove a model"
    echo "  set-default       Set the default model"
    echo ""
    echo "Options for 'add-vllm':"
    echo "  --model <hf-model>    HuggingFace model ID"
    echo "  --name <api-name>     Name to expose in API"
    echo "  --quantization <q>    Quantization method (awq, gptq, none)"
    echo ""
    echo "Options for 'add-llamacpp':"
    echo "  --url <gguf-url>      URL to GGUF model file"
    echo "  --name <api-name>     Name to expose in API"
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 add-vllm --model 'Qwen/Qwen2.5-7B-Instruct' --name 'qwen2.5-7b'"
    echo "  $0 add-llamacpp --url 'https://huggingface.co/.../model.gguf' --name 'llama3-70b'"
}

# Check prerequisites
check_prereqs() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found${NC}"
        exit 1
    fi
    
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        echo -e "${RED}Error: LLM API not installed. Run install-llmapi.sh first.${NC}"
        exit 1
    fi
}

# List models
cmd_list() {
    echo ""
    echo -e "${BLUE}Configured Models${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo -e "${GREEN}vLLM (GPU) Models:${NC}"
    if kubectl get statefulset vllm -n "$NAMESPACE" &>/dev/null; then
        # Get model from ConfigMap
        MODEL=$(kubectl get configmap vllm-config -n "$NAMESPACE" -o jsonpath='{.data.MODEL_NAME}' 2>/dev/null || echo "N/A")
        echo "   • $MODEL"
    else
        echo "   (vLLM not deployed)"
    fi
    echo ""
    
    echo -e "${GREEN}llama.cpp (CPU) Models:${NC}"
    if kubectl get deployment llamacpp -n "$NAMESPACE" &>/dev/null; then
        MODEL_FILE=$(kubectl get configmap llamacpp-config -n "$NAMESPACE" -o jsonpath='{.data.MODEL_FILE}' 2>/dev/null || echo "N/A")
        echo "   • $MODEL_FILE"
    else
        echo "   (llama.cpp not deployed)"
    fi
    echo ""
    
    echo -e "${GREEN}Embedding Models:${NC}"
    if kubectl get deployment embedding -n "$NAMESPACE" &>/dev/null; then
        MODEL_FILE=$(kubectl get configmap embedding-config -n "$NAMESPACE" -o jsonpath='{.data.MODEL_FILE}' 2>/dev/null || echo "N/A")
        echo "   • $MODEL_FILE"
    else
        echo "   (Embedding service not deployed)"
    fi
    echo ""
}

# Add vLLM model
cmd_add_vllm() {
    local model=""
    local name=""
    local quantization="awq"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model)
                model="$2"
                shift 2
                ;;
            --name)
                name="$2"
                shift 2
                ;;
            --quantization)
                quantization="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$model" ]; then
        echo "Available model presets:"
        echo "  1. Qwen/Qwen2.5-14B-Instruct-AWQ"
        echo "  2. Qwen/Qwen2.5-7B-Instruct"
        echo "  3. mistralai/Mistral-7B-Instruct-v0.3"
        echo "  4. TheBloke/CodeLlama-34B-Instruct-AWQ"
        echo "  5. Custom"
        read -p "Choose [1-5]: " choice
        case "$choice" in
            1) model="Qwen/Qwen2.5-14B-Instruct-AWQ"; name="qwen2.5-14b" ;;
            2) model="Qwen/Qwen2.5-7B-Instruct"; name="qwen2.5-7b"; quantization="none" ;;
            3) model="mistralai/Mistral-7B-Instruct-v0.3"; name="mistral-7b"; quantization="none" ;;
            4) model="TheBloke/CodeLlama-34B-Instruct-AWQ"; name="codellama-34b" ;;
            5) read -p "Enter HuggingFace model ID: " model
               read -p "Enter API name: " name ;;
        esac
    fi
    
    if [ -z "$name" ]; then
        name=$(echo "$model" | sed 's|.*/||' | tr '[:upper:]' '[:lower:]')
    fi
    
    echo ""
    echo "Updating vLLM configuration..."
    echo "   Model: $model"
    echo "   API Name: $name"
    echo "   Quantization: $quantization"
    
    # Update ConfigMap
    kubectl patch configmap vllm-config -n "$NAMESPACE" --type merge \
        -p "{\"data\":{\"MODEL_NAME\":\"$model\",\"QUANTIZATION\":\"$quantization\"}}"
    
    # Update StatefulSet args
    kubectl patch statefulset vllm -n "$NAMESPACE" --type='json' \
        -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--model\",\"$model\",\"--max-model-len\",\"8192\",\"--gpu-memory-utilization\",\"0.90\",\"--quantization\",\"$quantization\",\"--host\",\"0.0.0.0\",\"--port\",\"8000\",\"--served-model-name\",\"$name\",\"--trust-remote-code\"]}]"
    
    echo ""
    echo -e "${GREEN}✓ vLLM model updated${NC}"
    echo "   Restarting vLLM to load new model..."
    
    kubectl rollout restart statefulset/vllm -n "$NAMESPACE"
    
    echo ""
    echo "   Note: Model download may take 10-60 minutes."
    echo "   Monitor: kubectl logs -n $NAMESPACE -l app=vllm -f"
}

# Add llama.cpp model
cmd_add_llamacpp() {
    local url=""
    local name=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                url="$2"
                shift 2
                ;;
            --name)
                name="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$url" ]; then
        echo "Available model presets:"
        echo "  1. Meta-Llama-3.1-70B-Instruct Q4_K_M (~45GB)"
        echo "  2. Meta-Llama-3.1-70B-Instruct Q5_K_M (~55GB)"
        echo "  3. Mixtral-8x7B Q4_K_M (~30GB)"
        echo "  4. Meta-Llama-3.1-8B Q8 (~10GB)"
        echo "  5. Custom GGUF URL"
        read -p "Choose [1-5]: " choice
        case "$choice" in
            1) url="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
               name="llama3.1-70b-q4" ;;
            2) url="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q5_K_M.gguf"
               name="llama3.1-70b-q5" ;;
            3) url="https://huggingface.co/TheBloke/Mixtral-8x7B-Instruct-v0.1-GGUF/resolve/main/mixtral-8x7b-instruct-v0.1.Q4_K_M.gguf"
               name="mixtral-8x7b" ;;
            4) url="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q8_0.gguf"
               name="llama3.1-8b" ;;
            5) read -p "Enter GGUF URL: " url
               read -p "Enter API name: " name ;;
        esac
    fi
    
    local filename=$(basename "$url")
    if [ -z "$name" ]; then
        name="${filename%.gguf}"
    fi
    
    echo ""
    echo "Updating llama.cpp configuration..."
    echo "   URL: $url"
    echo "   Filename: $filename"
    echo "   API Name: $name"
    
    # Update ConfigMap
    kubectl patch configmap llamacpp-config -n "$NAMESPACE" --type merge \
        -p "{\"data\":{\"MODEL_URL\":\"$url\",\"MODEL_FILE\":\"$filename\"}}"
    
    # Delete existing pod to trigger re-download
    echo ""
    echo -e "${YELLOW}Restarting llama.cpp to download new model...${NC}"
    kubectl rollout restart deployment/llamacpp -n "$NAMESPACE"
    
    echo ""
    echo -e "${GREEN}✓ llama.cpp model updated${NC}"
    echo "   Note: Model download may take 10-60 minutes."
    echo "   Monitor: kubectl logs -n $NAMESPACE -l app=llamacpp -f"
}

# Add embedding model
cmd_add_embedding() {
    echo "Available embedding models:"
    echo "  1. nomic-embed-text-v1.5 Q8 (recommended)"
    echo "  2. bge-m3 (multilingual)"
    echo "  3. Custom GGUF URL"
    read -p "Choose [1-3]: " choice
    
    local url=""
    local filename=""
    
    case "$choice" in
        1) url="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf"
           filename="nomic-embed-text-v1.5.Q8_0.gguf" ;;
        2) url="https://huggingface.co/BAAI/bge-m3-GGUF/resolve/main/bge-m3-q8_0.gguf"
           filename="bge-m3-q8_0.gguf" ;;
        3) read -p "Enter GGUF URL: " url
           filename=$(basename "$url") ;;
    esac
    
    echo ""
    echo "Updating embedding configuration..."
    
    kubectl patch configmap embedding-config -n "$NAMESPACE" --type merge \
        -p "{\"data\":{\"MODEL_URL\":\"$url\",\"MODEL_FILE\":\"$filename\"}}"
    
    kubectl rollout restart deployment/embedding -n "$NAMESPACE"
    
    echo ""
    echo -e "${GREEN}✓ Embedding model updated${NC}"
    echo "   Monitor: kubectl logs -n $NAMESPACE -l app=embedding -f"
}

# Main
check_prereqs

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    list)
        cmd_list
        ;;
    add-vllm)
        cmd_add_vllm "$@"
        ;;
    add-llamacpp)
        cmd_add_llamacpp "$@"
        ;;
    add-embedding)
        cmd_add_embedding "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo -e "${RED}Unknown command: $command${NC}"
        usage
        exit 1
        ;;
esac
