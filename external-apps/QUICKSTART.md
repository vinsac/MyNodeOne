# External App Quick Start

Deploy your own apps on MyNodeOne in 3 steps.

---

## 🎯 Overview

MyNodeOne allows you to deploy any containerized application using:
- **Standard docker-compose.yml** files
- **Kubernetes manifests**  
- **Simple naming conventions** (no MyNodeOne-specific config required)

The deployment script automatically:
- ✅ Detects service types (public vs internal)
- ✅ Assigns external IPs via MetalLB
- ✅ Registers local DNS
- ✅ Configures optional public domains + SSL

---

## 📋 Prerequisites

**Your app must have:**
1. Container images in a registry (Docker Hub, ghcr.io, etc.)
2. Standard docker-compose.yml or Kubernetes manifests
3. Service names following conventions (see [DEPLOYMENT-PATTERNS.md](DEPLOYMENT-PATTERNS.md))

**Not supported automatically:**
- `build:` directives (images must be pre-built)
- Host path volumes (use named volumes)
- Privileged containers

---

## 🚀 Quick Start

### TL;DR

```bash
# Option 1: Use template generator
bash /path/to/MyNodeOne/external-apps/scripts/generate-template.sh --name myapp --type fullstack --database
cd myapp
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Option 2: Deploy existing manifests
kubectl apply -f your-app.yaml
bash /path/to/MyNodeOne/external-apps/scripts/register-app.sh \
  --name myapp --subdomain myapp --namespace myapp --service myapp

# Access: http://myapp.mynodeone.local
```

### 1. Prepare Your App

**Minimal docker-compose.yml:**
```yaml
services:
  web:                        # Name indicates public service
    image: nginx:latest       # Registry image (not build:)
    ports:
      - "80:80"
```

**Full SaaS example:**
```yaml
services:
  frontend:                  # Public - gets app.domain.com
    image: your-registry/frontend:latest
    ports:
      - "80:80"
  
  backend:                   # Public - gets api.domain.com
    image: your-registry/backend:latest
    environment:
      - DATABASE_URL=postgresql://postgres:pass@database:5432
  
  database:                  # Internal - no public domain
    image: postgres:15
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:
```

### 2. Deploy

```bash
cd your-app-folder/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

**Script will ask:**
- App name?
- How much RAM per service? (default: 512Mi)
- How much CPU per service? (default: 500m)
- Storage size? (default: 10Gi)
- Domains? (api.example.com, app.example.com)
- Make public? (y/n)

### 3. Access Your App

- **Local**: `http://myapp.mynodeone.local` (automatic)
- **Public**: `https://app.example.com` (after DNS setup)

---

## 🎯 When to Use External Apps

✅ **Use external apps when:**
- Building a SaaS product you want to keep private
- Custom business applications specific to your needs
- You're a developer using MyNodeOne as infrastructure
- You want separate Git repos for different projects
- You need to share code with customers/partners

❌ **Use built-in apps when:**
- You want one-click installation
- You prefer pre-configured applications
- You need community-supported apps
- You want automatic updates and maintenance

---

## 📝 Service Naming Conventions

The deployment script automatically detects service types:

| Service Name Pattern | Detected Type | Public Domain | Convention |
|---------------------|---------------|---------------|------------|
| frontend, web, app, ui, client | `frontend` | ✓ | `app.domain.com` |
| backend, api, server | `backend` | ✓ | `api.domain.com` |
| admin, dashboard | `admin` | ✓ | `admin.domain.com` |
| db, database, postgres, mysql, mongo | `database` | ✗ | Internal only |
| redis, cache, memcache | `cache` | ✗ | Internal only |
| worker, queue, celery | `worker` | ✗ | Internal only |

---

## 🛠️ Advanced Options

### Template Generator

Create a new app template:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/generate-template.sh \
  --name myapp --type fullstack --database
```

### Register Existing App

For apps already deployed with `kubectl`:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/register-app.sh \
  --name myapp --subdomain myapp --namespace myapp --service myapp-web
```

### Remove App

Clean up deployed app:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh myapp
```

---

## 📚 Next Steps

**Read the documentation:**
- `DEPLOYMENT-PATTERNS.md` - Service detection patterns and conventions
- `LIMITATIONS.md` - Known limitations and workarounds
- `MULTI-DOMAIN-ARCHITECTURE.md` - How multi-domain routing works
- `DOMAIN-SSL-WORKFLOW.md` - Public domain and SSL setup

**Try the examples:**
```bash
cd external-apps/examples/simple-web-app/
bash ../../scripts/deploy.sh
```
