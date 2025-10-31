# Port Simplification for Non-Technical Users

## 🎯 The Problem

**Original Design:**
- Immich ran on port 3001: `http://immich.mynodeone.local:3001`
- Users had to remember port numbers
- Port numbers are confusing for non-technical users
- Inconsistent with other apps (Jellyfin, Vaultwarden use port 80)

**The Fix:**
- All apps now use standard HTTP port 80
- No port numbers needed!
- Simple, consistent URLs

---

## ✅ Standard Access Pattern

### All Apps Use Port 80 (No Port Number Needed!)

```
✅ http://jellyfin.mynodeone.local      (not :8096)
✅ http://immich.mynodeone.local        (not :3001)
✅ http://vaultwarden.mynodeone.local   (not :80)
✅ http://nextcloud.mynodeone.local     (not :80)
✅ http://mattermost.mynodeone.local    (not :8065)
✅ http://homepage.mynodeone.local      (not :3000)
```

**Simple Rule:** `http://[appname].mynodeone.local`

---

## 🔧 How It Works (Technical)

### Kubernetes Service Configuration

**Before (confusing):**
```yaml
apiVersion: v1
kind: Service
spec:
  type: LoadBalancer
  ports:
  - port: 3001        # External port users see
    targetPort: 3001  # Internal container port
```
**Users had to access: http://immich.mynodeone.local:3001**

**After (simple):**
```yaml
apiVersion: v1
kind: Service
spec:
  type: LoadBalancer
  ports:
  - port: 80          # External port (standard HTTP)
    targetPort: 3001  # Internal container port (unchanged)
    name: http
```
**Users access: http://immich.mynodeone.local (port 80 is default!)**

### What Changed

**Inside the container:** App still runs on its native port
- Immich: port 3001
- Jellyfin: port 8096
- Homepage: port 3000
- etc.

**Outside (user-facing):** LoadBalancer exposes on port 80
- All web apps accessible without port numbers
- Port 80 is default for HTTP, browsers don't show it
- Consistent, simple user experience

---

## 📱 Impact on Mobile Apps

### Before
```
❌ Immich app → http://immich.mynodeone.local:3001
❌ User: "What's :3001? Do I need that?"
❌ Confusion and support requests
```

### After
```
✅ Immich app → http://immich.mynodeone.local
✅ User: "Simple! Just like any website!"
✅ No confusion, just works
```

---

## 🎯 Apps Standardized

| App | Internal Port | External Port | User Access URL |
|-----|---------------|---------------|-----------------|
| Jellyfin | 8096 | 80 | `http://jellyfin.mynodeone.local` |
| Immich | 3001 | 80 | `http://immich.mynodeone.local` |
| Vaultwarden | 80 | 80 | `http://vaultwarden.mynodeone.local` |
| Nextcloud | 80 | 80 | `http://nextcloud.mynodeone.local` |
| Mattermost | 8065 | 80 | `http://mattermost.mynodeone.local` |
| Homepage | 3000 | 80 | `http://homepage.mynodeone.local` |
| Minecraft | 25565 | 25565 | `minecraft.mynodeone.local:25565` |

**Note:** Minecraft is exception - game protocol requires specific port

---

## 💡 User Experience Improvement

### Complexity Removed

**Before:**
1. Install Immich
2. Remember it uses port 3001
3. Type full URL with port
4. Configure mobile app with port
5. Explain to family what port means

**After:**
1. Install Immich
2. Type http://immich.mynodeone.local
3. Done!

### Documentation Simplified

**Before:**
- Need to document which app uses which port
- Users confused about when ports are needed
- Support questions: "Do I type :80 or not?"

**After:**
- No port documentation needed
- Consistent pattern for all apps
- No confusion

---

## 🚀 Benefits

### For Users
✅ **Simpler URLs** - No port numbers to remember  
✅ **Consistent** - All apps follow same pattern  
✅ **Less Confusion** - Works like any website  
✅ **Mobile-Friendly** - Easy to type on phone  
✅ **Professional** - Looks like real web services  

### For Developers
✅ **Easier Support** - Fewer user questions  
✅ **Better UX** - More accessible to non-technical users  
✅ **Flexible** - Can change internal ports without affecting users  
✅ **Standard** - Follows web conventions  

---

## 🔒 Security Note

**Question:** Is exposing everything on port 80 less secure?

**Answer:** No! Security is unchanged:

- ✅ Services still only accessible via Tailscale VPN
- ✅ LoadBalancer IPs are on private Tailscale network
- ✅ No public internet exposure
- ✅ Each app has authentication
- ✅ Network traffic still encrypted by Tailscale

**Port 80 vs 3001 doesn't matter for security** - what matters is:
1. Network isolation (Tailscale ✅)
2. Authentication (each app has login ✅)
3. Encryption in transit (Tailscale ✅)

---

## 📊 Migration Impact

### Existing Users

**If you installed Immich before this change:**

Your installation uses port 3001. To upgrade:

```bash
# Uninstall old version
kubectl delete namespace immich

# Reinstall with new version
sudo ./scripts/apps/install-immich.sh
```

**Mobile apps:** Change server URL from `:3001` to no port

### New Users

**Zero impact!** Just install and use standard URLs.

---

## 🎓 Implementation Details

### Service Manifest Pattern

All apps now follow this pattern:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
spec:
  type: LoadBalancer
  ports:
  - port: 80                    # User-facing port
    targetPort: ${INTERNAL_PORT} # App's actual port
    name: http
  selector:
    app: ${APP_NAME}
```

**Example for Immich:**
```yaml
ports:
- port: 80          # Users access on port 80
  targetPort: 3001  # Immich internally runs on 3001
  name: http
```

---

## ✅ Verification

### Test Access
```bash
# Should work without port:
curl http://immich.mynodeone.local

# Should also work with explicit port 80:
curl http://immich.mynodeone.local:80

# Old port should NOT work:
curl http://immich.mynodeone.local:3001
# (connection refused)
```

### Check Service
```bash
# Verify LoadBalancer configuration
kubectl get svc -n immich

# Should show:
# PORT(S): 80:XXXXX/TCP
```

---

## 📝 Summary

**Bottom Line:** All web apps accessible via simple URLs with no port numbers.

**Pattern:** `http://[appname].mynodeone.local`

**Exception:** Game servers (Minecraft) that require specific ports

**User Impact:** Dramatically simplified, more accessible to non-technical users

**Technical Impact:** Zero security or functionality changes, just better UX

---

**Last Updated:** October 2024  
**Status:** ✅ Implemented for all apps
