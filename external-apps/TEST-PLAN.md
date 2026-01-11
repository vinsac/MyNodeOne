# External App Deployment - Test Plan

## Branch Information

**Branch**: `feature/external-app-deployment`  
**Latest Commit**: `af10162`  
**Status**: Documentation complete, ready for production use

## Pull Branch on Control Plane

```bash
# On control plane
cd /path/to/MyNodeOne
git fetch origin
git checkout feature/external-app-deployment
git pull origin feature/external-app-deployment
```

---

## Test Application

We'll use **Docker's Example Voting App** - a real-world distributed application.

**Repository**: https://github.com/dockersamples/example-voting-app  
**Why this app**: 
- ✓ Production-quality example from Docker
- ✓ Multiple services (5 services)
- ✓ Has docker-compose.yml
- ✓ Mixed tech stack (Python, Node.js, .NET, Redis, Postgres)
- ✓ Perfect for testing intelligent domain mapping

**Architecture**:
```
vote        (Python web app)   → Frontend
result      (Node.js web app)  → Frontend  
worker      (.NET)             → Worker
redis       (Redis)            → Cache
db          (Postgres)         → Database
```

---

## Test Procedure

### Step 1: Clone Test App on Control Plane

```bash
# On control plane
cd /tmp
git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app
```

### Step 2: Review docker-compose.yml

```bash
cat docker-compose.yml
```

Expected services:
- `vote` - Python Flask app (port 8080)
- `result` - Node.js app (port 8081)
- `worker` - .NET worker (no exposed port)
- `redis` - Redis cache
- `db` - PostgreSQL database

### Step 3: Run Deployment Script

```bash
cd /tmp/example-voting-app
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

### Step 4: Answer Interactive Prompts

**Expected questions and answers**:

```
? App name: voting-app

? Memory per service? 512Mi

? CPU per service? 500m

? Storage size? 10Gi

? Local subdomain? voting

? Make public? y

? Choose domain setup:
  1. Auto-detect (Recommended)  ← Test this first

? Base domain: test.mynodeone.local
  (Or use your actual domain if testing public access)
```

**What should happen (Auto-detect mode)**:

```
✓ Auto-detecting subdomain mapping...
  ✓ app.test.mynodeone.local → vote (frontend)
  ✓ result.test.mynodeone.local → result (frontend)
  
Internal services (no public domain):
  • worker, redis, db
```

---

## Expected Results

### 1. Services Created

```bash
kubectl get all -n voting-app
```

Expected:
- 2-3 deployments (vote, result, maybe worker)
- 5 pods (all services)
- 2-3 services (vote, result as LoadBalancer, others as ClusterIP)
- PVC for database

### 2. LoadBalancer IPs Assigned

```bash
kubectl get svc -n voting-app
```

Expected:
```
NAME     TYPE           EXTERNAL-IP      PORT(S)
vote     LoadBalancer   10.20.30.40      80:30xxx/TCP
result   LoadBalancer   10.20.30.41      80:30xxx/TCP
redis    ClusterIP      10.96.x.x        6379/TCP
db       ClusterIP      10.96.x.x        5432/TCP
worker   (none or ClusterIP)
```

### 3. DNS Registration

```bash
kubectl get configmap -n kube-system service-registry -o yaml
```

Should contain entries for:
- `voting` subdomain
- Services registered

### 4. Local Access

```bash
# From control plane or any cluster node
curl http://voting.mynodeone.local
curl http://app.test.mynodeone.local
curl http://result.test.mynodeone.local
```

Expected:
- Vote app UI (HTML page)
- Result app UI (real-time results)

### 5. Application Functionality

**Vote App** (`http://voting.mynodeone.local` or LoadBalancer IP):
- Should show voting UI (Cats vs Dogs)
- Click vote, should submit

**Result App** (`http://result.test.mynodeone.local`):
- Should show real-time results
- Should update when votes are cast

**Behind the scenes**:
- Vote → Redis → Worker → Postgres → Result
- All services should communicate

---

## Test Cases

### Test Case 1: Auto-Detect Mode (Primary Test)

**Steps**:
1. Run `deploy.sh`
2. Choose option 1 (Auto-detect)
3. Provide base domain: `test.mynodeone.local`

**Expected**:
- Script detects `vote` and `result` as frontend type
- Auto-maps: `app.test.mynodeone.local` → vote
- Auto-maps: `result.test.mynodeone.local` → result
- Skips internal: redis, db, worker

**Verify**:
```bash
kubectl get svc -n voting-app -o wide
curl http://app.test.mynodeone.local
curl http://result.test.mynodeone.local
```

### Test Case 2: Manual Mode with Intelligence

**Steps**:
1. Undeploy: `bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh voting-app`
2. Run `deploy.sh` again
3. Choose option 2 (Manual)
4. Domains: `vote.test.com,results.test.com`

**Expected**:
- Script should NOT auto-match (no "app." or "result." prefix)
- Should ask which service for each domain
- User manually selects

**Verify**: Manual mapping works

### Test Case 3: Single Domain Mode

**Steps**:
1. Undeploy
2. Run `deploy.sh`
3. Choose option 3 (Single domain)
4. Domain: `voting.mynodeone.local`

**Expected**:
- Maps to primary service (vote or first service)
- Result service has no public domain (internal only)

**Verify**:
```bash
kubectl get svc -n voting-app
# Only 'vote' should be LoadBalancer
```

### Test Case 4: Interactive Mode (No docker-compose)

**Steps**:
1. Create empty directory: `mkdir /tmp/test-interactive`
2. Run: `bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh`
3. Provide service details manually

**Expected**:
- Script detects no docker-compose
- Falls back to interactive mode
- Asks for number of services, images, ports, etc.

### Test Case 5: Update Deployment

**Steps**:
1. After successful deployment
2. Update image:
```bash
kubectl set image deployment/voting-app-vote \
  vote=dockersamples/examplevotingapp_vote:after \
  -n voting-app
```

**Verify**: Rolling update works, no downtime

---

## Potential Issues & Debugging

### Issue: ImagePullBackOff

**Cause**: Docker images not available or rate limited

**Debug**:
```bash
kubectl describe pod -n voting-app <pod-name>
kubectl logs -n voting-app <pod-name>
```

**Fix**: 
- Wait for rate limit reset
- Use different registry
- Pre-pull images

### Issue: Services Can't Communicate

**Cause**: Network policies or wrong service names

**Debug**:
```bash
kubectl exec -it -n voting-app <vote-pod> -- nslookup redis
kubectl exec -it -n voting-app <vote-pod> -- nslookup db
```

**Expected**: Should resolve to ClusterIP

### Issue: LoadBalancer IP Pending

**Cause**: MetalLB not configured or IP pool exhausted

**Debug**:
```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
```

**Fix**: Configure MetalLB or use NodePort temporarily

### Issue: DNS Not Working

**Cause**: Service registry not synced

**Debug**:
```bash
kubectl get configmap -n kube-system service-registry -o yaml
cat /etc/hosts | grep mynodeone.local
```

**Fix**:
```bash
sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh
```

### Issue: Database Connection Errors

**Cause**: Worker can't reach Postgres

**Debug**:
```bash
kubectl logs -n voting-app <worker-pod>
```

**Expected error**: Connection string issues

**Fix**: Check environment variables in deployment

---

## Success Criteria

✅ **Must Pass**:
1. Script detects docker-compose.yml automatically
2. Parses all 5 services correctly
3. Auto-detects service types (frontend, cache, database)
4. Creates appropriate Kubernetes resources
5. Assigns LoadBalancer IPs to public services only
6. Registers with MyNodeOne service registry
7. DNS resolution works (app.test.mynodeone.local)
8. Both vote and result apps are accessible
9. Apps can communicate (vote → redis → worker → db → result)
10. Real-time updates work (vote submission shows in results)

✅ **Nice to Have**:
1. Auto-scaling configured
2. Resource limits applied correctly
3. Health checks work
4. Logs accessible via kubectl
5. Can undeploy cleanly

---

## Performance Metrics

Track during deployment:

- **Time to deploy**: Should be < 5 minutes
- **Script execution**: Should complete without errors
- **First access**: Apps should be responsive immediately
- **Memory usage**: Should match requested resources
- **Pod startup time**: < 30 seconds per pod

---

## Test Report Template

```markdown
## Test Execution Report

**Date**: YYYY-MM-DD
**Tester**: Name
**Branch**: feature/external-app-deployment
**Commit**: 2a6ad40

### Environment
- Control plane: [specs]
- Kubernetes version: [version]
- MyNodeOne version: [commit]

### Test Case Results

#### TC1: Auto-Detect Mode
- Status: ✓ PASS / ✗ FAIL
- Notes: [observations]

#### TC2: Manual Mode
- Status: ✓ PASS / ✗ FAIL
- Notes: [observations]

#### TC3: Single Domain
- Status: ✓ PASS / ✗ FAIL
- Notes: [observations]

### Issues Found
1. [Issue description]
   - Severity: Critical/Major/Minor
   - Steps to reproduce:
   - Expected:
   - Actual:

### Recommendations
- [Improvements needed]

### Screenshots
- [Attach relevant screenshots]
```

---

## Next Steps After Testing

### If Tests Pass:
1. Merge feature branch to main
2. Update main README with external-apps link
3. Create demo video
4. Write blog post

### If Tests Fail:
1. Document issues in GitHub Issues
2. Fix critical bugs
3. Re-test
4. Iterate

---

## Additional Test Apps (Future)

For broader testing, consider:

1. **Ghost** (Blog platform)
   - Repository: https://github.com/TryGhost/Ghost
   - Services: Ghost, MySQL
   - Tests: Database integration

2. **n8n** (Workflow automation)
   - Repository: https://github.com/n8n-io/n8n
   - Services: n8n, Postgres, Redis
   - Tests: Multi-service coordination

3. **Uptime Kuma** (Monitoring)
   - Repository: https://github.com/louislam/uptime-kuma
   - Services: Single service
   - Tests: Simple app deployment

4. **Directus** (Headless CMS)
   - Repository: https://github.com/directus/directus
   - Services: Directus, Postgres
   - Tests: Data persistence

---

## Quick Test Commands (Copy-Paste)

```bash
# On control plane
cd /path/to/MyNodeOne
git fetch origin
git checkout feature/external-app-deployment

# Clone test app
cd /tmp
git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app

# Deploy
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Monitor deployment
watch kubectl get pods -n voting-app

# Check services
kubectl get svc -n voting-app

# Test access
curl http://voting.mynodeone.local

# Check logs
kubectl logs -n voting-app -l app=voting-app -f

# Undeploy when done
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh voting-app
```

---

## Contact for Issues

- Create GitHub issue with test report
- Tag: `external-apps`, `testing`
- Include: logs, error messages, environment details
