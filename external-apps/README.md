# Deploy Your App on MyNodeOne

**TL;DR:** Build a containerized app, run one command, your app is live.

```bash
cd your-app-folder/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

That's it. The script will:
1. Detect your app structure (docker-compose.yml or Kubernetes manifests)
2. Ask you for resource requirements (RAM, CPU, storage)
3. Ask you for domains (api.yourdomain.com, app.yourdomain.com, etc.)
4. Deploy everything
5. Configure DNS, SSL, routing automatically

---

## Prerequisites

- Your app is containerized (Docker images available)
- Images are in a registry (Docker Hub, GitHub Container Registry, private registry, etc.)
- You have access to a MyNodeOne cluster

---

## Quick Start

### Option 1: Deploy from docker-compose.yml

```bash
# In your app folder with docker-compose.yml
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Script will ask:
# - App name?
# - How much RAM per service?
# - How much CPU per service?
# - Storage size?
# - Domains? (api.example.com, app.example.com)
# - Make public?
```

### Option 2: Deploy from Kubernetes manifests

```bash
# In your app folder with k8s/*.yaml
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Same interactive questions
```

### Option 3: Let script generate for you

```bash
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Script will ask:
# - App name?
# - Docker images?
# - Ports?
# - Environment variables?
# - Resources?
# Then generates and deploys
```

---

## What You Get

After deployment:

✅ **Local access**: `http://myapp.mynodeone.local`  
✅ **Public access**: `https://app.yourdomain.com`, `https://api.yourdomain.com`  
✅ **SSL certificates**: Automatic (Let's Encrypt)  
✅ **DNS**: Automatic configuration  
✅ **Storage**: Persistent volumes  
✅ **Scaling**: Auto-scaling based on CPU/memory  
✅ **Monitoring**: Logs via `kubectl logs`  

---

## Examples

See `external-apps/examples/` for:
- Simple web app
- Multi-service SaaS (frontend + backend + database)
- API with database
- Microservices architecture

---

## For SaaS Developers

Your app structure:
```
your-saas-app/
├── docker-compose.yml          # Standard docker-compose
├── frontend/
│   ├── Dockerfile
│   └── ...
├── backend/
│   ├── Dockerfile
│   └── ...
└── README.md
```

Deploy:
```bash
cd your-saas-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

The script handles:
- Converting docker-compose to Kubernetes
- Setting up databases
- Configuring networking
- SSL certificates
- Domain routing
- Everything

---

## Multi-Domain Support

The script automatically handles:
```
api.yourdomain.com     → backend service
app.yourdomain.com     → frontend service
admin.yourdomain.com   → admin panel
```

Just provide the domains when asked.

---

## Zero Kubernetes Knowledge Needed

You don't need to know:
- Kubernetes concepts
- MyNodeOne architecture
- YAML syntax
- kubectl commands

Just build standard containerized apps.

---

## Documentation

- **Quick Start**: See this file
- **Detailed Guide**: `external-apps/docs/DEVELOPER-GUIDE.md`
- **Examples**: `external-apps/examples/`
- **Troubleshooting**: `external-apps/docs/TROUBLESHOOTING.md`

---

## Support

- Issues: GitHub Issues
- Questions: GitHub Discussions
- Examples: `external-apps/examples/`
