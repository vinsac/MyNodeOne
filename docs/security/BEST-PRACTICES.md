# Security Best Practices

Production security hardening guide for MyNodeOne deployments.

---

## What's Already Enabled

MyNodeOne includes these security features by default (no action required):

| Feature | Details |
|---------|---------|
| Secrets Encryption | AES-256 encryption at rest |
| Audit Logging | All API requests logged to `/var/log/k3s-audit.log` |
| Pod Security Standards | Baseline enforcement, restricted audit/warn |
| Firewall (UFW) | Default deny, allow SSH and Tailscale only |
| Fail2ban | SSH brute-force protection |
| Network Isolation | Services only accessible via Tailscale |

This guide covers additional hardening beyond the defaults.

---

## Quick Checklist

### After Installation

- [ ] Save credentials to password manager
- [ ] Delete credential files: `sudo shred -u /root/mynodeone-*.txt`
- [ ] Disable SSH password authentication
- [ ] Enable automatic security updates
- [ ] Verify firewall: `sudo ufw status verbose`
- [ ] Test services are only accessible via Tailscale

### Monthly

- [ ] Review audit logs
- [ ] Update K3s and Helm charts
- [ ] Rotate service credentials
- [ ] Test backup restoration

---

## Network Security

### Tailscale ACLs

Create access control lists to restrict access:

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["group:admins"],
      "dst": ["tag:k8s-control:*"]
    },
    {
      "action": "accept",
      "src": ["tag:k8s-nodes"],
      "dst": ["tag:k8s-control:6443"]
    }
  ]
}
```

### Firewall Verification

```bash
sudo ufw status verbose
```

Expected output:
```
Status: active
Default: deny (incoming), allow (outgoing)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
Anywhere on tailscale0     ALLOW IN    Anywhere
```

### SSH Hardening

Edit `/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
```

```bash
sudo systemctl restart sshd
```

---

## Authentication

### Strong Passwords

All service passwords must be:
- At least 32 characters
- Randomly generated
- Stored in a password manager
- Never shared in plaintext

### Change Default Passwords

**Grafana:**
```bash
kubectl exec -it -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o name | head -1) \
  -- grafana-cli admin reset-admin-password <NEW_PASSWORD>
```

**ArgoCD:**
```bash
argocd account update-password
```

### RBAC

Create limited service accounts for applications:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-deployer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: app-deployer-role
  namespace: default
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-deployer-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: app-deployer-role
subjects:
- kind: ServiceAccount
  name: app-deployer
  namespace: default
```

---

## Secrets Management

Secrets encryption at rest is enabled by default. For additional secrets management:

### External Secrets Operator

For production, use External Secrets Operator:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system --create-namespace
```

---

## Pod Security

### Security Context

Example secure deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: myapp:1.0
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
              - ALL
        resources:
          limits:
            cpu: "1"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
```

---

## Network Policies

### Default Deny

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Allow Specific Traffic

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

---

## Audit Logging

### Enable Kubernetes Audit

Create audit policy:

```yaml
# /etc/rancher/k3s/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    omitStages:
      - RequestReceived
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
```

Add to K3s config:
```
--kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log
--kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml
--kube-apiserver-arg=audit-log-maxage=30
--kube-apiserver-arg=audit-log-maxbackup=10
```

---

## Incident Response

### Containment

```bash
# Block suspicious IP
sudo ufw deny from <suspicious-ip>

# Disable Tailscale on compromised node
sudo tailscale down

# Cordon and drain node
kubectl cordon <node-name>
kubectl drain <node-name> --ignore-daemonsets
```

### Investigation

```bash
# Collect logs
kubectl logs -n kube-system <pod> --previous > incident-logs.txt

# Check audit logs
grep "suspicious-activity" /var/log/k3s-audit.log

# Review network connections
netstat -tulpn | grep ESTABLISHED
```

### Remediation

1. Rotate all credentials
2. Update all components
3. Patch vulnerabilities
4. Review and update security policies

### Recovery

1. Restore from clean backups
2. Re-deploy affected workloads
3. Re-join nodes to cluster
4. Document incident and update procedures

---

## Security Tools

### Trivy - Vulnerability Scanning

```bash
# Scan images
trivy image nginx:latest

# Scan cluster
trivy k8s --report summary cluster
```

### Falco - Runtime Security

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco-system --create-namespace
```

### Kube-bench - CIS Benchmark

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

---

## Monthly Security Audit

- [ ] Review firewall logs
- [ ] Check failed login attempts
- [ ] Verify all services are updated
- [ ] Test backup restoration
- [ ] Review RBAC permissions
- [ ] Scan images for vulnerabilities
- [ ] Check certificate expiration
- [ ] Review network policies
- [ ] Audit service account permissions

---

## Resources

- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/security-checklist/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)

---

## Reporting Security Issues

Report security vulnerabilities privately via GitHub Security Advisories. Do not post security issues in public GitHub issues.
