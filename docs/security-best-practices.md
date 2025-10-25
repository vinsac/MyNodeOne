# NodeZero Security Best Practices

**Version:** 1.0.0  
**Last Updated:** October 25, 2025  
**Audience:** System Administrators and DevOps Teams

---

## 🔒 Overview

This guide provides security best practices for deploying and maintaining NodeZero in production environments. Following these guidelines will significantly reduce your security risk.

---

## 🎯 Quick Security Checklist

### Immediate Actions (After Installation)

- [ ] Save all credentials from `/root/nodezero-*.txt` files to a password manager
- [ ] Delete credential files after saving: `rm /root/nodezero-*.txt`
- [ ] Change default SSH port (optional but recommended)
- [ ] Enable automatic security updates
- [ ] Review firewall rules: `sudo ufw status verbose`
- [ ] Test that services are only accessible via Tailscale

### First Week

- [ ] Set up backup encryption
- [ ] Configure log aggregation and monitoring alerts
- [ ] Review RBAC permissions
- [ ] Enable audit logging
- [ ] Document your security procedures

### Monthly

- [ ] Review audit logs for suspicious activity
- [ ] Update all components (K3s, Helm charts)
- [ ] Rotate service credentials
- [ ] Review and update firewall rules
- [ ] Test backup restoration

---

## 🛡️ Defense in Depth Strategy

### Layer 1: Network Security

#### Tailscale Configuration

**Best Practices:**
```bash
# Enable key expiry
tailscale set --advertise-exit-node --advertise-routes=192.168.1.0/24

# Disable key expiry only for production nodes (be careful!)
# tailscale set --advertise-exit-node --advertise-routes=192.168.1.0/24 --ssh
```

**Access Control Lists (ACLs):**
Create tailscale ACLs to restrict access:
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

#### Firewall Configuration

**Verify Firewall Status:**
```bash
sudo ufw status verbose
```

**Expected Output:**
```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
Anywhere on tailscale0     ALLOW IN    Anywhere
```

**Harden SSH:**
```bash
# Edit /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2

# Restart SSH
sudo systemctl restart sshd
```

---

### Layer 2: Authentication & Authorization

#### Strong Passwords

**All service passwords must be:**
- At least 32 characters
- Randomly generated
- Stored in a password manager (1Password, Bitwarden, etc.)
- Never shared in plaintext

**Change Default Passwords:**

```bash
# Grafana
kubectl exec -it -n monitoring \
  $(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o name | head -1) \
  -- grafana-cli admin reset-admin-password <NEW_STRONG_PASSWORD>

# ArgoCD
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "<bcrypt_hash_of_new_password>",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'
```

#### RBAC Hardening

**Create Limited Service Accounts:**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-deployer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind:Role
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

#### Certificate Management

**Automatic Rotation:**
cert-manager handles this automatically. Verify:
```bash
kubectl get certificates -A
```

**Manual Certificate Check:**
```bash
# Check certificate expiry
kubectl get secret -n cert-manager \
  -o jsonpath='{.items[0].data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | grep "Not After"
```

---

### Layer 3: Secrets Management

#### Kubernetes Secrets Best Practices

**Encrypt Secrets at Rest:**

Create encryption config:
```yaml
# /etc/rancher/k3s/encryption.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <BASE64_ENCODED_32_BYTE_KEY>
      - identity: {}
```

Generate encryption key:
```bash
head -c 32 /dev/urandom | base64
```

Add to K3s config:
```yaml
encryption-config: /etc/rancher/k3s/encryption.yaml
```

#### External Secrets Operator (Recommended)

For production, use External Secrets Operator:
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace
```

#### Sealed Secrets (Alternative)

For GitOps workflows:
```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml
```

---

### Layer 4: Pod Security

#### Pod Security Standards

**Enable Restricted Policy:**

```yaml
# /etc/rancher/k3s/pss-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "restricted"
        audit: "restricted"
        warn: "restricted"
      exemptions:
        namespaces:
          - kube-system
          - longhorn-system
          - metallb-system
```

Add to K3s:
```bash
--kube-apiserver-arg=admission-control-config-file=/etc/rancher/k3s/pss-config.yaml
```

#### Security Contexts

**Example Secure Deployment:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
spec:
  replicas: 3
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

### Layer 5: Network Policies

#### Default Deny All

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

#### Allow Specific Traffic

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

## 🔍 Monitoring & Auditing

### Enable Kubernetes Audit Logging

**Create Audit Policy:**

```yaml
# /etc/rancher/k3s/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log failed requests at Request level
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    omitStages:
      - RequestReceived
  # Log secrets access
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  # Don't log read-only URLs
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
```

**Enable in K3s:**
```bash
--kube-apiserver-arg=audit-log-path=/var/log/k3s-audit.log
--kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml
--kube-apiserver-arg=audit-log-maxage=30
--kube-apiserver-arg=audit-log-maxbackup=10
--kube-apiserver-arg=audit-log-maxsize=100
```

### Security Alerts

**Grafana Alerts for Security Events:**

1. Failed authentication attempts
2. Unauthorized API calls
3. Pod security policy violations
4. Unusual network traffic
5. Resource exhaustion

**Example Alert:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-alert-rules
  namespace: monitoring
data:
  alert-rules.yaml: |
    groups:
      - name: security
        interval: 1m
        rules:
          - alert: FailedAuthAttempts
            expr: rate(apiserver_audit_requests_total{verb="authenticate"}[5m]) > 10
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "High rate of failed authentication attempts"
```

---

## 🔐 Credential Rotation

### Monthly Rotation Schedule

**Week 1:** MinIO credentials
```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)

# Update MinIO
kubectl set env deployment/minio -n minio \
  MINIO_ROOT_PASSWORD=$NEW_PASSWORD

# Update secret
kubectl create secret generic minio-credentials \
  --from-literal=rootPassword="$NEW_PASSWORD" \
  --namespace minio \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Week 2:** ArgoCD password
```bash
# Use ArgoCD CLI
argocd account update-password
```

**Week 3:** Grafana password
```bash
kubectl exec -it -n monitoring <grafana-pod> -- \
  grafana-cli admin reset-admin-password <new-password>
```

**Week 4:** Review and update service tokens

---

## 🚨 Incident Response

### Security Incident Playbook

**1. Detection:**
- Monitor audit logs
- Check Grafana dashboards
- Review failed login attempts

**2. Containment:**
```bash
# Immediately isolate affected nodes
sudo ufw deny from <suspicious-ip>

# Disable Tailscale on compromised node
sudo tailscale down

# Cordon node in Kubernetes
kubectl cordon <node-name>

# Drain workloads
kubectl drain <node-name> --ignore-daemonsets
```

**3. Investigation:**
```bash
# Collect logs
kubectl logs -n kube-system <pod> --previous > incident-logs.txt

# Check audit logs
grep "suspicious-activity" /var/log/k3s-audit.log

# Review network connections
netstat -tulpn | grep ESTABLISHED
```

**4. Remediation:**
- Rotate ALL credentials
- Update all components
- Patch vulnerabilities
- Review and update security policies

**5. Recovery:**
- Restore from clean backups
- Re-deploy affected workloads
- Re-join nodes to cluster

**6. Post-Incident:**
- Document what happened
- Update procedures
- Team training
- Implement additional controls

---

## 🔧 Security Tools

### Recommended Tools

**1. Trivy - Vulnerability Scanning**
```bash
# Scan images
trivy image nginx:latest

# Scan cluster
trivy k8s --report summary cluster
```

**2. Falco - Runtime Security**
```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco \
  --namespace falco-system \
  --create-namespace
```

**3. Kube-bench - CIS Benchmark**
```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

**4. OPA Gatekeeper - Policy Enforcement**
```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/master/deploy/gatekeeper.yaml
```

---

## 📋 Compliance

### Common Compliance Frameworks

**GDPR:**
- ✅ Data encryption at rest and in transit
- ✅ Audit logging of data access
- ✅ Data retention policies
- ✅ Right to deletion (data purging)

**HIPAA:**
- ⚠️ Requires Business Associate Agreement
- ⚠️ Additional encryption requirements
- ⚠️ Strict access controls
- ⚠️ Comprehensive audit logs

**SOC 2:**
- ⚠️ Formal change management
- ⚠️ Incident response procedures
- ⚠️ Regular security reviews
- ⚠️ Third-party audits

**PCI DSS:**
- ❌ Not recommended without dedicated security team
- ❌ Requires extensive additional controls

---

## ✅ Security Verification

### Monthly Security Audit Checklist

- [ ] Review firewall logs for unusual activity
- [ ] Check for failed login attempts
- [ ] Verify all services are updated
- [ ] Test backup restoration
- [ ] Review RBAC permissions
- [ ] Scan images for vulnerabilities
- [ ] Check certificate expiration dates
- [ ] Review network policies
- [ ] Audit service account permissions
- [ ] Test disaster recovery procedures

---

## 📚 Additional Resources

- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/security-checklist/)
- [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
- [OWASP Kubernetes Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Kubernetes_Security_Cheat_Sheet.html)
- [NSA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF)

---

## 🆘 Getting Help

**Security Issues:**
- Report security vulnerabilities privately via GitHub Security Advisories
- DO NOT post security issues in public GitHub issues

**General Security Questions:**
- Check [FAQ.md](../FAQ.md)
- Review [SECURITY-AUDIT.md](../SECURITY-AUDIT.md)
- Ask in GitHub Discussions

---

**Remember:** Security is a continuous process, not a one-time setup. Regular reviews and updates are essential.

---

**Document Version:** 1.0  
**Last Updated:** October 25, 2025  
**Next Review:** January 25, 2026
