# Password Management Guide

This guide covers proper password storage for MyNodeOne credentials.

---

## Do Not Self-Host Password Manager on MyNodeOne

Never install a password manager (Vaultwarden, Bitwarden, etc.) on your MyNodeOne cluster for storing MyNodeOne's own credentials.

**Reasons:**
- **Single point of failure** - If cluster is compromised, attacker gets all passwords
- **Chicken and egg problem** - Cannot access passwords when cluster is down
- **Disaster recovery** - Cannot restore cluster without passwords, cannot get passwords without cluster

---

## Recommended Solutions

### Personal Use

| Solution | Cost | Notes |
|----------|------|-------|
| Bitwarden Cloud | $10/year | Open source, excellent security |
| 1Password | $3/month | Best UX, great for families |
| KeePassXC | Free | Offline, you control the database file |

### Teams

| Solution | Cost | Notes |
|----------|------|-------|
| 1Password Business | $8/user/month | Shared vaults, RBAC, audit logs |
| Bitwarden Teams | $4/user/month | Open source alternative |
| HashiCorp Vault | Enterprise | For large organizations |

---

## Credentials to Store

After MyNodeOne installation, save these from `/root/`:

| File | Contents |
|------|----------|
| `mynodeone-minio-credentials.txt` | MinIO admin user and password |
| `mynodeone-grafana-credentials.txt` | Grafana admin password |
| `mynodeone-argocd-credentials.txt` | ArgoCD admin password |
| `mynodeone-join-token.txt` | K3s cluster join token |

Also save your kubeconfig:
```bash
cat ~/.kube/config
```

---

## Storage Workflow

### Step 1: Save to Password Manager

```bash
# View credentials
sudo cat /root/mynodeone-minio-credentials.txt
sudo cat /root/mynodeone-grafana-credentials.txt
sudo cat /root/mynodeone-argocd-credentials.txt
sudo cat /root/mynodeone-join-token.txt
```

Create entries in your password manager:
- MyNodeOne MinIO
- MyNodeOne Grafana
- MyNodeOne ArgoCD
- MyNodeOne Join Token
- MyNodeOne Kubeconfig

### Step 2: Delete Credential Files

```bash
# After confirming credentials are saved
sudo shred -u /root/mynodeone-minio-credentials.txt
sudo shred -u /root/mynodeone-grafana-credentials.txt
sudo shred -u /root/mynodeone-argocd-credentials.txt
# Keep join token if adding worker nodes
```

### Step 3: Secure Kubeconfig

```bash
chmod 600 ~/.kube/config
echo ".kube/config" >> ~/.gitignore
```

---

## Password Rotation

Rotate credentials monthly:

**MinIO:**
```bash
NEW_PASS=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)

kubectl set env deployment/minio -n minio MINIO_ROOT_PASSWORD=$NEW_PASS

kubectl create secret generic minio-credentials \
  --from-literal=rootPassword="$NEW_PASS" \
  --namespace minio \
  --dry-run=client -o yaml | kubectl apply -f -

unset NEW_PASS
```

**ArgoCD:**
```bash
argocd account update-password \
  --current-password <old> \
  --new-password <new>
```

**Grafana:**
```bash
kubectl exec -it -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o name) \
  -- grafana-cli admin reset-admin-password <new-password>
```

---

## Password Manager Security

### Enable 2FA

Always enable two-factor authentication on your password manager:
- Authenticator app (Authy, Google Authenticator)
- Hardware key (YubiKey)

### Master Password

Your master password should be:
- At least 20 characters
- Unique (never used elsewhere)
- Memorable (use passphrase method)

Example passphrase: `correct-horse-battery-staple-purple-7392`

### Emergency Access

Set up emergency access in your password manager:
- Designate a trusted person
- Set wait period (7-14 days)
- They can access if you are unavailable

### Backup

If using KeePassXC:
```bash
cp ~/Passwords.kdbx ~/Backups/Passwords-$(date +%Y%m%d).kdbx
```

Store backup in a different location (USB drive, encrypted cloud storage).

---

## What Not to Do

- Store passwords in plain text files
- Commit passwords to Git
- Email passwords
- Use weak or reused passwords
- Share passwords in Slack/Discord
- Write passwords on sticky notes

---

## Emergency Recovery

If you lose access to your password manager:

```bash
# If you still have cluster access, retrieve from Kubernetes secrets
kubectl get secret -n minio minio-credentials -o jsonpath='{.data.rootPassword}' | base64 -d
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Kubeconfig is still on your workstation at `~/.kube/config`.

If you have no cluster access, you will need to rebuild from backups.

---

## Kubernetes Secrets for Applications

For application secrets (not MyNodeOne infrastructure), consider:

**Sealed Secrets (GitOps-friendly):**
```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

echo -n 'my-secret' | kubectl create secret generic my-secret \
  --dry-run=client --from-file=password=/dev/stdin -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml
```

**External Secrets Operator:**
```bash
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace
```

---

## Related Documentation

- [SECURITY.md](SECURITY.md) - Security overview
- [BEST-PRACTICES.md](BEST-PRACTICES.md) - Production hardening
