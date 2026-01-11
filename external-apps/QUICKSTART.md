# External App Quick Start

Deploy your own apps on MyNodeOne in 3 steps.

## TL;DR

```bash
# Option 1: Use template generator
cd /path/to/MyNodeOne
bash scripts/new-external-app.sh --name myapp --type fullstack --database
cd ../external-apps/myapp
bash scripts/deploy.sh

# Option 2: Deploy existing manifests
kubectl apply -f your-app.yaml
bash /path/to/MyNodeOne/scripts/lib/register-external-app.sh \
  --name myapp --subdomain myapp --namespace myapp --service myapp

# Access: http://myapp.mynodeone.local
```

## When to Use External Apps

✅ **Use external apps when:**
- Building a SaaS product you want to keep private
- Custom business applications specific to your needs
- You're a developer using MyNodeOne as infrastructure
- You want separate Git repos for different projects
- You need to share code with customers/partners

❌ **Use MyNodeOne built-in apps when:**
- Adding a popular self-hosted app everyone uses (Nextcloud, Jellyfin, etc.)
- Contributing to the MyNodeOne project
- Creating example/demo apps

## 3 Deployment Patterns

### Pattern 1: Template Generator (Fastest)

```bash
# Generate scaffolded app
bash /path/to/MyNodeOne/scripts/new-external-app.sh \
  --name mysaas \
  --type fullstack \
  --database \
  --redis

# Customize and deploy
cd ../external-apps/mysaas
# Edit kubernetes/ manifests
# Update Docker images
bash scripts/deploy.sh
```

**Best for:** New projects, rapid prototyping

### Pattern 2: Kubernetes-Native (Most Flexible)

```yaml
# your-app.yaml
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

```bash
kubectl apply -f your-app.yaml
```

**Best for:** Existing Kubernetes apps, CI/CD pipelines

### Pattern 3: Manual Integration

```bash
# Deploy however you want
kubectl apply -f myapp/

# Register manually
bash /path/to/MyNodeOne/scripts/lib/register-external-app.sh \
  --name myapp \
  --subdomain myapp \
  --namespace myapp \
  --service myapp-web \
  --port 80
```

**Best for:** Complex apps, custom workflows

## What You Get from MyNodeOne

| Feature | Description | Auto-Configured |
|---------|-------------|-----------------|
| **DNS** | `myapp.mynodeone.local` | ✅ |
| **LoadBalancer** | MetalLB assigns IPs | ✅ |
| **Storage** | Longhorn persistent volumes | Use `storageClassName: longhorn` |
| **Public Routing** | VPS edge nodes | Run `manage-app-visibility.sh` |
| **SSL** | Let's Encrypt certificates | ✅ (when public) |
| **Monitoring** | Logs via kubectl | ✅ |

## Making Apps Public

```bash
# Interactive setup
sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh

# Manual
bash /path/to/MyNodeOne/scripts/lib/multi-domain-registry.sh \
  configure-routing myapp yourdomain.com vps-ip round-robin
```

Then add DNS record:
```
Type: A
Name: myapp (or *)
Value: <VPS_PUBLIC_IP>
```

Access at: `https://myapp.yourdomain.com`

## Directory Structure

### Recommended Layout

```
your-projects/
├── MyNodeOne/                    # Infrastructure repo
│   └── scripts/
│       ├── new-external-app.sh
│       └── lib/
│           └── register-external-app.sh
│
└── external-apps/                # Your apps
    ├── saas-app-1/
    │   ├── kubernetes/
    │   ├── scripts/deploy.sh
    │   ├── src/
    │   └── .mynodeone/config.yaml
    │
    └── saas-app-2/
        ├── kubernetes/
        └── ...
```

### Each App Structure

```
myapp/
├── kubernetes/           # K8s manifests
│   ├── 00-namespace.yaml
│   ├── 10-database.yaml
│   ├── 20-app.yaml
│   └── 30-service.yaml
├── scripts/
│   └── deploy.sh        # Deployment automation
├── src/                 # Your code
├── .mynodeone/
│   └── config.yaml      # MyNodeOne integration
├── Dockerfile
└── README.md
```

## Common Workflows

### Initial Deployment

```bash
# Generate template
bash /path/to/MyNodeOne/scripts/new-external-app.sh --name myapp

# Customize
cd ../external-apps/myapp
# Edit kubernetes/ manifests
# Build your app: docker build -t registry/myapp:v1 .
# Push: docker push registry/myapp:v1
# Update image in kubernetes/20-app.yaml

# Deploy
bash scripts/deploy.sh
```

### Update Existing App

```bash
# Build new version
docker build -t registry/myapp:v2 .
docker push registry/myapp:v2

# Rolling update
kubectl set image deployment/myapp \
  myapp=registry/myapp:v2 -n myapp

# Or redeploy
kubectl apply -f kubernetes/
```

### Check Status

```bash
# Pods
kubectl get pods -n myapp

# Services
kubectl get svc -n myapp

# Logs
kubectl logs -n myapp -l app=myapp -f

# Events
kubectl get events -n myapp --sort-by='.lastTimestamp'
```

### Troubleshooting

```bash
# No LoadBalancer IP?
kubectl get svc -n myapp
kubectl get pods -n metallb-system

# DNS not working?
kubectl get configmap -n kube-system service-registry -o yaml
sudo bash /path/to/MyNodeOne/scripts/sync-dns.sh

# App not accessible?
kubectl describe svc -n myapp myapp
curl http://$(kubectl get svc -n myapp myapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

## Examples

### Simple Web App

```bash
# Use the example
kubectl apply -f /path/to/MyNodeOne/manifests/examples/external-app-simple.yaml

# Access
curl http://$(kubectl get svc -n myexternalapp myexternalapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
```

### Full-Stack SaaS

```bash
# Generate with all features
bash /path/to/MyNodeOne/scripts/new-external-app.sh \
  --name mysaas \
  --type fullstack \
  --database \
  --redis

# This creates:
# - Frontend deployment
# - Backend API
# - PostgreSQL database
# - Redis cache
# - Auto-scaling
# - Health checks
```

### Python FastAPI

```bash
bash /path/to/MyNodeOne/scripts/new-external-app.sh \
  --name myapi \
  --type api \
  --database
```

## CI/CD Integration

### GitHub Actions

```yaml
# .github/workflows/deploy.yml
name: Deploy
on: [push]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: docker build -t registry/myapp:${{ github.sha }} .
      - run: docker push registry/myapp:${{ github.sha }}
      - uses: azure/k8s-set-context@v3
        with:
          kubeconfig: ${{ secrets.KUBECONFIG }}
      - run: |
          kubectl set image deployment/myapp \
            myapp=registry/myapp:${{ github.sha }} -n myapp
```

## Best Practices

1. **Use namespaces** - One namespace per app
2. **Set resource limits** - Prevent resource exhaustion
3. **Add health checks** - Liveness and readiness probes
4. **Use secrets** - Never hardcode passwords
5. **Tag images** - Use semantic versioning
6. **Enable autoscaling** - Handle traffic spikes
7. **Monitor logs** - `kubectl logs` is your friend

## Full Documentation

See `docs/guides/EXTERNAL-APP-DEPLOYMENT.md` for complete guide.

## Support

- **Issues**: GitHub Issues
- **Examples**: `manifests/examples/`
- **Community**: GitHub Discussions
