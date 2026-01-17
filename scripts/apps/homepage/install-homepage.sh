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
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Homepage Dashboard${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

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

# Configure DNS automatically
if bash "$PROJECT_ROOT/scripts/domains/configure-app-dns.sh" > /dev/null 2>&1; then
    # Load cluster domain
    CLUSTER_DOMAIN="mynodeone"
    if [ -f "$HOME/.mynodeone/config.env" ]; then
        source "$HOME/.mynodeone/config.env"
        CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
    fi
    echo "✓ DNS configured! Access at: http://homepage.${CLUSTER_DOMAIN}.local"
    echo ""
fi
