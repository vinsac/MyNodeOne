# Multi-Domain Architecture in MyNodeOne

## **Core Concept: One Domain Per App**

MyNodeOne supports multiple apps, each with its own unique domain:

```
App A: exampleA.com      → appA.mynodeone.local (local)
App B: exampleB.com      → appB.mynodeone.local (local)  
App C: mysaas.net        → saas.mynodeone.local (local)
Immich: photos.family.io → photos.mynodeone.local (local)
```

**Each app is completely independent in terms of domains.**

---

## **How Routing Works**

### **Architecture Overview**

```
┌────────────────────────────────────────────────────────┐
│  Internet                                              │
└──────────────────┬─────────────────────────────────────┘
                   │
                   │ DNS Resolution
                   │
          ┌────────┴────────┐
          │                 │
    exampleA.com      exampleB.com
          │                 │
          ↓                 ↓
┌─────────────────────────────────────────────────────────┐
│  VPS Edge Node (Public IP: 147.182.123.45)             │
│  Traefik Reverse Proxy                                 │
├─────────────────────────────────────────────────────────┤
│  Routes based on Host header:                          │
│                                                         │
│  Host: exampleA.com      → Tailscale → App A           │
│  Host: exampleB.com      → Tailscale → App B           │
│  Host: photos.family.io  → Tailscale → Immich          │
└──────────────────────┬──────────────────────────────────┘
                       │
                       │ Tailscale Mesh (encrypted)
                       │
┌──────────────────────┴──────────────────────────────────┐
│  MyNodeOne Cluster (Control Plane + Workers)           │
├─────────────────────────────────────────────────────────┤
│  App A: appA.mynodeone.local (10.20.30.40)             │
│  App B: appB.mynodeone.local (10.20.30.50)             │
│  Immich: photos.mynodeone.local (10.20.30.60)          │
└─────────────────────────────────────────────────────────┘
```

---

## **Traefik Host-Based Routing**

Traefik uses HTTP `Host` headers to route traffic:

```yaml
# App A Route
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: appa-public
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`exampleA.com`)
      kind: Rule
      services:
        - name: appa
          port: 80
  tls:
    certResolver: letsencrypt
```

```yaml
# App B Route
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: appb-public
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`exampleB.com`)
      kind: Rule
      services:
        - name: appb
          port: 80
  tls:
    certResolver: letsencrypt
```

**Key Point:** Different `Host()` rules mean different apps can use completely different domains.

---

## **Apex Domain vs Subdomain**

You can choose between:

### **Option 1: Subdomain (Default)**
```
Main app:  voting.vinaysachdeva.com
Services:  vote.vinaysachdeva.com
           result.vinaysachdeva.com
```

### **Option 2: Apex/Root Domain**
```
Main app:  vinaysachdeva.com
Services:  vote.vinaysachdeva.com
           result.vinaysachdeva.com
```

**Both work! The script now asks which you prefer.**

---

## **DNS Configuration**

### **Scenario: Multiple Apps, Different Domains**

**App A (exampleA.com):**
```
At your DNS provider for exampleA.com:
A    @              147.182.123.45   # Root domain
A    vote           147.182.123.45   # vote.exampleA.com
A    api            147.182.123.45   # api.exampleA.com
```

**App B (exampleB.com):**
```
At your DNS provider for exampleB.com:
A    @              147.182.123.45   # Root domain
A    dashboard      147.182.123.45   # dashboard.exampleB.com
```

**All point to the same VPS IP!** Traefik routes by hostname, not IP.

---

## **SSL Certificates**

Let's Encrypt issues certificates per domain:

```
exampleA.com            → Certificate 1
vote.exampleA.com       → Certificate 2
api.exampleA.com        → Certificate 3
exampleB.com            → Certificate 4
dashboard.exampleB.com  → Certificate 5
```

**Automatic!** Traefik requests certificates when traffic first arrives.

---

## **Local Access (Always Works)**

Regardless of public domain, local DNS always works:

```
App A:  http://appa.mynodeone.local       (10.20.30.40)
App B:  http://appb.mynodeone.local       (10.20.30.50)
Immich: http://photos.mynodeone.local     (10.20.30.60)
```

**Local DNS is managed by `/etc/hosts` and service registry.**

---

## **Example: Two Separate Apps**

### **Voting App**
```bash
cd /tmp/example-voting-app
bash ~/MyNodeOne/external-apps/scripts/deploy.sh

# When prompted:
App name: voting-app
Subdomain: voting
Public: y
Base domain: vinaysachdeva.com
Domain type: 2 (apex domain)

# Result:
Local:  http://voting.mynodeone.local
Public: https://vinaysachdeva.com  ← Apex domain!
```

### **Blog App**
```bash
cd /tmp/my-blog
bash ~/MyNodeOne/external-apps/scripts/deploy.sh

# When prompted:
App name: blog
Subdomain: blog
Public: y
Base domain: myblog.com
Domain type: 1 (subdomain)

# Result:
Local:  http://blog.mynodeone.local
Public: https://blog.myblog.com  ← Subdomain
```

**Both apps run simultaneously, each with its own domain!**

---

## **Traffic Flow Example**

### **Request to vinaysachdeva.com**
```
1. Browser → DNS lookup → 147.182.123.45 (VPS IP)
2. Browser → HTTPS to VPS
3. VPS Traefik reads Host: vinaysachdeva.com
4. Traefik matches IngressRoute: Host(`vinaysachdeva.com`)
5. Traefik → Tailscale mesh → Control plane
6. Reaches voting-app service (10.20.30.40)
7. Response flows back
```

### **Request to myblog.com**
```
1. Browser → DNS lookup → 147.182.123.45 (same VPS!)
2. Browser → HTTPS to VPS
3. VPS Traefik reads Host: myblog.com
4. Traefik matches IngressRoute: Host(`blog.myblog.com`)
5. Traefik → Tailscale mesh → Control plane
6. Reaches blog service (10.20.30.50)
7. Response flows back
```

**Same VPS, different routing based on hostname!**

---

## **manage-app-visibility.sh**

This script configures public access by:
1. Asking which app to make public
2. Asking which domain(s) to use
3. Creating Traefik IngressRoutes
4. Syncing config to VPS edge nodes
5. Requesting SSL certificates

**It supports apex domains via `@` notation:**
```bash
# In manage-app-visibility.sh, you can enter:
Domain: @vinaysachdeva.com  # @ means apex/root domain
# Or:
Domain: vinaysachdeva.com   # Also works
```

---

## **Limitations**

### **Same Domain, Different Apps**
**NOT SUPPORTED:**
```
App A: myapp.com
App B: myapp.com  ← Conflict! Same domain
```

**SUPPORTED:**
```
App A: myapp.com
App B: api.myapp.com      ← Different subdomain
App C: admin.myapp.com    ← Different subdomain
```

### **Multiple Domains for One Service**
**Currently NOT automatic**, but possible manually:
```yaml
# You can manually create IngressRoutes for same app
routes:
  - match: Host(`app.com`) || Host(`www.app.com`)
```

---

## **Key Takeaways**

1. ✅ **Each app can have its own domain** (exampleA.com, exampleB.com)
2. ✅ **Apex domains supported** (vinaysachdeva.com, not just voting.vinaysachdeva.com)
3. ✅ **All apps point to same VPS IP** (Traefik routes by hostname)
4. ✅ **Local DNS always works** (voting.mynodeone.local)
5. ✅ **Automatic SSL per domain** (Let's Encrypt)
6. ✅ **Independent apps don't conflict** (different namespaces, domains, IPs)

---

## **Testing Multi-Domain Setup**

```bash
# Deploy App A
cd /tmp/voting-app
bash ~/MyNodeOne/external-apps/scripts/deploy.sh
# Use: vinaysachdeva.com (apex domain)

# Deploy App B
cd /tmp/another-app
bash ~/MyNodeOne/external-apps/scripts/deploy.sh
# Use: myblog.com (apex domain)

# Configure DNS at registrars
# vinaysachdeva.com:  A @ → VPS_IP
# myblog.com:         A @ → VPS_IP (same IP!)

# Enable public access
sudo bash ~/MyNodeOne/scripts/manage-app-visibility.sh
# Select voting-app → vinaysachdeva.com
# Run again for another-app → myblog.com

# Both work:
curl https://vinaysachdeva.com    # App A
curl https://myblog.com            # App B
```

---

## **Architecture Diagram (Detailed)**

```
┌─────────────────────────────────────────────────────────────┐
│  DNS Registrars                                             │
├─────────────────────────────────────────────────────────────┤
│  vinaysachdeva.com  →  147.182.123.45                       │
│  myblog.com         →  147.182.123.45 (same IP!)            │
│  family.io          →  147.182.123.45 (same IP!)            │
└──────────────────────┬──────────────────────────────────────┘
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  VPS Edge Node (147.182.123.45)                             │
│  Traefik Reverse Proxy + SSL Termination                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  IngressRoute 1: Host(`vinaysachdeva.com`)                 │
│    → Tailscale → voting.mynodeone.local                    │
│                                                             │
│  IngressRoute 2: Host(`myblog.com`)                        │
│    → Tailscale → blog.mynodeone.local                      │
│                                                             │
│  IngressRoute 3: Host(`photos.family.io`)                  │
│    → Tailscale → photos.mynodeone.local                    │
│                                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │ Tailscale VPN Mesh
                       ↓
┌─────────────────────────────────────────────────────────────┐
│  MyNodeOne Cluster (mynodeone.local)                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Namespace: voting-app                                      │
│    Service: vote (LoadBalancer: 10.20.30.40)               │
│    DNS: voting.mynodeone.local                              │
│                                                             │
│  Namespace: blog                                            │
│    Service: blog (LoadBalancer: 10.20.30.50)               │
│    DNS: blog.mynodeone.local                                │
│                                                             │
│  Namespace: immich                                          │
│    Service: immich-server (LoadBalancer: 10.20.30.60)      │
│    DNS: photos.mynodeone.local                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Summary:** One VPS, multiple domains, multiple apps, all routed correctly by Traefik.
