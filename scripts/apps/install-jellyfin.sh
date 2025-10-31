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

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Jellyfin Media Server${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Error: kubectl not found. Please install Kubernetes first.${NC}"
    exit 1
fi

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

# Configure DNS automatically
echo "🌐 Configuring local DNS..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/../configure-app-dns.sh" jellyfin > /dev/null 2>&1; then
    echo ""
    echo "✓ DNS configured! You can now access Jellyfin at:"
    echo "   http://jellyfin.mynodeone.local"
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
        echo "Do you want to make Jellyfin accessible from the internet?"
        echo ""
        echo "This will:"
        echo "  • Set up proxy on control plane"
        echo "  • Configure VPS to route traffic to Jellyfin"
        echo "  • Enable HTTPS with automatic SSL certificate"
        echo "  • Allow streaming from anywhere"
        echo ""
        read -p "Configure internet access? [Y/n]: " configure_internet
        
        if [[ "$configure_internet" != "n" ]] && [[ "$configure_internet" != "N" ]]; then
            echo ""
            
            # Step 1: Setup proxy on control plane
            if [[ -x "$SCRIPT_DIR/../setup-app-proxy.sh" ]]; then
                echo "📡 Setting up app proxy on control plane..."
                bash "$SCRIPT_DIR/../setup-app-proxy.sh" jellyfin jellyfin --skip-systemd || {
                    echo "⚠️  Proxy setup incomplete. You can set it up later:"
                    echo "   sudo ./scripts/setup-app-proxy.sh jellyfin jellyfin"
                }
            fi
            
            # Step 2: Configure VPS route
            read -p "Enter your domain (e.g., example.com): " user_domain
            read -p "Enter subdomain for Jellyfin (e.g., media or jellyfin): " subdomain
            
            if [[ -n "$user_domain" ]] && [[ -n "$subdomain" ]]; then
                echo ""
                echo "📡 Configuring VPS route..."
                echo ""
                
                # Get proxy port
                PROXY_PORT=8081  # Default for jellyfin
                if [[ -f ~/.mynodeone/proxy-ports.env ]]; then
                    source ~/.mynodeone/proxy-ports.env
                    PROXY_PORT="${jellyfin_PROXY_PORT:-8081}"
                fi
                
                # Run VPS route configuration
                if [[ -x "$SCRIPT_DIR/../configure-vps-route.sh" ]]; then
                    bash "$SCRIPT_DIR/../configure-vps-route.sh" jellyfin "$PROXY_PORT" "$subdomain" "$user_domain" || {
                        echo ""
                        echo "⚠️  VPS route configuration incomplete"
                        echo ""
                        echo "To configure manually later, run:"
                        echo "  sudo ./scripts/configure-vps-route.sh jellyfin $PROXY_PORT $subdomain $user_domain"
                    }
                else
                    echo "⚠️  VPS route script not found"
                    echo ""
                    echo "To configure manually:"
                    echo "  1. Setup proxy: sudo ./scripts/setup-app-proxy.sh jellyfin jellyfin"
                    echo "  2. Configure VPS: sudo ./scripts/configure-vps-route.sh jellyfin 80 $subdomain $user_domain"
                fi
            else
                echo ""
                echo "⚠️  Domain and subdomain required. Skipped."
                echo ""
                echo "To configure later, run:"
                echo "  sudo ./scripts/setup-app-proxy.sh jellyfin jellyfin"
                echo "  sudo ./scripts/configure-vps-route.sh jellyfin 80 <subdomain> <domain>"
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
            echo "  1. Setup proxy: sudo ./scripts/setup-app-proxy.sh jellyfin jellyfin"
            echo "  2. Configure VPS route: sudo ./scripts/configure-vps-route.sh jellyfin 80 <subdomain> <domain>"
            echo "  3. Setup DNS: See docs/guides/DNS-SETUP-GUIDE.md"
            echo ""
        fi
    fi
fi
