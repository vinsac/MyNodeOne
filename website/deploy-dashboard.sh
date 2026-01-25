#!/bin/bash

###############################################################################
# Deploy MyNodeOne Dashboard
# 
# Deploys the local dashboard accessible at <cluster-domain>.local
# Shows cluster info, installed services, and one-click app installation
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="mynodeone-dashboard"

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

echo "📦 Deploying MyNodeOne Dashboard..."
echo "🌐 Using domain: ${CLUSTER_DOMAIN}.local"

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create a temporary HTML file with domain replaced (no static service injection)
TEMP_HTML=$(mktemp)
sed "s/mynodeone\.local/${CLUSTER_DOMAIN}.local/g" "$SCRIPT_DIR/dashboard.html" > "$TEMP_HTML"

echo "✓ Dashboard will load services dynamically from /api/services.json"

# Create ConfigMap with all dashboard HTML files
kubectl create configmap dashboard-html \
    --from-file=index.html="$TEMP_HTML" \
    --from-file=app-store.html="$SCRIPT_DIR/app-store.html" \
    --from-file=scripts.html="$SCRIPT_DIR/scripts.html" \
    --from-file=cluster-status.html="$SCRIPT_DIR/cluster-status.html" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap with exporter script
kubectl create configmap dashboard-exporter \
    --from-file=export-services.sh="$SCRIPT_DIR/export-services.sh" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Clean up temp file
rm -f "$TEMP_HTML"

# Create ServiceAccount and RBAC for dashboard pod to read cluster info
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dashboard
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dashboard-reader
rules:
# Service registry access
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["service-registry"]
  verbs: ["get", "list"]
# Node status access
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
# Pod status access
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
# Service access
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
# Metrics access (if metrics-server is available)
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: dashboard-reader
subjects:
- kind: ServiceAccount
  name: dashboard
  namespace: $NAMESPACE
EOF

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
      serviceAccountName: dashboard
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
          readOnly: true
        - name: api
          mountPath: /usr/share/nginx/html/api
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
      - name: service-exporter
        image: bitnami/kubectl:latest
        command: ["/bin/bash", "/scripts/export-services.sh"]
        env:
        - name: OUTPUT_DIR
          value: "/api"
        - name: REFRESH_INTERVAL
          value: "30"
        volumeMounts:
        - name: api
          mountPath: /api
        - name: exporter-script
          mountPath: /scripts
        resources:
          requests:
            memory: "16Mi"
            cpu: "10m"
          limits:
            memory: "64Mi"
            cpu: "50m"
      volumes:
      - name: html
        configMap:
          name: dashboard-html
      - name: api
        emptyDir: {}
      - name: exporter-script
        configMap:
          name: dashboard-exporter
          defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: dashboard
  namespace: $NAMESPACE
  annotations:
    ${CLUSTER_DOMAIN}.local/subdomain: ""
    mynodeone.io/subdomain: ""
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
echo "✓ Dashboard deployed successfully"
echo ""
echo "📍 Access at: http://$SERVICE_IP"
echo "📍 Will also be available at: http://${CLUSTER_DOMAIN}.local (after DNS setup)"
echo ""

# Return the IP for use in other scripts
echo "$SERVICE_IP"
