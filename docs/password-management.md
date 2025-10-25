# MyNodeOne Password & Secrets Management Guide

**Version:** 1.0.0  
**Last Updated:** October 25, 2025  
**Critical:** Read this before deploying to production

---

## ⚠️ CRITICAL: Do NOT Host Password Manager on MyNodeOne

### Why Not Self-Host?

**DO NOT install a password manager (Vaultwarden, Bitwarden, etc.) on your MyNodeOne cluster for storing MyNodeOne's own credentials.**

**Reasons:**
1. **Single Point of Failure** - If cluster is compromised, attacker gets all passwords
2. **Chicken and Egg Problem** - How do you access passwords when cluster is down?
3. **Disaster Recovery** - Can't restore cluster without passwords, can't get passwords without cluster
4. **Security Best Practice** - Never store keys to the kingdom in the kingdom itself

**Analogy:** Don't lock your house keys inside your house!

---

## ✅ Recommended Password Storage Solutions

### For Personal/Small Team (Recommended)

**1. Bitwarden (Self-Hosted Elsewhere) or Cloud**
- **Option A:** Use Bitwarden cloud ($10/year)
- **Option B:** Self-host on a **separate** VPS (not MyNodeOne)
- Open source
- Excellent security
- Browser extensions
- Mobile apps

**Cost:** $10/year or $5/month for VPS

**2. 1Password**
- Best-in-class security
- Great team features
- Excellent UX
- Secret references feature

**Cost:** $3-8/user/month

**3. KeePassXC (Offline)**
- Free and open source
- Database file you control
- Sync via Dropbox/Google Drive
- No cloud dependency

**Cost:** Free

**Recommendation:** **Bitwarden Cloud** or **1Password** for best balance of security and convenience.

---

### For Teams/Companies

**1. 1Password Teams/Business**
- Best for teams
- Shared vaults
- RBAC
- Audit logs
- Integrations

**Cost:** $8/user/month

**2. HashiCorp Vault (Enterprise)**
- For large organizations
- Dynamic secrets
- Encryption as a service
- Complex setup

**Cost:** Enterprise pricing

**3. AWS Secrets Manager / Google Secret Manager**
- If already on cloud
- Pay per secret
- Good integrations

**Cost:** $0.40/secret/month + API calls

**Recommendation:** **1Password Business** for most teams.

---

## 📋 What Passwords Need to Be Stored

### Critical Credentials (Must Store Securely)

After MyNodeOne installation, you'll have these credential files in `/root/`:

1. **mynodeone-minio-credentials.txt**
   - MinIO admin user and password
   - S3 endpoint URL
   - Console URL

2. **mynodeone-grafana-credentials.txt**
   - Grafana admin password
   - Dashboard URL

3. **mynodeone-argocd-credentials.txt**
   - ArgoCD admin password
   - GitOps URL

4. **mynodeone-join-token.txt**
   - K3s cluster join token
   - Allows adding nodes to cluster

5. **/etc/rancher/k3s/k3s.yaml** (kubeconfig)
   - Full cluster admin access
   - Most sensitive file

---

## 🔐 Proper Password Storage Workflow

### Immediately After Installation

**Step 1: Save to Password Manager**

```bash
# On your MyNodeOne control plane node

# View credentials
sudo cat /root/mynodeone-minio-credentials.txt
sudo cat /root/mynodeone-grafana-credentials.txt
sudo cat /root/mynodeone-argocd-credentials.txt
sudo cat /root/mynodeone-join-token.txt

# Copy each to your password manager
# Create entries:
# - "MyNodeOne MinIO"
# - "MyNodeOne Grafana"
# - "MyNodeOne ArgoCD"
# - "MyNodeOne Join Token"
```

**Step 2: Save Kubeconfig**

```bash
# Copy kubeconfig to your workstation
scp user@nodezer-node:~/.kube/config ~/.kube/mynodeone-config

# OR copy content and save in password manager as "MyNodeOne Kubeconfig"
cat ~/.kube/config
```

**Step 3: Delete Credential Files**

```bash
# After confirming you've saved everything
sudo rm /root/mynodeone-*.txt

# Verify deletion
sudo ls /root/mynodeone-*.txt
# Should show: No such file or directory
```

**Step 4: Secure Kubeconfig**

```bash
# Ensure restrictive permissions
chmod 600 ~/.kube/config

# Never commit to git
echo ".kube/config" >> ~/.gitignore
```

---

## 🎯 Password Manager Setup Example (Bitwarden)

### Option 1: Bitwarden Cloud (Easiest)

1. **Sign up** at https://bitwarden.com
2. **Install** browser extension
3. **Create** vault folder: "MyNodeOne Production"
4. **Add** secure notes for each credential file
5. **Enable** 2FA for Bitwarden account

**Structure:**
```
MyNodeOne Production/
├── MinIO Admin (Login item)
│   ├── Username: admin
│   ├── Password: [saved]
│   └── URL: http://10.x.x.x:9001
├── Grafana Admin (Login item)
├── ArgoCD Admin (Login item)
├── Join Token (Secure Note)
└── Kubeconfig (Secure Note)
```

### Option 2: Self-Hosted Bitwarden on Separate VPS

**DO NOT install on MyNodeOne. Use a separate $5/month VPS.**

```bash
# On a SEPARATE VPS (not MyNodeOne!)
# Using Vaultwarden (lightweight Bitwarden)

# Install Docker
curl -fsSL https://get.docker.com | sh

# Run Vaultwarden
docker run -d --name vaultwarden \
  -v /vw-data/:/data/ \
  -p 80:80 \
  vaultwarden/server:latest

# Setup reverse proxy with SSL (use Caddy for simplicity)
# Point domain to this VPS
# Access at https://passwords.yourdomain.com
```

**Cost:** $5/month VPS  
**Benefit:** Full control, no recurring fees

---

## 🔄 Password Rotation Schedule

### Monthly Rotation (Recommended)

**Week 1: MinIO**
```bash
# Generate new password
NEW_PASS=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)

# Update MinIO
kubectl set env deployment/minio -n minio \
  MINIO_ROOT_PASSWORD=$NEW_PASS

# Update Kubernetes secret
kubectl create secret generic minio-credentials \
  --from-literal=rootPassword="$NEW_PASS" \
  --namespace minio \
  --dry-run=client -o yaml | kubectl apply -f -

# Save new password to password manager
# Delete NEW_PASS variable
unset NEW_PASS
```

**Week 2: ArgoCD**
```bash
# Use ArgoCD CLI
argocd account update-password \
  --current-password <old> \
  --new-password <new>

# Save to password manager
```

**Week 3: Grafana**
```bash
kubectl exec -it -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o name) \
  -- grafana-cli admin reset-admin-password <new-password>

# Save to password manager
```

**Week 4: Review & Audit**
- Check password manager for any weak passwords
- Review who has access
- Verify 2FA is enabled
- Test password recovery process

---

## 🛡️ Additional Security Measures

### 1. Enable 2FA on Password Manager

**Critical:** Always enable two-factor authentication on your password manager.

**Options:**
- Authenticator app (recommended): Authy, Google Authenticator
- Hardware key: YubiKey, Titan
- Biometric: Fingerprint, Face ID (mobile)

### 2. Master Password Best Practices

Your password manager master password should be:
- **At least 20 characters**
- **Unique** (never used elsewhere)
- **Memorable** (use passphrase method)
- **Never written down** (except offline in safe)

**Example Good Passphrase:**
```
correct-horse-battery-staple-purple-elephant-7392
```

### 3. Emergency Access

**Set up emergency access** in your password manager:
- Designate trusted person
- Set wait period (7-14 days)
- They can access if you're unavailable

**For 1Password:** Family/Team emergency access  
**For Bitwarden:** Emergency access feature  

### 4. Backup Your Password Database

**If using KeePassXC:**
```bash
# Backup database file
cp ~/Passwords.kdbx ~/Backups/Passwords-$(date +%Y%m%d).kdbx

# Store backup in different location
# - Different computer
# - USB drive in safe
# - Encrypted cloud storage
```

**If using cloud password manager:**
- They handle backups
- Export periodically as insurance
- Store encrypted export offline

---

## 🚫 What NOT to Do

### ❌ Never Do These

1. **Store passwords in plain text files**
   ```bash
   # BAD!
   echo "password123" > passwords.txt
   ```

2. **Commit passwords to Git**
   ```bash
   # BAD!
   git add .env
   git commit -m "added passwords"
   ```

3. **Email passwords**
   - Email is not encrypted
   - Stays in sent folder forever
   - Can be forwarded

4. **Use weak passwords**
   - "admin"
   - "password123"
   - "mynodeone2024"

5. **Reuse passwords across services**
   - If one is compromised, all are

6. **Share passwords in Slack/Discord**
   - Messages are stored
   - Can be searched
   - Not secure

7. **Store in browser without master password**
   - Anyone with access to your computer can see them

8. **Write on sticky notes**
   - Physical security breach risk

---

## 🎓 Kubernetes Secrets Best Practices

### For Application Secrets (Not MyNodeOne Infrastructure)

**Option 1: Sealed Secrets (GitOps-Friendly)**

```bash
# Install Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Encrypt a secret
echo -n 'my-secret-password' | \
  kubectl create secret generic my-secret \
    --dry-run=client \
    --from-file=password=/dev/stdin \
    -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml

# Safe to commit sealed-secret.yaml to Git
# Only cluster can decrypt
```

**Option 2: External Secrets Operator**

```bash
# Install External Secrets Operator
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace

# Reference secrets from external source (1Password, AWS, etc.)
```

**Option 3: SOPS (Mozilla)**

```bash
# Encrypt files with SOPS
sops -e secrets.yaml > secrets.enc.yaml

# Commit encrypted file
# Decrypt at deployment time
```

---

## 📊 Password Storage Comparison

| Solution | Cost | Security | Ease of Use | Team Features | Recommendation |
|----------|------|----------|-------------|---------------|----------------|
| **1Password** | $8/user/mo | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ✅ Best for teams |
| **Bitwarden Cloud** | $10/year | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ✅ Best value |
| **KeePassXC** | Free | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐ | ✅ Best for offline |
| **Vaultwarden (self-hosted)** | $5/mo VPS | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ | ⚠️ Separate VPS only |
| **HashiCorp Vault** | $$$$ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ | Enterprise only |
| **Browser built-in** | Free | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐ | ❌ Not recommended |
| **Plain text file** | Free | ⭐ | ⭐⭐⭐⭐⭐ | ⭐ | ❌ Never do this |

---

## ✅ Quick Start Checklist

### After Installing MyNodeOne

- [ ] Choose password manager (Bitwarden or 1Password recommended)
- [ ] Create account and enable 2FA
- [ ] Create "MyNodeOne Production" folder/vault
- [ ] Save MinIO credentials
- [ ] Save Grafana credentials
- [ ] Save ArgoCD credentials
- [ ] Save join token
- [ ] Save kubeconfig
- [ ] Delete /root/mynodeone-*.txt files
- [ ] Test password retrieval
- [ ] Set up emergency access
- [ ] Schedule monthly password rotation

---

## 🆘 Emergency Recovery

### "I Lost All My Passwords!"

**If you lose access to your password manager:**

1. **MinIO/Grafana/ArgoCD:** Passwords are in Kubernetes secrets
   ```bash
   # If you still have cluster access
   kubectl get secret -n minio minio-credentials -o jsonpath='{.data.rootPassword}' | base64 -d
   kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
   ```

2. **Kubeconfig:** Still on your workstation at `~/.kube/config`

3. **No cluster access:** You'll need to rebuild from backups

**Prevention:** This is why you backup your password database!

---

## 📞 Support

**Questions about password management?**
- Review this guide thoroughly first
- Check password manager's documentation
- For MyNodeOne-specific questions: GitHub Discussions

**Security issues with passwords?**
- Rotate immediately
- Follow incident response in docs/security-best-practices.md
- Report via GitHub Security Advisories

---

## 🎯 Summary

**DO:**
- ✅ Use established password manager (1Password, Bitwarden)
- ✅ Enable 2FA on password manager
- ✅ Save all credentials immediately after install
- ✅ Delete credential files from server
- ✅ Rotate passwords monthly
- ✅ Backup password database

**DON'T:**
- ❌ Self-host password manager on MyNodeOne
- ❌ Store passwords in plain text
- ❌ Commit passwords to Git
- ❌ Share passwords insecurely
- ❌ Use weak passwords
- ❌ Skip 2FA

**Remember:** Your MyNodeOne cluster is only as secure as your password management practices!

---

**Document Version:** 1.0  
**Author:** Vinay Sachdeva  
**Last Updated:** October 25, 2025
