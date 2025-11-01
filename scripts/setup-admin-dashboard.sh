#!/bin/bash

###############################################################################
# Setup Admin Dashboard for Non-Technical Users
# 
# Installs Kubernetes Dashboard for web-based cluster management
# Provides easy access for non-technical administrators
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
            # Just show token
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

# Create admin service account
echo "👤 Creating admin service account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Create token
echo "🔑 Creating access token..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: admin-user-token
  namespace: kubernetes-dashboard
  annotations:
    kubernetes.io/service-account.name: admin-user
type: kubernetes.io/service-account-token
EOF

sleep 3

# Get token
TOKEN=$(kubectl get secret admin-user-token -n kubernetes-dashboard -o jsonpath='{.data.token}' | base64 -d)

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
if [ -f "$SCRIPT_DIR/update-laptop-dns.sh" ]; then
    echo "📝 Updating local DNS..."
    bash "$SCRIPT_DIR/update-laptop-dns.sh" > /dev/null 2>&1 || true
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

echo "🔐 Login Token:"
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
echo "   • Restart applications"
echo "   • Scale applications up/down"
echo "   • Monitor cluster health"
echo ""
echo "⚠️  Token Security:"
echo "   • Save this token securely"
echo "   • Anyone with this token has full cluster access"
echo "   • To revoke: kubectl delete secret admin-user-token -n kubernetes-dashboard"
echo ""
echo "📝 To retrieve token later:"
echo "   kubectl get secret admin-user-token -n kubernetes-dashboard \\"
echo "     -o jsonpath='{.data.token}' | base64 -d"
echo ""

# Save token to file
TOKEN_FILE="$HOME/.mynodeone/dashboard-token.txt"
mkdir -p "$(dirname "$TOKEN_FILE")"
echo "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

echo "✓ Token saved to: $TOKEN_FILE"
echo ""
