# MyNodeOne Cluster - Access Information

**Date:** October 26, 2025  
**Cluster:** canada-pc-0001

---

## 🌐 Access URLs

### Via Tailscale IP (Works from any Tailscale-connected device)

| Service | URL | Purpose |
|---------|-----|---------|
| **Demo App** | http://100.118.5.206 | Demo Chat Application (Test) |
| **LLM Chat** | http://100.118.5.205 | Private AI Chat (Ollama + Open WebUI) |
| **Grafana** | http://100.118.5.203 | Metrics & Dashboards |
| **ArgoCD** | https://100.118.5.204 | GitOps Deployments |
| **MinIO Console** | http://100.118.5.202:9001 | S3 Storage Management |
| **MinIO API** | http://100.118.5.201:9000 | S3 API Endpoint |
| **Longhorn** | http://100.118.5.68:30080 | Block Storage Management |

### Via .local Domains (Works on control plane and configured devices)

| Service | URL | Purpose |
|---------|-----|---------|
| **Demo App** | http://demo.mynodeone.local | Demo Chat Application |
| **LLM Chat** | http://chat.mynodeone.local | Private AI Chat |
| **Grafana** | http://grafana.mynodeone.local | Metrics & Dashboards |
| **ArgoCD** | https://argocd.mynodeone.local | GitOps Deployments |
| **MinIO** | http://minio.mynodeone.local:9001 | S3 Storage |
| **Longhorn** | http://longhorn.mynodeone.local | Block Storage |

---

## 🔐 Service Credentials

### Grafana (Monitoring)
- **Username:** admin
- **Password:** xQES3mCBgyvuwgssEYppgU22rtoFNK8z

### ArgoCD (GitOps)
- **Username:** admin
- **Password:** a2GAvvrl1pVyGeQq

### MinIO (S3 Storage)
- **Username:** admin
- **Password:** Sf55DvhbiNiOcIb7MLjVwnrDNbfqPlX5

### Longhorn (Block Storage)
- **Authentication:** None (protected by Tailscale VPN)

### LLM Chat (Open WebUI)
- **First Login:** Create account (first user becomes admin)
- **No default credentials**

---

## 💻 Setting Up .local Domains on Other Devices

To access services using `.local` domains from your laptop or other devices:

1. **Ensure Tailscale is installed and connected**
   ```bash
   tailscale status
   ```

2. **Copy the setup script to your device**
   ```bash
   # From your laptop:
   scp canada-pc-0001@canada-pc-0001:/home/canada-pc-0001/MyNodeOne/setup-client-dns.sh ~/
   ```

3. **Run the setup script**
   ```bash
   sudo bash ~/setup-client-dns.sh
   ```

4. **Test access**
   ```bash
   curl http://chat.mynodeone.local
   ```

---

## 🔄 Retrieving Credentials Anytime

Credentials are stored securely in Kubernetes secrets and can be retrieved anytime:

```bash
sudo /home/canada-pc-0001/MyNodeOne/scripts/show-credentials.sh
```

**Security Notes:**
- ✅ Credential files have been deleted from disk
- ✅ Passwords are stored encrypted in Kubernetes
- ✅ Use show-credentials.sh to view them anytime
- 📋 Save credentials to your password manager
- 🔁 Change default passwords after first login

---

## 🚀 Quick Start with LLM Chat

1. **Access the UI**
   - Via IP: http://100.118.5.205
   - Via .local: http://chat.mynodeone.local

2. **Create your account**
   - First user automatically becomes admin
   - Use a strong password

3. **Download a model**
   - Go to Settings → Models
   - Pull a model (e.g., phi3:mini, llama3.2)
   - Wait for download to complete

4. **Start chatting\!**
   - Your data stays 100% private
   - Everything runs locally on your hardware

---

## 📊 Monitoring Your Cluster

### Grafana Dashboards
```
http://grafana.mynodeone.local
Username: admin
Password: (see above)
```

**Available Dashboards:**
- Kubernetes cluster metrics
- Node resource usage
- Pod metrics
- Storage metrics
- Network traffic

### View Logs
```bash
# View all pods
kubectl get pods -A

# View logs for a specific pod
kubectl logs -n <namespace> <pod-name>

# Follow logs in real-time
kubectl logs -n llm-chat -f <pod-name>
```

---

## 🛠️ Common Commands

### Check Cluster Health
```bash
kubectl get nodes
kubectl get pods -A
kubectl top nodes
```

### Check LLM Chat Status
```bash
kubectl get pods -n llm-chat
kubectl get svc -n llm-chat
kubectl logs -n llm-chat -l app=ollama
kubectl logs -n llm-chat -l app=open-webui
```

### Restart Services
```bash
# Restart LLM Chat
kubectl rollout restart deployment/ollama -n llm-chat
kubectl rollout restart deployment/open-webui -n llm-chat
```

---

## 🎯 Next Steps

1. ✅ **Access LLM Chat** - Start chatting with your private AI
2. 📊 **Explore Grafana** - See your cluster metrics
3. 💻 **Setup Laptop** - Run `setup-client-dns.sh` on your laptop
4. 📦 **Deploy Apps** - Use ArgoCD or kubectl to deploy more apps
5. 🔐 **Change Passwords** - Update default credentials in each service

---

## �� Documentation

- **Getting Started:** /home/canada-pc-0001/MyNodeOne/GETTING-STARTED.md
- **Post Installation Guide:** /home/canada-pc-0001/MyNodeOne/docs/guides/POST_INSTALLATION_GUIDE.md
- **Operations Guide:** /home/canada-pc-0001/MyNodeOne/docs/operations.md
- **Troubleshooting:** /home/canada-pc-0001/MyNodeOne/docs/troubleshooting.md
- **FAQ:** /home/canada-pc-0001/MyNodeOne/FAQ.md

---

**Enjoy your private cloud\! 🎉**
