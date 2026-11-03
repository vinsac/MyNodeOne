#!/bin/bash

###############################################################################
# Setup Admin Dashboard for Non-Technical Users
# 
# Installs Kubernetes Dashboard for web-based cluster management
# Provides easy access for non-technical administrators
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

DASHBOARD_NS="kubernetes-dashboard"
DASHBOARD_SA="dashboard-operator"
TOKEN_DURATION="${DASHBOARD_TOKEN_DURATION:-1h}"

# Under sudo, $HOME may be root's while the old token file is in the user's home
ACTUAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Setting Up Admin Dashboard${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if already installed
if kubectl get namespace kubernetes-dashboard &>/dev/null; then
    echo -e "${YELLOW}Dashboard already installed!${NC}"
    echo ""
    echo "What would you like to do?"
    echo "  1. Get access token"
    echo "  2. Reinstall dashboard"
    echo "  3. Exit"
    echo ""
    read -p "Choose [1-3]: " CHOICE
    
    case $CHOICE in
        1)
            # Fall through: refreshes access and issues a new short-lived token
            ;;
        2)
            echo "Removing existing installation..."
            kubectl delete namespace kubernetes-dashboard
            sleep 5
            ;;
        *)
            exit 0
            ;;
    esac
fi

# Install Kubernetes Dashboard
if ! kubectl get namespace kubernetes-dashboard &>/dev/null; then
    echo "📦 Installing Kubernetes Dashboard..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    
    echo "⏳ Waiting for dashboard to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/kubernetes-dashboard -n kubernetes-dashboard 2>/dev/null || sleep 30
fi

# Dashboard login: an operator role rather than cluster-admin. It can view apps and
# their logs, scale them, and restart them by deleting a pod. It cannot read Secrets
# or ConfigMaps, change what a workload runs, or change RBAC.
echo "👤 Creating dashboard operator account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $DASHBOARD_SA
  namespace: $DASHBOARD_NS
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $DASHBOARD_SA
rules:
- apiGroups: [""]
  resources: ["namespaces", "nodes", "pods", "pods/log", "services", "endpoints", "events", "persistentvolumes", "persistentvolumeclaims", "replicationcontrollers", "resourcequotas", "limitranges"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments/scale", "statefulsets/scale", "replicasets/scale"]
  verbs: ["get", "patch", "update"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "ingressclasses", "networkpolicies"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $DASHBOARD_SA
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $DASHBOARD_SA
subjects:
- kind: ServiceAccount
  name: $DASHBOARD_SA
  namespace: $DASHBOARD_NS
EOF

# Earlier versions created a cluster-admin account with a token that never expires,
# and saved that token to a file. Deleting the token Secret revokes it.
LEGACY_REMOVED=false
if [ -n "$(kubectl get secret admin-user-token -n "$DASHBOARD_NS" --ignore-not-found -o name)" ] || \
   [ -n "$(kubectl get serviceaccount admin-user -n "$DASHBOARD_NS" --ignore-not-found -o name)" ]; then
    LEGACY_REMOVED=true
fi
kubectl delete secret admin-user-token -n "$DASHBOARD_NS" --ignore-not-found
kubectl delete serviceaccount admin-user -n "$DASHBOARD_NS" --ignore-not-found
# Only this script's binding: the name alone is generic enough to be someone else's
LEGACY_BINDING_NS=$(kubectl get clusterrolebinding admin-user --ignore-not-found \
    -o jsonpath='{.subjects[0].namespace}')
if [ "$LEGACY_BINDING_NS" = "$DASHBOARD_NS" ]; then
    kubectl delete clusterrolebinding admin-user --ignore-not-found
fi
if [ -f "$ACTUAL_HOME/.mynodeone/dashboard-token.txt" ]; then
    rm -f "$ACTUAL_HOME/.mynodeone/dashboard-token.txt"
    LEGACY_REMOVED=true
fi
if [ "$LEGACY_REMOVED" = "true" ]; then
    echo -e "${YELLOW}Revoked the old cluster-admin dashboard login and removed its saved token.${NC}"
fi

# Issue a short-lived token. It is shown once and never written to disk.
echo "🔑 Creating access token (valid for $TOKEN_DURATION)..."
TOKEN=$(kubectl create token "$DASHBOARD_SA" -n "$DASHBOARD_NS" --duration="$TOKEN_DURATION")

# Patch service to LoadBalancer
echo "🌐 Configuring external access..."
kubectl patch svc kubernetes-dashboard -n kubernetes-dashboard -p '{"spec":{"type":"LoadBalancer"}}'

# Wait for external IP
echo "⏳ Waiting for external IP..."
for i in {1..30}; do
    DASHBOARD_IP=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$DASHBOARD_IP" ]; then
        break
    fi
    sleep 2
done

# Update local DNS
if [ -f "$PROJECT_ROOT/scripts/domains/update-laptop-dns.sh" ]; then
    echo "📝 Updating local DNS..."
    bash "$PROJECT_ROOT/scripts/domains/update-laptop-dns.sh" > /dev/null 2>&1 || true
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Admin Dashboard Installed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Dashboard:"
if [ -n "$DASHBOARD_IP" ]; then
    echo "   https://$DASHBOARD_IP"
    echo ""
else
    echo "   Get IP: kubectl get svc kubernetes-dashboard -n kubernetes-dashboard"
    echo "   Then: https://<EXTERNAL-IP>"
    echo ""
fi

echo "🔐 Login Token (valid for $TOKEN_DURATION):"
echo ""
echo "$TOKEN"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📖 How to Use"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Open the dashboard URL in your browser"
echo "2. Select 'Token' authentication method"
echo "3. Paste the token above"
echo "4. Click 'Sign In'"
echo ""
echo "💡 What You Can Do:"
echo "   • View all applications and their status"
echo "   • Check resource usage (CPU, RAM, storage)"
echo "   • View logs from any application"
echo "   • Restart applications (delete a pod and it is recreated)"
echo "   • Scale applications up/down"
echo "   • Monitor cluster health"
echo ""
echo "⚠️  Token Security:"
echo "   • This login cannot read Secrets, change workloads or change permissions."
echo "     For those, use kubectl."
echo "   • The token expires by itself and is not saved anywhere."
echo ""
echo "📝 To get a new token:"
echo "   kubectl create token $DASHBOARD_SA -n $DASHBOARD_NS --duration=$TOKEN_DURATION"
echo ""
