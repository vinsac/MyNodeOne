#!/bin/bash

###############################################################################
# Homepage - One-Click Installation
# 
# Modern, fully customizable application dashboard
# Beautiful homepage to organize all your self-hosted services
###############################################################################

set -euo pipefail

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null
source "$PROJECT_ROOT/scripts/apps/lib/validation.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load configuration
if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi
CONFIG_FILE="$ACTUAL_HOME/.mynodeone/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Homepage Dashboard${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

# Prompt for subdomain
echo "🌐 App Subdomain Configuration"
echo ""
echo "Choose a subdomain for Homepage. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: home, homepage, dash, dashboard"
echo ""
read -p "Enter subdomain [default: homepage]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-homepage}"

# Sanitize subdomain
APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "homepage")

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

NAMESPACE="homepage"
warn_if_namespace_exists "$NAMESPACE"

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🏠 Deploying Homepage..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: homepage
  template:
    metadata:
      labels:
        app: homepage
    spec:
      priorityClassName: mynodeone-app
      containers:
      - name: homepage
        image: ghcr.io/gethomepage/homepage:latest
        ports:
        - containerPort: 3000
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
          limits:
            memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: homepage
  namespace: $NAMESPACE
  annotations:
    mynodeone.io/subdomain: "$APP_SUBDOMAIN"
spec:
  type: LoadBalancer
  ports:
  - port: 3000
    targetPort: 3000
  selector:
    app: homepage
EOF

echo "⏳ Waiting for Homepage to start..."
kubectl wait --for=condition=available --timeout=180s deployment/homepage -n "$NAMESPACE"

sleep 10
SERVICE_IP=$(kubectl get svc homepage -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Homepage installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Homepage at: http://$SERVICE_IP:3000"
echo ""

# Register service in service registry
echo "📝 Registering service in registry..."
if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "homepage" "$APP_SUBDOMAIN" "$NAMESPACE" "homepage" "3000" "false"; then
        echo "✓ Service registered in registry"

        # Verify registration
        echo "🔍 Verifying registration..."
        REGISTERED_LOCAL_NAME=$(kubectl get configmap -n kube-system service-registry \
            -o jsonpath='{.data.services\.json}' 2>/dev/null | \
            jq -r '.homepage.local_name' 2>/dev/null || echo "")

        if [ "$REGISTERED_LOCAL_NAME" = "$APP_SUBDOMAIN" ]; then
            echo "✓ Verified: Service registered with local_name '$APP_SUBDOMAIN'"
        else
            echo -e "${YELLOW}⚠️  Registration verification failed${NC}"
            echo "   Expected local_name: $APP_SUBDOMAIN"
            echo "   Got: $REGISTERED_LOCAL_NAME"
        fi
        echo ""

        # Update local DNS
        if [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
            if sudo bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" --quiet 2>/dev/null; then
                echo "✓ Local DNS updated"
            fi
        fi
    else
        echo -e "${YELLOW}⚠️  Could not register service${NC}"
    fi
fi

echo ""
echo "📍 Access Information:"
echo "   Local URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

# Source post-install routing for public access configuration
if [ -f "$PROJECT_ROOT/scripts/lib/post-install-routing.sh" ]; then
    source "$PROJECT_ROOT/scripts/lib/post-install-routing.sh" "homepage" "3000" "$APP_SUBDOMAIN" "$NAMESPACE" "homepage"
fi

echo -e "${GREEN}Installation complete! 🎉${NC}"
