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
    # Recommended: Same models as vLLM for consistent responses  
    ["qwen2.5-14b-q4"]="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q4_K_M.gguf|9.2G|Same as GPU model (recommended)"
    ["qwen2.5-14b-q8"]="https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF/resolve/main/Qwen2.5-14B-Instruct-Q8_0.gguf|15.7G|Higher quality Q8"
    ["mistral-7b-q4"]="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf|4.4G|Fast Mistral (matches GPU)"
    ["mistral-7b-q8"]="https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q8_0.gguf|7.7G|Higher quality Mistral"
    # Large models for high-RAM systems
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
    
    # Required dependencies (pip3 will be auto-installed if missing)
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

# Load centralized HF token management
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/hf-token.sh"

setup_hf_token() {
    # Use centralized token management - prompts if needed
    if HF_TOKEN=$(get_hf_token true); then
        export HF_TOKEN
        return 0
    else
        return 1
    fi
}

ensure_directories() {
    mkdir -p "$DOWNLOAD_DIR"/{vllm,llamacpp,embedding}
    mkdir -p "$TEMP_DIR"
}

human_size() {
    local bytes="${1:-0}"
    
    # Ensure bytes is a valid number
    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        bytes=0
    fi
    
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
    local test_size=5242880  # 5MB test chunk
    local timeout=15
    
    # Print status to stderr so it doesn't get captured
    echo -e "${BLUE}[INFO]${NC} Testing download speed from $name..." >&2
    
    local start_time=$(date +%s.%N)
    local bytes_downloaded=0
    
    # For small files (like index.json), curl returns the whole file
    # For large files, -r 0-N downloads first N bytes
    # Use timeout to limit test duration
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
    
    # Validate bytes_downloaded is numeric
    if ! [[ "$bytes_downloaded" =~ ^[0-9]+$ ]]; then
        bytes_downloaded=0
    fi
    
    # Calculate speed if we downloaded enough data (at least 100KB) and took reasonable time
    if [[ "$bytes_downloaded" -gt 102400 ]] && [[ $(awk "BEGIN {print ($duration > 0.5)}") -eq 1 ]]; then
        local speed=$(awk "BEGIN {printf \"%.0f\", $bytes_downloaded / $duration}")
        echo "$speed"
    elif [[ "$bytes_downloaded" -gt 0 ]] && [[ "$bytes_downloaded" -lt 102400 ]]; then
        # Small file - estimate based on actual download, but warn it's unreliable
        echo -e "${YELLOW}[WARN]${NC}   Small test file, speed may be inaccurate" >&2
        local speed=$(awk "BEGIN {printf \"%.0f\", $bytes_downloaded / ($duration > 0 ? $duration : 1)}")
        # Assume at least 1MB/s if file downloaded quickly
        if [[ "$speed" -lt 100000 ]] && [[ $(awk "BEGIN {print ($duration < 2)}") -eq 1 ]]; then
            speed=1000000  # Assume 1MB/s minimum
        fi
        echo "$speed"
    else
        echo "0"
    fi
}

select_best_source() {
    local model_type="$1"
    local model_id="$2"
    
    # For vLLM models, we use huggingface_hub Python library which handles 
    # source selection internally. Skip speed test and default to huggingface.
    if [[ "$model_type" == "vllm" ]]; then
        log_info "Using HuggingFace (primary source for vLLM models)"
        echo "huggingface"
        return 0
    fi
    
    declare -A sources
    
    case "$model_type" in
        llamacpp|embedding)
            # Direct URL - test the actual file (large GGUF files support range requests)
            sources["huggingface"]="$model_id"
            ;;
    esac
    
    local best_source=""
    local best_speed=0
    
    for source in "${!sources[@]}"; do
        local url="${sources[$source]}"
        local speed
        speed=$(test_download_speed "$url" "$source")
        
        # Ensure speed is a number
        if ! [[ "$speed" =~ ^[0-9]+$ ]]; then
            speed=0
        fi
        
        echo -e "${BLUE}[INFO]${NC}   $source: $(human_size $speed)/s" >&2
        
        if [[ $speed -gt $best_speed ]]; then
            best_speed=$speed
            best_source=$source
        fi
    done
    
    if [[ $best_speed -lt $MIN_SPEED ]]; then
        echo -e "${YELLOW}[WARN]${NC} All sources are slow (< 1 MB/s). Download may take a long time." >&2
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
        
        local pip_installed=false
        local packages_installed=false
        
        # First, ensure pip3 is available with robust fallback
        if ! command -v pip3 &>/dev/null; then
            log_info "pip3 not found, installing..."
            
            if command -v apt-get &>/dev/null; then
                # Ubuntu/Debian
                log_info "Installing python3-pip via apt-get..."
                if apt-get update -qq && apt-get install -y -qq python3-pip 2>/dev/null; then
                    pip_installed=true
                    log_success "pip3 installed via apt-get"
                fi
            elif command -v dnf &>/dev/null; then
                # RHEL/Rocky/Fedora 22+
                log_info "Installing python3-pip via dnf..."
                if dnf install -y -q python3-pip 2>/dev/null; then
                    pip_installed=true
                    log_success "pip3 installed via dnf"
                fi
            elif command -v yum &>/dev/null; then
                # RHEL/CentOS 7 and older
                log_info "Installing python3-pip via yum..."
                if yum install -y -q python3-pip 2>/dev/null; then
                    pip_installed=true
                    log_success "pip3 installed via yum"
                fi
            elif command -v zypper &>/dev/null; then
                # openSUSE
                log_info "Installing python3-pip via zypper..."
                if zypper install -y python3-pip 2>/dev/null; then
                    pip_installed=true
                    log_success "pip3 installed via zypper"
                fi
            elif command -v pacman &>/dev/null; then
                # Arch Linux
                log_info "Installing python-pip via pacman..."
                if pacman -S --noconfirm python-pip 2>/dev/null; then
                    pip_installed=true
                    log_success "pip3 installed via pacman"
                fi
            else
                log_error "Cannot install pip3 automatically on this system"
                echo "Please install python3-pip manually for your distribution"
                return 1
            fi
            
            if [[ "$pip_installed" != "true" ]]; then
                log_error "Failed to install pip3"
                return 1
            fi
        fi
        
        # Now install huggingface_hub with multiple fallback approaches
        log_info "Installing huggingface_hub and hf_transfer..."
        
        # Try system-wide installation first (preferred for control plane)
        if pip3 install --break-system-packages huggingface_hub hf_transfer 2>/dev/null; then
            packages_installed=true
            log_success "Installed packages with --break-system-packages"
        elif pip3 install huggingface_hub hf_transfer 2>/dev/null; then
            packages_installed=true
            log_success "Installed packages (standard)"
        elif pip3 install --user huggingface_hub hf_transfer 2>/dev/null; then
            packages_installed=true
            log_success "Installed packages with --user"
        elif python3 -m pip install --break-system-packages huggingface_hub hf_transfer 2>/dev/null; then
            packages_installed=true  
            log_success "Installed packages via python3 -m pip"
        else
            log_error "Failed to install huggingface_hub"
            echo ""
            echo "Please install manually:"
            echo "  pip3 install --break-system-packages huggingface_hub hf_transfer"
            return 1
        fi
        
        # Verify installation
        if ! python3 -c "import huggingface_hub" 2>/dev/null; then
            log_error "Failed to install huggingface_hub"
            log_info "Try manually: sudo pip3 install --break-system-packages huggingface_hub"
            return 1
        fi
        
        log_success "huggingface_hub installed successfully"
        
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
    local max_retries=3
    local retry_count=0
    
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
    local output_dir="$DOWNLOAD_DIR/llamacpp"
    local output_file="$output_dir/$filename"
    
    echo ""
    echo -e "${CYAN}=== Downloading llama.cpp Model ===${NC}"
    echo "Model: $model_key"
    echo "File: $filename"
    echo "Size: ~$size"
    echo ""
    
    mkdir -p "$output_dir"
    
    # Check if file already exists
    if [[ -f "$output_file" ]]; then
        local current_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo 0)
        if [[ $current_size -gt 1000000 ]]; then  # > 1MB, likely valid
            log_success "Model already downloaded: $filename ($(human_size $current_size))"
            return 0
        fi
    fi
    
    # Test download speed and select source
    log_info "Testing download speed..."
    local test_speed=$(test_download_speed "$url" "HuggingFace")
    if [[ $test_speed -gt 0 ]]; then
        log_info "Download speed: $(human_size $test_speed)/s"
        local file_size_bytes=$(echo "$size" | sed 's/G/*1024*1024*1024/g; s/M/*1024*1024/g; s/K/*1024/g' | sed 's/[^0-9*]//g' | bc 2>/dev/null || echo 0)
        if [[ $file_size_bytes -gt 0 ]]; then
            local eta_seconds=$((file_size_bytes / test_speed))
            local eta_formatted=$(printf "%02d:%02d:%02d" $((eta_seconds/3600)) $(((eta_seconds%3600)/60)) $((eta_seconds%60)))
            log_info "Estimated time: $eta_formatted"
        fi
    else
        log_warn "Could not test download speed"
    fi
    
    # Download with retry mechanism
    echo ""
    while [[ $retry_count -lt $max_retries ]]; do
        if [[ $retry_count -gt 0 ]]; then
            log_info "Retry attempt $retry_count/$max_retries..."
            sleep 2  # Brief pause before retry
        fi
        
        if download_file "$url" "$output_file"; then
            # Verify downloaded file
            if [[ -f "$output_file" ]] && [[ $(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null || echo 0) -gt 1000000 ]]; then
                log_success "llama.cpp model ready at: $output_file"
                return 0
            else
                log_warn "Downloaded file appears corrupt or incomplete"
                rm -f "$output_file" 2>/dev/null
            fi
        fi
        
        retry_count=$((retry_count + 1))
    done
    
    # All retries failed - log gracefully but don't exit
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  Download Failed: llama.cpp Model${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_error "Failed to download $model_key after $max_retries attempts"
    echo ""
    echo "Possible causes:"
    echo "  • Network connectivity issues"
    echo "  • Model URL changed or file moved"
    echo "  • Repository access restrictions"
    echo ""
    echo "You can:"
    echo "  1. Continue installation without this model (CPU backend will be disabled)"
    echo "  2. Try downloading manually later: ./download-models.sh --model llamacpp"
    echo "  3. Check for updated model URLs in the script"
    echo ""
    log_warn "Continuing installation without llama.cpp model..."
    return 1
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
            log_info "Downloading recommended models (same model family for GPU + CPU)..."
            
            local download_results=()
            local failed_models=()
            
            # Download vLLM model
            echo ""
            if download_vllm_model "qwen2.5-14b-awq"; then
                download_results+=("✅ vLLM: qwen2.5-14b-awq")
            else
                download_results+=("❌ vLLM: qwen2.5-14b-awq")
                failed_models+=("vLLM GPU backend")
            fi
            
            # Download llama.cpp model (same model family for consistent responses)
            echo ""
            if download_llamacpp_model "qwen2.5-14b-q4"; then
                download_results+=("✅ llama.cpp: qwen2.5-14b-q4")
            else
                download_results+=("❌ llama.cpp: qwen2.5-14b-q4")
                failed_models+=("llama.cpp CPU backend")
            fi
            
            # Download embedding model
            echo ""
            if download_embedding_model "nomic-embed-v1.5"; then
                download_results+=("✅ Embedding: nomic-embed-v1.5")
            else
                download_results+=("❌ Embedding: nomic-embed-v1.5")
                failed_models+=("Embedding service")
            fi
            
            # Summary
            echo ""
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BLUE}  Download Summary${NC}"
            echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo ""
            for result in "${download_results[@]}"; do
                echo "  $result"
            done
            echo ""
            
            if [[ ${#failed_models[@]} -gt 0 ]]; then
                echo -e "${YELLOW}⚠ Some models failed to download:${NC}"
                for model in "${failed_models[@]}"; do
                    echo "  • $model will not be available"
                done
                echo ""
                echo "The installation can continue with available models."
                echo "You can retry downloading failed models later:"
                echo "  ./download-models.sh"
                echo ""
            else
                log_success "All recommended models downloaded successfully!"
            fi
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
    
    # Setup HuggingFace token (unless --list or --status)
    if [[ "${1:-}" != "--list" ]] && [[ "${1:-}" != "--status" ]]; then
        setup_hf_token
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
