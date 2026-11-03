#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

source "$SCRIPT_DIR/lib/install-helpers.sh"
source "$SCRIPT_DIR/lib/gateway-code.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="${NAMESPACE:-llmapi}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"
MAIN_FILE="$SCRIPT_DIR/gateway/main.py"

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if [ ! -f "$MAIN_FILE" ]; then
    echo -e "${RED}Error: Gateway source not found at $MAIN_FILE${NC}"
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: Namespace $NAMESPACE not found${NC}"
    exit 1
fi

GATEWAY_CODE_SHA=$(gateway_code_sha "$SCRIPT_DIR")
PREVIOUS_GENERATION=$(kubectl get deployment gateway -n "$NAMESPACE" -o 'jsonpath={.metadata.generation}' 2>/dev/null || true)

echo "📄 Updating gateway code ConfigMap..."
ship_gateway_code "$SCRIPT_DIR"
ship_gateway_static "$SCRIPT_DIR"

echo "🚀 Rolling gateway deployment..."
apply_gateway_deployment "$SCRIPT_DIR" "$GATEWAY_CODE_SHA" >/dev/null

# Callers also use this to pick up gateway-config changes, so it has to restart the
# pods even when the Deployment itself didn't change.
if [ "$(kubectl get deployment gateway -n "$NAMESPACE" -o 'jsonpath={.metadata.generation}' 2>/dev/null || true)" = "$PREVIOUS_GENERATION" ]; then
    kubectl rollout restart deployment/gateway -n "$NAMESPACE" >/dev/null
fi

kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"

echo -e "${GREEN}✓ Gateway updated${NC}"
