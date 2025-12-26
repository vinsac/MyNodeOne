#!/bin/bash

###############################################################################
# Unload LLM Models from Memory
# 
# Immediately frees RAM by unloading models from Ollama
# Useful after using large models like 70B
###############################################################################

set -euo pipefail

NAMESPACE="llm-chat"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Unload LLM Models from Memory${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Get Ollama pod
OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$OLLAMA_POD" ]; then
    echo -e "${YELLOW}Ollama pod not found. Is LLM Chat installed?${NC}"
    exit 1
fi

# Check memory before
echo "📊 Memory usage BEFORE unload:"
kubectl top pod -n "$NAMESPACE" "$OLLAMA_POD" 2>/dev/null || echo "  (Metrics not available)"
echo ""

# Check what's loaded
echo "🔍 Currently loaded models:"
kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- ollama ps 2>/dev/null
echo ""

# Get list of loaded models
LOADED_MODELS=$(kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- ollama ps 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v "^$" || echo "")

if [ -z "$LOADED_MODELS" ]; then
    echo -e "${GREEN}✓ No models loaded in memory${NC}"
    echo ""
    exit 0
fi

# Count models
MODEL_COUNT=$(echo "$LOADED_MODELS" | wc -l)
echo "Found $MODEL_COUNT model(s) loaded in RAM"
echo ""

# Ask for confirmation
read -p "Unload all models? [y/N]: " CONFIRM
if [ "${CONFIRM,,}" != "y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "🗑️  Unloading models..."
echo ""

# Unload each model by setting keep_alive=0
while IFS= read -r model; do
    if [ -n "$model" ]; then
        echo "  • Unloading: $model"
        kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- \
            curl -s -X POST http://localhost:11434/api/generate \
            -d "{\"model\":\"$model\",\"keep_alive\":0}" >/dev/null 2>&1 || true
    fi
done <<< "$LOADED_MODELS"

echo ""
echo "⏳ Waiting for models to unload..."
sleep 10

# Check memory after
echo ""
echo "📊 Memory usage AFTER unload:"
kubectl top pod -n "$NAMESPACE" "$OLLAMA_POD" 2>/dev/null || echo "  (Metrics not available)"
echo ""

echo "🔍 Remaining loaded models:"
kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- ollama ps 2>/dev/null
echo ""

echo -e "${GREEN}✓ Models unloaded!${NC}"
echo ""
echo "💡 Tips:"
echo "  • Models will auto-unload after 2 minutes of inactivity"
echo "  • Adjust with: kubectl set env deployment/ollama -n llm-chat OLLAMA_KEEP_ALIVE=<time>"
echo "  • Examples: 30s, 1m, 5m, 1h"
echo ""
