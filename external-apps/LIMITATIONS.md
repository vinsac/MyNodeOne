# External App Deployment - Known Limitations

This document describes known limitations when deploying external apps to MyNodeOne and how to handle them.

## Design Philosophy

MyNodeOne's external app deployment is designed to work like standard Kubernetes:
- **Input**: docker-compose.yml or Kubernetes manifests
- **Output**: Deployed app with LoadBalancer and local DNS
- **Principle**: Simple, predictable, no app-specific magic

We use **Kompose** to convert docker-compose.yml to Kubernetes manifests, then apply generic MyNodeOne improvements (LoadBalancer service type, PVC sizing).

---

## Common Issues and Solutions

### 1. Build Directives Not Supported

**Issue:**
```yaml
services:
  myapp:
    build: ./myapp    # ❌ Kompose can't build images
```

**Why:** Kompose converts docker-compose to Kubernetes manifests but cannot build Docker images. It generates `image: myapp` which doesn't exist in any registry.

**Solution:**
```yaml
# Option A: Use pre-built images
services:
  myapp:
    image: myregistry.com/myapp:latest    # ✅ Pull from registry

# Option B: Build and push manually
docker build -t myregistry.com/myapp:latest ./myapp
docker push myregistry.com/myapp:latest
# Then update docker-compose.yml to reference it
```

---

### 2. PostgreSQL Volume Mount Issues

**Issue:** PostgreSQL crashes with:
```
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
It contains a lost+found directory
```

**Why:** Longhorn (MyNodeOne's storage) creates `lost+found` in volume root. PostgreSQL refuses to initialize in non-empty directories.

**Solution:** Use PGDATA subdirectory
```yaml
services:
  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      PGDATA: /var/lib/postgresql/data/pgdata    # ✅ Use subdirectory
    volumes:
      - db-data:/var/lib/postgresql/data
```

---

### 3. PodSecurity Warnings

**Issue:**
```
Warning: would violate PodSecurity "restricted:latest": 
  allowPrivilegeEscalation != false
  unrestricted capabilities
  runAsNonRoot != true
```

**Why:** MyNodeOne uses Kubernetes PodSecurity standards. Many Docker images run as root or require elevated privileges.

**Impact:** These are **warnings only** - pods will still run. They indicate the app doesn't follow security best practices.

**Solution (if pods fail to start):**
```yaml
# Add security context to deployment manifest
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault
```

---

### 4. Service Type Conversion

**What we do:** Automatically convert frontend/backend services from ClusterIP to LoadBalancer.

**Why:** ClusterIP services are only accessible within the cluster. LoadBalancer type gets an external IP from MetalLB for local network access.

**Detection logic:**
- Service names matching: `vote`, `result`, `frontend`, `web`, `ui`, `client`, `backend`, `api`, `server`, `admin`, `dashboard`
- Internal services (database, cache, worker, queue) remain ClusterIP

**Override:** Manually edit generated manifests before deployment if detection is wrong.

---

### 5. PVC Size Minimum

**What we do:** Enforce minimum 1Gi storage for Persistent Volume Claims.

**Why:** MyNodeOne uses Longhorn which has a 1Gi minimum.

**If you need less:** Edit the PVC manifest after generation but before deployment.

---

## Workflow for Complex Apps

For apps with build directives or special configurations:

### Step 1: Generate Manifests
```bash
cd /path/to/your-app
bash ~/MyNodeOne/external-apps/scripts/deploy.sh
# Answer prompts, let it generate manifests
# Deployment may fail - that's expected
```

### Step 2: Review Generated Manifests
```bash
# Manifests are in /tmp/mynodeone-deploy-*/
ls /tmp/mynodeone-deploy-*/

# Common files:
# - *-deployment.yaml    (app containers)
# - *-service.yaml       (networking)
# - *-persistentvolumeclaim.yaml (storage)
```

### Step 3: Fix Issues Manually
```bash
# Edit manifests as needed
vi /tmp/mynodeone-deploy-*/*.yaml

# Common fixes:
# - Replace image: with registry images
# - Add environment variables
# - Adjust resource limits
# - Fix security contexts
```

### Step 4: Deploy Manually
```bash
# Create namespace
kubectl create namespace myapp

# Apply manifests
kubectl apply -f /tmp/mynodeone-deploy-*/ -n myapp

# Register with MyNodeOne
sudo bash ~/MyNodeOne/scripts/lib/service-registry.sh register \
    myapp mysubdomain myapp myservice 80 false

# Update DNS
sudo bash ~/MyNodeOne/scripts/sync-dns.sh
```

---

## Example: Docker Voting App

The Docker Example Voting App requires these manual fixes:

### Original docker-compose.yml Issues:
- Uses `build:` directives (no registry images)
- PostgreSQL needs PGDATA subdirectory
- Multiple frontend services (vote, result)

### Manual Fixes:

1. **Replace build with images:**
```bash
# Edit deployments
sed -i 's|image: vote|image: dockersamples/examplevotingapp_vote:latest|g' vote-deployment.yaml
sed -i 's|image: result|image: dockersamples/examplevotingapp_result:latest|g' result-deployment.yaml
sed -i 's|image: worker|image: dockersamples/examplevotingapp_worker:latest|g' worker-deployment.yaml
```

2. **Fix PostgreSQL:**
```yaml
# Add to db-deployment.yaml under env:
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

3. **Deploy:**
```bash
kubectl create namespace votingapp
kubectl apply -f /tmp/mynodeone-deploy-*/ -n votingapp
```

---

## Getting Help

**Documentation:**
- `external-apps/README.md` - Overview and usage
- `external-apps/ARCHITECTURE.md` - How it works
- `scripts/apps/*/install-*.sh` - Reference implementations (Immich, Jellyfin)

**Debugging:**
```bash
# Check pod status
kubectl get pods -n <namespace>

# View pod logs
kubectl logs -n <namespace> <pod-name>

# Describe pod for events
kubectl describe pod -n <namespace> <pod-name>

# Check services
kubectl get svc -n <namespace>
```

**Community:**
- GitHub Issues: Report bugs or request features
- Discussions: Ask questions about deployment

---

## Future: LLM-Assisted Conversion

We're considering an LLM-powered tool to automatically fix common issues:

```bash
# Future tool (not yet implemented)
mynodeone convert docker-compose.yml

# Would analyze and suggest fixes:
# - Replace build: with registry images
# - Add missing env vars
# - Fix security contexts
# - Generate MyNodeOne-compatible manifests
```

This would make deployment easier while keeping the approach general and maintainable.
