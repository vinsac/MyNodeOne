# Application Deployment Guide

This guide shows you how to easily deploy and manage applications on your MyNodeOne cluster.

---

## 🚀 Quick Start: One-Click App Deployment

MyNodeOne includes a helper script for easy app management:

```bash
# List available applications
sudo ./scripts/manage-apps.sh list

# Deploy an application
sudo ./scripts/manage-apps.sh deploy <app-name>

# Remove an application
sudo ./scripts/manage-apps.sh remove <app-name>

# Check status of deployed apps
sudo ./scripts/manage-apps.sh status
```

---

## 📦 Available One-Click Applications

### Databases

#### PostgreSQL
```bash
# Deploy
sudo ./scripts/manage-apps.sh deploy postgresql

# Connection info will be displayed after deployment
# Host: postgresql.databases.svc.cluster.local
# Port: 5432
# Database: myapp
# Username: postgres
# Password: changeme123 (change this!)
```

#### MySQL
```bash
# Deploy
sudo ./scripts/manage-apps.sh deploy mysql

# Connection info
# Host: mysql.databases.svc.cluster.local
# Port: 3306
# Database: myapp
# Root Password: changeme123 (change this!)
```

#### Redis
```bash
# Deploy
sudo ./scripts/manage-apps.sh deploy redis

# Connection info
# Host: redis.databases.svc.cluster.local
# Port: 6379
```

### Demo Application
```bash
# Deploy demo app to test your cluster
sudo ./scripts/manage-apps.sh deploy demo

# Or use the dedicated script
sudo ./scripts/deploy-demo-app.sh deploy
```

---

## 📝 Manual Deployment Methods

### Method 1: Using kubectl

#### Simple Deployment Example
```bash
# Create a deployment
kubectl create deployment my-app \
  --image=nginx:alpine \
  --replicas=2

# Expose it as a service
kubectl expose deployment my-app \
  --port=80 \
  --type=LoadBalancer

# Check the external IP
kubectl get svc my-app
```

#### Using YAML Manifests
```yaml
# Save as my-app.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 80
```

Deploy it:
```bash
kubectl apply -f my-app.yaml
```

### Method 2: Using Helm Charts

Helm is pre-installed on your cluster. You can use it to deploy complex applications:

```bash
# Add a Helm repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Deploy WordPress
helm install my-wordpress bitnami/wordpress \
  --namespace wordpress \
  --create-namespace \
  --set wordpressUsername=admin \
  --set wordpressPassword=changeme123

# Check deployment
helm list -A
kubectl get pods -n wordpress
```

### Method 3: Using ArgoCD (GitOps)

ArgoCD is pre-installed for GitOps deployments:

1. Access ArgoCD UI: https://100.118.5.204
2. Login with credentials from `/root/mynodeone-argocd-credentials.txt`
3. Create a new application pointing to your Git repository
4. ArgoCD will automatically sync and deploy your application

---

## 🔒 Security Best Practices

### Pod Security Standards

New namespaces enforce "restricted" pod security by default. Your pods must:
- Run as non-root user
- Not allow privilege escalation
- Drop all capabilities
- Use seccomp profiles

Example secure pod:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginxinc/nginx-unprivileged:alpine
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      runAsNonRoot: true
      runAsUser: 101
```

### Exempting a Namespace (if needed)

If you need to deploy legacy applications that don't meet security standards:

```bash
# Label namespace to use baseline security
kubectl label namespace my-legacy-app \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/warn=baseline \
  --overwrite
```

---

## 💾 Using Persistent Storage

### Create a PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

### Use in a Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-storage
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
```

---

## 🌐 Exposing Applications

### Option 1: LoadBalancer (Recommended)

Best for applications that need external access:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: LoadBalancer  # MetalLB will assign a Tailscale IP
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

The service will get a 100.x.x.x IP from MetalLB (accessible via Tailscale).

### Option 2: Ingress (For HTTP/HTTPS)

Use Traefik ingress for HTTP/HTTPS routing:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
  - host: myapp.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
```

### Option 3: ClusterIP (Internal Only)

For services that should only be accessible within the cluster:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-internal-service
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
  - port: 80
    targetPort: 8080
```

---

## 📊 Monitoring Your Applications

### View Logs
```bash
# Get pod logs
kubectl logs <pod-name>

# Follow logs in real-time
kubectl logs -f <pod-name>

# Logs from specific container
kubectl logs <pod-name> -c <container-name>
```

### Check Resource Usage
```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -A

# Specific namespace
kubectl top pods -n my-namespace
```

### Use Grafana Dashboards

Access Grafana at http://100.118.5.203 to view:
- CPU and memory usage per pod
- Network traffic
- Storage usage
- Application metrics (if exposed)

---

## 🗑️ Removing Applications

### Delete by Name
```bash
# Delete deployment
kubectl delete deployment my-app

# Delete service
kubectl delete service my-app

# Delete everything in a namespace
kubectl delete namespace my-namespace
```

### Using the Helper Script
```bash
# Remove one-click apps
sudo ./scripts/manage-apps.sh remove postgresql
sudo ./scripts/manage-apps.sh remove demo
```

### Delete by YAML
```bash
# Remove everything defined in a file
kubectl delete -f my-app.yaml
```

---

## 🎯 Common Use Cases

### Deploy a Web Application with Database

```bash
# 1. Deploy PostgreSQL
sudo ./scripts/manage-apps.sh deploy postgresql

# 2. Deploy your web app
kubectl create deployment my-web-app \
  --image=my-registry/my-app:latest

# 3. Set environment variables for database connection
kubectl set env deployment/my-web-app \
  DATABASE_URL=postgresql://postgres:changeme123@postgresql.databases.svc.cluster.local:5432/myapp

# 4. Expose your app
kubectl expose deployment my-web-app \
  --port=80 \
  --target-port=3000 \
  --type=LoadBalancer
```

### Deploy with Custom Configuration

```bash
# Create a ConfigMap
kubectl create configmap my-config \
  --from-file=config.yaml

# Create a Secret
kubectl create secret generic my-secrets \
  --from-literal=api-key=secret123

# Use in deployment
kubectl set volume deployment/my-app \
  --add \
  --name=config \
  --type=configmap \
  --configmap-name=my-config \
  --mount-path=/etc/config
```

### Scale Applications

```bash
# Scale up
kubectl scale deployment my-app --replicas=5

# Scale down
kubectl scale deployment my-app --replicas=1

# Autoscaling (HPA)
kubectl autoscale deployment my-app \
  --min=2 \
  --max=10 \
  --cpu-percent=80
```

---

## 🆘 Troubleshooting

### Pod Won't Start

```bash
# Check pod status
kubectl get pods

# Describe pod for events
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>

# Common issues:
# - Image pull errors: Check image name and registry access
# - Security violations: Check Pod Security Standards
# - Resource limits: Check if cluster has available resources
```

### Service Not Accessible

```bash
# Check service
kubectl get svc

# Check endpoints
kubectl get endpoints <service-name>

# Ensure pods are running
kubectl get pods -l app=<your-app>
```

### Storage Issues

```bash
# Check PVC status
kubectl get pvc

# Check PV
kubectl get pv

# Check Longhorn dashboard
# Visit: http://100.118.5.205
```

---

## 📚 Additional Resources

- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **Helm Charts**: https://artifacthub.io/
- **Longhorn Docs**: https://longhorn.io/docs/
- **ArgoCD Docs**: https://argo-cd.readthedocs.io/
- **Traefik Docs**: https://doc.traefik.io/traefik/

---

## 💡 Tips and Best Practices

1. **Use Namespaces**: Organize applications into namespaces
   ```bash
   kubectl create namespace my-project
   kubectl apply -f app.yaml -n my-project
   ```

2. **Set Resource Limits**: Always define resource requests and limits
   ```yaml
   resources:
     requests:
       memory: "256Mi"
       cpu: "250m"
     limits:
       memory: "512Mi"
       cpu: "500m"
   ```

3. **Use Labels**: Label everything for easy filtering
   ```yaml
   metadata:
     labels:
       app: my-app
       environment: production
       version: v1.0.0
   ```

4. **Health Checks**: Add liveness and readiness probes
   ```yaml
   livenessProbe:
     httpGet:
       path: /health
       port: 8080
     initialDelaySeconds: 30
     periodSeconds: 10
   ```

5. **Use GitOps**: Store your manifests in Git and use ArgoCD for deployment

6. **Monitor Everything**: Use Grafana dashboards to track application health

7. **Regular Backups**: Use MinIO or external storage for backups
   ```bash
   # Example: Backup PostgreSQL
   kubectl exec -it postgresql-0 -n databases -- \
     pg_dump -U postgres myapp > backup.sql
   ```

---

**Need Help?** Check the main documentation or run:
```bash
kubectl explain <resource-type>
# Example: kubectl explain deployment
```
