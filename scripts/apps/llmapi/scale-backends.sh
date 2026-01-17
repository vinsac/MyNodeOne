#!/bin/bash

###############################################################################
# LLM API Backend Scaling
# 
# Scale vLLM and llama.cpp instances for load balancing.
###############################################################################

set -euo pipefail

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Load cluster resource detection utilities
source "$PROJECT_ROOT/scripts/lib/cluster-resources.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="llmapi"

usage() {
    echo "Usage: $0 <backend> <replicas>"
    echo ""
    echo "Backends:"
    echo "  vllm      - Scale vLLM GPU instances (requires GPUs)"
    echo "  llamacpp  - Scale llama.cpp CPU instances"
    echo "  gateway   - Scale API gateway replicas"
    echo "  embedding - Scale embedding service"
    echo ""
    echo "Examples:"
    echo "  $0 vllm 2       # Scale vLLM to 2 replicas (needs 2 GPUs)"
    echo "  $0 llamacpp 3   # Scale llama.cpp to 3 replicas"
    echo "  $0 gateway 4    # Scale gateway to 4 replicas"
    echo ""
}

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: LLM API not installed. Run install-llmapi.sh first.${NC}"
    exit 1
fi

if [ $# -lt 2 ]; then
    usage
    exit 1
fi

BACKEND="$1"
REPLICAS="$2"

# Validate replicas is a number
if ! [[ "$REPLICAS" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: Replicas must be a positive number${NC}"
    exit 1
fi

case "$BACKEND" in
    vllm)
        # Check GPU availability using centralized utility
        GPU_COUNT=$(get_cluster_gpu_count)
        
        if [ "$REPLICAS" -gt "$GPU_COUNT" ]; then
            echo -e "${YELLOW}Warning: Requesting $REPLICAS replicas but only $GPU_COUNT GPUs available${NC}"
            read -p "Continue anyway? [y/N]: " confirm
            if [ "${confirm,,}" != "y" ]; then
                exit 1
            fi
        fi
        
        echo "Scaling vLLM to $REPLICAS replicas..."
        kubectl scale statefulset vllm -n "$NAMESPACE" --replicas="$REPLICAS"
        
        # Update gateway config with new vLLM URLs
        VLLM_URLS=""
        for i in $(seq 0 $((REPLICAS - 1))); do
            if [ -n "$VLLM_URLS" ]; then
                VLLM_URLS="${VLLM_URLS},"
            fi
            VLLM_URLS="${VLLM_URLS}http://vllm-${i}.vllm:8000"
        done
        
        kubectl patch configmap gateway-config -n "$NAMESPACE" \
            --type merge -p "{\"data\":{\"VLLM_URLS\":\"$VLLM_URLS\"}}"
        
        # Restart gateway to pick up new config
        kubectl rollout restart deployment/gateway -n "$NAMESPACE"
        
        echo -e "${GREEN}✓ vLLM scaled to $REPLICAS replicas${NC}"
        echo "   Gateway updated with URLs: $VLLM_URLS"
        ;;
    
    llamacpp)
        echo "Scaling llama.cpp to $REPLICAS replicas..."
        kubectl scale deployment llamacpp -n "$NAMESPACE" --replicas="$REPLICAS"
        echo -e "${GREEN}✓ llama.cpp scaled to $REPLICAS replicas${NC}"
        ;;
    
    gateway)
        echo "Scaling gateway to $REPLICAS replicas..."
        kubectl scale deployment gateway -n "$NAMESPACE" --replicas="$REPLICAS"
        echo -e "${GREEN}✓ Gateway scaled to $REPLICAS replicas${NC}"
        ;;
    
    embedding)
        echo "Scaling embedding service to $REPLICAS replicas..."
        kubectl scale deployment embedding -n "$NAMESPACE" --replicas="$REPLICAS"
        echo -e "${GREEN}✓ Embedding service scaled to $REPLICAS replicas${NC}"
        ;;
    
    *)
        echo -e "${RED}Unknown backend: $BACKEND${NC}"
        usage
        exit 1
        ;;
esac

echo ""
echo "Current status:"
kubectl get pods -n "$NAMESPACE" -l "app in ($BACKEND, llmapi-gateway)" 2>/dev/null || \
    kubectl get pods -n "$NAMESPACE"
