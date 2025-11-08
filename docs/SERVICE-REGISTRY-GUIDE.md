# Service Registry & DNS Management Guide

**Complete guide to understanding how services are exposed across your MyNodeOne cluster**

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Service Registration](#service-registration)
4. [DNS Synchronization](#dns-synchronization)
5. [Manual Operations](#manual-operations)
6. [Troubleshooting](#troubleshooting)
7. [Best Practices](#best-practices)

---

## Overview

### What is the Service Registry?

The **Service Registry** is the **single source of truth** for all services running in your MyNodeOne cluster. When any service is deployed:

1. ✅ It's registered in the ConfigMap (`service-registry` in `kube-system` namespace)
2. ✅ Management laptops automatically sync DNS from this registry
3. ✅ All services become accessible via `.local` domains

### Benefits

- ✅ **Centralized** - One source of truth for all services
- ✅ **Automatic** - Apps register themselves during installation
- ✅ **Consistent** - Platform services and user apps work the same way
- ✅ **Synced** - Management laptops get updates automatically
- ✅ **Scalable** - Works for any number of services

---

## Architecture

### How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                    CONTROL PLANE                             │
│                                                              │
│  1. Service Deployed (Grafana, Immich, etc.)                │
│              ↓                                               │
│  2. Gets LoadBalancer IP                                     │
│              ↓                                               │
│  3. Registers in ConfigMap                                   │
│     (kube-system/service-registry)                          │
│              ↓                                               │
│  4. Stored in Cluster                                        │
│     {                                                        │
│       "grafana": {                                           │
│         "subdomain": "grafana",                             │
│         "ip": "100.76.150.205",                             │
│         "port": 80,                                          │
│         "namespace": "monitoring"                            │
│       }                                                      │
│     }                                                        │
└──────────────────────────────────────────────────────────────┘
                         ↓
                    (ConfigMap)
                         ↓
┌──────────────────────────────────────────────────────────────┐
│                 MANAGEMENT LAPTOP                            │
│                                                              │
│  1. Run: sudo ./scripts/sync-dns.sh                         │
│              ↓                                               │
│  2. Pull ConfigMap from cluster                              │
│              ↓                                               │
│  3. Parse service entries                                    │
│              ↓                                               │
│  4. Update /etc/hosts                                        │
│     100.76.150.205  grafana.minicloud.local                  │
│     100.76.150.207  demo.minicloud.local                     │
│     100.76.150.208  chat.minicloud.local                     │
│              ↓                                               │
│  5. Services accessible via .local domains! ✅               │
└──────────────────────────────────────────────────────────────┘
```

---

## Service Registration

### Automatic Registration

All apps automatically register when installed using standard install scripts:

#### Platform Services (Installed During Bootstrap)

```bash
# During control plane bootstrap
sudo ./scripts/mynodeone
# Select: 1 (Control Plane)

# Automatically registers:
- grafana.minicloud.local
- argocd.minicloud.local
- minio.minicloud.local
- longhorn.minicloud.local
- <cluster-name>.minicloud.local (dashboard)
```

#### User Apps (Post-Installation)

```bash
# Install any app
sudo ./scripts/apps/install-immich.sh

# Automatically registers:
- photos.minicloud.local (or your custom subdomain)
```

#### Demo & Special Apps

```bash
# Deploy demo app
sudo ./scripts/deploy-demo-app.sh
# Registers: demo.minicloud.local

# Deploy LLM chat
sudo ./scripts/deploy-llm-chat.sh
# Registers: chat.minicloud.local
```

### Registration Parameters

When a service registers, it provides:

| Parameter | Description | Example |
|-----------|-------------|---------|
| **internal-name** | Kubernetes service name | `"open-webui"` |
| **subdomain** | DNS subdomain | `"chat"` |
| **namespace** | Kubernetes namespace | `"llm-chat"` |
| **service** | Service name in namespace | `"open-webui"` |
| **port** | Service port | `"80"` |
| **public** | Public exposure | `"false"` |

**Example:**
```bash
./scripts/lib/service-registry.sh register \
  "open-webui" "chat" "llm-chat" "open-webui" "80" "false"
```

---

## DNS Synchronization

### Automatic Sync (Recommended)

Management laptops can sync DNS automatically:

```bash
# On management laptop
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

**What it does:**
1. Connects to cluster via kubectl
2. Fetches `service-registry` ConfigMap
3. Extracts all service entries
4. Updates `/etc/hosts` with `.local` domains

### Manual Check

```bash
# View the registry directly
kubectl get configmap -n kube-system service-registry \
  -o jsonpath='{.data.services\.json}' | jq '.'

# Example output:
{
  "grafana": {
    "subdomain": "grafana",
    "namespace": "monitoring",
    "service": "kube-prometheus-stack-grafana",
    "ip": "100.76.150.205",
    "port": 80,
    "public": false,
    "updated": "2025-11-08T05:16:39Z"
  },
  "demo": {
    "subdomain": "demo",
    "namespace": "demo-apps",
    "service": "demo",
    "ip": "100.76.150.207",
    "port": 80,
    "public": false,
    "updated": "2025-11-08T05:16:58Z"
  }
}
```

### Verify DNS Entries

```bash
# Check /etc/hosts
cat /etc/hosts | grep "MyNodeOne Services"

# Test access
curl http://grafana.minicloud.local
curl http://demo.minicloud.local
curl http://chat.minicloud.local
```

---

## Manual Operations

### Register a Service Manually

If you deployed a service manually (not using install scripts):

```bash
# On control plane
cd ~/MyNodeOne

# Register the service
sudo ./scripts/lib/service-registry.sh register \
  "<internal-name>" "<subdomain>" "<namespace>" "<service-name>" "<port>" "false"

# Example: Register custom app
sudo ./scripts/lib/service-registry.sh register \
  "myapp" "myapp" "default" "myapp-service" "8080" "false"
```

### Unregister a Service

```bash
# On control plane
sudo ./scripts/lib/service-registry.sh unregister "<subdomain>"

# Example:
sudo ./scripts/lib/service-registry.sh unregister "myapp"
```

### List All Services

```bash
# On control plane
sudo ./scripts/lib/service-registry.sh list

# Output:
Registered Services:
  • grafana (monitoring/kube-prometheus-stack-grafana:80)
    → http://grafana.minicloud.local
  • demo (demo-apps/demo:80)
    → http://demo.minicloud.local
  • chat (llm-chat/open-webui:80)
    → http://chat.minicloud.local
```

### Export DNS Entries

```bash
# On control plane
sudo ./scripts/lib/service-registry.sh export-dns "minicloud.local"

# Output (suitable for /etc/hosts):
# MyNodeOne Services - Auto-generated
100.76.150.205    grafana.minicloud.local
100.76.150.207    demo.minicloud.local
100.76.150.208    chat.minicloud.local
```

---

## Troubleshooting

### Service Not Accessible After Installation

**Symptom:** Just installed an app but can't access it via `.local` domain

**Solution:**
```bash
# 1. Verify service is registered
kubectl get configmap -n kube-system service-registry \
  -o jsonpath='{.data.services\.json}' | jq '.'

# 2. If missing, register manually (see above)

# 3. Sync DNS on laptop
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh

# 4. Test
curl http://<subdomain>.minicloud.local
```

### Old Services Still Showing

**Symptom:** Deleted app but DNS entry still exists

**Solution:**
```bash
# 1. Unregister from control plane
ssh <control-plane-ip>
cd ~/MyNodeOne
sudo ./scripts/lib/service-registry.sh unregister "<subdomain>"

# 2. Sync DNS on laptop
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

### DNS Not Syncing

**Symptom:** `sync-dns.sh` fails or shows "No services found"

**Solution:**
```bash
# 1. Check kubectl connectivity
kubectl get nodes
# Should show cluster nodes

# 2. Check service registry exists
kubectl get configmap -n kube-system service-registry
# Should show the ConfigMap

# 3. If missing, initialize on control plane
ssh <control-plane-ip>
cd ~/MyNodeOne
sudo ./scripts/lib/service-registry.sh init

# 4. Re-register platform services
sudo ./scripts/bootstrap-control-plane.sh  # Re-run bootstrap
# OR manually register each service
```

### Platform Services Missing from Registry

**Symptom:** Grafana/MinIO/ArgoCD work but not in registry

**Issue:** Control plane installed before registry feature was added

**Solution:**
```bash
# On control plane - manually register platform services
cd ~/MyNodeOne

# Register Grafana
sudo ./scripts/lib/service-registry.sh register \
  "kube-prometheus-stack-grafana" "grafana" "monitoring" \
  "kube-prometheus-stack-grafana" "80" "false"

# Register ArgoCD
sudo ./scripts/lib/service-registry.sh register \
  "argocd-server" "argocd" "argocd" \
  "argocd-server" "80" "false"

# Register MinIO
sudo ./scripts/lib/service-registry.sh register \
  "minio-console" "minio" "minio" \
  "minio-console" "9001" "false"

# Register Longhorn (if LoadBalancer)
sudo ./scripts/lib/service-registry.sh register \
  "longhorn-frontend" "longhorn" "longhorn-system" \
  "longhorn-frontend" "80" "false"

# Then sync on laptop
cd ~/MyNodeOne
sudo ./scripts/sync-dns.sh
```

---

## Best Practices

### For Developers

✅ **Always use `post-install-routing.sh`** in your install scripts
```bash
# In your app install script
source "$SCRIPT_DIR/lib/post-install-routing.sh" \
  "myapp" "80" "myapp" "myapp" "myapp-service"
```

✅ **Test registration** after deploying
```bash
kubectl get configmap -n kube-system service-registry -o json | jq '.data.services.json'
```

✅ **Provide clear DNS info** in success message
```bash
echo "✅ App accessible at: http://myapp.minicloud.local"
```

### For Users

✅ **Sync DNS regularly** on management laptops
```bash
# Add to cron or run after installing new apps
sudo ./scripts/sync-dns.sh
```

✅ **Check registry** if service isn't accessible
```bash
kubectl get configmap -n kube-system service-registry \
  -o jsonpath='{.data.services\.json}' | jq '.'
```

✅ **Use standard install scripts** - they handle registration automatically

### For Cluster Admins

✅ **Monitor registry size** - clean up old entries
```bash
sudo ./scripts/lib/service-registry.sh list
sudo ./scripts/lib/service-registry.sh unregister "<old-service>"
```

✅ **Backup registry** before major changes
```bash
kubectl get configmap -n kube-system service-registry -o yaml > service-registry-backup.yaml
```

✅ **Document custom subdomains** for your team

---

## Related Documentation

- **[APP-PUBLIC-ACCESS.md](APP-PUBLIC-ACCESS.md)** - Making apps publicly accessible via domains
- **[OPERATIONS-GUIDE.md](OPERATIONS-GUIDE.md)** - General operations and troubleshooting
- **[DNS-ARCHITECTURE.md](DNS_ARCHITECTURE.md)** - Deep dive into DNS architecture

---

## Quick Reference

### Common Commands

```bash
# Register service
sudo ./scripts/lib/service-registry.sh register \
  "<name>" "<subdomain>" "<namespace>" "<service>" "<port>" "false"

# Unregister service
sudo ./scripts/lib/service-registry.sh unregister "<subdomain>"

# List all services
sudo ./scripts/lib/service-registry.sh list

# Sync DNS on laptop
sudo ./scripts/sync-dns.sh

# View registry
kubectl get configmap -n kube-system service-registry \
  -o jsonpath='{.data.services\.json}' | jq '.'
```

### File Locations

- **Registry Script:** `scripts/lib/service-registry.sh`
- **DNS Sync Script:** `scripts/sync-dns.sh`
- **Post-Install Helper:** `scripts/lib/post-install-routing.sh`
- **ConfigMap:** `kube-system/service-registry`
- **Local DNS:** `/etc/hosts` (on management laptops)

---

**Questions or issues?** Check the [Troubleshooting](#troubleshooting) section or consult the operations guide.
