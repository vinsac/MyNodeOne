# Jellyfin Installation - One-Click Setup

**Jellyfin** is an open-source media server (Netflix/Plex alternative) that lets you stream movies, TV shows, music, and photos to any device.

---

## ✨ One-Click Installation

### **Prerequisites**
- MyNodeOne cluster installed and running
- kubectl configured
- (Optional) VPS edge node for internet access

### **Install Command**
```bash
sudo ./scripts/apps/jellyfin/install-jellyfin.sh
```

**Installation time:** ~2 minutes

---

## 📋 What Happens Automatically

The script handles everything for you:

### **1. Subdomain Configuration**
```
Choose a subdomain for Jellyfin. This will be used for:
  • Local access: <subdomain>.mynodeone.local
  • Public access: <subdomain>.yourdomain.com (if VPS configured)

Examples: media, jellyfin, movies, tv

Enter subdomain [default: jellyfin]: media
```

**Result:**
- Local: `http://media.mynodeone.local`
- Public: `https://media.example.com`

### **2. Kubernetes Deployment**
- ✅ Creates dedicated namespace (`jellyfin`)
- ✅ Configures persistent storage (50GB config + 500GB media)
- ✅ Deploys Jellyfin container
- ✅ Creates LoadBalancer service with NodePort
- ✅ Adds subdomain annotation for DNS discovery

### **3. Local DNS Update**
- ✅ Automatically adds entry to `/etc/hosts`
- ✅ Works on management laptop and any Tailscale device
- ✅ Format: `<subdomain>.mynodeone.local`

### **4. VPS Route Configuration (Optional)**
If VPS edge node is configured:
- ✅ Auto-detects control plane IP
- ✅ Auto-detects NodePort
- ✅ Configures Traefik route
- ✅ Requests Let's Encrypt SSL certificate
- ✅ Sets up HTTPS redirect

---

## 🎯 What Makes This "One-Click"

### **No Manual Configuration Needed**

#### **❌ Old Way (Manual)**
```bash
# 1. Manually set inotify limits
sudo sysctl -w fs.inotify.max_user_instances=1024
echo "fs.inotify.max_user_instances=1024" | sudo tee -a /etc/sysctl.conf

# 2. Manually find service IP and port
kubectl get svc -n jellyfin

# 3. Manually create VPS route with wrong IP
# (LoadBalancer IP doesn't work from VPS!)

# 4. Manually update DNS
# 5. Manually fix SSL certificate
# 6. Manually restart everything
```

#### **✅ New Way (Automated)**
```bash
sudo ./scripts/apps/jellyfin/install-jellyfin.sh
# Answer 2 questions:
#   1. Subdomain? (e.g., "media")
#   2. Public domain? (e.g., example.com")
# Done! Everything works.
```

---

## 🔧 Behind the Scenes

### **System Optimizations** (in `bootstrap-control-plane.sh`)
```bash
# Automatically applied during cluster setup
fs.inotify.max_user_instances=1024  # Prevents container crashes
fs.inotify.max_user_watches=524288  # Supports file watching apps
```

**Why needed:** Jellyfin uses file watchers for media library updates. Default Linux limits (128) are too low for containers.

### **VPS Route Intelligence** (in `configure-vps-route.sh`)
```bash
# Auto-detection logic:
1. Get control plane Tailscale IP from Kubernetes
   → kubectl get nodes -o jsonpath='{...InternalIP...}'

2. Get service NodePort (not LoadBalancer IP!)
   → kubectl get svc -n jellyfin jellyfin -o jsonpath='{...nodePort}'

3. Configure Traefik: http://<control-plane-ip>:<nodeport>
   → VPS can reach this over Tailscale
```

**Why needed:** LoadBalancer IPs (e.g., 100.118.5.208) are only accessible within cluster network. VPS needs NodePort on control plane's Tailscale IP.

### **DNS Discovery** (automatic via node agent)
```bash
# Reads Kubernetes annotation:
annotations:
  mynodeone.local/subdomain: "media"

# Generates DNS entry (synced automatically to all nodes):
100.118.5.208    media.mynodeone.local    # jellyfin/jellyfin
```

**Why needed:** Consistent subdomain across local and public access.
**Note:** DNS entries are automatically synced to management laptops within 30-60 seconds via node agent.

---

## 🚀 Post-Installation

### **Access Jellyfin**

#### **Local Network (via Tailscale)**
```
http://media.mynodeone.local
```

#### **Internet (via VPS)**
```
https://media.example.com
```

### **First-Time Setup**
1. Open the URL in your browser
2. Follow the setup wizard
3. Create admin account
4. **Skip adding libraries for now** (add media first)
5. Upload your media (see "Getting Your Media Into Jellyfin" below)
6. Add media libraries pointing to `/media/Movies`, `/media/TV`, etc.
7. (Optional) Configure hardware transcoding

### **Mobile Apps**
- **iOS:** Search "Jellyfin" in App Store
- **Android:** Search "Jellyfin" in Play Store

**Server URL:** `http://media.mynodeone.local` (or `https://media.example.com`)

---

## 📁 Getting Your Media Into Jellyfin

**Important:** Jellyfin doesn't have a web upload feature like Google Photos or Dropbox. Instead, you need to tell Jellyfin where your media files are located.

### **Understanding Your Options**

You have **3 main scenarios** for getting media into Jellyfin:

1. **Small collection on your laptop** (a few movies/shows)
   → Use our upload script to copy files to Jellyfin

2. **Large collection on external hard drive** (hundreds of GB)
   → Mount the drive and point Jellyfin to it

3. **Media already on a NAS** (network storage)
   → Connect Jellyfin directly to your NAS

Let's walk through each scenario:

---

### **Scenario 1: Upload Files from Your Laptop** 📤

**Best for:** Small to medium collections (under 100GB), files scattered across your laptop

**How it works:** Copy files from your laptop into Jellyfin's storage

#### **Step-by-Step Guide**
```bash
# Can be run from your laptop OR control plane
./scripts/apps/jellyfin/upload-media.sh
```

**Features:**
- **Works from management laptop** - no need to SSH!
- Upload single files or entire folders
- Organized directory structure (Movies, TV, Music, Photos)
- Interactive menu with helpful tips
- Drag-and-drop support (drag file into terminal)
- Tab completion for browsing files
- Shows common file locations
- Shows current media

**Example workflow from laptop:**
```bash
# On your laptop (no SSH needed!)
cd ~/MyNodeOne
./scripts/apps/jellyfin/upload-media.sh

# Script detects you're on laptop
✓ Running from management laptop
  Files will be uploaded from your laptop to Jellyfin

# Choose "Upload a folder"
💡 Tip: You can drag and drop a folder into the terminal
   Or use tab completion to browse: /home/[TAB]

Common locations:
  ~/Downloads/
  ~/Videos/
  ~/Movies/

Enter path to folder: ~/Downloads/Inception  # or drag-drop here
Select destination: 1 (Movies)

📤 Uploading folder...
✓ Folder uploaded successfully!
```

**Example workflow from control plane:**
```bash
# SSH into control plane
ssh user@control-plane

# Run script
./scripts/apps/jellyfin/upload-media.sh

# Script detects you're on control plane
✓ Running on control plane
  Files will be uploaded from control plane to Jellyfin
```

**Tips:**
- **Drag and drop**: Drag a file/folder from your file manager into the terminal to get its path
- **Tab completion**: Type `~/Down` and press TAB to autocomplete to `~/Downloads/`
- **Tilde expansion**: `~/Movies` works (expands to `/home/user/Movies`)

**After uploading:**
1. Go to Jellyfin web interface
2. Dashboard → Libraries → Add Library
3. Choose content type (Movies, TV Shows, etc.)
4. Add folder: `/media/Movies` (or `/media/TV`, etc.)
5. Jellyfin will scan and organize your media automatically

---

### **Scenario 2: Use External Hard Drive** 💾

**Best for:** Large collections (500GB+), media already organized on external drive

**How it works:** Plug external drive into control plane, mount it, point Jellyfin to it

#### **Step-by-Step Guide**

**Step 1: Plug in your external hard drive**
```bash
# SSH into control plane
ssh user@control-plane

# Find your drive
lsblk
# Look for your drive (e.g., sdb1, sdc1)
# Example output:
# sdb           8:16   0   2T  0 disk
# └─sdb1        8:17   0   2T  0 part
```

**Step 2: Mount the drive**
```bash
# Create mount point
sudo mkdir -p /mnt/media-drive

# Mount the drive (replace sdb1 with your drive)
sudo mount /dev/sdb1 /mnt/media-drive

# Verify it's mounted
ls /mnt/media-drive
# You should see your media files
```

**Step 3: Make mount permanent (optional)**
```bash
# Get drive UUID
sudo blkid /dev/sdb1
# Copy the UUID value

# Add to /etc/fstab
sudo nano /etc/fstab
# Add this line (replace UUID with yours):
UUID=your-uuid-here /mnt/media-drive ext4 defaults 0 2
```

**Step 4: Update Jellyfin to use the drive**

Edit the Jellyfin deployment to mount your external drive:

```bash
kubectl edit deployment jellyfin -n jellyfin
```

Add a hostPath volume:
```yaml
spec:
  template:
    spec:
      volumes:
      - name: external-media
        hostPath:
          path: /mnt/media-drive  # Your mount point
          type: Directory
      containers:
      - name: jellyfin
        volumeMounts:
        - name: external-media
          mountPath: /external-media  # Path inside container
          readOnly: true  # Jellyfin only reads, doesn't modify
```

**Step 5: Add library in Jellyfin**
1. Go to Jellyfin → Dashboard → Libraries → Add Library
2. Choose content type (Movies, TV Shows, etc.)
3. Add folder: `/external-media/Movies` (or wherever your media is)
4. Jellyfin will scan your external drive

**Pros:**
- No copying needed (saves time and space)
- Can unplug drive when not in use
- Easy to swap drives

**Cons:**
- Drive must stay plugged into control plane
- If drive disconnected, media unavailable

---

### **Scenario 3: Connect to NAS (Network Storage)** 🌐

**Best for:** Media already on Synology/QNAP/TrueNAS, want to keep it there

**How it works:** Jellyfin accesses your NAS over the network (NFS or SMB)

#### **Step-by-Step Guide (NFS)**

**Step 1: Enable NFS on your NAS**

*For Synology:*
1. Control Panel → File Services → NFS → Enable NFS
2. Shared Folder → Edit → NFS Permissions
3. Add rule: `192.168.1.0/24` (your network), Read/Write, Squash: Map all users to admin

*For QNAP:*
1. Control Panel → Network & File Services → NFS Service → Enable
2. Shared Folders → Edit Share → NFS Host Access
3. Add: `192.168.1.0/24`, Read/Write

**Step 2: Test NFS from control plane**
```bash
# SSH into control plane
ssh user@control-plane

# Install NFS client (if not already installed)
sudo apt install nfs-common

# Test mount
sudo mkdir -p /mnt/nas-test
sudo mount -t nfs 192.168.1.100:/volume1/Media /mnt/nas-test
# Replace 192.168.1.100 with your NAS IP
# Replace /volume1/Media with your NAS share path

# Verify
ls /mnt/nas-test
# You should see your media

# Unmount test
sudo umount /mnt/nas-test
```

**Step 3: Create Kubernetes NFS PersistentVolume**

Create a file `jellyfin-nas-pv.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jellyfin-nas-media
spec:
  capacity:
    storage: 5Ti  # Adjust to your NAS size
  accessModes:
    - ReadWriteMany
  nfs:
    server: 192.168.1.100  # Your NAS IP
    path: /volume1/Media   # Your NAS share path
  mountOptions:
    - nfsvers=4.1
    - hard
    - timeo=600
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-nas-media
  namespace: jellyfin
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""  # Empty for static binding
  volumeName: jellyfin-nas-media
  resources:
    requests:
      storage: 5Ti
```

Apply it:
```bash
kubectl apply -f jellyfin-nas-pv.yaml
```

**Step 4: Update Jellyfin deployment**
```bash
kubectl edit deployment jellyfin -n jellyfin
```

Add the NAS volume:
```yaml
spec:
  template:
    spec:
      volumes:
      - name: nas-media
        persistentVolumeClaim:
          claimName: jellyfin-nas-media
      containers:
      - name: jellyfin
        volumeMounts:
        - name: nas-media
          mountPath: /nas-media
          readOnly: true
```

**Step 5: Add library in Jellyfin**
1. Go to Jellyfin → Dashboard → Libraries → Add Library
2. Choose content type
3. Add folder: `/nas-media/Movies` (or wherever your media is on NAS)
4. Jellyfin will scan your NAS

**Pros:**
- No copying needed
- Media stays on NAS (your source of truth)
- Multiple apps can access same media
- NAS handles backups/RAID

**Cons:**
- Requires NAS with NFS/SMB
- Network speed affects streaming quality
- More complex setup

---

### **Which Scenario Should I Choose?**

| Scenario | When to Use | Complexity |
|----------|-------------|------------|
| **Upload Script** | Small collection, files on laptop | ⭐ Easy |
| **External Drive** | Large collection, dedicated drive | ⭐⭐ Medium |
| **NAS** | Already have NAS, want centralized storage | ⭐⭐⭐ Advanced |

**Recommendation for beginners:** Start with the upload script. You can always switch to external drive or NAS later.

---

### **Storage Configuration**

**Default Allocation:**
- **Config:** 50GB (Longhorn PVC) - for Jellyfin settings
- **Media:** 500GB (Longhorn PVC) - for uploaded media

**Adjust Storage:**
Edit the script before running:
```bash
STORAGE_CONFIG="50Gi"   # Change as needed
STORAGE_MEDIA="500Gi"   # Adjust for your library size
```

**Note:** If using external drive or NAS, you don't need large media PVC.

---

### **Advanced: Direct kubectl cp**
```bash
# Upload a single movie
kubectl cp /path/to/movie.mp4 jellyfin/jellyfin-pod:/media/Movies/movie.mp4

# Upload entire folder
kubectl cp /path/to/TV-Show/ jellyfin/jellyfin-pod:/media/TV/TV-Show/

# Get pod name
kubectl get pods -n jellyfin
```

### **Advanced: SSH + rsync (For large libraries)**
```bash
# From your laptop with media
rsync -avz --progress /path/to/media/ user@control-plane:/tmp/media/

# On control plane
kubectl cp /tmp/media/ jellyfin/jellyfin-pod:/media/
```

### **Directory Structure**
```bash
/media/
├── Movies/
│   ├── Movie1 (2020)/
│   │   └── Movie1.mkv
│   └── Movie2 (2021)/
│       └── Movie2.mp4
├── TV/
│   └── ShowName/
│       ├── Season 01/
│       │   ├── S01E01.mkv
│       │   └── S01E02.mkv
│       └── Season 02/
├── Music/
│   └── Artist/
│       └── Album/
└── Photos/
```

### **Storage Info**
```bash
# List volumes
kubectl get pvc -n jellyfin

# Check storage usage
kubectl exec -n jellyfin deployment/jellyfin -- df -h /media

# Storage paths in container
/config  → Jellyfin configuration (50Gi)
/media   → Your media files (500Gi default)
```

---

## 🔍 Troubleshooting

### **Issue: Pod CrashLoopBackOff**

**Symptom:**
```bash
kubectl get pods -n jellyfin
# jellyfin-xxx   0/1     CrashLoopBackOff
```

**Cause:** inotify limits too low

**Fix:** (Applied automatically in new installations)
```bash
# On control plane node:
kubectl debug node/canada-pc-0001 -it --image=alpine -- chroot /host sh -c "
  sysctl -w fs.inotify.max_user_instances=1024
  sysctl -w fs.inotify.max_user_watches=524288
  echo 'fs.inotify.max_user_instances=1024' >> /etc/sysctl.conf
  echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
"

# Restart pod
kubectl delete pod -n jellyfin --all
```

---

### **Issue: Local DNS Not Working**

**Symptom:**
```bash
ping media.mynodeone.local
# ping: cannot resolve media.mynodeone.local
```

**Fix:**
```bash
# DNS should sync automatically within 60 seconds
# If needed immediately, force a sync:
sudo mynodeone-node-agent sync

# Verify
cat /etc/hosts | grep media.mynodeone.local

# Check node agent status
sudo systemctl status mynodeone-node-agent
```

---

### **Issue: VPS Shows 502 Bad Gateway**

**Symptom:** `https://media.example.com` shows 502 error

**Cause:** VPS route pointing to wrong backend

**Fix:** Re-run VPS configuration (now auto-detects NodePort)
```bash
sudo ./scripts/vps/configure-vps-route.sh jellyfin 80 media example.com
```

**Verify backend:**
```bash
ssh root@<vps-ip> "cat /etc/traefik/dynamic/jellyfin.yml"
# Should show: http://<control-plane-ip>:<nodeport>
# Example: http://100.118.5.68:31185
```

---

### **Issue: SSL Certificate Shows "TRAEFIK DEFAULT CERT"**

**Symptom:** Browser shows invalid certificate immediately after installation

**Cause:** Let's Encrypt certificate not issued yet (THIS IS NORMAL for new domains!)

**Expected Timeline:**
- **0-30 seconds:** Shows "TRAEFIK DEFAULT CERT" (temporary)
- **30-60 seconds:** Let's Encrypt completes HTTP-01 challenge
- **60+ seconds:** Valid Let's Encrypt certificate active

**Fix:** **Just wait!** This is automatic and takes 30-60 seconds.

**If still showing default cert after 2 minutes:**
```bash
# Restart Traefik to trigger new certificate request
ssh root@<vps-ip> "docker restart traefik"

# Wait 60 seconds, then verify
sleep 60
echo | openssl s_client -servername media.example.com \
  -connect media.example.com:443 2>/dev/null | \
  openssl x509 -noout -subject -issuer

# Should show:
# subject=CN = media.example.com
# issuer=C = US, O = Let's Encrypt, CN = R12
```

**Important:** Don't panic if you see "TRAEFIK DEFAULT CERT" right after installation. This is expected and will automatically resolve within 1-2 minutes as Let's Encrypt issues your certificate.

---

## 📊 Management Commands

### **View Logs**
```bash
kubectl logs -f deployment/jellyfin -n jellyfin
```

### **Restart Jellyfin**
```bash
kubectl rollout restart deployment/jellyfin -n jellyfin
```

### **Check Status**
```bash
kubectl get all -n jellyfin
```

### **Access Configuration**
```bash
kubectl exec -it deployment/jellyfin -n jellyfin -- bash
cd /config
ls -la
```

### **Uninstall**
```bash
kubectl delete namespace jellyfin
```

**Note:** This deletes all data! Back up first if needed.

---

## 🎬 Example Use Cases

### **Family Media Server**
```
1. Install Jellyfin: sudo ./scripts/apps/jellyfin/install-jellyfin.sh
2. Subdomain: "movies"
3. Public domain: "smith-family.com"
4. Result: https://movies.smith-family.com
5. Share with family worldwide!
```

### **Home Media Library**
```
1. Install Jellyfin: sudo ./scripts/apps/jellyfin/install-jellyfin.sh
2. Subdomain: "media"
3. Skip VPS setup (local only)
4. Result: http://media.mynodeone.local
5. Stream on local network
```

### **Personal Netflix**
```
1. Install Jellyfin: sudo ./scripts/apps/jellyfin/install-jellyfin.sh
2. Subdomain: "flix"
3. Public domain: "mydomain.com"
4. Result: https://flix.mydomain.com
5. Access from anywhere!
```

---

## 🔒 Security Notes

### **HTTPS (Public Access)**
- ✅ Automatic Let's Encrypt SSL
- ✅ HTTPS redirect enabled
- ✅ Certificate auto-renewal

### **Authentication**
- ✅ Jellyfin requires login by default
- ✅ Create strong admin password
- ✅ Use different passwords for each user

### **Network Isolation**
- ✅ Namespace isolation in Kubernetes
- ✅ Tailscale VPN for internal access
- ✅ VPS acts as secure gateway for public access

---

## 📚 Related Documentation

- [APP-STORE.md](../../docs/reference/APP-STORE.md) - All available apps
- [HYBRID-TROUBLESHOOTING.md](../../docs/guides/HYBRID-TROUBLESHOOTING.md) - VPS & SSL issues
- [DNS-SETUP-GUIDE.md](../../docs/guides/DNS-SETUP-GUIDE.md) - DNS configuration

---

## ✅ Success Checklist

After installation, verify:

- [ ] Pod is running: `kubectl get pods -n jellyfin`
- [ ] Service has IP: `kubectl get svc -n jellyfin`
- [ ] Local DNS works: `ping media.mynodeone.local`
- [ ] Local access works: `curl http://media.mynodeone.local`
- [ ] (If VPS) Public DNS points to VPS: `nslookup media.example.com`
- [ ] (If VPS) HTTPS works: `curl https://media.example.com`
- [ ] (If VPS) SSL certificate valid: Check in browser (green padlock)

**All green? Perfect! Enjoy your personal media server! 🎉**
