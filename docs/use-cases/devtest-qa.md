# Dev/Test/QA Environments

**Unlimited Development Environments at Zero Marginal Cost**

---

## 🎯 Overview

### The Challenge

Engineering teams face escalating cloud costs for development:

**Cost Problems:**
- AWS/GCP dev accounts: $2K-$5K/month per team
- Each developer needs isolated environment
- QA environments multiply costs
- Integration testing requires production-scale
- Costs scale with team growth

**Resource Limitations:**
- Cloud quotas limit environments
- Waiting for environment provisioning
- Resource contention
- Limited experiment freedom

**Production Parity:**
- Dev differs from production
- "Works on my machine" syndrome
- Integration issues caught late
- Kubernetes version mismatches

**Typical Cloud Costs:**
- 10 developers × $300/month = $3,000/month
- QA environments (3×) = $2,000/month
- Integration testing = $1,500/month
- **Total: $6,500/month = $78,000/year**

### The MyNodeOne Solution

**Unlimited namespaces, one-time hardware cost**

**Investment:** $3K-$10K hardware  
**Monthly cost:** $50 (electricity)  
**Savings:** $75K+/year

---

## 🏗️ Architecture

### Development Cluster Layout

```
┌──────────────────────────────────────────────────────────┐
│  MyNodeOne Dev/Test Cluster                              │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Control Plane (8GB RAM, 4 CPU)                          │
│  ├── ArgoCD (GitOps deployments)                        │
│  ├── Gitlab/Gitea (Code repos)                          │
│  ├── Harbor (Container registry)                         │
│  └── Tekton/Argo Workflows (CI/CD)                      │
│                                                          │
│  Worker Nodes (3× 16GB RAM, 8 CPU each)                 │
│  ├── dev-alice (namespace)                              │
│  ├── dev-bob (namespace)                                │
│  ├── dev-carol (namespace)                              │
│  ├── qa-staging (namespace)                             │
│  ├── qa-integration (namespace)                         │
│  ├── qa-performance (namespace)                         │
│  ├── feature-login-redesign (namespace)                 │
│  ├── feature-api-v2 (namespace)                         │
│  └── ... unlimited more                                 │
│                                                          │
│  Shared Services                                         │
│  ├── PostgreSQL (dev databases)                         │
│  ├── Redis (caching)                                    │
│  ├── MinIO (S3 testing)                                 │
│  ├── Monitoring (Grafana)                               │
│  └── Logging (Loki)                                     │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### Namespace Strategy

**Per-Developer Environments:**
```
dev-{username}       # Personal sandbox
qa-{feature}         # Feature testing
integration-{pr}     # PR testing
performance-test     # Load testing
```

**Automatic Provisioning:**
- Create namespace on git push
- Deploy via ArgoCD
- Assign subdomain
- Ready in < 2 minutes

---

## 🚀 Implementation Guide

### Phase 1: Hardware Setup (Day 1)

**Recommended Hardware:**

**Budget Option** ($3K total):
- 1 control plane: NUC or mini PC (8GB RAM)
- 2 worker nodes: Used Dell/HP workstations (16GB each)
- Cost: ~$3,000

**Production Option** ($10K total):
- 1 control plane: Server (32GB RAM)
- 3 worker nodes: Servers (64GB RAM each)
- Cost: ~$10,000

**Install MyNodeOne:**
```bash
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/bootstrap-control-plane.sh
```

### Phase 2: CI/CD Setup (Day 1-2)

**Deploy GitLab (Code Hosting):**

```bash
# Install GitLab
helm repo add gitlab https://charts.gitlab.io/
helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  --create-namespace \
  --set global.hosts.domain=mynodeone.local \
  --set global.edition=ce \
  --set certmanager.install=false \
  --set nginx-ingress.enabled=false \
  --set gitlab-runner.install=true
```

**Or use Gitea** (lighter weight):
```bash
sudo ./scripts/apps/install-gitea.sh
# Access at: http://gitea.mynodeone.local
```

**Configure ArgoCD** (Already installed):
```bash
# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Access: https://argocd.mynodeone.local
```

**Deploy Tekton** (CI Pipeline):
```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Dashboard
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

### Phase 3: Developer Environments (Day 2-3)

**Create Developer Template:**

```yaml
# templates/dev-environment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev-${USERNAME}
  labels:
    environment: development
    owner: ${USERNAME}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: dev-quota
  namespace: dev-${USERNAME}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    persistentvolumeclaims: "5"
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dev-network-policy
  namespace: dev-${USERNAME}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: dev-${USERNAME}
  egress:
  - to:
    - namespaceSelector: {}
```

**Provisioning Script:**

```bash
#!/bin/bash
# scripts/provision-dev-env.sh

USERNAME=$1

# Create namespace
envsubst < templates/dev-environment.yaml | kubectl apply -f -

# Deploy database
kubectl create secret generic dev-db-secret \
  --from-literal=password=$(openssl rand -base64 32) \
  -n dev-${USERNAME}

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: dev-${USERNAME}
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: dev-db-secret
              key: password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      resources:
        requests:
          storage: 10Gi
EOF

# Configure subdomain
echo "Dev environment ready at: http://dev-${USERNAME}.mynodeone.local"
```

**Usage:**
```bash
# Provision environment for Alice
./scripts/provision-dev-env.sh alice

# Alice can now deploy
kubectl config set-context --current --namespace=dev-alice
kubectl apply -f my-app.yaml
```

### Phase 4: QA Environments (Day 3-4)

**Create QA Pipeline:**

```yaml
# qa-pipeline.yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: qa-deploy
spec:
  params:
  - name: git-url
  - name: git-revision
  - name: environment
  tasks:
  - name: clone
    taskRef:
      name: git-clone
    params:
    - name: url
      value: $(params.git-url)
    - name: revision
      value: $(params.git-revision)
  
  - name: build
    taskRef:
      name: buildah
    runAfter:
    - clone
  
  - name: deploy-to-qa
    taskRef:
      name: deploy
    runAfter:
    - build
    params:
    - name: environment
      value: $(params.environment)
```

**Automated QA Deploy:**

```bash
# On PR creation, webhook triggers:
tkn pipeline start qa-deploy \
  --param git-url=https://gitea.mynodeone.local/myapp.git \
  --param git-revision=pr-123 \
  --param environment=qa-pr-123 \
  --namespace qa
```

**QA Environment Features:**
- Isolated per PR
- Production-like data (anonymized)
- Full monitoring stack
- Automated tests
- Auto-cleanup after PR merge

### Phase 5: Integration Testing (Day 4-5)

**Deploy Test Database:**

```yaml
# integration-db.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: test-db
  namespace: integration
spec:
  serviceName: test-db
  replicas: 1
  selector:
    matchLabels:
      app: test-db
  template:
    metadata:
      labels:
        app: test-db
    spec:
      containers:
      - name: postgresql
        image: postgres:15-alpine
        env:
        - name: POSTGRES_DB
          value: testdb
        - name: POSTGRES_PASSWORD
          value: testpassword  # OK for integration tests
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Gi
```

**Integration Test Runner:**

```yaml
# integration-tests.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: integration-test-{{ .Values.prNumber }}
  namespace: integration
spec:
  template:
    spec:
      containers:
      - name: test-runner
        image: myapp-tests:latest
        env:
        - name: DB_HOST
          value: test-db.integration.svc.cluster.local
        - name: API_URL
          value: http://api-pr-{{ .Values.prNumber }}.integration.svc.cluster.local
        command:
        - pytest
        - --junitxml=results.xml
        - tests/integration/
      restartPolicy: Never
  backoffLimit: 0
```

---

## 📊 Workflows

### Daily Developer Workflow

**1. Morning (Get Fresh Environment):**
```bash
# Pull latest code
git pull origin main

# Deploy to personal namespace
kubectl config set-context --current --namespace=dev-alice
kubectl apply -f k8s/

# Access app
open http://dev-alice.mynodeone.local
```

**2. Development:**
```bash
# Make changes
vim src/app.py

# Hot reload (if configured)
# Or rebuild and redeploy
docker build -t myapp:dev .
kubectl set image deployment/myapp myapp=myapp:dev
```

**3. Testing:**
```bash
# Run tests in cluster
kubectl run test-pod \
  --image=myapp:dev \
  --rm -it \
  --restart=Never \
  -- pytest tests/

# Check logs
kubectl logs -f deployment/myapp
```

**4. End of Day:**
```bash
# Optional: Clean up
kubectl delete namespace dev-alice
# (Auto-recreated tomorrow)
```

### PR/CI Workflow

**1. Developer Creates PR:**
```bash
git checkout -b feature/new-api
git push origin feature/new-api
# Create PR on GitLab
```

**2. Automatic CI Triggers:**
```yaml
# .gitlab-ci.yml
stages:
  - build
  - test
  - deploy-qa

build:
  stage: build
  script:
    - docker build -t harbor.mynodeone.local/myapp:$CI_COMMIT_SHA .
    - docker push harbor.mynodeone.local/myapp:$CI_COMMIT_SHA

test:
  stage: test
  script:
    - pytest tests/unit/

deploy-qa:
  stage: deploy-qa
  script:
    - |
      kubectl create namespace qa-pr-$CI_MERGE_REQUEST_IID || true
      kubectl apply -f k8s/ -n qa-pr-$CI_MERGE_REQUEST_IID
  environment:
    name: qa-pr-$CI_MERGE_REQUEST_IID
    url: http://qa-pr-$CI_MERGE_REQUEST_IID.mynodeone.local
```

**3. QA Tests PR:**
- Access QA environment
- Run manual tests
- Automated integration tests run
- Approve or request changes

**4. PR Merged:**
```bash
# Auto-cleanup
kubectl delete namespace qa-pr-123
```

### Performance Testing Workflow

**1. Create Load Test:**
```yaml
# load-test.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: load-test
  namespace: performance
spec:
  parallelism: 10  # 10 concurrent users
  completions: 100  # 100 total requests
  template:
    spec:
      containers:
      - name: k6
        image: grafana/k6
        args:
        - run
        - /scripts/load-test.js
        volumeMounts:
        - name: scripts
          mountPath: /scripts
      volumes:
      - name: scripts
        configMap:
          name: load-test-scripts
      restartPolicy: Never
```

**2. Run Test:**
```bash
kubectl apply -f load-test.yaml -n performance
kubectl logs -f job/load-test -n performance
```

**3. View Results:**
- Grafana dashboards show performance metrics
- Identify bottlenecks
- Iterate and retest

---

## 💰 Cost Analysis

### Cloud Costs (Annual)

**AWS Dev Accounts (10 developers):**
- t3.medium instances (10×): $300/month = $3,600/year
- RDS dev databases (10×): $150/month = $1,800/year
- S3 + CloudWatch: $100/month = $1,200/year
- **Subtotal:** $6,700/year

**QA Environments (3 permanent + PRs):**
- QA clusters: $2,000/month = $24,000/year
- Load testing: $500/month = $6,000/year
- **Subtotal:** $30,000/year

**CI/CD:**
- GitHub Actions minutes: $200/month = $2,400/year
- Container registry: $100/month = $1,200/year
- **Subtotal:** $3,600/year

**Total Annual Cloud Cost:** $40,300/year

### MyNodeOne Costs

**One-Time:**
- Hardware (budget setup): $3,000
- Network equipment: $500
- **Total:** $3,500

**Annual:**
- Electricity (~500W 24/7): $525/year
- Replacement parts: $200/year
- **Total:** $725/year

### 3-Year TCO

**Cloud:** $120,900  
**MyNodeOne:** $5,675  

**Savings:** $115,225 (95% reduction)

---

## 🎯 Success Metrics

### Before MyNodeOne

**Environment Metrics:**
- Environments per developer: 1-2
- Environment provision time: 30-60 minutes
- Cost per environment: $300/month
- Experiment freedom: Low (quota limits)

**Team Productivity:**
- Waiting for environments: 2-4 hours/week
- "Works on my machine" bugs: 20%/sprint
- Integration test frequency: Weekly
- Production parity: 60%

**Costs:**
- Monthly: $3,400
- Annual: $40,300
- 3-year: $120,900

### After MyNodeOne

**Environment Metrics:**
- Environments per developer: Unlimited
- Environment provision time: <2 minutes
- Cost per environment: $0 marginal
- Experiment freedom: Total

**Team Productivity:**
- Waiting for environments: 0 hours/week
- "Works on my machine" bugs: <5%/sprint
- Integration test frequency: Every commit
- Production parity: 95%

**Costs:**
- Monthly: $60
- Annual: $725
- 3-year: $5,675

**ROI:** 20× return in 3 years

---

## 🛠️ Advanced Features

### 1. Auto-Scaling Dev Environments

```yaml
# HPA for dev apps
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-hpa
  namespace: dev-alice
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

### 2. Ephemeral Environments

```bash
# Auto-create on PR, auto-delete on merge
#!/bin/bash
# hooks/pr-created.sh

PR_NUMBER=$1
NAMESPACE="ephemeral-pr-${PR_NUMBER}"

# Create namespace with TTL
kubectl create namespace $NAMESPACE
kubectl annotate namespace $NAMESPACE \
  janitor/ttl="168h"  # Auto-delete after 1 week

# Deploy app
argocd app create pr-${PR_NUMBER} \
  --repo https://gitea.mynodeone.local/myapp.git \
  --path k8s \
  --dest-namespace $NAMESPACE \
  --dest-server https://kubernetes.default.svc

# Post comment to PR
curl -X POST gitea.mynodeone.local/api/v1/repos/myapp/issues/${PR_NUMBER}/comments \
  -d "{\"body\":\"Environment ready at http://${NAMESPACE}.mynodeone.local\"}"
```

### 3. Database Snapshots

```bash
# scripts/db-snapshot.sh
#!/bin/bash
NAMESPACE=$1
SNAPSHOT_NAME="snapshot-$(date +%Y%m%d-%H%M%S)"

# Create snapshot using Longhorn
kubectl create -f - <<EOF
apiVersion: longhorn.io/v1beta1
kind: Backup
metadata:
  name: $SNAPSHOT_NAME
  namespace: longhorn-system
spec:
  snapshotName: pvc-${NAMESPACE}-postgres
EOF

echo "Snapshot created: $SNAPSHOT_NAME"
echo "Restore with: kubectl apply -f restore-${SNAPSHOT_NAME}.yaml"
```

### 4. Chaos Engineering

```bash
# Install Chaos Mesh
curl -sSL https://mirrors.chaos-mesh.org/latest/install.sh | bash

# Create chaos experiment
kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-failure
  namespace: dev-alice
spec:
  action: pod-failure
  mode: one
  selector:
    namespaces:
      - dev-alice
    labelSelectors:
      app: myapp
  duration: "30s"
  scheduler:
    cron: "@every 2h"
EOF
```

---

## 📋 Best Practices

### 1. Namespace Hygiene
- Use descriptive names (dev-alice, not ns-1)
- Set resource quotas
- Apply network policies
- Label everything

### 2. Resource Management
- Set requests and limits
- Use PodDisruptionBudgets
- Monitor resource usage
- Clean up unused environments

### 3. Database Management
- Use separate DB per namespace
- Anonymize production data for testing
- Regular backups
- Easy snapshot/restore

### 4. Security
- NetworkPolicies by default
- Secrets management (Sealed Secrets)
- RBAC per namespace
- Image scanning (Trivy)

### 5. Monitoring
- Grafana dashboard per team
- Loki for log aggregation
- Prometheus alerts
- Cost tracking

---

## 🆘 Troubleshooting

### Environment Won't Start

```bash
# Check events
kubectl get events -n dev-alice --sort-by='.lastTimestamp'

# Check pod status
kubectl get pods -n dev-alice

# Check logs
kubectl logs -f deployment/myapp -n dev-alice

# Common issues:
# - Image pull errors: Check registry credentials
# - Resource limits: Increase namespace quota
# - PVC pending: Check Longhorn storage
```

### Database Connection Issues

```bash
# Test connectivity
kubectl run -it --rm debug \
  --image=postgres:15-alpine \
  --restart=Never \
  -n dev-alice \
  -- psql -h postgres.dev-alice.svc.cluster.local -U postgres

# Check service
kubectl get svc postgres -n dev-alice

# Check endpoints
kubectl get endpoints postgres -n dev-alice
```

### Out of Resources

```bash
# Check cluster capacity
kubectl top nodes

# Check namespace usage
kubectl top pods -n dev-alice

# Increase quota if needed
kubectl patch resourcequota dev-quota \
  -n dev-alice \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"8","requests.memory":"16Gi"}}}'
```

---

## ✅ Quick Start Checklist

**Day 1:**
- [ ] Install MyNodeOne cluster
- [ ] Deploy GitLab/Gitea
- [ ] Configure ArgoCD
- [ ] Set up Harbor (container registry)

**Day 2:**
- [ ] Create developer environment template
- [ ] Provision test environments for team
- [ ] Configure CI/CD pipelines
- [ ] Set up automated deployments

**Day 3:**
- [ ] Create QA environment workflows
- [ ] Configure PR-based deployments
- [ ] Set up monitoring dashboards
- [ ] Document processes

**Day 4:**
- [ ] Train developers on workflows
- [ ] Migrate first project
- [ ] Run parallel with cloud (2 weeks)
- [ ] Decommission cloud environments

**Estimated timeline:** 1 week  
**Team required:** 1-2 DevOps engineers

---

**Give your developers unlimited freedom to experiment** 🚀
