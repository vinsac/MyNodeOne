#!/bin/bash

###############################################################################
# Nextcloud - Performance Tuning Script
# 
# Optimize Nextcloud resource allocation for better performance
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="nextcloud"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Nextcloud Performance Tuning${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Nextcloud namespace not found. Is Nextcloud installed?${NC}"
    exit 1
fi

echo "🔍 When to Tune Performance:"
echo ""
echo "Consider tuning if you experience:"
echo "  • Slow file uploads/downloads"
echo "  • Sluggish web interface"
echo "  • Timeouts during large file operations"
echo "  • High CPU/memory usage warnings"
echo "  • Multiple concurrent users"
echo ""

# Get current resource allocation for all components
echo "📊 Current Resource Allocation:"
echo ""

NEXTCLOUD_CPU_LIMIT=$(kubectl get deployment nextcloud -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "1000m")
NEXTCLOUD_MEM_LIMIT=$(kubectl get deployment nextcloud -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "2Gi")
POSTGRES_CPU_LIMIT=$(kubectl get deployment nextcloud-postgres -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "500m")
POSTGRES_MEM_LIMIT=$(kubectl get deployment nextcloud-postgres -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "1Gi")

echo "  Nextcloud:"
echo "    CPU: $NEXTCLOUD_CPU_LIMIT"
echo "    Memory: $NEXTCLOUD_MEM_LIMIT"
echo ""
echo "  PostgreSQL:"
echo "    CPU: $POSTGRES_CPU_LIMIT"
echo "    Memory: $POSTGRES_MEM_LIMIT"
echo ""

echo "🎯 What would you like to tune?"
echo ""
echo "1. Nextcloud server resources (for file operations, web interface)"
echo "2. PostgreSQL resources (for database performance)"
echo "3. PHP settings (upload limits, execution time)"
echo "4. All of the above"
echo "5. Cancel"
echo ""
read -p "Select option [1-5]: " OPTION

case $OPTION in
    1|4)
        echo ""
        echo "💪 Nextcloud Server Resource Tuning"
        echo ""
        echo "Recommendations based on usage:"
        echo "  Personal (1-3 users):"
        echo "    • CPU: 1 core (1000m)"
        echo "    • Memory: 2Gi"
        echo ""
        echo "  Small Family (3-10 users):"
        echo "    • CPU: 2 cores (2000m)"
        echo "    • Memory: 4Gi"
        echo ""
        echo "  Team (10-50 users):"
        echo "    • CPU: 4 cores (4000m)"
        echo "    • Memory: 8Gi"
        echo ""
        echo "  Large Team (50+ users):"
        echo "    • CPU: 8 cores (8000m)"
        echo "    • Memory: 16Gi"
        echo ""
        echo "Current: CPU=$NEXTCLOUD_CPU_LIMIT, Memory=$NEXTCLOUD_MEM_LIMIT"
        echo ""
        read -p "Enter new CPU limit (e.g., 2000m for 2 cores) [default: 2000m]: " NEW_NC_CPU
        NEW_NC_CPU="${NEW_NC_CPU:-2000m}"
        
        read -p "Enter new memory limit (e.g., 4Gi) [default: 4Gi]: " NEW_NC_MEM
        NEW_NC_MEM="${NEW_NC_MEM:-4Gi}"
        
        echo ""
        echo "🚀 Updating Nextcloud resources..."
        kubectl patch deployment nextcloud -n "$NAMESPACE" --type='json' -p="[
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$NEW_NC_CPU\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$NEW_NC_MEM\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"200m\"},
          {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"512Mi\"}
        ]"
        
        echo "✓ Nextcloud resources updated"
        echo ""
        
        if [ "$OPTION" != "4" ]; then
            echo "⏳ Waiting for rollout..."
            kubectl rollout status deployment/nextcloud -n "$NAMESPACE" --timeout=120s
            echo ""
            echo -e "${GREEN}✓ Nextcloud performance tuning complete!${NC}"
            exit 0
        fi
        ;;
    5)
        echo "Cancelled."
        exit 0
        ;;
esac

if [ "$OPTION" = "2" ] || [ "$OPTION" = "4" ]; then
    echo ""
    echo "🗄️ PostgreSQL Resource Tuning"
    echo ""
    echo "Recommendations:"
    echo "  Light usage (small files, few users):"
    echo "    • CPU: 500m"
    echo "    • Memory: 1Gi"
    echo ""
    echo "  Medium usage (moderate files/users):"
    echo "    • CPU: 1000m (1 core)"
    echo "    • Memory: 2Gi"
    echo ""
    echo "  Heavy usage (large files, many users):"
    echo "    • CPU: 2000m (2 cores)"
    echo "    • Memory: 4Gi"
    echo ""
    echo "Current: CPU=$POSTGRES_CPU_LIMIT, Memory=$POSTGRES_MEM_LIMIT"
    echo ""
    read -p "Enter new CPU limit [default: 1000m]: " NEW_PG_CPU
    NEW_PG_CPU="${NEW_PG_CPU:-1000m}"
    
    read -p "Enter new memory limit [default: 2Gi]: " NEW_PG_MEM
    NEW_PG_MEM="${NEW_PG_MEM:-2Gi}"
    
    echo ""
    echo "🚀 Updating PostgreSQL resources..."
    kubectl patch deployment nextcloud-postgres -n "$NAMESPACE" --type='json' -p="[
      {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/cpu\", \"value\": \"$NEW_PG_CPU\"},
      {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\": \"$NEW_PG_MEM\"},
      {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/cpu\", \"value\": \"100m\"},
      {\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/requests/memory\", \"value\": \"256Mi\"}
    ]"
    
    echo "✓ PostgreSQL resources updated"
    echo ""
fi

if [ "$OPTION" = "3" ] || [ "$OPTION" = "4" ]; then
    echo ""
    echo "⚙️ PHP Settings Tuning"
    echo ""
    echo "Current PHP limits can be increased for:"
    echo "  • Larger file uploads"
    echo "  • Longer execution times"
    echo "  • More memory for PHP processes"
    echo ""
    echo "Recommendations:"
    echo "  Small files (<100MB):"
    echo "    • Upload limit: 512M"
    echo "    • Memory limit: 512M"
    echo ""
    echo "  Medium files (100MB-1GB):"
    echo "    • Upload limit: 2G"
    echo "    • Memory limit: 1G"
    echo ""
    echo "  Large files (1GB-10GB):"
    echo "    • Upload limit: 16G"
    echo "    • Memory limit: 2G"
    echo ""
    read -p "Enter PHP upload limit [default: 2G]: " PHP_UPLOAD
    PHP_UPLOAD="${PHP_UPLOAD:-2G}"
    
    read -p "Enter PHP memory limit [default: 1G]: " PHP_MEMORY
    PHP_MEMORY="${PHP_MEMORY:-1G}"
    
    echo ""
    echo "🚀 Updating PHP settings..."
    kubectl set env deployment/nextcloud -n "$NAMESPACE" \
        PHP_MEMORY_LIMIT="$PHP_MEMORY" \
        PHP_UPLOAD_LIMIT="$PHP_UPLOAD"
    
    echo "✓ PHP settings updated"
    echo ""
fi

echo "⏳ Waiting for changes to apply..."
kubectl rollout status deployment/nextcloud -n "$NAMESPACE" --timeout=120s

if [ "$OPTION" = "2" ] || [ "$OPTION" = "4" ]; then
    kubectl rollout status deployment/nextcloud-postgres -n "$NAMESPACE" --timeout=120s
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Performance Tuning Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📊 New Resource Allocation:"
echo ""

if [ "$OPTION" = "1" ] || [ "$OPTION" = "4" ]; then
    echo "  Nextcloud:"
    echo "    CPU: $NEW_NC_CPU"
    echo "    Memory: $NEW_NC_MEM"
    echo ""
fi

if [ "$OPTION" = "2" ] || [ "$OPTION" = "4" ]; then
    echo "  PostgreSQL:"
    echo "    CPU: $NEW_PG_CPU"
    echo "    Memory: $NEW_PG_MEM"
    echo ""
fi

if [ "$OPTION" = "3" ] || [ "$OPTION" = "4" ]; then
    echo "  PHP Settings:"
    echo "    Upload limit: $PHP_UPLOAD"
    echo "    Memory limit: $PHP_MEMORY"
    echo ""
fi

echo "💡 Tips:"
echo "  • Monitor performance: kubectl top pods -n nextcloud"
echo "  • View logs: kubectl logs -f deployment/nextcloud -n nextcloud"
echo "  • Run this script again anytime to adjust settings"
echo ""
