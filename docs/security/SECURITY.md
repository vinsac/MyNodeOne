# Security Overview

This guide explains how MyNodeOne handles security and what actions you should take to secure your cluster.

---

## Security Layers

MyNodeOne implements multiple security layers by default:

| Layer | Protection | Status |
|-------|------------|--------|
| Network Isolation | All services accessible only via Tailscale VPN | Enabled |
| Kubernetes RBAC | Role-based access control | Enabled |
| Pod Security Standards | Containers run as non-root, no privilege escalation | Enabled |
| Firewall (UFW) | Only SSH and Tailscale traffic allowed | Enabled |
| Audit Logging | API requests logged to `/var/log/k3s-audit.log` | Enabled |
| File Permissions | Credential files have 600 permissions (root only) | Enabled |

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

## Secrets Encryption at Rest

Kubernetes stores secrets in etcd. By default, these are base64 encoded (not encrypted). MyNodeOne can enable encryption at rest.

### Enable Encryption

```bash
# Generate encryption key
head -c 32 /dev/urandom | base64

# Create encryption config
sudo nano /etc/rancher/k3s/encryption-config.yaml
```

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <BASE64_KEY_FROM_ABOVE>
      - identity: {}
```

```bash
# Add to K3s config
sudo nano /etc/rancher/k3s/config.yaml
# Add: kube-apiserver-arg: "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"

sudo systemctl restart k3s
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
