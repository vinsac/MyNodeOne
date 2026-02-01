# Full-Stack SaaS Example

Complete SaaS application with:
- Frontend (React/Vue/etc)
- Backend API (Node.js/Python/etc)
- PostgreSQL database
- Redis cache

## Before Deploying

1. Build and push your Docker images:
   ```bash
   docker build -t your-registry/myapp-frontend:latest ./frontend
   docker build -t your-registry/myapp-backend:latest ./backend
   docker push your-registry/myapp-frontend:latest
   docker push your-registry/myapp-backend:latest
   ```

2. Update `docker-compose.yml` with your image URLs

## Deploy

```bash
cd external-apps/examples/saas-fullstack/
bash ../../scripts/deploy.sh
```

Answer questions:
- App name: `mysaas`
- Memory per service: `1Gi`
- CPU per service: `1000m`
- Storage: `50Gi` (for database)
- Subdomain: `mysaas`
- Public: `y`
- Domains: `app.yourdomain.com,api.yourdomain.com`

## Configure DNS

Add A records at your domain registrar:
```
app.yourdomain.com    A    <VPS_PUBLIC_IP>
api.yourdomain.com    A    <VPS_PUBLIC_IP>
```

Get VPS IP:
```bash
kubectl get configmap -n kube-system domain-registry -o jsonpath='{.data.vps-nodes\.json}'
```

## Complete Setup

```bash
sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
```

Select your app and configure routing.

## Access

- Frontend: `https://app.yourdomain.com`
- API: `https://api.yourdomain.com`

SSL certificates are automatic.

## Multi-Domain Mapping

The script will ask you to map domains to services:

```
Which service for app.yourdomain.com? [1: frontend, 2: backend]
> 1

Which service for api.yourdomain.com? [1: frontend, 2: backend]
> 2
```

## What Gets Deployed

- **Frontend**: Public-facing web application
- **Backend**: API server (accessed by frontend)
- **Database**: PostgreSQL with persistent storage
- **Redis**: Cache/sessions
- **Load Balancers**: For frontend and backend
- **Auto-scaling**: Based on CPU/memory
- **SSL**: Let's Encrypt certificates
- **DNS**: Automatic configuration

All from one command!