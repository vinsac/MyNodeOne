# External Apps - Complete File Structure

All external app deployment materials are now consolidated in the `external-apps/` folder.

## Directory Tree

```
external-apps/
│
├── README.md                           # Quick start (2 min read)
├── INDEX.md                            # Complete reference guide
├── QUICKSTART.md                       # Quick reference for common tasks
├── STRUCTURE.md                        # This file
├── IMPLEMENTATION-NOTES.md             # Technical implementation details
│
├── scripts/
│   ├── deploy.sh                      # ⭐ Main deployment script
│   ├── undeploy.sh                    # Remove apps from cluster
│   ├── register-app.sh                # Register existing apps with MyNodeOne
│   └── generate-template.sh           # Generate new app templates
│
├── docs/
│   ├── DEVELOPER-GUIDE.md             # Complete developer documentation
│   ├── DETAILED-GUIDE.md              # In-depth technical guide
│   └── TROUBLESHOOTING.md             # Common issues and solutions
│
├── templates/
│   └── simple-web-app.yaml            # Kubernetes template for simple apps
│
└── examples/
    ├── simple-web-app/                # Working example - static site
    │   ├── README.md
    │   ├── docker-compose.yml
    │   └── html/
    │       └── index.html
    │
    └── saas-fullstack/                # Working example - full SaaS
        ├── README.md
        └── docker-compose.yml
```

## Files Consolidated (Moved Here)

The following files were moved from scattered locations into this folder:

| Old Location | New Location | Purpose |
|--------------|--------------|---------|
| `docs/guides/EXTERNAL-APP-DEPLOYMENT.md` | `external-apps/docs/DETAILED-GUIDE.md` | Technical deployment guide |
| `docs/EXTERNAL-APP-QUICKSTART.md` | `external-apps/QUICKSTART.md` | Quick reference |
| `docs/guides/EXTERNAL-APPS-SUMMARY.md` | `external-apps/IMPLEMENTATION-NOTES.md` | Implementation summary |
| `scripts/lib/register-external-app.sh` | `external-apps/scripts/register-app.sh` | App registration helper |
| `scripts/new-external-app.sh` | `external-apps/scripts/generate-template.sh` | Template generator |
| `manifests/examples/external-app-simple.yaml` | `external-apps/templates/simple-web-app.yaml` | K8s template |

## Key Scripts

### deploy.sh - Main Deployment Script

**Features:**
- Auto-detects docker-compose.yml or Kubernetes manifests
- Interactive resource configuration (RAM, CPU, storage)
- **Intelligent domain mapping** with 3 modes:
  1. **Auto-detect** (recommended): Just provide base domain (e.g., `myapp.com`)
     - Script creates: `api.myapp.com`, `app.myapp.com`, `admin.myapp.com`
     - Maps based on service naming conventions
  2. **Manual**: Provide specific domains, script intelligently matches to services
  3. **Single domain**: All traffic to primary service

**Usage:**
```bash
cd your-app-folder/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

### undeploy.sh - Remove Apps

```bash
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh myapp
```

### register-app.sh - Register Existing App

For apps already deployed with `kubectl`:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/register-app.sh \
  --name myapp --subdomain myapp --namespace myapp --service myapp-web
```

### generate-template.sh - Create New App Template

Generate boilerplate for new apps:
```bash
bash /path/to/MyNodeOne/external-apps/scripts/generate-template.sh \
  --name myapp --type fullstack --database
```

## Documentation Reading Order

### For Developers (New to MyNodeOne)

1. **Start**: `README.md` (2 min)
2. **Try it**: `examples/simple-web-app/` (5 min)
3. **Full guide**: `docs/DEVELOPER-GUIDE.md` (15 min)
4. **Reference**: Keep `QUICKSTART.md` handy

### For Evaluating MyNodeOne

1. **Quick overview**: `INDEX.md` (5 min)
2. **Try example**: `examples/simple-web-app/` (5 min)
3. **Deploy real app**: Use `scripts/deploy.sh` with your app

### For Troubleshooting

1. **Common issues**: `docs/TROUBLESHOOTING.md`
2. **Check logs**: `kubectl logs -n myapp -l app=myapp -f`
3. **GitHub Issues**: For MyNodeOne-specific problems

## Intelligent Domain Mapping

The new `deploy.sh` script solves the problem of developers needing to know all service names for complex apps.

### Problem Solved

**Before:** For an app with 10+ services, developers had to:
- Know all service names in docker-compose.yml
- Manually map each domain to each service
- Understand which services are public vs internal

**Now:** Three simple options:

#### Option 1: Auto-Detect (Recommended)

```
? Make public? y
? Choose domain setup:
  1. Auto-detect (Recommended)  ← Select this

? Base domain: myapp.com

✓ Auto-detecting subdomain mapping...
  ✓ api.myapp.com → backend (backend)
  ✓ app.myapp.com → frontend (frontend)
  ✓ admin.myapp.com → admin (admin)
  (database, redis, worker = internal only)
```

**Script automatically:**
- Detects service types from names (frontend, backend, api, admin, db, cache, worker)
- Creates conventional subdomains (api, app, admin)
- Skips internal services (database, cache, workers)

#### Option 2: Manual with Intelligence

```
? Domains: api.myapp.com,app.myapp.com,dashboard.myapp.com

✓ Mapping domains to services...
  ✓ api.myapp.com → backend (auto-matched: backend)
  ✓ app.myapp.com → frontend (auto-matched: frontend)
  
Which service should handle: dashboard.myapp.com?
  1. frontend (frontend)
  2. backend (backend)
  3. admin (admin)
Service # [1]: 3
  ✓ dashboard.myapp.com → admin
```

Script uses pattern matching:
- `api.*` → backend service
- `app.*` or `www.*` → frontend service  
- `admin.*` → admin service
- Unknown → asks user

#### Option 3: Single Domain

```
? Domain: myapp.com

✓ myapp.com → frontend
  (All other services internal)
```

Maps to primary service (frontend or first service).

### Service Type Detection

The script automatically categorizes services:

| Service Name Pattern | Detected Type | Public Domain | Convention |
|---------------------|---------------|---------------|------------|
| frontend, web, app, ui, client | `frontend` | ✓ | `app.domain.com` |
| backend, api, server | `backend` | ✓ | `api.domain.com` |
| admin, dashboard | `admin` | ✓ | `admin.domain.com` |
| db, database, postgres, mysql, mongo | `database` | ✗ | Internal only |
| redis, cache, memcache | `cache` | ✗ | Internal only |
| worker, queue, celery | `worker` | ✗ | Internal only |

**Result:** Developers don't need to know service names. Just provide base domain.

## Examples

### Simple Web App (1 service)

```bash
cd external-apps/examples/simple-web-app/
bash ../../scripts/deploy.sh

# Detected: 1 service (web)
# Resources: 128Mi RAM, 100m CPU
# Domain: demo.mynodeone.local
# Public: No
# Access: http://demo.mynodeone.local
```

### Complex SaaS (10+ services)

```yaml
# docker-compose.yml
services:
  frontend:     # Auto-detected: frontend type
  backend:      # Auto-detected: backend type
  admin:        # Auto-detected: admin type
  api-gateway:  # Auto-detected: backend type
  auth-service: # Auto-detected: backend type
  database:     # Auto-detected: database type (internal)
  redis:        # Auto-detected: cache type (internal)
  worker-1:     # Auto-detected: worker type (internal)
  worker-2:     # Auto-detected: worker type (internal)
  queue:        # Auto-detected: worker type (internal)
```

```bash
bash deploy.sh

# Resources: 1Gi RAM, 1000m CPU per service
# Auto-detect domains for base: myapp.com

✓ Auto-configured domains:
  • https://app.myapp.com      → frontend
  • https://api.myapp.com      → backend
  • https://admin.myapp.com    → admin
  
Internal services (no public domain):
  • database, redis, worker-1, worker-2, queue
```

**Developer only needed:**
1. Base domain: `myapp.com`
2. That's it!

## Next Steps

1. **Update docs index**: Link to `external-apps/` from main docs
2. **Test deploy.sh**: Try with real complex app
3. **Add video demo**: Show 30-second deployment
4. **Consider**: Bundle `kompose` for better docker-compose conversion

## Support

- **Quick start**: `external-apps/README.md`
- **Full guide**: `external-apps/docs/DEVELOPER-GUIDE.md`
- **Troubleshooting**: `external-apps/docs/TROUBLESHOOTING.md`
- **Examples**: `external-apps/examples/`
- **Issues**: GitHub Issues