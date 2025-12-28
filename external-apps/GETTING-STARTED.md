# Getting Started with External App Deployment

This guide helps you deploy your containerized applications on MyNodeOne infrastructure.

---

## Overview

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

## Prerequisites

**Your app must have:**
1. Container images in a registry (Docker Hub, ghcr.io, etc.)
2. Standard docker-compose.yml or Kubernetes manifests
3. Service names following conventions (see DEPLOYMENT-PATTERNS.md)

**Not supported automatically:**
- `build:` directives (images must be pre-built)
- Host path volumes (use named volumes)
- Privileged containers

---

## Quick Start

### 1. Prepare Your App

**Minimal docker-compose.yml:**
```yaml
services:
  web:                        # Name indicates public service
    image: nginx:latest       # Registry image (not build:)
    ports:
      - "80:80"
```

### 2. Deploy

```bash
cd /path/to/your-app
bash ~/MyNodeOne/external-apps/scripts/deploy.sh
```

**The script will ask:**
- App name? (namespace)
- Local subdomain? (for myapp.minicloud.local)
- Make publicly accessible? (y/n)
- Public domain? (optional)

### 3. Access

**Local network:**
```bash
curl http://myapp.minicloud.local
```

**Public internet** (if configured):
```bash
# After DNS propagation
https://myapp.yourdomain.com
```

---

## Service Naming Conventions

MyNodeOne uses service names to determine which services get public IPs:

**Public services** (get LoadBalancer):
- `frontend`, `web`, `ui`, `client`
- `backend`, `api`, `server`
- `admin`, `dashboard`

**Internal services** (stay ClusterIP):
- `database`, `db`, `postgres`, `mysql`, `mongo`
- `redis`, `cache`, `memcache`
- `worker`, `queue`, `celery`

**Example:**
```yaml
services:
  web:        # → LoadBalancer (public)
  api:        # → LoadBalancer (public)
  database:   # → ClusterIP (internal only)
  redis:      # → ClusterIP (internal only)
```

---

## Inter-Service Communication

Services communicate using Kubernetes DNS:

```yaml
services:
  frontend:
    image: myapp/web:latest
    environment:
      API_URL: http://backend:8080    # Kubernetes DNS

  backend:
    image: myapp/api:latest
    environment:
      DB_HOST: database               # Kubernetes DNS
      DB_PORT: "5432"

  database:
    image: postgres:15-alpine
```

**This works automatically** - no configuration needed.

---

## Common Patterns

### Simple Web App
```yaml
services:
  web:
    image: myapp:latest
    ports:
      - "8080:80"
```

### API + Database
```yaml
services:
  api:
    image: myapp/api:latest
    environment:
      DB_HOST: database
  
  database:
    image: postgres:15-alpine
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

### Full Stack
```yaml
services:
  frontend:
    image: myapp/web:latest
    environment:
      API_URL: http://backend:8080
  
  backend:
    image: myapp/api:latest
    environment:
      DB_HOST: database
  
  database:
    image: postgres:15-alpine
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

---

## Troubleshooting

### Build Directives Not Supported

**Problem:**
```yaml
services:
  app:
    build: ./app    # ❌ Kompose can't build
```

**Solution:**
```bash
# Build and push manually
docker build -t myregistry.com/app:latest ./app
docker push myregistry.com/app:latest

# Update docker-compose.yml
services:
  app:
    image: myregistry.com/app:latest    # ✅
```

### Service Not Getting Public IP

**Problem:** Service stays ClusterIP instead of LoadBalancer.

**Solution:** Check service name matches conventions:
```yaml
# Before
services:
  myapp:    # ❌ Doesn't match pattern

# After
services:
  web:      # ✅ Matches 'frontend' pattern
```

### Database Mount Issues

**Problem:** PostgreSQL crashes with "directory exists but is not empty"

**Solution:** Use PGDATA subdirectory:
```yaml
services:
  database:
    image: postgres:15-alpine
    environment:
      PGDATA: /var/lib/postgresql/data/pgdata    # ✅
    volumes:
      - db-data:/var/lib/postgresql/data
```

---

## Next Steps

**Read the documentation:**
- `DEPLOYMENT-PATTERNS.md` - Service detection patterns and conventions
- `LIMITATIONS.md` - Known limitations and workarounds
- `MULTI-DOMAIN-ARCHITECTURE.md` - How multi-domain routing works
- `DOMAIN-SSL-WORKFLOW.md` - Public domain and SSL setup

**Example deployments:**
- Look at `scripts/apps/immich/install-immich.sh`
- Look at `scripts/apps/jellyfin/install-jellyfin.sh`

**Get help:**
- Check pod status: `kubectl get pods -n <namespace>`
- View logs: `kubectl logs -n <namespace> <pod-name>`
- Describe pod: `kubectl describe pod -n <namespace> <pod-name>`

---

## Making Your App "MyNodeOne-Ready"

For app developers wanting to ensure compatibility:

1. **Use registry images** (not `build:` directives)
2. **Name services clearly:**
   - Public: `frontend`, `web`, `api`, `backend`
   - Internal: `database`, `cache`, `worker`
3. **Use environment variables** for configuration
4. **Use named volumes** (not host paths)
5. **Document in README:**
   ```markdown
   ## Deploy on MyNodeOne
   bash ~/MyNodeOne/external-apps/scripts/deploy.sh
   ```

---

## Current Limitations

This is an initial release. The deployment system:

✅ **Works automatically for:**
- Standard docker-compose apps with registry images
- Service type detection via naming conventions
- LoadBalancer assignment via MetalLB
- Local DNS registration
- Public domain + SSL (manual DNS configuration required)

⚠️ **Requires manual fixes for:**
- Apps with `build:` directives
- Database-specific volume mount issues
- Non-standard service names
- PodSecurity violations

📋 **Future enhancements planned:**
- LLM-assisted conversion tool
- Explicit label-based configuration
- Better error messages with specific fixes
- Automatic issue detection and suggestions

---

## Contributing

Found an issue or have a suggestion? Please create a GitHub issue.

**This deployment system is a starting point** - we'll make it more robust based on real-world usage and feedback.
