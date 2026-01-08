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

# Create a temporary HTML file with domain replaced AND MinIO services injected
TEMP_HTML=$(mktemp)

# First, replace cluster domain
sed "s/mynodeone\.local/${CLUSTER_DOMAIN}.local/g" "$SCRIPT_DIR/dashboard.html" > "$TEMP_HTML"

# Get all MinIO console services from service registry
MINIO_SERVICES=$(kubectl get configmap -n kube-system service-registry \
    -o jsonpath='{.data.services\.json}' 2>/dev/null | \
    jq -r 'to_entries[] | select(.key | startswith("minio-console-")) | 
        "<li class=\"service-item\"><span class=\"service-name\">MinIO Console (" + .key + ")</span><a href=\"http://" + .value.subdomain + "." + $domain + ":9001\" class=\"service-link\">Open →</a></li>"' \
    --arg domain "${CLUSTER_DOMAIN}.local" 2>/dev/null || echo "")

# Inject MinIO services into the HTML
if [[ -n "$MINIO_SERVICES" ]]; then
    # Replace the minio-services-container div with actual services
    sed -i "s|<div id=\"minio-services-container\"></div>|${MINIO_SERVICES}|g" "$TEMP_HTML"
    echo "✓ Injected $(echo "$MINIO_SERVICES" | grep -c 'service-item') MinIO service(s)"
else
    echo "ℹ No MinIO services found (will be added when MinIO is installed)"
fi

# Create ConfigMap with HTML (services loaded via JavaScript)
kubectl create configmap dashboard-html \
    --from-file=index.html="$TEMP_HTML" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap with exporter script
kubectl create configmap dashboard-exporter \
    --from-file=export-services.sh="$SCRIPT_DIR/export-services.sh" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Clean up temp file
rm -f "$TEMP_HTML"

# Create ServiceAccount and RBAC for dashboard pod to read service registry
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
  name: service-registry-reader
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["service-registry"]
  verbs: ["get", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-service-registry-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: service-registry-reader
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
echo "✓ Dashboard deployed successfully!"
echo ""
echo "📍 Access at: http://$SERVICE_IP"
echo "📍 Will also be available at: http://${CLUSTER_DOMAIN}.local (after DNS setup)"
echo ""

# Return the IP for use in other scripts
echo "$SERVICE_IP"
