# Security Overview

This guide explains how MyNodeOne handles security and what actions you should take to secure your cluster.

---

## Built-in Security (Enabled by Default)

MyNodeOne enables security best practices during installation. These features are configured automatically in `bootstrap-control-plane.sh`:

| Feature | Implementation | Status |
|---------|----------------|--------|
| Secrets Encryption at Rest | AES-256 encryption via `/etc/rancher/k3s/encryption-config.yaml` | Enabled |
| Kubernetes Audit Logging | Logs to `/var/log/k3s-audit.log` with 30-day retention | Enabled |
| Pod Security Standards | Baseline enforcement, restricted audit/warn | Enabled |
| Firewall (UFW) | Default deny incoming, allow SSH and Tailscale only | Enabled |
| Fail2ban | SSH brute-force protection | Enabled |
| Network Isolation | All services accessible only via Tailscale VPN | Enabled |
| Kubeconfig Permissions | Written with mode 0600 (owner read/write only) | Enabled |

---

## Credential Storage

### Where Credentials Are Stored

| Credential | Location | Permissions |
|------------|----------|-------------|
| ArgoCD password | `/root/mynodeone-argocd-credentials.txt` | 600 (root only) |
| MinIO password | `/root/mynodeone-minio-credentials.txt` | 600 (root only) |
| Grafana password | Kubernetes secret only | N/A |
| Join token | `/root/mynodeone-join-token.txt` | 600 (root only) |

### Why Plain Text Files?

Credential files exist for initial access only. They are protected by:

1. File permissions (600) - only root can read
2. SSH key authentication required
3. Tailscale VPN - machine not accessible from internet
4. Firewall - only SSH and Tailscale ports open

**After installation:** Save credentials to a password manager and delete the files.

---

## Post-Installation Security Actions

### 1. Save Credentials to Password Manager

Use a password manager on your laptop (not on the control plane):
- **Bitwarden** - https://bitwarden.com (free, open source)
- **1Password** - https://1password.com
- **KeePassXC** - https://keepassxc.org (offline)

```bash
# View all credentials
sudo /path/to/MyNodeOne/scripts/show-credentials.sh
```

### 2. Delete Credential Files

The installation script prompts you to confirm credentials are saved, then securely deletes files using `shred`. If you skipped this:

```bash
sudo shred -u /root/mynodeone-argocd-credentials.txt
sudo shred -u /root/mynodeone-minio-credentials.txt
# Keep join token if adding worker nodes later
```

### 3. Change Default Passwords

**Grafana:**
1. Login at `http://grafana.mynodeone.local`
2. Go to Profile → Change Password

**MinIO:**
1. Login at `http://minio.mynodeone.local`
2. Go to Settings → Access Keys → Create new key

**ArgoCD:**
```bash
argocd account update-password
```

### 4. SSH Key Authentication

```bash
# On your laptop
ssh-keygen -t ed25519 -C "your_email@example.com"
ssh-copy-id user@control-plane-ip

# Disable password authentication
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

---

## Security Configuration Details

### Secrets Encryption at Rest

MyNodeOne automatically encrypts all Kubernetes secrets using AES-256. This is configured during installation:

```yaml
# /etc/rancher/k3s/encryption-config.yaml (auto-generated)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <AUTO_GENERATED_KEY>
      - identity: {}  # Fallback for reading old unencrypted data
```

The encryption key is generated during installation using `head -c 32 /dev/urandom | base64`.

### Audit Logging

All Kubernetes API requests are logged with the following policy:

- **Admin actions**: Full request/response logging
- **Secret access**: Metadata logging
- **Pod operations**: Request-level logging for create/update/delete
- **Everything else**: Metadata logging

Logs are stored at `/var/log/k3s-audit.log` with:
- 30-day retention
- 10 backup files
- 100MB max file size

### Pod Security Standards

MyNodeOne enforces baseline Pod Security Standards:

```yaml
# /etc/rancher/k3s/pod-security-config.yaml
defaults:
  enforce: "baseline"        # Block non-compliant pods
  audit: "restricted"        # Log restricted violations
  warn: "restricted"         # Warn on restricted violations
exemptions:
  namespaces: [kube-system, longhorn-system, metallb-system, cert-manager]
```

### Firewall Configuration

UFW is configured on all nodes:

**Control Plane and Worker Nodes:**
```
Default: deny incoming, allow outgoing
Allow: SSH (22/tcp)
Allow: All traffic on tailscale0 interface
```

**VPS Edge Nodes:**
```
Default: deny incoming, allow outgoing
Allow: SSH (22/tcp)
Allow: HTTP (80/tcp)
Allow: HTTPS (443/tcp)
Allow: All traffic on tailscale0 interface
```

---

## Optional Security Enhancements

During installation, you are prompted to deploy additional security features. These can also be added later:

```bash
sudo ./scripts/enable-security-hardening.sh
```

This adds:
- **Network Policies**: Default deny with explicit allow rules
- **Resource Quotas**: Prevent resource exhaustion attacks
- **Traefik Security Headers**: HSTS, CSP, XSS protection

These are recommended for production but optional for home/testing environments.

---

## Verifying Security Configuration

```bash
# Check firewall status
sudo ufw status verbose

# Check audit logs exist
ls -la /var/log/k3s-audit.log

# Check encryption config exists
sudo ls -la /etc/rancher/k3s/encryption-config.yaml

# Check pod security config
sudo cat /etc/rancher/k3s/pod-security-config.yaml

# Check fail2ban status
sudo systemctl status fail2ban
```

---

## Security Checklist

### After Installation

- [ ] Save all credentials to password manager
- [ ] Delete credential files from `/root/`
- [ ] Change default passwords for Grafana, MinIO, ArgoCD
- [ ] Verify SSH key authentication works
- [ ] Disable SSH password authentication
- [ ] Verify firewall: `sudo ufw status verbose`

### Monthly

- [ ] Review audit logs for suspicious activity
- [ ] Rotate service credentials
- [ ] Update system packages: `sudo apt update && sudo apt upgrade`
- [ ] Check for K3s updates

---

## Incident Response

If credentials are compromised:

1. **Change all passwords immediately**
2. **Revoke compromised API keys**
3. **Check audit logs:**
   ```bash
   sudo grep "authentication.*failed" /var/log/k3s-audit.log
   ```
4. **Review running pods:**
   ```bash
   kubectl get pods -A
   ```
5. **Rotate encryption keys** (requires cluster restart)

---

## Related Documentation

- [PASSWORD-MANAGEMENT.md](PASSWORD-MANAGEMENT.md) - Detailed password storage guidance
- [BEST-PRACTICES.md](BEST-PRACTICES.md) - Production security hardening
