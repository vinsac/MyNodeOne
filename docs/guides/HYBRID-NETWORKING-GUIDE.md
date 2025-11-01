# Hybrid Networking Architecture Guide

**Understanding MyNodeOne Hybrid Setup Networking**

---

## 🎯 Overview

This guide explains how networking works in a hybrid MyNodeOne setup, where your control plane runs at home and a VPS edge node provides internet access.

**Target Audience:** Technical users, system administrators, DevOps engineers

---

## 📐 Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        INTERNET USERS                           │
│                    (Anywhere in the world)                      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ HTTPS (443)
                         │ HTTP (80) → redirects to HTTPS
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      VPS EDGE NODE                              │
│                   (Public IP: 45.x.x.x)                         │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              Traefik Reverse Proxy                     │   │
│  │  • SSL/TLS Termination (Let's Encrypt)                │   │
│  │  • Dynamic routing (*.yourdomain.com)                 │   │
│  │  • HTTPS redirect                                     │   │
│  │  • Rate limiting & security                           │   │
│  └──────────────────────┬─────────────────────────────────┘   │
│                         │                                       │
└─────────────────────────┼───────────────────────────────────────┘
                          │
                          │ Tailscale VPN (Encrypted)
                          │ 100.x.x.x → 100.x.x.x
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                    CONTROL PLANE (Home)                         │
│                 (Tailscale IP: 100.x.x.x)                       │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐   │
│  │           Socat Proxy (Optional but Recommended)       │   │
│  │  • Listens on: 100.x.x.x:8080                         │   │
│  │  • Forwards to: Kubernetes ClusterIP                  │   │
│  │  • Systemd service for persistence                    │   │
│  └──────────────────────┬─────────────────────────────────┘   │
│                         │                                       │
│  ┌────────────────────────────────────────────────────────┐   │
│  │              Kubernetes (k3s)                          │   │
│  │                                                        │   │
│  │  ┌──────────────────────────────────────────────┐    │   │
│  │  │  MetalLB Load Balancer                        │    │   │
│  │  │  • Assigns IPs: 100.x.x.207, 100.x.x.208      │    │   │
│  │  │  • Only routable INSIDE cluster               │    │   │
│  │  └────────────┬──────────────────────────────────┘    │   │
│  │               │                                        │   │
│  │  ┌────────────▼──────────────────────────────────┐    │   │
│  │  │  Kubernetes Services (ClusterIP/LoadBalancer) │    │   │
│  │  │  • immich-server: 10.43.x.x:80                │    │   │
│  │  │  • jellyfin: 10.43.x.x:80                     │    │   │
│  │  │  • vault: 10.43.x.x:80                        │    │   │
│  │  └────────────┬──────────────────────────────────┘    │   │
│  │               │                                        │   │
│  │  ┌────────────▼──────────────────────────────────┐    │   │
│  │  │           Application Pods                     │    │   │
│  │  │  • Immich (port 2283)                         │    │   │
│  │  │  • Jellyfin (port 8096)                       │    │   │
│  │  │  • Vaultwarden (port 80)                      │    │   │
│  │  │  • Homepage (port 3000)                       │    │   │
│  │  └───────────────────────────────────────────────┘    │   │
│  │                                                        │   │
│  └────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🔍 Network Layers Explained

### **Layer 1: Public Internet → VPS**

**Technology:** Standard HTTP/HTTPS  
**IP:** Public IPv4 (e.g., 45.8.133.192)  
**Ports:** 80 (HTTP), 443 (HTTPS)

**Components:**
- DNS: `photos.yourdomain.com` → VPS Public IP
- Firewall: UFW allowing ports 80, 443
- Traefik: Reverse proxy & SSL termination

**Request Flow:**
```
User Browser
  → DNS Lookup (photos.yourdomain.com → 45.8.133.192)
  → TCP Connection to 45.8.133.192:443
  → TLS Handshake (SSL certificate verification)
  → HTTPS Request to Traefik
```

---

### **Layer 2: VPS → Control Plane (Tailscale VPN)**

**Technology:** Tailscale (WireGuard VPN)  
**IP Range:** 100.64.0.0/10 (CGNAT range)  
**Ports:** Dynamic (WireGuard protocol)  
**Encryption:** Yes (WireGuard encryption)

**Components:**
- Tailscale Mesh Network
- Encrypted tunnel between VPS and Control Plane
- No port forwarding required
- NAT traversal handled automatically

**Request Flow:**
```
Traefik on VPS
  → Routes based on Host header (photos.yourdomain.com)
  → Sends to backend: http://100.118.5.68:8080
  → Tailscale encrypts traffic
  → Sends through VPN tunnel
  → Control Plane receives on 100.118.5.68:8080
```

**Why Tailscale?**
- ✅ No need to expose home IP
- ✅ Encrypted by default
- ✅ Works behind NAT/firewall
- ✅ Automatic mesh routing
- ✅ Easy device management

---

### **Layer 3: Control Plane Socat Proxy**

**Technology:** Socat (TCP relay)  
**Listen:** Tailscale IP:8080 (e.g., 100.118.5.68:8080)  
**Forward:** Kubernetes ClusterIP:80 (e.g., 10.43.126.136:80)

**Why is this needed?**

**Problem:** MetalLB-assigned IPs (like 100.118.5.207) are NOT routable from outside the cluster, even via Tailscale.

**Kubernetes Networking Facts:**
- ClusterIP: Only accessible from within cluster
- NodePort: Only works on node's actual IP (but k3s doesn't bind by default)
- LoadBalancer (MetalLB): Assigns IP from pool, but NOT routable outside cluster network

**Socat Solution:**
```bash
# Socat listens on Tailscale IP (routable from VPS)
# Forwards to ClusterIP (accessible from control plane node)

socat TCP-LISTEN:8080,bind=100.118.5.68,fork TCP:10.43.126.136:80
     │              │                      │
     │              │                      └─ ClusterIP of app service
     │              └─ Tailscale IP (routable from VPS)
     └─ Listen port
```

**Benefits:**
- ✅ Simple and lightweight
- ✅ No complex Kubernetes networking changes
- ✅ Works with any service
- ✅ Easy to manage (systemd service)

**Alternative Solutions (not used):**
- ❌ NodePort: k3s doesn't bind to node IP by default
- ❌ Host networking: Security risk, port conflicts
- ❌ Ingress controller: Overkill, adds complexity
- ❌ Service mesh (Istio/Linkerd): Too heavy for simple use case

---

### **Layer 4: Kubernetes Services**

**Technology:** Kubernetes Services  
**Types Used:** LoadBalancer (with MetalLB)  
**IP Range:** 100.118.5.200-100.118.5.250 (configured in MetalLB)

**Service Configuration Example:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-server
  namespace: immich
spec:
  type: LoadBalancer
  ports:
  - port: 80              # Service port
    targetPort: 2283      # Container port
  selector:
    app: immich-server
```

**What happens:**
1. Service created with type LoadBalancer
2. MetalLB assigns IP from pool (e.g., 100.118.5.207)
3. Service accessible at:
   - From pods: `immich-server.immich.svc.cluster.local:80`
   - From nodes: `10.43.126.136:80` (ClusterIP)
   - From external (MetalLB): `100.118.5.207:80` (NOT routable via Tailscale)
4. Service forwards to pod on port 2283

---

### **Layer 5: Application Pods**

**Technology:** Docker containers in Kubernetes  
**Network:** Pod network (10.42.0.0/16)  
**Ports:** Application-specific

**Pod Configuration Example:**
```yaml
spec:
  containers:
  - name: immich-server
    image: ghcr.io/immich-app/immich-server:release
    ports:
    - containerPort: 2283
    env:
    - name: DB_HOSTNAME
      value: immich-postgres
```

**Pod Networking:**
- Each pod gets IP from 10.42.0.0/16
- Pods can communicate directly via pod IP
- DNS: `<service-name>.<namespace>.svc.cluster.local`
- Example: `immich-postgres.immich.svc.cluster.local`

---

## 🌊 Complete Request Flow

**Example: User accesses `https://photos.yourdomain.com`**

```
1. DNS Resolution
   User Browser → DNS Server → 45.8.133.192

2. TLS Connection
   Browser → VPS:443 → TLS Handshake → SSL Certificate Verified

3. Traefik Routing
   VPS Traefik:
   - Receives: Host: photos.yourdomain.com
   - Matches route: immich
   - Backend: http://100.118.5.68:8080
   - Forwards request

4. Tailscale VPN
   VPS → Tailscale Tunnel (encrypted) → Control Plane

5. Socat Proxy
   Control Plane:
   - Receives: 100.118.5.68:8080
   - Forwards: 10.43.126.136:80

6. Kubernetes Service
   Service (immich-server):
   - Receives: 10.43.126.136:80
   - Selects pod: 10.42.0.105
   - Forwards: 10.42.0.105:2283

7. Application Pod
   Immich Pod:
   - Receives: localhost:2283
   - Processes request
   - Returns HTML response

8. Response Path (reverse of above)
   Pod → Service → Socat → Tailscale → Traefik → User
```

**Total Latency:** ~50-200ms depending on:
- Home internet upload speed
- VPS location
- Tailscale routing efficiency

---

## 📊 Data Flow & Bandwidth (IMPORTANT!)

### **🔴 Critical Understanding: All Traffic Flows Through VPS**

**Question:** When I upload a photo to Immich, does it go through the VPS?  
**Answer:** **YES! ALL traffic flows through the VPS in BOTH directions.**

### **📤 Upload Example: Photo to Immich**

```
YOU → VPS → Control Plane → Immich

Detailed Flow:
1. Browser: Upload photo.jpg (5MB)
   → HTTPS POST to photos.curiios.com
   
2. VPS (Traefik):
   → Receives: 5MB upload (inbound to VPS)
   → Decrypts HTTPS
   → Routes to: http://100.118.5.68:8080
   → Sends: 5MB via Tailscale (outbound from VPS)
   
3. Tailscale VPN:
   → Encrypted tunnel: VPS → Control Plane
   → Transfer: 5MB data
   
4. Control Plane (Socat):
   → Receives: 5MB on 100.118.5.68:8080
   → Forwards to: 10.43.126.136:80
   
5. Kubernetes → Immich Pod:
   → Saves: 5MB to disk

VPS Bandwidth Used: 5MB inbound + 5MB outbound = 10MB total
```

### **📥 Download Example: Photo from Immich**

```
Immich → Control Plane → VPS → YOU

Detailed Flow:
1. Immich Pod:
   → Reads: photo.jpg (5MB) from disk
   
2. Kubernetes → Socat:
   → Returns: 5MB via ClusterIP
   
3. Socat → Tailscale:
   → Forwards: 5MB to VPS
   
4. Tailscale VPN:
   → Encrypted tunnel: Control Plane → VPS
   → Transfer: 5MB data
   
5. VPS (Traefik):
   → Receives: 5MB from backend (inbound to VPS)
   → Encrypts HTTPS
   → Sends: 5MB to browser (outbound from VPS)
   
6. Browser:
   → Displays: photo.jpg

VPS Bandwidth Used: 5MB inbound + 5MB outbound = 10MB total
```

---

### **⚠️ Bandwidth Implications**

#### **VPS Bandwidth = 2x Your Data**

```bash
# Example: Upload 1000 photos (5GB total)
Actual data: 5GB
VPS bandwidth used:
  - Inbound: 5GB (from your computer)
  - Outbound: 5GB (to control plane)
  - Total: 10GB

# Example: Download 1000 photos (5GB total)
Actual data: 5GB
VPS bandwidth used:
  - Inbound: 5GB (from control plane)
  - Outbound: 5GB (to your computer)
  - Total: 10GB

# Monthly usage for active Immich use:
Upload 10,000 photos: ~100GB VPS bandwidth
Stream 100 movies: ~500GB VPS bandwidth
Access apps 1000x: ~10GB VPS bandwidth
```

#### **Typical VPS Bandwidth Limits**

| Provider | Monthly Limit | Cost if Exceeded |
|----------|---------------|------------------|
| Contabo | 32TB | €1/TB |
| Hetzner | 20TB | €1.19/TB |
| DigitalOcean | 1-12TB | $0.01/GB |
| Vultr | 1-10TB | $0.01/GB |

**Most hybrid setups use < 1TB/month** (well within limits)

---

### **🚀 Performance Bottlenecks**

#### **Bottleneck 1: Home Upload Speed**

```
Downloading photo from Immich:
  Your browser ← VPS: Limited by YOUR download speed ✓
  VPS ← Control Plane: Limited by HOME upload speed ⚠️
                       ↑ BOTTLENECK!

Why? Control plane must UPLOAD to VPS to send data out.

Example:
  Home Upload: 10 Mbps (1.25 MB/s)
  Download 100MB photo: ~80 seconds
  
Solution: Get faster home internet or use VPS-only deployment
```

#### **Bottleneck 2: VPS Network**

```
Most VPS providers:
  - 1 Gbps network (125 MB/s)
  - Rarely the bottleneck
  - Home internet is usually slower
```

#### **Bottleneck 3: Tailscale VPN**

```
Typical Tailscale performance:
  - Good: 100-500 Mbps (12-60 MB/s)
  - Depends on: NAT traversal, routing path
  - Usually NOT the bottleneck
```

---

### **💡 Performance Optimization**

#### **For Large File Transfers (Photos/Videos):**

```bash
# Option 1: Direct Tailscale access (bypass VPS)
# Access Immich directly via Tailscale
https://100.118.5.207  # Direct to control plane
# Upload speed: Limited by home upload
# Download speed: Limited by home download
# No VPS bandwidth used!

# Option 2: Temporary uploads via home network
http://immich.mynodeone.local  # Local network access
# Upload speed: Gigabit LAN
# Only when home
```

#### **For Streaming Media (Jellyfin):**

```bash
# Option 1: Use VPS for remote access only
# Option 2: Transcode to lower quality for remote
# Option 3: Download locally before watching

# Bandwidth calculation:
1080p video: ~5 GB/hour
720p video: ~2 GB/hour
480p video: ~1 GB/hour

# Through VPS = 2x bandwidth usage!
```

---

### **📈 Bandwidth Monitoring**

#### **On VPS:**

```bash
# Install vnstat
apt install vnstat

# Check bandwidth usage
vnstat -m  # Monthly
vnstat -d  # Daily
vnstat -h  # Hourly

# Monitor live
vnstat -l
```

#### **On Control Plane:**

```bash
# Check Tailscale traffic
sudo tailscale status --json | jq '.Peer[] | {hostname, tx, rx}'

# Monitor network usage
iftop -i tailscale0
```

---

### **🎯 Capacity Planning**

#### **Estimated Bandwidth Needs:**

| Use Case | Monthly VPS Bandwidth |
|----------|---------------------|
| Light use (web apps, occasional access) | < 100 GB |
| Moderate use (photo uploads, some streaming) | 100-500 GB |
| Heavy use (daily photo uploads, video streaming) | 500-2000 GB |
| Very heavy (large library sync, frequent streaming) | 2-10 TB |

#### **When to Upgrade VPS:**

```
Symptoms of bandwidth limit approaching:
  - Provider throttling warnings
  - Slow transfer speeds
  - Overage charges

Solutions:
1. Upgrade VPS plan (more bandwidth)
2. Use direct Tailscale access when home
3. Optimize data transfer (compression, lower quality)
4. Move high-bandwidth apps to VPS storage
```

---

### **✅ Summary: Traffic Flow**

**Key Takeaway:** 
```
Everything flows through VPS = 2x bandwidth usage

Upload:  You → VPS → Home → Storage
Download: Storage → Home → VPS → You

This is the trade-off for:
  ✅ Accessing home apps from anywhere
  ✅ HTTPS with valid SSL certificates
  ✅ No port forwarding on home network
  ✅ No exposing home IP address

Alternative: Direct Tailscale access
  ✅ No VPS bandwidth usage
  ❌ Only works when Tailscale connected
  ❌ No custom domain
  ❌ Requires Tailscale app on device
```

---

## 🔐 Security Considerations

### **Defense in Depth:**

**Layer 1: VPS Firewall (UFW)**
```bash
# Only allow essential ports
sudo ufw allow 22/tcp     # SSH
sudo ufw allow 80/tcp     # HTTP
sudo ufw allow 443/tcp    # HTTPS
sudo ufw allow 41641/udp  # Tailscale
sudo ufw default deny incoming
sudo ufw enable
```

**Layer 2: Traefik Security**
- Automatic HTTPS redirect
- Let's Encrypt SSL certificates
- Rate limiting (optional)
- IP whitelisting (optional)
- HTTP headers (HSTS, CSP)

**Layer 3: Tailscale Encryption**
- WireGuard protocol (state-of-the-art encryption)
- Key rotation
- Access control lists (ACLs)
- Device authorization required

**Layer 4: Control Plane Firewall**
```bash
# Allow Tailscale network
sudo ufw allow in on tailscale0

# Allow VPS access to specific ports
sudo ufw allow from 100.101.92.95 to any port 8080 proto tcp
```

**Layer 5: Kubernetes Network Policies (optional)**
```yaml
# Restrict inter-pod communication
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: immich-network-policy
spec:
  podSelector:
    matchLabels:
      app: immich-server
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: immich-postgres
```

---

## 📊 Port Reference

### **VPS Edge Node:**
| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH management |
| 80 | TCP | HTTP (redirects to 443) |
| 443 | TCP | HTTPS (Traefik) |
| 41641 | UDP | Tailscale (dynamic) |

### **Control Plane:**
| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH management |
| 6443 | TCP | Kubernetes API |
| 8080 | TCP | Socat proxy (app-specific) |
| 8081 | TCP | Socat proxy (app 2) |
| 8082 | TCP | Socat proxy (app 3) |
| 30000-32767 | TCP | K8s NodePort range (optional) |
| 41641 | UDP | Tailscale |

### **Application Containers:**
| App | Container Port | Service Port | Socat Port |
|-----|----------------|--------------|------------|
| Immich | 2283 | 80 | 8080 |
| Jellyfin | 8096 | 80 | 8081 |
| Vaultwarden | 80 | 80 | 8082 |
| Homepage | 3000 | 80 | 8083 |

---

## 🛠️ Configuration Files

### **Traefik Dynamic Route (VPS):**
```yaml
# /etc/traefik/dynamic/immich.yml
http:
  routers:
    immich:
      rule: "Host(`photos.yourdomain.com`)"
      service: immich-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
    
    immich-http:
      rule: "Host(`photos.yourdomain.com`)"
      service: immich-service
      entryPoints:
        - web
      middlewares:
        - https-redirect

  services:
    immich-service:
      loadBalancer:
        servers:
          - url: "http://100.118.5.68:8080"

  middlewares:
    https-redirect:
      redirectScheme:
        scheme: https
        permanent: true
```

### **Socat Systemd Service (Control Plane):**
```ini
# /etc/systemd/system/immich-proxy.service
[Unit]
Description=Immich Socat Proxy
After=network.target k3s.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:8080,bind=100.118.5.68,fork TCP:10.43.126.136:80
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### **Kubernetes Service:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-server
  namespace: immich
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 2283
  selector:
    app: immich-server
```

---

## 🐛 Common Issues

### **Issue 1: "502 Bad Gateway" from Traefik**

**Symptoms:**
- HTTPS works (SSL certificate valid)
- But returns 502 error

**Diagnosis:**
```bash
# On VPS:
curl -I http://100.118.5.68:8080
# If connection fails:
```

**Possible Causes:**
1. Socat not running on control plane
2. Wrong IP/port in Traefik config
3. Firewall blocking connection
4. Kubernetes service not ready

**Solution:**
```bash
# On control plane:
sudo systemctl status immich-proxy
sudo systemctl restart immich-proxy

# Check firewall:
sudo ufw status | grep 8080
```

---

### **Issue 2: SSL Certificate Not Issuing**

**Symptoms:**
- Browser shows "Certificate Error"
- Traefik logs show ACME errors

**Diagnosis:**
```bash
# On VPS:
docker logs traefik | grep -i acme
```

**Possible Causes:**
1. Domain not pointing to VPS
2. Port 80 blocked (needed for HTTP challenge)
3. Rate limit hit (Let's Encrypt)

**Solution:**
```bash
# Verify DNS:
dig +short photos.yourdomain.com
# Should return VPS IP

# Check port 80:
sudo ufw status | grep 80

# Check Traefik ACME:
docker exec traefik cat /etc/traefik/acme.json
```

---

### **Issue 3: MetalLB IP Not Reachable**

**Symptoms:**
- Service has External-IP assigned
- But cannot access from outside cluster

**This is EXPECTED behavior!**

MetalLB IPs are only routable within the cluster network, NOT via Tailscale.

**Solution:** Use socat proxy (as documented above)

---

## 💡 Best Practices

### **1. Use Systemd for Persistence**
Always create systemd services for socat proxies:
- Survives reboots
- Automatic restart on failure
- Easy to manage (`systemctl`)

### **2. One Socat Per App**
Don't multiplex apps on same port:
- Easier to debug
- Independent restart
- Clear port allocation

### **3. Document Port Assignments**
Keep a port mapping file:
```
# ~/mynodeone-ports.txt
8080 - Immich
8081 - Jellyfin
8082 - Vaultwarden
8083 - Homepage
```

### **4. Firewall Rules Per App**
Add specific UFW rules:
```bash
sudo ufw allow from <VPS_TAILSCALE_IP> to any port 8080 proto tcp comment "Immich"
```

### **5. Monitor Socat Processes**
```bash
# Add to crontab:
*/5 * * * * systemctl is-active immich-proxy || systemctl restart immich-proxy
```

---

## 🔄 Scaling Considerations

### **Multiple Apps:**
- Each app needs unique socat port (8080, 8081, etc.)
- Each app needs Traefik route
- Each app needs systemd service

### **Multiple VPS:**
- Traefik can load balance across VPS
- Geo-routing for latency optimization
- Failover for high availability

### **Multiple Control Planes:**
- Kubernetes federation
- Service mesh (Istio/Linkerd)
- Global load balancing

---

## 📚 Further Reading

- **Tailscale Documentation:** https://tailscale.com/kb/
- **Traefik Documentation:** https://doc.traefik.io/traefik/
- **Kubernetes Services:** https://kubernetes.io/docs/concepts/services-networking/service/
- **MetalLB:** https://metallb.universe.tf/
- **Socat Manual:** https://linux.die.net/man/1/socat

---

## ✅ Summary

**Hybrid networking requires:**
1. ✅ Public VPS with Traefik
2. ✅ Tailscale VPN connecting VPS ↔ Control Plane
3. ✅ Socat proxy on control plane (bridges Tailscale → K8s)
4. ✅ Kubernetes services (LoadBalancer type)
5. ✅ Firewall rules allowing connections
6. ✅ Systemd services for persistence

**Traffic flow:**
```
Internet → VPS (Traefik + SSL) 
        → Tailscale (encrypted)
        → Control Plane (socat)
        → Kubernetes (service)
        → Pod (application)
```

**Key insight:** MetalLB IPs are NOT routable via Tailscale, hence socat proxy needed.

---

**Questions?** See `docs/guides/HYBRID-TROUBLESHOOTING.md`
