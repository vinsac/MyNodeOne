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
PRE_DOWNLOAD_DIR="${PRE_DOWNLOAD_DIR:-/var/lib/llmapi/models}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  LLM API - Copy Pre-Downloaded Models${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if namespace exists
if ! kubectl get namespace $NAMESPACE &>/dev/null; then
    echo -e "${RED}❌ Namespace '$NAMESPACE' not found. Please install LLM API first.${NC}"
    exit 1
fi

# Runs a copy and records whether it copied, skipped or failed.
run_copy() {
    local status=0
    copy_models_to_pvc "$@" || status=$?
    case "$status" in
        0) COPIED="$COPIED $1" ;;
        2) SKIPPED="$SKIPPED $1" ;;
        *) FAILED="$FAILED $1" ;;
    esac
}

# Puts the service back at the replica count it had before the copy.
restore_replicas() {
    local model_type="$1" replicas="$2"
    [ -n "$replicas" ] || return 0
    case "$model_type" in
        vllm) kubectl scale statefulset/vllm --replicas="$replicas" -n $NAMESPACE || true ;;
        llamacpp) kubectl scale deployment/llamacpp --replicas="$replicas" -n $NAMESPACE || true ;;
        embedding) kubectl scale deployment/embedding --replicas="$replicas" -n $NAMESPACE || true ;;
    esac
}

# Copies models to a PVC. Returns 0 if copied, 2 if skipped because the PVC isn't
# available, and 1 if the copy failed.
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
        return 2
    fi

    local pvc_status=$(kubectl get pvc $pvc_name -n $NAMESPACE -o jsonpath='{.status.phase}')
    if [ "$pvc_status" != "Bound" ]; then
        echo -e "   ${YELLOW}⚠ PVC $pvc_name not bound (status: $pvc_status), skipping${NC}"
        return 2
    fi
    
    # Scale down the deployment/statefulset to avoid conflicts
    echo "   🔄 Scaling down $model_type service..."
    local original_replicas=""
    case "$model_type" in
        vllm)
            original_replicas=$(kubectl get statefulset/vllm -n $NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
            kubectl scale statefulset/vllm --replicas=0 -n $NAMESPACE --timeout=60s || true
            ;;
        llamacpp)
            original_replicas=$(kubectl get deployment/llamacpp -n $NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
            kubectl scale deployment/llamacpp --replicas=0 -n $NAMESPACE --timeout=60s || true
            ;;
        embedding)
            original_replicas=$(kubectl get deployment/embedding -n $NAMESPACE -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
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

    # Wait for copy to complete. Don't wait for Ready first: a pod that finishes quickly
    # is never reported Ready.
    echo "   ⏳ Waiting for copy to complete..."
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/$copy_pod -n $NAMESPACE --timeout=900s || {
        echo -e "   ${RED}❌ Copy operation timed out or failed${NC}"
        kubectl logs $copy_pod -n $NAMESPACE 2>/dev/null || true
        kubectl delete pod $copy_pod -n $NAMESPACE --ignore-not-found
        restore_replicas "$model_type" "$original_replicas"
        return 1
    }
    
    # Show copy results
    echo "   📋 Copy results:"
    kubectl logs $copy_pod -n $NAMESPACE | tail -10
    
    # Clean up copy pod
    kubectl delete pod $copy_pod -n $NAMESPACE --ignore-not-found
    
    # Scale back up
    echo "   🔄 Scaling up $model_type service..."
    restore_replicas "$model_type" "$original_replicas"

    echo -e "   ${GREEN}✅ $model_type models copied successfully${NC}"
    echo ""
}

# Check what models are available to copy
echo "🔍 Checking for pre-downloaded models..."
echo ""

FOUND_MODELS=false
COPIED=""
SKIPPED=""
FAILED=""

# vLLM models
if [ -d "$PRE_DOWNLOAD_DIR/vllm" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/vllm 2>/dev/null)" ]; then
    echo "Found vLLM models:"
    ls -la "$PRE_DOWNLOAD_DIR/vllm"
    echo ""
    FOUND_MODELS=true
    run_copy "vllm" "/predownloaded/vllm" "vllm-models" "/models"
fi

# llama.cpp models  
if [ -d "$PRE_DOWNLOAD_DIR/llamacpp" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/llamacpp/*.gguf 2>/dev/null)" ]; then
    echo "Found llama.cpp models:"
    ls -la "$PRE_DOWNLOAD_DIR/llamacpp"/*.gguf
    echo ""
    FOUND_MODELS=true
    run_copy "llamacpp" "/predownloaded/llamacpp" "llamacpp-models" "/models"
fi

# Embedding models
if [ -d "$PRE_DOWNLOAD_DIR/embedding" ] && [ -n "$(ls -A $PRE_DOWNLOAD_DIR/embedding/*.gguf 2>/dev/null)" ]; then
    echo "Found embedding models:"
    ls -la "$PRE_DOWNLOAD_DIR/embedding"/*.gguf
    echo ""
    FOUND_MODELS=true
    run_copy "embedding" "/predownloaded/embedding" "embedding-models" "/models"
fi

if [ "$FOUND_MODELS" = false ]; then
    echo -e "${YELLOW}⚠ No pre-downloaded models found in $PRE_DOWNLOAD_DIR${NC}"
    echo ""
    echo "The backends download their models on first start."
    exit 0
fi

if [ -n "$COPIED" ]; then
    echo -e "${GREEN}✅ Copied:$COPIED${NC}"
fi
if [ -n "$SKIPPED" ]; then
    echo -e "${YELLOW}⚠ Skipped, no matching PVC:$SKIPPED${NC}"
    echo "   The current manifests read models directly from $PRE_DOWNLOAD_DIR on the node,"
    echo "   so backends without a PVC need no copy and will use those files as they are."
fi
if [ -n "$FAILED" ]; then
    echo -e "${RED}❌ Failed:$FAILED${NC}"
    exit 1
fi
echo ""
echo "📊 Check service status:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "🔍 Monitor service startup:"
echo "  kubectl logs -n $NAMESPACE statefulset/vllm -f"
echo "  kubectl logs -n $NAMESPACE deployment/llamacpp -f"
