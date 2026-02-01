# Domain and Public Access Management

This guide covers how to add domains, make apps publicly accessible, and manage routing through VPS edge nodes.

---

## Prerequisites

Before making apps public, you need:
- A VPS edge node installed (see [INSTALLATION.md](../installation/INSTALLATION.md#section-2-vps-edge-node-installation))
- A public domain name (e.g., `yourdomain.com`)
- DNS access to configure A records

---

## Adding a Domain

### Step 1: Configure DNS

Log into your domain registrar (Namecheap, GoDaddy, Cloudflare, etc.) and add A records pointing to your VPS public IP.

### Recommended DNS Strategy: Multiple A Records
If you have multiple VPS nodes, add an A record for EACH node. This enables DNS round-robin load balancing.

| Type | Name | Value | Description |
|------|------|-------|-------------|
| A | @ | `<VPS-1-IP>` | Root domain |
| A | @ | `<VPS-2-IP>` | Root (for redundancy) |
| A | www | `<VPS-1-IP>` | WWW subdomain |
| A | * | `<VPS-1-IP>` | Wildcard for app subdomains |

- `@` = Root domain (e.g., `yourdomain.com`)
- `www` = WWW subdomain (e.g., `www.yourdomain.com`)
- `*` = Wildcard (e.g., `photos.yourdomain.com`)

### Step 2: Register Domain with MyNodeOne

Run on **control plane**:
```bash
sudo ./scripts/domains/add-domain.sh
```

Follow the prompts to:
- Enter your domain name
- Select which VPS edge node(s) to use
- Configure SSL email for Let's Encrypt

### Step 3: Verify DNS Propagation

```bash
# Check DNS resolves to your VPS IP
dig yourdomain.com
dig photos.yourdomain.com
```

Both should return your VPS public IP. DNS propagation can take 5-60 minutes.

---

## Making Apps Public

### Method 1: During App Installation

When installing apps from the app store, you'll be asked to configure its network identity:

```
? Local DNS name (e.g., 'photos' for photos.mynodeone.local) [immich]: photos
? Make this app publicly accessible? [y/N]: y
? Enter full URLs (comma-separated): photos.yourdomain.com, www.yourdomain.com
```

**Key Difference:** You now enter the **full URL** exactly as you want it to appear in the browser. 

- **Root:** `yourdomain.com`
- **WWW:** `www.yourdomain.com`
- **Subdomain:** `photos.yourdomain.com`

The app will automatically be configured for public access with SSL using the `expose` array.

### Method 2: For Existing Apps

Run on **control plane**:
```bash
sudo ./scripts/operations/manage-app-visibility.sh
```

This interactive script uses the **Clean Separation** architecture:
1. **Local Access**: Check/set the `local_name` used for internal `.local` DNS.
2. **Public Access**: Define one or more full domains in the `expose` array.
3. **VPS Selection**: Choose which edge nodes will proxy the traffic.

### Example: Making Nextcloud Public at Root

```bash
sudo ./scripts/operations/manage-app-visibility.sh

# Select: nextcloud
# Action: Make public
# URLs: yourdomain.com, www.yourdomain.com
# VPS Selection: 100.x.x.x

# Results: 
# ✅ https://yourdomain.com
# ✅ https://www.yourdomain.com
# ✅ http://nextcloud.mynodeone.local (still works!)
```

---

## Managing Domains

### List Registered Domains

Run on **control plane**:
```bash
kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' | jq
```

### Remove a Domain

Run on **control plane**:
```bash
sudo ./scripts/domains/remove-domain.sh
```

### Update Domain Configuration

Run on **control plane**:
```bash
sudo ./scripts/domains/configure-domain-routing.sh
```

---

## SSL Certificates

SSL certificates are automatically managed by Traefik on your VPS edge node using Let's Encrypt.

### How It Works

1. When you make an app public, routing is configured on the VPS
2. Traefik automatically requests an SSL certificate from Let's Encrypt
3. Certificates auto-renew every 60 days

### Verify SSL Status

Run on **VPS edge node**:
```bash
docker logs traefik 2>&1 | grep -i certificate
```

### Troubleshooting SSL

If certificates aren't being issued:

```bash
# Check DNS is correct
dig photos.yourdomain.com  # Should return VPS IP

# Check ports are open
sudo ufw status | grep -E '80|443'

# Check Traefik logs
docker logs traefik -f | grep -i acme

# Restart Traefik
cd /etc/traefik && docker compose restart
```

---

## Viewing Current Configuration

### App Visibility Status

Run on **control plane**:
```bash
sudo ./scripts/operations/manage-app-visibility.sh
# Select: List all apps
```

### Routing Configuration

Run on **control plane**:
```bash
kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.routing\.json}' | jq
```

### VPS Routes

Run on **VPS edge node**:
```bash
cat /etc/traefik/dynamic/mynodeone-routes.yml
```

---

## Common Subdomain Patterns

Organize your apps with meaningful subdomains:

| App | Subdomain | URL |
|-----|-----------|-----|
| Immich | photos | `https://photos.yourdomain.com` |
| Nextcloud | files | `https://files.yourdomain.com` |
| Jellyfin | media | `https://media.yourdomain.com` |
| Paperless | docs | `https://docs.yourdomain.com` |

---

## Security Considerations

### What to Expose Publicly

Recommended for public access:
- Photo sharing (Immich)
- File sharing (Nextcloud) - has built-in auth
- Media server (Jellyfin) - has built-in auth

Keep private (Tailscale-only access):
- Monitoring dashboards (Grafana)
- Admin panels (ArgoCD, Longhorn)
- Databases

### App Authentication

Most apps have built-in authentication. Ensure you:
- Set strong passwords during app setup
- Enable 2FA where available
- Review app security settings

---

## Troubleshooting

### App Not Accessible Publicly

1. **Check app is running:**
   ```bash
   kubectl get pods -A | grep <app-name>
   ```

2. **Check routing is configured:**
   ```bash
   kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.routing\.json}' | jq
   ```

3. **Check VPS can reach the app:**
   ```bash
   # On VPS
   curl -I http://<app-loadbalancer-ip>
   ```

4. **Check Traefik routes:**
   ```bash
   # On VPS
   cat /etc/traefik/dynamic/mynodeone-routes.yml | grep <app-name>
   ```

### DNS Not Resolving

```bash
# Check DNS propagation
dig yourdomain.com

# If not resolving, verify:
# 1. A records are correct in domain registrar
# 2. Wait for propagation (up to 60 minutes)
# 3. Try different DNS server: dig @8.8.8.8 yourdomain.com
```

### SSL Certificate Errors

```bash
# On VPS - check Traefik logs
docker logs traefik 2>&1 | grep -i acme

# Common issues:
# - DNS not pointing to VPS IP
# - Port 80 blocked (needed for ACME challenge)
# - Rate limited (wait 1 hour and retry)
```

---

## Related Documentation

- [INSTALLATION.md](../installation/INSTALLATION.md#section-2-vps-edge-node-installation) - VPS edge node installation
- [CLUSTER-MANAGEMENT.md](CLUSTER-MANAGEMENT.md) - General cluster operations
- [APP-STORE.md](../apps/APP-STORE.md) - Available apps