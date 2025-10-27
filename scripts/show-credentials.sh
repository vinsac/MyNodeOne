#!/bin/bash

# MyNodeOne Credentials Display Script
# Shows all service credentials in one place

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo "kubectl not found. Please ensure Kubernetes is installed."
        exit 1
    fi
}

print_header "MyNodeOne Service Credentials"

# Get service IPs
GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
MINIO_CONSOLE_IP=$(kubectl get svc -n minio minio-console -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
MINIO_API_IP=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
LONGHORN_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

# Get credentials from Kubernetes secrets (secure)
GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Run on control plane with kubectl access")

# Get ArgoCD credentials from Kubernetes
ARGOCD_PASS=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")

# Get MinIO credentials from Kubernetes
MINIO_USER=$(kubectl get secret -n minio minio -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
MINIO_PASS=$(kubectl get secret -n minio minio -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")

echo -e "${GREEN}📊 Grafana (Monitoring)${NC}"
echo "  URL: http://$GRAFANA_IP"
echo "  Username: admin"
echo "  Password: $GRAFANA_PASS"
echo

echo -e "${GREEN}🚀 ArgoCD (GitOps)${NC}"
echo "  URL: https://$ARGOCD_IP"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASS"
echo

echo -e "${GREEN}💾 MinIO (S3 Storage)${NC}"
echo "  Console URL: http://$MINIO_CONSOLE_IP:9001"
echo "  API URL: http://$MINIO_API_IP:9000"
echo "  Username: $MINIO_USER"
echo "  Password: $MINIO_PASS"
echo

echo -e "${GREEN}📦 Longhorn (Block Storage)${NC}"
echo "  URL: http://$LONGHORN_IP"
echo "  Authentication: None (protected by Tailscale VPN)"
echo

print_header "Security Status"

echo "✅ Passwords displayed above are retrieved from Kubernetes secrets (encrypted if secrets encryption enabled)"
echo
echo "📁 Checking for old credential files on disk:"
echo

FILES_FOUND=0
if [ -f /root/mynodeone-argocd-credentials.txt ]; then
    echo -e "  ${YELLOW}⚠️  /root/mynodeone-argocd-credentials.txt (SHOULD BE DELETED)${NC}"
    FILES_FOUND=$((FILES_FOUND + 1))
fi

if [ -f /root/mynodeone-minio-credentials.txt ]; then
    echo -e "  ${YELLOW}⚠️  /root/mynodeone-minio-credentials.txt (SHOULD BE DELETED)${NC}"
    FILES_FOUND=$((FILES_FOUND + 1))
fi

if [ -f /root/mynodeone-grafana-credentials.txt ]; then
    echo -e "  ${YELLOW}⚠️  /root/mynodeone-grafana-credentials.txt (SHOULD BE DELETED)${NC}"
    FILES_FOUND=$((FILES_FOUND + 1))
fi

if [ -f /root/mynodeone-join-token.txt ]; then
    echo -e "  ${GREEN}✓${NC} /root/mynodeone-join-token.txt (kept for adding worker nodes)"
fi

if [ $FILES_FOUND -gt 0 ]; then
    echo
    echo -e "${YELLOW}⚠️  WARNING: Credential files found on disk! For security, delete them:${NC}"
    echo -e "   ${YELLOW}sudo rm /root/mynodeone-*-credentials.txt${NC}"
    echo
fi

print_header "Security Recommendations"

echo "1. ✅ Use show-credentials.sh to view passwords (reads from Kubernetes, not files)"
echo "2. 📋 Save credentials to password manager (1Password, Bitwarden, KeePassXC)"
echo "3. 🗑️  Delete credential files if they still exist (see above)"
echo "4. 🔄 Change default passwords after first login"
echo "5. 🔁 Regularly rotate credentials (90-day schedule recommended)"
echo

print_header "Access Documentation"

echo "For complete access information, see:"
echo "  • ACCESS_INFORMATION.md"
echo "  • QUICK_START.md"
echo
