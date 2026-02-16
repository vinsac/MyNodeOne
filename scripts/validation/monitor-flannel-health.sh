#!/bin/bash

###############################################################################
# Flannel Interface Health Monitor
#
# Monitors the Flannel VXLAN interface (flannel.1) and alerts/recovers
# if it goes missing. Designed to run as a systemd service with a timer.
#
# Usage:
#   sudo bash monitor-flannel-health.sh              # One-shot check
#   sudo bash monitor-flannel-health.sh --install     # Install systemd timer
#   sudo bash monitor-flannel-health.sh --uninstall   # Remove systemd timer
#   sudo bash monitor-flannel-health.sh --status      # Show timer status
#
# When installed as a systemd timer, runs every 2 minutes.
# If flannel.1 is missing, restarts K3s/K3s-agent to recover it.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="flannel-health"
FLANNEL_IFACE="flannel.1"
STATE_DIR="/var/lib/mynodeone/flannel-health"
RECOVERY_LOG="$STATE_DIR/recovery.log"
MAX_RECOVERIES_PER_HOUR=3

# Colors (only for interactive use)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; logger -t "$LOG_TAG" "INFO: $1" 2>/dev/null || true; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; logger -t "$LOG_TAG" "OK: $1" 2>/dev/null || true; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; logger -t "$LOG_TAG" "WARN: $1" 2>/dev/null || true; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; logger -t "$LOG_TAG" "ERROR: $1" 2>/dev/null || true; }

###############################################################################
# Core Health Check
###############################################################################

detect_k3s_service() {
    if systemctl is-active k3s &>/dev/null; then
        echo "k3s"
    elif systemctl is-active k3s-agent &>/dev/null; then
        echo "k3s-agent"
    else
        echo ""
    fi
}

count_recent_recoveries() {
    if [ ! -f "$RECOVERY_LOG" ]; then
        echo "0"
        return
    fi

    local one_hour_ago=$(date -d '1 hour ago' +%s 2>/dev/null || date -v-1H +%s 2>/dev/null || echo "0")
    local count=0

    while IFS= read -r line; do
        local ts=$(echo "$line" | awk '{print $1}')
        if [ "$ts" -ge "$one_hour_ago" ] 2>/dev/null; then
            count=$((count + 1))
        fi
    done < "$RECOVERY_LOG"

    echo "$count"
}

record_recovery() {
    mkdir -p "$STATE_DIR"
    echo "$(date +%s) $(date '+%Y-%m-%d %H:%M:%S') recovery" >> "$RECOVERY_LOG"

    # Keep log file manageable (last 100 entries)
    if [ -f "$RECOVERY_LOG" ] && [ "$(wc -l < "$RECOVERY_LOG")" -gt 100 ]; then
        tail -50 "$RECOVERY_LOG" > "$RECOVERY_LOG.tmp"
        mv "$RECOVERY_LOG.tmp" "$RECOVERY_LOG"
    fi
}

check_flannel_health() {
    local k3s_service=$(detect_k3s_service)

    if [ -z "$k3s_service" ]; then
        log_warn "K3s is not running - skipping Flannel health check"
        return 0
    fi

    # Check 1: Does flannel.1 interface exist?
    if ip link show "$FLANNEL_IFACE" &>/dev/null; then
        # Check 2: Does it have an IP?
        local flannel_ip=$(ip -4 addr show "$FLANNEL_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
        if [ -n "$flannel_ip" ]; then
            log_success "Flannel interface healthy: $FLANNEL_IFACE ($flannel_ip)"
            return 0
        else
            log_warn "Flannel interface exists but has no IP address"
        fi
    fi

    # Flannel interface is missing or unhealthy
    log_error "Flannel interface $FLANNEL_IFACE is MISSING on $(hostname)"

    # Check recovery throttle
    local recent=$(count_recent_recoveries)
    if [ "$recent" -ge "$MAX_RECOVERIES_PER_HOUR" ]; then
        log_error "Too many recoveries in the last hour ($recent/$MAX_RECOVERIES_PER_HOUR) - NOT restarting"
        log_error "Manual intervention required. Check K3s logs: journalctl -u $k3s_service -n 50"
        return 1
    fi

    # Attempt recovery by restarting K3s
    log_warn "Attempting recovery: restarting $k3s_service (recovery $((recent + 1))/$MAX_RECOVERIES_PER_HOUR in last hour)"
    record_recovery

    if systemctl restart "$k3s_service"; then
        # Wait for Flannel to come up
        local max_wait=30
        local waited=0
        while [ $waited -lt $max_wait ]; do
            if ip link show "$FLANNEL_IFACE" &>/dev/null; then
                local new_ip=$(ip -4 addr show "$FLANNEL_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "")
                log_success "Recovery successful: $FLANNEL_IFACE restored ($new_ip) after ${waited}s"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done

        log_error "Recovery FAILED: $FLANNEL_IFACE did not appear after ${max_wait}s"
        log_error "Manual intervention required"
        return 1
    else
        log_error "Failed to restart $k3s_service"
        return 1
    fi
}

###############################################################################
# UFW Health Check (bonus - check firewall config hasn't regressed)
###############################################################################

check_ufw_health() {
    # Only check if UFW is active
    if ! ufw status &>/dev/null; then
        return 0
    fi

    local issues=0

    # Check routed policy
    if ! ufw status verbose 2>/dev/null | grep "Default:" | grep -q "allow (routed)"; then
        log_warn "UFW routed policy is NOT 'allow' - pod networking may be broken"
        issues=$((issues + 1))
    fi

    # Check VXLAN port
    if ! ufw status 2>/dev/null | grep -q "8472/udp.*ALLOW"; then
        log_warn "UFW does NOT allow VXLAN port 8472/UDP - Flannel overlay may be broken"
        issues=$((issues + 1))
    fi

    if [ "$issues" -eq 0 ]; then
        log_success "UFW configuration correct for Kubernetes networking"
    else
        log_error "$issues UFW issue(s) detected - run: sudo bash $(dirname "$0")/validate-network.sh --fix"
    fi

    return $issues
}

###############################################################################
# Systemd Installation
###############################################################################

install_systemd() {
    local script_path="$(realpath "$0")"

    log_info "Installing Flannel health monitor as systemd timer..."

    # Create service unit
    cat > /etc/systemd/system/flannel-health-monitor.service <<EOF
[Unit]
Description=MyNodeOne Flannel Interface Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $script_path
StandardOutput=journal
StandardError=journal
EOF

    # Create timer unit (every 2 minutes)
    cat > /etc/systemd/system/flannel-health-monitor.timer <<EOF
[Unit]
Description=MyNodeOne Flannel Health Monitor Timer
Requires=flannel-health-monitor.service

[Timer]
OnBootSec=60
OnUnitActiveSec=120
AccuracySec=10

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable flannel-health-monitor.timer
    systemctl start flannel-health-monitor.timer

    log_success "Flannel health monitor installed and started"
    log_info "Check status: systemctl status flannel-health-monitor.timer"
    log_info "View logs: journalctl -t flannel-health -n 20"
}

uninstall_systemd() {
    log_info "Removing Flannel health monitor..."

    systemctl stop flannel-health-monitor.timer 2>/dev/null || true
    systemctl disable flannel-health-monitor.timer 2>/dev/null || true
    rm -f /etc/systemd/system/flannel-health-monitor.service
    rm -f /etc/systemd/system/flannel-health-monitor.timer
    systemctl daemon-reload

    log_success "Flannel health monitor removed"
}

show_status() {
    echo
    echo "Flannel Health Monitor Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Timer status
    if systemctl is-active flannel-health-monitor.timer &>/dev/null; then
        echo -e "${GREEN}Timer: Active${NC}"
        systemctl status flannel-health-monitor.timer --no-pager 2>/dev/null | grep -E "Active:|Trigger:|Triggers:" || true
    else
        echo -e "${YELLOW}Timer: Not installed or inactive${NC}"
    fi

    echo

    # Current Flannel state
    if ip link show "$FLANNEL_IFACE" &>/dev/null; then
        local ip=$(ip -4 addr show "$FLANNEL_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "no IP")
        echo -e "Flannel: ${GREEN}UP${NC} ($ip)"
    else
        echo -e "Flannel: ${RED}DOWN${NC}"
    fi

    # Recovery history
    if [ -f "$RECOVERY_LOG" ]; then
        local total=$(wc -l < "$RECOVERY_LOG")
        local recent=$(count_recent_recoveries)
        echo "Recoveries: $total total, $recent in last hour"
        echo
        echo "Last 5 recoveries:"
        tail -5 "$RECOVERY_LOG" | while IFS= read -r line; do
            echo "  $line"
        done
    else
        echo "Recoveries: 0 (no recovery log)"
    fi

    echo
    echo "Recent logs:"
    journalctl -t "$LOG_TAG" -n 5 --no-pager 2>/dev/null || echo "  (no journal entries)"
    echo
}

###############################################################################
# Main
###############################################################################

case "${1:-}" in
    --install)
        install_systemd
        ;;
    --uninstall)
        uninstall_systemd
        ;;
    --status)
        show_status
        ;;
    *)
        check_flannel_health
        check_ufw_health
        ;;
esac
