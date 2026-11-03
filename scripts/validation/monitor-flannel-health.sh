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
#
# If flannel.1 stays missing, restarts K3s/K3s-agent to recover it. A restart interrupts
# this node's pods, so it's the last resort. It doesn't restart when:
#   - the interface comes back during a few checks over the next minute
#   - k3s started within the last few minutes
#   - the interface Flannel runs over (flannel-iface) is down: restarting can't help
#   - the configured Flannel backend doesn't use flannel.1
#   - it restarted recently: 15 minutes after the first restart, doubling each time
#   - it has already restarted 4 times in 24 hours: then it needs a person
###############################################################################

set -euo pipefail

LOG_TAG="flannel-health"
INSTALL_PATH="/usr/local/sbin/mynodeone-flannel-health"
FLANNEL_IFACE="flannel.1"
STATE_DIR="${FLANNEL_HEALTH_STATE_DIR:-/var/lib/mynodeone/flannel-health}"
RECOVERY_LOG="$STATE_DIR/recovery.log"
K3S_CONFIG_FILE="${K3S_CONFIG_FILE:-/etc/rancher/k3s/config.yaml}"
MAX_RECOVERIES_PER_DAY="${MAX_RECOVERIES_PER_DAY:-4}"
RECOVERY_BACKOFF_SECONDS="${RECOVERY_BACKOFF_SECONDS:-900}"
RECOVERY_WAIT_SECONDS="${RECOVERY_WAIT_SECONDS:-60}"
RECHECK_ATTEMPTS="${RECHECK_ATTEMPTS:-3}"
RECHECK_DELAY_SECONDS="${RECHECK_DELAY_SECONDS:-20}"
K3S_STARTUP_GRACE_SECONDS="${K3S_STARTUP_GRACE_SECONDS:-300}"
ALERT_HOOK="${ALERT_HOOK:-/etc/mynodeone/hooks/flannel-health.sh}"

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

notify_hook() {
    local event="$1"
    local message="$2"

    if [ -x "$ALERT_HOOK" ]; then
        "$ALERT_HOOK" "$event" "$message" 2>/dev/null || true
    fi
}

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

# Counts recoveries in the last N seconds.
count_recent_recoveries() {
    local window="$1"
    if [ ! -f "$RECOVERY_LOG" ]; then
        echo "0"
        return
    fi

    awk -v since="$(( $(date +%s) - window ))" '$1 ~ /^[0-9]+$/ && $1 >= since { n++ } END { print n + 0 }' "$RECOVERY_LOG"
}

last_recovery_epoch() {
    if [ -f "$RECOVERY_LOG" ]; then
        awk '$1 ~ /^[0-9]+$/ { last = $1 } END { print last + 0 }' "$RECOVERY_LOG"
    else
        echo "0"
    fi
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

flannel_is_healthy() {
    ip link show "$FLANNEL_IFACE" &>/dev/null || return 1
    [ -n "$(ip -4 addr show "$FLANNEL_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)" ]
}

# Reads one key from the k3s config. Prints nothing if it isn't set.
k3s_config_value() {
    [ -r "$K3S_CONFIG_FILE" ] || return 0
    awk -v key="$1" '$1 == key ":" { v = $2; gsub(/["\047]/, "", v); print v; exit }' "$K3S_CONFIG_FILE"
}

# True while k3s has only just started, when flannel.1 isn't expected to be up yet.
k3s_recently_started() {
    local entered epoch
    entered=$(systemctl show -p ActiveEnterTimestamp --value "$1" 2>/dev/null || true)
    [ -n "$entered" ] || return 1
    epoch=$(date -d "$entered" +%s 2>/dev/null) || return 1
    [ $(( $(date +%s) - epoch )) -lt "$K3S_STARTUP_GRACE_SECONDS" ]
}

check_flannel_health() {
    local k3s_service=$(detect_k3s_service)

    if [ -z "$k3s_service" ]; then
        log_warn "K3s is not running - skipping Flannel health check"
        return 0
    fi

    if flannel_is_healthy; then
        log_success "Flannel interface healthy: $FLANNEL_IFACE"
        return 0
    fi

    # flannel.1 only exists with the vxlan backend. Any other backend isn't a failure.
    local backend
    backend=$(k3s_config_value flannel-backend)
    if [ -n "$backend" ] && [ "$backend" != "vxlan" ]; then
        log_info "flannel-backend is $backend, which doesn't use $FLANNEL_IFACE - skipping"
        return 0
    fi

    if k3s_recently_started "$k3s_service"; then
        log_info "$k3s_service started under ${K3S_STARTUP_GRACE_SECONDS}s ago, so $FLANNEL_IFACE may still be coming up - not restarting"
        return 0
    fi

    # Flannel can't create its interface without the one it runs over, and restarting k3s
    # doesn't bring that back. This is the usual case when Tailscale drops.
    local underlay
    underlay=$(k3s_config_value flannel-iface)
    if [ -n "$underlay" ] && ! ip -o link show "$underlay" 2>/dev/null | grep -qE '<([^>]*,)?UP(,[^>]*)?>'; then
        log_error "$underlay, which Flannel runs over, is missing or down on $(hostname) - not restarting $k3s_service, because that can't fix it"
        notify_hook "flannel-underlay-down" "$underlay is down on $(hostname). Flannel can't run until it's back."
        return 1
    fi

    # One failed look isn't a failure. Look again before doing anything disruptive.
    local attempt
    for ((attempt = 1; attempt <= RECHECK_ATTEMPTS; attempt++)); do
        log_warn "$FLANNEL_IFACE not healthy, checking again in ${RECHECK_DELAY_SECONDS}s ($attempt/$RECHECK_ATTEMPTS)"
        sleep "$RECHECK_DELAY_SECONDS"
        if flannel_is_healthy; then
            log_success "$FLANNEL_IFACE came back without a restart"
            return 0
        fi
    done

    log_error "Flannel interface $FLANNEL_IFACE is MISSING or has no IP on $(hostname)"
    notify_hook "flannel-missing" "Flannel interface $FLANNEL_IFACE missing on $(hostname)"

    # Each restart interrupts every pod's networking on this node, and if the first few
    # didn't fix it, more won't. So: wait longer after each one, and stop at a daily cap.
    local recent last wait_needed since_last
    recent=$(count_recent_recoveries 86400)
    if [ "$recent" -ge "$MAX_RECOVERIES_PER_DAY" ]; then
        log_error "$recent restarts in the last 24 hours (limit: $MAX_RECOVERIES_PER_DAY) - NOT restarting"
        log_error "Manual intervention required. Check K3s logs: journalctl -u $k3s_service -n 50"
        notify_hook "recovery-throttled" "Flannel recovery stopped on $(hostname) after $recent restarts in 24 hours. Check K3s logs."
        return 1
    fi
    if [ "$recent" -gt 0 ]; then
        last=$(last_recovery_epoch)
        wait_needed=$(( RECOVERY_BACKOFF_SECONDS * (1 << (recent - 1)) ))
        since_last=$(( $(date +%s) - last ))
        if [ "$since_last" -lt "$wait_needed" ]; then
            log_warn "Backing off: restarted $k3s_service ${since_last}s ago, next attempt no sooner than ${wait_needed}s after that ($recent in the last 24 hours)"
            return 1
        fi
    fi

    # Attempt recovery by restarting K3s
    log_warn "Attempting recovery: restarting $k3s_service (recovery $((recent + 1))/$MAX_RECOVERIES_PER_DAY in 24 hours)"
    record_recovery

    if systemctl restart "$k3s_service"; then
        # Wait for Flannel to come up
        local waited=0
        while [ "$waited" -lt "$RECOVERY_WAIT_SECONDS" ]; do
            if flannel_is_healthy; then
                log_success "Recovery successful: $FLANNEL_IFACE restored after ${waited}s"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done

        log_error "Recovery FAILED: $FLANNEL_IFACE not healthy after ${RECOVERY_WAIT_SECONDS}s"
        log_error "Manual intervention required"
        notify_hook "recovery-failed" "Flannel recovery failed on $(hostname); $FLANNEL_IFACE missing after restart."
        return 1
    else
        log_error "Failed to restart $k3s_service"
        notify_hook "recovery-failed" "Failed to restart $k3s_service on $(hostname) during flannel recovery."
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

    # VXLAN runs over tailscale0 (flannel-iface), so the tailscale0 rule is what it needs
    if ! ufw status 2>/dev/null | grep -E 'on tailscale0[[:space:]]+ALLOW' >/dev/null; then
        log_warn "UFW does NOT allow traffic on tailscale0 - Flannel overlay may be broken"
        issues=$((issues + 1))
    fi

    # Older installs opened this to Anywhere. It is not needed and exposes VXLAN to the LAN.
    if ufw status 2>/dev/null | grep -E '^8472/udp( \(v6\))?[[:space:]]+ALLOW' >/dev/null; then
        log_warn "UFW allows 8472/udp from Anywhere and it is not needed - remove it: sudo ufw delete allow 8472/udp"
    fi

    if [ "$issues" -eq 0 ]; then
        log_success "UFW configuration correct for Kubernetes networking"
    else
        log_error "$issues UFW issue(s) detected - expected: 'ufw default allow routed' and 'ufw allow in on tailscale0'"
    fi

    return $issues
}

###############################################################################
# Systemd Installation
###############################################################################

install_systemd() {
    local script_path
    script_path="$(realpath "$0")"

    log_info "Installing Flannel health monitor as systemd timer..."

    # This runs as root, so it runs from a root-owned copy. Running it from the repo
    # would let anyone who can write to the checkout run code as root.
    install -o root -g root -m 755 "$script_path" "$INSTALL_PATH"

    # Create service unit
    cat > /etc/systemd/system/flannel-health-monitor.service <<EOF
[Unit]
Description=MyNodeOne Flannel Interface Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
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
    rm -f "$INSTALL_PATH"
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
        local recent=$(count_recent_recoveries 86400)
        echo "Recoveries: $total total, $recent in last 24 hours (limit: $MAX_RECOVERIES_PER_DAY)"
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
