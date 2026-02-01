# MinIO Credential Management

## Overview

MyNodeOne uses **shared credentials** across all MinIO instances in the cluster. This ensures consistent S3 API access regardless of which node you're connecting to.

---

## Architecture: Option B - Common Credentials

**Design Decision:** All MinIO instances (control plane and worker nodes) share the same admin credentials.

**Benefits:**
- Consistent S3 access across all nodes
- Single set of credentials to manage
- Easier for users and applications

**Implementation:**
- Credentials stored in Kubernetes secret: `minio-credentials` in `minio` namespace
- First MinIO installation (control plane OR worker) creates the secret
- Subsequent installations read from the secret
- Credentials persist even if MinIO pods/deployments are deleted

---

## Credential Lifecycle

### Initial Installation

**Scenario 1: Control Plane MinIO Installed First**
```bash
# Control plane bootstrap
./scripts/installation/bootstrap-control-plane.sh
# → Creates minio-credentials secret with random password

# Worker joins later
./scripts/nodes/add-worker-node.sh
# → Reads existing minio-credentials secret
# → Uses SAME credentials as control plane
```

**Scenario 2: Worker MinIO Installed First**
```bash
# Worker joins (control plane has no MinIO)
./scripts/nodes/add-worker-node.sh
# → Creates minio-credentials secret with random password

# Control plane MinIO installed later
# → Reads existing minio-credentials secret
# → Uses SAME credentials as worker
```

**Result:** Regardless of installation order, all MinIO instances share credentials.

---

## Credential Persistence

### What Happens When MinIO is Uninstalled?

**Kubernetes Secret Behavior:**
- Deleting MinIO pods/deployments does NOT delete the secret
- Secret persists in the cluster
- Reinstalling MinIO reuses the existing secret

**Example:**
```bash
# Uninstall MinIO from control plane
kubectl delete deployment minio -n minio
kubectl delete svc minio -n minio

# Secret still exists
kubectl get secret minio-credentials -n minio
# Output: minio-credentials   Opaque   2      5d

# Reinstall MinIO
./scripts/storage/minio/install-interactive.sh
# → Reads existing secret, uses SAME credentials
```

---

## Viewing Current Credentials

### From Kubernetes Secret

```bash
# View username
kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' | base64 -d
# Output: admin

# View password
kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' | base64 -d
# Output: [random password]
```

### From Local Credentials File

Each node saves credentials to a local file during MinIO installation:

```bash
# On control plane or worker
cat ~/mynodeone-minio-credentials.txt
```

**Example output:**
```
MinIO Credentials
=================

Node: canada-pc-0001
Endpoint: http://minio-canada-pc-0001.mynodeone.local:9000
Console: http://minio-canada-pc-0001.mynodeone.local:9001

Admin Credentials (shared across all nodes):
  Username: admin
  Password: xYz9K3mN8pQ2rT5vW7aB4cD

Generated: Wed Jan 8 18:30:00 UTC 2026

IMPORTANT: These credentials are shared across ALL MinIO instances in the cluster.
Each node runs a standalone MinIO instance with the same admin credentials.
```

---

## Resetting Credentials

### When to Reset

- Security breach or credential leak
- Forgot password and lost credentials file
- Want to change from default credentials

### How to Reset

**⚠️ WARNING:** This will break access to existing MinIO instances until they are reconfigured.

```bash
# Step 1: Delete the Kubernetes secret
kubectl delete secret minio-credentials -n minio

# Step 2: Reinstall MinIO on ANY node
# This will generate NEW credentials and create a new secret

# Option A: Reinstall on control plane
./scripts/storage/minio/install-interactive.sh

# Option B: Reinstall on worker
./scripts/nodes/add-worker-node.sh  # Select MinIO installation

# Step 3: Reinstall MinIO on OTHER nodes
# They will automatically read the new credentials from the secret
```

**Alternative: Manual Secret Update**

```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Update secret
kubectl create secret generic minio-credentials \
  -n minio \
  --from-literal=rootUser="admin" \
  --from-literal=rootPassword="$NEW_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart all MinIO pods to pick up new credentials
kubectl rollout restart deployment -n minio
```

---

## Troubleshooting

### Different Credentials on Different Nodes

**Symptom:** Control plane and worker have different MinIO passwords

**Cause:** Credentials were manually changed or secret was deleted/recreated

**Fix:**
```bash
# Check if secret exists
kubectl get secret minio-credentials -n minio

# If missing, reinstall MinIO on one node to create it
# Then reinstall on other nodes to sync credentials

# If exists but different, delete and recreate
kubectl delete secret minio-credentials -n minio
# Reinstall MinIO on all nodes
```

### Cannot Access MinIO After Reinstall

**Symptom:** Old credentials don't work after MinIO reinstall

**Cause:** Secret was deleted during uninstall

**Fix:**
```bash
# View current credentials from secret
kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' | base64 -d

# Update local credentials file with new password
# Or use the password from Kubernetes secret
```

### Worker Node Cannot Read Credentials

**Symptom:** Worker shows "kubectl not available" or "connection refused"

**Cause:** kubectl not configured on worker node

**Fix:**
```bash
# On worker node, verify kubectl is configured
kubectl get nodes

# If not working, reconfigure kubectl
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config

# Test access
kubectl get secret minio-credentials -n minio
```

---

## Security Best Practices

### Credential Storage

- ✅ **DO:** Keep credentials in Kubernetes secrets (encrypted at rest)
- ✅ **DO:** Save local credentials file with restricted permissions (600)
- ❌ **DON'T:** Commit credentials to git repositories
- ❌ **DON'T:** Share credentials in plain text over insecure channels

### Access Control

- MinIO credentials grant **full admin access** to all buckets
- Create separate user accounts for applications (not implemented yet)
- Use MinIO policies to restrict access per user/application

### Rotation

- Consider rotating credentials periodically (e.g., every 90 days)
- Use the reset procedure above to generate new credentials
- Update all applications and services with new credentials

---

## Related Documentation

- **Architecture:** `docs/architecture/STORAGE-ARCHITECTURE.md` (Storage design and implementation)
- **Installation:** `docs/installation/INSTALLATION.md` (kubectl configuration on workers)
- **MinIO Installer:** `scripts/storage/minio/install-interactive.sh`

---

## Quick Reference

```bash
# View credentials
kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' | base64 -d

# Reset credentials
kubectl delete secret minio-credentials -n minio
# Then reinstall MinIO

# Check credential sync across nodes
kubectl get secret minio-credentials -n minio -o yaml
```