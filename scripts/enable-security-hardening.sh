#!/bin/bash

###############################################################################
# NodeZero Security Hardening Script
# 
# Enables all MEDIUM/LOW security features:
# - Kubernetes audit logging
# - Secrets encryption at rest
# - Pod Security Standards
# - Network policies
# - Resource quotas
# - Traefik security headers
#
# Run this AFTER bootstrap-control-plane.sh
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Is K3s installed?"
        exit 1
    fi
    
    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

enable_audit_logging() {
    log_info "Enabling Kubernetes audit logging..."
    
    # Copy audit policy
    cp "$PROJECT_ROOT/config/security/audit-policy.yaml" /etc/rancher/k3s/audit-policy.yaml
    
    # Backup existing K3s config
    if [ -f /etc/rancher/k3s/config.yaml ]; then
        cp /etc/rancher/k3s/config.yaml /etc/rancher/k3s/config.yaml.backup-$(date +%Y%m%d)
    fi
    
    # Add audit logging configuration to K3s
    cat >> /etc/rancher/k3s/config.yaml <<EOF

# Audit logging configuration
kube-apiserver-arg:
  - "audit-log-path=/var/log/k3s-audit.log"
  - "audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
EOF
    
    log_info "Restarting K3s to apply audit logging..."
    systemctl restart k3s
    
    # Wait for K3s to be ready
    sleep 10
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    log_success "Audit logging enabled"
    log_info "Audit logs location: /var/log/k3s-audit.log"
}

enable_secrets_encryption() {
    log_info "Enabling secrets encryption at rest..."
    
    # Generate encryption key
    ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
    
    # Create encryption config from template
    sed "s/<GENERATED_KEY>/$ENCRYPTION_KEY/" \
        "$PROJECT_ROOT/config/security/encryption-config.yaml.template" \
        > /etc/rancher/k3s/encryption-config.yaml
    
    chmod 600 /etc/rancher/k3s/encryption-config.yaml
    
    # Add to K3s config
    cat >> /etc/rancher/k3s/config.yaml <<EOF

# Secrets encryption at rest
kube-apiserver-arg:
  - "encryption-provider-config=/etc/rancher/k3s/encryption-config.yaml"
EOF
    
    log_info "Restarting K3s to apply secrets encryption..."
    systemctl restart k3s
    
    # Wait for K3s to be ready
    sleep 10
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    log_success "Secrets encryption enabled"
    log_warn "Existing secrets need to be re-encrypted. Run: kubectl get secrets --all-namespaces -o json | kubectl replace -f -"
}

enable_pod_security_standards() {
    log_info "Enabling Pod Security Standards..."
    
    # Copy Pod Security config
    cp "$PROJECT_ROOT/config/security/pod-security-config.yaml" /etc/rancher/k3s/pod-security-config.yaml
    
    # Add to K3s config
    cat >> /etc/rancher/k3s/config.yaml <<EOF

# Pod Security Standards
kube-apiserver-arg:
  - "admission-control-config-file=/etc/rancher/k3s/pod-security-config.yaml"
EOF
    
    log_info "Restarting K3s to apply Pod Security Standards..."
    systemctl restart k3s
    
    # Wait for K3s to be ready
    sleep 10
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    log_success "Pod Security Standards enabled (restricted mode)"
    log_warn "New pods must comply with restricted security profile"
}

deploy_network_policies() {
    log_info "Deploying default network policies..."
    
    kubectl apply -f "$PROJECT_ROOT/manifests/security/network-policies.yaml"
    
    log_success "Network policies deployed"
    log_warn "Default deny policy is active. Configure app-specific policies as needed."
}

deploy_resource_quotas() {
    log_info "Deploying resource quotas..."
    
    kubectl apply -f "$PROJECT_ROOT/manifests/security/resource-quotas.yaml"
    
    log_success "Resource quotas deployed"
    log_info "All new pods must specify resource requests/limits"
}

deploy_traefik_security() {
    log_info "Deploying Traefik security headers..."
    
    kubectl apply -f "$PROJECT_ROOT/manifests/security/traefik-security-headers.yaml"
    
    log_success "Traefik security middleware deployed"
    log_info "Apply 'secure-chain' middleware to your IngressRoutes"
}

print_summary() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Security Hardening Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Enabled Security Features:"
    echo "  ✅ Kubernetes audit logging (/var/log/k3s-audit.log)"
    echo "  ✅ Secrets encryption at rest (AES-CBC)"
    echo "  ✅ Pod Security Standards (restricted)"
    echo "  ✅ Network policies (default deny)"
    echo "  ✅ Resource quotas (prevents exhaustion)"
    echo "  ✅ Traefik security headers (HSTS, CSP, etc.)"
    echo
    echo "Configuration Files:"
    echo "  - /etc/rancher/k3s/audit-policy.yaml"
    echo "  - /etc/rancher/k3s/encryption-config.yaml"
    echo "  - /etc/rancher/k3s/pod-security-config.yaml"
    echo
    echo "Next Steps:"
    echo "  1. Monitor audit logs: tail -f /var/log/k3s-audit.log"
    echo "  2. Re-encrypt existing secrets: kubectl get secrets --all-namespaces -o json | kubectl replace -f -"
    echo "  3. Add security middleware to your apps (see traefik-security-headers.yaml)"
    echo "  4. Review network policies for your applications"
    echo "  5. Review SECURITY-AUDIT.md for remaining recommendations"
    echo
    echo "Documentation:"
    echo "  - docs/security-best-practices.md"
    echo "  - docs/password-management.md"
    echo "  - SECURITY-AUDIT.md"
    echo
    log_success "Your cluster is now significantly more secure! 🔒"
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NodeZero Security Hardening"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    
    log_warn "This will restart K3s multiple times. Temporary disruption expected."
    read -p "Continue? [y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled by user"
        exit 0
    fi
    
    enable_audit_logging
    enable_secrets_encryption
    enable_pod_security_standards
    deploy_network_policies
    deploy_resource_quotas
    deploy_traefik_security
    
    echo
    print_summary
}

# Run main function
main "$@"
