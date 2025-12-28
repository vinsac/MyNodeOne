# External Apps - Complete Reference

**Everything you need to deploy your apps on MyNodeOne infrastructure.**

---

## Quick Start (30 seconds)

```bash
cd your-app-folder/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

Answer questions about resources and domains. Done.

---

## Directory Structure

```
external-apps/
├── README.md                    ← Start here (2 min read)
├── INDEX.md                     ← This file
│
├── scripts/
│   ├── deploy.sh               ← Main deployment script
│   └── undeploy.sh             ← Remove apps
│
├── docs/
│   ├── DEVELOPER-GUIDE.md      ← Complete developer guide
│   └── TROUBLESHOOTING.md      ← Fix common issues
│
└── examples/
    ├── simple-web-app/         ← Static site example
    │   ├── docker-compose.yml
    │   ├── html/index.html
    │   └── README.md
    │
    └── saas-fullstack/         ← Full SaaS example
        ├── docker-compose.yml
        └── README.md
```

---

## Three-Step Process

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
The script will help you create everything.

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

## For Different User Types

### I'm a SaaS Developer

- Build your app as usual (React + Node.js + PostgreSQL)
- Create standard `docker-compose.yml`
- Run `deploy.sh`
- Get: Local DNS, Public routing, SSL, Auto-scaling
- **No Kubernetes knowledge needed**

See: `examples/saas-fullstack/`

### I Have an Existing App

- If you have `docker-compose.yml`: Perfect, run `deploy.sh`
- If you have Kubernetes manifests: Also works, run `deploy.sh`
- If you have just images: Script will generate everything

See: `docs/DEVELOPER-GUIDE.md`

### I'm Evaluating MyNodeOne

- Try the simple example: `cd examples/simple-web-app/ && bash ../../scripts/deploy.sh`
- See it work in < 5 minutes
- Then try with your real app

### I Need Multi-Domain Setup

Example: `api.example.com`, `app.example.com`, `admin.example.com`

The script asks:
```
Domains: api.example.com,app.example.com,admin.example.com
```

Maps each domain to your services automatically. SSL included.

See: `docs/DEVELOPER-GUIDE.md` → "Multi-Service Apps"

---

## What You Get (Automatic)

When you deploy, MyNodeOne automatically configures:

| Feature | What You Get | Command |
|---------|-------------|---------|
| **Local DNS** | `myapp.mynodeone.local` | Automatic |
| **Load Balancer** | IP address assigned | Automatic |
| **Storage** | Persistent volumes via Longhorn | Automatic |
| **Public Access** | VPS routing + SSL | After `manage-app-visibility.sh` |
| **Auto-Scaling** | Scale based on CPU/memory | Automatic |
| **Monitoring** | Logs and metrics | `kubectl logs` |
| **High Availability** | Multi-replica deployment | Automatic |

---

## Key Design Principles

### 1. Zero MyNodeOne Knowledge Required
- Developers don't need to learn Kubernetes
- Don't need to understand MyNodeOne architecture
- Just know how to build containerized apps

### 2. Standard Tools
- Standard `docker-compose.yml` works
- Standard `Dockerfile` works
- Standard Kubernetes manifests work
- No proprietary formats

### 3. One Command
- Deploy: `bash deploy.sh`
- Update: `kubectl set image ...`
- Undeploy: `bash undeploy.sh myapp`

### 4. Infrastructure-Agnostic Apps
- Build once, deploy anywhere
- Same app can deploy to AWS, GCP, or MyNodeOne
- No MyNodeOne-specific code in your app

### 5. Multi-Service Support
- Frontend + Backend + Database in one `docker-compose.yml`
- Multiple domains (api.example.com, app.example.com)
- All handled automatically

---

## Common Workflows

### Deploy New App
```bash
cd my-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
# Answer questions
# Access at http://myapp.mynodeone.local
```

### Update App
```bash
# Build new version
docker build -t registry/myapp:v2 .
docker push registry/myapp:v2

# Update
kubectl set image deployment/myapp myapp=registry/myapp:v2 -n myapp
```

### Make App Public
```bash
# Add DNS A records for your domains
# Then:
sudo /path/to/MyNodeOne/scripts/manage-app-visibility.sh
# Select your app and configure
```

### Scale App
```bash
kubectl scale deployment -n myapp --replicas=5 --all
# Or auto-scaling is already configured
```

### View Logs
```bash
kubectl logs -n myapp -l app=myapp -f
```

### Remove App
```bash
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh myapp
```

---

## Documentation Map

| Document | Purpose | Time |
|----------|---------|------|
| `README.md` | Quick overview | 2 min |
| `INDEX.md` | This file - complete reference | 5 min |
| `docs/DEVELOPER-GUIDE.md` | Complete developer guide | 15 min |
| `examples/simple-web-app/` | Try it yourself | 5 min |
| `examples/saas-fullstack/` | Real-world SaaS pattern | 10 min |

---

## Support

**Quick Issues**
```bash
kubectl logs -n myapp -l app=myapp -f
kubectl get pods -n myapp
```

**Can't Access App**
```bash
kubectl get svc -n myapp
sudo bash /path/to/MyNodeOne/scripts/sync-dns.sh
```

**Detailed Help**
- See: `docs/TROUBLESHOOTING.md` (when created)
- GitHub Issues
- GitHub Discussions

---

## Examples You Can Try Now

### Example 1: Static Website (2 minutes)
```bash
cd /path/to/MyNodeOne/external-apps/examples/simple-web-app/
bash ../../scripts/deploy.sh

# Questions:
# - App name: demo
# - Memory: 128Mi
# - CPU: 100m
# - Storage: none
# - Subdomain: demo
# - Public: n

# Access: http://demo.mynodeone.local
```

### Example 2: Full SaaS (5 minutes)
```bash
cd examples/saas-fullstack/
# Edit docker-compose.yml with your images
bash ../../scripts/deploy.sh

# Questions:
# - Memory: 1Gi
# - CPU: 1000m
# - Storage: 50Gi
# - Public: y
# - Domains: app.example.com,api.example.com

# Then:
# 1. Add DNS records
# 2. Run: sudo manage-app-visibility.sh
# 3. Access: https://app.example.com
```

---

## Philosophy

MyNodeOne provides **infrastructure as code** that developers don't need to code for.

- **You**: Build containerized apps (standard Docker)
- **MyNodeOne**: Handles Kubernetes, networking, storage, SSL, DNS
- **Result**: Your app runs in production with enterprise features

It's like AWS Elastic Beanstalk or Heroku, but:
- You own the infrastructure
- No vendor lock-in
- No monthly fees per app
- Full control

---

## Next Steps

1. **Try the simple example**: 5 minutes to see it work
2. **Deploy your real app**: Use `deploy.sh` with your app
3. **Configure public access**: If you want internet exposure
4. **Scale as needed**: Add replicas, adjust resources

**Start here**: `bash examples/simple-web-app/../../scripts/deploy.sh` from the simple-web-app directory

---

## FAQ

**Q: Do I need to learn MyNodeOne internals?**  
A: No. Just run `deploy.sh`.

**Q: Can I use this for production SaaS?**  
A: Yes. Includes auto-scaling, HA, SSL, monitoring.

**Q: What if I have 10 microservices?**  
A: Works fine. One `docker-compose.yml` with all services.

**Q: How much does it cost?**  
A: Free. You only pay for your servers.

**Q: Can I deploy multiple apps?**  
A: Yes. Unlimited apps, each isolated.

**Q: Do my users need MyNodeOne?**  
A: No. Your app is standard - works anywhere.

---

**Ready?** Start with: `cd examples/simple-web-app/ && bash ../../scripts/deploy.sh`
