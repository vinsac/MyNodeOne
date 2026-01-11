# External App Deployment - Debug Checklist

When deployment completes but something doesn't work, follow this checklist:

## **1. Check if Pods Are Running**

```bash
kubectl get pods -n votingapp
```

**Expected:**
```
NAME                      READY   STATUS    RESTARTS
vote-xxx                  1/1     Running   0
result-xxx                1/1     Running   0
worker-xxx                1/1     Running   0
redis-xxx                 1/1     Running   0
db-xxx                    1/1     Running   0
```

**If pods are CrashLoopBackOff:**
```bash
kubectl logs -n votingapp <pod-name>
kubectl describe pod -n votingapp <pod-name>
```

---

## **2. Check Services and IPs**

```bash
kubectl get svc -n votingapp
```

**Expected:**
```
NAME     TYPE           EXTERNAL-IP     PORT(S)
vote     LoadBalancer   10.20.30.40     80:30123/TCP
result   LoadBalancer   10.20.30.50     80:30124/TCP
redis    ClusterIP      10.43.1.2       6379/TCP
db       ClusterIP      10.43.1.3       5432/TCP
```

**Key points:**
- `vote` and `result` should have `EXTERNAL-IP` (MetalLB assigned)
- `redis` and `db` should be `ClusterIP` (internal only)
- If `EXTERNAL-IP` is `<pending>`, MetalLB hasn't assigned yet (wait 30s)

---

## **3. Check Local DNS Registration**

```bash
# Check service registry
kubectl get configmap -n kube-system service-registry -o yaml

# Should show your app registered
```

**If not registered:**
```bash
# Manually register
cd /path/to/MyNodeOne
sudo bash scripts/lib/service-registry.sh register \
    votingapp voting votingapp vote 80 false

# Update DNS
sudo bash scripts/domains/sync-dns.sh
```

**Test DNS:**
```bash
nslookup voting.mynodeone.local
# Should return the LoadBalancer IP
```

---

## **4. Test Access**

### **A. Via LoadBalancer IP (direct)**
```bash
# Get IP
kubectl get svc vote -n votingapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Test
curl http://<LOADBALANCER_IP>
```

### **B. Via Local DNS**
```bash
curl http://voting.mynodeone.local
# Should work if DNS is registered
```

### **C. Via NodePort (fallback)**
```bash
# Get NodePort
kubectl get svc vote -n votingapp -o jsonpath='{.spec.ports[0].nodePort}'

# Test (use any cluster node IP)
curl http://<NODE_IP>:<NODEPORT>
```

---

## **5. Check Service Communication**

**Test if internal services can talk to each other:**

```bash
# Exec into vote pod
kubectl exec -it -n votingapp deployment/vote -- sh

# Try to reach redis (should work via ClusterIP DNS)
ping redis
nc -zv redis 6379

# Try to reach db
nc -zv db 5432
```

**This should work even if LoadBalancer IPs aren't assigned!**

---

## **Common Issues**

### **Issue 1: "Could not get LoadBalancer IP"**

**Cause:** MetalLB takes time to assign IPs, or IP pool exhausted.

**Solution:**
```bash
# Wait 30 seconds and check again
kubectl get svc -n votingapp

# If still pending, check MetalLB
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
```

**Manual registration if needed:**
```bash
# Once IP is assigned
LB_IP=$(kubectl get svc vote -n votingapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
sudo bash /path/to/MyNodeOne/scripts/lib/service-registry.sh register \
    votingapp voting votingapp vote 80 false
sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh
```

---

### **Issue 2: "voting.mynodeone.local doesn't resolve"**

**Cause:** DNS registration failed or not synced.

**Check:**
```bash
# Check /etc/hosts
cat /etc/hosts | grep voting

# Should have:
# 10.20.30.40  voting.mynodeone.local
```

**Fix:**
```bash
# Re-sync DNS
sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh

# Or manually add to /etc/hosts
echo "10.20.30.40  voting.mynodeone.local" | sudo tee -a /etc/hosts
```

---

### **Issue 3: "App works locally but services can't communicate"**

**This should NEVER happen** - Kubernetes internal DNS always works.

**Debug:**
```bash
# Check DNS from inside a pod
kubectl exec -it -n votingapp deployment/vote -- nslookup redis
kubectl exec -it -n votingapp deployment/vote -- nslookup db

# Should resolve to ClusterIP
```

**If not working:**
```bash
# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check service endpoints
kubectl get endpoints -n votingapp
```

---

### **Issue 4: "Pods crash with connection errors"**

**Common causes:**
1. Environment variables wrong (check connection strings)
2. Database not ready yet (check init containers or readiness probes)
3. Network policies blocking traffic

**Debug:**
```bash
kubectl logs -n votingapp deployment/vote --previous
kubectl logs -n votingapp deployment/worker -f
```

---

## **Understanding the Networking Flow**

### **Internal Traffic (No MetalLB needed)**
```
┌─────────────────────────────────────────────────┐
│  Voting App Namespace                           │
├─────────────────────────────────────────────────┤
│                                                 │
│  vote pod ──[redis]──> ClusterIP ──> redis pod │
│     │                                    │      │
│     └──[db]──> ClusterIP ──────────────> db pod│
│                                           │     │
│  worker pod ──[redis]──> ClusterIP ───────┘     │
│     │                                           │
│     └──[db]──> ClusterIP ──────────────────────┘│
│                                                 │
└─────────────────────────────────────────────────┘

All using Kubernetes DNS: redis.votingapp.svc.cluster.local
                          db.votingapp.svc.cluster.local
```

### **External Access (MetalLB LoadBalancer)**
```
┌──────────────────────────────────────────────────┐
│  Your Laptop                                     │
└──────────────────┬───────────────────────────────┘
                   │
                   │ http://voting.mynodeone.local
                   ↓
┌──────────────────────────────────────────────────┐
│  DNS: voting.mynodeone.local → 10.20.30.40       │
└──────────────────┬───────────────────────────────┘
                   ↓
┌──────────────────────────────────────────────────┐
│  MetalLB LoadBalancer: 10.20.30.40               │
│  (Service: vote, Type: LoadBalancer)             │
└──────────────────┬───────────────────────────────┘
                   ↓
┌──────────────────────────────────────────────────┐
│  vote pod (port 80)                              │
└──────────────────────────────────────────────────┘
```

---

## **Quick Fix for Current Deployment**

If your deployment completed but DNS doesn't work:

```bash
# 1. Verify services have IPs
kubectl get svc -n votingapp

# 2. Get the vote service IP
VOTE_IP=$(kubectl get svc vote -n votingapp -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 3. Manually register (if IP exists)
if [[ -n "$VOTE_IP" ]]; then
    sudo bash /path/to/MyNodeOne/scripts/lib/service-registry.sh register \
        votingapp voting votingapp vote 80 false
    sudo bash /path/to/MyNodeOne/scripts/domains/sync-dns.sh
fi

# 4. Test
curl http://voting.mynodeone.local
```

---

## **What's Working vs Not Working**

After deployment, this is the status:

### **✓ What's Working**
- Pods are running
- Internal service communication (redis, db, worker)
- Direct access via LoadBalancer IP
- Direct access via NodePort

### **✗ What Might Not Be Working**
- Local DNS (voting.mynodeone.local) - if registration failed
- Public access - not configured yet (needs DNS + manage-app-visibility.sh)

---

## **Next Steps**

1. **Verify app functionality** (internal communication)
2. **Fix local DNS** (manual registration if needed)
3. **Configure public access** (when you own a domain)

See `DOMAIN-SSL-WORKFLOW.md` for public access setup.
