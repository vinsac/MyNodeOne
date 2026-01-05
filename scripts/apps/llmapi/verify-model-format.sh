#!/bin/bash
#
# Verify Model Format - Check if models are in correct format for each backend
# =============================================================================
# Different backends have different format requirements:
#   - vLLM: HuggingFace cache format (models--Org--ModelName/snapshots/...)
#   - llama.cpp: Single GGUF file
#   - embedding: Single GGUF file
#
# Usage:
#   ./verify-model-format.sh                    # Check all backends
#   ./verify-model-format.sh vllm               # Check specific backend
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_MODEL_DIR="/var/lib/llmapi/models"
BACKEND="${1:-all}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Model Format Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

check_vllm_models() {
    local MODEL_DIR="$BASE_MODEL_DIR/vllm"
    
    echo "📦 vLLM Models (HuggingFace cache format required)"
    echo "─────────────────────────────────────────────────────"
    
    if [[ ! -d "$MODEL_DIR" ]]; then
        echo -e "${YELLOW}⚠ Directory not found: $MODEL_DIR${NC}"
        echo ""
        return 1
    fi
    
    local valid_models=0
    local invalid_models=0
    
    echo "Models Found:"
    echo "─────────────────────────────────────────────────────"
    
    # Check for HuggingFace cache format models (models--Org--ModelName)
    for model_dir in "$MODEL_DIR"/models--*/; do
        if [[ -d "$model_dir" ]]; then
        local     local model_name=$(basename "$model_dir")
        # Check for required HF cache structure
        if [[ -d "$model_dir/snapshots" ]] && [[ -d "$model_dir/blobs" ]]; then
            local size=$(du -sh "$model_dir" 2>/dev/null | cut -f1)
            echo -e "${GREEN}✓${NC} $model_name ($size)"
            echo "  Format: HuggingFace Cache ✓"
            echo "  Location: $model_dir"
            
            # Check if snapshots have actual files
            local snapshot_count=$(find "$model_dir/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
            if [[ $snapshot_count -gt 0 ]]; then
                echo "  Snapshots: $snapshot_count"
                valid_models=$((valid_models + 1))
            else
                echo -e "  ${YELLOW}Warning: No snapshots found${NC}"
            fi
        else
            echo -e "${RED}✗${NC} $model_name"
            echo "  Format: Incomplete HuggingFace Cache ✗"
            echo "  Missing: snapshots/ or blobs/ directory"
            invalid_models=$((invalid_models + 1))
        fi
        echo ""
    fi
done
    
    # Check for flat structure models (non-HF format)
    for model_dir in "$MODEL_DIR"/*/; do
        if [[ -d "$model_dir" ]]; then
        local     local model_name=$(basename "$model_dir")
        
        # Skip HF format models (already checked above)
        if [[ "$model_name" == models--* ]] || [[ "$model_name" == "hub" ]] || \
           [[ "$model_name" == "modules" ]] || [[ "$model_name" == ".locks" ]] || \
           [[ "$model_name" == "xet" ]]; then
            continue
        fi
        
        # This is a flat structure model
        local size=$(du -sh "$model_dir" 2>/dev/null | cut -f1)
        echo -e "${YELLOW}⚠${NC} $model_name ($size)"
        echo "  Format: Flat Directory Structure ✗"
        echo "  Location: $model_dir"
        echo -e "  ${YELLOW}Action: Delete and re-download with huggingface_hub${NC}"
        invalid_models=$((invalid_models + 1))
        echo ""
    fi
done
    
    # Check for hub/ directory (part of HF cache)
    if [[ -d "$MODEL_DIR/hub" ]]; then
        local hub_size=$(du -sh "$MODEL_DIR/hub" 2>/dev/null | cut -f1)
        echo -e "${BLUE}ℹ${NC} hub/ ($hub_size)"
        echo "  Part of HuggingFace cache metadata"
        echo ""
    fi
    
    echo "─────────────────────────────────────────────────────"
    echo ""
    echo "Summary:"
    echo "  ✓ Valid models (HF format): $valid_models"
    if [[ $invalid_models -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠ Invalid models (flat structure): $invalid_models${NC}"
    fi
    echo ""
    
    if [[ $invalid_models -gt 0 ]]; then
        echo -e "${YELLOW}Recommendations:${NC}"
        echo "1. Delete flat structure models:"
        for model_dir in "$MODEL_DIR"/*/; do
            local model_name=$(basename "$model_dir")
            if [[ "$model_name" != models--* ]] && [[ "$model_name" != "hub" ]] && \
               [[ "$model_name" != "modules" ]] && [[ "$model_name" != ".locks" ]] && \
               [[ "$model_name" != "xet" ]] && [[ -d "$model_dir" ]]; then
                echo "   sudo rm -rf $model_dir"
            fi
        done
        echo ""
        echo "2. Re-download using huggingface_hub:"
        echo "   # From Python:"
        echo "   from huggingface_hub import snapshot_download"
        echo "   snapshot_download(repo_id='Qwen/Qwen2.5-14B-Instruct-AWQ',"
        echo "                     cache_dir='$MODEL_DIR')"
        echo ""
        echo "   # Or let vLLM init container download automatically"
        echo ""
    fi

    if [[ $valid_models -eq 0 ]]; then
        echo -e "${YELLOW}No valid vLLM models found. Will download on first pod startup.${NC}"
    fi
    echo ""
}

check_llamacpp_models() {
    local MODEL_DIR="$BASE_MODEL_DIR/llamacpp"
    
    echo "📦 llama.cpp Models (GGUF file format)"
    echo "─────────────────────────────────────────────────────"
    
    if [[ ! -d "$MODEL_DIR" ]]; then
        echo -e "${YELLOW}⚠ Directory not found: $MODEL_DIR${NC}"
        echo ""
        return 1
    fi
    
    local gguf_count=$(find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | wc -l)
    
    if [[ $gguf_count -eq 0 ]]; then
        echo -e "${YELLOW}No GGUF models found. Will download on first pod startup.${NC}"
    else
        for gguf_file in "$MODEL_DIR"/*.gguf; do
            if [[ -f "$gguf_file" ]]; then
                local model_name=$(basename "$gguf_file")
                local size=$(du -sh "$gguf_file" 2>/dev/null | cut -f1)
                echo -e "${GREEN}✓${NC} $model_name ($size)"
            fi
        done
        echo ""
        echo -e "${GREEN}✓ $gguf_count GGUF model(s) ready${NC}"
    fi
    echo ""
}

check_embedding_models() {
    local MODEL_DIR="$BASE_MODEL_DIR/embedding"
    
    echo "📦 Embedding Models (GGUF file format)"
    echo "─────────────────────────────────────────────────────"
    
    if [[ ! -d "$MODEL_DIR" ]]; then
        echo -e "${YELLOW}⚠ Directory not found: $MODEL_DIR${NC}"
        echo ""
        return 1
    fi
    
    local gguf_count=$(find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null | wc -l)
    
    if [[ $gguf_count -eq 0 ]]; then
        echo -e "${YELLOW}No GGUF embedding models found. Will download on first pod startup.${NC}"
    else
        for gguf_file in "$MODEL_DIR"/*.gguf; do
            if [[ -f "$gguf_file" ]]; then
                local model_name=$(basename "$gguf_file")
                local size=$(du -sh "$gguf_file" 2>/dev/null | cut -f1)
                echo -e "${GREEN}✓${NC} $model_name ($size)"
            fi
        done
        echo ""
        echo -e "${GREEN}✓ $gguf_count embedding model(s) ready${NC}"
    fi
    echo ""
}

# Main execution
case "$BACKEND" in
    vllm)
        check_vllm_models
        ;;
    llamacpp)
        check_llamacpp_models
        ;;
    embedding)
        check_embedding_models
        ;;
    all|*)
        check_vllm_models
        check_llamacpp_models
        check_embedding_models
        ;;
esac

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Verification complete${NC}"
echo ""
echo "Format Summary:"
echo "  • vLLM: Requires HuggingFace cache (models--Org--ModelName/)"
echo "  • llama.cpp: Single .gguf file"
echo "  • embedding: Single .gguf file"
