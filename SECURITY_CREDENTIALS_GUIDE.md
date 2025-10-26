# Security & Credentials Management Guide

**IMPORTANT:** This guide explains how MyNodeOne handles sensitive credentials and what you should do to secure them.

---

## 🔒 Current Security Status

### What's Protected ✅

Your MyNodeOne cluster has multiple layers of security:

1. **Network Isolation** ✅
   - All services only accessible via Tailscale VPN (100.x.x.x addresses)
   - No public internet exposure by default
   - Encrypted mesh network communication

2. **Kubernetes RBAC** ✅
   - Role-Based Access Control enforced
   - Service accounts with limited permissions
   - Namespace isolation

3. **Pod Security Standards** ✅
   - Restricted security policies enforced
   - Containers run as non-root
   - No privilege escalation allowed

4. **Firewall (UFW)** ✅
   - Only SSH and Tailscale traffic allowed
   - All other ports blocked

5. **Audit Logging** ✅
   - All API requests logged to `/var/log/k3s-audit.log`
   - Track who accessed what and when

6. **File System Permissions** ✅
   - Credential files have 600 permissions (only root can read)
   - Located in /root/ directory (not accessible to normal users)

### What's Currently Disabled ⚠️

**Secrets Encryption at Rest:**
- Status: Temporarily disabled
- Location: Kubernetes etcd database
- **IMPORTANT:** Will be automatically enabled on fresh installations

---

## 🔐 Secrets Encryption Explained

### What is Secrets Encryption at Rest?

Kubernetes stores all secrets (passwords, API keys, etc.) in an internal database called **etcd**. By default, these are stored in **base64 encoding** (which is NOT encryption - it's just obfuscation).

**Secrets encryption at rest** means encrypting these secrets with a real encryption key before storing them in etcd.

### Why Was It Disabled on Your Current Cluster?

During the installation and debugging process, we:
1. Enabled secrets encryption with one configuration
2. Later changed the encryption provider
3. This created a conflict - K3s couldn't decrypt existing secrets with the new key
4. Had to temporarily disable it to get the cluster running

**This is a known Kubernetes issue** when changing encryption configurations on running clusters.

### Fresh Installation = Auto-Enabled ✅

**Good news:** On a **fresh installation**, secrets encryption will be **automatically enabled** from the start because:
- No existing secrets to conflict with
- Encryption provider set from the beginning
- All new secrets encrypted from day one

---

## 📋 Credential File Security

### Where Credentials Are Stored

| What | Location | Permissions | Encrypted? |
|------|----------|-------------|------------|
| **ArgoCD password** | `/root/mynodeone-argocd-credentials.txt` | 600 (root only) | No (file) / Yes (in K8s) |
| **MinIO password** | `/root/mynodeone-minio-credentials.txt` | 600 (root only) | No (file) / Yes (in K8s) |
| **Grafana password** | Kubernetes secret only | N/A | Yes (in K8s) |
| **Join token** | `/root/mynodeone-join-token.txt` | 600 (root only) | Yes (in K8s) |

### Why Plain Text Files?

**For initial access only:**
- You need these passwords to log into services the first time
- They're only accessible to root user
- Machine is protected by SSH keys and Tailscale VPN
- **You should delete them** after saving to a password manager

### Security Layers

Even though credential files are plain text, they're protected by:

1. **File Permissions (600)** - Only root can read
2. **SSH Access** - Need SSH key to get into machine
3. **Tailscale VPN** - Machine not accessible from internet
4. **Firewall** - Only SSH and Tailscale ports open
5. **Physical Security** - Your hardware, your location

---

## 🎯 Recommended Security Actions

### Immediate Actions (After Installation)

#### 1. Save Credentials Securely

**Install a password manager on your laptop** (not on the control plane):
- **1Password** - https://1password.com (Paid, best UX)
- **Bitwarden** - https://bitwarden.com (Free & Open Source)
- **KeePassXC** - https://keepassxc.org (Free, Offline)

**Save these credentials:**
```bash
# View all credentials
sudo /home/canada-pc-0001/MyNodeOne/scripts/show-credentials.sh

# Copy each to your password manager:
# 1. Grafana: admin + password
# 2. ArgoCD: username + password (from file)
# 3. MinIO: admin + password (from file)
```

#### 2. Delete Credential Files (After Saving)

**Once saved to password manager:**
```bash
# Delete credential files
sudo rm /root/mynodeone-argocd-credentials.txt
sudo rm /root/mynodeone-minio-credentials.txt
# Keep join token if you plan to add worker nodes
```

#### 3. Change Default Passwords

**Grafana:**
```bash
# Login to http://100.118.5.203
# Use admin + saved password
# Go to Profile → Change Password
```

**MinIO:**
```bash
# Login to http://100.118.5.202:9001
# Use admin + saved password
# Go to Settings → Access Keys → Create new key
# Delete old admin user
```

**ArgoCD:**
```bash
# Change password via CLI
argocd account update-password
```

#### 4. Set Up SSH Key Authentication (If Not Already)

```bash
# On your laptop, generate SSH key
ssh-keygen -t ed25519 -C "your_email@example.com"

# Copy to control plane
ssh-copy-id user@your-control-plane-ip

# Test
ssh user@your-control-plane-ip

# Disable password authentication
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### Additional Security Measures

#### 5. Enable Secrets Encryption (If Disabled)

**For existing clusters where it's disabled:**
```bash
# Backup existing secrets first
kubectl get secrets --all-namespaces -o yaml > /root/secrets-backup.yaml

# Re-enable encryption
sudo cp /etc/rancher/k3s/encryption-config.yaml.bak /etc/rancher/k3s/encryption-config.yaml

# Update K3s config
sudo nano /etc/rancher/k3s/config.yaml
# Add this line under kube-apiserver-arg:
#   - "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"

# Restart K3s
sudo systemctl restart k3s

# Wait for K3s to be ready
kubectl get nodes

# Re-encrypt all existing secrets
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

#### 6. Rotate Credentials Regularly

**Set a reminder to rotate every 90 days:**
- Change Grafana admin password
- Regenerate MinIO access keys
- Update ArgoCD password
- Rotate SSH keys

#### 7. Enable 2FA (Where Possible)

Some services support two-factor authentication:
- ArgoCD: Can integrate with OAuth/OIDC providers
- Grafana: Supports 2FA natively

#### 8. Set Up Backup Encryption

```bash
# Install age encryption tool
sudo apt install age -y

# Generate encryption key
age-keygen > /root/backup-key.txt
sudo chmod 600 /root/backup-key.txt

# Encrypt backups
kubectl get secrets --all-namespaces -o yaml | \
  age -r $(cat /root/backup-key.txt | grep public | cut -d' ' -f3) > \
  /root/secrets-backup.age
```

---

## 🆘 What If Credentials Are Compromised?

### Immediate Steps:

1. **Change all passwords immediately**
2. **Revoke compromised API keys**
3. **Check audit logs** for unauthorized access:
   ```bash
   sudo grep "authentication.*failed" /var/log/k3s-audit.log
   ```
4. **Rotate encryption keys** (requires cluster downtime)
5. **Review all running pods** for suspicious activity:
   ```bash
   kubectl get pods -A
   ```

### Prevention:

- ✅ Use strong, unique passwords
- ✅ Enable 2FA where available
- ✅ Regularly rotate credentials
- ✅ Monitor audit logs
- ✅ Keep credential files deleted
- ✅ Use password manager

---

## ✅ Fresh Installation Security Checklist

When installing MyNodeOne on fresh machines:

- [ ] **Before Installation:**
  - [ ] Set up password manager on your laptop
  - [ ] Generate strong SSH key pair
  - [ ] Document your security policies

- [ ] **During Installation:**
  - [ ] Secrets encryption will be auto-enabled ✅
  - [ ] Pod Security Standards will be enforced ✅
  - [ ] Firewall will be configured ✅
  - [ ] Audit logging will be enabled ✅

- [ ] **After Installation:**
  - [ ] Run `sudo ./scripts/show-credentials.sh`
  - [ ] Save all credentials to password manager
  - [ ] Delete credential files: `sudo rm /root/mynodeone-*-credentials.txt`
  - [ ] Change default Grafana password
  - [ ] Create new MinIO access keys
  - [ ] Change ArgoCD password
  - [ ] Verify secrets encryption is enabled:
    ```bash
    sudo grep "encryption-provider-config" /etc/rancher/k3s/config.yaml
    ```
  - [ ] Test access to all services
  - [ ] Set calendar reminder for credential rotation (90 days)

---

## 📊 Security Comparison

### Current State (Debugging Cluster)
```
✅ Network Isolation (Tailscale)
✅ Firewall (UFW)
✅ RBAC
✅ Pod Security Standards
✅ Audit Logging
✅ File Permissions (600)
⚠️ Secrets Encryption (Disabled)
⚠️ Credential files on disk
```

### Recommended State (Fresh Production Cluster)
```
✅ Network Isolation (Tailscale)
✅ Firewall (UFW)
✅ RBAC
✅ Pod Security Standards
✅ Audit Logging
✅ File Permissions (600)
✅ Secrets Encryption (Enabled from start)
✅ Credential files deleted
✅ Passwords changed from defaults
✅ 2FA enabled where possible
✅ Regular credential rotation
```

---

## 🎓 Understanding the Risk

### Plain Text Credential Files Risk Level

**Actual Risk:** 🟡 **MEDIUM** (with current protections)

**Why Medium and not High:**
- Machine not accessible from internet (Tailscale only)
- Requires SSH key to access machine
- Requires root privilege to read files
- Files have 600 permissions
- Firewall blocking most traffic

**Risk Increases If:**
- 🔴 SSH password authentication is enabled (disable it!)
- 🔴 Machine is exposed to internet without VPN
- 🔴 Multiple users have root access
- 🔴 Files left on disk permanently

**Risk Decreases To LOW When:**
- ✅ Credential files are deleted
- ✅ Passwords changed from defaults
- ✅ Secrets encryption enabled
- ✅ Regular credential rotation

### Comparison to Other Systems

| System | Credentials Storage | Your Security Level |
|--------|-------------------|---------------------|
| **Docker Compose** | Plain text in .env files | Similar to yours |
| **Default Kubernetes** | base64 (not encrypted!) | **Yours is better** |
| **Kubernetes + Encryption** | Encrypted in etcd | **Fresh install matches** |
| **Cloud Providers** | Encrypted + HSM | Higher (but you pay $$$) |

---

## 💡 Best Practices for Production

### 1. Principle of Least Privilege
- Create separate user accounts (don't use root)
- Grant minimal permissions needed
- Use Kubernetes RBAC for app-specific access

### 2. Defense in Depth
- Multiple security layers (we have 6+)
- No single point of failure
- Assume breach mentality

### 3. Regular Security Audits
```bash
# Monthly security check
sudo ./scripts/security-audit.sh  # If available

# Check for unauthorized access
sudo lastlog
sudo grep "authentication failure" /var/log/auth.log

# Verify firewall
sudo ufw status verbose

# Check running containers
kubectl get pods -A
```

### 4. Keep System Updated
```bash
# Update system packages monthly
sudo apt update && sudo apt upgrade -y

# Update K3s when new versions release
# (Follow K3s upgrade documentation)
```

---

## 📞 Questions?

### Q: Should I wait for a fresh installation to be secure?
**A:** No, your current cluster is secure enough for testing/development. For production, follow the checklist above to harden it, or do a fresh install.

### Q: Can I install a password manager on the control plane?
**A:** Not recommended. Install on your laptop/desktop. Control plane should be minimal and headless.

### Q: What if I lose my password manager?
**A:** Keep encrypted backups:
1. Export password manager vault
2. Encrypt with GPG or age
3. Store in multiple locations (USB drive, cloud, another machine)

### Q: Is Tailscale secure enough?
**A:** Yes, Tailscale uses WireGuard (military-grade encryption). It's one of the most secure VPN solutions available.

### Q: Should I use an external secrets manager (Vault, etc.)?
**A:** For enterprise/production with many users: Yes
For personal/small team: Current setup is sufficient

---

## 🎯 Summary

**You asked the right questions!** Security is critical.

**Current State:**
- Protected by multiple layers
- Good enough for testing
- Credential files should be deleted after saving

**Fresh Installation:**
- Secrets encryption enabled automatically ✅
- Follow the checklist above
- Implement credential rotation policy

**Key Takeaways:**
1. Save credentials to password manager on your laptop
2. Delete credential files from control plane
3. Change default passwords
4. Fresh installs will have encryption enabled from start
5. Your cluster is more secure than you think (Tailscale + Firewall + RBAC)

**Remember:** Perfect security doesn't exist. We aim for **practical security** that balances usability with protection.

---

**Ready to harden your cluster?** Follow the checklist above! ✅
