#!/bin/bash

###############################################################################
# Paperless-ngx - One-Click Installation
# 
# Document management system with OCR
# Scan, index, and archive all your physical documents
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
echo -e "${BLUE}  Installing Paperless-ngx (Document Management)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

# Prompt for subdomain
echo "🌐 App Subdomain Configuration"
echo ""
echo "Choose a subdomain for Paperless. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: paperless, docs, documents, archive"
echo ""
read -p "Enter subdomain [default: paperless]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-paperless}"

# Sanitize subdomain
APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "paperless")

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

NAMESPACE="paperless"

# Prompt for storage allocation
echo ""
echo "💾 Storage Configuration"
echo ""
echo "Paperless requires storage for documents, media, and database."
echo ""
echo "Recommended document storage sizes:"
echo "  • 50Gi   - Good for personal use (~5,000 documents)"
echo "  • 100Gi  - Good for small family (recommended)"
echo "  • 200Gi  - Good for large family or small business"
echo "  • 500Gi+ - Good for extensive archives"
echo ""
read -p "Enter document storage size [default: 100Gi]: " DOC_STORAGE
DOC_STORAGE="${DOC_STORAGE:-100Gi}"

echo ""
echo "Database storage (for metadata and search index):"
echo "  • 5Gi    - Good for personal use (recommended)"
echo "  • 10Gi   - Good for families or small business"
echo "  • 20Gi   - Good for large archives"
echo ""
read -p "Enter database storage size [default: 5Gi]: " DB_STORAGE
DB_STORAGE="${DB_STORAGE:-5Gi}"

echo ""
echo "✓ Storage allocation:"
echo "  Documents: $DOC_STORAGE"
echo "  Database: $DB_STORAGE"
echo ""

echo "🔐 Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -base64 32)
REDIS_PASSWORD=$(openssl rand -base64 32)
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
SECRET_KEY=$(openssl rand -base64 32)

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🔒 Creating secrets..."
kubectl create secret generic paperless-db \
    --from-literal=postgres-password="$POSTGRES_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic paperless-redis \
    --from-literal=redis-password="$REDIS_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic paperless-secret \
    --from-literal=secret-key="$SECRET_KEY" \
    --from-literal=admin-password="$ADMIN_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $DOC_STORAGE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-media
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $DOC_STORAGE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-postgres
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $DB_STORAGE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-redis
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF

echo "🗄️ Deploying PostgreSQL..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless-postgres
  template:
    metadata:
      labels:
        app: paperless-postgres
    spec:
      priorityClassName: mynodeone-infrastructure
      containers:
      - name: postgres
        image: postgres:16
        env:
        - name: POSTGRES_DB
          value: paperless
        - name: POSTGRES_USER
          value: paperless
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: paperless-db
              key: postgres-password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: paperless-postgres
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: paperless-postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF

echo "📮 Deploying Redis..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-redis
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless-redis
  template:
    metadata:
      labels:
        app: paperless-redis
    spec:
      priorityClassName: mynodeone-infrastructure
      containers:
      - name: redis
        image: redis:7
        ports:
        - containerPort: 6379
        volumeMounts:
        - name: redis-storage
          mountPath: /data
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
      volumes:
      - name: redis-storage
        persistentVolumeClaim:
          claimName: paperless-redis
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-redis
  namespace: $NAMESPACE
spec:
  selector:
    app: paperless-redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

echo "⏳ Waiting for database and Redis to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/paperless-postgres -n "$NAMESPACE" || true
kubectl wait --for=condition=available --timeout=120s deployment/paperless-redis -n "$NAMESPACE" || true
sleep 10

echo "📄 Deploying Paperless-ngx..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless
  template:
    metadata:
      labels:
        app: paperless
    spec:
      priorityClassName: mynodeone-app
      containers:
      - name: paperless
        image: ghcr.io/paperless-ngx/paperless-ngx:latest
        env:
        - name: PAPERLESS_PORT
          value: "8000"
        - name: PAPERLESS_REDIS
          value: "redis://paperless-redis:6379"
        - name: PAPERLESS_DBHOST
          value: paperless-postgres
        - name: PAPERLESS_DBNAME
          value: paperless
        - name: PAPERLESS_DBUSER
          value: paperless
        - name: PAPERLESS_DBPASS
          valueFrom:
            secretKeyRef:
              name: paperless-db
              key: postgres-password
        - name: PAPERLESS_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: paperless-secret
              key: secret-key
        - name: PAPERLESS_URL
          value: "http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        - name: PAPERLESS_ALLOWED_HOSTS
          value: "${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        - name: PAPERLESS_CSRF_TRUSTED_ORIGINS
          value: "http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        - name: PAPERLESS_TIME_ZONE
          value: "UTC"
        - name: PAPERLESS_OCR_LANGUAGE
          value: "eng"
        - name: PAPERLESS_ADMIN_USER
          value: admin
        - name: PAPERLESS_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: paperless-secret
              key: admin-password
        - name: PAPERLESS_ADMIN_MAIL
          value: admin@localhost
        ports:
        - containerPort: 8000
        volumeMounts:
        - name: data
          mountPath: /usr/src/paperless/data
        - name: media
          mountPath: /usr/src/paperless/media
        - name: consume
          mountPath: /usr/src/paperless/consume
        - name: export
          mountPath: /usr/src/paperless/export
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "2Gi"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: paperless-data
      - name: media
        persistentVolumeClaim:
          claimName: paperless-media
      - name: consume
        emptyDir: {}
      - name: export
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: paperless
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  selector:
    app: paperless
  ports:
  - port: 80
    targetPort: 8000
EOF

echo ""
echo "⏳ Waiting for Paperless to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/paperless -n "$NAMESPACE" || true

echo ""
echo "📝 Registering service in service registry..."
if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "paperless" "$APP_SUBDOMAIN" "$NAMESPACE" "paperless" "80" "false"; then
        echo "✓ Service registered in registry"
        
        # Verify registration
        if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" get "paperless" &>/dev/null; then
            echo "✓ Service registration verified"
            
            # Update local DNS immediately
            if [ -f "$PROJECT_ROOT/scripts/sync-dns.sh" ]; then
                echo "🔄 Updating DNS..."
                if sudo bash "$PROJECT_ROOT/scripts/sync-dns.sh" --quiet 2>/dev/null; then
                    echo "✓ DNS updated"
                fi
            fi
            
            # Trigger sync to all remote nodes
            if [ -f "$PROJECT_ROOT/scripts/lib/sync-controller.sh" ]; then
                echo "🔄 Syncing to all nodes..."
                if sudo bash "$PROJECT_ROOT/scripts/lib/sync-controller.sh" push >/dev/null 2>&1; then
                    echo "✓ Sync completed"
                else
                    echo "⚠️  Sync will retry automatically"
                fi
            fi
        else
            echo "⚠️  Could not verify service registration"
        fi
    else
        echo "⚠️  Service registration failed, but installation continues"
    fi
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Paperless-ngx Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📋 Access Information:"
echo "  URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""
echo "🔐 Login Credentials:"
echo "  Username: admin"
echo "  Password: $ADMIN_PASSWORD"
echo ""
echo "⚠️  IMPORTANT: Save these credentials securely!"
echo ""
echo "📚 Next Steps:"
echo "  1. Access Paperless at the URL above"
echo "  2. Login with the credentials shown"
echo "  3. Configure document consumption methods:"
echo "     • Upload via web interface"
echo "     • Email documents (configure in settings)"
echo "     • Mobile app scanning"
echo "  4. Set up document tags and correspondents"
echo "  5. Configure OCR languages if needed"
echo ""
echo "📱 Mobile Apps:"
echo "  • iOS: Paperless Mobile (App Store)"
echo "  • Android: Paperless Mobile (Play Store)"
echo ""
echo "🌐 Public Access:"
echo "  To make Paperless accessible from the internet:"
echo "  sudo ./scripts/manage-app-visibility.sh"
echo ""

# Call post-install routing script
if [ -f "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" ]; then
    source "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" "paperless" "80" "$APP_SUBDOMAIN" "$NAMESPACE" "paperless"
fi

echo "✅ Installation complete!"
echo ""
