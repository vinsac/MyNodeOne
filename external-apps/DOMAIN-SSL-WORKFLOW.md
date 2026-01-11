# Domain & SSL Workflow - Simple Explanation

## **The Big Picture**

When you deploy an app and say "yes" to public access, here's what happens:

```
1. App deployed → MyNodeOne cluster ✓
2. Local access works → http://voting.mynodeone.local ✓
3. Public access needs YOU to do 2 things:
   a. Add DNS records at your domain registrar
   b. Run one more MyNodeOne script
4. SSL certificates → Automatic (Let's Encrypt)
```

---

## **Step-by-Step: Making Your App Public**

### **What You Just Did (deploy.sh)**

✅ Deployed your app to Kubernetes  
✅ Got a LoadBalancer IP (e.g., 10.20.30.40)  
✅ App works locally: `http://voting.mynodeone.local`  

**But it's NOT on the internet yet!**

---

### **Step 1: YOU Configure DNS (At Your Domain Registrar)**

**What is this?** You need to tell the internet where your domain points.

**Where?** Go to your domain registrar (GoDaddy, Namecheap, Cloudflare, etc.)

**What to add:**

```
Type: A Record
Name: vote
Value: <YOUR_VPS_PUBLIC_IP>
TTL: 300 (or Auto)

Type: A Record  
Name: result
Value: <YOUR_VPS_PUBLIC_IP>
TTL: 300 (or Auto)
```

**What is YOUR_VPS_PUBLIC_IP?**
- This is the public IP of your VPS edge node (NOT the cluster LoadBalancer IP)
- Example: If your VPS is at Digital Ocean, it's the IP they gave you
- Find it: `curl ifconfig.me` (run this on your VPS)

**How long does it take?** 5 minutes to 2 hours (DNS propagation)

**Check if it worked:**
```bash
# On your laptop
dig vote.example.com

# Should show your VPS IP
```

---

### **Step 2: MyNodeOne Configures Routing & SSL**

**What is this?** Tell MyNodeOne to route traffic from your domain to your app.

**Run this on control plane:**
```bash
sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
```

**What it does:**
1. Shows you all apps in the cluster
2. You select which app to make public
3. You select which domain(s) to use
4. It configures Traefik (the router)
5. It tells your VPS edge node about the route
6. **It automatically requests SSL certificates from Let's Encrypt**

**Output:**
```
✓ Configured routing for vote.example.com
✓ SSL certificate requested (takes ~30 seconds)
✓ App is now public!
```

---

### **Step 3: Access Your App**

**Wait a few minutes**, then:

```bash
https://vote.example.com    ← Automatic HTTPS!
https://result.example.com  ← Automatic HTTPS!
```

**SSL is automatic!** Let's Encrypt gives you a free, valid SSL certificate.

---

## **Common Questions**

### **Q: Do I need to register my domain with MyNodeOne first?**

**A: NO.** You just need to:
1. Own the domain (buy it from a registrar)
2. Point DNS to your VPS IP
3. Run `manage-app-visibility.sh`

MyNodeOne doesn't have a "domain registry" you need to pre-configure. It's dynamic.

---

### **Q: What if I don't own example.com yet?**

**A: You have 2 options:**

**Option 1: Skip public access for now**
- Deploy with public=no
- Access locally: `http://voting.mynodeone.local`
- Add public access later when you buy a domain

**Option 2: Use a free subdomain service**
- FreeDNS, DuckDNS, etc.
- Point their subdomain to your VPS
- Use that in deploy.sh

---

### **Q: How do SSL certificates work?**

**The magic:**

```
1. You run manage-app-visibility.sh
2. MyNodeOne tells Traefik: "Route vote.example.com to this app"
3. Traefik (via cert-manager) asks Let's Encrypt: "Can I get an SSL cert?"
4. Let's Encrypt checks: "Does vote.example.com point to this server?" (via HTTP challenge)
5. If yes → Issues certificate (valid for 90 days)
6. Traefik auto-renews every 60 days
```

**You do NOTHING.** It's all automatic once DNS is correct.

---

### **Q: What if I have 10 services to expose?**

**Answer:** You probably don't want to expose 10 services publicly.

**Best practice:**
- Expose 1-3 user-facing services (frontend, api, admin)
- Keep databases, caches, workers INTERNAL

**Example:**
```
✓ app.myapp.com    → Frontend (public)
✓ api.myapp.com    → Backend API (public)
✗ database         → Internal only (not exposed)
✗ redis            → Internal only
✗ worker-1 to 8    → Internal only
```

MyNodeOne's auto-detect does this automatically by detecting service types.

---

### **Q: What's the difference between LoadBalancer IP and VPS IP?**

**LoadBalancer IP (10.20.30.40):**
- Internal to your cluster
- Used for local access (`voting.mynodeone.local`)
- Assigned by MetalLB

**VPS Public IP (e.g., 147.182.123.45):**
- Public internet IP
- Used for DNS records
- This is what the world sees

**Flow:**
```
Internet → VPS IP (147.182.123.45)
       → Traefik on VPS routes to cluster
       → Tailscale mesh to control plane
       → LoadBalancer IP (10.20.30.40)
       → Your app pod
```

---

### **Q: Can I deploy without owning a domain?**

**YES!** Just say "no" to public access:

```bash
? Make this app publicly accessible?
Public access [y/N]: n
```

Your app still works:
- ✓ Locally: `http://voting.mynodeone.local`
- ✓ From any cluster node
- ✓ Via Tailscale VPN
- ✗ NOT on the public internet

Add public access later when you get a domain.

---

## **Visual Workflow**

```
┌─────────────────────────────────────────────────────────────┐
│ Step 1: Deploy App (deploy.sh)                             │
├─────────────────────────────────────────────────────────────┤
│ • App running in Kubernetes ✓                              │
│ • LoadBalancer IP assigned ✓                               │
│ • Local DNS works ✓                                        │
│ • http://voting.mynodeone.local ✓                          │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 2: YOU Configure DNS (at registrar)                   │
├─────────────────────────────────────────────────────────────┤
│ • Go to GoDaddy/Cloudflare/etc                             │
│ • Add A record: vote.example.com → VPS_PUBLIC_IP           │
│ • Wait 5-30 minutes for propagation                        │
│ • Test: dig vote.example.com                               │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 3: MyNodeOne Configures Routing                       │
├─────────────────────────────────────────────────────────────┤
│ • Run: manage-app-visibility.sh                            │
│ • Select app and domains                                   │
│ • Traefik configures routing ✓                             │
│ • Let's Encrypt issues SSL ✓                               │
│ • VPS edge node synced ✓                                   │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 4: Access Your App!                                   │
├─────────────────────────────────────────────────────────────┤
│ • https://vote.example.com ✓                               │
│ • Valid SSL certificate ✓                                  │
│ • Automatic HTTPS redirect ✓                               │
│ • Auto-renewal every 60 days ✓                             │
└─────────────────────────────────────────────────────────────┘
```

---

## **What deploy.sh Does vs. Doesn't Do**

### **✓ What deploy.sh DOES:**
- Deploys your app to Kubernetes
- Creates services with LoadBalancer IPs
- Registers app for local DNS (`voting.mynodeone.local`)
- Asks what domains you WANT to use
- **Prepares** public access configuration

### **✗ What deploy.sh DOESN'T DO:**
- Change your DNS records (you do that at your registrar)
- Issue SSL certificates (manage-app-visibility.sh does this)
- Configure VPS routing (manage-app-visibility.sh does this)
- Buy domains for you (you need to own them)

---

## **Quick Reference**

### **Deployment Command:**
```bash
cd your-app/
bash /path/to/MyNodeOne/external-apps/scripts/deploy.sh
```

### **Public Access Command:**
```bash
sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
```

### **Check App Status:**
```bash
kubectl get pods -n voting-app
kubectl get svc -n voting-app
kubectl logs -n voting-app -l app=voting-app -f
```

### **Test Local Access:**
```bash
curl http://voting.mynodeone.local
# Or open in browser
```

### **Test Public Access:**
```bash
curl https://vote.example.com
# Should return your app HTML
```

### **Check SSL Certificate:**
```bash
curl -vI https://vote.example.com 2>&1 | grep -i "subject:\|issuer:"
# Should show Let's Encrypt as issuer
```

---

## **Troubleshooting**

### **App works locally but not publicly**

**Check DNS:**
```bash
dig vote.example.com
# Should show your VPS IP
```

**Check routing:**
```bash
# On VPS
sudo docker logs traefik 2>&1 | grep curiios
```

**Re-run visibility:**
```bash
sudo /path/to/MyNodeOne/scripts/operations/manage-app-visibility.sh
```

### **SSL certificate not working**

**Check cert-manager:**
```bash
kubectl get certificate -n votingapp
kubectl describe certificate -n votingapp
```

**Common issue:** DNS not propagated yet. Wait 30 minutes and try again.

---

## **Key Takeaways**

1. **deploy.sh = Deploy app + prepare public access**
2. **YOU = Configure DNS at your registrar**
3. **manage-app-visibility.sh = Route + SSL automation**
4. **Let's Encrypt = Free, automatic SSL certificates**
5. **No pre-registration needed** - just own the domain and point DNS

---

**Still confused?** Read the simplified workflow:
- `external-apps/README.md` - Quick start
- `external-apps/docs/DEVELOPER-GUIDE.md` - Full guide
- This file - Domain/SSL deep dive
