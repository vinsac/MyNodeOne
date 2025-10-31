#!/bin/bash

###############################################################################
# Immich - One-Click Installation
# 
# Self-hosted Google Photos alternative
# Photo and video backup with AI-powered search
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Immich (Google Photos Alternative)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Error: kubectl not found.${NC}"
    exit 1
fi

NAMESPACE="immich"
DB_PASSWORD=$(openssl rand -base64 32)

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🔐 Creating secrets..."
kubectl create secret generic immich-secrets \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-photos
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 200Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-postgres
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi
EOF

echo "🗄️ Deploying PostgreSQL..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: immich-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: immich-postgres
  template:
    metadata:
      labels:
        app: immich-postgres
    spec:
      containers:
      - name: postgres
        image: tensorchord/pgvecto-rs:pg14-v0.2.0
        env:
        - name: POSTGRES_USER
          value: immich
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: immich-secrets
              key: DB_PASSWORD
        - name: POSTGRES_DB
          value: immich
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "2Gi"
            cpu: "1000m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: immich-postgres
---
apiVersion: v1
kind: Service
metadata:
  name: immich-postgres
  namespace: $NAMESPACE
spec:
  ports:
  - port: 5432
  selector:
    app: immich-postgres
EOF

echo "📸 Deploying Immich Server..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: immich-server
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: immich-server
  template:
    metadata:
      labels:
        app: immich-server
    spec:
      containers:
      - name: immich-server
        image: ghcr.io/immich-app/immich-server:release
        env:
        - name: DB_HOSTNAME
          value: immich-postgres
        - name: DB_USERNAME
          value: immich
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: immich-secrets
              key: DB_PASSWORD
        - name: DB_DATABASE_NAME
          value: immich
        - name: REDIS_HOSTNAME
          value: immich-redis
        ports:
        - containerPort: 3001
        volumeMounts:
        - name: photos
          mountPath: /usr/src/app/upload
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "8Gi"
            cpu: "4000m"
      volumes:
      - name: photos
        persistentVolumeClaim:
          claimName: immich-photos
---
apiVersion: v1
kind: Service
metadata:
  name: immich-server
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 3001
    name: http
  selector:
    app: immich-server
EOF

echo "🔴 Deploying Redis..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: immich-redis
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: immich-redis
  template:
    metadata:
      labels:
        app: immich-redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: immich-redis
  namespace: $NAMESPACE
spec:
  ports:
  - port: 6379
  selector:
    app: immich-redis
EOF

echo "⏳ Waiting for services to start..."
kubectl wait --for=condition=available --timeout=300s deployment/immich-postgres -n "$NAMESPACE"
kubectl wait --for=condition=available --timeout=300s deployment/immich-server -n "$NAMESPACE"

sleep 10
SERVICE_IP=$(kubectl get svc immich-server -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc immich-server -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Immich installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Immich at: http://$SERVICE_IP"
echo ""
echo "🎯 First Time Setup:"
echo "   1. Open the URL in your browser"
echo "   2. Create your admin account (first user = admin)"
echo "   3. Download mobile apps:"
echo "      • iOS: Search 'Immich' in App Store"
echo "      • Android: Search 'Immich' in Play Store"
echo "   4. Configure auto-upload in mobile app"
echo ""
echo "📱 Mobile App Setup:"
echo "   • Server URL: http://$SERVICE_IP (or http://immich.mynodeone.local)"
echo "   • Login with account created above"
echo "   • Enable background upload"
echo ""
echo "💡 Features:"
echo "   • Automatic photo backup from phone"
echo "   • AI-powered face recognition"
echo "   • Search by objects, locations, dates"
echo "   • Share albums with family"
echo "   • Original quality storage"
echo ""
echo "🔧 Management:"
echo "   • Logs: kubectl logs -f deployment/immich-server -n $NAMESPACE"
echo "   • Restart: kubectl rollout restart deployment/immich-server -n $NAMESPACE"
echo "   • Uninstall: kubectl delete namespace $NAMESPACE"
echo ""

# Configure DNS automatically
echo "🌐 Configuring local DNS..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/../configure-app-dns.sh" > /dev/null 2>&1; then
    echo ""
    echo "✓ DNS configured! Access Immich at:"
    echo "   http://immich.mynodeone.local"
    echo ""
    echo "📱 For mobile app, use: http://immich.mynodeone.local"
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
        echo "Do you want to make Immich accessible from the internet?"
        echo ""
        echo "This will:"
        echo "  • Configure your VPS to route traffic to this app"
        echo "  • Enable HTTPS with automatic SSL certificate"
        echo "  • Allow access from anywhere via your domain"
        echo ""
        read -p "Configure VPS route? [Y/n]: " configure_vps
        
        if [[ "$configure_vps" != "n" ]] && [[ "$configure_vps" != "N" ]]; then
            echo ""
            read -p "Enter your domain (e.g., example.com): " user_domain
            read -p "Enter subdomain for Immich (e.g., photos): " subdomain
            
            if [[ -n "$user_domain" ]] && [[ -n "$subdomain" ]]; then
                echo ""
                echo "📡 Configuring VPS route..."
                echo ""
                
                # Run VPS route configuration
                if [[ -x "$SCRIPT_DIR/../configure-vps-route.sh" ]]; then
                    bash "$SCRIPT_DIR/../configure-vps-route.sh" immich 80 "$subdomain" "$user_domain"
                else
                    echo "⚠️  VPS route script not found"
                    echo ""
                    echo "To configure manually later, run:"
                    echo "  sudo ./scripts/configure-vps-route.sh immich 80 $subdomain $user_domain"
                fi
            else
                echo ""
                echo "⚠️  Domain and subdomain required. Skipped."
                echo ""
                echo "To configure later, run:"
                echo "  sudo ./scripts/configure-vps-route.sh immich 80 <subdomain> <domain>"
            fi
        else
            echo ""
            echo "⚠️  VPS route configuration skipped"
            echo ""
            echo "To configure later, run:"
            echo "  sudo ./scripts/configure-vps-route.sh immich 80 <subdomain> <domain>"
            echo ""
        fi
        
        echo ""
        echo "📖 For DNS setup instructions, see:"
        echo "   docs/guides/DNS-SETUP-GUIDE.md"
        echo ""
    fi
fi
