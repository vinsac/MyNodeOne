#!/bin/bash

###############################################################################
# Vaultwarden - One-Click Installation
# 
# Self-hosted Bitwarden password manager
# Secure password storage and sync across all devices
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared validation library
source "$SCRIPT_DIR/lib/validation.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Vaultwarden (Password Manager)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

NAMESPACE="vaultwarden"
warn_if_namespace_exists "$NAMESPACE"
ADMIN_TOKEN=$(openssl rand -base64 32)

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🔐 Creating admin token..."
kubectl create secret generic vaultwarden-admin \
    --from-literal=ADMIN_TOKEN="$ADMIN_TOKEN" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
EOF

echo "🔒 Deploying Vaultwarden..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vaultwarden
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vaultwarden
  template:
    metadata:
      labels:
        app: vaultwarden
    spec:
      containers:
      - name: vaultwarden
        image: vaultwarden/server:latest
        ports:
        - containerPort: 80
        env:
        - name: ADMIN_TOKEN
          valueFrom:
            secretKeyRef:
              name: vaultwarden-admin
              key: ADMIN_TOKEN
        - name: SIGNUPS_ALLOWED
          value: "true"
        - name: INVITATIONS_ALLOWED
          value: "true"
        - name: WEBSOCKET_ENABLED
          value: "true"
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "500m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: vaultwarden-data
---
apiVersion: v1
kind: Service
metadata:
  name: vaultwarden
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
    name: http
  selector:
    app: vaultwarden
EOF

echo "⏳ Waiting for Vaultwarden to start..."
kubectl wait --for=condition=available --timeout=180s deployment/vaultwarden -n "$NAMESPACE"

sleep 10
SERVICE_IP=$(kubectl get svc vaultwarden -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc vaultwarden -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Vaultwarden installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Vaultwarden at: http://$SERVICE_IP"
echo "📍 Admin Panel: http://$SERVICE_IP/admin"
echo ""
echo "🔑 Admin Token (save this!):"
echo "   $ADMIN_TOKEN"
echo ""
echo "⚠️  IMPORTANT - Save admin token to secure location!"
echo ""
echo "🎯 First Time Setup:"
echo "   1. Open http://$SERVICE_IP in your browser"
echo "   2. Click 'Create Account'"
echo "   3. Enter your email and master password"
echo "   4. Install browser extensions:"
echo "      • Chrome/Edge: Search 'Bitwarden' in Web Store"
echo "      • Firefox: Search 'Bitwarden' in Add-ons"
echo "   5. Install mobile apps:"
echo "      • iOS: Search 'Bitwarden' in App Store"
echo "      • Android: Search 'Bitwarden' in Play Store"
echo ""
echo "🔧 Configure Browser Extension/Mobile App:"
echo "   1. Open Bitwarden extension/app"
echo "   2. Click settings/gear icon"
echo "   3. Set server URL: http://$SERVICE_IP"
echo "   4. Login with your account"
echo ""
echo "💡 Features:"
echo "   • Store unlimited passwords"
echo "   • Auto-fill on websites"
echo "   • Generate strong passwords"
echo "   • Secure notes and documents"
echo "   • Share passwords with family"
echo "   • Two-factor authentication"
echo ""
echo "🔐 Security Tips:"
echo "   • Use a STRONG master password"
echo "   • Enable 2FA in admin panel"
echo "   • Regularly backup /data volume"
echo "   • Disable signups after creating accounts"
echo ""
echo "🔧 Management:"
echo "   • View logs: kubectl logs -f deployment/vaultwarden -n $NAMESPACE"
echo "   • Restart: kubectl rollout restart deployment/vaultwarden -n $NAMESPACE"
echo "   • Uninstall: kubectl delete namespace $NAMESPACE"
echo ""
echo "⚠️  To disable new signups (after creating accounts):"
echo "   kubectl set env deployment/vaultwarden SIGNUPS_ALLOWED=false -n $NAMESPACE"
echo ""

# Configure DNS automatically
echo "🌐 Configuring local DNS..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/../configure-app-dns.sh" vaultwarden > /dev/null 2>&1; then
    echo ""
    echo "✓ DNS configured! Access Vaultwarden at:"
    echo "   http://vaultwarden.mynodeone.local"
    echo "   http://vaultwarden.mynodeone.local/admin (admin panel)"
    echo ""
else
    echo ""
    echo "⚠️  DNS auto-configuration skipped"
    echo ""
fi

# Check if VPS edge node is configured
if [[ -f ~/.mynodeone/config.env ]]; then
    source ~/.mynodeone/config.env
    
    if [[ -n "${VPS_EDGE_IP:-}" ]] || [[ "${NODE_TYPE:-}" == "vps-edge" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🌍 Internet Access via VPS Edge Node"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Do you want to make Vaultwarden accessible from the internet?"
        echo ""
        echo "⚠️  SECURITY NOTE:"
        echo "  • Internet-accessible password manager requires HTTPS"
        echo "  • You MUST use a domain with valid SSL certificate"
        echo "  • Never access via HTTP from internet (man-in-the-middle risk)"
        echo ""
        echo "This will:"
        echo "  • Set up proxy on control plane"
        echo "  • Configure VPS with automatic HTTPS (Let's Encrypt)"
        echo "  • Enable secure access from anywhere"
        echo ""
        read -p "Configure internet access? [y/N]: " configure_internet
        
        if [[ "$configure_internet" =~ ^[Yy]$ ]]; then
            echo ""
            
            # Step 1: Setup proxy on control plane
            if [[ -x "$SCRIPT_DIR/../setup-app-proxy.sh" ]]; then
                echo "📡 Setting up app proxy on control plane..."
                bash "$SCRIPT_DIR/../setup-app-proxy.sh" vaultwarden vaultwarden --skip-systemd || {
                    echo "⚠️  Proxy setup incomplete. You can set it up later:"
                    echo "   sudo ./scripts/setup-app-proxy.sh vaultwarden vaultwarden"
                }
            fi
            
            # Step 2: Configure VPS route
            read -p "Enter your domain (e.g., example.com): " user_domain
            read -p "Enter subdomain for Vaultwarden (e.g., vault or passwords): " subdomain
            
            if [[ -n "$user_domain" ]] && [[ -n "$subdomain" ]]; then
                echo ""
                echo "📡 Configuring VPS route with HTTPS..."
                echo ""
                
                # Get proxy port
                PROXY_PORT=8082  # Default for vaultwarden
                if [[ -f ~/.mynodeone/proxy-ports.env ]]; then
                    source ~/.mynodeone/proxy-ports.env
                    PROXY_PORT="${vaultwarden_PROXY_PORT:-8082}"
                fi
                
                # Run VPS route configuration
                if [[ -x "$SCRIPT_DIR/../configure-vps-route.sh" ]]; then
                    bash "$SCRIPT_DIR/../configure-vps-route.sh" vaultwarden "$PROXY_PORT" "$subdomain" "$user_domain" && {
                        echo ""
                        echo "✅ VPS configured!"
                        echo ""
                        echo "📝 Next steps:"
                        echo "  1. Add DNS A record: $subdomain.$user_domain → VPS_IP"
                        echo "  2. Wait 5-15 minutes for SSL certificate"
                        echo "  3. Access: https://$subdomain.$user_domain"
                        echo "  4. In Bitwarden app/extension, set server URL to: https://$subdomain.$user_domain"
                        echo ""
                        echo "⚠️  IMPORTANT: Always use HTTPS (not HTTP) for password manager!"
                        echo ""
                    } || {
                        echo ""
                        echo "⚠️  VPS route configuration incomplete"
                        echo ""
                        echo "To configure manually later, run:"
                        echo "  sudo ./scripts/configure-vps-route.sh vaultwarden $PROXY_PORT $subdomain $user_domain"
                    }
                else
                    echo "⚠️  VPS route script not found"
                    echo ""
                    echo "To configure manually:"
                    echo "  1. Setup proxy: sudo ./scripts/setup-app-proxy.sh vaultwarden vaultwarden"
                    echo "  2. Configure VPS: sudo ./scripts/configure-vps-route.sh vaultwarden 80 $subdomain $user_domain"
                fi
            else
                echo ""
                echo "⚠️  Domain and subdomain required. Skipped."
                echo ""
                echo "To configure later, run:"
                echo "  sudo ./scripts/setup-app-proxy.sh vaultwarden vaultwarden"
                echo "  sudo ./scripts/configure-vps-route.sh vaultwarden 80 <subdomain> <domain>"
            fi
            
            echo ""
            echo "📖 For DNS setup instructions, see:"
            echo "   docs/guides/DNS-SETUP-GUIDE.md"
            echo ""
        else
            echo ""
            echo "⚠️  Internet access configuration skipped"
            echo ""
            echo "To configure later:"
            echo "  1. Setup proxy: sudo ./scripts/setup-app-proxy.sh vaultwarden vaultwarden"
            echo "  2. Configure VPS route: sudo ./scripts/configure-vps-route.sh vaultwarden 80 <subdomain> <domain>"
            echo "  3. Setup DNS: See docs/guides/DNS-SETUP-GUIDE.md"
            echo ""
        fi
    fi
fi
