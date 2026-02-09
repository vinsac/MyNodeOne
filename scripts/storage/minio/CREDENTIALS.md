# MinIO Credential Management

## Overview

MyNodeOne uses **independent credentials per node** for MinIO instances. Each MinIO installation generates its own unique admin password, stored in a per-node Kubernetes namespace.

---

## Architecture: Per-Node Independent Credentials

**Design Decision:** Each MinIO instance has its own unique credentials, isolated in its own namespace.

**Benefits:**
- Security isolation between nodes
- Compromised credentials on one node don't affect others
- Independent lifecycle per installation

**Implementation:**
- Each installation generates a random 25-character password
- Credentials stored in Kubernetes secret: `minio-credentials` in namespace `minio-<nodename>`
- Also saved to local file: `~/minio-<nodename>-credentials.txt`
- Username is always `admin`

---

## Credential Lifecycle

### Installation

When `install-minio.sh` runs on a node, it:

1. Generates a unique password: `openssl rand -base64 32 | tr -d "=+/" | cut -c1-25`
2. Creates a Kubernetes secret in the per-node namespace
3. Saves credentials to a local file

```bash
# Install MinIO on a node
sudo ./scripts/storage/minio/install-minio.sh
# → Select node (e.g., canada-pc-0001)
# → Generates unique credentials
# → Creates secret in minio-canada-pc-0001 namespace
# → Saves to ~/minio-canada-pc-0001-credentials.txt
```

### Reinstallation

Reinstalling MinIO on the same node **deletes the old namespace** (including the secret) and generates **new credentials**. Always save credentials before reinstalling.

---

## Viewing Current Credentials

### From Local Credentials File

```bash
# Each node has its own credentials file
cat ~/minio-<nodename>-credentials.txt
```

**Example output:**
```
MinIO Installation on Node: canada-pc-0001
======================================

Namespace: minio-canada-pc-0001
API Domain: minio-canada-pc-0001.mynodeone.local
Console Domain: minio-console-canada-pc-0001.mynodeone.local

Credentials:
  Username: admin
  Password: AhLhJJzrMlNqTdZ0ArR9kysgg

Installed: Sun Feb  9 11:19:00 UTC 2026
```

### From Kubernetes Secret

```bash
# View username (replace <nodename> with actual node name)
kubectl get secret minio-credentials -n minio-<nodename> -o jsonpath='{.data.rootUser}' | base64 -d

# View password
kubectl get secret minio-credentials -n minio-<nodename> -o jsonpath='{.data.rootPassword}' | base64 -d
```

### List All MinIO Credentials

```bash
# Find all MinIO namespaces
kubectl get namespaces | grep minio

# View credentials for each
for ns in $(kubectl get namespaces -o name | grep minio-); do
  ns_name=$(basename "$ns")
  echo "=== $ns_name ==="
  echo -n "  User: "; kubectl get secret minio-credentials -n "$ns_name" -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d; echo
  echo -n "  Pass: "; kubectl get secret minio-credentials -n "$ns_name" -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d; echo
done
```

---

## Resetting Credentials

### When to Reset

- Security breach or credential leak
- Forgot password and lost credentials file
- Want to change credentials

### How to Reset (Per Node)

**Option 1: Reinstall MinIO** (simplest)
```bash
# This deletes everything and generates new credentials
sudo ./scripts/storage/minio/install-minio.sh
# Select the same node → confirms reinstall → new credentials generated
```

**Option 2: Manual Secret Update** (keeps data)
```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Update secret in the node's namespace
kubectl create secret generic minio-credentials \
  -n minio-<nodename> \
  --from-literal=rootUser="admin" \
  --from-literal=rootPassword="$NEW_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart MinIO pod to pick up new credentials
kubectl rollout restart statefulset/minio -n minio-<nodename>
```

---

## Troubleshooting

### Cannot Access MinIO After Reinstall

**Symptom:** Old credentials don't work

**Cause:** Reinstallation generates new credentials

**Fix:**
```bash
# View new credentials from the credentials file
cat ~/minio-<nodename>-credentials.txt

# Or from Kubernetes secret
kubectl get secret minio-credentials -n minio-<nodename> -o jsonpath='{.data.rootPassword}' | base64 -d
```

### Lost Credentials File

**Fix:** Retrieve from Kubernetes secret:
```bash
kubectl get secret minio-credentials -n minio-<nodename> -o jsonpath='{.data.rootPassword}' | base64 -d
```

---

## Security Best Practices

### Credential Storage

- ✅ **DO:** Keep credentials in Kubernetes secrets (encrypted at rest)
- ✅ **DO:** Save local credentials file with restricted permissions (600)
- ✅ **DO:** Save credentials to a password manager
- ❌ **DON'T:** Commit credentials to git repositories
- ❌ **DON'T:** Share credentials in plain text over insecure channels

### Access Control

- MinIO credentials grant **full admin access** to all buckets on that node
- Create separate user accounts for applications via the MinIO Console
- Use MinIO policies to restrict access per user/application

### Rotation

- Consider rotating credentials periodically (e.g., every 90 days)
- Use the manual secret update procedure above
- Update all applications and services with new credentials

---

## Related Documentation

- **Architecture:** `docs/architecture/STORAGE-ARCHITECTURE.md`
- **Service Discovery:** `scripts/storage/minio/SERVICE-DISCOVERY.md`
- **MinIO Installer:** `scripts/storage/minio/install-minio.sh`

---

## Quick Reference

```bash
# View credentials for a node
cat ~/minio-<nodename>-credentials.txt

# View from Kubernetes secret
kubectl get secret minio-credentials -n minio-<nodename> -o jsonpath='{.data.rootPassword}' | base64 -d

# Reset credentials (keeps data)
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
kubectl create secret generic minio-credentials \
  -n minio-<nodename> \
  --from-literal=rootUser="admin" \
  --from-literal=rootPassword="$NEW_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart statefulset/minio -n minio-<nodename>

# List all MinIO namespaces
kubectl get namespaces | grep minio
```