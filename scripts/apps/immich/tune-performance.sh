#!/bin/bash

###############################################################################
# Immich - Performance Tuning Script
# 
# Optimize Immich for better video playback performance
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="immich"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Immich Performance Tuning${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Immich namespace not found. Is Immich installed?${NC}"
    exit 1
fi

echo "🔍 Current Performance Issues:"
echo ""
echo "Common video playback problems:"
echo "  • Buffering/stuttering during playback"
echo "  • Slow video loading"
echo "  • High CPU usage during video viewing"
echo ""
echo "This script will optimize Immich for better video performance."
echo ""

# Get current resource allocation
CURRENT_CPU_LIMIT=$(kubectl get deployment immich-server -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "4000m")
CURRENT_MEM_LIMIT=$(kubectl get deployment immich-server -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "8Gi")

echo "📊 Current Resource Allocation:"
echo "  CPU Limit: $CURRENT_CPU_LIMIT"
echo "  Memory Limit: $CURRENT_MEM_LIMIT"
echo ""

echo "🎯 Performance Tuning Options:"
echo ""
echo "1. Increase CPU allocation (recommended for video transcoding)"
echo "2. Enable hardware acceleration (if GPU available)"
echo "3. Configure transcoding settings"
echo "4. All of the above"
echo ""
read -p "Select option [1-4]: " OPTION

case $OPTION in
    1|4)
        echo ""
        echo "💪 CPU Allocation Tuning"
        echo ""
        echo "Video transcoding is CPU-intensive. Recommendations:"
        echo "  • 4 cores  - Basic (1-2 concurrent video streams)"
        echo "  • 6 cores  - Good (2-4 concurrent streams)"
        echo "  • 8 cores  - Better (4-6 concurrent streams)"
        echo "  • 12 cores - Best (6+ concurrent streams, 4K videos)"
        echo ""
        echo "Current limit: $CURRENT_CPU_LIMIT"
        echo ""
        read -p "Enter new CPU limit (e.g., 6000m for 6 cores) [default: 8000m]: " NEW_CPU_LIMIT
        NEW_CPU_LIMIT="${NEW_CPU_LIMIT:-8000m}"
        
        echo ""
        echo "💾 Memory Allocation"
        echo ""
        echo "Video transcoding also needs memory. Recommendations:"
        echo "  • 8Gi   - Basic"
        echo "  • 12Gi  - Good"
        echo "  • 16Gi  - Better (recommended for 4K)"
        echo "  • 24Gi  - Best (multiple 4K streams)"
        echo ""
        echo "Current limit: $CURRENT_MEM_LIMIT"
        echo ""
        read -p "Enter new memory limit [default: 16Gi]: " NEW_MEM_LIMIT
        NEW_MEM_LIMIT="${NEW_MEM_LIMIT:-16Gi}"
        
        echo ""
        echo "🚀 Updating resource allocation..."
        kubectl patch deployment immich-server -n "$NAMESPACE" --type='json' -p="[
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$NEW_CPU_LIMIT\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$NEW_MEM_LIMIT\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"2000m\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"4Gi\"}
        ]"
        
        echo "✓ Resources updated"
        echo ""
        ;;
esac

if [ "$OPTION" = "2" ] || [ "$OPTION" = "4" ]; then
    echo ""
    echo "🎮 Hardware Acceleration Setup"
    echo ""
    echo "Immich supports hardware acceleration for video transcoding:"
    echo "  • NVIDIA GPU (NVENC) - Best performance"
    echo "  • Intel QuickSync (QSV) - Good performance"
    echo "  • VAAPI - Basic acceleration"
    echo ""
    
    read -p "Do you have a GPU available? [y/N]: " HAS_GPU
    
    if [[ "${HAS_GPU,,}" == "y" ]]; then
        echo ""
        echo "⚠️  GPU Setup Requirements:"
        echo "  1. NVIDIA GPU Operator must be installed on cluster"
        echo "  2. GPU must be available on the node"
        echo "  3. Immich will be redeployed with GPU support"
        echo ""
        read -p "Continue with GPU setup? [y/N]: " CONTINUE_GPU
        
        if [[ "${CONTINUE_GPU,,}" == "y" ]]; then
            echo ""
            echo "🎮 Enabling GPU acceleration..."
            
            # Add GPU resource request and NVIDIA runtime
            kubectl patch deployment immich-server -n "$NAMESPACE" --type='json' -p='[
              {"op": "add", "path": "/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu", "value": "1"}
            ]'
            
            # Add environment variables for hardware acceleration
            kubectl set env deployment/immich-server -n "$NAMESPACE" \
                IMMICH_MEDIA_FFMPEG_ACCEL=nvenc \
                IMMICH_MEDIA_FFMPEG_THREADS=0
            
            echo "✓ GPU acceleration enabled"
            echo ""
        fi
    else
        echo "ℹ️  Continuing without GPU acceleration"
        echo "   CPU transcoding will be used (slower but works)"
        echo ""
    fi
fi

if [ "$OPTION" = "3" ] || [ "$OPTION" = "4" ]; then
    echo ""
    echo "⚙️  Transcoding Configuration"
    echo ""
    echo "Optimizing transcoding settings for better performance..."
    
    # Set optimal transcoding settings
    kubectl set env deployment/immich-server -n "$NAMESPACE" \
        IMMICH_MEDIA_FFMPEG_THREADS=0 \
        IMMICH_MEDIA_FFMPEG_CRF=23 \
        IMMICH_MEDIA_FFMPEG_PRESET=faster \
        IMMICH_MEDIA_TRANSCODE_TARGET_VIDEO_CODEC=h264 \
        IMMICH_MEDIA_TRANSCODE_TARGET_RESOLUTION=1080p
    
    echo "✓ Transcoding settings optimized"
    echo ""
    echo "Settings applied:"
    echo "  • Codec: H.264 (best browser compatibility)"
    echo "  • Resolution: 1080p (good quality/performance balance)"
    echo "  • Preset: faster (quicker transcoding)"
    echo "  • CRF: 23 (good quality)"
    echo ""
fi

echo "🔄 Restarting Immich server to apply changes..."
kubectl rollout restart deployment/immich-server -n "$NAMESPACE"

echo "⏳ Waiting for server to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/immich-server -n "$NAMESPACE" || true

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Performance Tuning Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📝 Next Steps:"
echo ""
echo "1. Test video playback in Immich"
echo "2. Monitor resource usage:"
echo "   kubectl top pod -n $NAMESPACE"
echo ""
echo "3. Check transcoding logs:"
echo "   kubectl logs -f deployment/immich-server -n $NAMESPACE | grep ffmpeg"
echo ""
echo "4. If still having issues:"
echo "   • Check if videos need pre-transcoding (Admin > Jobs > Transcode Videos)"
echo "   • Verify network bandwidth (should be >10Mbps for 1080p)"
echo "   • Consider upgrading hardware"
echo ""
echo "💡 Pro Tips:"
echo "  • Pre-transcode videos in Admin panel for instant playback"
echo "  • Use H.264 codec when recording videos (better compatibility)"
echo "  • Lower resolution (720p) if CPU is still struggling"
echo ""
