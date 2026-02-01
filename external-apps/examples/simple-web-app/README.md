# Simple Web App Example

The simplest possible deployment - a static website.

## Deploy

```bash
cd external-apps/examples/simple-web-app/
bash ../../scripts/deploy.sh
```

Answer the questions:
- App name: `mywebapp`
- Memory: `128Mi`
- CPU: `100m`
- Storage: `none`
- Subdomain: `mywebapp`
- Public: `n` (or `y` if you want internet access)

## Access

```
http://mywebapp.mynodeone.local
```

## What's Included

- `docker-compose.yml` - Standard Docker Compose file
- `html/index.html` - Simple HTML page

## How It Works

1. Script reads docker-compose.yml
2. Detects nginx service
3. Converts to Kubernetes
4. Deploys with requested resources
5. Configures DNS automatically

No Kubernetes knowledge needed!