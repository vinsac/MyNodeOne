#!/bin/bash

###############################################################################
# NodeZero App Creator
# 
# Creates a new application with all necessary configurations for deployment
# to NodeZero cluster via ArgoCD GitOps
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

usage() {
    cat <<EOF
Usage: $0 <app-name> [options]

Options:
  -d, --domain DOMAIN     Domain name for the app (e.g., curiios.com)
  -p, --port PORT         Container port (default: 3000)
  -t, --type TYPE         App type: web, api, worker (default: web)
  -s, --storage SIZE      Storage size (e.g., 10Gi) - optional
  -h, --help              Show this help message

Example:
  $0 curiios --domain curiios.com --port 3000 --storage 20Gi
EOF
    exit 1
}

# Parse arguments
APP_NAME=""
DOMAIN=""
PORT="3000"
APP_TYPE="web"
STORAGE=""

if [ $# -eq 0 ]; then
    usage
fi

APP_NAME="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -t|--type)
            APP_TYPE="$2"
            shift 2
            ;;
        -s|--storage)
            STORAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate app name
if ! [[ "$APP_NAME" =~ ^[a-z0-9-]+$ ]]; then
    log_error "App name must contain only lowercase letters, numbers, and hyphens"
    exit 1
fi

create_directory_structure() {
    log_info "Creating directory structure for $APP_NAME..."
    
    mkdir -p "$APP_NAME"
    cd "$APP_NAME"
    
    mkdir -p {k8s,docker,.github/workflows}
    
    log_success "Directory structure created"
}

create_dockerfile() {
    log_info "Creating Dockerfile..."
    
    cat > docker/Dockerfile <<'EOF'
# Multi-stage Dockerfile for Node.js application
# Adjust as needed for your stack

FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy application code
COPY . .

# Build application (if needed)
# RUN npm run build

FROM node:20-alpine

WORKDIR /app

# Copy from builder
COPY --from=builder /app .

# Run as non-root user
USER node

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD node healthcheck.js || exit 1

# Start application
CMD ["node", "index.js"]
EOF
    
    # Create sample app files
    cat > index.js <<EOF
const http = require('http');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'healthy' }));
    return;
  }
  
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<h1>Hello from NodeZero!</h1><p>Your app is running successfully.</p>');
});

server.listen(PORT, () => {
  console.log(\`Server running on port \${PORT}\`);
});
EOF
    
    cat > healthcheck.js <<'EOF'
const http = require('http');

const options = {
  host: 'localhost',
  port: process.env.PORT || 3000,
  path: '/health',
  timeout: 2000
};

const request = http.request(options, (res) => {
  if (res.statusCode === 200) {
    process.exit(0);
  } else {
    process.exit(1);
  }
});

request.on('error', (err) => {
  process.exit(1);
});

request.end();
EOF
    
    cat > package.json <<EOF
{
  "name": "$APP_NAME",
  "version": "1.0.0",
  "description": "NodeZero application",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "keywords": [],
  "author": "",
  "license": "MIT"
}
EOF
    
    cat > .dockerignore <<EOF
node_modules
npm-debug.log
.git
.gitignore
README.md
.env
.env.*
k8s/
.github/
EOF
    
    log_success "Dockerfile and sample app created"
}

create_kubernetes_manifests() {
    log_info "Creating Kubernetes manifests..."
    
    # Deployment
    cat > k8s/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  labels:
    app: $APP_NAME
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
      - name: $APP_NAME
        image: DOCKER_IMAGE  # Will be replaced by CI/CD
        imagePullPolicy: Always
        ports:
        - containerPort: $PORT
          name: http
        env:
        - name: PORT
          value: "$PORT"
        - name: NODE_ENV
          value: "production"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 5
          periodSeconds: 5
EOF
    
    # Service
    cat > k8s/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  labels:
    app: $APP_NAME
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: $PORT
    protocol: TCP
    name: http
  selector:
    app: $APP_NAME
EOF
    
    # Ingress (if domain specified)
    if [ -n "$DOMAIN" ]; then
        cat > k8s/ingress.yaml <<EOF
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: $APP_NAME
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`$DOMAIN\`) || Host(\`www.$DOMAIN\`)
      kind: Rule
      services:
        - name: $APP_NAME
          port: 80
  tls:
    certResolver: letsencrypt
EOF
    fi
    
    # PersistentVolumeClaim (if storage specified)
    if [ -n "$STORAGE" ]; then
        cat > k8s/pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $APP_NAME-storage
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: $STORAGE
EOF
        
        # Add volume mount to deployment
        cat >> k8s/deployment.yaml <<EOF
        volumeMounts:
        - name: storage
          mountPath: /app/data
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: $APP_NAME-storage
EOF
    fi
    
    # Kustomization
    cat > k8s/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
EOF
    
    if [ -n "$DOMAIN" ]; then
        echo "  - ingress.yaml" >> k8s/kustomization.yaml
    fi
    
    if [ -n "$STORAGE" ]; then
        echo "  - pvc.yaml" >> k8s/kustomization.yaml
    fi
    
    log_success "Kubernetes manifests created"
}

create_github_workflow() {
    log_info "Creating GitHub Actions workflow..."
    
    cat > .github/workflows/deploy.yaml <<EOF
name: Build and Deploy

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: \${{ github.repository }}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
    - name: Checkout
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to Container Registry
      uses: docker/login-action@v3
      with:
        registry: \${{ env.REGISTRY }}
        username: \${{ github.actor }}
        password: \${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: \${{ env.REGISTRY }}/\${{ env.IMAGE_NAME }}
        tags: |
          type=sha,prefix=,format=short
          type=ref,event=branch
          type=raw,value=latest,enable={{is_default_branch}}

    - name: Build and push
      uses: docker/build-push-action@v5
      with:
        context: .
        file: ./docker/Dockerfile
        push: \${{ github.event_name != 'pull_request' }}
        tags: \${{ steps.meta.outputs.tags }}
        labels: \${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Update Kubernetes manifest
      if: github.ref == 'refs/heads/main'
      run: |
        IMAGE=\${{ env.REGISTRY }}/\${{ env.IMAGE_NAME }}:sha-\$(git rev-parse --short HEAD)
        sed -i "s|DOCKER_IMAGE|\$IMAGE|g" k8s/deployment.yaml
        
    - name: Commit updated manifest
      if: github.ref == 'refs/heads/main'
      run: |
        git config --local user.email "action@github.com"
        git config --local user.name "GitHub Action"
        git add k8s/deployment.yaml
        git diff --quiet && git diff --staged --quiet || git commit -m "Update image to \$(git rev-parse --short HEAD)"
        
    - name: Push changes
      if: github.ref == 'refs/heads/main'
      uses: ad-m/github-push-action@master
      with:
        github_token: \${{ secrets.GITHUB_TOKEN }}
        branch: \${{ github.ref }}
EOF
    
    log_success "GitHub Actions workflow created"
}

create_readme() {
    log_info "Creating README..."
    
    cat > README.md <<EOF
# $APP_NAME

NodeZero application

## Configuration

- **Domain**: ${DOMAIN:-Not configured}
- **Port**: $PORT
- **Type**: $APP_TYPE
- **Storage**: ${STORAGE:-None}

## Local Development

\`\`\`bash
npm install
npm start
\`\`\`

Visit http://localhost:$PORT

## Deployment

This app is automatically deployed to NodeZero via GitOps (ArgoCD).

1. Push your code to the main branch
2. GitHub Actions builds and pushes the Docker image
3. ArgoCD syncs the changes to the cluster

## Monitoring

- Logs: \`kubectl logs -f deployment/$APP_NAME\`
- Status: \`kubectl get pods -l app=$APP_NAME\`

## Architecture

This application runs on NodeZero, a private cloud infrastructure with:
- Automatic SSL certificates
- Load balancing across multiple nodes
- Distributed storage
- Comprehensive monitoring
EOF
    
    log_success "README created"
}

create_gitignore() {
    cat > .gitignore <<EOF
node_modules/
.env
.env.*
*.log
.DS_Store
dist/
build/
coverage/
EOF
}

initialize_git() {
    log_info "Initializing Git repository..."
    
    git init
    git add .
    git commit -m "Initial commit - $APP_NAME"
    
    log_success "Git repository initialized"
    log_info "Create a GitHub repository and push:"
    echo
    echo "  git remote add origin <your-repo-url>"
    echo "  git push -u origin main"
}

create_argocd_application() {
    log_info "Creating ArgoCD Application manifest..."
    
    cat > k8s/argocd-application.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_NAME
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/$APP_NAME.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
    
    log_info "To deploy this app to NodeZero:"
    echo
    echo "1. Update the repoURL in k8s/argocd-application.yaml"
    echo "2. Apply it: kubectl apply -f k8s/argocd-application.yaml"
    echo
}

print_summary() {
    log_success "Application $APP_NAME created successfully! 🎉"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Application Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "App Name: $APP_NAME"
    echo "Domain: ${DOMAIN:-Not configured}"
    echo "Port: $PORT"
    echo "Type: $APP_TYPE"
    echo "Storage: ${STORAGE:-None}"
    echo
    echo "Directory Structure:"
    echo "  $APP_NAME/"
    echo "  ├── docker/Dockerfile          # Docker build configuration"
    echo "  ├── k8s/                        # Kubernetes manifests"
    echo "  │   ├── deployment.yaml"
    echo "  │   ├── service.yaml"
    if [ -n "$DOMAIN" ]; then
        echo "  │   ├── ingress.yaml"
    fi
    if [ -n "$STORAGE" ]; then
        echo "  │   ├── pvc.yaml"
    fi
    echo "  │   └── kustomization.yaml"
    echo "  ├── .github/workflows/deploy.yaml  # CI/CD pipeline"
    echo "  ├── index.js                    # Sample application"
    echo "  └── README.md"
    echo
    echo "Next Steps:"
    echo "  1. Customize your application code"
    echo "  2. Create a GitHub repository"
    echo "  3. Push your code:"
    echo "     cd $APP_NAME"
    echo "     git remote add origin <your-repo-url>"
    echo "     git push -u origin main"
    echo
    echo "  4. Deploy to NodeZero:"
    echo "     kubectl apply -f k8s/argocd-application.yaml"
    echo
    if [ -n "$DOMAIN" ]; then
        echo "  5. Point your DNS to VPS IP addresses:"
        echo "     A    @    45.8.133.192"
        echo "     A    @    31.220.87.37"
        echo
    fi
    echo "Your app will be automatically built and deployed on every push!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NodeZero App Creator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    create_directory_structure
    create_dockerfile
    create_kubernetes_manifests
    create_github_workflow
    create_readme
    create_gitignore
    initialize_git
    create_argocd_application
    
    cd ..
    
    echo
    print_summary
}

# Run main function
main
