# Hybrid Setup Troubleshooting Guide

**Common issues and solutions for hybrid MyNodeOne deployments**

---

## 🎯 Quick Diagnostic Commands

Run these first to gather information:

```bash
# 1. Check DNS resolution
dig +short photos.yourdomain.com

# 2. Test VPS connectivity
curl -I https://photos.yourdomain.com

# 3. Check Tailscale status
tailscale status

# 4. Check Kubernetes pods
kubectl get pods -n immich

# 5. Check socat proxy (on control plane)
sudo systemctl status immich-proxy

# 6. Check Traefik logs (on VPS)
ssh root@VPS_IP 'docker logs traefik --tail 50'
```

---

## 🔍 Issue Categories

1. [DNS Issues](#dns-issues)
2. [SSL/TLS Certificate Issues](#ssltls-certificate-issues)
3. [Network Connectivity Issues](#network-connectivity-issues)
4. [Kubernetes Service Issues](#kubernetes-service-issues)
5. [Socat Proxy Issues](#socat-proxy-issues)
6. [Application-Specific Issues](#application-specific-issues)
7. [Performance Issues](#performance-issues)

---

## 1. DNS Issues

### **Issue 1.1: Domain not resolving**

**Symptoms:**
```bash
$ dig +short photos.yourdomain.com
# (no output)
```

**Diagnosis:**
```bash
# Check if domain exists
dig yourdomain.com

# Check A record specifically
dig A photos.yourdomain.com

# Check DNS propagation globally
# Visit: https://dnschecker.org
```

**Possible Causes:**
- A record not created
- DNS not propagated yet
- Wrong record type (AAAA instead of A)
- TTL too high (changes take longer)

**Solutions:**
```bash
# 1. Verify A record exists in your DNS provider
#    Type: A
#    Name: photos (or subdomain)
#    Value: 45.8.133.192 (your VPS IP)
#    TTL: 300-600 seconds

# 2. Wait for propagation (5-15 minutes typically)

# 3. Clear local DNS cache
sudo systemd-resolve --flush-caches  # Linux
```

---

### **Issue 1.2: Domain resolves to wrong IP**

**Symptoms:**
```bash
$ dig +short photos.yourdomain.com
1.2.3.4  # Wrong IP!
```

**Solution:**
```bash
# 1. Check your DNS provider settings
# 2. Ensure A record points to VPS public IP, not Tailscale IP
# 3. Delete any conflicting CNAME records
# 4. Wait for TTL to expire
```

---

### **Issue 1.3: Wildcard DNS not working**

**Symptoms:**
- `photos.yourdomain.com` works
- `*.yourdomain.com` doesn't match

**Solution:**
```bash
# Wildcard DNS requires specific record:
# Type: A
# Name: *
# Value: 45.8.133.192

# OR create individual A records for each subdomain
```

---

## 2. SSL/TLS Certificate Issues

### **Issue 2.1: Certificate not issued**

**Symptoms:**
```bash
$ curl -I https://photos.yourdomain.com
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

**Diagnosis:**
```bash
# Check Traefik logs for ACME errors
ssh root@VPS 'docker logs traefik 2>&1 | grep -i acme'

# Check acme.json file
ssh root@VPS 'cat /etc/traefik/acme.json | jq .'
```

**Possible Causes:**
1. Port 80 blocked (needed for HTTP-01 challenge)
2. DNS not propagated
3. Rate limit hit (Let's Encrypt: 5 certs/week per domain)
4. Wrong email in Traefik config

**Solutions:**
```bash
# 1. Ensure port 80 is accessible
ssh root@VPS 'sudo ufw status | grep 80'

# 2. Test HTTP-01 challenge manually
curl -I http://photos.yourdomain.com/.well-known/acme-challenge/test

# 3. Check rate limits
# Visit: https://crt.sh/?q=yourdomain.com

# 4. Delete acme.json and retry
ssh root@VPS 'rm /etc/traefik/acme.json && docker restart traefik'

# 5. Wait 1-2 minutes for certificate generation
```

---

### **Issue 2.2: Certificate expired**

**Symptoms:**
```bash
# Browser shows: "Your connection is not private"
# Error: NET::ERR_CERT_DATE_INVALID
```

**Diagnosis:**
```bash
# Check certificate expiry
echo | openssl s_client -servername photos.yourdomain.com \
  -connect photos.yourdomain.com:443 2>/dev/null | \
  openssl x509 -noout -dates
```

**Solution:**
```bash
# Traefik auto-renews certificates
# If not renewing:

# 1. Restart Traefik
ssh root@VPS 'cd /etc/traefik && docker compose restart'

# 2. Force renewal by deleting cert
ssh root@VPS 'rm /etc/traefik/acme.json && docker restart traefik'
```

---

### **Issue 2.3: Self-signed certificate shown**

**Symptoms:**
- Browser shows warning
- Certificate issuer: "Traefik Default Certificate"

**Cause:** Traefik using default certificate (cert not issued yet)

**Solution:**
Wait 1-2 minutes for Let's Encrypt certificate to be issued.

If still not working after 5 minutes, check Traefik logs.

---

## 3. Network Connectivity Issues

### **Issue 3.1: Cannot reach VPS from internet**

**Symptoms:**
```bash
$ curl -I https://photos.yourdomain.com
curl: (28) Failed to connect to photos.yourdomain.com port 443: Connection timed out
```

**Diagnosis:**
```bash
# Test direct IP connection
curl -I http://45.8.133.192

# Check VPS firewall
ssh root@VPS 'sudo ufw status'

# Check if Traefik is running
ssh root@VPS 'docker ps | grep traefik'
```

**Solutions:**
```bash
# 1. Open firewall ports
ssh root@VPS 'sudo ufw allow 80/tcp && sudo ufw allow 443/tcp'

# 2. Check cloud provider firewall (AWS Security Groups, etc.)

# 3. Restart Traefik
ssh root@VPS 'cd /etc/traefik && docker compose restart'
```

---

### **Issue 3.2: VPS cannot reach control plane**

**Symptoms:**
- Traefik logs show: "dial tcp 100.118.5.68:8080: i/o timeout"
- 502 Bad Gateway error

**Diagnosis:**
```bash
# From VPS, test connectivity to control plane
ssh root@VPS 'ping -c 3 100.118.5.68'
ssh root@VPS 'curl -I http://100.118.5.68:8080'

# Check Tailscale status on both machines
tailscale status  # On control plane
ssh root@VPS 'tailscale status'  # On VPS
```

**Possible Causes:**
1. Tailscale not running on one side
2. Firewall blocking connection
3. Socat proxy not running
4. Wrong IP in Traefik config

**Solutions:**
```bash
# 1. Restart Tailscale on both sides
sudo systemctl restart tailscaled

# 2. Check control plane firewall
sudo ufw status | grep 8080
sudo ufw allow from 100.101.92.95 to any port 8080 proto tcp

# 3. Restart socat proxy
sudo systemctl restart immich-proxy

# 4. Verify Traefik backend URL
ssh root@VPS 'cat /etc/traefik/dynamic/immich.yml | grep url'
```

---

### **Issue 3.3: Tailscale connection unstable**

**Symptoms:**
- Intermittent 502 errors
- Slow loading
- Connection drops

**Diagnosis:**
```bash
# Check Tailscale connection quality
tailscale ping 100.101.92.95  # VPS IP

# Check for packet loss
tailscale status --json | jq '.Peer[] | select(.TailscaleIPs[0]=="100.101.92.95") | .CurAddr'
```

**Solutions:**
```bash
# 1. Restart Tailscale
sudo systemctl restart tailscaled

# 2. Check for firewall issues blocking UDP
sudo ufw status

# 3. Enable UPnP/NAT-PMP if behind NAT

# 4. Use Tailscale relay (DERP) if direct connection fails
tailscale status  # Look for "relay" in connection type
```

---

## 4. Kubernetes Service Issues

### **Issue 4.1: Pods not running**

**Symptoms:**
```bash
$ kubectl get pods -n immich
NAME                             READY   STATUS             RESTARTS
immich-server-xxx                0/1     CrashLoopBackOff   5
```

**Diagnosis:**
```bash
# Check pod logs
kubectl logs -n immich deployment/immich-server --tail=50

# Describe pod for events
kubectl describe pod -n immich immich-server-xxx

# Check resource availability
kubectl top nodes
kubectl top pods -n immich
```

**Common Causes & Solutions:**

**CrashLoopBackOff:**
```bash
# Database not ready
kubectl get pods -n immich  # Check postgres pod

# Wrong environment variables
kubectl get secret -n immich immich-secrets -o yaml

# Port conflict
kubectl logs -n immich deployment/immich-server | grep -i "address already in use"
```

**ImagePullBackOff:**
```bash
# Check image exists
kubectl describe pod -n immich immich-server-xxx | grep -i image

# Check for typos in image name
kubectl get deployment -n immich immich-server -o yaml | grep image:
```

**Pending:**
```bash
# Insufficient resources
kubectl describe node | grep -A5 "Allocated resources"

# PVC not bound
kubectl get pvc -n immich
```

---

### **Issue 4.2: Service has no External-IP**

**Symptoms:**
```bash
$ kubectl get svc -n immich
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)
immich-server   LoadBalancer   10.43.126.136   <pending>     80:30487/TCP
```

**Cause:** MetalLB not installed or not configured

**Solution:**
```bash
# Check MetalLB
kubectl get pods -n metallb-system

# If not installed, install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Configure IP pool
kubectl apply -f - << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: metallb-system
spec:
  addresses:
  - 100.118.5.200-100.118.5.250
EOF
```

---

### **Issue 4.3: Service not responding**

**Symptoms:**
```bash
# From control plane:
$ curl -I http://10.43.126.136
curl: (7) Failed to connect to 10.43.126.136 port 80: Connection refused
```

**Diagnosis:**
```bash
# Check if pods are ready
kubectl get pods -n immich

# Check service endpoints
kubectl get endpoints -n immich immich-server

# Test direct pod connection
POD_IP=$(kubectl get pod -n immich -l app=immich-server -o jsonpath='{.items[0].status.podIP}')
curl -I http://$POD_IP:2283
```

**Solutions:**
```bash
# 1. Check target port matches container port
kubectl get svc immich-server -n immich -o yaml | grep targetPort
kubectl get pod -n immich -l app=immich-server -o yaml | grep containerPort

# 2. Check pod logs for errors
kubectl logs -n immich -l app=immich-server --tail=100

# 3. Restart deployment
kubectl rollout restart deployment/immich-server -n immich
```

---

## 5. Socat Proxy Issues

### **Issue 5.1: Socat service not running**

**Symptoms:**
```bash
$ sudo systemctl status immich-proxy
● immich-proxy.service - Immich App Proxy
   Loaded: loaded
   Active: failed (Result: exit-code)
```

**Diagnosis:**
```bash
# Check service logs
sudo journalctl -u immich-proxy -n 50

# Common errors:
# - "Address already in use" → port conflict
# - "Connection refused" → ClusterIP wrong
# - "Permission denied" → not running as root
```

**Solutions:**
```bash
# Port conflict - find what's using the port
sudo lsof -i :8080
sudo netstat -tlnp | grep 8080

# Fix service file
sudo nano /etc/systemd/system/immich-proxy.service

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart immich-proxy
```

---

### **Issue 5.2: Socat running but not accessible**

**Symptoms:**
```bash
$ sudo systemctl status immich-proxy
Active: active (running)

$ curl -I http://100.118.5.68:8080
curl: (7) Failed to connect
```

**Diagnosis:**
```bash
# Check if socat is actually listening
sudo netstat -tlnp | grep 8080
sudo lsof -i :8080

# Test from localhost
curl -I http://localhost:8080
curl -I http://100.118.5.68:8080

# Check firewall
sudo ufw status | grep 8080
```

**Solutions:**
```bash
# 1. Ensure socat binds to Tailscale IP
# Check service file:
ExecStart=/usr/bin/socat TCP-LISTEN:8080,bind=100.118.5.68,fork TCP:10.43.126.136:80
                                            ^^^^^^^^^^^^^^^^
                                            Must be Tailscale IP

# 2. Open firewall
sudo ufw allow from 100.101.92.95 to any port 8080 proto tcp

# 3. Test with netcat
echo -e "GET / HTTP/1.1\r\nHost: test\r\n\r\n" | nc 100.118.5.68 8080
```

---

### **Issue 5.3: Socat forwarding to wrong backend**

**Symptoms:**
- Socat running
- But returns wrong app or 404

**Diagnosis:**
```bash
# Check service file
sudo cat /etc/systemd/system/immich-proxy.service | grep ExecStart

# Verify ClusterIP
kubectl get svc -n immich immich-server -o wide
```

**Solution:**
```bash
# Update service file with correct ClusterIP
sudo nano /etc/systemd/system/immich-proxy.service

# Change:
ExecStart=/usr/bin/socat TCP-LISTEN:8080,bind=100.118.5.68,fork TCP:10.43.126.136:80
                                                                    ^^^^^^^^^^^^^^^
                                                                    Correct ClusterIP:Port

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart immich-proxy
```

---

## 6. Application-Specific Issues

### **Issue 6.1: Immich - 500 Internal Server Error**

**Diagnosis:**
```bash
# Check Immich server logs
kubectl logs -n immich deployment/immich-server --tail=100

# Common issues:
# - Database connection failed
# - Redis not reachable
# - Machine learning service down
```

**Solutions:**
```bash
# Check database
kubectl get pods -n immich | grep postgres
kubectl logs -n immich deployment/immich-postgres

# Check Redis
kubectl get pods -n immich | grep redis
kubectl logs -n immich deployment/immich-redis

# Restart all
kubectl rollout restart deployment -n immich
```

---

### **Issue 6.2: PostgreSQL won't start**

**Symptoms:**
```bash
$ kubectl get pods -n immich
immich-postgres-xxx   0/1     CrashLoopBackOff
```

**Diagnosis:**
```bash
kubectl logs -n immich deployment/immich-postgres --tail=50

# Common error:
# "directory not empty" / "lost+found exists"
```

**Solution:**
```bash
# Add PGDATA environment variable
kubectl set env deployment/immich-postgres -n immich \
  PGDATA=/var/lib/postgresql/data/pgdata

# Or edit deployment:
kubectl edit deployment immich-postgres -n immich

# Add:
env:
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata
```

---

### **Issue 6.3: App accessible locally but not via domain**

**Symptoms:**
```bash
# Works:
$ curl -I http://100.118.5.68:8080
HTTP/1.1 200 OK

# Doesn't work:
$ curl -I https://photos.yourdomain.com
HTTP/2 502
```

**This means:**
- ✅ App is running
- ✅ Socat is working
- ❌ VPS Traefik routing broken

**Diagnosis:**
```bash
# Check Traefik route
ssh root@VPS 'cat /etc/traefik/dynamic/immich.yml'

# Check Traefik logs
ssh root@VPS 'docker logs traefik --tail 50'
```

**Solution:**
```bash
# Verify backend URL in Traefik config
ssh root@VPS 'cat /etc/traefik/dynamic/immich.yml' | grep -A3 servers

# Should be:
servers:
  - url: "http://100.118.5.68:8080"  # Correct Tailscale IP + port

# Restart Traefik
ssh root@VPS 'cd /etc/traefik && docker compose restart'
```

---

## 7. Performance Issues

### **Issue 7.1: Slow loading times**

**Symptoms:**
- Pages take 5-10+ seconds to load
- Images load slowly

**Diagnosis:**
```bash
# Test latency
tailscale ping 100.118.5.68  # From VPS
tailscale ping 100.101.92.95  # From control plane

# Check resource usage
kubectl top pods -n immich
kubectl top nodes

# Check network throughput
iperf3 -c 100.118.5.68  # From VPS (install iperf3 first)
```

**Solutions:**
```bash
# 1. Increase app resources
kubectl edit deployment immich-server -n immich
# Increase memory/CPU limits

# 2. Enable caching in Traefik
# Add to /etc/traefik/traefik.yml:
http:
  middlewares:
    cache:
      plugin:
        souin:
          default_cache:
            ttl: 3600s

# 3. Optimize home upload bandwidth
# Check ISP upload speed: https://fast.com

# 4. Use CDN for static assets (advanced)
```

---

### **Issue 7.2: High CPU usage on control plane**

**Diagnosis:**
```bash
# Check what's using CPU
kubectl top pods -A

# Check node
top
htop
```

**Solutions:**
```bash
# Limit resource usage
kubectl set resources deployment immich-server -n immich \
  --limits=cpu=2,memory=4Gi \
  --requests=cpu=500m,memory=1Gi

# Add more worker nodes to cluster
```

---

### **Issue 7.3: Database growing too large**

**Diagnosis:**
```bash
# Check PVC size
kubectl get pvc -n immich

# Enter postgres pod and check
kubectl exec -it -n immich deployment/immich-postgres -- bash
du -sh /var/lib/postgresql/data
```

**Solutions:**
```bash
# Expand PVC (if storage class supports it)
kubectl patch pvc immich-postgres -n immich \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# Or backup and restore to new larger PVC
```

---

## 🛠️ Advanced Debugging

### **Enable Verbose Logging**

**Traefik:**
```yaml
# /etc/traefik/traefik.yml
log:
  level: DEBUG
```

**Kubernetes:**
```bash
kubectl logs -f deployment/immich-server -n immich --all-containers=true
```

**Socat:**
```bash
# Add -v to socat command for verbose
ExecStart=/usr/bin/socat -v TCP-LISTEN:8080,bind=100.118.5.68,fork TCP:10.43.126.136:80
```

---

### **Network Packet Capture**

```bash
# On VPS:
sudo tcpdump -i any port 443 -w /tmp/vps-traffic.pcap

# On control plane:
sudo tcpdump -i tailscale0 -w /tmp/tailscale-traffic.pcap

# Analyze with Wireshark
```

---

### **Test Each Layer Independently**

```bash
# Layer 1: DNS
dig +short photos.yourdomain.com

# Layer 2: VPS Traefik
curl -I -H "Host: photos.yourdomain.com" http://45.8.133.192

# Layer 3: Tailscale
ssh root@VPS 'curl -I http://100.118.5.68:8080'

# Layer 4: Socat
curl -I http://100.118.5.68:8080  # From control plane

# Layer 5: Kubernetes Service
curl -I http://10.43.126.136  # From control plane

# Layer 6: Pod
kubectl port-forward -n immich deployment/immich-server 2283:2283
curl -I http://localhost:2283
```

---

## 📞 Getting Help

### **Collect Diagnostic Information**

```bash
# Run this and share output when asking for help:
cat << 'EOF' > /tmp/mynodeone-debug.sh
#!/bin/bash
echo "=== DNS ==="
dig +short photos.yourdomain.com

echo "=== Kubernetes Pods ==="
kubectl get pods -A

echo "=== Kubernetes Services ==="
kubectl get svc -A

echo "=== Tailscale Status ==="
tailscale status

echo "=== Socat Services ==="
sudo systemctl list-units | grep proxy

echo "=== Firewall ==="
sudo ufw status numbered

echo "=== Recent Logs ==="
sudo journalctl -u immich-proxy -n 20 --no-pager
EOF

bash /tmp/mynodeone-debug.sh > /tmp/mynodeone-debug.txt
cat /tmp/mynodeone-debug.txt
```

### **Community Resources**

- GitHub Issues: https://github.com/vinsac/MyNodeOne/issues
- Discord: [Your Discord Link]
- Documentation: `docs/guides/`

---

## ✅ Prevention Checklist

Before deploying:
- [ ] DNS configured correctly
- [ ] Firewall rules added on both VPS and control plane
- [ ] Tailscale running on both machines
- [ ] Socat proxy created and enabled
- [ ] Kubernetes pods running
- [ ] Service has ClusterIP assigned
- [ ] Traefik route configured
- [ ] Test each layer independently

---

**Still stuck?** Open an issue with your debug output: https://github.com/vinsac/MyNodeOne/issues/new
