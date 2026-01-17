#!/bin/bash

###############################################################################
# Mattermost - One-Click Installation
# 
# Open source team chat and collaboration
# Self-hosted alternative to Slack and Microsoft Teams
###############################################################################

set -euo pipefail

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# Load shared validation library
source "$PROJECT_ROOT/scripts/apps/mattermost/lib/validation.sh"

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
echo -e "${BLUE}  Installing Mattermost (Team Chat)${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate prerequisites
validate_prerequisites

# Prompt for subdomain
echo "🌐 App Subdomain Configuration"
echo ""
echo "Choose a subdomain for Mattermost. This will be used for:"
echo "  • Local access: <subdomain>.${CLUSTER_DOMAIN}.local"
echo "  • Public access: <subdomain>.yourdomain.com (if VPS configured)"
echo ""
echo "Examples: chat, mattermost, team, slack"
echo ""
read -p "Enter subdomain [default: mattermost]: " APP_SUBDOMAIN
APP_SUBDOMAIN="${APP_SUBDOMAIN:-mattermost}"

# Sanitize subdomain
APP_SUBDOMAIN=$(validate_and_sanitize_subdomain "$APP_SUBDOMAIN" "mattermost")

echo ""
echo "✓ Subdomain: ${APP_SUBDOMAIN}"
echo "  Local: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""

NAMESPACE="mattermost"

# Prompt for storage allocation
echo ""
echo "💾 Storage Configuration"
echo ""
echo "Mattermost requires storage for data and database."
echo ""
echo "Recommended data storage sizes:"
echo "  • 20Gi   - Good for small teams (5-10 users)"
echo "  • 50Gi   - Good for medium teams (10-50 users, recommended)"
echo "  • 100Gi  - Good for large teams (50+ users)"
echo "  • 200Gi+ - Good for enterprise teams with extensive file sharing"
echo ""
read -p "Enter data storage size [default: 50Gi]: " DATA_STORAGE
DATA_STORAGE="${DATA_STORAGE:-50Gi}"

echo ""
echo "Database storage (for messages, user data, channels):"
echo "  • 10Gi   - Good for small teams (recommended)"
echo "  • 20Gi   - Good for medium teams"
echo "  • 50Gi   - Good for large teams with extensive history"
echo ""
read -p "Enter database storage size [default: 10Gi]: " DB_STORAGE
DB_STORAGE="${DB_STORAGE:-10Gi}"

echo ""
echo "✓ Storage allocation:"
echo "  Data: $DATA_STORAGE"
echo "  Database: $DB_STORAGE"
echo ""

echo "🔐 Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -hex 32)

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🔒 Creating secrets..."
kubectl create secret generic mattermost-db \
    --from-literal=db-password="$POSTGRES_PASSWORD" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mattermost-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $DATA_STORAGE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mattermost-postgres
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
  name: mattermost-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mattermost-postgres
  template:
    metadata:
      labels:
        app: mattermost-postgres
    spec:
      priorityClassName: mynodeone-infrastructure
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_DB
          value: mattermost
        - name: POSTGRES_USER
          value: mattermost
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mattermost-db
              key: db-password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "1Gi"
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: mattermost-postgres
---
apiVersion: v1
kind: Service
metadata:
  name: mattermost-postgres
  namespace: $NAMESPACE
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: mattermost-postgres
EOF

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/mattermost-postgres -n "$NAMESPACE" || true
sleep 10

echo "💬 Deploying Mattermost..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mattermost
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mattermost
  template:
    metadata:
      labels:
        app: mattermost
    spec:
      priorityClassName: mynodeone-app
      containers:
      - name: mattermost
        image: mattermost/mattermost-team-edition:latest
        env:
        - name: MM_SQLSETTINGS_DRIVERNAME
          value: postgres
        - name: MM_SQLSETTINGS_DATASOURCE
          value: postgres://mattermost:$POSTGRES_PASSWORD@mattermost-postgres:5432/mattermost?sslmode=disable&connect_timeout=10
        - name: MM_SERVICESETTINGS_SITEURL
          value: "http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
        - name: MM_SERVICESETTINGS_ENABLELOCALMODE
          value: "true"
        - name: TZ
          value: "UTC"
        ports:
        - containerPort: 8065
          name: http
        volumeMounts:
        - name: mattermost-data
          mountPath: /mattermost/data
        - name: mattermost-config
          mountPath: /mattermost/config
        - name: mattermost-logs
          mountPath: /mattermost/logs
        - name: mattermost-plugins
          mountPath: /mattermost/plugins
        - name: mattermost-client-plugins
          mountPath: /mattermost/client/plugins
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "2Gi"
        livenessProbe:
          httpGet:
            path: /api/v4/system/ping
            port: 8065
          initialDelaySeconds: 90
          periodSeconds: 15
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /api/v4/system/ping
            port: 8065
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
      volumes:
      - name: mattermost-data
        persistentVolumeClaim:
          claimName: mattermost-data
      - name: mattermost-config
        emptyDir: {}
      - name: mattermost-logs
        emptyDir: {}
      - name: mattermost-plugins
        emptyDir: {}
      - name: mattermost-client-plugins
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mattermost
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8065
    protocol: TCP
    name: http
  selector:
    app: mattermost
EOF

echo ""
echo "⏳ Waiting for Mattermost to be ready..."
kubectl wait --for=condition=available --timeout=180s deployment/mattermost -n "$NAMESPACE" || true

echo ""
echo "📝 Registering service in registry..."
if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
    if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
        "mattermost" "$APP_SUBDOMAIN" "$NAMESPACE" "mattermost" "80" "false"; then
        echo "✓ Service registered in registry"
        
        # Verify registration
        if bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" get "mattermost" &>/dev/null; then
            echo "✓ Service registration verified"
            
            # Update local DNS
            echo "🔄 Updating local DNS..."
            if [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
                bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" || echo "⚠️  DNS sync completed with warnings"
            fi
            
            # Trigger sync to all nodes
            echo "🔄 Syncing DNS to all nodes..."
            if [ -f "$PROJECT_ROOT/scripts/lib/sync-controller.sh" ]; then
                bash "$PROJECT_ROOT/scripts/lib/sync-controller.sh" || echo "⚠️  Node sync completed with warnings"
            fi
        else
            echo "⚠️  Warning: Could not verify service registration"
        fi
    else
        echo "⚠️  Warning: Service registration failed"
    fi
else
    echo "⚠️  Warning: Service registry script not found"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Mattermost Installation Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📍 Access Information:"
echo "   Local URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""
echo "👤 First-Time Setup:"
echo "   1. Open the URL above in your browser"
echo "   2. Create your admin account (first user becomes admin)"
echo "   3. Set up your team name and URL"
echo "   4. Start inviting team members!"
echo ""
echo "📱 Mobile & Desktop Apps:"
echo "   • iOS: Search 'Mattermost' in App Store"
echo "   • Android: Search 'Mattermost' in Play Store"
echo "   • Desktop: Download from https://mattermost.com/download"
echo "   • Server URL: http://${APP_SUBDOMAIN}.${CLUSTER_DOMAIN}.local"
echo ""
echo "🔧 Management Commands:"
echo "   View logs:      kubectl logs -n $NAMESPACE -l app=mattermost -f"
echo "   Check status:   kubectl get all -n $NAMESPACE"
echo "   Restart:        kubectl rollout restart deployment/mattermost -n $NAMESPACE"
echo ""
echo "📚 Documentation:"
echo "   • User Guide: https://docs.mattermost.com/guides/user.html"
echo "   • Admin Guide: https://docs.mattermost.com/guides/administrator.html"
echo ""

# Source post-install routing for public access configuration
if [ -f "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" ]; then
    source "$PROJECT_ROOT/scripts/apps/lib/post-install-routing.sh" "mattermost" "80" "$APP_SUBDOMAIN" "$NAMESPACE" "mattermost"
fi

echo -e "${GREEN}Installation complete! 🎉${NC}"
echo ""
