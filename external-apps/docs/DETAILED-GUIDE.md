# External App Deployment Guide

This guide explains how to deploy your own applications on MyNodeOne without adding them to the MyNodeOne repository. This is ideal for:

- **Personal SaaS applications** you want to build and deploy privately
- **Custom business applications** specific to your needs  
- **Third-party developers** who want to use MyNodeOne as infrastructure

## Table of Contents

1. [Quick Start](#quick-start)
2. [Deployment Patterns](#deployment-patterns)
3. [Integration with MyNodeOne](#integration-with-mynodeone)
4. [Exposing Apps to Internet](#exposing-apps-to-internet)
5. [Best Practices](#best-practices)
6. [Example Applications](#example-applications)

---

## Quick Start

### Prerequisites

- MyNodeOne cluster running and accessible
- `kubectl` configured to access your cluster
- Basic understanding of Kubernetes manifests

### 5-Minute Deploy

```bash
# 1. Create your app namespace and manifests (see templates below)
kubectl apply -f your-app.yaml

# 2. Register with MyNodeOne (for DNS and routing)
bash /path/to/MyNodeOne/scripts/lib/register-external-app.sh \
  --name "myapp" \
  --namespace "myapp" \
  --subdomain "myapp" \
  --service "myapp-frontend" \
  --port "80"

# 3. Access your app
# Local: http://myapp.mynodeone.local
# Public: Configure via manage-app-visibility.sh
```

---

## Deployment Patterns

### Pattern 1: Standalone Repository (Recommended for SaaS)

**Directory Structure:**
```
your-saas-app/
├── kubernetes/
│   ├── namespace.yaml
│   ├── database.yaml
│   ├── backend.yaml
│   ├── frontend.yaml
│   └── service.yaml
├── scripts/
│   └── deploy.sh              # Your deployment script
├── .mynodeone/
│   └── config.yaml            # MyNodeOne integration config
├── src/                       # Your application code
├── Dockerfile
└── README.md
```

**Benefits:**
- Complete separation from MyNodeOne repo
- Your own Git history and versioning
- Can be private or open source
- Easy to share with team/customers

**Integration:**
- Use MyNodeOne helper scripts for registration
- Reference MyNodeOne cluster via KUBECONFIG
- No MyNodeOne code in your repo

### Pattern 2: Kubernetes-Native with Annotations

**Use standard Kubernetes manifests with MyNodeOne annotations:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
  annotations:
    # MyNodeOne service registry integration
    mynodeone.io/subdomain: "myapp"
    mynodeone.io/auto-register: "true"
    mynodeone.io/public: "false"  # Change to "true" for internet access
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: myapp
```

**Benefits:**
- Standard kubectl workflow
- No special scripts needed
- MyNodeOne auto-discovers your app
- Works with any CI/CD pipeline

### Pattern 3: Template-Based Quick Start

Use the MyNodeOne app template generator:

```bash
# Generate a new app from template
cd /path/to/MyNodeOne
bash scripts/new-external-app.sh --name "myapp" --type "fullstack"

# This creates:
# - Kubernetes manifests
# - Deployment script
# - Integration config
# - Example code structure
```

---

## Integration with MyNodeOne

### Service Registry Integration

MyNodeOne maintains a central service registry for DNS and routing. To integrate your external app:

#### Option A: Automatic Registration (Recommended)

Add annotations to your LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
  annotations:
    mynodeone.io/subdomain: "myapp"
    mynodeone.io/auto-register: "true"
spec:
  type: LoadBalancer
  # ... rest of config
```

Then sync the registry:
```bash
kubectl exec -n kube-system deploy/mynodeone-controller -- \
  /app/scripts/lib/service-registry.sh sync
```

#### Option B: Manual Registration

```bash
# From MyNodeOne control plane
bash /path/to/MyNodeOne/scripts/lib/service-registry.sh register \
  "myapp" \          # Service name
  "myapp" \          # Subdomain
  "myapp" \          # Namespace
  "myapp-service" \  # Service name in k8s
  "80" \             # Port
  "false"            # Public (true/false)

# Update DNS
bash /path/to/MyNodeOne/scripts/sync-dns.sh
```

#### Option C: Using Helper Script (Easiest)

We'll create a dedicated helper script for external apps:

```bash
# Copy this to your app repo
curl -o register-app.sh \
  https://raw.githubusercontent.com/mynodeone/MyNodeOne/main/scripts/lib/register-external-app.sh

# Run it
bash register-app.sh \
  --name "myapp" \
  --subdomain "myapp" \
  --namespace "myapp" \
  --service "myapp-frontend" \
  --port 80
```

### DNS Integration

Once registered, your app gets:
- **Local DNS**: `http://<subdomain>.mynodeone.local` (or your CLUSTER_DOMAIN)
- **Automatic resolution** on all cluster nodes
- **Sync to worker nodes** via MyNodeOne sync controller

### Storage Integration

Use Longhorn storage (already configured in MyNodeOne):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  namespace: myapp
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn  # Use MyNodeOne's Longhorn storage
  resources:
    requests:
      storage: 50Gi
```

**Benefits:**
- Automatic replication across nodes
- Built-in snapshots and backups
- High availability

---

## Exposing Apps to Internet

### Make Your App Publicly Accessible

MyNodeOne provides built-in public routing via VPS edge nodes.

#### Step 1: Make Service Public

```bash
# Interactive configuration
sudo /path/to/MyNodeOne/scripts/manage-app-visibility.sh

# Select your app from the list
# Choose which domains and VPS nodes to use
```

#### Step 2: Configure DNS

Add DNS records at your domain registrar:

```
Type: A
Name: myapp (or * for wildcard)
Value: <VPS_PUBLIC_IP>
TTL: 300
```

#### Step 3: SSL Certificates

MyNodeOne automatically obtains SSL certificates via Let's Encrypt. Your app will be accessible at:
```
https://myapp.yourdomain.com
```

### Manual Public Configuration

If you prefer manual control:

```bash
# Register domain routing
bash /path/to/MyNodeOne/scripts/lib/multi-domain-registry.sh configure-routing \
  "myapp" \              # Service name
  "yourdomain.com" \     # Domain
  "vps-node-ip" \        # VPS node IP
  "round-robin"          # Load balancing strategy

# Push to VPS nodes
bash /path/to/MyNodeOne/scripts/lib/sync-controller.sh push
```

---

## Best Practices

### 1. Namespace Isolation

Always create a dedicated namespace for your app:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
  labels:
    app.kubernetes.io/name: myapp
    app.kubernetes.io/managed-by: external
```

### 2. Resource Limits

Set appropriate resource requests and limits:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### 3. Health Checks

Always include health checks:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
```

### 4. Security

Follow Kubernetes security best practices:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop:
    - ALL
```

### 5. Environment Variables

Use ConfigMaps and Secrets:

```yaml
# ConfigMap for non-sensitive config
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
  namespace: myapp
data:
  NODE_ENV: "production"
  API_URL: "https://api.myapp.com"

---
# Secret for sensitive data
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secrets
  namespace: myapp
type: Opaque
stringData:
  DATABASE_URL: "postgresql://user:pass@host:5432/db"
  API_KEY: "your-secret-key"
```

### 6. Deployment Strategy

Use rolling updates for zero-downtime deployments:

```yaml
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

### 7. Monitoring and Logging

- Use `kubectl logs` for application logs
- Logs are automatically collected by MyNodeOne
- Add Prometheus metrics endpoint for monitoring

---

## Example Applications

### Example 1: Simple Web App

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: mywebapp

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mywebapp
  namespace: mywebapp
spec:
  replicas: 2
  selector:
    matchLabels:
      app: mywebapp
  template:
    metadata:
      labels:
        app: mywebapp
    spec:
      containers:
      - name: web
        image: your-registry/mywebapp:latest
        ports:
        - containerPort: 8080
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
  name: mywebapp
  namespace: mywebapp
  annotations:
    mynodeone.io/subdomain: "mywebapp"
    mynodeone.io/auto-register: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: mywebapp
```

### Example 2: Full-Stack SaaS App

See `manifests/examples/fullstack-app.yaml` for a complete example with:
- Frontend (React/Vue)
- Backend API (Node.js/Python)
- PostgreSQL database
- Redis cache
- Horizontal auto-scaling

Customize it for your SaaS app by:
1. Copy the template
2. Change namespace to your app name
3. Update image references to your Docker images
4. Add your environment variables
5. Deploy: `kubectl apply -f your-saas-app.yaml`

### Example 3: Python FastAPI App

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: myapi

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapi
  namespace: myapi
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapi
  template:
    metadata:
      labels:
        app: myapi
    spec:
      containers:
      - name: api
        image: your-registry/myapi:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: myapi-secrets
              key: database-url
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
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10

---
apiVersion: v1
kind: Service
metadata:
  name: myapi
  namespace: myapi
  annotations:
    mynodeone.io/subdomain: "api"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8000
  selector:
    app: myapi
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Deploy to MyNodeOne

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build Docker image
        run: |
          docker build -t your-registry/myapp:${{ github.sha }} .
          docker push your-registry/myapp:${{ github.sha }}
      
      - name: Deploy to MyNodeOne
        env:
          KUBECONFIG_CONTENT: ${{ secrets.KUBECONFIG }}
        run: |
          echo "$KUBECONFIG_CONTENT" > /tmp/kubeconfig
          export KUBECONFIG=/tmp/kubeconfig
          
          # Update image tag
          kubectl set image deployment/myapp \
            myapp=your-registry/myapp:${{ github.sha }} \
            -n myapp
          
          # Wait for rollout
          kubectl rollout status deployment/myapp -n myapp
```

### GitLab CI Example

```yaml
deploy:
  stage: deploy
  script:
    - kubectl apply -f kubernetes/
    - kubectl rollout restart deployment/myapp -n myapp
  only:
    - main
```

---

## Troubleshooting

### App not accessible via DNS

```bash
# Check if service is registered
kubectl get configmap -n kube-system service-registry -o yaml

# Sync DNS manually
sudo bash /path/to/MyNodeOne/scripts/sync-dns.sh

# Check service has LoadBalancer IP
kubectl get svc -n your-namespace
```

### LoadBalancer stuck in Pending

```bash
# Check MetalLB status
kubectl get pods -n metallb-system

# Check IP pool
kubectl get ipaddresspool -n metallb-system

# See available IPs
kubectl get svc --all-namespaces | grep LoadBalancer
```

### Public access not working

```bash
# Check domain registry
kubectl get configmap -n kube-system domain-registry -o yaml

# Check VPS node status
kubectl get configmap -n kube-system domain-registry \
  -o jsonpath='{.data.vps-nodes\.json}' | jq

# Test VPS connectivity
ping <vps-public-ip>
```

---

## Migration from MyNodeOne Repo

If you have an app in `scripts/apps/` and want to move it external:

1. Create new Git repository
2. Copy your app manifests to `kubernetes/` directory
3. Update namespace and service names
4. Add MyNodeOne annotations to services
5. Create deployment script using helper scripts
6. Remove from MyNodeOne repo
7. Update documentation

---

## Community and Support

- **Documentation**: https://docs.mynodeone.io
- **Examples**: `mynodeone/MyNodeOne/manifests/examples/`
- **Issues**: GitHub Issues
- **Discussions**: GitHub Discussions

---

## Next Steps

1. **Choose your pattern**: Standalone repo, Kubernetes-native, or template-based
2. **Create your app**: Use examples as starting point
3. **Deploy**: Apply manifests and register with MyNodeOne
4. **Go public**: Configure domain routing for internet access
5. **Scale**: Add replicas, auto-scaling, and monitoring

Happy building! 🚀
