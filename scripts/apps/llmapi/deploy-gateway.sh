#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

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

GATEWAY_CODE_SHA=$(sha256sum "$MAIN_FILE" | awk '{print $1}')
ROLLOUT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📄 Updating gateway code ConfigMap..."
kubectl create configmap gateway-code -n "$NAMESPACE" \
    --from-file=main.py="$MAIN_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "🚀 Rolling gateway deployment..."
kubectl patch deployment gateway -n "$NAMESPACE" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"llmapi.mynodeone.io/gateway-code-sha\":\"$GATEWAY_CODE_SHA\",\"kubectl.kubernetes.io/restartedAt\":\"$ROLLOUT_AT\"}}}}}" >/dev/null

kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT"

echo -e "${GREEN}✓ Gateway updated${NC}"
