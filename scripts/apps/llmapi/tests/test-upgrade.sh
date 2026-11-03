#!/bin/bash
# upgrade-llmapi.sh and deploy-gateway.sh: order, refusals, every way of stopping, the
# backup, and rollback. kubectl is a stub that keeps enough state to re-run after a failure.
# Works on a copy of this directory so the guard on main.py can be tested both ways.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

APP="$SANDBOX/scripts/apps/llmapi"
mkdir -p "$APP" "$SANDBOX/scripts/lib"
: >"$SANDBOX/scripts/lib/project-root.sh"
for item in lib manifests model-downloader gateway deploy-gateway.sh upgrade-llmapi.sh; do
    cp -r "$LLMAPI_DIR/$item" "$APP/"
done
cat >"$APP/gateway/main.py" <<'EOF'
REDIS_PASSWORD = "read from env by the real gateway"
EOF

export STATE="$SANDBOX/state"
export LLMAPI_UPGRADE_BACKUP_DIR="$SANDBOX/backups"
export UPGRADE_POLL_SECONDS=0
mkdir -p "$STATE"

# Touch $STATE/fail-<word> to make the call matching that word fail.
write_stub kubectl '
echo "kubectl $*" >>"$CALLS"
fail_if() { [ ! -e "$STATE/fail-$1" ] || { echo "stub: $1 failed" >&2; exit 1; }; }
case "$*" in
    *"--dry-run=server"*) cat >/dev/null 2>&1; fail_if dry-run ;;
    "get namespace "*) [ ! -e "$STATE/no-namespace" ] ;;
    "get secret llmapi-db "*"go-template"*) [ -e "$STATE/no-db-key" ] || printf yes ;;
    "get secret llmapi-db "*) [ ! -e "$STATE/no-db-secret" ] ;;
    "get secret llmapi-redis-auth "*) [ -e "$STATE/redis-secret" ] ;;
    "create -n llmapi -f -") cat >/dev/null; touch "$STATE/redis-secret" ;;
    "get deployment gateway -n llmapi -o jsonpath={.metadata.generation}") cat "$STATE/generation" ;;
    "get deployment gateway -n llmapi -o jsonpath={.spec.replicas}"*) cat "$STATE/replicas" ;;
    "get deployment gateway -n llmapi --request-timeout=10s -o jsonpath={.spec.replicas}"*) cat "$STATE/replicas" ;;
    "get deployment gateway -n llmapi --request-timeout=10s -o jsonpath={.status.readyReplicas}"*)
        if [ -e "$STATE/fail-gateway-rollout" ] || [ -e "$STATE/nothing-ready" ]; then echo 0; else cat "$STATE/replicas"; fi ;;
    "get deployment gateway -n llmapi --ignore-not-found"*) cat "$STATE/gateway-env" ;;
    "get deployment gateway -n llmapi") [ ! -e "$STATE/no-gateway" ] ;;
    "get deployment redis -n llmapi"*) cat "$STATE/redis-env" ;;
    "get deployment/"*" -n llmapi --ignore-not-found -o json" | "get configmap/"*" -n llmapi --ignore-not-found -o json" | \
    "get serviceaccount/"*" -n llmapi --ignore-not-found -o json" | "get role/"*" -n llmapi --ignore-not-found -o json" | \
    "get rolebinding/"*" -n llmapi --ignore-not-found -o json" | "get clusterrole/"*" -n llmapi --ignore-not-found -o json" | \
    "get clusterrolebinding/"*" -n llmapi --ignore-not-found -o json")
        object="$2"
        if [ "$object" = configmap/gateway-static ] && [ ! -e "$STATE/static-exists" ]; then exit 0; fi
        printf "{\"kind\":\"Thing\",\"metadata\":{\"name\":\"%s\",\"uid\":\"u1\",\"resourceVersion\":\"7\",\"managedFields\":[1]},\"spec\":{},\"status\":{\"a\":1}}" "$object" ;;
    "get networkpolicy -n llmapi -o json")
        if [ -e "$STATE/policies-exist" ]; then
            printf "{\"kind\":\"List\",\"items\":[{\"metadata\":{\"name\":\"p\",\"uid\":\"u\"}}]}"
        else
            printf "{\"kind\":\"List\",\"items\":[]}"
        fi ;;
    "get Deployment "*"--ignore-not-found"*) echo present ;;
    "get Deployment gateway "*"spec.replicas"*) cat "$STATE/replicas" ;;
    "get Deployment "*"spec.replicas"*) echo 1 ;;
    "get StatefulSet "*"spec.replicas"*) echo 2 ;;
    "get ConfigMap "*) echo configmap/existing ;;
    "get Secret "*) echo secret/existing ;;
    "get configmap gateway-code "*) exit 0 ;;
    "get configmap "*) exit 1 ;;
    "get deployment "*) exit 0 ;;
    "get pod llmapi-upgrade-preflight -n llmapi --request-timeout=10s -o jsonpath={.status.phase}")
        [ ! -e "$STATE/slow-api" ] || sleep 1
        if [ -e "$STATE/preflight-fails" ]; then echo Failed
        elif [ -e "$STATE/preflight-hangs" ] || [ -e "$STATE/preflight-no-image" ]; then echo Pending
        else echo Succeeded; fi ;;
    "get pod llmapi-upgrade-preflight "*"state.waiting.reason"*)
        [ ! -e "$STATE/preflight-no-image" ] || echo ImagePullBackOff ;;
    "logs llmapi-upgrade-preflight "*) echo "ERROR: Could not find a version that satisfies the requirement" ;;
    "create configmap llmapi-upgrade-preflight "*) ;;
    "create configmap gateway-code "*) fail_if ship-code; echo "apiVersion: v1"; echo "kind: ConfigMap" ;;
    "create configmap "*) echo "apiVersion: v1"; echo "kind: ConfigMap" ;;
    "exec -n llmapi deploy/llmapi-postgres -- pg_dump "*) fail_if pg-dump; printf "FAKE-DUMP" ;;
    "exec -i -n llmapi deploy/llmapi-postgres -- pg_restore -l") cat >/dev/null; fail_if pg-list
        [ -e "$STATE/dump-without-keys" ] || echo "1234; 0 16385 TABLE DATA public api_keys llmapi" ;;
    "exec -i -n llmapi deploy/llmapi-postgres -- pg_restore -f /dev/null") cat >/dev/null; fail_if pg-truncated ;;
    "exec -i -n llmapi deploy/llmapi-postgres -- pg_restore -U "*) cat >"$STATE/restored-dump"; fail_if pg-restore ;;
    "exec -n llmapi deploy/llmapi-postgres -- psql "*) cat "$STATE/plaintext" ;;
    "exec -n llmapi deploy/redis -- redis-cli ping") echo PONG ;;
    "scale deployment/gateway -n llmapi --replicas="*)
        fail_if scale
        args="$*"
        echo "${args##*=}" >"$STATE/replicas" ;;
    "scale deployment/redis "*) fail_if redis-scale ;;
    "wait --for=delete pod -l app=llmapi-gateway "*) fail_if wait-gateway ;;
    "rollout status deployment/redis "*) fail_if redis-rollout ;;
    "rollout status deployment/gateway "*)
        # With 0 replicas wanted, a real rollout has nothing to wait for.
        [ "$(cat "$STATE/replicas")" = 0 ] || fail_if gateway-rollout ;;
    "apply -f - "* | "apply -f -")
        cat >"$STATE/last-apply"
        if grep -q "name: gateway$" "$STATE/last-apply"; then
            echo "gateway REDIS_PASSWORD" >"$STATE/gateway-env"
            [ ! -e "$STATE/template-changes" ] || echo 8 >"$STATE/generation"
        fi
        if grep -q "name: redis$" "$STATE/last-apply"; then
            echo "REDISCLI_AUTH" >"$STATE/redis-env"
        fi ;;
    "apply -f "*"networkpolicy.yaml") fail_if network-policy ;;
    "create -f -")
        cat >"$STATE/last-create"
        cat "$STATE/last-create" >>"$STATE/replaced"
        if grep -q "^kind: Pod" "$STATE/last-create"; then cp "$STATE/last-create" "$STATE/preflight-pod"; fi ;;
    "replace -f -") cat >>"$STATE/replaced" ;;
esac
'

reset() {
    rm -rf "${STATE:?}"/* "$LLMAPI_UPGRADE_BACKUP_DIR"
    echo 7 >"$STATE/generation"
    echo 2 >"$STATE/replicas"
    echo 3 >"$STATE/plaintext"
    echo "gateway SOME_OTHER_VAR" >"$STATE/gateway-env"
    echo "NOTHING_RELEVANT" >"$STATE/redis-env"
    : >"$CALLS"
    write_stub systemctl 'exit 3'
}

run_upgrade() {
    OUTPUT=$(bash "$APP/upgrade-llmapi.sh" "$@" 2>&1 </dev/null)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

# Usage: line_of <text>. The line in the call log where it first appears.
line_of() {
    grep -nF -- "$1" <<<"$CALL_LOG" | head -n1 | cut -d: -f1
}

assert_before() {
    local first second
    first=$(line_of "$2")
    second=$(line_of "$3")
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
        pass "$1"
    else
        fail "$1" "$2 at line ${first:-none}, $3 at line ${second:-none}
$CALL_LOG"
    fi
}

# Usage: assert_nothing_stopped <name>. Refused before anything stopped, and said so.
assert_nothing_stopped() {
    assert_not_contains "$1: exits non-zero" "$STATUS" "0"
    assert_not_contains "$1: gateway not scaled" "$CALL_LOG" "scale deployment/gateway"
    assert_not_contains "$1: Redis untouched" "$CALL_LOG" "rollout status deployment/redis"
    assert_not_contains "$1: Redis secret not created" "$CALL_LOG" "create -n llmapi -f -"
    assert_contains "$1: says nothing changed" "$OUTPUT" "Nothing changed"
    assert_equals "$1: no marker" "$(ls "$LLMAPI_UPGRADE_BACKUP_DIR/in-progress" 2>/dev/null)" ""
}

run_dir() {
    find "$LLMAPI_UPGRADE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1
}

## The full upgrade, from a gateway that can't send a Redis password

reset
run_upgrade
assert_equals "upgrade: succeeds" "$STATUS" 0
assert_contains "upgrade: outage announced" "$OUTPUT" "stops the API for about"
assert_not_contains "upgrade: nobody is told requests just fail" "$OUTPUT" "Requests that need Redis fail"
assert_before "order: manifests dry-run before the test pod" "--dry-run=server" "create configmap llmapi-upgrade-preflight"
assert_before "order: test pod before the dump" "create configmap llmapi-upgrade-preflight" "pg_dump"
assert_before "order: dump verified, table of contents" "pg_dump" "pg_restore -l"
assert_before "order: dump verified, every byte" "pg_restore -l" "pg_restore -f /dev/null"
assert_before "order: dump before anything stops" "pg_restore -f /dev/null" "scale deployment/gateway -n llmapi --replicas=0"
assert_before "order: secret before the gateway stops" "create -n llmapi -f -" "scale deployment/gateway -n llmapi --replicas=0"
assert_before "order: waits for the old pods to be gone" "scale deployment/gateway -n llmapi --replicas=0" "wait --for=delete pod -l app=llmapi-gateway"
assert_before "order: old gateway gone before Redis changes" "wait --for=delete pod -l app=llmapi-gateway" "rollout status deployment/redis"
assert_before "order: RBAC after the old gateway is gone" "wait --for=delete pod -l app=llmapi-gateway" "apply -f $APP/manifests/gateway-rbac.yaml"
assert_before "order: new code only after the old gateway is gone" "wait --for=delete pod -l app=llmapi-gateway" "create configmap gateway-code"
assert_before "order: Redis up before the new gateway" "rollout status deployment/redis" "create configmap gateway-code"
assert_before "order: new gateway shipped before it's scaled up" "create configmap gateway-code" "scale deployment/gateway -n llmapi --replicas=2"
assert_contains "order: waits for the scaled-up gateway" "$(sed -n '/replicas=2/,$p' <<<"$CALL_LOG")" "rollout status deployment/gateway"
assert_before "order: the gateway is up before NetworkPolicy" "rollout status deployment/gateway -n llmapi --timeout=300s" "apply -f $APP/manifests/networkpolicy.yaml"
assert_equals "upgrade: comes back with the replica count it had" "$(cat "$STATE/replicas")" 2
assert_contains "upgrade: Service gets its ServiceMonitor label" "$CALL_LOG" "label service llmapi -n llmapi app=llmapi-gateway"
assert_not_contains "upgrade: backends untouched by default" "$CALL_LOG" "model-downloader-lock"
assert_not_contains "upgrade: Postgres secret not recreated" "$CALL_LOG" "llmapi-db --"
assert_contains "upgrade: NetworkPolicy back-out printed" "$OUTPUT" "kubectl delete networkpolicy"
assert_not_contains "upgrade: never rollout undo" "$CALL_LOG" "rollout undo"
ALLOWED_DELETES='delete configmap gateway-static|delete pod llmapi-upgrade-preflight|delete configmap llmapi-upgrade-preflight'
assert_not_contains "upgrade: nothing else deleted" "$(grep -vE "$ALLOWED_DELETES" <<<"$CALL_LOG")" " delete "

# The backup
DIR=$(run_dir)
assert_equals "backup: directory private" "$(stat -c %a "$DIR")" 700
assert_equals "backup: dump private" "$(stat -c %a "$DIR/postgres.dump")" 600
assert_equals "backup: dump holds what pg_dump wrote" "$(cat "$DIR/postgres.dump")" "FAKE-DUMP"
assert_equals "backup: checksum matches" "$(cd "$DIR" && sha256sum --quiet -c postgres.dump.sha256 && echo good)" good
assert_equals "backup: no partial file left" "$(find "$DIR" -name "*partial*" | wc -l)" 0
assert_equals "backup: objects private" "$(stat -c %a "$DIR/objects/deployment-gateway.json")" 600
assert_equals "backup: prior gateway Deployment saved, without server fields" "$(jq -c '.metadata' "$DIR/objects/deployment-gateway.json")" '{"name":"deployment/gateway"}'
assert_contains "backup: prior code saved" "$(cat "$DIR/objects/configmap-gateway-code.json")" "configmap/gateway-code"
assert_equals "backup: an absent ConfigMap is recorded as absent" "$(find "$DIR/objects" -name configmap-gateway-static.absent | wc -l)" 1
assert_equals "backup: replica count saved" "$(cat "$DIR/gateway-replicas")" 2
assert_contains "backup: through kubectl exec, so NetworkPolicy doesn't matter" "$CALL_LOG" "exec -n llmapi deploy/llmapi-postgres -- pg_dump -U llmapi -d llmapi -Fc"
assert_contains "backup: warns the dump holds raw keys" "$OUTPUT" "holds raw API keys"
assert_contains "backup: warns rollback means this dump" "$OUTPUT" "Going back means restoring this dump"
assert_contains "backup: says how to roll back" "$OUTPUT" "--rollback $DIR"
assert_equals "upgrade finished: marker gone" "$(ls "$LLMAPI_UPGRADE_BACKUP_DIR/in-progress" 2>/dev/null)" ""

# The throwaway pod
POD=$(cat "$STATE/preflight-pod")
assert_not_contains "test pod: Service can't select it" "$POD" "app: llmapi-gateway"
assert_contains "test pod: doesn't read gateway-code" "$POD" "name: llmapi-upgrade-preflight"
assert_not_contains "test pod: doesn't mount gateway-code" "$POD" "name: gateway-code"
assert_contains "test pod: same pip flags as the gateway" "$POD" "--require-hashes --only-binary=:all:"
assert_contains "test pod: those are the gateway's flags" "$(cat "$APP/manifests/gateway-deployment.yaml")" "--require-hashes --only-binary=:all:"
assert_contains "test pod: uses the gateway's image" "$POD" "image: $(sed -n 's/^ *image: *//p' "$APP/manifests/gateway-deployment.yaml" | head -n1)"
assert_contains "test pod: pulls Redis's image" "$POD" "image: $(sed -n 's/^ *image: *//p' "$APP/manifests/redis.yaml" | head -n1)"
assert_contains "test pod: imports main.py" "$POD" "import main"
assert_contains "test pod: removed afterwards" "$CALL_LOG" "delete pod llmapi-upgrade-preflight"
assert_not_contains "test pod: no API token" "$POD" "serviceAccountName"

## Already upgraded: nothing has to stop

reset
touch "$STATE/redis-secret"
echo "gateway REDIS_PASSWORD" >"$STATE/gateway-env"
echo "REDISCLI_AUTH" >"$STATE/redis-env"
run_upgrade
assert_equals "second upgrade: succeeds" "$STATUS" 0
assert_not_contains "second upgrade: Redis secret not recreated" "$CALL_LOG" "create -n llmapi -f -"
assert_not_contains "second upgrade: gateway not stopped" "$CALL_LOG" "scale deployment/gateway"
assert_not_contains "second upgrade: no outage announced" "$OUTPUT" "stops the API for about"

# Half-upgraded by hand or by the old script: new Redis under an old gateway hangs.
reset
touch "$STATE/redis-secret"
echo "REDISCLI_AUTH" >"$STATE/redis-env"
run_upgrade
assert_equals "old gateway, new Redis: succeeds" "$STATUS" 0
assert_contains "old gateway, new Redis: gateway stopped first" "$CALL_LOG" "scale deployment/gateway -n llmapi --replicas=0"

reset
echo "gateway REDIS_PASSWORD" >"$STATE/gateway-env"
echo 0 >"$STATE/replicas"
echo "REDISCLI_AUTH" >"$STATE/redis-env"
run_upgrade
assert_equals "new gateway at 0, no unfinished run: succeeds" "$STATUS" 0
assert_contains "new gateway at 0, no unfinished run: brought up" "$CALL_LOG" "scale deployment/gateway -n llmapi --replicas=1"

## Flags

reset
run_upgrade --skip-network-policy
assert_not_contains "--skip-network-policy: not applied" "$CALL_LOG" "networkpolicy.yaml"

reset
run_upgrade --with-backends
assert_contains "--with-backends: downloader lockfile shipped" "$CALL_LOG" "create configmap model-downloader-lock"
assert_contains "--with-backends: lockfile shipped before vLLM needs it" "$(sed -n '/create configmap model-downloader-lock/,$p' <<<"$CALL_LOG")" "get StatefulSet vllm"

reset
run_upgrade --skip-backup
assert_equals "--skip-backup: succeeds" "$STATUS" 0
assert_not_contains "--skip-backup: no dump" "$CALL_LOG" "pg_dump"
assert_contains "--skip-backup: says there's no way back" "$OUTPUT" "no way back"

reset
run_upgrade --skip-deps-check
assert_equals "--skip-deps-check: succeeds" "$STATUS" 0
assert_not_contains "--skip-deps-check: no test pod" "$CALL_LOG" "llmapi-upgrade-preflight"

reset
run_upgrade --nonsense
assert_equals "unknown flag: refused" "$STATUS" 2
assert_equals "unknown flag: no cluster calls" "$CALL_LOG" ""

reset
run_upgrade --rollback
assert_equals "--rollback without a path: refused" "$STATUS" 2

## Refusals before any change

reset
touch "$STATE/no-namespace"
run_upgrade
assert_equals "no namespace: refused" "$STATUS" 1
assert_nothing_stopped "no namespace"
assert_not_contains "no namespace: nothing applied" "$CALL_LOG" "apply"

reset
touch "$STATE/no-db-secret"
run_upgrade
assert_equals "no database secret: refused" "$STATUS" 1
assert_nothing_stopped "no database secret"

reset
touch "$STATE/no-db-key"
run_upgrade
assert_equals "database secret without the key: refused" "$STATUS" 1
assert_nothing_stopped "database secret without the key"

reset
touch "$STATE/no-gateway"
run_upgrade
assert_equals "no gateway Deployment: refused" "$STATUS" 1
assert_nothing_stopped "no gateway Deployment"

# Taking Redis to a password with a gateway that can't send one would be an outage.
reset
echo 'no password support here' >"$APP/gateway/main.py"
run_upgrade
assert_equals "gateway without REDIS_PASSWORD: refused" "$STATUS" 1
assert_nothing_stopped "gateway without REDIS_PASSWORD"
echo 'REDIS_PASSWORD' >"$APP/gateway/main.py"

## The health monitor

reset
write_stub systemctl 'echo "systemctl $*" >>"$CALLS"; [ "$1" = is-active ]'
run_upgrade
assert_equals "monitor active: refused" "$STATUS" 1
assert_nothing_stopped "monitor active"
assert_contains "monitor active: says how to stop it" "$OUTPUT" "sudo systemctl stop llmapi-health-monitor.timer"
assert_contains "monitor active: names the override" "$OUTPUT" "--allow-health-monitor"
assert_not_contains "monitor active: this script doesn't stop it" "$CALL_LOG" "systemctl stop"

reset
write_stub systemctl '[ "$1" = is-active ]'
run_upgrade --allow-health-monitor
assert_equals "monitor active, overridden: succeeds" "$STATUS" 0
assert_contains "monitor active, overridden: warns" "$OUTPUT" "WARNING: llmapi-health-monitor.timer is active"

## Preflight failures

reset
touch "$STATE/fail-dry-run"
run_upgrade
assert_equals "manifest rejected by the API server: stops" "$STATUS" 1
assert_nothing_stopped "manifest rejected by the API server"
assert_not_contains "manifest rejected by the API server: no dump" "$CALL_LOG" "pg_dump"

reset
touch "$STATE/preflight-fails"
run_upgrade
assert_equals "pip install fails in the test pod: stops" "$STATUS" 1
assert_nothing_stopped "pip install fails in the test pod"
assert_contains "pip install fails in the test pod: shows its log" "$OUTPUT" "Could not find a version"
assert_contains "pip install fails in the test pod: pod removed" "$CALL_LOG" "delete pod llmapi-upgrade-preflight"
assert_not_contains "pip install fails in the test pod: no dump" "$CALL_LOG" "pg_dump"

reset
touch "$STATE/preflight-no-image"
run_upgrade
assert_equals "image can't be pulled: stops" "$STATUS" 1
assert_nothing_stopped "image can't be pulled"
assert_contains "image can't be pulled: says so" "$OUTPUT" "can't pull an image"

reset
# The limit is real time. A slow API server mustn't stretch it, and with no sleep to count
# only real time can end this.
reset
touch "$STATE/preflight-hangs" "$STATE/slow-api"
PREFLIGHT_TIMEOUT=2 timeout 30 bash "$APP/upgrade-llmapi.sh" >/dev/null 2>&1 </dev/null
assert_equals "slow API server: the preflight limit still ends it" "$?" 1
rm -f "$STATE/slow-api"

reset
touch "$STATE/preflight-hangs"
OUTPUT=$(PREFLIGHT_TIMEOUT=0 bash "$APP/upgrade-llmapi.sh" 2>&1 </dev/null)
STATUS=$?
CALL_LOG=$(cat "$CALLS")
assert_equals "test pod never finishes: stops" "$STATUS" 1
assert_nothing_stopped "test pod never finishes"
assert_contains "test pod never finishes: pod removed" "$CALL_LOG" "delete pod llmapi-upgrade-preflight"

## Backup failures

for failure in pg-dump pg-list pg-truncated; do
    reset
    touch "$STATE/fail-$failure"
    run_upgrade
    assert_equals "backup, $failure fails: stops" "$STATUS" 1
    assert_nothing_stopped "backup, $failure fails"
    assert_contains "backup, $failure fails: names the flag" "$OUTPUT" "--skip-backup"
    assert_equals "backup, $failure fails: leaves no raw keys behind" "$(run_dir)" ""
done

reset
touch "$STATE/dump-without-keys"
run_upgrade
assert_equals "dump has no api_keys: stops" "$STATUS" 1
assert_nothing_stopped "dump has no api_keys"

## Failures after the cut

reset
touch "$STATE/fail-scale"
run_upgrade
assert_equals "can't stop the gateway: stops" "$STATUS" 1
assert_not_contains "can't stop the gateway: Redis untouched" "$CALL_LOG" "rollout status deployment/redis"
assert_contains "can't stop the gateway: reports" "$OUTPUT" "upgrade STOPPED during: Stopping the old gateway"

reset
touch "$STATE/fail-wait-gateway"
run_upgrade
assert_equals "old pods don't go away: stops" "$STATUS" 1
assert_not_contains "old pods don't go away: Redis untouched" "$CALL_LOG" "rollout status deployment/redis"
assert_contains "old pods don't go away: API reported down" "$OUTPUT" "The public API is DOWN"
assert_contains "old pods don't go away: says how to go back" "$OUTPUT" "--rollback"

reset
touch "$STATE/fail-redis-rollout"
run_upgrade
assert_equals "Redis doesn't come back: stops" "$STATUS" 1
assert_not_contains "Redis doesn't come back: new code not shipped" "$CALL_LOG" "create configmap gateway-code"
assert_contains "Redis doesn't come back: API reported down" "$OUTPUT" "The public API is DOWN"
assert_contains "Redis doesn't come back: reports Redis state" "$OUTPUT" "requires a password: yes"
assert_contains "Redis doesn't come back: warns off rollout undo" "$OUTPUT" "Don't use 'kubectl rollout undo'"

reset
touch "$STATE/fail-ship-code"
run_upgrade
assert_equals "gateway code can't ship: stops" "$STATUS" 1
assert_contains "gateway code can't ship: API reported down" "$OUTPUT" "The public API is DOWN"

reset
touch "$STATE/fail-gateway-rollout"
run_upgrade
assert_equals "new gateway never ready: stops" "$STATUS" 1
assert_contains "new gateway never ready: API reported down" "$OUTPUT" "The public API is DOWN"
assert_contains "new gateway never ready: reports replicas" "$OUTPUT" "2 replicas wanted, 0 ready"
assert_contains "new gateway never ready: reports keys" "$OUTPUT" "API keys not yet hashed: 3"
assert_contains "new gateway never ready: says to re-run" "$OUTPUT" "carries on with the same backup"
assert_contains "new gateway never ready: gives the rollback command" "$OUTPUT" "--rollback $(run_dir)"
assert_contains "new gateway never ready: points at the install log" "$OUTPUT" "logs deployment/gateway -c install-deps"
assert_equals "new gateway never ready: marker stays" "$(cat "$LLMAPI_UPGRADE_BACKUP_DIR/in-progress")" "$(run_dir)"

# Re-run after that: same dump, same replica count, though it's at 2 by now.
FIRST_DIR=$(run_dir)
rm "$STATE/fail-gateway-rollout"
: >"$CALLS"
echo 0 >"$STATE/replicas"
run_upgrade
assert_equals "re-run after a failure: succeeds" "$STATUS" 0
assert_not_contains "re-run after a failure: the pre-migration dump isn't replaced" "$CALL_LOG" "pg_dump"
assert_contains "re-run after a failure: says so" "$OUTPUT" "Carrying on with the unfinished upgrade in $FIRST_DIR"
assert_contains "re-run after a failure: original replica count" "$CALL_LOG" "scale deployment/gateway -n llmapi --replicas=2"
assert_equals "re-run after a failure: one backup directory" "$(find "$LLMAPI_UPGRADE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" 1
assert_equals "re-run after a failure: marker gone" "$(ls "$LLMAPI_UPGRADE_BACKUP_DIR/in-progress" 2>/dev/null)" ""

# Re-run that fails too. It has no cut of its own, but nothing is ready, so the API is down.
reset
touch "$STATE/fail-gateway-rollout"
run_upgrade
FIRST_DIR=$(run_dir)
: >"$CALLS"
run_upgrade
assert_equals "re-run still failing: stops" "$STATUS" 1
assert_contains "re-run still failing: says it's carrying on" "$OUTPUT" "An earlier run of this upgrade didn't finish"
assert_not_contains "re-run still failing: doesn't promise no stop" "$OUTPUT" "rolls"
assert_not_contains "re-run still failing: no second cut" "$CALL_LOG" "--replicas=0"
assert_contains "re-run still failing: API reported down, though this run cut nothing" "$OUTPUT" "The public API is DOWN"
assert_contains "re-run still failing: same backup offered" "$OUTPUT" "--rollback $FIRST_DIR"

# Re-run with the first attempt stopped before Redis: the cut happens again.
reset
touch "$STATE/fail-wait-gateway"
run_upgrade
rm "$STATE/fail-wait-gateway"
: >"$CALLS"
run_upgrade
assert_equals "re-run, stopped before Redis: succeeds" "$STATUS" 0
assert_before "re-run, stopped before Redis: still waits before Redis" "wait --for=delete pod -l app=llmapi-gateway" "rollout status deployment/redis"
assert_equals "re-run, stopped before Redis: replicas restored" "$(cat "$STATE/replicas")" 2

# Failing after the gateway is up isn't an outage.
reset
touch "$STATE/fail-network-policy"
run_upgrade
assert_equals "NetworkPolicy rejected: stops" "$STATUS" 1
assert_contains "NetworkPolicy rejected: API not reported down" "$OUTPUT" "The public API was not stopped by this failure"
assert_contains "NetworkPolicy rejected: re-run is safe" "$OUTPUT" "carries on with the same backup"
: >"$CALLS"
rm "$STATE/fail-network-policy"
run_upgrade
assert_not_contains "NetworkPolicy rejected, re-run: first dump kept" "$CALL_LOG" "pg_dump"

reset
mkdir -p "$LLMAPI_UPGRADE_BACKUP_DIR"
echo "$SANDBOX/gone" >"$LLMAPI_UPGRADE_BACKUP_DIR/in-progress"
run_upgrade
assert_equals "marker to a directory that's gone: stops" "$STATUS" 1
assert_not_contains "marker to a directory that's gone: gateway not scaled" "$CALL_LOG" "scale deployment/gateway"
assert_contains "marker to a directory that's gone: says what to do" "$OUTPUT" "delete $LLMAPI_UPGRADE_BACKUP_DIR/in-progress"

reset
mkdir -p "$LLMAPI_UPGRADE_BACKUP_DIR/older"
echo 2 >"$LLMAPI_UPGRADE_BACKUP_DIR/older/gateway-replicas"
echo "$LLMAPI_UPGRADE_BACKUP_DIR/older" >"$LLMAPI_UPGRADE_BACKUP_DIR/in-progress"
run_upgrade
assert_equals "unfinished run without a dump: stops" "$STATUS" 1
assert_contains "unfinished run without a dump: names the flag" "$OUTPUT" "--skip-backup"
run_upgrade --skip-backup
assert_equals "unfinished run without a dump, --skip-backup: carries on" "$STATUS" 0

## Rollback

# A backup directory as an upgrade leaves it, and the cluster as it leaves it.
upgraded_cluster() {
    reset
    touch "$STATE/policies-exist" "$STATE/static-exists"
    run_upgrade --skip-deps-check
    BACKUP=$(run_dir)
    : >"$CALLS"
    rm -f "$STATE/policies-exist" "$STATE/static-exists"
}

run_rollback() {
    run_upgrade --rollback "$@"
}

upgraded_cluster
run_rollback "$BACKUP" --yes
assert_equals "rollback: succeeds" "$STATUS" 0
assert_before "rollback order: dump verified first" "pg_restore -f /dev/null" "scale deployment/gateway -n llmapi --replicas=0"
assert_before "rollback order: gateway gone before the restore" "wait --for=delete pod -l app=llmapi-gateway" "pg_restore -U llmapi"
assert_before "rollback order: database before Redis" "pg_restore -U llmapi" "scale deployment/redis -n llmapi --replicas=0"
assert_before "rollback order: Redis stopped for its volume" "wait --for=delete pod -l app=redis" "rollout status deployment/redis"
assert_before "rollback order: Redis before the old gateway" "rollout status deployment/redis" "scale deployment/gateway -n llmapi --replicas=2"
assert_before "rollback order: gateway waited for" "scale deployment/gateway -n llmapi --replicas=2" "rollout status deployment/gateway"
assert_before "rollback order: NetworkPolicy last" "rollout status deployment/gateway" "delete networkpolicy -n llmapi --all"
assert_contains "rollback: one transaction" "$CALL_LOG" "--clean --if-exists --no-owner --no-privileges --single-transaction --exit-on-error"
assert_equals "rollback: restores the saved dump" "$(cat "$STATE/restored-dump")" "FAKE-DUMP"
assert_not_contains "rollback: never rollout undo" "$CALL_LOG" "rollout undo"
assert_contains "rollback: prior gateway Deployment back" "$(cat "$STATE/replaced")" "deployment/gateway"
assert_contains "rollback: prior Redis Deployment back" "$(cat "$STATE/replaced")" "deployment/redis"
assert_contains "rollback: prior code back" "$(cat "$STATE/replaced")" "configmap/gateway-code"
assert_contains "rollback: prior static files back" "$(cat "$STATE/replaced")" "configmap/gateway-static"
assert_contains "rollback: prior RBAC back" "$(cat "$STATE/replaced")" "clusterrole/gateway-node-reader"
assert_contains "rollback: prior NetworkPolicy back" "$CALL_LOG" "apply -f $BACKUP/objects/networkpolicies.json"
assert_equals "rollback: replica count back" "$(cat "$STATE/replicas")" 2
assert_contains "rollback: warns what's lost" "$OUTPUT" "are lost"
assert_contains "rollback: warns the dump is still there" "$OUTPUT" "still holds raw API keys"
assert_equals "rollback: marker gone" "$(ls "$LLMAPI_UPGRADE_BACKUP_DIR/in-progress" 2>/dev/null)" ""

upgraded_cluster
run_rollback "$BACKUP/postgres.dump" --yes
assert_equals "rollback given the dump's path: succeeds" "$STATUS" 0

# Static files and NetworkPolicy that weren't there before go again.
reset
run_upgrade --skip-deps-check
BACKUP=$(run_dir)
: >"$CALLS"
run_rollback "$BACKUP" --yes
assert_contains "rollback, no static files before: deleted" "$CALL_LOG" "delete configmap gateway-static"
assert_not_contains "rollback, no NetworkPolicy before: none applied" "$CALL_LOG" "networkpolicies.json"
assert_contains "rollback, no NetworkPolicy before: removed" "$CALL_LOG" "delete networkpolicy -n llmapi --all"

upgraded_cluster
run_rollback "$BACKUP"
assert_equals "rollback without --yes or a terminal: refused" "$STATUS" 1
assert_not_contains "rollback without --yes or a terminal: nothing stopped" "$CALL_LOG" "scale deployment"
assert_contains "rollback without --yes or a terminal: names the flag" "$OUTPUT" "--yes"

upgraded_cluster
run_rollback "$SANDBOX/nowhere" --yes
assert_equals "rollback, path not found: refused" "$STATUS" 1
assert_equals "rollback, path not found: no cluster calls" "$(cat "$CALLS")" ""

upgraded_cluster
rm "$BACKUP/objects/deployment-gateway.json"
run_rollback "$BACKUP" --yes
assert_equals "rollback, Deployment not saved: refused" "$STATUS" 1
assert_contains "rollback, Deployment not saved: names the file" "$OUTPUT" "objects/deployment-gateway.json is missing"
assert_contains "rollback, Deployment not saved: points at the restore Job" "$OUTPUT" "llmapi-postgres-restore-job.yaml"
assert_not_contains "rollback, Deployment not saved: nothing stopped" "$CALL_LOG" "scale deployment"

upgraded_cluster
printf 'changed' >>"$BACKUP/postgres.dump"
run_rollback "$BACKUP" --yes
assert_equals "rollback, checksum mismatch: refused" "$STATUS" 1
assert_contains "rollback, checksum mismatch: says so" "$OUTPUT" "doesn't match its checksum"
assert_not_contains "rollback, checksum mismatch: nothing stopped" "$CALL_LOG" "scale deployment"

upgraded_cluster
touch "$STATE/fail-pg-truncated"
run_rollback "$BACKUP" --yes
assert_equals "rollback, dump unreadable: refused" "$STATUS" 1
assert_not_contains "rollback, dump unreadable: nothing stopped" "$CALL_LOG" "scale deployment"

upgraded_cluster
write_stub systemctl '[ "$1" = is-active ]'
run_rollback "$BACKUP" --yes
assert_equals "rollback, monitor active: refused" "$STATUS" 1
assert_not_contains "rollback, monitor active: nothing stopped" "$CALL_LOG" "scale deployment"

upgraded_cluster
touch "$STATE/fail-pg-restore"
run_rollback "$BACKUP" --yes
assert_equals "rollback, restore fails: stops" "$STATUS" 1
assert_contains "rollback, restore fails: API reported down" "$OUTPUT" "The public API is DOWN"
assert_contains "rollback, restore fails: gives the same command" "$OUTPUT" "--rollback $BACKUP"
assert_not_contains "rollback, restore fails: old code not put back on a new database" "$(cat "$STATE/replaced" 2>/dev/null)" "configmap/gateway-code"
assert_contains "rollback, restore fails: reported as rollback" "$OUTPUT" "rollback STOPPED during: Restoring Postgres"

# Repeating a failed rollback works.
rm "$STATE/fail-pg-restore"
run_rollback "$BACKUP" --yes
assert_equals "rollback, repeated after a failure: succeeds" "$STATUS" 0

upgraded_cluster
touch "$STATE/fail-gateway-rollout"
run_rollback "$BACKUP" --yes
assert_equals "rollback, gateway never ready: stops" "$STATUS" 1
assert_contains "rollback, gateway never ready: API reported down" "$OUTPUT" "The public API is DOWN"

## deploy-gateway.sh

run_deploy() {
    OUTPUT=$(bash "$APP/deploy-gateway.sh" 2>&1)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

reset
run_deploy
assert_equals "deploy, template unchanged: succeeds" "$STATUS" 0
assert_contains "deploy, template unchanged: still restarts, to pick up config" "$CALL_LOG" "rollout restart deployment/gateway"
assert_contains "deploy: replica count kept" "$(cat "$STATE/last-apply")" "  replicas: 2"
assert_not_contains "deploy: doesn't create the Redis secret" "$CALL_LOG" "llmapi-redis-auth"

reset
touch "$STATE/template-changes"
run_deploy
assert_equals "deploy, template changed: succeeds" "$STATUS" 0
assert_not_contains "deploy, template changed: no second restart" "$CALL_LOG" "rollout restart"
assert_contains "deploy: waits for the rollout" "$CALL_LOG" "rollout status deployment/gateway"

finish
