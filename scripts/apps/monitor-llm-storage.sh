#!/bin/bash

###############################################################################
# LLM Chat Storage Monitor
# 
# Automatically monitors Ollama storage and expands when usage is high
# Can be run as a cron job or one-time check
###############################################################################

set -euo pipefail

NAMESPACE="llm-chat"
USAGE_THRESHOLD=80  # Expand when usage exceeds this percentage
EXPAND_BY=200       # Add this many Gi when expanding

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if LLM chat is installed
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_error "LLM Chat namespace not found. Is it installed?"
    exit 1
fi

# Get Ollama pod
OLLAMA_POD=$(kubectl get pods -n "$NAMESPACE" -l app=ollama -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$OLLAMA_POD" ]; then
    log_error "Ollama pod not found"
    exit 1
fi

# Check if pod is running
POD_STATUS=$(kubectl get pod -n "$NAMESPACE" "$OLLAMA_POD" -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" != "Running" ]; then
    log_warn "Ollama pod is not running (status: $POD_STATUS)"
    exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  LLM Chat Storage Monitor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get storage usage
DISK_INFO=$(kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- df -h /home/ollama/.ollama 2>/dev/null | tail -1)
USAGE_PERCENT=$(echo "$DISK_INFO" | awk '{print $5}' | sed 's/%//')
USED=$(echo "$DISK_INFO" | awk '{print $3}')
AVAILABLE=$(echo "$DISK_INFO" | awk '{print $4}')
TOTAL=$(echo "$DISK_INFO" | awk '{print $2}')

log_info "Storage Status:"
echo "  Total:     $TOTAL"
echo "  Used:      $USED"
echo "  Available: $AVAILABLE"
echo "  Usage:     $USAGE_PERCENT%"
echo ""

# Get current PVC size
CURRENT_PVC_SIZE=$(kubectl get pvc ollama-data -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
log_info "PVC Size: $CURRENT_PVC_SIZE"
echo ""

# Check if expansion is needed
if [ "$USAGE_PERCENT" -ge "$USAGE_THRESHOLD" ]; then
    log_warn "Storage usage ($USAGE_PERCENT%) exceeds threshold ($USAGE_THRESHOLD%)"
    echo ""
    
    # Calculate new size
    CURRENT_NUM=$(echo "$CURRENT_PVC_SIZE" | sed 's/Gi//')
    NEW_SIZE="$((CURRENT_NUM + EXPAND_BY))Gi"
    
    log_info "Automatic expansion triggered"
    echo "  Current: $CURRENT_PVC_SIZE"
    echo "  New:     $NEW_SIZE"
    echo ""
    
    # Check if we're in auto mode
    if [ "${AUTO_EXPAND:-false}" = "true" ]; then
        log_info "AUTO_EXPAND enabled. Expanding storage..."
        echo ""
        
        # Patch PVC
        kubectl patch pvc ollama-data -n "$NAMESPACE" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_SIZE\"}}}}"
        
        log_info "Scaling down Ollama..."
        kubectl scale deployment ollama -n "$NAMESPACE" --replicas=0
        sleep 15
        
        log_info "Scaling back up..."
        kubectl scale deployment ollama -n "$NAMESPACE" --replicas=1
        sleep 30
        
        log_success "Storage expanded to $NEW_SIZE"
        echo ""
        
        # Send notification if command exists
        if command -v notify-send &>/dev/null; then
            notify-send "LLM Chat Storage" "Automatically expanded to $NEW_SIZE"
        fi
        
    else
        log_warn "Manual intervention required"
        echo ""
        echo "To expand storage automatically, run:"
        echo "  AUTO_EXPAND=true $0"
        echo ""
        echo "Or run the installation script:"
        echo "  sudo ./scripts/apps/install-llm-chat.sh"
        echo "  → Choose option 4 (Expand storage)"
        echo ""
    fi
else
    log_success "Storage usage is healthy ($USAGE_PERCENT% < $USAGE_THRESHOLD%)"
    echo ""
fi

# List models
log_info "Downloaded models:"
kubectl exec -n "$NAMESPACE" "$OLLAMA_POD" -- ollama list 2>/dev/null || echo "  (Could not retrieve model list)"
echo ""

# Show recommendations
if [ "$USAGE_PERCENT" -ge 70 ]; then
    echo "💡 Recommendations:"
    echo "  • Consider removing unused models"
    echo "  • Current usage is high - expansion may be needed soon"
    echo ""
    echo "To remove a model:"
    echo "  kubectl exec -n $NAMESPACE deployment/ollama -- ollama rm <model-name>"
    echo ""
fi
