# External App Deployment - Test Plan

## Overview

This test plan validates the MyNodeOne external app deployment system using real-world applications to ensure all features work correctly.

## Quick Test (5 minutes)

```bash
# Clone test app
cd /tmp
git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app

# Deploy
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Monitor
watch kubectl get pods -n voting-app
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

**Objective**: Validate intelligent domain mapping

**Steps**:
1. Deploy voting app using auto-detect mode
2. Verify service type detection
3. Confirm domain mapping

**Expected Results**:
```
✓ Auto-detecting subdomain mapping...
  ✓ app.test.mynodeone.local → vote (frontend)
  ✓ result.test.mynodeone.local → result (frontend)
  
Internal services (no public domain):
  • worker, redis, db
```

### Test Case 2: Manual Mode with Intelligence

**Objective**: Test manual domain specification with auto-matching

**Steps**:
1. Deploy with manual mode
2. Specify custom domains
3. Verify intelligent matching

**Expected**:
- Script auto-matches common patterns (api.*, app.*)
- Asks for unknown patterns
- User can manually select services

### Test Case 3: Single Domain Mode

**Objective**: Test simplified single-domain deployment

**Expected**:
- Maps to primary frontend service
- Other services remain internal
- Simplified DNS configuration

### Test Case 4: Interactive Mode (No docker-compose)

**Objective**: Test fallback to interactive setup

**Steps**:
1. Create empty directory
2. Run deploy script
3. Provide service details manually

**Expected**:
- Script detects no docker-compose
- Falls back to interactive mode
- Generates manifests from user input

### Test Case 5: Error Handling

**Objective**: Test error scenarios and recovery

**Test Scenarios**:
- Invalid Docker images
- Insufficient resources
- Network issues
- MetalLB problems

**Expected**: Clear error messages with actionable fixes

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

✅ **Core Functionality (Must Pass)**:
1. Script detects docker-compose.yml automatically
2. Parses all 5 services correctly  
3. Auto-detects service types (frontend, cache, database, worker)
4. Creates appropriate Kubernetes resources
5. Assigns LoadBalancer IPs to public services only
6. Registers with MyNodeOne service registry
7. DNS resolution works (app.test.mynodeone.local)
8. Both vote and result apps are accessible
9. Apps can communicate (vote → redis → worker → db → result)
10. Real-time updates work (vote submission shows in results)

✅ **Advanced Features (Should Pass)**:
1. All three domain modes work (auto-detect, manual, single)
2. Interactive mode generates manifests correctly
3. Error handling provides clear guidance
4. Resource limits applied correctly
5. Health checks work
6. Clean undeployment possible

---

## Performance Benchmarks

Track during deployment:

- **Deployment time**: < 5 minutes for voting app
- **Script execution**: Complete without user intervention errors
- **First access**: Apps responsive within 30 seconds
- **Resource usage**: Matches requested specifications
- **Pod startup**: < 30 seconds per pod

---

## Modern Test Applications

For comprehensive testing, consider these additional apps:

### 1. Ghost (Blog Platform)
```bash
git clone https://github.com/TryGhost/Ghost.git
# Tests: Single service with database integration
```

### 2. Uptime Kuma (Monitoring)
```bash
git clone https://github.com/louislam/uptime-kuma.git
# Tests: Simple single-service deployment
```

### 3. n8n (Workflow Automation)
```bash
git clone https://github.com/n8n-io/n8n.git
# Tests: Multi-service coordination (n8n, Postgres, Redis)
```

---

## Quick Validation Commands

```bash
# Deploy voting app
cd /tmp && git clone https://github.com/dockersamples/example-voting-app.git
cd example-voting-app
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh

# Monitor deployment
watch kubectl get pods -n voting-app

# Test services
kubectl get svc -n voting-app
curl http://voting.mynodeone.local

# Check logs
kubectl logs -n voting-app -l app=voting-app -f

# Cleanup
bash /path/to/MyNodeOne/external-apps/scripts/undeploy.sh voting-app
```

---

## Contributing to Test Plan

To improve this test plan:
1. Test with additional applications
2. Document edge cases and solutions
3. Update success criteria as features evolve
4. Add performance benchmarks
5. Report issues via GitHub with `external-apps` and `testing` tags

---

**Last Updated**: January 2026  
**MyNodeOne Version**: Current main branch  
**Test Status**: Ready for validation