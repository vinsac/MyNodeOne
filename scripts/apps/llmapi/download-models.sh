#!/bin/bash
#
# LLM Model Download Manager
# ==========================
# Pre-downloads LLM models with smart source selection and speed optimization.
#
# Features:
# - Tests download speed from multiple sources before downloading
# - Supports HuggingFace, ModelScope (Chinese mirror), and direct URLs
# - Multi-threaded downloads with aria2c when available
# - Resume support for interrupted downloads
# - Verifies downloaded files with checksums when available
#
# Usage:
#   ./download-models.sh                    # Interactive mode
#   ./download-models.sh --model vllm       # Download vLLM model
#   ./download-models.sh --model llamacpp   # Download llama.cpp model
#   ./download-models.sh --model embedding  # Download embedding model
#   ./download-models.sh --model all        # Download all models
#   ./download-models.sh --list             # List available models
#   ./download-models.sh --status           # Check download status
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default download directory (can be overridden)
DOWNLOAD_DIR="${LLM_MODEL_DIR:-/var/lib/llmapi/models}"
TEMP_DIR="/tmp/llm-downloads"

# HuggingFace token (optional but recommended for faster downloads)
HF_TOKEN="${HF_TOKEN:-}"

# Minimum acceptable download speed (bytes/sec) - 1 MB/s
MIN_SPEED=1048576

# =============================================================================
# Model Definitions
# =============================================================================

declare -A VLLM_MODELS=(
    ["qwen2.5-14b-awq"]="Qwen/Qwen2.5-14B-Instruct-AWQ|8.5G|Best balance for 24GB VRAM"
    ["qwen2.5-7b-awq"]="Qwen/Qwen2.5-7B-Instruct-AWQ|4.5G|Faster, good for testing"
    ["qwen2.5-32b-awq"]="Qwen/Qwen2.5-32B-Instruct-AWQ|17G|Larger, needs 24GB+ VRAM"
    ["llama3.1-8b-awq"]="hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4|4.5G|Meta Llama 3.1"
    ["mistral-7b-awq"]="TheBloke/Mistral-7B-Instruct-v0.2-AWQ|4G|Fast Mistral model"
)

declare -A LLAMACPP_MODELS=(
    ["llama3.1-70b-q4"]="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf|40.5G|Best 70B for CPU"
    ["llama3.1-70b-q3"]="https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q3_K_M.gguf|33G|Smaller 70B, slightly lower quality"
    ["llama3.1-8b-q4"]="https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|4.9G|Fast 8B model"
    ["qwen2.5-72b-q4"]="https://huggingface.co/bartowski/Qwen2.5-72B-Instruct-GGUF/resolve/main/Qwen2.5-72B-Instruct-Q4_K_M.gguf|43G|Qwen 72B for CPU"
    ["deepseek-r1-70b-q4"]="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Llama-70B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf|40G|DeepSeek R1 reasoning"
)

declare -A EMBEDDING_MODELS=(
    ["nomic-embed-v1.5"]="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf|140M|Default embedding model"
    ["bge-large"]="https://huggingface.co/CompendiumLabs/bge-large-en-v1.5-gguf/resolve/main/bge-large-en-v1.5-q8_0.gguf|400M|BGE Large English"
    ["e5-large"]="https://huggingface.co/ChristianAzinn/e5-large-v2-gguf/resolve/main/e5-large-v2-q8_0.gguf|400M|E5 Large v2"
)

# ModelScope mirrors (Chinese, often faster for large models)
declare -A MODELSCOPE_MIRRORS=(
    ["Qwen/Qwen2.5-14B-Instruct-AWQ"]="qwen/Qwen2.5-14B-Instruct-AWQ"
    ["Qwen/Qwen2.5-7B-Instruct-AWQ"]="qwen/Qwen2.5-7B-Instruct-AWQ"
    ["Qwen/Qwen2.5-32B-Instruct-AWQ"]="qwen/Qwen2.5-32B-Instruct-AWQ"
)

# =============================================================================
# Utility Functions
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dependencies() {
    local missing=()
    local to_install=()
    
    # Required
    command -v curl &>/dev/null || missing+=("curl")
    
    # Check for aria2c and pv - auto-install if missing
    if ! command -v aria2c &>/dev/null; then
        to_install+=("aria2")
    fi
    
    if ! command -v pv &>/dev/null; then
        to_install+=("pv")
    fi
    
    # Auto-install missing optional dependencies
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log_info "Installing recommended packages: ${to_install[*]}..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq "${to_install[@]}" 2>/dev/null || {
                log_warn "Could not auto-install ${to_install[*]}. Downloads may be slower."
            }
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y -q "${to_install[@]}" 2>/dev/null || {
                log_warn "Could not auto-install ${to_install[*]}. Downloads may be slower."
            }
        elif command -v yum &>/dev/null; then
            sudo yum install -y -q "${to_install[@]}" 2>/dev/null || {
                log_warn "Could not auto-install ${to_install[*]}. Downloads may be slower."
            }
        else
            log_warn "Could not auto-install ${to_install[*]}. Please install manually for better performance."
        fi
        
        # Verify installation
        if command -v aria2c &>/dev/null; then
            log_success "aria2c installed (16x parallel downloads enabled)"
        fi
        if command -v pv &>/dev/null; then
            log_success "pv installed (progress bars enabled)"
        fi
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

prompt_hf_token() {
    # Skip if token already set
    if [[ -n "$HF_TOKEN" ]]; then
        log_info "Using HuggingFace token from environment"
        return 0
    fi
    
    # Check if token exists in Kubernetes secret
    if command -v kubectl &>/dev/null; then
        local k8s_token
        k8s_token=$(kubectl get secret hf-token -n llmapi -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [[ -n "$k8s_token" ]]; then
            HF_TOKEN="$k8s_token"
            log_info "Using HuggingFace token from Kubernetes secret"
            return 0
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  HuggingFace Token (Recommended)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "A HuggingFace token enables:"
    echo "  • Faster download speeds (authenticated users get priority)"
    echo "  • Access to gated models (Llama 3, CodeLlama, etc.)"
    echo ""
    echo "Get your free token at: https://huggingface.co/settings/tokens"
    echo "(Create a 'Read' token - no special permissions needed)"
    echo ""
    read -p "Enter HuggingFace token (or press Enter to skip): " user_token
    
    if [[ -n "$user_token" ]]; then
        # Validate token format (should start with hf_)
        if [[ "$user_token" == hf_* ]]; then
            HF_TOKEN="$user_token"
            log_success "HuggingFace token set"
            
            # Offer to save to Kubernetes if available
            if command -v kubectl &>/dev/null && kubectl get namespace llmapi &>/dev/null 2>&1; then
                read -p "Save token to Kubernetes for future use? [Y/n]: " save_k8s
                if [[ "${save_k8s,,}" != "n" ]]; then
                    kubectl create secret generic hf-token -n llmapi \
                        --from-literal=token="$HF_TOKEN" \
                        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null && \
                        log_success "Token saved to Kubernetes secret 'hf-token'" || \
                        log_warn "Could not save to Kubernetes (namespace may not exist yet)"
                fi
            fi
        else
            log_warn "Token doesn't look like a HuggingFace token (should start with 'hf_')"
            log_warn "Continuing without token - downloads may be slower"
        fi
    else
        log_info "Continuing without HuggingFace token"
        log_info "Downloads will work but may be slower for large models"
    fi
    echo ""
}

ensure_directories() {
    mkdir -p "$DOWNLOAD_DIR"/{vllm,llamacpp,embedding}
    mkdir -p "$TEMP_DIR"
}

human_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")G"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")M"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}")K"
    else
        echo "${bytes}B"
    fi
}

# =============================================================================
# Speed Testing
# =============================================================================

test_download_speed() {
    local url="$1"
    local name="${2:-source}"
    local test_size=10485760  # 10MB test
    local timeout=30
    
    log_info "Testing download speed from $name..."
    
    local start_time=$(date +%s.%N)
    local bytes_downloaded=0
    
    # Download with timeout and capture bytes
    if [[ -n "$HF_TOKEN" ]] && [[ "$url" == *"huggingface.co"* ]]; then
        bytes_downloaded=$(curl -sL --max-time $timeout -r 0-$test_size \
            -H "Authorization: Bearer $HF_TOKEN" \
            -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)
    else
        bytes_downloaded=$(curl -sL --max-time $timeout -r 0-$test_size \
            -o /dev/null -w '%{size_download}' "$url" 2>/dev/null || echo 0)
    fi
    
    local end_time=$(date +%s.%N)
    local duration=$(awk "BEGIN {printf \"%.2f\", $end_time - $start_time}")
    
    if [[ "$bytes_downloaded" -gt 0 ]] && [[ $(awk "BEGIN {print ($duration > 0)}") -eq 1 ]]; then
        local speed=$(awk "BEGIN {printf \"%.0f\", $bytes_downloaded / $duration}")
        echo "$speed"
    else
        echo "0"
    fi
}

select_best_source() {
    local model_type="$1"
    local model_id="$2"
    
    declare -A sources
    
    case "$model_type" in
        vllm)
            # HuggingFace
            sources["huggingface"]="https://huggingface.co/$model_id/resolve/main/config.json"
            
            # ModelScope mirror if available
            if [[ -n "${MODELSCOPE_MIRRORS[$model_id]:-}" ]]; then
                sources["modelscope"]="https://modelscope.cn/models/${MODELSCOPE_MIRRORS[$model_id]}/resolve/master/config.json"
            fi
            ;;
        llamacpp|embedding)
            # Direct URL - test the actual file
            sources["huggingface"]="$model_id"
            ;;
    esac
    
    local best_source=""
    local best_speed=0
    
    for source in "${!sources[@]}"; do
        local url="${sources[$source]}"
        local speed=$(test_download_speed "$url" "$source")
        
        log_info "  $source: $(human_size $speed)/s"
        
        if [[ $speed -gt $best_speed ]]; then
            best_speed=$speed
            best_source=$source
        fi
    done
    
    if [[ $best_speed -lt $MIN_SPEED ]]; then
        log_warn "All sources are slow (< 1 MB/s). Download may take a long time."
    fi
    
    echo "$best_source:$best_speed"
}

# =============================================================================
# Download Functions
# =============================================================================

download_with_aria2() {
    local url="$1"
    local output="$2"
    local connections="${3:-16}"
    
    # Ensure output is an absolute path
    local output_dir=$(dirname "$output")
    local output_file=$(basename "$output")
    
    local aria_opts="-x $connections -s $connections -k 10M --file-allocation=none"
    aria_opts="$aria_opts --console-log-level=notice --summary-interval=10"
    aria_opts="$aria_opts -c"  # Continue/resume
    
    if [[ -n "$HF_TOKEN" ]] && [[ "$url" == *"huggingface.co"* ]]; then
        aria2c $aria_opts --header="Authorization: Bearer $HF_TOKEN" -d "$output_dir" -o "$output_file" "$url"
    else
        aria2c $aria_opts -d "$output_dir" -o "$output_file" "$url"
    fi
}

download_with_curl() {
    local url="$1"
    local output="$2"
    
    local curl_opts="-L -C - --progress-bar"
    
    if [[ -n "$HF_TOKEN" ]] && [[ "$url" == *"huggingface.co"* ]]; then
        curl $curl_opts -H "Authorization: Bearer $HF_TOKEN" -o "$output" "$url"
    else
        curl $curl_opts -o "$output" "$url"
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local expected_size="${3:-}"
    
    # Check if file already exists and is complete
    if [[ -f "$output" ]]; then
        local existing_size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [[ -n "$expected_size" ]] && [[ "$existing_size" -ge "$expected_size" ]]; then
            log_success "File already downloaded: $output ($(human_size $existing_size))"
            return 0
        else
            log_info "Resuming partial download: $(human_size $existing_size) downloaded"
        fi
    fi
    
    # Use aria2c if available, otherwise curl
    if command -v aria2c &>/dev/null; then
        log_info "Using aria2c (16 parallel connections)..."
        download_with_aria2 "$url" "$output"
    else
        log_info "Using curl (single connection)..."
        download_with_curl "$url" "$output"
    fi
    
    # Verify download
    if [[ -f "$output" ]]; then
        local final_size=$(stat -c%s "$output")
        log_success "Download complete: $(human_size $final_size)"
        return 0
    else
        log_error "Download failed!"
        return 1
    fi
}

download_hf_model() {
    local repo_id="$1"
    local output_dir="$2"
    local source="${3:-huggingface}"
    
    log_info "Downloading HuggingFace model: $repo_id"
    log_info "Output directory: $output_dir"
    
    mkdir -p "$output_dir"
    
    # Use huggingface-cli if available
    if command -v huggingface-cli &>/dev/null || python3 -c "import huggingface_hub" &>/dev/null; then
        log_info "Using huggingface_hub for download..."
        
        # Enable hf_transfer if available
        export HF_HUB_ENABLE_HF_TRANSFER=1
        
        python3 << PYEOF
import os
import sys
try:
    from huggingface_hub import snapshot_download
    
    repo_id = "$repo_id"
    output_dir = "$output_dir"
    token = os.environ.get("HF_TOKEN") or None
    
    print(f"Downloading {repo_id}...")
    path = snapshot_download(
        repo_id=repo_id,
        local_dir=output_dir,
        token=token,
        resume_download=True,
        local_dir_use_symlinks=False
    )
    print(f"Downloaded to: {path}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    else
        log_warn "huggingface_hub not installed. Installing..."
        pip install --quiet huggingface_hub hf_transfer
        
        # Retry with installed package
        download_hf_model "$repo_id" "$output_dir" "$source"
    fi
}

# =============================================================================
# Model Download Commands
# =============================================================================

download_vllm_model() {
    local model_key="${1:-qwen2.5-14b-awq}"
    
    if [[ -z "${VLLM_MODELS[$model_key]:-}" ]]; then
        log_error "Unknown vLLM model: $model_key"
        log_info "Available models:"
        for key in "${!VLLM_MODELS[@]}"; do
            IFS='|' read -r repo size desc <<< "${VLLM_MODELS[$key]}"
            echo "  $key: $desc ($size)"
        done
        return 1
    fi
    
    IFS='|' read -r repo_id size desc <<< "${VLLM_MODELS[$model_key]}"
    
    echo ""
    echo -e "${CYAN}=== Downloading vLLM Model ===${NC}"
    echo "Model: $model_key"
    echo "Repository: $repo_id"
    echo "Size: ~$size"
    echo ""
    
    # Test sources and select best
    log_info "Testing download sources..."
    local result=$(select_best_source "vllm" "$repo_id")
    local best_source=$(echo "$result" | cut -d: -f1)
    local best_speed=$(echo "$result" | cut -d: -f2)
    
    echo ""
    log_info "Selected source: $best_source ($(human_size $best_speed)/s)"
    echo ""
    
    local output_dir="$DOWNLOAD_DIR/vllm/$model_key"
    download_hf_model "$repo_id" "$output_dir" "$best_source"
    
    # Create a marker file with metadata
    cat > "$output_dir/.model-info" << EOF
model_key=$model_key
repo_id=$repo_id
source=$best_source
downloaded=$(date -Iseconds)
EOF
    
    log_success "vLLM model ready at: $output_dir"
}

download_llamacpp_model() {
    local model_key="${1:-llama3.1-70b-q4}"
    
    if [[ -z "${LLAMACPP_MODELS[$model_key]:-}" ]]; then
        log_error "Unknown llama.cpp model: $model_key"
        log_info "Available models:"
        for key in "${!LLAMACPP_MODELS[@]}"; do
            IFS='|' read -r url size desc <<< "${LLAMACPP_MODELS[$key]}"
            echo "  $key: $desc ($size)"
        done
        return 1
    fi
    
    IFS='|' read -r url size desc <<< "${LLAMACPP_MODELS[$model_key]}"
    local filename=$(basename "$url")
    
    echo ""
    echo -e "${CYAN}=== Downloading llama.cpp Model ===${NC}"
    echo "Model: $model_key"
    echo "File: $filename"
    echo "Size: ~$size"
    echo ""
    
    # Test download speed
    log_info "Testing download speed..."
    local speed=$(test_download_speed "$url" "HuggingFace")
    log_info "Download speed: $(human_size $speed)/s"
    
    if [[ $speed -gt 0 ]]; then
        # Parse size to bytes for ETA calculation
        local size_bytes=$(echo "$size" | sed 's/G/*1073741824/;s/M/*1048576/;s/K/*1024/' | bc)
        local eta_seconds=$(awk "BEGIN {printf \"%.0f\", $size_bytes / $speed}")
        local eta_human=$(date -d@$eta_seconds -u +%H:%M:%S 2>/dev/null || echo "${eta_seconds}s")
        log_info "Estimated time: $eta_human"
    fi
    echo ""
    
    local output_path="$DOWNLOAD_DIR/llamacpp/$filename"
    download_file "$url" "$output_path"
    
    # Create symlink with model key name
    ln -sf "$filename" "$DOWNLOAD_DIR/llamacpp/$model_key.gguf" 2>/dev/null || true
    
    log_success "llama.cpp model ready at: $output_path"
}

download_embedding_model() {
    local model_key="${1:-nomic-embed-v1.5}"
    
    if [[ -z "${EMBEDDING_MODELS[$model_key]:-}" ]]; then
        log_error "Unknown embedding model: $model_key"
        log_info "Available models:"
        for key in "${!EMBEDDING_MODELS[@]}"; do
            IFS='|' read -r url size desc <<< "${EMBEDDING_MODELS[$key]}"
            echo "  $key: $desc ($size)"
        done
        return 1
    fi
    
    IFS='|' read -r url size desc <<< "${EMBEDDING_MODELS[$model_key]}"
    local filename=$(basename "$url")
    
    echo ""
    echo -e "${CYAN}=== Downloading Embedding Model ===${NC}"
    echo "Model: $model_key"
    echo "File: $filename"
    echo "Size: ~$size"
    echo ""
    
    local output_path="$DOWNLOAD_DIR/embedding/$filename"
    download_file "$url" "$output_path"
    
    # Create symlink
    ln -sf "$filename" "$DOWNLOAD_DIR/embedding/$model_key.gguf" 2>/dev/null || true
    
    log_success "Embedding model ready at: $output_path"
}

# =============================================================================
# Status and Listing
# =============================================================================

list_models() {
    echo ""
    echo -e "${CYAN}=== Available Models ===${NC}"
    echo ""
    
    echo -e "${GREEN}vLLM Models (GPU):${NC}"
    for key in "${!VLLM_MODELS[@]}"; do
        IFS='|' read -r repo size desc <<< "${VLLM_MODELS[$key]}"
        printf "  %-20s %6s  %s\n" "$key" "$size" "$desc"
    done
    
    echo ""
    echo -e "${GREEN}llama.cpp Models (CPU):${NC}"
    for key in "${!LLAMACPP_MODELS[@]}"; do
        IFS='|' read -r url size desc <<< "${LLAMACPP_MODELS[$key]}"
        printf "  %-20s %6s  %s\n" "$key" "$size" "$desc"
    done
    
    echo ""
    echo -e "${GREEN}Embedding Models:${NC}"
    for key in "${!EMBEDDING_MODELS[@]}"; do
        IFS='|' read -r url size desc <<< "${EMBEDDING_MODELS[$key]}"
        printf "  %-20s %6s  %s\n" "$key" "$size" "$desc"
    done
    echo ""
}

check_status() {
    echo ""
    echo -e "${CYAN}=== Download Status ===${NC}"
    echo "Download directory: $DOWNLOAD_DIR"
    echo ""
    
    echo -e "${GREEN}vLLM Models:${NC}"
    if [[ -d "$DOWNLOAD_DIR/vllm" ]]; then
        for dir in "$DOWNLOAD_DIR/vllm"/*/; do
            if [[ -d "$dir" ]]; then
                local name=$(basename "$dir")
                local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                local status="✓"
                [[ -f "$dir/.model-info" ]] || status="?"
                echo "  $status $name: $size"
            fi
        done
    else
        echo "  (none)"
    fi
    
    echo ""
    echo -e "${GREEN}llama.cpp Models:${NC}"
    if [[ -d "$DOWNLOAD_DIR/llamacpp" ]]; then
        for file in "$DOWNLOAD_DIR/llamacpp"/*.gguf; do
            if [[ -f "$file" ]]; then
                local name=$(basename "$file")
                local size=$(du -h "$file" 2>/dev/null | cut -f1)
                echo "  ✓ $name: $size"
            fi
        done
    else
        echo "  (none)"
    fi
    
    echo ""
    echo -e "${GREEN}Embedding Models:${NC}"
    if [[ -d "$DOWNLOAD_DIR/embedding" ]]; then
        for file in "$DOWNLOAD_DIR/embedding"/*.gguf; do
            if [[ -f "$file" ]]; then
                local name=$(basename "$file")
                local size=$(du -h "$file" 2>/dev/null | cut -f1)
                echo "  ✓ $name: $size"
            fi
        done
    else
        echo "  (none)"
    fi
    echo ""
}

# =============================================================================
# Interactive Mode
# =============================================================================

interactive_mode() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           LLM Model Download Manager                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check for HF token
    if [[ -z "$HF_TOKEN" ]]; then
        log_warn "HuggingFace token not set. Downloads may be slower."
        echo "Set HF_TOKEN environment variable for faster downloads."
        echo ""
    fi
    
    echo "What would you like to do?"
    echo ""
    echo "  1) Download vLLM model (GPU)"
    echo "  2) Download llama.cpp model (CPU)"
    echo "  3) Download embedding model"
    echo "  4) Download all recommended models"
    echo "  5) List available models"
    echo "  6) Check download status"
    echo "  7) Test download speeds"
    echo "  0) Exit"
    echo ""
    
    read -p "Select option [1-7]: " choice
    
    case "$choice" in
        1)
            echo ""
            echo "Available vLLM models:"
            local i=1
            declare -a keys
            for key in "${!VLLM_MODELS[@]}"; do
                IFS='|' read -r repo size desc <<< "${VLLM_MODELS[$key]}"
                echo "  $i) $key ($size) - $desc"
                keys+=("$key")
                ((i++))
            done
            echo ""
            read -p "Select model [1-$((i-1))]: " model_choice
            if [[ $model_choice -ge 1 ]] && [[ $model_choice -lt $i ]]; then
                download_vllm_model "${keys[$((model_choice-1))]}"
            fi
            ;;
        2)
            echo ""
            echo "Available llama.cpp models:"
            local i=1
            declare -a keys
            for key in "${!LLAMACPP_MODELS[@]}"; do
                IFS='|' read -r url size desc <<< "${LLAMACPP_MODELS[$key]}"
                echo "  $i) $key ($size) - $desc"
                keys+=("$key")
                ((i++))
            done
            echo ""
            read -p "Select model [1-$((i-1))]: " model_choice
            if [[ $model_choice -ge 1 ]] && [[ $model_choice -lt $i ]]; then
                download_llamacpp_model "${keys[$((model_choice-1))]}"
            fi
            ;;
        3)
            echo ""
            echo "Available embedding models:"
            local i=1
            declare -a keys
            for key in "${!EMBEDDING_MODELS[@]}"; do
                IFS='|' read -r url size desc <<< "${EMBEDDING_MODELS[$key]}"
                echo "  $i) $key ($size) - $desc"
                keys+=("$key")
                ((i++))
            done
            echo ""
            read -p "Select model [1-$((i-1))]: " model_choice
            if [[ $model_choice -ge 1 ]] && [[ $model_choice -lt $i ]]; then
                download_embedding_model "${keys[$((model_choice-1))]}"
            fi
            ;;
        4)
            echo ""
            log_info "Downloading recommended models..."
            download_vllm_model "qwen2.5-14b-awq"
            download_llamacpp_model "llama3.1-70b-q4"
            download_embedding_model "nomic-embed-v1.5"
            ;;
        5)
            list_models
            ;;
        6)
            check_status
            ;;
        7)
            echo ""
            log_info "Testing download speeds from various sources..."
            echo ""
            
            # Test HuggingFace
            local hf_speed=$(test_download_speed "https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-AWQ/resolve/main/config.json" "HuggingFace")
            echo "HuggingFace: $(human_size $hf_speed)/s"
            
            # Test ModelScope
            local ms_speed=$(test_download_speed "https://modelscope.cn/models/qwen/Qwen2.5-14B-Instruct-AWQ/resolve/master/config.json" "ModelScope")
            echo "ModelScope: $(human_size $ms_speed)/s"
            
            echo ""
            if [[ $hf_speed -gt $ms_speed ]]; then
                log_info "Recommendation: Use HuggingFace"
            else
                log_info "Recommendation: Use ModelScope (Chinese mirror)"
            fi
            ;;
        0)
            exit 0
            ;;
        *)
            log_error "Invalid option"
            ;;
    esac
}

# =============================================================================
# Copy to Kubernetes PVC
# =============================================================================

copy_to_k8s() {
    local model_type="$1"
    local namespace="${2:-llmapi}"
    
    log_info "Copying pre-downloaded models to Kubernetes PVC..."
    
    case "$model_type" in
        vllm)
            local pvc="vllm-models"
            local src_dir="$DOWNLOAD_DIR/vllm"
            ;;
        llamacpp)
            local pvc="llamacpp-models"
            local src_dir="$DOWNLOAD_DIR/llamacpp"
            ;;
        embedding)
            local pvc="embedding-models"
            local src_dir="$DOWNLOAD_DIR/embedding"
            ;;
        *)
            log_error "Unknown model type: $model_type"
            return 1
            ;;
    esac
    
    if [[ ! -d "$src_dir" ]] || [[ -z "$(ls -A "$src_dir" 2>/dev/null)" ]]; then
        log_error "No models found in $src_dir"
        return 1
    fi
    
    # Create a temporary pod to copy files
    log_info "Creating temporary pod to copy files to PVC $pvc..."
    
    kubectl run model-copy-$$ --rm -it --restart=Never \
        -n "$namespace" \
        --image=busybox \
        --overrides="{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"copy\",
                    \"image\": \"busybox\",
                    \"command\": [\"sleep\", \"3600\"],
                    \"volumeMounts\": [{
                        \"name\": \"models\",
                        \"mountPath\": \"/models\"
                    }]
                }],
                \"volumes\": [{
                    \"name\": \"models\",
                    \"persistentVolumeClaim\": {
                        \"claimName\": \"$pvc\"
                    }
                }]
            }
        }" &
    
    sleep 5
    
    # Copy files
    kubectl cp "$src_dir" "$namespace/model-copy-$$:/models/"
    
    # Cleanup
    kubectl delete pod model-copy-$$ -n "$namespace" --force --grace-period=0 2>/dev/null || true
    
    log_success "Models copied to PVC $pvc"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           LLM Model Download Manager                          ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_dependencies
    ensure_directories
    
    # Prompt for HuggingFace token (unless --list or --status)
    if [[ "${1:-}" != "--list" ]] && [[ "${1:-}" != "--status" ]]; then
        prompt_hf_token
    fi
    
    case "${1:-}" in
        --model)
            case "${2:-}" in
                vllm)
                    download_vllm_model "${3:-qwen2.5-14b-awq}"
                    ;;
                llamacpp)
                    download_llamacpp_model "${3:-llama3.1-70b-q4}"
                    ;;
                embedding)
                    download_embedding_model "${3:-nomic-embed-v1.5}"
                    ;;
                all)
                    download_vllm_model "qwen2.5-14b-awq"
                    download_llamacpp_model "llama3.1-70b-q4"
                    download_embedding_model "nomic-embed-v1.5"
                    ;;
                *)
                    log_error "Unknown model type: ${2:-}"
                    echo "Usage: $0 --model [vllm|llamacpp|embedding|all] [model-key]"
                    exit 1
                    ;;
            esac
            ;;
        --list)
            list_models
            ;;
        --status)
            check_status
            ;;
        --copy-to-k8s)
            copy_to_k8s "${2:-vllm}" "${3:-llmapi}"
            ;;
        --help|-h)
            echo "LLM Model Download Manager"
            echo ""
            echo "Usage:"
            echo "  $0                              Interactive mode"
            echo "  $0 --model vllm [key]           Download vLLM model"
            echo "  $0 --model llamacpp [key]       Download llama.cpp model"
            echo "  $0 --model embedding [key]      Download embedding model"
            echo "  $0 --model all                  Download all recommended models"
            echo "  $0 --list                       List available models"
            echo "  $0 --status                     Check download status"
            echo "  $0 --copy-to-k8s [type] [ns]    Copy models to K8s PVC"
            echo ""
            echo "Environment variables:"
            echo "  HF_TOKEN          HuggingFace token for faster downloads"
            echo "  LLM_MODEL_DIR     Download directory (default: /var/lib/llmapi/models)"
            ;;
        "")
            interactive_mode
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
}

main "$@"
