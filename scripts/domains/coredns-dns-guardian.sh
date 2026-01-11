#!/bin/bash

# CoreDNS DNS Guardian - Ensures CoreDNS uses public DNS servers
# This script defends against K3s overwriting our DNS configuration
# Run as: sudo bash coredns-dns-guardian.sh [--install-service]

set -e

LOG_PREFIX="[DNS-Guardian]"

log_info() {
    echo "$LOG_PREFIX INFO: $1"
}

log_warn() {
    echo "$LOG_PREFIX WARN: $1"
}

log_success() {
    echo "$LOG_PREFIX SUCCESS: $1"
}

log_error() {
    echo "$LOG_PREFIX ERROR: $1"
}

fix_coredns_dns() {
    log_info "Checking CoreDNS configuration..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Ensure Kubernetes is installed."
        return 1
    fi
    
    # Check if CoreDNS configmap exists
    if ! kubectl get configmap -n kube-system coredns &>/dev/null; then
        log_warn "CoreDNS configmap not found. Cluster may not be ready."
        return 1
    fi
    
    # Check current configuration
    local current_forward
    current_forward=$(kubectl get configmap -n kube-system coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "forward" || true)
    
    if echo "$current_forward" | grep -q "/etc/resolv.conf"; then
        log_info "CoreDNS using /etc/resolv.conf - applying fix..."
        
        # Apply the fix
        if kubectl get configmap -n kube-system coredns -o json | \
            jq '.data.Corefile = (.data.Corefile | sub("forward . /etc/resolv.conf"; "forward . 8.8.8.8 1.1.1.1"))' | \
            kubectl apply -f - &>/dev/null; then
            
            log_success "CoreDNS configuration updated to use 8.8.8.8 1.1.1.1"
            
            # Restart CoreDNS pods
            kubectl rollout restart deployment coredns -n kube-system &>/dev/null
            log_info "CoreDNS pods restarted"
            
            return 0
        else
            log_error "Failed to update CoreDNS configuration"
            return 1
        fi
    elif echo "$current_forward" | grep -q "8.8.8.8.*1.1.1.1"; then
        log_info "CoreDNS already configured with public DNS servers - no action needed"
        return 0
    else
        log_warn "CoreDNS has unexpected forward configuration: $current_forward"
        return 1
    fi
}

install_systemd_service() {
    log_info "Installing systemd service for persistent DNS guardian..."
    
    # Create systemd service
    cat > /etc/systemd/system/coredns-dns-guardian.service << 'EOF'
[Unit]
Description=CoreDNS DNS Guardian
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/coredns-dns-guardian.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer for periodic checks
    cat > /etc/systemd/system/coredns-dns-guardian.timer << 'EOF'
[Unit]
Description=Run CoreDNS DNS Guardian every 5 minutes
Requires=coredns-dns-guardian.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Copy script to system location
    cp "$0" /usr/local/bin/coredns-dns-guardian.sh
    chmod +x /usr/local/bin/coredns-dns-guardian.sh
    
    # Enable and start the service
    systemctl daemon-reload
    systemctl enable coredns-dns-guardian.timer
    systemctl start coredns-dns-guardian.timer
    
    log_success "DNS Guardian systemd service installed and enabled"
    log_info "Guardian will check DNS configuration every 5 minutes"
}

show_status() {
    log_info "CoreDNS DNS Guardian Status"
    echo "================================"
    
    if systemctl is-enabled coredns-dns-guardian.timer &>/dev/null; then
        echo "✅ Guardian Service: ENABLED"
        if systemctl is-active coredns-dns-guardian.timer &>/dev/null; then
            echo "✅ Guardian Timer: ACTIVE"
        else
            echo "❌ Guardian Timer: INACTIVE"
        fi
    else
        echo "❌ Guardian Service: NOT INSTALLED"
    fi
    
    echo ""
    echo "Current CoreDNS DNS Configuration:"
    if kubectl get configmap -n kube-system coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "forward" | grep -q "8.8.8.8.*1.1.1.1"; then
        echo "✅ Using public DNS servers (8.8.8.8 1.1.1.1)"
    elif kubectl get configmap -n kube-system coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "forward" | grep -q "/etc/resolv.conf"; then
        echo "❌ Using /etc/resolv.conf (problematic)"
    else
        echo "⚠️  Unknown DNS configuration"
    fi
    
    echo ""
    echo "Recent Guardian Activity:"
    journalctl -u coredns-dns-guardian.service --since "1 hour ago" --no-pager -n 5 2>/dev/null || echo "No recent activity logged"
}

uninstall_service() {
    log_info "Uninstalling CoreDNS DNS Guardian service..."
    
    systemctl stop coredns-dns-guardian.timer &>/dev/null || true
    systemctl disable coredns-dns-guardian.timer &>/dev/null || true
    
    rm -f /etc/systemd/system/coredns-dns-guardian.service
    rm -f /etc/systemd/system/coredns-dns-guardian.timer
    rm -f /usr/local/bin/coredns-dns-guardian.sh
    
    systemctl daemon-reload
    
    log_success "DNS Guardian service uninstalled"
}

main() {
    case "${1:-}" in
        --install-service)
            fix_coredns_dns
            install_systemd_service
            ;;
        --status)
            show_status
            ;;
        --uninstall)
            uninstall_service
            ;;
        --help)
            echo "CoreDNS DNS Guardian - Persistent DNS Fix"
            echo ""
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  (no args)         Apply DNS fix once"
            echo "  --install-service Install persistent systemd service"
            echo "  --status          Show guardian and DNS status"
            echo "  --uninstall       Remove guardian service"
            echo "  --help            Show this help"
            ;;
        *)
            fix_coredns_dns
            ;;
    esac
}

# Ensure running as root for systemd operations
if [[ "${1:-}" =~ ^--(install-service|uninstall)$ ]] && [ "$EUID" -ne 0 ]; then
    echo "$LOG_PREFIX ERROR: Must run with sudo for --install-service or --uninstall"
    exit 1
fi

main "$@"
