# Example Applications

This directory contains ready-to-deploy example applications that demonstrate MyNodeOne capabilities and Kubernetes best practices.

## 🚀 Available Examples

### 🌐 Basic Applications

#### hello-world-app.yaml
**Purpose**: Simple nginx-based hello world application  
**Use Case**: Learn basic Kubernetes deployment concepts  
**Features**: 
- Deployment with 2 replicas
- Health checks (liveness/readiness probes)
- Resource limits and requests
- Traefik IngressRoute for HTTPS access

**Deploy**: `kubectl apply -f hello-world-app.yaml`  
**Access**: Update domain in IngressRoute, then access via HTTPS

---

### 🏗️ Full-Stack Applications

#### fullstack-app.yaml
**Purpose**: Complete web application with database and cache  
**Use Case**: Learn multi-service deployment patterns  
**Features**:
- Frontend web application
- PostgreSQL database with persistent storage
- Redis cache for session management
- Proper service discovery and networking

**Deploy**: `kubectl apply -f fullstack-app.yaml`  
**Access**: Services available within cluster network

---

### 🤖 AI/ML Applications

#### llm-cpu-inference.yaml
**Purpose**: CPU-based LLM inference server  
**Use Case**: Run AI models without GPU requirements  
**Features**:
- LLaMA model inference with CPU optimization
- Persistent model storage
- Resource-optimized for CPU-only nodes
- Internal API endpoint

**Deploy**: `kubectl apply -f llm-cpu-inference.yaml`  
**Access**: Internal service endpoint for API calls

#### open-webui.yaml
**Purpose**: Web-based AI chat interface (Open WebUI)  
**Use Case**: User-friendly chat interface for LLMs  
**Features**:
- Open WebUI frontend
- Connection to LLM inference backend
- Persistent chat history storage
- User authentication (basic)

**Deploy**: `kubectl apply -f open-webui.yaml`  
**Access**: Via Traefik with domain configuration

---

### 🗄️ Database Examples

#### postgres-database.yaml
**Purpose**: Production-ready PostgreSQL deployment  
**Use Case**: Database backend for applications  
**Features**:
- PostgreSQL 14+ with persistent storage
- Resource limits and backup configuration
- Environment-based configuration
- Service exposure within cluster

**Deploy**: `kubectl apply -f postgres-database.yaml`  
**Access**: `postgresql://user:pass@postgres:5432/dbname`

#### redis-cache.yaml
**Purpose**: Redis cache for session/data caching  
**Use Case**: High-performance caching layer  
**Features**:
- Redis 7+ with persistence
- Memory optimization
- Cluster-internal service
- Configuration via environment variables

**Deploy**: `kubectl apply -f redis-cache.yaml`  
**Access**: `redis://redis:6379`

---

### 🎭 Demo Applications

#### demo-app.yaml
**Purpose**: Comprehensive demo showcasing MyNodeOne features  
**Use Case**: Complete system demonstration  
**Features**:
- Interactive web dashboard
- Real-time cluster status display
- Service integration examples
- Modern UI with responsive design

**Deploy**: `kubectl apply -f demo-app.yaml`  
**Access**: Via configured domain with HTTPS

---

### ⏰ Automation Examples

#### cronjob-backup.yaml
**Purpose**: Automated backup solution  
**Use Case**: Regular data backups and maintenance  
**Features**:
- Kubernetes CronJob for scheduled backups
- Persistent volume for backup storage
- Configurable backup schedules
- Retention policies

**Deploy**: `kubectl apply -f cronjob-backup.yaml`  
**Access**: View backup logs and stored files

---

## 📋 Deployment Guide

### Prerequisites
- MyNodeOne cluster installed and running
- kubectl configured to access cluster
- Sufficient cluster resources (check each manifest)

### Quick Deployment
```bash
# Deploy all examples (for testing)
kubectl apply -f .

# Deploy specific example
kubectl apply -f hello-world-app.yaml

# Check deployment status
kubectl get pods --all-namespaces
```

### Customization
Each manifest can be customized for your environment:

#### Namespaces
```yaml
metadata:
  name: your-custom-namespace  # Change namespace
```

#### Resources
```yaml
resources:
  requests:
    memory: "128Mi"    # Adjust memory
    cpu: "100m"        # Adjust CPU
  limits:
    memory: "256Mi"
    cpu: "200m"
```

#### Storage
```yaml
resources:
  requests:
    storage: "10Gi"    # Adjust storage size
```

### Domain Configuration
For applications with external access (IngressRoute):

1. Update the Host field in IngressRoute:
```yaml
spec:
  routes:
  - match: Host(`your-app.yourdomain.com`)  # Change this
```

2. Ensure DNS points to your VPS edge node
3. MyNodeOne will automatically provision SSL certificate

## 🔍 Monitoring and Troubleshooting

### Check Application Status
```bash
# List all pods in all namespaces
kubectl get pods --all-namespaces

# Check specific application
kubectl get pods -n <namespace>

# View pod logs
kubectl logs <pod-name> -n <namespace>

# Describe pod for detailed information
kubectl describe pod <pod-name> -n <namespace>
```

### Check Services
```bash
# List all services
kubectl get svc --all-namespaces

# Check service endpoints
kubectl get endpoints -n <namespace>
```

### Check Storage
```bash
# List persistent volumes
kubectl get pv

# List persistent volume claims
kubectl get pvc --all-namespaces

# Check storage usage
kubectl df
```

### Common Issues and Solutions

#### Pod Pending/Not Starting
```bash
# Check resource availability
kubectl describe node <node-name>

# Check events
kubectl get events --sort-by=.metadata.creationTimestamp
```

#### Storage Issues
```bash
# Check Longhorn status
kubectl get pods -n longhorn-system

# Check volume status
kubectl get pv
```

#### Network Issues
```bash
# Check Traefik status
kubectl get pods -n traefik

# Check IngressRoute status
kubectl get ingressroute --all-namespaces
```

## 🧹 Cleanup

Remove example applications:
```bash
# Remove specific example
kubectl delete -f hello-world-app.yaml

# Remove all examples
kubectl delete -f .

# Clean up remaining resources
kubectl delete all --all -n demo-apps
kubectl delete all --all -n hello-world
kubectl delete namespace demo-apps hello-world
```

## 📚 Next Steps

1. **Learn the patterns**: Study how each manifest is structured
2. **Create your own**: Use examples as templates for your applications
3. **Explore advanced features**: Check GPU manifests for AI workloads
4. **Security hardening**: Apply security manifests to production deployments

## 🔗 Related Resources

- **App Store**: [../../docs/apps/APP-STORE.md](../../docs/apps/APP-STORE.md)
- **Create App Script**: `../../scripts/operations/create-app.sh`
- **GPU Support**: [../../docs/architecture/GPU-SUPPORT.md](../../docs/architecture/GPU-SUPPORT.md)
- **Security Guide**: [../../docs/security/SECURITY.md](../../docs/security/SECURITY.md)
