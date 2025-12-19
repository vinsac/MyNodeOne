#!/bin/bash

###############################################################################
# LLM API Monitoring
# 
# Monitor status, health, and metrics of the LLM API service.
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="llmapi"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: LLM API not installed. Run install-llmapi.sh first.${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  LLM API Service Status${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# =============================================================================
# Pod Status
# =============================================================================

echo -e "${BLUE}📦 Pods${NC}"
echo "────────────────────────────────────────────────────────"

kubectl get pods -n "$NAMESPACE" -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' \
    2>/dev/null || kubectl get pods -n "$NAMESPACE"

echo ""

# =============================================================================
# Service Endpoints
# =============================================================================

echo -e "${BLUE}🌐 Services${NC}"
echo "────────────────────────────────────────────────────────"

SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc llmapi -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
fi

echo "   Gateway:    http://$SERVICE_IP (llmapi service)"

VLLM_STATUS="not deployed"
if kubectl get statefulset vllm -n "$NAMESPACE" &>/dev/null; then
    VLLM_READY=$(kubectl get statefulset vllm -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    VLLM_DESIRED=$(kubectl get statefulset vllm -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    VLLM_STATUS="$VLLM_READY/$VLLM_DESIRED ready"
fi
echo "   vLLM:       $VLLM_STATUS"

LLAMACPP_STATUS="not deployed"
if kubectl get deployment llamacpp -n "$NAMESPACE" &>/dev/null; then
    LLAMACPP_READY=$(kubectl get deployment llamacpp -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    LLAMACPP_DESIRED=$(kubectl get deployment llamacpp -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    LLAMACPP_STATUS="$LLAMACPP_READY/$LLAMACPP_DESIRED ready"
fi
echo "   llama.cpp:  $LLAMACPP_STATUS"

EMBEDDING_STATUS="not deployed"
if kubectl get deployment embedding -n "$NAMESPACE" &>/dev/null; then
    EMBEDDING_READY=$(kubectl get deployment embedding -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    EMBEDDING_DESIRED=$(kubectl get deployment embedding -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    EMBEDDING_STATUS="$EMBEDDING_READY/$EMBEDDING_DESIRED ready"
fi
echo "   Embedding:  $EMBEDDING_STATUS"

echo ""

# =============================================================================
# Health Check
# =============================================================================

echo -e "${BLUE}🏥 Health Check${NC}"
echo "────────────────────────────────────────────────────────"

# Gateway health
GATEWAY_HEALTH="❌ unhealthy"
if curl -s --max-time 5 "http://$SERVICE_IP/health" &>/dev/null; then
    GATEWAY_HEALTH="✅ healthy"
fi
echo "   Gateway:    $GATEWAY_HEALTH"

# vLLM health (via internal service)
VLLM_HEALTH="⏭️  not deployed"
if kubectl get statefulset vllm -n "$NAMESPACE" &>/dev/null; then
    VLLM_POD=$(kubectl get pods -n "$NAMESPACE" -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$VLLM_POD" ]; then
        if kubectl exec -n "$NAMESPACE" "$VLLM_POD" -- curl -s --max-time 5 http://localhost:8000/health &>/dev/null; then
            VLLM_HEALTH="✅ healthy"
        else
            VLLM_HEALTH="❌ unhealthy"
        fi
    fi
fi
echo "   vLLM:       $VLLM_HEALTH"

# llama.cpp health
LLAMACPP_HEALTH="⏭️  not deployed"
if kubectl get deployment llamacpp -n "$NAMESPACE" &>/dev/null; then
    LLAMACPP_POD=$(kubectl get pods -n "$NAMESPACE" -l app=llamacpp -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$LLAMACPP_POD" ]; then
        if kubectl exec -n "$NAMESPACE" "$LLAMACPP_POD" -- curl -s --max-time 5 http://localhost:8080/health &>/dev/null 2>&1; then
            LLAMACPP_HEALTH="✅ healthy"
        else
            LLAMACPP_HEALTH="❌ unhealthy (may be loading model)"
        fi
    fi
fi
echo "   llama.cpp:  $LLAMACPP_HEALTH"

echo ""

# =============================================================================
# Resource Usage
# =============================================================================

echo -e "${BLUE}📊 Resource Usage${NC}"
echo "────────────────────────────────────────────────────────"

kubectl top pods -n "$NAMESPACE" 2>/dev/null || echo "   (metrics-server not available)"

echo ""

# =============================================================================
# GPU Usage (if available)
# =============================================================================

GPU_PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].spec.containers[*].resources.limits.nvidia\.com/gpu}' 2>/dev/null || echo "")
if [ -n "$GPU_PODS" ] && [ "$GPU_PODS" != "null" ]; then
    echo -e "${BLUE}🎮 GPU Status${NC}"
    echo "────────────────────────────────────────────────────────"
    
    # Try to get GPU info from vLLM pod
    VLLM_POD=$(kubectl get pods -n "$NAMESPACE" -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$VLLM_POD" ]; then
        kubectl exec -n "$NAMESPACE" "$VLLM_POD" -- nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "   Unable to query GPU"
    fi
    echo ""
fi

# =============================================================================
# Queue Status
# =============================================================================

echo -e "${BLUE}📋 Queue Status${NC}"
echo "────────────────────────────────────────────────────────"

REDIS_POD=$(kubectl get pods -n "$NAMESPACE" -l app=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$REDIS_POD" ]; then
    for priority in realtime high normal low batch; do
        count=$(kubectl exec -n "$NAMESPACE" "$REDIS_POD" -- redis-cli ZCARD "queue:$priority" 2>/dev/null || echo "0")
        echo "   $priority: $count"
    done
else
    echo "   (Redis not available)"
fi

echo ""

# =============================================================================
# Recent Logs
# =============================================================================

echo -e "${BLUE}📜 Recent Events${NC}"
echo "────────────────────────────────────────────────────────"

kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || echo "   No recent events"

echo ""

# =============================================================================
# Quick Commands
# =============================================================================

echo -e "${BLUE}🔧 Quick Commands${NC}"
echo "────────────────────────────────────────────────────────"
echo ""
echo "   # View gateway logs"
echo "   kubectl logs -n $NAMESPACE -l app=llmapi-gateway -f"
echo ""
echo "   # View vLLM logs"
echo "   kubectl logs -n $NAMESPACE -l app=vllm -f"
echo ""
echo "   # View llama.cpp logs"
echo "   kubectl logs -n $NAMESPACE -l app=llamacpp -f"
echo ""
echo "   # Test API"
echo "   curl http://$SERVICE_IP/v1/models -H 'Authorization: Bearer \$(cat ~/.mynodeone/llmapi-key)'"
echo ""
