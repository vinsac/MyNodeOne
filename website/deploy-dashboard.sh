#!/bin/bash

###############################################################################
# Deploy MyNodeOne Dashboard
# 
# Deploys the local dashboard accessible at mynodeone.local
# Shows cluster info, installed services, and one-click app installation
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="mynodeone-dashboard"

echo "📦 Deploying MyNodeOne Dashboard..."

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap with dashboard HTML
kubectl create configmap dashboard-html \
    --from-file=index.html="$SCRIPT_DIR/dashboard.html" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy nginx with dashboard
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard
  namespace: $NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dashboard
  template:
    metadata:
      labels:
        app: dashboard
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
      volumes:
      - name: html
        configMap:
          name: dashboard-html
---
apiVersion: v1
kind: Service
metadata:
  name: dashboard
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: dashboard
EOF

# Wait for deployment
echo "⏳ Waiting for dashboard to start..."
kubectl wait --for=condition=available --timeout=120s deployment/dashboard -n "$NAMESPACE" 2>/dev/null || true

# Get service IP
sleep 5
SERVICE_IP=$(kubectl get svc dashboard -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc dashboard -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "pending")
fi

echo ""
echo "✓ Dashboard deployed successfully!"
echo ""
echo "📍 Access at: http://$SERVICE_IP"
echo "📍 Will also be available at: http://mynodeone.local (after DNS setup)"
echo ""

# Return the IP for use in other scripts
echo "$SERVICE_IP"
