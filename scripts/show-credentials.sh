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

# Get credentials
GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "Not available")

echo -e "${GREEN}📊 Grafana (Monitoring)${NC}"
echo "  URL: http://$GRAFANA_IP"
echo "  Username: admin"
echo "  Password: $GRAFANA_PASS"
echo

echo -e "${GREEN}🚀 ArgoCD (GitOps)${NC}"
echo "  URL: https://$ARGOCD_IP"
if [ -f /root/mynodeone-argocd-credentials.txt ]; then
    echo "  Credentials file: /root/mynodeone-argocd-credentials.txt"
    echo -e "${YELLOW}  Run: cat /root/mynodeone-argocd-credentials.txt${NC}"
else
    echo "  Credentials file not found"
fi
echo

echo -e "${GREEN}💾 MinIO (S3 Storage)${NC}"
echo "  Console URL: http://$MINIO_CONSOLE_IP:9001"
echo "  API URL: http://$MINIO_API_IP:9000"
if [ -f /root/mynodeone-minio-credentials.txt ]; then
    echo "  Credentials file: /root/mynodeone-minio-credentials.txt"
    echo -e "${YELLOW}  Run: cat /root/mynodeone-minio-credentials.txt${NC}"
else
    echo "  Credentials file not found"
fi
echo

echo -e "${GREEN}📦 Longhorn (Block Storage)${NC}"
echo "  URL: http://$LONGHORN_IP"
echo "  Authentication: None (protected by Tailscale VPN)"
echo

print_header "Credential Files Location"

echo "All credential files are stored in /root/ with 600 permissions:"
echo
if [ -f /root/mynodeone-argocd-credentials.txt ]; then
    echo "  ✓ /root/mynodeone-argocd-credentials.txt"
else
    echo "  ✗ /root/mynodeone-argocd-credentials.txt (not found)"
fi

if [ -f /root/mynodeone-minio-credentials.txt ]; then
    echo "  ✓ /root/mynodeone-minio-credentials.txt"
else
    echo "  ✗ /root/mynodeone-minio-credentials.txt (not found)"
fi

if [ -f /root/mynodeone-join-token.txt ]; then
    echo "  ✓ /root/mynodeone-join-token.txt"
else
    echo "  ✗ /root/mynodeone-join-token.txt (not found)"
fi
echo

print_header "Security Recommendations"

echo "1. Save these credentials in a secure password manager"
echo "2. Change default passwords after first login"
echo "3. Delete credential files after saving securely:"
echo -e "   ${YELLOW}sudo rm /root/mynodeone-*-credentials.txt${NC}"
echo "4. Regularly rotate credentials"
echo

print_header "Access Documentation"

echo "For complete access information, see:"
echo "  • ACCESS_INFORMATION.md"
echo "  • QUICK_START.md"
echo
