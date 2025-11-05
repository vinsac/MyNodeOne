# DNS Issues Found and Fixes Needed

## Issues Summary

### 1. Demo App DNS Name
**Problem:** demo-chat-app.mycloud.local (service name used directly)
**Expected:** demoapp.mycloud.local
**Fix:** Use friendly name instead of service name in DNS

### 2. Traefik 404
**Problem:** http://traefik.mycloud.local/ shows 404
**Root Cause:** Traefik dashboard not exposed/configured
**Fix:** Enable Traefik dashboard or document that it's for routing only

### 3. MinIO Console Wrong Port
**Problem:** http://minio.mycloud.local/ times out
**Root Cause:** DNS points to console IP but port 80 doesn't exist (needs :9001)
**Working:** http://minio.mycloud.local:9001/
**Fix:** Document correct URLs with ports or setup Traefik ingress

### 4. MinIO API Wrong Port  
**Problem:** http://minio-api.mycloud.local/ times out
**Root Cause:** DNS points to API IP but port 80 doesn't exist (needs :9000)
**Fix:** Document correct URLs with ports or setup Traefik ingress

### 5. Dashboard DNS Inconsistency
**Problem:** Script says http://mycloud.local but /etc/hosts has dashboard.mycloud.local
**Root Cause:** 
  - setup-local-dns.sh line 210 adds: ${DASHBOARD_IP} ${CLUSTER_DOMAIN}.local
  - But configure-app-dns.sh detects it as service and adds: dashboard.mycloud.local
**Fix:** Either use mycloud.local OR dashboard.mycloud.local consistently

## Detailed Fixes

### Fix 1: Demo App Friendly Name
File: `scripts/configure-app-dns.sh`

Add mapping for friendly names:
```bash
# Map service names to friendly DNS names
declare -A APP_DNS_NAMES=(
    ["demo-apps"]="demoapp"
    ["open-webui"]="chat"  
    # etc
)
```

### Fix 2: Port-Based Service URLs
File: `scripts/setup-local-dns.sh`

Add port information to URL display:
```bash
echo "  • MinIO Console: http://minio.${CLUSTER_DOMAIN}.local:9001"
echo "  • MinIO API:     http://minio-api.${CLUSTER_DOMAIN}.local:9000"
```

### Fix 3: Dashboard DNS Consistency
File: `scripts/setup-local-dns.sh` line 210

**Option A:** Keep as ${CLUSTER_DOMAIN}.local (simpler)
```bash
${DASHBOARD_IP}      ${CLUSTER_DOMAIN}.local
```
And add to configure-app-dns.sh exclusion list

**Option B:** Change to dashboard.${CLUSTER_DOMAIN}.local (more consistent)
```bash
${DASHBOARD_IP}      dashboard.${CLUSTER_DOMAIN}.local
```
And update all messages

### Fix 4: Traefik Dashboard
File: `scripts/bootstrap-control-plane.sh`

**Option A:** Enable Traefik dashboard
```yaml
--set dashboard.enabled=true
```

**Option B:** Document that traefik.mycloud.local is for routing only
Update help text to explain Traefik is reverse proxy, not UI

## Recommended Approach

1. **Demo App:** Use friendly name "demoapp"
2. **MinIO:** Document correct ports in all messages
3. **Dashboard:** Use mycloud.local (root domain) consistently
4. **Traefik:** Add note that it's routing only, no dashboard UI
