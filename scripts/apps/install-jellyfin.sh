#!/bin/bash

###############################################################################
# Jellyfin Media Server - One-Click Installation
# 
# Open source media server (Plex alternative)
# Stream movies, TV shows, music, and photos to any device
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load cluster domain from config
CLUSTER_DOMAIN="mynodeone"
if [ -f "$HOME/.mynodeone/config.env" ]; then
    source "$HOME/.mynodeone/config.env"
    CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Jellyfin Media Server${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Error: kubectl not found. Please install Kubernetes first.${NC}"
    echo "Run: sudo ./scripts/bootstrap-control-plane.sh"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl get nodes &> /dev/null; then
    echo -e "${YELLOW}Error: Cannot connect to Kubernetes cluster.${NC}"
    echo "Please ensure:"
    echo "  • K3s is running: systemctl status k3s"
    echo "  • KUBECONFIG is set: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    exit 1
fi

# Check if Longhorn storage is available
if ! kubectl get storageclass longhorn &> /dev/null; then
    echo -e "${YELLOW}Warning: Longhorn storage class not found.${NC}"
    echo "Installation may fail without persistent storage."
    read -p "Continue anyway? [y/N]: " continue_without_storage
    if [[ "$continue_without_storage" != "y" ]] && [[ "$continue_without_storage" != "Y" ]]; then
        echo "Installation cancelled."
        exit 1
    fi
fi

# Prompt for subdomain (used for both local and public access)
echo "🌐 App Subdomain Configuration"
echo ""
echo "Choose a subdomain for Jellyfin. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: media, jellyfin, movies, tv"
echo ""
read -p "Enter subdomain [default: jellyfin]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-jellyfin}"

# Sanitize subdomain (lowercase, alphanumeric and hyphens only)
APP_SUBDOMAIN=$(echo "$APP_SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

# Validate subdomain is not empty after sanitization
if [ -z "$APP_SUBDOMAIN" ]; then
    echo -e "${YELLOW}Error: Invalid subdomain. Using default: jellyfin${NC}"
    APP_SUBDOMAIN="jellyfin"
fi

# Validate subdomain doesn't start with hyphen
if [[ "$APP_SUBDOMAIN" == -* ]]; then
    echo -e "${YELLOW}Error: Subdomain cannot start with hyphen. Using default: jellyfin${NC}"
    APP_SUBDOMAIN="jellyfin"
fi

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

# Configuration
NAMESPACE="jellyfin"
STORAGE_CONFIG="50Gi"
STORAGE_MEDIA="500Gi"  # Adjust based on your media library size

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-config
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $STORAGE_CONFIG
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-media
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: longhorn
  resources:
    requests:
      storage: $STORAGE_MEDIA
EOF

echo "🚀 Deploying Jellyfin..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jellyfin
  template:
    metadata:
      labels:
        app: jellyfin
    spec:
      containers:
      - name: jellyfin
        image: jellyfin/jellyfin:latest
        ports:
        - containerPort: 8096
          name: http
        env:
        - name: TZ
          value: "America/New_York"
        volumeMounts:
        - name: config
          mountPath: /config
        - name: media
          mountPath: /media
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: config
        persistentVolumeClaim:
          claimName: jellyfin-config
      - name: media
        persistentVolumeClaim:
          claimName: jellyfin-media
---
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: $NAMESPACE
  annotations:
    ${CLUSTER_DOMAIN}.local/subdomain: "$APP_SUBDOMAIN"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8096
    name: http
  selector:
    app: jellyfin
EOF

echo "⏳ Waiting for Jellyfin to start..."
kubectl wait --for=condition=available --timeout=300s deployment/jellyfin -n "$NAMESPACE"

# Get LoadBalancer IP
echo "🔍 Getting service IP..."
sleep 10
SERVICE_IP=$(kubectl get svc jellyfin -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc jellyfin -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Jellyfin installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Jellyfin at: http://$SERVICE_IP"
echo ""
echo "🎬 First Time Setup:"
echo "   1. Open the URL above in your browser"
echo "   2. Follow the setup wizard"
echo "   3. Create your admin account"
echo "   4. Add your media libraries"
echo ""
echo "📁 Media Storage:"
echo "   • Upload media to: /media in the container"
echo "   • Or connect via NFS/SMB from your NAS"
echo ""
echo "💡 Tips:"
echo "   • Hardware acceleration: Available if you have GPU"
echo "   • Mobile apps: Available for iOS and Android"
echo "   • Web client: Works on any device"
echo ""
echo "🔧 Manage Jellyfin:"
echo "   • View logs: kubectl logs -f deployment/jellyfin -n $NAMESPACE"
echo "   • Restart: kubectl rollout restart deployment/jellyfin -n $NAMESPACE"
echo "   • Uninstall: kubectl delete namespace $NAMESPACE"
echo ""

# Configure local DNS automatically (if kubectl is available)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    echo "🌐 Updating local DNS entries..."
    if sudo bash "$SCRIPT_DIR/../update-laptop-dns.sh" --quiet 2>/dev/null; then
        echo ""
        echo "✓ Local DNS updated! Access Jellyfin at:"
        echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        echo ""
    fi
else
    # Not on a machine with kubectl configured
    echo ""
    echo "💡 To access via .local domain on any Tailscale-connected machine:"
    echo "   Run: sudo ./scripts/update-laptop-dns.sh"
    echo "   Then access: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
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
        echo "Make Jellyfin accessible from the internet?"
        echo ""
        echo "This will configure:"
        echo "  • Public URL: https://${APP_SUBDOMAIN}.yourdomain.com"
        echo "  • Automatic SSL certificate"
        echo "  • VPS routing to your cluster"
        echo ""
        echo "Using subdomain: ${APP_SUBDOMAIN} (same as local)"
        echo ""
        read -p "Configure internet access? [Y/n]: " configure_internet
        
        if [[ "$configure_internet" != "n" ]] && [[ "$configure_internet" != "N" ]]; then
            echo ""
            read -p "Enter your public domain (e.g., curiios.com): " user_domain
            
            if [[ -n "$user_domain" ]]; then
                echo ""
                echo "📡 Configuring VPS route..."
                echo "   Public URL: https://${APP_SUBDOMAIN}.${user_domain}"
                echo ""
                
                # Run VPS route configuration (auto-detects NodePort)
                if [[ -x "$SCRIPT_DIR/../configure-vps-route.sh" ]]; then
                    bash "$SCRIPT_DIR/../configure-vps-route.sh" jellyfin 80 "$APP_SUBDOMAIN" "$user_domain" || {
                        echo ""
                        echo "⚠️  VPS route configuration incomplete"
                        echo ""
                        echo "To configure manually later, run:"
                        echo "  sudo ./scripts/configure-vps-route.sh jellyfin 80 $APP_SUBDOMAIN $user_domain"
                    }
                else
                    echo "⚠️  VPS route script not found"
                    echo ""
                    echo "To configure manually:"
                    echo "  sudo ./scripts/configure-vps-route.sh jellyfin 80 $APP_SUBDOMAIN $user_domain"
                fi
            else
                echo ""
                echo "⚠️  Domain required. Skipped."
                echo ""
                echo "To configure later, run:"
                echo "  sudo ./scripts/configure-vps-route.sh jellyfin 80 $APP_SUBDOMAIN <domain>"
                echo ""
            fi
            
            echo ""
            echo "📖 For DNS setup instructions, see:"
            echo "   docs/guides/DNS-SETUP-GUIDE.md"
            echo ""
        else
            echo ""
            echo "⚠️  VPS configuration skipped"
            echo ""
            echo "To configure later, run:"
            echo "  sudo ./scripts/configure-vps-route.sh jellyfin 80 $APP_SUBDOMAIN <domain>"
            echo ""
        fi
    fi
fi
