#!/bin/bash

###############################################################################
# Homepage - One-Click Installation
# 
# Modern, fully customizable application dashboard
# Beautiful homepage to organize all your self-hosted services
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Homepage Dashboard${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

NAMESPACE="homepage"

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
      containers:
      - name: homepage
        image: ghcr.io/gethomepage/homepage:latest
        ports:
        - containerPort: 3000
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "512Mi"
            cpu: "200m"
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
echo "💡 Customize your dashboard by editing the configuration!"
echo ""

# Configure DNS automatically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/../configure-app-dns.sh" > /dev/null 2>&1; then
    echo "✓ DNS configured! Access at: http://homepage.mynodeone.local"
    echo ""
fi
