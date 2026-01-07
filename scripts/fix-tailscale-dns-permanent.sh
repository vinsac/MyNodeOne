#!/bin/bash

# Permanent Tailscale DNS Override
# Prevents Tailscale from breaking host DNS resolution
# Makes control plane internet connectivity persistent across reboots

set -e

LOG_PREFIX="[DNS-Fix]"

log_info() {
    echo "$LOG_PREFIX INFO: $1"
}

log_success() {
    echo "$LOG_PREFIX SUCCESS: $1"
}

log_error() {
    echo "$LOG_PREFIX ERROR: $1"
}

fix_tailscale_dns_permanent() {
    log_info "Applying permanent fix for Tailscale DNS override..."
    
    # 1. Configure systemd-resolved to override Tailscale DNS
    log_info "Configuring systemd-resolved with reliable DNS servers..."
    mkdir -p /etc/systemd/resolved.conf.d/
    
    cat > /etc/systemd/resolved.conf.d/override-tailscale-dns.conf << 'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=1.0.0.1 9.9.9.9 208.67.222.222
Domains=~.
DNSSEC=no
DNSStubListener=no
Cache=yes
EOF

    # 2. Create systemd service to maintain DNS configuration
    log_info "Installing DNS persistence service..."
    
    cat > /etc/systemd/system/maintain-dns-config.service << 'EOF'
[Unit]
Description=Maintain DNS Configuration Against Tailscale Override
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/maintain-dns-config.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 3. Create the maintenance script
    cat > /usr/local/bin/maintain-dns-config.sh << 'EOF'
#!/bin/bash

# Check if resolv.conf is controlled by Tailscale and fix it
if grep -q "tailscale" /etc/resolv.conf || grep -q "100.100.100.100" /etc/resolv.conf; then
    # Backup original if exists
    if [ ! -f /etc/resolv.conf.tailscale.backup ]; then
        cp /etc/resolv.conf /etc/resolv.conf.tailscale.backup
    fi
    
    # Apply reliable DNS configuration
    cat > /etc/resolv.conf << EOF_DNS
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 1.0.0.1
search tail9bb5a2.ts.net home
EOF_DNS
    
    # Make immutable to prevent Tailscale from overwriting
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    echo "[$(date)] DNS configuration restored from Tailscale override"
fi
EOF

    chmod +x /usr/local/bin/maintain-dns-config.sh

    # 4. Create systemd timer for periodic checks
    cat > /etc/systemd/system/maintain-dns-config.timer << 'EOF'
[Unit]
Description=Check DNS configuration every 2 minutes
Requires=maintain-dns-config.service

[Timer]
OnBootSec=30sec
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 5. Apply initial DNS fix
    log_info "Applying initial DNS configuration..."
    
    # Stop systemd-resolved to prevent conflicts
    systemctl stop systemd-resolved 2>/dev/null || true
    
    # Backup current resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.tailscale.backup 2>/dev/null || true
    
    # Remove immutable flag if exists
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Apply reliable DNS configuration
    cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 1.0.0.1
search tail9bb5a2.ts.net home
EOF
    
    # Make immutable to prevent Tailscale from overwriting
    # Note: chattr may fail on some filesystems (e.g., tmpfs, overlayfs) - this is non-critical
    if ! chattr +i /etc/resolv.conf 2>/dev/null; then
        log_warn "Could not make /etc/resolv.conf immutable (filesystem may not support it)"
        log_info "DNS will still be maintained by the timer service"
    fi
    
    # 6. Enable and start services
    systemctl daemon-reload
    systemctl enable maintain-dns-config.timer
    systemctl start maintain-dns-config.timer
    
    # Run initial maintenance
    /usr/local/bin/maintain-dns-config.sh
    
    log_success "Permanent DNS fix applied successfully"
    log_info "DNS configuration will be maintained automatically across reboots"
    
    # Test DNS resolution
    if dig google.com @8.8.8.8 +short > /dev/null 2>&1; then
        log_success "DNS resolution test passed"
    else
        log_error "DNS resolution test failed - manual intervention may be needed"
    fi
}

revert_dns_fix() {
    log_info "Reverting permanent DNS fix..."
    
    # Remove immutable flag
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # Restore Tailscale backup if exists
    if [ -f /etc/resolv.conf.tailscale.backup ]; then
        cp /etc/resolv.conf.tailscale.backup /etc/resolv.conf
    fi
    
    # Stop and disable services
    systemctl stop maintain-dns-config.timer 2>/dev/null || true
    systemctl disable maintain-dns-config.timer 2>/dev/null || true
    
    # Remove service files
    rm -f /etc/systemd/system/maintain-dns-config.service
    rm -f /etc/systemd/system/maintain-dns-config.timer
    rm -f /usr/local/bin/maintain-dns-config.sh
    rm -f /etc/systemd/resolved.conf.d/override-tailscale-dns.conf
    
    systemctl daemon-reload
    systemctl start systemd-resolved 2>/dev/null || true
    
    log_success "DNS fix reverted - Tailscale will control DNS again"
}

show_status() {
    echo "=== DNS Configuration Status ==="
    echo ""
    
    if [ -f /etc/systemd/system/maintain-dns-config.timer ]; then
        echo "✅ DNS Maintenance Service: INSTALLED"
        if systemctl is-active maintain-dns-config.timer &>/dev/null; then
            echo "✅ DNS Timer: ACTIVE"
        else
            echo "❌ DNS Timer: INACTIVE"
        fi
    else
        echo "❌ DNS Maintenance Service: NOT INSTALLED"
    fi
    
    echo ""
    echo "Current /etc/resolv.conf:"
    cat /etc/resolv.conf | head -10
    
    echo ""
    echo "DNS Resolution Test:"
    if dig google.com +short > /dev/null 2>&1; then
        echo "✅ DNS working"
    else
        echo "❌ DNS not working"
    fi
    
    echo ""
    echo "Recent DNS maintenance activity:"
    journalctl -u maintain-dns-config.service --since "1 hour ago" --no-pager -n 3 2>/dev/null || echo "No recent activity"
}

main() {
    case "${1:-}" in
        --revert)
            revert_dns_fix
            ;;
        --status)
            show_status
            ;;
        --help)
            echo "Permanent Tailscale DNS Fix"
            echo ""
            echo "Usage: $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  (no args)  Apply permanent DNS fix"
            echo "  --status   Show DNS fix status"
            echo "  --revert   Remove DNS fix (restore Tailscale control)"
            echo "  --help     Show this help"
            ;;
        *)
            fix_tailscale_dns_permanent
            ;;
    esac
}

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "$LOG_PREFIX ERROR: Must run with sudo"
    exit 1
fi

main "$@"
