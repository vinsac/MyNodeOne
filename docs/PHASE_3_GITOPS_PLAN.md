# Phase 3: GitOps Integration Plan

## 🎯 **Objective**
Add GitOps layer using Flux CD while preserving dynamic ConfigMap-based registry system.

---

## 📊 **Architecture: Hybrid Approach**

```
┌─────────────────────────────────────────────────────────────┐
│                    GIT REPOSITORY                            │
│  (Static Configuration - Version Controlled)                 │
├─────────────────────────────────────────────────────────────┤
│  • Application Manifests                                     │
│  • Infrastructure Helm Charts                                │
│  • Platform Policies (RBAC, NetworkPolicy)                   │
│  • Traefik Base Config                                       │
│  • Environment Overlays (dev/prod)                           │
└────────────────────┬────────────────────────────────────────┘
                     │
                     │ Flux CD watches & syncs
                     ↓
┌─────────────────────────────────────────────────────────────┐
│              KUBERNETES CLUSTER                              │
│  (Runtime State - Dynamically Managed)                       │
├─────────────────────────────────────────────────────────────┤
│  ConfigMaps (Dynamic):                                       │
│  • sync-controller-registry (node registration)             │
│  • service-registry (auto-discovered apps)                  │
│  • domain-registry (routing + VPS mapping)                  │
│                                                              │
│  Deployed Resources (From Git):                             │
│  • Applications (demo, llm-chat, etc.)                      │
│  • Infrastructure (Traefik, ArgoCD, Grafana)                │
│  • Policies (RBAC, NetworkPolicies)                         │
└─────────────────────────────────────────────────────────────┘
                     │
                     │ Sync controller pushes routes
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                    VPS NODES                                 │
│  (Edge Infrastructure)                                       │
├─────────────────────────────────────────────────────────────┤
│  • Traefik Base Config (From Git via Flux)                  │
│  • Dynamic Routes (From ConfigMap via sync-controller)      │
│  • SSL Certificates (Let's Encrypt)                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 🗂️ **Repository Structure**

### **Option A: Monorepo (Recommended for MyNodeOne)**

```
MyNodeOne/  (existing repo)
├── apps/
│   ├── base/
│   │   ├── demo/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── ingress.yaml
│   │   │   └── kustomization.yaml
│   │   ├── llm-chat/
│   │   ├── grafana-override/
│   │   └── dashboard/
│   └── overlays/
│       ├── dev/
│       │   └── kustomization.yaml
│       └── production/
│           └── kustomization.yaml
│
├── infrastructure/
│   ├── base/
│   │   ├── traefik/
│   │   │   ├── helmrelease.yaml
│   │   │   ├── values-base.yaml
│   │   │   └── kustomization.yaml
│   │   ├── argocd/
│   │   ├── grafana-stack/
│   │   ├── longhorn/
│   │   └── minio/
│   └── overlays/
│       ├── control-plane/
│       └── vps/
│
├── platform/
│   ├── namespaces/
│   │   ├── mynodeone-system.yaml
│   │   ├── mynodeone-apps.yaml
│   │   └── kustomization.yaml
│   ├── rbac/
│   │   ├── admin-role.yaml
│   │   ├── developer-role.yaml
│   │   └── kustomization.yaml
│   └── network-policies/
│
├── clusters/
│   ├── control-plane/
│   │   ├── flux-system/
│   │   │   ├── gotk-components.yaml
│   │   │   ├── gotk-sync.yaml
│   │   │   └── kustomization.yaml
│   │   ├── apps.yaml
│   │   ├── infrastructure.yaml
│   │   └── platform.yaml
│   └── vps-nodes/
│       └── traefik-base/
│
├── scripts/  (existing - enhanced)
│   ├── bootstrap-control-plane.sh
│   ├── setup-vps-node.sh
│   └── lib/
│       ├── node-registry-manager.sh  (existing)
│       ├── sync-controller.sh  (existing)
│       └── gitops-helper.sh  (new)
│
└── docs/
    ├── GITOPS_WORKFLOW.md
    └── MIGRATION_GUIDE.md
```

### **Option B: Separate GitOps Repo**

```
mynodeone-gitops/  (new repo)
├── apps/
├── infrastructure/
├── platform/
└── clusters/

MyNodeOne/  (existing - application code only)
├── src/
├── Dockerfile
└── scripts/
```

**Recommendation:** Start with **Option A (Monorepo)** for simplicity.

---

## 🔄 **What Changes in Each Phase**

### **Current (Phase 2):**
```bash
# Deploy an app
kubectl apply -f demo-app.yaml

# Register in service registry
./scripts/lib/service-registry.sh register demo demo default demo 80 false

# Make public
./scripts/manage-app-visibility.sh
```

### **Phase 3 (GitOps):**
```bash
# 1. Commit app manifest to Git
git add apps/base/demo/
git commit -m "Add demo app"
git push

# 2. Flux auto-deploys to cluster (30 seconds)

# 3. Auto-discovery registers in ConfigMap (existing)
# Service registry watches for new LoadBalancer services

# 4. Make public (same as before)
./scripts/manage-app-visibility.sh
```

**Key Difference:** 
- ✅ Steps 1-2: Now version controlled with audit trail
- ✅ Steps 3-4: Still automatic via ConfigMaps

---

## 📝 **Migration Steps**

### **Phase 3.1: Install Flux CD (Week 1)**

**1. Bootstrap Flux on Control Plane**
```bash
# Install Flux CLI
curl -s https://fluxcd.io/install.sh | sudo bash

# Bootstrap Flux (creates flux-system namespace)
flux bootstrap github \
  --owner=vinsac \
  --repository=MyNodeOne \
  --branch=main \
  --path=clusters/control-plane \
  --personal

# Verify
flux check
kubectl get pods -n flux-system
```

**2. Create Base Structure**
```bash
mkdir -p apps/base infrastructure/base platform clusters/control-plane
```

**3. Test with One App (demo)**
```bash
# Create Kustomization for demo app
cat > apps/base/demo/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
EOF

# Let Flux deploy it
flux create kustomization demo \
  --source=GitRepository/flux-system \
  --path="./apps/base/demo" \
  --prune=true \
  --interval=5m

# Watch deployment
flux get kustomizations --watch
```

**4. Validate Auto-Discovery Still Works**
```bash
# Service should auto-register in ConfigMap
kubectl get cm service-registry -n kube-system -o jsonpath='{.data.services\.json}' | jq
```

### **Phase 3.2: Migrate Infrastructure (Week 2)**

**1. Convert Traefik to HelmRelease**
```yaml
# infrastructure/base/traefik/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: traefik
  namespace: kube-system
spec:
  interval: 5m
  chart:
    spec:
      chart: traefik
      version: 23.0.1
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    service:
      type: LoadBalancer
    # ... rest of values
```

**2. Create HelmRepository Source**
```bash
flux create source helm traefik \
  --url=https://helm.traefik.io/traefik \
  --interval=1h
```

**3. Apply HelmRelease**
```bash
flux create helmrelease traefik \
  --source=HelmRepository/traefik \
  --chart=traefik \
  --values=./infrastructure/base/traefik/values.yaml
```

### **Phase 3.3: Add Image Automation (Week 3)**

**1. Enable Image Automation**
```bash
flux create image repository demo \
  --image=ghcr.io/vinsac/mynodeone-demo \
  --interval=1m

flux create image policy demo \
  --image-ref=demo \
  --select-semver=">=1.0.0"

flux create image update demo \
  --git-repo-ref=flux-system \
  --git-repo-path="./apps/base/demo" \
  --checkout-branch=main \
  --push-branch=main \
  --author-name=fluxcdbot \
  --author-email=fluxcdbot@users.noreply.github.com \
  --commit-template="Update demo image to {{range .Updated.Images}}{{println .}}{{end}}"
```

**2. Add Image Policy Marker to Deployment**
```yaml
# apps/base/demo/deployment.yaml
spec:
  template:
    spec:
      containers:
      - name: demo
        image: ghcr.io/vinsac/mynodeone-demo:1.0.0 # {"$imagepolicy": "flux-system:demo"}
```

**Now:** Push new image → Registry → Flux detects → Git commit → Deploy

### **Phase 3.4: Multi-Environment (Week 4)**

**1. Create Production Overlay**
```yaml
# apps/overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/demo
patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 3
    target:
      kind: Deployment
      name: demo
```

**2. Create Separate Flux Kustomization for Prod**
```bash
flux create kustomization demo-prod \
  --source=GitRepository/flux-system \
  --path="./apps/overlays/production" \
  --prune=true \
  --interval=5m
```

---

## 🔐 **Secrets Management**

### **Using Mozilla SOPS with Flux**

**1. Install SOPS**
```bash
wget https://github.com/mozilla/sops/releases/download/v3.7.3/sops-v3.7.3.linux
chmod +x sops-v3.7.3.linux
sudo mv sops-v3.7.3.linux /usr/local/bin/sops
```

**2. Create GPG Key**
```bash
gpg --full-generate-key
gpg --list-secret-keys --keyid-format LONG
export SOPS_PGP_FP="YOUR_KEY_FINGERPRINT"
```

**3. Encrypt Secret**
```bash
cat > secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
  namespace: default
stringData:
  api-key: "super-secret-key"
EOF

sops --encrypt --pgp $SOPS_PGP_FP secret.yaml > secret.enc.yaml
git add secret.enc.yaml
```

**4. Configure Flux to Decrypt**
```bash
gpg --export-secret-keys --armor $SOPS_PGP_FP | \
kubectl create secret generic sops-gpg \
  --namespace=flux-system \
  --from-file=sops.asc=/dev/stdin
```

**5. Reference in Kustomization**
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: demo
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-gpg
```

---

## 🚦 **What Stays Dynamic (ConfigMaps)**

These should **NOT** be in Git:

```yaml
# ❌ Don't put these in Git - they're runtime state
- sync-controller-registry  # Nodes register dynamically
- service-registry          # Apps auto-discovered
- domain-registry           # Routing changes dynamically
```

**Why?**
- They change frequently (every app deployment, node registration)
- They're discovered automatically
- They need real-time updates
- Git commits would be noise

---

## 📊 **Comparison: Before vs After**

| Aspect | Phase 2 (Current) | Phase 3 (GitOps) |
|--------|------------------|------------------|
| **App Deployment** | `kubectl apply` | Git commit → Flux |
| **Version Control** | Manual | Automatic |
| **Audit Trail** | None | Full git history |
| **Peer Review** | None | PR required |
| **Rollback** | Manual | `git revert` |
| **Node Registry** | ConfigMap ✅ | ConfigMap ✅ |
| **Service Discovery** | ConfigMap ✅ | ConfigMap ✅ |
| **Routing** | ConfigMap ✅ | ConfigMap ✅ |
| **Infrastructure** | Manual | Flux HelmRelease |
| **Secrets** | Plain YAML | SOPS encrypted |
| **Multi-Environment** | Manual | Kustomize overlays |
| **Image Updates** | Manual | Automated |

---

## 🎯 **Benefits of Adding GitOps**

### **Developer Experience**
```bash
# Before
kubectl apply -f app.yaml
kubectl get pods --watch
# Did it work? Check manually

# After
git push origin main
# Flux handles everything, notifications to Slack
# Git history shows who deployed what when
```

### **Security**
```bash
# Before
- Developers need kubectl access to production
- Secrets in plaintext YAML
- No approval process

# After
- Developers only push to Git
- Secrets encrypted with SOPS
- PR approval required for production
```

### **Reliability**
```bash
# Before
- Cluster state drifts from Git
- No easy rollback
- Manual disaster recovery

# After
- Git is source of truth
- Rollback = git revert
- Disaster recovery = flux bootstrap + reconcile
```

---

## ⚠️ **What NOT to Do**

### **Don't GitOps Everything**
```yaml
# ❌ BAD: Managing dynamic state in Git
apiVersion: v1
kind: ConfigMap
metadata:
  name: sync-controller-registry
data:
  registry.json: |
    {
      "vps_nodes": [
        {"ip": "100.105.188.46", "last_sync": "2025-11-09T13:00:00Z"}
      ]
    }
```

Every sync would require:
1. Operator detects change
2. Modifies YAML
3. Commits to Git
4. Pushes
5. Flux pulls
6. Applies to cluster

**This is crazy!** Keep this in ConfigMaps.

### **Don't Lose Auto-Discovery**
```yaml
# ❌ BAD: Hardcoding discovered services
apiVersion: v1
kind: ConfigMap
metadata:
  name: service-registry
data:
  services.json: |
    {
      "demo": {"ip": "100.76.150.207"}  # Hardcoded!
    }
```

**Keep auto-discovery!** When LoadBalancer appears, ConfigMap updates automatically.

---

## 📅 **Timeline**

| Week | Phase | Effort | Risk |
|------|-------|--------|------|
| 1 | Install Flux, migrate 1 app | 4-6 hours | Low |
| 2 | Migrate infrastructure | 8-10 hours | Medium |
| 3 | Add image automation | 4-6 hours | Low |
| 4 | Multi-environment setup | 6-8 hours | Medium |
| **Total** | **Phase 3 Complete** | **22-30 hours** | |

---

## 🎓 **Learning Resources**

1. **Flux CD Official Docs**: https://fluxcd.io/docs/
2. **Kustomize Tutorial**: https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/
3. **SOPS Guide**: https://github.com/mozilla/sops
4. **GitOps Principles**: https://opengitops.dev/

---

## ✅ **Success Criteria**

Phase 3 is complete when:
- [ ] All apps deployed via Flux
- [ ] Infrastructure managed by HelmReleases
- [ ] Secrets encrypted with SOPS
- [ ] Image updates automated
- [ ] ConfigMap-based registries still work
- [ ] PR approval required for production
- [ ] Rollback tested successfully
- [ ] Zero manual kubectl apply commands

---

## 🎯 **Recommendation**

**Should you do Phase 3?**

**YES, but not immediately.**

**Recommended Order:**
1. ✅ **Phase 1 & 2** (Done!) - Fix current architecture
2. **Test** - Complete reinstall, verify everything works
3. **Stabilize** - Run for 2-4 weeks, fix any issues
4. **Phase 3** - Add GitOps layer incrementally

**Why wait?**
- Phase 1 & 2 fixed critical bugs
- Need to validate fixes work in production
- GitOps adds complexity (good complexity, but still complexity)
- Better to have working base before adding GitOps

**When to start Phase 3:**
- After successful reinstall
- After 2+ weeks of stable operation
- When you're ready to learn Flux CD
- When you want enterprise-grade deployment workflow

---

**Phase 3 is optional but highly recommended for production use!**
