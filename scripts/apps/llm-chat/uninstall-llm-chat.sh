#!/bin/bash

###############################################################################
# LLM Chat - Uninstallation Script
# 
# Removes Open WebUI and Ollama from the cluster
###############################################################################

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  Uninstalling LLM Chat (Open WebUI + Ollama)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${RED}WARNING: This will delete all chat history and downloaded models!${NC}"
echo ""
read -p "Are you sure you want to uninstall? [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "Deleting LLM Chat namespace (contains Ollama + Open WebUI)..."
kubectl delete namespace llm-chat --ignore-not-found=true

echo ""
echo "Waiting for namespace deletion to complete..."
sleep 5

echo ""
echo -e "${YELLOW}✓ LLM Chat uninstalled${NC}"
echo ""
echo "Note: PersistentVolumes may still exist in Longhorn."
echo "To completely remove storage, delete them manually from Longhorn UI."
echo ""
