# Security Configuration Files

This directory contains Kubernetes security configuration files that enhance the security posture of your NodeZero cluster.

## Files

### audit-policy.yaml
**Purpose:** Kubernetes audit logging policy  
**What it does:** Defines what events are logged by the Kubernetes API server  
**Usage:** Copied to `/etc/rancher/k3s/audit-policy.yaml` by `enable-security-hardening.sh`

**Features:**
- Logs all pod, service account, and secret operations
- Tracks RBAC changes
- Captures authentication failures
- 30-day retention with log rotation
- Filters out noisy system operations

**Logs location:** `/var/log/k3s-audit.log`

---

### encryption-config.yaml.template
**Purpose:** Secrets encryption at rest configuration  
**What it does:** Encrypts all Kubernetes secrets in the etcd database  
**Usage:** Template that requires key generation before use

**Setup:**
```bash
# Generate encryption key
head -c 32 /dev/urandom | base64

# Replace <GENERATED_KEY> in template with output
# Copy to /etc/rancher/k3s/encryption-config.yaml
```

**Security:** Uses AES-CBC encryption. Protects secrets even if etcd database is compromised.

---

### pod-security-config.yaml
**Purpose:** Pod Security Standards enforcement  
**What it does:** Enforces "restricted" security profile on all pods  
**Usage:** Copied to `/etc/rancher/k3s/pod-security-config.yaml` by `enable-security-hardening.sh`

**Features:**
- Prevents privileged containers
- Blocks dangerous Linux capabilities
- Enforces read-only root filesystems
- Requires non-root users
- System namespaces exempted for necessary services

---

## Automatic Deployment

All these configurations are automatically deployed when you run:

```bash
sudo ./scripts/enable-security-hardening.sh
```

This script:
1. Copies configuration files to `/etc/rancher/k3s/`
2. Updates K3s configuration
3. Restarts K3s to apply changes
4. Verifies everything is working

---

## Manual Deployment

If you prefer manual control:

```bash
# Copy files
sudo cp audit-policy.yaml /etc/rancher/k3s/
sudo cp pod-security-config.yaml /etc/rancher/k3s/

# Generate and setup encryption
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
sed "s/<GENERATED_KEY>/$ENCRYPTION_KEY/" encryption-config.yaml.template | \
  sudo tee /etc/rancher/k3s/encryption-config.yaml
sudo chmod 600 /etc/rancher/k3s/encryption-config.yaml

# Edit K3s config: /etc/rancher/k3s/config.yaml
# Add these lines:
kube-apiserver-arg:
  - "audit-log-path=/var/log/k3s-audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"
  - "admission-control-config-file=/etc/rancher/k3s/pod-security-config.yaml"

# Restart K3s
sudo systemctl restart k3s
```

---

## Verification

```bash
# Check audit logs are being written
tail -f /var/log/k3s-audit.log

# Verify secrets encryption
# Create a test secret
kubectl create secret generic test-secret --from-literal=key=value
# Check etcd (should be encrypted)
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/default/test-secret

# Test pod security standards
# Try to create privileged pod (should be blocked)
kubectl run test --image=nginx --privileged=true
# Should fail with admission error
```

---

## Troubleshooting

**K3s won't start after applying configs:**
```bash
# Check K3s logs
sudo journalctl -u k3s -f

# Common issues:
# - Invalid YAML syntax
# - Missing configuration file
# - Incorrect file permissions (should be 600 for encryption config)
```

**Audit logs not appearing:**
```bash
# Verify audit policy is loaded
sudo cat /etc/rancher/k3s/config.yaml | grep audit

# Check log file permissions
ls -la /var/log/k3s-audit.log

# Ensure log directory exists
sudo mkdir -p /var/log
```

**Pod security blocking legitimate pods:**
```bash
# Add namespace to exemptions in pod-security-config.yaml
# Or label namespace to use different policy:
kubectl label namespace my-namespace pod-security.kubernetes.io/enforce=baseline
```

---

## Security Best Practices

1. **Audit Logs:**
   - Review regularly for suspicious activity
   - Set up log forwarding to centralized logging
   - Create alerts for security-relevant events
   - Retain logs for compliance requirements

2. **Encryption Keys:**
   - Generate strong random keys (32 bytes)
   - Never commit keys to version control
   - Rotate encryption keys periodically
   - Backup keys securely offline

3. **Pod Security:**
   - Use "restricted" profile by default
   - Only exempt namespaces that truly need it
   - Regularly review exemptions
   - Test applications comply with restrictions

---

## Documentation

- Full security guide: `/docs/security-best-practices.md`
- Security audit report: `/SECURITY-AUDIT.md`
- Password management: `/docs/password-management.md`

---

**Version:** 1.0.0  
**Last Updated:** October 25, 2025
