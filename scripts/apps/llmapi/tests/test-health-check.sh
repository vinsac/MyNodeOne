#!/bin/bash
# R8: the health monitor must leave healthy and just-rebooted pods alone, restart only
# Deployments that are really stuck, within a budget, and never force anything.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

FIXTURES="$SANDBOX/fixtures"
export FIXTURES
mkdir -p "$FIXTURES"

NOW=2000000000
export HEALTH_NOW=$NOW
export LOG_FILE="$SANDBOX/health.log"
export HEALTH_UPTIME_FILE="$SANDBOX/uptime"

write_stub kubectl '
echo "kubectl $*" >>"$CALLS"
case "$*" in
    "cluster-info") exit 0 ;;
    "get pods -n llmapi -o json")
        [ ! -e "$FIXTURES/fail-api" ] || exit 1
        cat "$FIXTURES/pods.json" ;;
    "get replicasets -n llmapi -o json") cat "$FIXTURES/rs.json" ;;
    "get nodes -o json") cat "$FIXTURES/nodes.json" ;;
    "get pvc -n llmapi -o json") cat "$FIXTURES/pvc.json" ;;
    "get pods -n llmapi -l "*) echo "{\"items\":[]}" ;;
    "rollout restart "*) echo "restarted" ;;
    *) exit 0 ;;
esac
'

iso() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# Time $1 seconds ago, as an ISO date
ago() {
    iso $((NOW - $1))
}

# Usage: pod <name> <owner kind> <owner> <phase> <ready condition> <ready since, seconds ago>
#            [waiting reason] [container started, seconds ago] [running init container]
pod() {
    local started_json=null
    if [ -n "${8:-}" ]; then
        started_json="\"$(ago "$8")\""
    fi
    jq -n --arg name "$1" --arg kind "$2" --arg owner "$3" --arg phase "$4" --arg ready "$5" \
        --arg since "$(ago "$6")" --arg waiting "${7:-}" --argjson started "$started_json" --arg init "${9:-}" \
        --arg created "$(ago 9000000)" '{
            metadata: ({name: $name, creationTimestamp: $created} + (if $kind == "None" then {} else {ownerReferences: [{kind: $kind, name: $owner}]} end)),
            spec: {nodeName: "node-1"},
            status: ({
                phase: $phase,
                conditions: [{type: "Ready", status: $ready, lastTransitionTime: $since}],
                containerStatuses: [{
                    name: "main",
                    ready: ($ready == "True"),
                    state: (if $waiting != "" then {waiting: {reason: $waiting}}
                            elif $started != null then {running: {startedAt: $started}}
                            else {} end)
                }]
            } + (if $init != "" then {initContainerStatuses: [{name: "init", state: {running: {startedAt: $since}}}]} else {} end))
        }'
}

set_pods() {
    jq -s '{items: .}' >"$FIXTURES/pods.json"
}

# Usage: set_node <Ready status> <since, seconds ago>
set_node() {
    jq -n --arg ready "$1" --arg since "$(ago "$2")" \
        '{items: [{metadata: {name: "node-1"}, status: {conditions: [{type: "Ready", status: $ready, lastTransitionTime: $since}]}}]}' \
        >"$FIXTURES/nodes.json"
}

# Fresh state: long uptime, a node that has been Ready for days, the gateway ReplicaSet
# owned by the gateway Deployment.
reset() {
    rm -f "$FIXTURES/fail-api"
    export HEALTH_STATE_DIR="$SANDBOX/state-$RANDOM$RANDOM"
    echo "864000.00 100.00" >"$HEALTH_UPTIME_FILE"
    echo '{"items":[]}' >"$FIXTURES/pvc.json"
    jq -n '{items: [{metadata: {name: "gateway-abc", ownerReferences: [{kind: "Deployment", name: "gateway"}]}}]}' >"$FIXTURES/rs.json"
    set_node True 864000
    set_pods </dev/null
    : >"$CALLS"
}

run_check() {
    OUTPUT=$(bash "$LLMAPI_DIR/health-check.sh" "$@" 2>&1)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

expect_no_restart() {
    assert_not_contains "$1" "$CALL_LOG" "rollout restart"
}

expect_restart() {
    assert_contains "$1" "$CALL_LOG" "rollout restart deployment/$2 -n llmapi"
}

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running True 500 | set_pods
run_check
expect_no_restart "healthy pod: no restart"
assert_equals "healthy pod: exits 0" "$STATUS" 0

# The failure this replaces: a healthy old pod with any restart age got restarted.
reset
echo "120.00 10.00" >"$HEALTH_UPTIME_FILE"
pod gateway-abc-1 ReplicaSet gateway-abc Running True 60 "" 60 | set_pods
run_check
expect_no_restart "fresh reboot, pod already Ready: no restart"

reset
echo "120.00 10.00" >"$HEALTH_UPTIME_FILE"
pod gateway-abc-1 ReplicaSet gateway-abc Running False 18000 CrashLoopBackOff | set_pods
run_check
expect_no_restart "fresh reboot, stale crash loop status: no restart inside the boot grace period"

# Uptime past the grace period, but the node came back only 2 minutes ago, so the old
# lastTransitionTime says nothing about the pod.
reset
set_node True 120
pod gateway-abc-1 ReplicaSet gateway-abc Running False 18000 "" 100 | set_pods
run_check
expect_no_restart "node just came back, Ready=False from before the outage: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 18000 "" 100 | set_pods
run_check
expect_no_restart "container started 100s ago, old Ready=False: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 600 "" 600 | set_pods
run_check
expect_no_restart "not Ready for 10m on an old pod: age alone doesn't count, no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 "" 3600 | set_pods
run_check
expect_restart "not Ready for 60m: restart" gateway

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
run_check
expect_restart "CrashLoopBackOff for 60m: restart" gateway

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 300 CrashLoopBackOff | set_pods
run_check
expect_no_restart "CrashLoopBackOff for 5m: below threshold, no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
set_node False 3000
run_check
expect_no_restart "node not Ready: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
run_check --report-only
expect_no_restart "--report-only: no restart"
assert_contains "--report-only: says what it would do" "$OUTPUT" "Would restart deployment gateway"

for case_args in \
    "statefulset|vllm-0 StatefulSet vllm Running False 3600 CrashLoopBackOff" \
    "bare pod|loner None - Running False 3600 CrashLoopBackOff" \
    "job|job-1 Job job Running False 3600 CrashLoopBackOff"; do
    label="${case_args%%|*}"
    # shellcheck disable=SC2086
    set -- ${case_args#*|}
    reset
    pod "$@" | set_pods
    run_check
    expect_no_restart "$label crash looping: no restart"
    assert_not_contains "$label crash looping: nothing deleted" "$CALL_LOG" "delete"
    assert_contains "$label crash looping: reported" "$OUTPUT" "doesn't restart"
done

reset
pod gateway-abc-1 ReplicaSet gateway-abc Pending False 3600 | set_pods
run_check
expect_no_restart "Pending: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Failed False 3600 | set_pods
run_check
expect_no_restart "evicted (Failed) pod: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Pending False 3600 ImagePullBackOff | set_pods
run_check
expect_no_restart "ImagePullBackOff: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Pending False 90000 "" "" yes | set_pods
run_check
expect_no_restart "init container still running for 25h (model download): no restart"

# Restart budget and backoff. Each step reuses the state from the one before.
reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
STATE="$HEALTH_STATE_DIR"
run_check
expect_restart "budget: first restart allowed" gateway
assert_equals "budget: restart recorded" "$(wc -l <"$STATE/restarts-gateway")" 1

: >"$CALLS"
run_check
expect_no_restart "backoff: an immediate second restart is refused"

: >"$CALLS"
export HEALTH_NOW=$((NOW + 1700))
run_check
expect_no_restart "backoff: refused at 28m"

: >"$CALLS"
export HEALTH_NOW=$((NOW + 1900))
run_check
expect_restart "backoff: allowed after 30m" gateway

: >"$CALLS"
export HEALTH_NOW=$((NOW + 1900 + 1900))
run_check
expect_no_restart "backoff doubles: refused 30m after the second restart"

: >"$CALLS"
export HEALTH_NOW=$((NOW + 1900 + 3700))
run_check
expect_restart "backoff doubles: allowed 60m after the second restart" gateway
assert_equals "budget: three restarts recorded" "$(wc -l <"$STATE/restarts-gateway")" 3

: >"$CALLS"
export HEALTH_NOW=$((NOW + 1900 + 3700 + 40000))
run_check
expect_no_restart "budget: a fourth restart inside the window is refused"
assert_contains "budget: refusal is reported" "$OUTPUT" "restart budget"

: >"$CALLS"
export HEALTH_NOW=$((NOW + 90000))
run_check
expect_restart "budget: restarts allowed again once old ones age out of the window" gateway
export HEALTH_NOW=$NOW

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
touch "$SANDBOX/not-a-dir"
export HEALTH_STATE_DIR="$SANDBOX/not-a-dir/state"
run_check
expect_no_restart "state directory not writable: no restart"

reset
pod gateway-abc-1 ReplicaSet gateway-abc Running False 3600 CrashLoopBackOff | set_pods
touch "$FIXTURES/fail-api"
run_check
expect_no_restart "API failure reading pods: no action"
assert_equals "API failure reading pods: still exits 0" "$STATUS" 0

reset
echo '{"items":[{"metadata":{"name":"data-1","deletionTimestamp":"2030-01-01T00:00:00Z","finalizers":["kubernetes.io/pvc-protection"]}}]}' >"$FIXTURES/pvc.json"
run_check
assert_contains "PVC stuck deleting: reported" "$OUTPUT" "data-1"
assert_not_contains "PVC stuck deleting: not patched" "$CALL_LOG" "patch"
assert_not_contains "PVC stuck deleting: not deleted" "$CALL_LOG" "delete"

# Static checks on what the script could ever do.
CODE=$(grep -v '^[[:space:]]*#' "$LLMAPI_DIR/health-check.sh")
assert_not_contains "script: no finalizer edits" "$CODE" "finalizers"
assert_not_contains "script: no force delete" "$CODE" "--force"
assert_not_contains "script: no kubectl delete" "$CODE" "kubectl delete"
assert_not_contains "script: no kubectl patch" "$CODE" "kubectl patch"
assert_not_contains "script: no sed" "$CODE" "| sed"
assert_contains "script: logrotate rule covers the log directory" "$CODE" "/var/log/llmapi/*.log"
assert_contains "script: first timer run waits after boot" "$CODE" "OnBootSec=15min"
assert_contains "script: missed runs don't fire at boot" "$CODE" "Persistent=false"

SERVICE_UNIT=$(awk '/llmapi-health-monitor.service << EOF/{p=1;next} p&&/^EOF$/{exit} p' "$LLMAPI_DIR/health-check.sh")
assert_not_contains "service unit: doesn't run at boot on its own" "$SERVICE_UNIT" "[Install]"

finish
