# Developer Guide: Deploy Apps on MyNodeOne

**For developers who just want to deploy their containerized apps.**

You don't need to know Kubernetes, MyNodeOne architecture, or any infrastructure details. Just build your app, run one script.

---

## TL;DR

```bash
# In your app folder
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Answer some questions (RAM, CPU, domains), done.

---

## What You Need

### Before You Start

1. **Your app is containerized**
   - You have Docker images built
   - Images are pushed to a registry (Docker Hub, GitHub, private registry)

2. **Standard app structure** (one of these):
   - `docker-compose.yml` (preferred)
   - Kubernetes manifests in `k8s/` folder
   - Just a Dockerfile (script will help)

3. **Access to MyNodeOne**
   - Either run from the control plane, or
   - Have `kubectl` configured to access the cluster

That's it. No Kubernetes knowledge needed.

---

## Deployment Patterns

### Pattern 1: I Have docker-compose.yml (Easiest)

Your app structure:
```
my-saas-app/
├── docker-compose.yml
├── frontend/
│   ├── Dockerfile
│   └── ...
├── backend/
│   ├── Dockerfile
│   └── ...
└── database/
    └── (optional)
```

Deploy:
```bash
cd my-saas-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

The script will:
- Read your docker-compose.yml
- Ask for resource requirements (RAM, CPU)
- Ask for domains (api.example.com, app.example.com)
- Convert to Kubernetes
- Deploy everything
- Configure DNS and routing

### Pattern 2: I Have a Dockerfile

Your app:
```
my-app/
├── Dockerfile
├── src/
└── ...
```

Deploy:
```bash
cd my-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Script will ask:
- Docker image name/tag
- Port your app listens on
- RAM and CPU requirements
- Domains
Then deploys.

### Pattern 3: I Have Nothing (Script Generates)

Just run:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Script will ask everything:
- App name
- How many services (frontend, backend, etc.)
- Docker images for each
- Ports
- Resources
- Domains

Then generates everything and deploys.

---

## Multi-Service Apps (Microservices)

### Example: SaaS with Frontend + Backend + Database

Your `docker-compose.yml`:
```yaml
version: '3'
services:
  frontend:
    image: myregistry/myapp-frontend:latest
    ports:
      - "3000:3000"
    environment:
      - API_URL=http://backend:8000

  backend:
    image: myregistry/myapp-backend:latest
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=postgresql://db:5432/myapp

  database:
    image: postgres:16
    environment:
      - POSTGRES_DB=myapp
      - POSTGRES_PASSWORD=changeme
```

Deploy:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Script will detect all services and deploy them.

### Multiple Domains

The script asks for domains. Provide multiple:
```
Domains: app.example.com,api.example.com,admin.example.com
```

Script will:
- `app.example.com` → frontend service
- `api.example.com` → backend service
- `admin.example.com` → admin service

All with SSL certificates automatically.

---

## Resource Configuration

### Interactive Prompts

When you run the script, it asks:

```
? Memory per service?
  Examples: 256Mi, 512Mi, 1Gi, 2Gi
Memory [512Mi]: 1Gi

? CPU per service?
  Examples: 100m (0.1 core), 500m (0.5 core), 1000m (1 core)
CPU [500m]: 1000m

? Storage size (or 'none') [10Gi]: 50Gi
```

### Guidelines

**Small apps** (blog, personal site):
- RAM: 256Mi
- CPU: 100m
- Storage: 5Gi

**Medium apps** (small SaaS, API):
- RAM: 512Mi-1Gi
- CPU: 500m-1000m
- Storage: 20Gi

**Large apps** (production SaaS):
- RAM: 2Gi-4Gi
- CPU: 2000m-4000m
- Storage: 100Gi+

---

## Domains and Public Access

### Local Access (Automatic)

Every app gets:
```
http://myapp.mynodeone.local
```

Works on all devices connected to your MyNodeOne network.

### Public Access (Optional)

Script asks:
```
? Do you want public internet access? [y/N]: y

? Enter public domains (comma-separated)
  Examples:
  • app.yourdomain.com
  • app.yourdomain.com,api.yourdomain.com
Domains: app.example.com,api.example.com
```

After deployment, you need to:

1. **Add DNS A records** at your domain registrar:
   ```
   app.example.com    A    <VPS_IP>
   api.example.com    A    <VPS_IP>
   ```

2. **Complete setup** (one command):
   ```bash
   sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
   ```

Then access at:
```
https://app.example.com
https://api.example.com
```

SSL certificates are automatic.

---

## What Happens During Deployment

### Behind the Scenes (You Don't Need to Know)

1. Script converts your app to Kubernetes manifests
2. Creates isolated namespace for your app
3. Deploys all services
4. Assigns IP address via LoadBalancer
5. Configures persistent storage (if requested)
6. Registers with service registry
7. Updates DNS on all cluster nodes
8. Configures routing for public domains (if requested)
9. Sets up auto-scaling
10. Obtains SSL certificates

All automatic. You just provide the inputs.

---

## Managing Your App

### View Status

```bash
# Check if running
kubectl get pods -n myapp

# View logs
kubectl logs -n myapp -l app=myapp -f

# Check services
kubectl get svc -n myapp
```

### Update Your App

```bash
# Build new version
docker build -t myregistry/myapp:v2 .
docker push myregistry/myapp:v2

# Update deployment
kubectl set image deployment/myapp-frontend \
  myapp-frontend=myregistry/myapp:v2 -n myapp
```

### Scale Your App

```bash
# Scale to 5 replicas
kubectl scale deployment -n myapp --replicas=5 --all

# Auto-scaling is already configured
# App scales automatically based on CPU/memory
```

### Restart

```bash
kubectl rollout restart deployment -n myapp --all
```

### Delete/Undeploy

```bash
# Delete entire app
kubectl delete namespace myapp

# Or use undeploy script
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh myapp
```

---

## Examples

### Example 1: Simple Node.js App

```bash
# Your app structure
my-nodejs-app/
├── Dockerfile
├── package.json
└── src/

# Deploy
cd my-nodejs-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Answer questions:
# - App name: mynodeapp
# - Services: 1
# - Image: myregistry/mynodeapp:latest
# - Port: 3000
# - Memory: 512Mi
# - CPU: 500m
# - Storage: none
# - Subdomain: mynodeapp
# - Public: n

# Access: http://mynodeapp.mynodeone.local
```

### Example 2: Full-Stack SaaS

```yaml
# docker-compose.yml
version: '3'
services:
  frontend:
    image: myregistry/saas-frontend:latest
    ports: ["80:80"]
  
  backend:
    image: myregistry/saas-backend:latest
    ports: ["8000:8000"]
  
  database:
    image: postgres:16
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

```bash
# Deploy
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Answer questions:
# - Memory: 1Gi
# - CPU: 1000m
# - Storage: 50Gi
# - Subdomain: mysaas
# - Public: y
# - Domains: app.mysaas.com,api.mysaas.com

# Then:
# 1. Add DNS records
# 2. Run: sudo manage-app-visibility.sh

# Access:
# - https://app.mysaas.com
# - https://api.mysaas.com
```

### Example 3: Python FastAPI

```bash
# Your app
my-api/
├── Dockerfile
├── requirements.txt
└── main.py

# Deploy
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Questions:
# - App name: myapi
# - Services: 1
# - Image: myregistry/myapi:latest
# - Port: 8000
# - Memory: 512Mi
# - CPU: 500m
# - Public: y
# - Domains: api.example.com

# Access: https://api.example.com
```

---

## Troubleshooting

### App Not Starting

```bash
# Check pod status
kubectl get pods -n myapp

# Check logs
kubectl logs -n myapp -l app=myapp -f

# Describe pod (for errors)
kubectl describe pod -n myapp <pod-name>
```

Common issues:
- **ImagePullBackOff**: Docker image not found or registry credentials missing
- **CrashLoopBackOff**: App crashing on startup (check logs)
- **Pending**: Not enough resources (check resource requests)

### Can't Access App

```bash
# Check service has IP
kubectl get svc -n myapp

# Check DNS registration
kubectl get configmap -n kube-system service-registry -o yaml

# Update DNS manually
sudo bash /path/to/MyNodeOne/scripts/sync-dns.sh
```

### Public Domain Not Working

1. Check DNS propagation: `dig app.example.com`
2. Check VPS routing: `sudo manage-app-visibility.sh`
3. Check SSL certificate: `kubectl get certificate -A`

---

## Best Practices

### 1. Use Version Tags

❌ Bad:
```yaml
image: myregistry/myapp:latest
```

✅ Good:
```yaml
image: myregistry/myapp:v1.2.3
```

### 2. Set Resource Limits

Always specify RAM and CPU when prompted. This prevents one app from consuming all cluster resources.

### 3. Use Environment Variables

For configuration:
```yaml
environment:
  - DATABASE_URL=postgresql://...
  - API_KEY=${API_KEY}
```

### 4. Use Persistent Storage

For databases and user data:
```
Storage size: 50Gi  (not 'none')
```

### 5. Test Locally First

Before deploying:
```bash
# Test with docker-compose locally
docker-compose up

# Ensure images are pushed
docker push myregistry/myapp:v1
```

---

## CI/CD Integration

### GitHub Actions

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
      
      - name: Build and push
        run: |
          docker build -t myregistry/myapp:${{ github.sha }} .
          docker push myregistry/myapp:${{ github.sha }}
      
      - name: Deploy
        env:
          KUBECONFIG: ${{ secrets.KUBECONFIG }}
        run: |
          kubectl set image deployment/myapp \
            myapp=myregistry/myapp:${{ github.sha }} -n myapp
```

### GitLab CI

```yaml
deploy:
  stage: deploy
  script:
    - kubectl set image deployment/myapp myapp=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA -n myapp
  only:
    - main
```

---

## FAQ

**Q: Do I need to learn Kubernetes?**  
A: No. The script handles everything.

**Q: Can I use my existing docker-compose.yml?**  
A: Yes. That's the preferred method.

**Q: How much does this cost?**  
A: Just your infrastructure costs. MyNodeOne is open source and free.

**Q: Can I deploy multiple apps?**  
A: Yes. Each app gets its own namespace. Deploy unlimited apps.

**Q: What if my app has 5+ services?**  
A: Works fine. The script handles any number of services.

**Q: Can I customize the Kubernetes manifests?**  
A: Yes. After deployment, you can `kubectl edit` or regenerate with custom settings.

**Q: How do I add environment variables?**  
A: Via docker-compose.yml or kubectl after deployment.

**Q: Is my data safe?**  
A: Yes. Uses Longhorn storage with automatic replication and snapshots.

---

## Getting Help

- **Quick issues**: Check logs with `kubectl logs -n myapp -l app=myapp -f`
- **Examples**: See `external-apps/examples/`
- **Detailed troubleshooting**: See `external-apps/docs/TROUBLESHOOTING.md`
- **Community**: GitHub Discussions
- **Bugs**: GitHub Issues

---

## Summary

1. Build your containerized app (standard Docker setup)
2. Run: `bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh`
3. Answer questions about resources and domains
4. Your app is live

That's it. No infrastructure knowledge needed.
