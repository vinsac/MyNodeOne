# MyNodeOne App Store

MyNodeOne includes a built-in App Store with one-click installations for popular self-hosted applications.

---

## Available Applications

### AI & Assistant
| Application | Description | Status |
|-------------|-------------|--------|
| LLM Chat (Open WebUI + Ollama) | Private AI chat with local LLMs. Supports phi3, llama3.2, mistral, and more. | Available |
| LLM API | OpenAI-compatible API for AI applications with GPU acceleration | Available |

### Media & Entertainment
| Application | Description | Status |
|-------------|-------------|--------|
| Jellyfin | Open source media server | Available |

### Photos & Files
| Application | Description | Status |
|-------------|-------------|--------|
| Immich | Self-hosted Google Photos alternative with AI features | Available |
| Nextcloud | Cloud storage and collaboration platform | Available |
| Paperless-ngx | Document management with OCR | Available |

### Communication & Productivity
| Application | Description | Status |
|-------------|-------------|--------|
| Mattermost | Team chat and collaboration (Slack alternative) | Available |

### Security & Monitoring
| Application | Description | Status |
|-------------|-------------|--------|
| Homepage | Dashboard for all your services | Available |

### Resource Requirements

| Application | RAM | CPU | Storage | Notes |
|-------------|-----|-----|---------|-------|
| LLM Chat | 4GB+ | 2 cores | 50GB+ | Depends on model size |
| LLM API | 8GB+ | 4 cores | 100GB+ | GPU acceleration recommended |
| Jellyfin | 2GB | 1 core | 10GB + media | Hardware transcoding available |
| Immich | 4GB | 2 cores | 50GB + photos | Includes PostgreSQL + Redis |
| Nextcloud | 2GB | 1 core | 20GB + files | Includes database |
| Paperless-ngx | 2GB | 1 core | 10GB + documents | Includes OCR processing |
| Homepage | 256MB | 0.2 core | 500MB | Dashboard only |
| Mattermost | 2GB | 1 core | 10GB | Includes PostgreSQL |

---

## Installation

### Method 1: Interactive App Store

SSH into your control plane and run:

```bash
sudo ./scripts/operations/app-store.sh
```

This launches an interactive menu where you can:
1. Browse available applications
2. Select an app by number
3. Wait for automatic installation
4. Get access URL and credentials

### Method 2: Direct Script Execution

Install any app directly:

```bash
# AI Chat Assistant
sudo ./scripts/apps/llm-chat/install-llm-chat.sh

# LLM API (OpenAI-compatible)
sudo ./scripts/apps/llmapi/install-llmapi.sh

# Media server
sudo ./scripts/apps/jellyfin/install-jellyfin.sh

# Photo backup
sudo ./scripts/apps/immich/install-immich.sh

# Cloud storage
sudo ./scripts/apps/nextcloud/install-nextcloud.sh

# Document management
sudo ./scripts/apps/paperless/install-paperless.sh

# Team chat
sudo ./scripts/apps/mattermost/install-mattermost.sh

# Application dashboard
sudo ./scripts/apps/homepage/install-homepage.sh
```

### Method 3: Web Dashboard

1. Open `http://mynodeone.local` in your browser
2. Scroll to "One-Click App Installation"
3. Click on any app card
4. Copy the installation command
5. Run it on your control plane

### What Happens During Installation

Each script automatically:
1. Creates an isolated namespace
2. Deploys required databases (PostgreSQL/MySQL/Redis if needed)
3. Configures persistent storage via Longhorn
4. Assigns a LoadBalancer IP via MetalLB
5. Generates secure random passwords
6. Displays access URL and credentials

---

## Managing Installed Apps

### View Installed Apps

```bash
kubectl get namespaces | grep -E "jellyfin|immich|homepage|llm-chat|llmapi|nextcloud|paperless|mattermost"
```

### Check App Status

```bash
kubectl get all -n <app-name>
```

### View App Logs

```bash
kubectl logs -f deployment/<app-name> -n <app-name>
```

### Restart App

```bash
kubectl rollout restart deployment/<app-name> -n <app-name>
```

### Uninstall App

```bash
# This removes everything including data
kubectl delete namespace <app-name>
```

### Accessing Apps

Every app gets an easy-to-remember address:

| Application | URL |
|-------------|-----|
| Jellyfin | `http://jellyfin.mynodeone.local` |
| Immich | `http://immich.mynodeone.local` |
| Nextcloud | `http://nextcloud.mynodeone.local` |
| Paperless-ngx | `http://paperless.mynodeone.local` |
| Homepage | `http://homepage.mynodeone.local` |
| Mattermost | `http://mattermost.mynodeone.local` |
| LLM Chat | `http://chat.mynodeone.local` |
| LLM API | `http://llmapi.mynodeone.local` |

**Desktop/Laptop:** Works immediately after DNS setup. Run `setup-client-dns.sh` on each client.

**Mobile Devices:** Requires Tailscale. Install the Tailscale app, login with the same account as MyNodeOne, and connect.

### Mobile App Clients

| Application | iOS | Android |
|-------------|-----|---------|
| Immich | Immich app | Immich app |
| Jellyfin | Jellyfin app | Jellyfin app |
| Nextcloud | Nextcloud app | Nextcloud app |
| Mattermost | Mattermost app | Mattermost app |

Configure each mobile app to use your `http://<app>.mynodeone.local` server URL.

---

## Troubleshooting

### App Not Starting

```bash
# Check pod status
kubectl get pods -n <app-name>

# View logs
kubectl logs <pod-name> -n <app-name>

# Describe pod for events
kubectl describe pod <pod-name> -n <app-name>
```

**Common causes:**
- **ImagePullBackOff:** Network issue or incorrect image name
- **CrashLoopBackOff:** Application error, check logs
- **Pending:** Insufficient resources or storage

### Cannot Access App

```bash
# Check service IP
kubectl get svc -n <app-name>

# Verify Tailscale connection
tailscale status

# Test connectivity
curl http://<service-ip>
```

**Common causes:**
- DNS not configured on client
- Tailscale not connected (mobile devices)
- Service not ready yet

### High Resource Usage

```bash
# Check resource usage
kubectl top pods -n <app-name>
kubectl top nodes

# Edit resource limits
kubectl edit deployment <app-name> -n <app-name>
```

### Storage Issues

```bash
# Check persistent volumes
kubectl get pv
kubectl get pvc -n <app-name>

# Check Longhorn status
kubectl get volumes -n longhorn-system
```

---

## Contributing

To add a new app to the store:

1. Create installation script: `scripts/apps/install-<appname>.sh`
2. Follow the template from existing apps (Homepage, Jellyfin, Immich, Mattermost, etc.)
3. Include:
   - Namespace creation
   - Storage configuration
   - Database deployment (if needed)
   - Main application deployment
   - Service with LoadBalancer
   - Access info and credentials output
4. Create uninstall script: `scripts/apps/uninstall-<appname>.sh`
5. Update:
   - `scripts/apps/README.md`
   - `scripts/operations/app-store.sh` (add menu option)
   - `website/dashboard.html` (add app card)
   - This file
6. Test on a real cluster
7. Submit a Pull Request

### Requirements

- Must work with K3s
- Must use Longhorn for storage
- Must request LoadBalancer service with `mynodeone.io/subdomain` annotation
- Must generate secure random passwords
- Must display access info clearly
- Must use `validate_prerequisites` from `scripts/apps/lib/validation.sh` for pre-flight checks
- Must call `post-install-routing.sh` after deployment for service registration and DNS
- Registry key (in `register` and `post-install-routing`) must match the K8s service name
- Verification must check `.local_name` field (not `.subdomain`)
- Dependencies: `kubectl`, `jq` (for registry verification), Longhorn storage class

### Service Registration Pattern

Every app install script must:

1. **Add annotation** to the K8s Service:
   ```yaml
   annotations:
     mynodeone.io/subdomain: "${APP_SUBDOMAIN}"
   ```
2. **Register with matching key**: The first argument to `service-registry.sh register` and `post-install-routing.sh` must be the K8s service name (e.g., `jellyfin`, `open-webui`, `immich-server`)
3. **Verify with `.local_name`**: Post-registration checks should read `.local_name` from the ConfigMap, not `.subdomain`

See [DEFENSIVE-PROGRAMMING.md](../contributing/DEFENSIVE-PROGRAMMING.md#service-registry-and-domain-handling) for the full pattern.

---

## More Information

- **Installation scripts:** `scripts/apps/`
- **Troubleshooting:** [troubleshooting.md](../operations/troubleshooting.md)
- **FAQ:** [FAQ.md](../reference/FAQ.md)