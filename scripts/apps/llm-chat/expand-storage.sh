#!/bin/bash

###############################################################################
# LLM Chat - Storage Expansion Script
# 
# Safely expand model or chat history storage for Open WebUI/Ollama
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  LLM Chat Storage Expansion${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespaces exist
OLLAMA_EXISTS=$(kubectl get namespace ollama &>/dev/null && echo "true" || echo "false")
WEBUI_EXISTS=$(kubectl get namespace open-webui &>/dev/null && echo "true" || echo "false")

if [ "$OLLAMA_EXISTS" = "false" ] && [ "$WEBUI_EXISTS" = "false" ]; then
    echo -e "${RED}Error: LLM Chat not found. Is it installed?${NC}"
    exit 1
fi

# Get current storage sizes
echo "📊 Current Storage Allocation:"
echo ""

if [ "$OLLAMA_EXISTS" = "true" ]; then
    CURRENT_MODEL_SIZE=$(kubectl get pvc ollama-data -n ollama -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "N/A")
    ACTUAL_MODEL_SIZE=$(kubectl get pvc ollama-data -n ollama -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "$CURRENT_MODEL_SIZE")
    echo "  AI Models: $ACTUAL_MODEL_SIZE (requested: $CURRENT_MODEL_SIZE)"
else
    echo "  AI Models: Not installed"
    CURRENT_MODEL_SIZE="N/A"
fi

if [ "$WEBUI_EXISTS" = "true" ]; then
    CURRENT_WEBUI_SIZE=$(kubectl get pvc open-webui-data -n open-webui -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "N/A")
    ACTUAL_WEBUI_SIZE=$(kubectl get pvc open-webui-data -n open-webui -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "$CURRENT_WEBUI_SIZE")
    echo "  Chat History: $ACTUAL_WEBUI_SIZE (requested: $CURRENT_WEBUI_SIZE)"
else
    echo "  Chat History: Not installed"
    CURRENT_WEBUI_SIZE="N/A"
fi

echo ""
echo "Which storage would you like to expand?"
OPTIONS=()
if [ "$OLLAMA_EXISTS" = "true" ]; then
    OPTIONS+=("1) AI Models storage")
fi
if [ "$WEBUI_EXISTS" = "true" ]; then
    OPTIONS+=("2) Chat History storage")
fi
if [ "$OLLAMA_EXISTS" = "true" ] && [ "$WEBUI_EXISTS" = "true" ]; then
    OPTIONS+=("3) Both")
fi

for opt in "${OPTIONS[@]}"; do
    echo "  $opt"
done
echo ""
read -p "Enter choice: " CHOICE

EXPAND_MODELS=false
EXPAND_WEBUI=false

case $CHOICE in
    1)
        if [ "$OLLAMA_EXISTS" = "true" ]; then
            EXPAND_MODELS=true
        else
            echo -e "${RED}Invalid choice${NC}"
            exit 1
        fi
        ;;
    2)
        if [ "$WEBUI_EXISTS" = "true" ]; then
            EXPAND_WEBUI=true
        else
            echo -e "${RED}Invalid choice${NC}"
            exit 1
        fi
        ;;
    3)
        if [ "$OLLAMA_EXISTS" = "true" ] && [ "$WEBUI_EXISTS" = "true" ]; then
            EXPAND_MODELS=true
            EXPAND_WEBUI=true
        else
            echo -e "${RED}Invalid choice${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

# Expand model storage
if [ "$EXPAND_MODELS" = "true" ]; then
    echo ""
    echo "🤖 Expanding AI Model Storage"
    echo ""
    echo "Current size: $CURRENT_MODEL_SIZE"
    echo ""
    echo "Recommended sizes:"
    echo "  • 100Gi  - Good for 4-5 small models (7B-8B)"
    echo "  • 200Gi  - Good for 8-10 models or larger models"
    echo "  • 500Gi  - Good for many models including 70B+ models"
    echo "  • 1Ti    - Good for extensive model library"
    echo ""
    read -p "Enter new size (e.g., 200Gi): " NEW_MODEL_SIZE
    
    if [ -z "$NEW_MODEL_SIZE" ]; then
        echo -e "${RED}Error: Size cannot be empty${NC}"
        exit 1
    fi
    
    echo ""
    echo "Expanding ollama-data PVC to $NEW_MODEL_SIZE..."
    kubectl patch pvc ollama-data -n ollama -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_MODEL_SIZE\"}}}}"
    
    echo "✓ Storage expansion requested"
    echo ""
    echo "Note: Longhorn will automatically expand the volume."
    echo "The Ollama pod may restart during expansion."
fi

# Expand chat history storage
if [ "$EXPAND_WEBUI" = "true" ]; then
    echo ""
    echo "💬 Expanding Chat History Storage"
    echo ""
    echo "Current size: $CURRENT_WEBUI_SIZE"
    echo ""
    echo "Recommended sizes:"
    echo "  • 10Gi   - Good for thousands of conversations"
    echo "  • 20Gi   - Good for extensive chat history"
    echo "  • 50Gi   - Good for very large chat archives"
    echo ""
    read -p "Enter new size (e.g., 20Gi): " NEW_WEBUI_SIZE
    
    if [ -z "$NEW_WEBUI_SIZE" ]; then
        echo -e "${RED}Error: Size cannot be empty${NC}"
        exit 1
    fi
    
    echo ""
    echo "Expanding open-webui-data PVC to $NEW_WEBUI_SIZE..."
    kubectl patch pvc open-webui-data -n open-webui -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_WEBUI_SIZE\"}}}}"
    
    echo "✓ Storage expansion requested"
    echo ""
    echo "Note: Longhorn will automatically expand the volume."
    echo "The Open WebUI pod may restart during expansion."
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Storage Expansion Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "You can verify the new sizes with:"
if [ "$EXPAND_MODELS" = "true" ]; then
    echo "  kubectl get pvc ollama-data -n ollama"
fi
if [ "$EXPAND_WEBUI" = "true" ]; then
    echo "  kubectl get pvc open-webui-data -n open-webui"
fi
echo ""
