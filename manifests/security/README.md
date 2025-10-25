# Security Manifests

This directory contains Kubernetes manifests that implement security best practices for your NodeZero cluster.

## Files

### network-policies.yaml
**Purpose:** Network segmentation and access control  
**What it does:** Implements "default deny" network policies with explicit allow rules

**Policies included:**
1. **default-deny-all** - Blocks all ingress and egress by default
2. **allow-dns** - Permits DNS queries (required for service discovery)
3. **allow-same-namespace** - Allows pods in same namespace to communicate
4. **allow-from-traefik** - Permits ingress traffic from Traefik
5. **app-network-policy-template** - Template for application-specific policies

**Benefits:**
- Prevents lateral movement after breach
- Limits blast radius of compromised pods
- Enforces least-privilege networking
- Compliance with security frameworks

---

### resource-quotas.yaml
**Purpose:** Resource management and DoS prevention  
**What it does:** Sets limits on CPU, memory, and object counts per namespace

**Quotas included:**
1. **default-quota** - Namespace-level resource limits
2. **default-limit-range** - Per-pod and per-container limits
3. **custom-namespace-quota-template** - Template for custom namespaces

**Limits:**
- CPU: 20 cores requested, 40 cores limit (default namespace)
- Memory: 40Gi requested, 80Gi limit (default namespace)
- Pods: Maximum 50 per namespace
- Storage: 100Gi total per namespace

**Benefits:**
- Prevents resource exhaustion attacks
- Fair resource allocation
- Cost control
- Cluster stability

---

### traefik-security-headers.yaml
**Purpose:** HTTP security headers and rate limiting  
**What it does:** Adds security middleware to protect web applications

**Middleware included:**
1. **security-headers** - Comprehensive HTTP security headers
2. **rate-limit** - Request rate limiting (100 req/sec, burst 50)
3. **compress** - Response compression
4. **secure-chain** - Combines all security middleware

**Headers added:**
- **HSTS** - Forces HTTPS (1 year)
- **Content-Security-Policy** - XSS protection
- **X-Frame-Options: DENY** - Clickjacking protection
- **X-Content-Type-Options: nosniff** - MIME-sniffing protection
- **Referrer-Policy** - Controls referrer information
- **Permissions-Policy** - Restricts browser features

**Benefits:**
- Protects against XSS attacks
- Prevents clickjacking
- Enforces HTTPS
- Rate limiting prevents abuse

---

## Deployment

### Automatic Deployment

All manifests are deployed automatically when you run:

```bash
sudo ./scripts/enable-security-hardening.sh
```

### Manual Deployment

```bash
# Deploy all security manifests
kubectl apply -f manifests/security/

# Or deploy individually
kubectl apply -f manifests/security/network-policies.yaml
kubectl apply -f manifests/security/resource-quotas.yaml
kubectl apply -f manifests/security/traefik-security-headers.yaml
```

---

## Usage Examples

### Using Security Headers in Your App

Add the middleware to your IngressRoute:

```yaml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: my-app
  namespace: default
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.com`)
      kind: Rule
      services:
        - name: my-app-service
          port: 80
      middlewares:
        - name: secure-chain  # <-- Add this
          namespace: traefik
  tls:
    certResolver: default
```

### Creating App-Specific Network Policy

Copy and customize the template:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from Traefik
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: 3000
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
    # Allow to backend
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 8080
    # Allow HTTPS to internet
    - ports:
        - protocol: TCP
          port: 443
```

### Custom Namespace Quota

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "50"
    requests.memory: "100Gi"
    limits.cpu: "100"
    limits.memory: "200Gi"
    pods: "100"
    services: "30"
```

---

## Verification

### Check Network Policies

```bash
# List all network policies
kubectl get networkpolicies -A

# Test connectivity (should be denied)
kubectl run test-pod --image=busybox --rm -it -- wget -O- http://google.com
# Should timeout (egress blocked by default)

# Test DNS (should work)
kubectl run test-pod --image=busybox --rm -it -- nslookup kubernetes.default
# Should resolve (DNS explicitly allowed)
```

### Check Resource Quotas

```bash
# View quota usage
kubectl describe quota -n default

# Try to exceed quota (should fail)
kubectl run big-pod --image=nginx --requests=cpu=100 -n default
# Should fail with "exceeded quota"

# View limit ranges
kubectl describe limitrange -n default
```

### Check Security Headers

```bash
# Test headers on your application
curl -I https://myapp.com

# Look for:
# Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
# X-Frame-Options: DENY
# X-Content-Type-Options: nosniff
# Content-Security-Policy: ...
```

---

## Troubleshooting

### Pods Can't Connect

**Symptom:** Pod networking not working after applying policies

**Solution:**
```bash
# Check if DNS is allowed
kubectl get networkpolicy allow-dns -n default

# Ensure same-namespace policy exists
kubectl get networkpolicy allow-same-namespace -n default

# Verify pod labels match policy selectors
kubectl get pods --show-labels
```

### Pods Rejected Due to Quota

**Symptom:** Pods fail to create with "exceeded quota" error

**Solution:**
```bash
# Check current usage
kubectl describe quota -n default

# View what's using resources
kubectl top pods -n default

# Increase quota or delete unused pods
kubectl delete pod <unused-pod>
```

### Security Headers Not Applied

**Symptom:** Headers missing from HTTP responses

**Solution:**
```bash
# Verify middleware exists
kubectl get middleware -n traefik

# Check IngressRoute references middleware
kubectl describe ingressroute my-app -n default

# Ensure middleware namespace is correct (traefik)
```

---

## Customization

### Adjust Rate Limits

Edit `traefik-security-headers.yaml`:

```yaml
spec:
  rateLimit:
    average: 200  # Increase from 100
    burst: 100    # Increase from 50
    period: 1s
```

### Relax Network Policies

For development, you can delete default-deny:

```bash
# NOT RECOMMENDED for production!
kubectl delete networkpolicy default-deny-all -n default
```

Or create a permissive namespace:

```bash
kubectl create namespace dev
# Don't apply network policies to dev namespace
```

### Adjust Resource Quotas

Edit `resource-quotas.yaml` and adjust limits based on your hardware:

```yaml
spec:
  hard:
    requests.cpu: "40"    # Adjust based on your CPUs
    requests.memory: "80Gi"  # Adjust based on your RAM
```

---

## Best Practices

1. **Network Policies:**
   - Start with default deny
   - Add explicit allow rules as needed
   - Document why each rule exists
   - Review policies quarterly

2. **Resource Quotas:**
   - Set based on actual usage patterns
   - Monitor quota utilization
   - Adjust as applications scale
   - Use LimitRanges to enforce minimums

3. **Security Headers:**
   - Apply to all public-facing apps
   - Test headers with security scanners
   - Customize CSP based on app needs
   - Enable HSTS preloading for domains

4. **Rate Limiting:**
   - Set based on expected traffic
   - Monitor rate limit hits
   - Adjust for legitimate spikes
   - Use different limits per endpoint

---

## Compliance

These security controls help meet requirements for:

- **PCI DSS:** Network segmentation, resource controls
- **HIPAA:** Access controls, audit logging
- **SOC 2:** Security policies, resource management
- **GDPR:** Data protection controls

See `docs/security-best-practices.md` for full compliance guidance.

---

## Documentation

- Security best practices: `/docs/security-best-practices.md`
- Security audit report: `/SECURITY-AUDIT.md`
- Password management: `/docs/password-management.md`
- Network policies guide: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Resource quotas guide: https://kubernetes.io/docs/concepts/policy/resource-quotas/

---

**Version:** 1.0.0  
**Last Updated:** October 25, 2025
