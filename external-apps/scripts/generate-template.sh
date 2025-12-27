#!/bin/bash

###############################################################################
# External App Template Generator
# 
# Scaffolds a new external application with MyNodeOne integration
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default values
APP_NAME=""
APP_TYPE="simple"
OUTPUT_DIR=""
INCLUDE_DATABASE="false"
INCLUDE_REDIS="false"

usage() {
    cat << EOF
Generate External App Template for MyNodeOne

Usage:
  $(basename "$0") --name <name> [options]

Required:
  --name <name>           Application name (e.g., myapp, my-saas)

Optional:
  --type <type>           App type: simple, fullstack, api (default: simple)
  --output <dir>          Output directory (default: ../external-apps/<name>)
  --database              Include PostgreSQL database
  --redis                 Include Redis cache
  --help                  Show this help

App Types:
  simple      - Single container web app (nginx, static site)
  fullstack   - Frontend + Backend + Database
  api         - Backend API only (FastAPI, Express, etc.)

Examples:
  # Simple web app
  $(basename "$0") --name mywebapp

  # Full-stack SaaS with database and cache
  $(basename "$0") --name mysaas --type fullstack --database --redis

  # API backend with database
  $(basename "$0") --name myapi --type api --database

EOF
    exit 1
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            APP_NAME="$2"
            shift 2
            ;;
        --type)
            APP_TYPE="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --database)
            INCLUDE_DATABASE="true"
            shift
            ;;
        --redis)
            INCLUDE_REDIS="true"
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate
if [[ -z "$APP_NAME" ]]; then
    echo "Error: --name is required"
    usage
fi

# Sanitize app name
APP_NAME=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

# Set output directory
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$PROJECT_ROOT/../external-apps/$APP_NAME"
fi

# Validate app type
if [[ ! "$APP_TYPE" =~ ^(simple|fullstack|api)$ ]]; then
    echo "Error: Invalid app type. Must be: simple, fullstack, or api"
    exit 1
fi

# Auto-include database for fullstack
if [[ "$APP_TYPE" == "fullstack" ]]; then
    INCLUDE_DATABASE="true"
fi

clear
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🚀 External App Template Generator"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "App Name:      $APP_NAME"
log_info "App Type:      $APP_TYPE"
log_info "Output Dir:    $OUTPUT_DIR"
log_info "Database:      $INCLUDE_DATABASE"
log_info "Redis:         $INCLUDE_REDIS"
echo ""

# Check if output directory exists
if [[ -d "$OUTPUT_DIR" ]]; then
    log_warn "Directory already exists: $OUTPUT_DIR"
    read -p "Overwrite? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy] ]]; then
        echo "Cancelled."
        exit 0
    fi
    rm -rf "$OUTPUT_DIR"
fi

# Create directory structure
log_info "Creating directory structure..."
mkdir -p "$OUTPUT_DIR"/{kubernetes,scripts,src,.mynodeone}

# Create README
cat > "$OUTPUT_DIR/README.md" << EOF
# $APP_NAME

External application deployed on MyNodeOne cluster.

## Quick Start

\`\`\`bash
# Deploy to cluster
bash scripts/deploy.sh

# Check status
kubectl get all -n $APP_NAME

# Access app
# Local: http://$APP_NAME.mynodeone.local
\`\`\`

## Development

\`\`\`bash
# Build Docker image
docker build -t your-registry/$APP_NAME:latest .

# Push to registry
docker push your-registry/$APP_NAME:latest

# Update deployment
kubectl set image deployment/$APP_NAME \\
  $APP_NAME=your-registry/$APP_NAME:latest \\
  -n $APP_NAME
\`\`\`

## Configuration

Edit \`kubernetes/\` manifests to customize:
- Resource limits
- Storage size
- Environment variables
- Replicas

## Public Access

To expose this app to the internet:

\`\`\`bash
# From MyNodeOne control plane
sudo /path/to/MyNodeOne/scripts/manage-app-visibility.sh
\`\`\`

## MyNodeOne Integration

This app uses MyNodeOne for:
- ✅ DNS resolution (\`$APP_NAME.mynodeone.local\`)
- ✅ Load balancer (MetalLB)
- ✅ Storage (Longhorn)
- ✅ Public routing (VPS edge nodes)

## Deployment Script

See \`scripts/deploy.sh\` for automated deployment.

## Troubleshooting

\`\`\`bash
# View logs
kubectl logs -n $APP_NAME -l app=$APP_NAME -f

# Check pods
kubectl get pods -n $APP_NAME

# Restart deployment
kubectl rollout restart deployment/$APP_NAME -n $APP_NAME
\`\`\`
EOF

log_success "Created README.md"

# Create MyNodeOne config
cat > "$OUTPUT_DIR/.mynodeone/config.yaml" << EOF
# MyNodeOne Integration Configuration
app:
  name: "$APP_NAME"
  subdomain: "$APP_NAME"
  namespace: "$APP_NAME"
  
  # Service to register
  service:
    name: "$APP_NAME"
    port: 80
    
  # Public access
  public: false
  
  # Resource requirements
  resources:
    storage: "10Gi"
    memory: "512Mi"
    cpu: "500m"
EOF

log_success "Created .mynodeone/config.yaml"

# Create namespace
cat > "$OUTPUT_DIR/kubernetes/00-namespace.yaml" << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: $APP_NAME
  labels:
    app.kubernetes.io/name: $APP_NAME
    app.kubernetes.io/managed-by: external
EOF

log_success "Created kubernetes/00-namespace.yaml"

# Create database if requested
if [[ "$INCLUDE_DATABASE" == "true" ]]; then
    cat > "$OUTPUT_DIR/kubernetes/10-database.yaml" << EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${APP_NAME}-db-credentials
  namespace: $APP_NAME
type: Opaque
stringData:
  POSTGRES_USER: "$APP_NAME"
  POSTGRES_PASSWORD: "CHANGE-ME-$(openssl rand -hex 16)"
  POSTGRES_DB: "${APP_NAME}_production"
  DATABASE_URL: "postgresql://$APP_NAME:CHANGE-ME@postgres:5432/${APP_NAME}_production"

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: $APP_NAME
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 20Gi

---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: $APP_NAME
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
        envFrom:
        - secretRef:
            name: ${APP_NAME}-db-credentials
        env:
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: postgres-data

---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: $APP_NAME
spec:
  type: ClusterIP
  ports:
  - port: 5432
  selector:
    app: postgres
EOF

    log_success "Created kubernetes/10-database.yaml"
fi

# Create Redis if requested
if [[ "$INCLUDE_REDIS" == "true" ]]; then
    cat > "$OUTPUT_DIR/kubernetes/11-redis.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: $APP_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
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
            memory: "256Mi"
            cpu: "200m"

---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: $APP_NAME
spec:
  type: ClusterIP
  ports:
  - port: 6379
  selector:
    app: redis
EOF

    log_success "Created kubernetes/11-redis.yaml"
fi

# Create app deployment based on type
if [[ "$APP_TYPE" == "simple" ]]; then
    cat > "$OUTPUT_DIR/kubernetes/20-app.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
      - name: web
        image: nginxinc/nginx-unprivileged:alpine
        # TODO: Replace with your Docker image
        # image: your-registry/$APP_NAME:latest
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
  annotations:
    mynodeone.io/subdomain: "$APP_NAME"
    mynodeone.io/auto-register: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: $APP_NAME
EOF

elif [[ "$APP_TYPE" == "api" ]]; then
    cat > "$OUTPUT_DIR/kubernetes/20-app.yaml" << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-config
  namespace: $APP_NAME
data:
  NODE_ENV: "production"
  PORT: "8000"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
spec:
  replicas: 3
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
      - name: api
        # TODO: Replace with your API image
        image: your-registry/${APP_NAME}-api:latest
        ports:
        - containerPort: 8000
          name: http
        envFrom:
        - configMapRef:
            name: ${APP_NAME}-config
$(if [[ "$INCLUDE_DATABASE" == "true" ]]; then
cat << 'DBENV'
        - secretRef:
            name: ${APP_NAME}-db-credentials
DBENV
fi)
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
  annotations:
    mynodeone.io/subdomain: "$APP_NAME"
    mynodeone.io/auto-register: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8000
  selector:
    app: $APP_NAME
EOF

elif [[ "$APP_TYPE" == "fullstack" ]]; then
    cat > "$OUTPUT_DIR/kubernetes/20-backend.yaml" << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-backend-config
  namespace: $APP_NAME
data:
  NODE_ENV: "production"
  PORT: "3000"
$(if [[ "$INCLUDE_REDIS" == "true" ]]; then
cat << 'REDISENV'
  REDIS_URL: "redis://redis:6379"
REDISENV
fi)

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-backend
  namespace: $APP_NAME
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${APP_NAME}-backend
  template:
    metadata:
      labels:
        app: ${APP_NAME}-backend
    spec:
      containers:
      - name: backend
        # TODO: Replace with your backend image
        image: your-registry/${APP_NAME}-backend:latest
        ports:
        - containerPort: 3000
        envFrom:
        - configMapRef:
            name: ${APP_NAME}-backend-config
        - secretRef:
            name: ${APP_NAME}-db-credentials
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 10

---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-backend
  namespace: $APP_NAME
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 3000
  selector:
    app: ${APP_NAME}-backend
EOF

    cat > "$OUTPUT_DIR/kubernetes/21-frontend.yaml" << EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-frontend
  namespace: $APP_NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${APP_NAME}-frontend
  template:
    metadata:
      labels:
        app: ${APP_NAME}-frontend
    spec:
      containers:
      - name: frontend
        # TODO: Replace with your frontend image
        image: your-registry/${APP_NAME}-frontend:latest
        ports:
        - containerPort: 80
        env:
        - name: API_URL
          value: "http://${APP_NAME}-backend"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"

---
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
  annotations:
    mynodeone.io/subdomain: "$APP_NAME"
    mynodeone.io/auto-register: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: ${APP_NAME}-frontend
EOF
fi

log_success "Created kubernetes/20-app.yaml"

# Create deployment script
cat > "$OUTPUT_DIR/scripts/deploy.sh" << 'DEPLOY_SCRIPT'
#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load config
CONFIG_FILE="$APP_DIR/.mynodeone/config.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Parse YAML (basic parsing)
APP_NAME=$(grep 'name:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')
APP_SUBDOMAIN=$(grep 'subdomain:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
APP_NAMESPACE=$(grep 'namespace:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploying $APP_NAME to MyNodeOne"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found"
    exit 1
fi

# Apply manifests
echo "📦 Applying Kubernetes manifests..."
kubectl apply -f "$APP_DIR/kubernetes/"

echo ""
echo "⏳ Waiting for deployment..."
kubectl wait --for=condition=available --timeout=180s \
    deployment -n "$APP_NAMESPACE" -l app.kubernetes.io/name="$APP_NAME" 2>/dev/null || \
    kubectl wait --for=condition=available --timeout=180s \
    deployment -n "$APP_NAMESPACE" --all 2>/dev/null || true

echo ""
echo "📝 Registering with MyNodeOne..."

# Find MyNodeOne installation
MYNODEONE_PATH="${MYNODEONE_PATH:-/opt/MyNodeOne}"
if [[ ! -d "$MYNODEONE_PATH" ]]; then
    # Try common locations
    for path in ~/MyNodeOne ../MyNodeOne ../../MyNodeOne; do
        if [[ -d "$path" ]]; then
            MYNODEONE_PATH="$path"
            break
        fi
    done
fi

if [[ -f "$MYNODEONE_PATH/scripts/lib/register-external-app.sh" ]]; then
    SERVICE_NAME=$(kubectl get svc -n "$APP_NAMESPACE" -o name | grep -v postgres | grep -v redis | head -1 | cut -d'/' -f2)
    
    bash "$MYNODEONE_PATH/scripts/lib/register-external-app.sh" \
        --name "$APP_NAME" \
        --subdomain "$APP_SUBDOMAIN" \
        --namespace "$APP_NAMESPACE" \
        --service "$SERVICE_NAME"
else
    echo "⚠️  MyNodeOne not found at $MYNODEONE_PATH"
    echo "   Set MYNODEONE_PATH environment variable"
    echo ""
    echo "   Or register manually:"
    echo "   kubectl get svc -n $APP_NAMESPACE"
fi

echo ""
echo "✅ Deployment complete!"
echo ""
DEPLOY_SCRIPT

chmod +x "$OUTPUT_DIR/scripts/deploy.sh"
log_success "Created scripts/deploy.sh"

# Create example Dockerfile
cat > "$OUTPUT_DIR/Dockerfile" << 'DOCKERFILE'
# Example Dockerfile - customize for your app
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

# Production image
FROM node:20-alpine

WORKDIR /app

COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./

USER node

EXPOSE 8080

CMD ["node", "dist/index.js"]
DOCKERFILE

log_success "Created Dockerfile"

# Create gitignore
cat > "$OUTPUT_DIR/.gitignore" << 'GITIGNORE'
node_modules/
dist/
build/
*.log
.env
.DS_Store
.vscode/
.idea/
GITIGNORE

log_success "Created .gitignore"

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}  Template Created Successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_info "Created at: $OUTPUT_DIR"
echo ""
echo "📁 Directory Structure:"
tree -L 2 "$OUTPUT_DIR" 2>/dev/null || find "$OUTPUT_DIR" -type f | head -20

echo ""
echo "📋 Next Steps:"
echo ""
echo "1. Customize your app:"
echo "   cd $OUTPUT_DIR"
echo "   # Edit kubernetes/ manifests"
echo "   # Update Docker image references"
echo ""
echo "2. Deploy to MyNodeOne:"
echo "   bash scripts/deploy.sh"
echo ""
echo "3. Access your app:"
echo "   http://${APP_NAME}.mynodeone.local"
echo ""
echo "4. Make it public (optional):"
echo "   sudo /path/to/MyNodeOne/scripts/manage-app-visibility.sh"
echo ""

log_success "Happy building! 🚀"
echo ""
