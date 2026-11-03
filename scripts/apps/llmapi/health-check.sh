#!/bin/bash

# Health check for the LLM API. Reports on pods, PVCs, Longhorn and services, and can
# restart a Deployment whose pod is really stuck, within a restart budget.
#
# It never removes finalizers or force-deletes anything, and it only restarts
# Deployments. StatefulSets, Jobs and bare pods are reported for a person to look at.
#
# A pod counts as stuck only when one of these holds:
#   - a container is in CrashLoopBackOff, for longer than CRASHLOOP_THRESHOLD_SECONDS
#   - the Ready condition has been False for longer than POD_RESTART_THRESHOLD_SECONDS
# Time is measured from the Ready condition's lastTransitionTime, the newest container
# start, and when the pod's node last became Ready, whichever is latest. That matters
# after a reboot: a pod can still show a Ready=False from hours earlier, when its node
# went down, even though its containers have only just started.
#
# Usage:
#   health-check.sh                    Run the checks
#   health-check.sh --report-only      Run the checks, take no action
#   health-check.sh --install-monitor  Install the systemd timer and logrotate config

set -euo pipefail

NAMESPACE="llmapi"
SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/var/log/llmapi/${SCRIPT_NAME}.log}"
MONITOR_SCRIPT_PATH="/usr/local/bin/llmapi-health-monitor.sh"
LOGROTATE_CONFIG="/etc/logrotate.d/llmapi-health-monitor"

POD_RESTART_THRESHOLD_SECONDS="${POD_RESTART_THRESHOLD_SECONDS:-1800}"
CRASHLOOP_THRESHOLD_SECONDS="${CRASHLOOP_THRESHOLD_SECONDS:-900}"
# Take no action this soon after this machine booted, while the cluster settles.
BOOT_GRACE_SECONDS="${BOOT_GRACE_SECONDS:-1800}"
# At most this many restarts of one Deployment per window. The wait before each repeat
# restart doubles, starting from the backoff value.
RESTART_BUDGET_MAX="${RESTART_BUDGET_MAX:-3}"
RESTART_BUDGET_WINDOW_SECONDS="${RESTART_BUDGET_WINDOW_SECONDS:-86400}"
RESTART_BACKOFF_SECONDS="${RESTART_BACKOFF_SECONDS:-1800}"
STATE_DIR="${HEALTH_STATE_DIR:-/var/lib/llmapi-health}"
UPTIME_FILE="${HEALTH_UPTIME_FILE:-/proc/uptime}"
REPORT_ONLY="${HEALTH_REPORT_ONLY:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

write_log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null || true
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    write_log "$1"
}

error() {
    echo -e "${RED}ERROR: $1${NC}"
    write_log "ERROR: $1"
}

warn() {
    echo -e "${YELLOW}WARN: $1${NC}"
    write_log "WARN: $1"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
    write_log "SUCCESS: $1"
}

# Check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed or not in PATH"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        error "jq is not installed or not in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
}

# Report only. A PVC stays Terminating while something still uses it, and that protects
# the data. Removing its finalizers is how volumes get lost, so that stays a human decision.
report_stuck_pvcs() {
    log "Checking for PVCs being deleted in namespace '$NAMESPACE'..."

    local pvc_json stuck_pvcs
    if ! pvc_json=$(kubectl get pvc -n "$NAMESPACE" -o json 2>/dev/null); then
        warn "Could not list PVCs"
        return 0
    fi

    stuck_pvcs=$(jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' <<<"$pvc_json")
    if [[ -z "$stuck_pvcs" ]]; then
        success "No PVCs are being deleted"
        return 0
    fi

    warn "PVCs waiting to finish deleting (no action taken): $(tr '\n' ' ' <<<"$stuck_pvcs")"
    warn "Find what still mounts them: kubectl describe pvc -n $NAMESPACE <name>"
}

system_uptime_seconds() {
    local uptime=""
    if [[ -r "$UPTIME_FILE" ]]; then
        uptime=$(cut -d. -f1 <"$UPTIME_FILE" | cut -d' ' -f1)
    fi
    echo "${uptime:-0}"
}

# Prints the time a restart is allowed, or nothing if the budget is used up. Also trims
# entries that have aged out of the window.
restart_allowed_at() {
    local state_file="$1" now="$2" kept="" stamp count=0 last=0
    if [[ -f "$state_file" ]]; then
        while IFS= read -r stamp; do
            if [[ "$stamp" =~ ^[0-9]+$ ]] && (( now - stamp < RESTART_BUDGET_WINDOW_SECONDS )); then
                kept+="$stamp"$'\n'
                count=$((count + 1))
                last=$stamp
            fi
        done <"$state_file"
        printf '%s' "$kept" >"$state_file"
    fi
    if (( count >= RESTART_BUDGET_MAX )); then
        return 0
    fi
    if (( count == 0 )); then
        echo "$now"
    else
        echo $((last + RESTART_BACKOFF_SECONDS * (1 << (count - 1))))
    fi
}

# Restarts a Deployment if the budget and backoff allow it.
restart_deployment() {
    local deployment="$1" reason="$2" now="$3" state_file allowed_at
    if [[ "$REPORT_ONLY" == "true" ]]; then
        warn "Would restart deployment $deployment ($reason), but running report-only"
        return 0
    fi

    # With nowhere to record the restart there is no budget, so don't restart.
    if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! [[ -w "$STATE_DIR" ]]; then
        warn "Cannot write to $STATE_DIR, not restarting deployment $deployment ($reason)"
        return 0
    fi
    state_file="$STATE_DIR/restarts-$deployment"

    allowed_at=$(restart_allowed_at "$state_file" "$now")
    if [[ -z "$allowed_at" ]]; then
        error "Deployment $deployment needs attention ($reason): restart budget of $RESTART_BUDGET_MAX per $((RESTART_BUDGET_WINDOW_SECONDS / 3600))h is used up, not restarting"
        return 0
    fi
    if (( now < allowed_at )); then
        warn "Deployment $deployment still unhealthy ($reason), next restart allowed in $(( (allowed_at - now) / 60 ))m"
        return 0
    fi

    log "Restarting deployment $deployment: $reason"
    if kubectl rollout restart deployment/"$deployment" -n "$NAMESPACE"; then
        echo "$now" >>"$state_file"
        success "Initiated restart for deployment: $deployment"
    else
        warn "Failed to restart deployment $deployment"
    fi
}

# Checks each pod once, from a single consistent snapshot of the cluster.
fix_pod_issues() {
    log "Checking for pod issues in namespace '$NAMESPACE'..."

    local pods_json rs_json nodes_json now uptime rows
    if ! pods_json=$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null) ||
        ! rs_json=$(kubectl get replicasets -n "$NAMESPACE" -o json 2>/dev/null) ||
        ! nodes_json=$(kubectl get nodes -o json 2>/dev/null); then
        warn "Could not read cluster state, taking no action this run"
        return 0
    fi

    now="${HEALTH_NOW:-$(date +%s)}"
    uptime=$(system_uptime_seconds)

    # One row per pod that isn't healthy: name, phase, owner kind, owner name, whether
    # anything is crash looping, waiting on an image, or still in an init container, and
    # how long the pod has really been unready.
    if ! rows=$(jq -r --argjson now "$now" --slurpfile rs <(printf '%s' "$rs_json") --slurpfile nodes <(printf '%s' "$nodes_json") '
        def epoch: if . == null then 0 else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
        ($rs[0].items | map({key: .metadata.name, value: ([.metadata.ownerReferences[]? | select(.kind == "Deployment") | .name][0] // "")}) | from_entries) as $rs_owner
        | ($nodes[0].items | map({key: .metadata.name, value: ([.status.conditions[]? | select(.type == "Ready")][0] | {ready: (.status == "True"), since: (.lastTransitionTime | epoch)})}) | from_entries) as $node_state
        | .items[]
        | select(.status.phase != "Succeeded" and .metadata.deletionTimestamp == null)
        | ([.status.conditions[]? | select(.type == "Ready")][0] // {}) as $ready
        | select($ready.status != "True")
        | ((.status.containerStatuses // []) + (.status.initContainerStatuses // [])) as $all
        | ([$all[] | .state.waiting.reason? // empty] ) as $waiting
        | ([.status.initContainerStatuses[]? | select(.state.running != null)] | length > 0) as $init_running
        | ((.metadata.ownerReferences // [])[0] // {}) as $owner
        | (if $owner.kind == "ReplicaSet" then {kind: "Deployment", name: ($rs_owner[$owner.name] // "")} else {kind: ($owner.kind // "None"), name: ($owner.name // "")} end) as $workload
        | ($node_state[.spec.nodeName // ""] // {ready: false, since: $now}) as $node
        | ([$all[] | .state.running.startedAt? // empty | epoch] | max // 0) as $last_start
        | ([($ready.lastTransitionTime | epoch), $node.since] | max) as $crash_since
        | ([$crash_since, $last_start] | max) as $unready_since
        | [
            .metadata.name,
            (.status.phase // "Unknown"),
            $workload.kind,
            (if $workload.name == "" then "-" else $workload.name end),
            ($waiting | any(. == "CrashLoopBackOff")),
            ($waiting | any(. == "ImagePullBackOff" or . == "ErrImagePull")),
            $init_running,
            $node.ready,
            ($now - $crash_since),
            ($now - $unready_since)
          ]
        | @tsv
    ' <<<"$pods_json"); then
        warn "Could not parse pod status, taking no action this run"
        return 0
    fi

    if [[ -z "$rows" ]]; then
        success "All pods are healthy"
        return 0
    fi

    local in_boot_grace=false
    if (( uptime < BOOT_GRACE_SECONDS )); then
        in_boot_grace=true
        log "System booted ${uptime}s ago, taking no action during the ${BOOT_GRACE_SECONDS}s grace period"
    fi

    local pod phase kind workload crashloop image_wait init_running node_ready crash_age unready_age
    while IFS=$'\t' read -r pod phase kind workload crashloop image_wait init_running node_ready crash_age unready_age; do
        [[ -n "$pod" ]] || continue

        local reason=""
        if [[ "$phase" == "Failed" ]]; then
            # An evicted pod stays listed after its replacement is running.
            log "Pod $pod has already failed and won't run again, no action needed"
            continue
        elif [[ "$crashloop" == "true" ]] && (( crash_age > CRASHLOOP_THRESHOLD_SECONDS )); then
            reason="CrashLoopBackOff for $((crash_age / 60))m"
        elif [[ "$crashloop" == "true" ]]; then
            log "Pod $pod is in CrashLoopBackOff for $((crash_age / 60))m, below the $((CRASHLOOP_THRESHOLD_SECONDS / 60))m threshold"
            continue
        elif [[ "$image_wait" == "true" ]]; then
            warn "Pod $pod can't pull its image. A restart won't help: kubectl describe pod -n $NAMESPACE $pod"
            continue
        elif [[ "$init_running" == "true" ]]; then
            log "Pod $pod is still initializing (a first model download can take hours)"
            continue
        elif [[ "$phase" == "Pending" ]]; then
            warn "Pod $pod is Pending. A restart won't help: kubectl describe pod -n $NAMESPACE $pod"
            continue
        elif (( unready_age > POD_RESTART_THRESHOLD_SECONDS )); then
            reason="not Ready for $((unready_age / 60))m"
        else
            log "Pod $pod is not Ready for $((unready_age / 60))m, below the $((POD_RESTART_THRESHOLD_SECONDS / 60))m threshold"
            continue
        fi

        warn "Pod $pod ($kind/$workload): $reason"
        kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' 2>/dev/null | tail -n 5 || true

        if [[ "$node_ready" != "true" ]]; then
            warn "The node for pod $pod is not Ready, taking no action"
        elif [[ "$in_boot_grace" == "true" ]]; then
            log "Inside the boot grace period, not acting on pod $pod"
        elif [[ "$kind" == "Deployment" && "$workload" != "-" ]]; then
            restart_deployment "$workload" "pod $pod: $reason" "$now"
        else
            warn "Pod $pod belongs to $kind/$workload, which this script doesn't restart. Look at it directly."
        fi
    done <<<"$rows"
}

# Function to check storage classes and Longhorn
check_storage_health() {
    log "Checking storage health..."

    local longhorn_pods longhorn_total
    longhorn_pods=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | awk '$3 == "Running" {count++} END {print count+0}' || true)
    longhorn_total=$(kubectl get pods -n longhorn-system --no-headers 2>/dev/null | wc -l || true)

    log "Longhorn pods: ${longhorn_pods:-0}/${longhorn_total:-0} running"

    if [[ ${longhorn_pods:-0} -lt $(( ${longhorn_total:-0} - 1 )) ]]; then
        warn "Some Longhorn pods are not running"
        kubectl get pods -n longhorn-system 2>/dev/null || true
    else
        success "Longhorn is healthy"
    fi

    # Check storage classes
    if ! kubectl get storageclass longhorn &> /dev/null; then
        error "Longhorn storage class not found"
    else
        success "Longhorn storage class is available"
    fi
}

# Function to check LLMAPI specific services
check_llmapi_services() {
    log "Checking LLMAPI services..."

    local service label container_name pods_json names pod ready healthy
    for service in redis gateway embedding llmapi-postgres; do
        label="$service"
        container_name="$service"
        if [[ "$service" == "gateway" ]]; then
            label="llmapi-gateway"
        elif [[ "$service" == "llmapi-postgres" ]]; then
            container_name="postgres"
        fi

        if ! pods_json=$(kubectl get pods -n "$NAMESPACE" -l app="$label" -o json 2>/dev/null); then
            warn "Could not list pods for service: $service"
            continue
        fi
        names=$(jq -r '.items[].metadata.name' <<<"$pods_json")
        if [[ -z "$names" ]]; then
            error "No pods found for service: $service"
            continue
        fi

        healthy=true
        for pod in $names; do
            ready=$(jq -r --arg pod "$pod" --arg container "$container_name" \
                '.items[] | select(.metadata.name == $pod) | .status.containerStatuses[]? | select(.name == $container) | .ready' <<<"$pods_json")
            if [[ "$ready" != "true" ]]; then
                error "Pod $pod for service $service is not ready"
                healthy=false
            fi
        done

        if [[ "$healthy" == "true" ]]; then
            success "Service $service is healthy"
        fi
    done
}

install_logrotate_config() {
    cat > "$LOGROTATE_CONFIG" << 'EOF'
/var/log/llmapi/*.log {
    daily
    rotate 14
    maxsize 10M
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
    chmod 644 "$LOGROTATE_CONFIG"
}

# Function to create monitoring systemd service (optional)
create_monitor_service() {
    if [[ "$EUID" -ne 0 ]]; then
        warn "Not running as root, skipping systemd service creation"
        return 0
    fi

    # Ensure log directory is writable
    mkdir -p /var/log/llmapi
    chown root:root /var/log/llmapi
    chmod 755 /var/log/llmapi
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    log "Installing monitor script to $MONITOR_SCRIPT_PATH"
    if [[ "$0" != "$MONITOR_SCRIPT_PATH" ]]; then
        cp "$0" "$MONITOR_SCRIPT_PATH"
    fi
    chmod +x "$MONITOR_SCRIPT_PATH"

    log "Installing logrotate config at $LOGROTATE_CONFIG"
    install_logrotate_config

    log "Creating systemd service for LLMAPI health monitoring..."

    # The timer starts this unit. It has no [Install] section because it must not also
    # run at boot on its own.
    cat > /etc/systemd/system/llmapi-health-monitor.service << EOF
[Unit]
Description=LLMAPI Health Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $MONITOR_SCRIPT_PATH
User=root
Group=root
EOF

    # Not Persistent: a run missed while the machine was off has no value, and it would
    # fire during boot. The first run waits for the cluster to come back.
    cat > /etc/systemd/system/llmapi-health-monitor.timer << EOF
[Unit]
Description=Run LLMAPI Health Monitor every 5 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min
Persistent=false

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable llmapi-health-monitor.timer
    # Restart, because a timer already running would keep its old schedule.
    systemctl restart llmapi-health-monitor.timer

    success "Created and started LLMAPI health monitor timer (runs every 5 minutes)"
}

# Main execution
main() {
    case "${1:-}" in
        --install-monitor)
            create_monitor_service
            return 0
            ;;
        --report-only)
            REPORT_ONLY=true
            ;;
        "") ;;
        *)
            echo "Usage: $0 [--report-only | --install-monitor]" >&2
            exit 2
            ;;
    esac

    log "Starting LLMAPI health check..."

    check_kubectl

    # Run all checks
    report_stuck_pvcs
    fix_pod_issues
    check_storage_health
    check_llmapi_services

    success "LLMAPI health check completed"
    log "Log saved to: $LOG_FILE"
}

# Run main function with all arguments
main "$@"
