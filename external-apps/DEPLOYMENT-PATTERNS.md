# MyNodeOne External App Deployment Patterns

This document explains how MyNodeOne automatically detects and configures containerized applications.

---

## What "Out-of-the-Box" Means

**Definition:** An app works out-of-the-box if:
1. **Images are available** in a registry (Docker Hub, ghcr.io, etc.) - no `build:` directives
2. **Service names follow conventions** - so we can detect which to expose publicly
3. **Standard Kubernetes patterns** - volumes, environment variables work normally

**Example apps that work out-of-the-box:**
```yaml
# docker-compose.yml
services:
  frontend:                          # ✅ Named 'frontend' → auto-detected as public
    image: myapp/web:latest          # ✅ Registry image (not build:)
    ports:
      - "3000:80"
    
  backend:                           # ✅ Named 'backend' → auto-detected as public
    image: myapp/api:latest          # ✅ Registry image
    ports:
      - "8080:8080"
    
  database:                          # ✅ Named 'database' → auto-detected as internal
    image: postgres:15-alpine        # ✅ Registry image
    environment:
      POSTGRES_PASSWORD: secret
    volumes:
      - db-data:/var/lib/postgresql/data
```

**What happens automatically:**
1. Kompose converts docker-compose.yml → Kubernetes manifests
2. MyNodeOne detects service types by name
3. `frontend` and `backend` → converted to LoadBalancer (get MetalLB IPs)
4. `database` → stays ClusterIP (internal only)
5. MetalLB assigns IPs: `frontend=100.72.41.214`, `backend=100.72.41.215`
6. Services registered in local DNS: `myapp.mynodeone.local`
7. Optional: Public domains configured (if user wants)

---

## Service Detection Logic

MyNodeOne uses **naming conventions** to classify services:

### Public-Facing Services (Get LoadBalancer + Public Exposure)

| Pattern | Service Type | Examples | Public Exposure |
|---------|--------------|----------|-----------------|
| `frontend`, `web`, `ui`, `client` | Frontend | User-facing web app | ✅ Yes |
| `backend`, `api`, `server` | Backend | API endpoints | ✅ Yes |
| `admin`, `dashboard` | Admin | Admin panel | ✅ Yes |

**What happens:**
- Service type changed: `ClusterIP` → `LoadBalancer`
- MetalLB assigns external IP from pool
- Registered in local DNS: `<subdomain>.mynodeone.local`
- Optionally exposed publicly: `<subdomain>.<yourdomain.com>`

### Internal Services (Stay ClusterIP)

| Pattern | Service Type | Examples | Public Exposure |
|---------|--------------|----------|-----------------|
| `db`, `database`, `postgres`, `mysql`, `mongo` | Database | Data storage | ❌ No |
| `redis`, `cache`, `memcache` | Cache | Caching layer | ❌ No |
| `worker`, `queue`, `celery` | Worker | Background jobs | ❌ No |
| Anything else | Internal | Other services | ❌ No |

**What happens:**
- Service type stays: `ClusterIP`
- Only accessible within cluster
- Other pods can reach via: `servicename.namespace.svc.cluster.local`

---

## Example: Real-World App

**Immich** (photo management app):

```yaml
services:
  immich-server:          # → Detected as 'internal' (needs explicit config)
    image: ghcr.io/immich-app/immich-server:latest
    
  immich-web:             # → Detected as 'frontend' ✅
    image: ghcr.io/immich-app/immich-web:latest
    
  immich-machine-learning:  # → Detected as 'internal'
    image: ghcr.io/immich-app/immich-machine-learning:latest
    
  redis:                  # → Detected as 'cache' (internal)
    image: redis:6.2-alpine
    
  database:               # → Detected as 'database' (internal)
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
```

**Result:**
- ✅ `immich-web` gets LoadBalancer IP
- ❌ `immich-server` stays internal (needs manual fix if it should be public)

**Fix:** Rename to match pattern or manually change service type.

---

## How Inter-Service Communication Works

### Inside the Cluster (Always Works)

Services talk to each other using Kubernetes DNS:

```yaml
# Frontend connects to backend
services:
  frontend:
    image: myapp/web:latest
    environment:
      API_URL: http://backend:8080    # ✅ Kubernetes DNS resolution
      
  backend:
    image: myapp/api:latest
    ports:
      - "8080:8080"
```

**How it works:**
1. Frontend pod looks up `backend` via DNS
2. Kubernetes resolves: `backend` → `backend.myapp.svc.cluster.local` → `10.43.x.x` (ClusterIP)
3. Traffic routes internally (fast, secure)

**This works regardless of LoadBalancer/ClusterIP type!**

### From Outside the Cluster

Only **LoadBalancer** services are accessible externally:

```
User → http://myapp.mynodeone.local (100.72.41.214) → MetalLB → frontend pod
```

Internal services (`database`, `cache`, etc.) are **never** exposed externally.

---

## Configuration Methods

### Method 1: Naming Conventions (Automatic)

**Best for:** Most apps, quick deployments

```yaml
services:
  web:        # ✅ Auto-detected as frontend
    image: myapp/web:latest
    
  api:        # ✅ Auto-detected as backend
    image: myapp/api:latest
    
  postgres:   # ✅ Auto-detected as database (internal)
    image: postgres:15
```

### Method 2: Explicit Labels (Future)

**Best for:** Complex apps, custom configurations

```yaml
services:
  myservice:
    image: myapp/service:latest
    labels:
      mynodeone.expose: "true"           # Override detection
      mynodeone.service-type: "frontend" # Explicit type
      mynodeone.public-domain: "app.example.com"
```

**Status:** Not yet implemented, but this is the future direction.

### Method 3: Manual Override

**Best for:** One-off fixes, testing

After `deploy.sh` generates manifests:

```bash
# Edit generated manifests
vi /tmp/mynodeone-deploy-*/myservice-service.yaml

# Change type manually
spec:
  type: LoadBalancer  # Was: ClusterIP
  
# Deploy
kubectl apply -f /tmp/mynodeone-deploy-*/
```

---

## Expected Config Format

### Minimum Requirements

**For automatic deployment to work:**

```yaml
# docker-compose.yml
services:
  frontend:                    # 1. Service name follows convention
    image: registry/app:tag    # 2. Registry image (not build:)
    ports:
      - "3000:80"              # 3. Port mapping (optional)
    environment:               # 4. Environment variables (optional)
      KEY: value
```

**That's it!** This will:
- ✅ Convert to Kubernetes manifests
- ✅ Detect service type (frontend)
- ✅ Convert to LoadBalancer
- ✅ Get MetalLB IP
- ✅ Register local DNS

### Optional Enhancements

```yaml
services:
  frontend:
    image: registry/app:tag
    ports:
      - "3000:80"
    environment:
      KEY: value
    volumes:                         # Persistent storage
      - app-data:/data
    healthcheck:                     # Health monitoring
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
    deploy:                          # Resource limits
      resources:
        limits:
          memory: 512M
          cpus: '0.5'

volumes:
  app-data:                          # Named volume (becomes PVC)
```

---

## Common Patterns by App Type

### Simple Web App

```yaml
services:
  web:
    image: myapp/web:latest
    ports:
      - "8080:80"
```

**Works immediately!** Single service exposed via LoadBalancer.

### API + Database

```yaml
services:
  api:                        # Public (LoadBalancer)
    image: myapp/api:latest
    environment:
      DB_HOST: database       # Connects via Kubernetes DNS
      DB_PORT: "5432"
    
  database:                   # Internal (ClusterIP)
    image: postgres:15-alpine
    environment:
      POSTGRES_PASSWORD: secret
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

**Works immediately!** API exposed publicly, database internal, they communicate via DNS.

### Full Stack (Frontend + Backend + Database)

```yaml
services:
  frontend:                   # Public (LoadBalancer)
    image: myapp/web:latest
    environment:
      API_URL: http://backend:8080    # Internal DNS
    
  backend:                    # Public (LoadBalancer)
    image: myapp/api:latest
    environment:
      DB_HOST: database
    
  database:                   # Internal (ClusterIP)
    image: postgres:15-alpine
    volumes:
      - db-data:/var/lib/postgresql/data

volumes:
  db-data:
```

**Works immediately!** Frontend and backend get public IPs, database stays internal.

---

## What Doesn't Work Out-of-the-Box

### 1. Build Directives

```yaml
services:
  app:
    build: ./app    # ❌ Kompose can't build images
```

**Fix:** Use registry images
```yaml
services:
  app:
    image: myregistry.com/app:latest    # ✅
```

### 2. Non-Standard Service Names

```yaml
services:
  myapp:          # ❌ Doesn't match any pattern → detected as 'internal'
    image: myapp:latest
```

**Fix:** Rename or manually change service type
```yaml
services:
  web:            # ✅ Matches 'frontend' pattern
    image: myapp:latest
```

### 3. Host Paths

```yaml
services:
  app:
    volumes:
      - /host/path:/container/path    # ❌ Host paths not recommended in K8s
```

**Fix:** Use named volumes
```yaml
services:
  app:
    volumes:
      - app-data:/container/path      # ✅ Becomes PVC

volumes:
  app-data:
```

### 4. Privileged Containers

```yaml
services:
  app:
    privileged: true    # ❌ Security violation
```

**Fix:** Remove or add security contexts manually.

---

## Standardized Deployment Workflow

### For Users Deploying Apps

```bash
# 1. Clone/create app with docker-compose.yml
cd my-app/

# 2. Ensure images are in registry
# - If using build:, build and push first
docker build -t myregistry.com/app:latest .
docker push myregistry.com/app:latest

# 3. Run deploy script
bash ~/MyNodeOne/external-apps/scripts/deploy.sh

# 4. Access app
curl http://myapp.mynodeone.local
```

### For App Developers

**To make your app "MyNodeOne-ready":**

1. **Use registry images** (not `build:`)
2. **Name services clearly:**
   - Public-facing: `frontend`, `web`, `api`, `backend`
   - Internal: `database`, `cache`, `worker`
3. **Use environment variables** for configuration (not hard-coded values)
4. **Use named volumes** (not host paths)
5. **Document requirements** in README

**Example README:**
```markdown
## Deploy on MyNodeOne

```bash
bash ~/MyNodeOne/external-apps/scripts/deploy.sh
```

That's it! The app will be available at http://myapp.mynodeone.local
```

---

## Future: Explicit Configuration

We're planning to support explicit configuration via labels:

```yaml
# docker-compose.yml (future)
services:
  myservice:
    image: myapp:latest
    labels:
      # MyNodeOne-specific configuration
      mynodeone.expose: "true"
      mynodeone.service-type: "frontend"
      mynodeone.subdomain: "app"
      mynodeone.public-domain: "myapp.com"
      mynodeone.ssl: "true"
```

This would override automatic detection and give developers explicit control.

---

## Summary

**What makes an app work out-of-the-box:**
1. ✅ Registry images (no `build:`)
2. ✅ Service names match conventions (`frontend`, `api`, `database`)
3. ✅ Standard docker-compose patterns

**What MyNodeOne automatically handles:**
1. ✅ Service type detection (public vs internal)
2. ✅ LoadBalancer conversion for public services
3. ✅ MetalLB IP assignment
4. ✅ Local DNS registration
5. ✅ PVC creation for volumes
6. ✅ Inter-service communication via Kubernetes DNS

**What users need to provide:**
1. docker-compose.yml with registry images
2. Service names that indicate purpose
3. Optional: Public domain configuration

**The pattern we expect:**
- Like standard Kubernetes/docker-compose
- No MyNodeOne-specific config required
- Naming conventions guide automatic behavior
- Manual override available when needed

This makes deployment **predictable and simple**, just like running `docker-compose up` but on Kubernetes with automatic public exposure.
