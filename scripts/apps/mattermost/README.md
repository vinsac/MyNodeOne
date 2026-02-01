# Mattermost Installation - One-Click Setup

**Mattermost** is an open-source team chat and collaboration platform (Slack/Teams alternative) that gives you complete control over your team communications.

---

## ✨ One-Click Installation

### **Prerequisites**
- MyNodeOne cluster installed and running
- kubectl configured
- (Optional) VPS edge node for internet access

### **Install Command**
```bash
sudo ./scripts/apps/mattermost/install-mattermost.sh
```

**Installation time:** ~3 minutes

---

## 📋 What Happens Automatically

The script handles everything for you:

### **1. Subdomain Configuration**
```
Choose a subdomain for Mattermost. This will be used for:
  • Local access: <subdomain>.mynodeone.local
  • Public access: <subdomain>.yourdomain.com (if VPS configured)

Examples: chat, mattermost, team, slack

Enter subdomain [default: mattermost]: chat
```

**Result:**
- Local: `http://chat.mynodeone.local`
- Public: `https://chat.yourdomain.com`

### **2. Storage Configuration**
```
Recommended data storage sizes:
  • 20Gi   - Good for small teams (5-10 users)
  • 50Gi   - Good for medium teams (10-50 users, recommended)
  • 100Gi  - Good for large teams (50+ users)

Database storage:
  • 10Gi   - Good for small teams (recommended)
  • 20Gi   - Good for medium teams
```

### **3. Kubernetes Deployment**
- ✅ Creates dedicated namespace (`mattermost`)
- ✅ Configures persistent storage for data and database
- ✅ Deploys PostgreSQL database
- ✅ Deploys Mattermost server
- ✅ Creates ClusterIP service
- ✅ Registers service in DNS

### **4. DNS and Routing**
- ✅ Automatically adds entry to local DNS
- ✅ Works on management laptop and any Tailscale device
- ✅ Optional public access via VPS edge node

---

## 🚀 First-Time Setup

### **1. Access Mattermost**

Open your browser and navigate to:
```
http://chat.mynodeone.local
```

### **2. Create Admin Account**

The first user to sign up becomes the **System Administrator**:

1. **Email Address**: Your email (can be fake for local use)
2. **Username**: Your preferred username
3. **Password**: Choose a strong password

**Important:** The first account has full admin privileges!

### **3. Create Your Team**

After creating your account:
1. **Team Name**: Your team or organization name
2. **Team URL**: Short name for your team (e.g., `myteam`)

### **4. Start Using Mattermost**

- Create channels for different topics
- Invite team members
- Start messaging!

---

## 👥 Inviting Team Members

### **Method 1: Invite Link**
1. Click **Main Menu** (☰) → **Invite People**
2. Copy the invitation link
3. Share with team members

### **Method 2: Email Invite**
1. Click **Main Menu** (☰) → **Invite People**
2. Enter email addresses
3. Send invitations

### **Method 3: Direct Signup**
Share your Mattermost URL with team members:
```
http://chat.mynodeone.local
```

They can create accounts directly (if enabled in settings).

---

## 📱 Mobile & Desktop Apps

### **Mobile Apps**

#### **iOS (iPhone/iPad)**
1. Open App Store
2. Search for "Mattermost"
3. Install the app
4. Enter server URL: `http://chat.mynodeone.local`
5. Log in with your credentials

#### **Android**
1. Open Google Play Store
2. Search for "Mattermost"
3. Install the app
4. Enter server URL: `http://chat.mynodeone.local`
5. Log in with your credentials

**Note:** Mobile apps work when connected to your Tailscale VPN.

### **Desktop Apps**

Download from: https://mattermost.com/download

**Available for:**
- Windows
- macOS
- Linux

**Setup:**
1. Install the desktop app
2. Add server: `http://chat.mynodeone.local`
3. Log in with your credentials

---

## 🔧 Common Tasks

### **Check Status**
```bash
kubectl get all -n mattermost
```

### **View Logs**
```bash
# Mattermost logs
kubectl logs -n mattermost -l app=mattermost -f

# Database logs
kubectl logs -n mattermost -l app=mattermost-postgres -f
```

### **Restart Mattermost**
```bash
kubectl rollout restart deployment/mattermost -n mattermost
```

### **Check Storage Usage**
```bash
kubectl get pvc -n mattermost
```

---

## 🌐 Public Access (Optional)

To make Mattermost accessible from the internet:

### **1. Configure Domain**
```bash
sudo ./scripts/operations/manage-app-visibility.sh
```

### **2. Select Mattermost**
Choose Mattermost from the list of services.

### **3. Choose Domain**
Select which public domain to use (if you have multiple).

### **4. Select VPS Node**
Choose which VPS edge node should handle traffic.

**Result:**
- HTTPS enabled automatically
- Let's Encrypt SSL certificate
- Accessible at: `https://chat.yourdomain.com`

---

## 💾 Storage Management

### **Check Storage Usage**
```bash
kubectl get pvc -n mattermost
```

### **Expand Storage**

If you need more space:

```bash
# Edit the PVC
kubectl edit pvc mattermost-data -n mattermost

# Change the storage size
spec:
  resources:
    requests:
      storage: 100Gi  # Increase this value
```

Longhorn will automatically expand the volume.

---

## 🔒 Security Best Practices

### **1. Enable Multi-Factor Authentication (MFA)**
1. Go to **System Console** → **Authentication** → **MFA**
2. Enable MFA
3. Require MFA for all users

### **2. Configure Email Notifications**
1. Go to **System Console** → **Environment** → **SMTP**
2. Configure your SMTP server
3. Test email delivery

### **3. Set Password Requirements**
1. Go to **System Console** → **Authentication** → **Password**
2. Set minimum length (recommended: 10+)
3. Require numbers and symbols

### **4. Enable Session Timeout**
1. Go to **System Console** → **Environment** → **Session Lengths**
2. Set appropriate timeout (e.g., 30 days)

---

## 🎨 Customization

### **Change Team Icon**
1. Click **Main Menu** (☰) → **Team Settings**
2. Upload team icon/logo

### **Customize Theme**
1. Click your profile picture → **Settings**
2. Go to **Display** → **Theme**
3. Choose from presets or create custom theme

### **Add Custom Emoji**
1. Click **Main Menu** (☰) → **Custom Emoji**
2. Upload custom emoji images

---

## 🔌 Integrations

### **Webhooks**

#### **Incoming Webhooks**
Receive messages from external services:
1. Go to **Integrations** → **Incoming Webhooks**
2. Create webhook
3. Copy webhook URL
4. Use in external services

#### **Outgoing Webhooks**
Send messages to external services:
1. Go to **Integrations** → **Outgoing Webhooks**
2. Configure trigger words
3. Set callback URL

### **Slash Commands**
Create custom slash commands:
1. Go to **Integrations** → **Slash Commands**
2. Create command
3. Configure trigger and callback

### **Bots**
Add bot accounts for automation:
1. Go to **Integrations** → **Bot Accounts**
2. Create bot
3. Use bot token for API access

---

## 🛠️ Troubleshooting

### **Can't Access Mattermost**

**Check if pods are running:**
```bash
kubectl get pods -n mattermost
```

**Check service:**
```bash
kubectl get svc -n mattermost
```

**Check DNS:**
```bash
ping chat.mynodeone.local
```

### **Database Connection Issues**

**Check PostgreSQL logs:**
```bash
kubectl logs -n mattermost -l app=mattermost-postgres
```

**Verify database secret:**
```bash
kubectl get secret mattermost-db -n mattermost -o yaml
```

### **Slow Performance**

**Check resource usage:**
```bash
kubectl top pods -n mattermost
```

**Increase resources:**
```bash
kubectl edit deployment mattermost -n mattermost

# Increase memory and CPU limits
resources:
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

### **Storage Full**

**Check storage usage:**
```bash
kubectl exec -n mattermost deployment/mattermost -- df -h /mattermost/data
```

**Expand storage** (see Storage Management section above)

---

## 📊 Admin Console

Access the System Console for advanced configuration:

1. Click **Main Menu** (☰) → **System Console**
2. Requires admin account

**Key sections:**
- **User Management**: Manage users and teams
- **Environment**: SMTP, file storage, logging
- **Site Configuration**: URLs, notifications
- **Authentication**: SSO, LDAP, SAML
- **Plugins**: Extend functionality

---

## 🔄 Backup & Restore

### **Backup**

**1. Backup Database:**
```bash
kubectl exec -n mattermost deployment/mattermost-postgres -- \
  pg_dump -U mattermost mattermost > mattermost-backup.sql
```

**2. Backup Files:**
```bash
kubectl cp mattermost/mattermost-<pod-id>:/mattermost/data ./mattermost-data-backup
```

### **Restore**

**1. Restore Database:**
```bash
kubectl exec -i -n mattermost deployment/mattermost-postgres -- \
  psql -U mattermost mattermost < mattermost-backup.sql
```

**2. Restore Files:**
```bash
kubectl cp ./mattermost-data-backup mattermost/mattermost-<pod-id>:/mattermost/data
```

---

## 🗑️ Uninstallation

### **Keep Data (Remove App Only)**
```bash
sudo ./scripts/apps/mattermost/uninstall-mattermost.sh
# Choose option 1
```

This removes the application but keeps:
- All messages and chat history
- All uploaded files
- Database

You can reinstall later and keep your data.

### **Delete Everything**
```bash
sudo ./scripts/apps/mattermost/uninstall-mattermost.sh
# Choose option 2
# Type 'DELETE' to confirm
```

This permanently deletes:
- All messages and chat history
- All uploaded files and attachments
- All user accounts
- All teams and channels
- Database

---

## 📚 Additional Resources

### **Official Documentation**
- User Guide: https://docs.mattermost.com/guides/user.html
- Admin Guide: https://docs.mattermost.com/guides/administrator.html
- API Documentation: https://api.mattermost.com/

### **Community**
- Forum: https://forum.mattermost.com/
- GitHub: https://github.com/mattermost/mattermost

### **Integrations**
- Integration Directory: https://mattermost.com/marketplace/

---

## 💡 Tips & Best Practices

### **For Teams**
1. Create channels for different projects/topics
2. Use direct messages for private conversations
3. Pin important messages in channels
4. Use @mentions to notify specific people
5. Set up webhooks for external notifications

### **For Admins**
1. Regular backups (weekly recommended)
2. Monitor storage usage
3. Keep Mattermost updated
4. Configure email notifications
5. Enable MFA for all users
6. Review audit logs regularly

### **Performance**
1. Archive old channels to reduce database size
2. Set file retention policies
3. Use plugins sparingly
4. Monitor resource usage
5. Scale resources as team grows

---

## 🎉 You're All Set!

Mattermost is now running on your MyNodeOne cluster. Start chatting with your team! 🚀