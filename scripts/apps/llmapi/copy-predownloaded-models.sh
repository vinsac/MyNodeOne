#!/bin/bash

# LLM API - Copy Pre-Downloaded Models to PVCs
# This script copies pre-downloaded models to Kubernetes PVCs after deployment

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="llmapi"
PRE_DOWNLOAD_DIR="/var/lib/llmapi/models"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  LLM API - Copy Pre-Downloaded Models${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    echo -e "${RED}❌ Namespace '$NAMESPACE' not found. Please install LLM API first.${NC}"
    exit 1
fi

# Function to copy models to PVC
copy_models_to_pvc() {
    local model_type="$1"
    local source_path="$2"
    local pvc_name="$3"
    local target_path="$4"
    
    echo "📦 Copying $model_type models..."
    echo "   Source: $source_path"
    echo "   Target PVC: $pvc_name"
    
    # Check if PVC exists and is bound
    if ! kubectl get pvc $pvc_name -n $NAMESPACE &>/dev/null; then
        echo -e "   ${YELLOW}⚠ PVC $pvc_name not found, skipping${NC}"
        return 0
    fi
    
    local pvc_status=$(kubectl get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.status.phase}')
    if [ "$pvc_status" != "Bound" ]; then
        echo -e "   ${YELLOW}⚠ PVC $pvc_name not bound (status: $pvc_status), skipping${NC}"
        return 0
    fi
    
    # Scale down the deployment/statefulset to avoid conflicts
    echo "   🔄 Scaling down $model_type service..."
    case "$model_type" in
        vllm)
            kubectl scale statefulset/vllm --replicas=0 -n $NAMESPACE --timeout=60s || true
            ;;
        llamacpp)
            kubectl scale deployment/llamacpp --replicas=0 -n $NAMESPACE --timeout=60s || true
            ;;
        embedding)
            kubectl scale deployment/embedding --replicas=0 -n $NAMESPACE --timeout=60s || true
            ;;
    esac
    
    # Wait for pods to terminate
    sleep 10
    
    # Create copy pod
    local copy_pod="model-copy-$model_type-$$"
    
    echo "   📋 Creating copy pod..."
    cat <<COPYPOD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $copy_pod
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: copy
    image: busybox:1.35
    command: ["sh", "-c"]
    args:
    - |
      echo "Copying files from $source_path to $target_path"
      if [ -d "$source_path" ]; then
        mkdir -p "$target_path"
        cp -rv $source_path/* $target_path/
        echo "Copy completed successfully"
        ls -la $target_path/
      else
        echo "Source path $source_path not found"
        exit 1
      fi
    volumeMounts:
    - name: models-pvc
      mountPath: /models
    - name: predownloaded
      mountPath: /predownloaded
      readOnly: true
    securityContext:
      runAsNonRoot: false
      runAsUser: 0
  volumes:
  - name: models-pvc
    persistentVolumeClaim:
      claimName: $pvc_name
  - name: predownloaded
    hostPath:
      path: $PRE_DOWNLOAD_DIR
COPYPOD

    # Wait for copy to complete
    echo "   ⏳ Waiting for copy to complete..."
    kubectl wait --for=condition=Ready pod/$copy_pod -n $NAMESPACE --timeout=300s || {
        echo -e "   ${RED}❌ Copy pod failed to start${NC}"
        kubectl logs $copy_pod -n $NAMESPACE 2>/dev/null || true
        kubectl delete pod $copy_pod -n $NAMESPACE --ignore-not-found
        return 1
    }
    
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/$copy_pod -n $NAMESPACE --timeout=600s || {
        echo -e "   ${YELLOW}⚠ Copy operation timed out or failed${NC}"
        kubectl logs $copy_pod -n $NAMESPACE 2>/dev/null || true
        kubectl delete pod $copy_pod -n $NAMESPACE --ignore-not-found
        return 1
    }
    
    # Show copy results
    echo "   📋 Copy results:"
    kubectl logs $copy_pod -n $NAMESPACE | tail -10
    
    # Clean up copy pod
    kubectl delete pod $copy_pod -n $NAMESPACE --ignore-not-found
    
    # Scale back up
    echo "   🔄 Scaling up $model_type service..."
    case "$model_type" in
        vllm)
            kubectl scale statefulset/vllm --replicas=1 -n $NAMESPACE
            ;;
        llamacpp)
            kubectl scale deployment/llamacpp --replicas=1 -n $NAMESPACE
            ;;
        embedding)
            kubectl scale deployment/embedding --replicas=1 -n $NAMESPACE
            ;;
    esac
    
    echo -e "   ${GREEN}✅ $model_type models copied successfully${NC}"
    echo ""
}

# Check what models are available to copy
echo "🔍 Checking for pre-downloaded models..."
echo ""

MODELS_COPIED=false

# vLLM models
if [ -d "$PRE_DOWNLOAD_DIR/vllm" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/vllm 2>/dev/null)" ]; then
    echo "Found vLLM models:"
    ls -la "$PRE_DOWNLOAD_DIR/vllm"
    echo ""
    copy_models_to_pvc "vllm" "/predownloaded/vllm" "vllm-models" "/models"
    MODELS_COPIED=true
fi

# llama.cpp models  
if [ -d "$PRE_DOWNLOAD_DIR/llamacpp" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/llamacpp/*.gguf 2>/dev/null)" ]; then
    echo "Found llama.cpp models:"
    ls -la "$PRE_DOWNLOAD_DIR/llamacpp"/*.gguf
    echo ""
    copy_models_to_pvc "llamacpp" "/predownloaded/llamacpp" "llamacpp-models" "/models"
    MODELS_COPIED=true
fi

# Embedding models
if [ -d "$PRE_DOWNLOAD_DIR/embedding" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/embedding/*.gguf 2>/dev/null)" ]; then
    echo "Found embedding models:"
    ls -la "$PRE_DOWNLOAD_DIR/embedding"/*.gguf
    echo ""
    copy_models_to_pvc "embedding" "/predownloaded/embedding" "embedding-models" "/models"
    MODELS_COPIED=true
fi

if [ "$MODELS_COPIED" = false ]; then
    echo -e "${YELLOW}⚠ No pre-downloaded models found in $PRE_DOWNLOAD_DIR${NC}"
    echo ""
    echo "To download models, run:"
    echo "  sudo $SCRIPT_DIR/download-models.sh"
    exit 0
fi

echo -e "${GREEN}✅ Model copy operations completed!${NC}"
echo ""
echo "📊 Check service status:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "🔍 Monitor service startup:"
echo "  kubectl logs -n $NAMESPACE statefulset/vllm -f"
echo "  kubectl logs -n $NAMESPACE deployment/llamacpp -f"
