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

## 📁 Complete Directory Structure

```
external-apps/
├── README.md                    ← This file (start here)
├── scripts/
│   ├── deploy.sh               ← Main deployment script
│   ├── undeploy.sh             ← Remove apps
│   ├── register-app.sh         ← Register existing apps
│   └── generate-template.sh     ← Create app templates
├── docs/
│   ├── DEVELOPER-GUIDE.md      ← Complete developer guide
│   ├── DETAILED-GUIDE.md       ← In-depth technical guide
│   └── TROUBLESHOOTING.md      ← Fix common issues
├── examples/
│   ├── simple-web-app/         ← Static site example
│   └── saas-fullstack/         ← Full SaaS example
├── templates/
│   └── simple-web-app.yaml     ← Kubernetes template
└── guides/
    ├── DEPLOYMENT-PATTERNS.md   ← Service detection patterns
    ├── DOMAIN-SSL-WORKFLOW.md   ← Public domain setup
    └── LIMITATIONS.md           ← Known limitations
```

---

## 🚀 Three-Step Process

### 1. Prepare Your App

**Option A: You have docker-compose.yml** (easiest)
```yaml
# docker-compose.yml
version: '3'
services:
  web:
    image: your-registry/myapp:latest
    ports:
      - "80:80"
```

**Option B: You have Dockerfile**
```dockerfile
FROM node:20-alpine
COPY . /app
CMD ["node", "server.js"]
```

**Option C: You have nothing**
The script will help you create everything interactively.

### 2. Deploy

```bash
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Script asks:
- **Resources**: RAM (512Mi), CPU (500m), Storage (10Gi)
- **Domains**: Local (myapp.mynodeone.local) and/or public (app.example.com)

### 3. Access

- **Local**: `http://myapp.mynodeone.local` (automatic)
- **Public**: `https://app.example.com` (after DNS setup)

---

## 👥 For Different User Types

### 🏢 I'm a SaaS Developer

- Build your app as usual (React + Node.js + PostgreSQL)
- Create standard `docker-compose.yml`
- Run `deploy.sh`
- Get: Local DNS, Public routing, SSL, Auto-scaling
- **No Kubernetes knowledge needed**

**See**: `examples/saas-fullstack/`

### 🔄 I Have an Existing App

```bash
# If already deployed with kubectl
bash /path/to/MyNodeOne/external-apps/scripts/register-app.sh \
  --name myapp --subdomain myapp --namespace myapp --service myapp-web

# If deploying new
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

### 🎯 I Want to Try It Out

```bash
# Try the example
cd external-apps/examples/simple-web-app/
bash ../../scripts/deploy.sh

# Access: http://simple-web-app.mynodeone.local
```

---

## 🎯 What You Get

After deployment:

✅ **Local access**: `http://myapp.mynodeone.local`  
✅ **Public access**: `https://app.yourdomain.com`, `https://api.yourdomain.com`  
✅ **SSL certificates**: Automatic (Let's Encrypt)  
✅ **DNS**: Automatic configuration  
✅ **Storage**: Persistent volumes  
✅ **Scaling**: Auto-scaling based on CPU/memory  
✅ **Monitoring**: Logs via `kubectl logs`  
✅ **Multi-domain**: Intelligent service-to-domain mapping  

---

## 🧠 Intelligent Domain Mapping

The script automatically maps services to conventional domains:

### Auto-Detect Mode (Recommended)
```
? Base domain: myapp.com

✓ Auto-configured:
  • https://app.myapp.com    → frontend service
  • https://api.myapp.com    → backend service  
  • https://admin.myapp.com  → admin service
```

### Service Types Detected
- **frontend/web/app** → `app.domain.com`
- **backend/api/server** → `api.domain.com`
- **admin/dashboard** → `admin.domain.com`
- **database/redis** → Internal only (no public domain)

---

## 📚 Documentation

- **Quick Start**: This file
- **Complete Guide**: `docs/DEVELOPER-GUIDE.md`
- **Examples**: `examples/`
- **Troubleshooting**: `docs/TROUBLESHOOTING.md`
- **Deployment Patterns**: `DEPLOYMENT-PATTERNS.md`
- **Domain Setup**: `DOMAIN-SSL-WORKFLOW.md`

---

## Prerequisites

- Your app is containerized (Docker images available)
- Images are in a registry (Docker Hub, GitHub Container Registry, private registry, etc.)
- You have access to a MyNodeOne cluster

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

## Support

- Issues: GitHub Issues
- Questions: GitHub Discussions
- Examples: `external-apps/examples/`
