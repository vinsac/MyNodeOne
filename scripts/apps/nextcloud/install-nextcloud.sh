#!/bin/bash

###############################################################################
# Nextcloud - One-Click Installation
# 
# Complete cloud storage and collaboration platform
# Self-hosted alternative to Google Drive, Dropbox, and Microsoft 365
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load shared validation library
source "$SCRIPT_DIR/../lib/validation.sh"

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
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Nextcloud (Cloud Storage)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

# Prompt for subdomain
echo "🌐 App Subdomain Configuration"
echo ""
echo "Choose a subdomain for Nextcloud. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: cloud, nextcloud, files, drive"
echo ""
read -p "Enter subdomain [default: nextcloud]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-nextcloud}"

# Sanitize subdomain
APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "nextcloud")

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

NAMESPACE="nextcloud"

# Prompt for storage allocation
echo ""
echo "💾 Storage Configuration"
echo ""
echo "Nextcloud requires storage for files and database."
echo ""
echo "Recommended file storage sizes:"
echo "  • 100Gi  - Good for personal use (~10,000 files)"
echo "  • 500Gi  - Good for small family (recommended)"
echo "  • 1Ti    - Good for large family or small team"
echo "  • 2Ti+   - Good for teams or extensive media libraries"
echo ""
read -p "Enter file storage size [default: 100Gi]: " FILE_STORAGE
FILE_STORAGE="${FILE_STORAGE:-100Gi}"

echo ""
echo "Database storage (for metadata, user data, app data):"
echo "  • 10Gi   - Good for personal use (recommended)"
echo "  • 20Gi   - Good for families or small teams"
echo "  • 50Gi   - Good for large teams"
echo ""
read -p "Enter database storage size [default: 10Gi]: " DB_STORAGE
DB_STORAGE="${DB_STORAGE:-10Gi}"

echo ""
echo "✓ Storage allocation:"
echo "  Files: $FILE_STORAGE"
echo "  Database: $DB_STORAGE"
echo ""

echo "🔐 Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -base64 32)
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "� Creating secrets..."
kubectl create secret generic nextcloud-db \
    --from-literal=db-password="$POSTGRES_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic nextcloud-admin \
    --from-literal=admin-password="$ADMIN_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $FILE_STORAGE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-postgres
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
  name: nextcloud-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nextcloud-postgres
  template:
    metadata:
      labels:
        app: nextcloud-postgres
    spec:
      priorityClassName: mynodeone-infrastructure
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_DB
          value: nextcloud
        - name: POSTGRES_USER
          value: nextcloud
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nextcloud-db
              key: db-password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: data
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "1Gi"
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: nextcloud-postgres
---
apiVersion: v1
kind: Service
metadata:
  name: nextcloud-postgres
  namespace: $NAMESPACE
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: nextcloud-postgres
EOF

echo "🔄 Deploying Redis..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nextcloud-redis
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nextcloud-redis
  template:
    metadata:
      labels:
        app: nextcloud-redis
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
  name: nextcloud-redis
  namespace: $NAMESPACE
spec:
  ports:
  - port: 6379
    targetPort: 6379
  selector:
    app: nextcloud-redis
EOF

echo "☁️ Deploying Nextcloud..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nextcloud
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nextcloud
  template:
    metadata:
      labels:
        app: nextcloud
    spec:
      priorityClassName: mynodeone-app
      containers:
      - name: nextcloud
        image: nextcloud:28-apache
        env:
        - name: POSTGRES_HOST
          value: nextcloud-postgres
        - name: POSTGRES_DB
          value: nextcloud
        - name: POSTGRES_USER
          value: nextcloud
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nextcloud-db
              key: db-password
        - name: REDIS_HOST
          value: nextcloud-redis
        - name: NEXTCLOUD_ADMIN_USER
          value: admin
        - name: NEXTCLOUD_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nextcloud-admin
              key: admin-password
        - name: NEXTCLOUD_TRUSTED_DOMAINS
          value: "${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local localhost"
        ports:
        - containerPort: 80
        volumeMounts:
        - name: nextcloud-data
          mountPath: /var/www/html
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "2Gi"
        livenessProbe:
          httpGet:
            path: /status.php
            port: 80
            httpHeaders:
            - name: Host
              value: "${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
          initialDelaySeconds: 90
          periodSeconds: 30
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /status.php
            port: 80
            httpHeaders:
            - name: Host
              value: "${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: nextcloud-data
        persistentVolumeClaim:
          claimName: nextcloud-data
---
apiVersion: v1
kind: Service
metadata:
  name: nextcloud
  namespace: $NAMESPACE
  annotations:
    mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nextcloud
EOF

echo "⏳ Waiting for Nextcloud to start (this may take 2-3 minutes)..."
kubectl wait --for=condition=available --timeout=300s deployment/nextcloud -n "$NAMESPACE" || {
    echo -e "${YELLOW}Timeout waiting for Nextcloud. Checking status...${NC}"
    kubectl get pods -n "$NAMESPACE"
}

sleep 10
SERVICE_IP=$(kubectl get svc nextcloud -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Nextcloud installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Nextcloud at: http://$SERVICE_IP"
echo ""
echo "🔐 Admin Credentials:"
echo "   Username: admin"
echo "   Password: $ADMIN_PASSWORD"
echo ""
echo -e "${YELLOW}⚠️  IMPORTANT: Save your admin password!${NC}"
echo "   You can also retrieve it later with:"
echo "   kubectl get secret nextcloud-admin -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
echo ""
echo "📱 First Time Setup:"
echo "   1. Open the URL above in your browser"
echo "   2. Log in with the admin credentials"
echo "   3. Complete the setup wizard"
echo "   4. Install recommended apps"
echo ""
echo "💡 Features:"
echo "   • File storage and sync"
echo "   • Calendar and contacts"
echo "   • Photo gallery"
echo "   • Document editing (install Collabora or OnlyOffice)"
echo "   • Mobile apps for iOS/Android"
echo "   • Desktop sync clients"
echo ""

# Register service in service registry
if command -v kubectl &> /dev/null && kubectl get nodes &>/dev/null 2>&1; then
    echo "📝 Registering service in registry..."
    
    # Register with custom subdomain
    if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "nextcloud" "$APP_SUBDOMAIN" "$NAMESPACE" "nextcloud" "80" "false"; then
            echo "✓ Service registered in registry"
            echo ""
            
            # Verify registration
            echo "🔍 Verifying registration..."
            REGISTERED_SUBDOMAIN=$(kubectl get configmap -n kube-system service-registry \
                -o jsonpath='{.data.services\.json}' 2>/dev/null | \
                jq -r '.nextcloud.subdomain' 2>/dev/null || echo "")
            
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
                if sudo bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" --quiet 2>/dev/null; then
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
            
            echo "✓ Access Nextcloud at:"
            echo "   http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
            echo ""
        else
            echo "⚠️  Could not register service (will update DNS manually)"
            echo ""
            
            # Fallback to manual DNS update
            if sudo bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" --quiet 2>/dev/null; then
                echo "✓ Local DNS updated manually"
            fi
        fi
    else
        # Fallback to manual DNS update if service-registry.sh not found
        echo -e "${YELLOW}⚠️  Service registry not found - updating DNS manually${NC}"
        if sudo bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" --quiet 2>/dev/null; then
            echo "✓ Local DNS updated"
        fi
    fi
fi

# Automatically configure routing and ask about public access
if [[ -f "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" ]]; then
    source "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" "nextcloud" "80" "$APP_SUBDOMAIN" "$NAMESPACE" "nextcloud"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
