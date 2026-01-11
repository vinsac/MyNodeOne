#!/bin/bash

###############################################################################
# Immich - One-Click Installation
# 
# Self-hosted Google Photos alternative
# Photo and video backup with AI-powered search
#
# DOCUMENTATION:
# - Public access configuration: docs/APP-PUBLIC-ACCESS.md
# - After installation, you'll be asked if you want to make this app public
# - You can change visibility anytime: sudo ./scripts/operations/manage-app-visibility.sh
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Get cluster domain from cluster-info ConfigMap (authoritative source)
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    CLUSTER_DOMAIN=$(kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.cluster-domain}' 2>/dev/null || echo "")
fi

# If not found, ask user
if [ -z "$CLUSTER_DOMAIN" ]; then
    echo -e "${YELLOW}⚠️  Could not detect cluster domain from cluster-info ConfigMap${NC}"
    echo ""
    read -p "Enter your cluster domain [default: mynodeone]: " USER_CLUSTER_DOMAIN
    CLUSTER_DOMAIN="${USER_CLUSTER_DOMAIN:-mynodeone}"
    echo ""
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Immich (Google Photos Alternative)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check for latest Immich version
echo "🔍 Checking for latest Immich version..."
LATEST_VERSION=""
if command -v curl &> /dev/null; then
    LATEST_VERSION=$(curl -s https://api.github.com/repos/immich-app/immich/releases/latest | grep -o '"tag_name": *"[^"]*"' | grep -o 'v[0-9.]*' || echo "")
fi

if [ -n "$LATEST_VERSION" ]; then
    echo "✓ Latest Immich version: $LATEST_VERSION"
    IMMICH_IMAGE="ghcr.io/immich-app/immich-server:${LATEST_VERSION}"
else
    echo -e "${YELLOW}⚠️  Could not fetch latest version, using 'release' tag${NC}"
    IMMICH_IMAGE="ghcr.io/immich-app/immich-server:release"
fi
echo ""

# Validate prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Error: kubectl not found. Please install Kubernetes first.${NC}"
    echo "Run: sudo ./scripts/installation/bootstrap-control-plane.sh"
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
echo "Choose a subdomain for Immich. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: photos, immich, pics, gallery"
echo ""
read -p "Enter subdomain [default: immich]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-immich}"

# Sanitize subdomain (lowercase, alphanumeric and hyphens only)
APP_SUBDOMAIN=$(echo "$APP_SUBDOMAIN" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

# Validate subdomain is not empty after sanitization
if [ -z "$APP_SUBDOMAIN" ]; then
    echo -e "${YELLOW}Error: Invalid subdomain. Using default: immich${NC}"
    APP_SUBDOMAIN="immich"
fi

# Validate subdomain doesn't start with hyphen
if [[ "$APP_SUBDOMAIN" == -* ]]; then
    echo -e "${YELLOW}Error: Subdomain cannot start with hyphen. Using default: immich${NC}"
    APP_SUBDOMAIN="immich"
fi

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

# Prompt for storage allocation
echo "💾 Storage Configuration"
echo ""
echo "Immich requires storage for photos/videos and database."
echo ""
echo "Recommended photo storage sizes:"
echo "  • 500Gi  - Good for ~50,000 photos (average 10MB each)"
echo "  • 1Ti    - Good for ~100,000 photos (recommended)"
echo "  • 2Ti    - Good for ~200,000 photos"
echo "  • 5Ti    - Good for large families or multiple users"
echo ""
read -p "Enter photo storage size [default: 1Ti]: " PHOTO_STORAGE
PHOTO_STORAGE="${PHOTO_STORAGE:-1Ti}"

echo ""
echo "Database storage (for metadata, thumbnails, face recognition data):"
echo "  • 20Gi   - Good for ~50,000 photos (recommended)"
echo "  • 50Gi   - Good for ~100,000+ photos"
echo "  • 100Gi  - Good for very large libraries"
echo ""
read -p "Enter database storage size [default: 20Gi]: " DB_STORAGE
DB_STORAGE="${DB_STORAGE:-20Gi}"

echo ""
echo "✓ Storage allocation:"
echo "  Photos/Videos: $PHOTO_STORAGE"
echo "  Database: $DB_STORAGE"
echo ""

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
      storage: $PHOTO_STORAGE
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
      storage: $DB_STORAGE
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
      priorityClassName: mynodeone-infrastructure
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
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "2Gi"
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

echo "📸 Deploying Immich Server (${IMMICH_IMAGE})..."
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
      priorityClassName: mynodeone-app
      containers:
      - name: immich-server
        image: $IMMICH_IMAGE
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
        - containerPort: 2283
        volumeMounts:
        - name: photos
          mountPath: /usr/src/app/upload
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "16Gi"
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
  annotations:
    ${CLUSTER_DOMAIN}.local/subdomain: "$APP_SUBDOMAIN"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 2283
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
      priorityClassName: mynodeone-infrastructure
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "512Mi"
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
echo "📍 Access Immich at:"
echo "   • Direct IP: http://$SERVICE_IP"
echo "   • Local domain: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local (after DNS update)"
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
echo "   • Server URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local (or http://$SERVICE_IP)"
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

# Configure local DNS automatically (if kubectl is available)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Detect actual user and home directory
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# Load cluster configuration
CONFIG_FILE="${CONFIG_FILE:-$ACTUAL_HOME/.mynodeone/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Cluster domain already fetched at the beginning of the script

# Register service in service registry
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    echo "📝 Registering service in registry..."
    
    # Register with custom subdomain
    if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "immich-server" "$APP_SUBDOMAIN" "$NAMESPACE" "immich-server" "80" "false"; then
            echo "✓ Service registered in registry"
            echo ""
            
            # Verify registration
            echo "🔍 Verifying registration..."
            REGISTERED_SUBDOMAIN=$(kubectl get configmap -n kube-system service-registry \
                -o jsonpath='{.data.services\.json}' 2>/dev/null | \
                jq -r '."immich-server".subdomain' 2>/dev/null || echo "")
            
            if [ "$REGISTERED_SUBDOMAIN" = "$APP_SUBDOMAIN" ]; then
                echo "✓ Verified: Service registered with subdomain '$APP_SUBDOMAIN'"
                echo ""
            else
                echo -e "${YELLOW}⚠️  Registration verification failed${NC}"
                echo "   Expected subdomain: $APP_SUBDOMAIN"
                echo "   Got: $REGISTERED_SUBDOMAIN"
                echo ""
            fi
            
            # Check if running on control plane
            IS_CONTROL_PLANE=false
            if kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | grep -q "$(hostname)"; then
                IS_CONTROL_PLANE=true
            fi
            
            # If on control plane, update local DNS immediately (no SSH overhead)
            if [ "$IS_CONTROL_PLANE" = "true" ]; then
                echo "🔄 Updating control plane DNS..."
                if sudo bash "$PROJECT_ROOT/scripts/sync-dns.sh" --quiet 2>/dev/null; then
                    echo "✓ Control plane DNS updated"
                fi
            fi
            
            # Trigger sync to all remote nodes (laptops, VPS)
            echo "🔄 Triggering sync to all nodes..."
            if [ -f "$PROJECT_ROOT/scripts/lib/sync-controller.sh" ]; then
                if sudo bash "$PROJECT_ROOT/scripts/lib/sync-controller.sh" push >/dev/null 2>&1; then
                    echo "✓ Sync completed successfully"
                else
                    echo -e "${YELLOW}⚠️  Manual sync failed - sync-controller daemon will retry${NC}"
                fi
            else
                echo -e "${YELLOW}⚠️  Sync controller not found - DNS will update on next reconciliation${NC}"
            fi
            echo ""
            
            echo "✓ Access Immich at:"
            echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
            echo ""
            echo "📱 For mobile app, use: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
            echo ""
        else
            echo "⚠️  Could not register service (will update DNS manually)"
            echo ""
            
            # Fallback to manual DNS update
            if sudo bash "$PROJECT_ROOT/scripts/sync-dns.sh" --quiet 2>/dev/null; then
                echo "✓ Local DNS updated manually"
            fi
        fi
    else
        # Fallback to manual DNS update if service-registry.sh not found
        echo "🌐 Updating local DNS entries..."
        if sudo bash "$PROJECT_ROOT/scripts/sync-dns.sh" --quiet 2>/dev/null; then
            echo "✓ Local DNS updated"
        fi
    fi
else
    # Not on a machine with kubectl configured
    echo ""
    echo "💡 To access via .local domain on any Tailscale-connected machine:"
    echo "   Run: sudo ./scripts/sync-dns.sh"
    echo ""
fi

# Automatically configure routing and ask about public access
if [[ -f "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" ]]; then
    source "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" "immich" "80" "$APP_SUBDOMAIN" "immich" "immich-server"
fi

# Offer to set up automated video transcoding
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Automated Video Transcoding${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Would you like to set up automatic nightly video transcoding?"
echo ""
echo "Benefits:"
echo "  • Videos are pre-transcoded for instant playback"
echo "  • No buffering during video viewing"
echo "  • Transcoding happens during off-peak hours (2 AM)"
echo ""
read -p "Set up automated transcoding? [Y/n]: " SETUP_AUTO_TRANSCODE

if [[ "${SETUP_AUTO_TRANSCODE,,}" != "n" ]]; then
    echo ""
    if [[ -f "$SCRIPT_DIR/setup-auto-transcode.sh" ]]; then
        bash "$SCRIPT_DIR/setup-auto-transcode.sh"
    else
        echo -e "${YELLOW}⚠️  setup-auto-transcode.sh not found${NC}"
        echo "You can set it up later by running:"
        echo "  sudo ./scripts/apps/immich/setup-auto-transcode.sh"
    fi
else
    echo ""
    echo "ℹ️  You can set up automated transcoding later by running:"
    echo "   sudo ./scripts/apps/immich/setup-auto-transcode.sh"
fi
echo ""
