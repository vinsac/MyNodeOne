#!/bin/bash

###############################################################################
# LLM API Service - Non-interactive upgrade of an existing install
#
# Brings Redis authentication, the gateway, RBAC and NetworkPolicy to the state in
# this repo. Never changes PVCs, the Postgres password, or the model settings in
# ConfigMaps. README.md, "Upgrading", has the sequence and what to expect.
#
# Upgrading from a gateway that can't send a Redis password takes the API down for a few
# minutes. It's a clean outage: Traefik answers 5xx, instead of a gateway that accepts
# requests and hangs. It's also one-way for the database, as the new gateway hashes
# API keys in place, so this first saves a dump that a rollback restores.
#
# Usage: upgrade-llmapi.sh [options]
#        upgrade-llmapi.sh --rollback <backup-dir-or-its-dump> [--yes] [--allow-health-monitor]
#   --with-backends         Also apply the vLLM, llama.cpp, embedding and Ollama manifests.
#                           Their pod templates changed, so running backends restart,
#                           and vLLM has to reload its model onto the GPU.
#   --skip-network-policy   Don't apply manifests/networkpolicy.yaml.
#   --skip-backup           Don't dump Postgres. A rollback then isn't possible.
#   --skip-deps-check       Don't test the gateway's image and pip install in a throwaway pod.
#   --allow-health-monitor  Run even with llmapi-health-monitor.timer active on this
#                           machine. It can restart pods in the middle of this.
#   --rollback <path>       Put back what a previous run saved, including the database.
#   --yes                   Don't ask before a rollback.
#
# Environment: LLMAPI_UPGRADE_BACKUP_DIR (default ~/.mynodeone/llmapi-upgrades)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/install-helpers.sh"
source "$SCRIPT_DIR/lib/gateway-code.sh"

export NAMESPACE="${NAMESPACE:-llmapi}"
BACKUP_ROOT="${LLMAPI_UPGRADE_BACKUP_DIR:-$HOME/.mynodeone/llmapi-upgrades}"
MARKER="$BACKUP_ROOT/in-progress"
PREFLIGHT_NAME=llmapi-upgrade-preflight
PREFLIGHT_TIMEOUT="${PREFLIGHT_TIMEOUT:-300}"
POLL_SECONDS="${UPGRADE_POLL_SECONDS:-3}"
GATEWAY_TIMEOUT="${GATEWAY_TIMEOUT:-300s}"
RBAC_OBJECTS="serviceaccount/gateway role/gateway-backend-manager rolebinding/gateway-backend-manager clusterrole/gateway-node-reader clusterrolebinding/gateway-node-reader"

WITH_BACKENDS=false
APPLY_NETWORK_POLICY=true
TAKE_BACKUP=true
CHECK_DEPS=true
ALLOW_MONITOR=false
ROLLBACK_PATH=""
ASSUME_YES=false

# What the failure report needs to know.
MODE=upgrade
STAGE=""
API_DOWN=false
RUN_DIR=""
RUN_DIR_INCOMPLETE=false
PREFLIGHT_STARTED=false

usage() {
    echo "Usage: $0 [--with-backends] [--skip-network-policy] [--skip-backup] [--skip-deps-check] [--allow-health-monitor]" >&2
    echo "       $0 --rollback <backup-dir-or-its-dump> [--yes] [--allow-health-monitor]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-backends) WITH_BACKENDS=true ;;
        --skip-network-policy) APPLY_NETWORK_POLICY=false ;;
        --skip-backup) TAKE_BACKUP=false ;;
        --skip-deps-check) CHECK_DEPS=false ;;
        --allow-health-monitor) ALLOW_MONITOR=true ;;
        --yes) ASSUME_YES=true ;;
        --rollback)
            [ $# -ge 2 ] || usage
            ROLLBACK_PATH="$2"
            MODE=rollback
            shift
            ;;
        *) usage ;;
    esac
    shift
done

stage() {
    STAGE="$1"
    echo ""
    echo "==> $1"
}

## The report when something stops the script

# Best effort, and short on time: the cluster may be why this is being printed.
print_state() {
    local replicas ready redis_auth=no gateway_auth=no plaintext
    replicas=$(kubectl get deployment gateway -n "$NAMESPACE" --request-timeout=10s -o 'jsonpath={.spec.replicas}' 2>/dev/null || echo unknown)
    ready=$(kubectl get deployment gateway -n "$NAMESPACE" --request-timeout=10s -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)
    gateway_predates_redis_auth || gateway_auth=yes
    redis_requires_password && redis_auth=yes
    plaintext=$(_psql_query "SELECT count(*) FROM api_keys WHERE api_key NOT LIKE 'sha256:%';" || echo unknown)
    echo "State now:"
    echo "  Gateway:   ${replicas} replicas wanted, ${ready:-0} ready, template sends a Redis password: $gateway_auth"
    echo "  Redis:     requires a password: $redis_auth"
    echo "  Postgres:  API keys not yet hashed: $plaintext"
    if [ -n "$RUN_DIR" ] && [ -s "$RUN_DIR/postgres.dump" ]; then
        echo "  Backup:    $RUN_DIR"
    fi
}

report_failure() {
    local ready
    echo "" >&2
    echo "============================================================" >&2
    echo "$MODE STOPPED during: $STAGE" >&2
    # API_DOWN alone isn't enough: a re-run has no cut of its own, yet may find nothing ready.
    ready=$(kubectl get deployment gateway -n "$NAMESPACE" --request-timeout=10s -o 'jsonpath={.status.readyReplicas}' 2>/dev/null) || ready=unknown
    if [ "$API_DOWN" = true ] || [ "${ready:-0}" = 0 ]; then
        echo "The public API is DOWN until this is resolved." >&2
    elif [ "$ready" = unknown ]; then
        echo "Couldn't read the gateway's state, so the public API may be down." >&2
    else
        echo "The public API was not stopped by this failure." >&2
    fi
    print_state >&2
    echo "" >&2
    echo "Why it stopped:" >&2
    echo "  kubectl -n $NAMESPACE get pods" >&2
    echo "  kubectl -n $NAMESPACE describe pods -l app=llmapi-gateway" >&2
    echo "  kubectl -n $NAMESPACE logs deployment/gateway -c install-deps --tail=50" >&2
    echo "  kubectl -n $NAMESPACE logs deployment/gateway --tail=50" >&2
    echo "" >&2
    echo "Then either:" >&2
    if [ "$MODE" = rollback ]; then
        echo "  Run the rollback again. Every step is safe to repeat:" >&2
        echo "    bash $0 --rollback $RUN_DIR" >&2
    else
        echo "  Fix the cause and run this again. It carries on with the same backup:" >&2
        echo "    bash $0" >&2
        if [ -n "$RUN_DIR" ] && [ -s "$RUN_DIR/postgres.dump" ]; then
            echo "  Or go back to what was running before:" >&2
            echo "    bash $0 --rollback $RUN_DIR" >&2
        fi
    fi
    echo "" >&2
    echo "Don't use 'kubectl rollout undo' here. The old pod template would load the new" >&2
    echo "main.py, and the old gateway can't authenticate against a migrated database." >&2
    echo "============================================================" >&2
}

on_exit() {
    local status=$?
    trap - EXIT
    set +e
    remove_preflight_objects
    if [ "$RUN_DIR_INCOMPLETE" = true ]; then
        rm -rf "$RUN_DIR"
    fi
    if [ "$status" -ne 0 ]; then
        if [ -n "$STAGE" ]; then
            report_failure
        else
            echo "Nothing changed in the cluster." >&2
        fi
    fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

## Checks that change nothing

require_tools() {
    local tool
    for tool in jq sha256sum; do
        if ! command -v "$tool" >/dev/null; then
            echo "ERROR: $tool is needed for the backup, and isn't installed." >&2
            exit 1
        fi
    done
}

require_install() {
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "ERROR: namespace $NAMESPACE not found. Use install-llmapi.sh for a first install." >&2
        exit 1
    fi
    # Prints only whether the key is there. The gateway and Postgres pods need it.
    if ! secret_exists llmapi-db || [ "$(kubectl get secret llmapi-db -n "$NAMESPACE" -o 'go-template={{if index .data "postgres-password"}}yes{{end}}' 2>/dev/null)" != yes ]; then
        echo "ERROR: Secret llmapi-db with a postgres-password not found, so this doesn't look like a working install." >&2
        exit 1
    fi
    if ! kubectl get deployment gateway -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "ERROR: Deployment gateway not found. Use install-llmapi.sh to finish the install." >&2
        exit 1
    fi
}

# The installed monitor restarts pods it thinks are unhealthy, and doesn't know about this.
require_monitor_stopped() {
    if systemctl is-active --quiet llmapi-health-monitor.timer 2>/dev/null; then
        if [ "$ALLOW_MONITOR" = true ]; then
            echo "WARNING: llmapi-health-monitor.timer is active and may restart pods during this."
            return 0
        fi
        echo "ERROR: llmapi-health-monitor.timer is active. It can restart pods during maintenance." >&2
        echo "       Stop it for now, and start it again afterwards:" >&2
        echo "         sudo systemctl stop llmapi-health-monitor.timer" >&2
        echo "         sudo systemctl start llmapi-health-monitor.timer" >&2
        echo "       Or pass --allow-health-monitor to run anyway." >&2
        exit 1
    fi
}

redis_requires_password() {
    local names
    names=$(kubectl get deployment redis -n "$NAMESPACE" --request-timeout=30s -o 'jsonpath={.spec.template.spec.containers[*].env[*].name}' 2>/dev/null) || return 1
    [[ " $names " == *" REDISCLI_AUTH "* ]]
}

## Preflight: what could fail after the cut, tried before it

remove_preflight_objects() {
    if [ "$PREFLIGHT_STARTED" = true ]; then
        kubectl delete pod "$PREFLIGHT_NAME" -n "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        kubectl delete configmap "$PREFLIGHT_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
    fi
}

check_manifests_render() {
    local sha rendered manifest
    sha=$(gateway_code_sha "$SCRIPT_DIR")
    rendered=$(render_manifest <(sed -e "s/__NAMESPACE__/$NAMESPACE/g" -e "s/__GATEWAY_CODE_SHA__/$sha/g" "$SCRIPT_DIR/manifests/gateway-deployment.yaml"))
    kubectl apply --dry-run=server -f - <<<"$rendered" >/dev/null
    rendered=$(render_manifest "$SCRIPT_DIR/manifests/redis.yaml")
    kubectl apply --dry-run=server -f - <<<"$rendered" >/dev/null
    kubectl apply --dry-run=server -f "$SCRIPT_DIR/manifests/gateway-rbac.yaml" >/dev/null
    if [ "$APPLY_NETWORK_POLICY" = true ]; then
        kubectl apply --dry-run=server -f "$SCRIPT_DIR/manifests/networkpolicy.yaml" >/dev/null
    fi
    render_gateway_static "$SCRIPT_DIR" >/dev/null
    if [ "$WITH_BACKENDS" = true ]; then
        for manifest in vllm llamacpp embedding ollama; do
            rendered=$(render_manifest "$SCRIPT_DIR/manifests/$manifest.yaml")
            kubectl apply --dry-run=server -f - <<<"$rendered" >/dev/null
        done
    fi
}

preflight_pod_manifest() {
    local gateway_image redis_image
    gateway_image=$(sed -n 's/^ *image: *//p' "$SCRIPT_DIR/manifests/gateway-deployment.yaml" | head -n1)
    redis_image=$(sed -n 's/^ *image: *//p' "$SCRIPT_DIR/manifests/redis.yaml" | head -n1)
    # No gateway label: the Service would route public traffic to this pod. A ConfigMap of
    # its own: replacing gateway-code now would hand new code to an old pod that restarts.
    cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $PREFLIGHT_NAME
  namespace: $NAMESPACE
  labels:
    app: $PREFLIGHT_NAME
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  initContainers:
  - name: pull-redis-image
    image: $redis_image
    command: ["redis-server", "--version"]
    resources: {requests: {memory: 32Mi, cpu: 50m}, limits: {memory: 128Mi, cpu: 500m}}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
  containers:
  - name: check
    image: $gateway_image
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -e
      pip install --no-cache-dir --quiet --disable-pip-version-check \\
        --require-hashes --only-binary=:all: \\
        --target=/deps -r /preflight/requirements.lock
      cd /preflight
      PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/deps python -c 'import main'
      echo "main.py imports with the locked dependencies"
    volumeMounts:
    - {name: deps, mountPath: /deps}
    - {name: code, mountPath: /preflight, readOnly: true}
    resources: {requests: {memory: 256Mi, cpu: 200m}, limits: {memory: 1Gi, cpu: "1"}}
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
  volumes:
  - {name: deps, emptyDir: {}}
  - name: code
    configMap:
      name: $PREFLIGHT_NAME
YAML
}

check_deps_in_a_throwaway_pod() {
    local phase reasons started=$SECONDS
    PREFLIGHT_STARTED=true
    # A leftover from a killed run, or the pod would refuse to be created.
    kubectl delete pod "$PREFLIGHT_NAME" -n "$NAMESPACE" --ignore-not-found --wait=true >/dev/null
    kubectl delete configmap "$PREFLIGHT_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null
    # Really creating it, with the files gateway-code will hold, also proves they fit.
    kubectl create configmap "$PREFLIGHT_NAME" -n "$NAMESPACE" \
        --from-file=main.py="$SCRIPT_DIR/gateway/main.py" \
        --from-file=requirements.lock="$SCRIPT_DIR/gateway/requirements.lock" >/dev/null
    preflight_pod_manifest | kubectl create -f - >/dev/null

    while :; do
        phase=$(kubectl get pod "$PREFLIGHT_NAME" -n "$NAMESPACE" --request-timeout=10s -o 'jsonpath={.status.phase}' 2>/dev/null || true)
        case "$phase" in
            Succeeded)
                remove_preflight_objects
                return 0
                ;;
            Failed)
                echo "ERROR: the test pod failed:" >&2
                kubectl logs "$PREFLIGHT_NAME" -n "$NAMESPACE" --all-containers --tail=30 >&2 || true
                echo "Pass --skip-deps-check only if you know why this can't happen to the gateway." >&2
                return 1
                ;;
        esac
        reasons=$(kubectl get pod "$PREFLIGHT_NAME" -n "$NAMESPACE" --request-timeout=10s \
            -o 'jsonpath={.status.initContainerStatuses[*].state.waiting.reason} {.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || true)
        if [[ "$reasons" == *ImagePull* || "$reasons" == *InvalidImageName* ]]; then
            echo "ERROR: the test pod can't pull an image ($reasons):" >&2
            kubectl get pod "$PREFLIGHT_NAME" -n "$NAMESPACE" -o 'jsonpath={.spec.initContainers[*].image} {.spec.containers[*].image}{"\n"}' >&2 || true
            return 1
        fi
        # Real time, as each kubectl call above can take seconds when the API server is slow.
        if [ $((SECONDS - started)) -ge "$PREFLIGHT_TIMEOUT" ]; then
            echo "ERROR: the test pod didn't finish in ${PREFLIGHT_TIMEOUT}s (phase: ${phase:-unknown}, waiting: ${reasons:-nothing})." >&2
            return 1
        fi
        sleep "$POLL_SECONDS"
    done
}

## Backup: Postgres through kubectl exec, so NetworkPolicy doesn't come into it

save_object() {
    local object="$1" file="$RUN_DIR/objects/${1//\//-}" json
    json=$(kubectl get "$object" -n "$NAMESPACE" --ignore-not-found -o json)
    if [ -z "$json" ]; then
        : >"$file.absent"
        return 0
    fi
    # The last-applied annotation stays, so that a later apply over this works as usual.
    jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation,
            .metadata.managedFields, .status, .metadata.annotations["deployment.kubernetes.io/revision"])' \
        <<<"$json" >"$file.json"
}

save_objects() {
    local object
    mkdir -p "$RUN_DIR/objects"
    for object in deployment/gateway deployment/redis configmap/gateway-code configmap/gateway-static \
        configmap/gateway-config $RBAC_OBJECTS; do
        save_object "$object"
    done
    kubectl get networkpolicy -n "$NAMESPACE" -o json |
        jq '.items |= map(del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status))' \
            >"$RUN_DIR/objects/networkpolicies.json"
    kubectl get deployment gateway -n "$NAMESPACE" -o 'jsonpath={.spec.replicas}' >"$RUN_DIR/gateway-replicas"
}

# pg_restore -l only reads the table of contents, so it passes a truncated dump. Reading
# everything into /dev/null doesn't.
verify_dump() {
    local dump="$1" contents
    if ! contents=$(kubectl exec -i -n "$NAMESPACE" deploy/llmapi-postgres -- pg_restore -l <"$dump"); then
        echo "ERROR: pg_restore can't read $dump." >&2
        return 1
    fi
    if ! grep -q 'TABLE DATA public api_keys' <<<"$contents"; then
        echo "ERROR: $dump has no api_keys data, so it can't be what a rollback needs." >&2
        return 1
    fi
    if ! kubectl exec -i -n "$NAMESPACE" deploy/llmapi-postgres -- pg_restore -f /dev/null <"$dump"; then
        echo "ERROR: $dump is damaged. pg_restore can't read all of it." >&2
        return 1
    fi
}

dump_postgres() {
    local plaintext
    if ! kubectl exec -n "$NAMESPACE" deploy/llmapi-postgres -- pg_dump -U llmapi -d llmapi -Fc >"$RUN_DIR/postgres.dump.partial"; then
        echo "ERROR: pg_dump failed. To upgrade without a backup, and so with no way back," >&2
        echo "       pass --skip-backup." >&2
        return 1
    fi
    if ! verify_dump "$RUN_DIR/postgres.dump.partial"; then
        echo "       To upgrade without a backup, and so with no way back, pass --skip-backup." >&2
        return 1
    fi
    mv "$RUN_DIR/postgres.dump.partial" "$RUN_DIR/postgres.dump"
    (cd "$RUN_DIR" && sha256sum postgres.dump >postgres.dump.sha256)

    plaintext=$(_psql_query "SELECT count(*) FROM api_keys WHERE api_key NOT LIKE 'sha256:%';" || echo unknown)
    echo "   Saved and verified: $RUN_DIR/postgres.dump"
    echo "   WARNING: this dump holds raw API keys ($plaintext not yet hashed). It's mode 600."
    echo "   Delete it once you're sure you won't roll back."
    echo "   WARNING: the new gateway hashes the keys in the database, and the old gateway"
    echo "   can't read them after that. Going back means restoring this dump, which loses"
    echo "   keys and usage from after it. Use: bash $0 --rollback $RUN_DIR"
    if [ "$plaintext" = 0 ]; then
        echo "   Every key is already hashed, so this dump can't bring back an older gateway."
    fi
}

# Sets RUN_DIR, and on the first run saves everything into it. A re-run after a failure
# keeps the first run's files: by then the database may be migrated, and only that dump
# can undo it.
prepare_backup() {
    umask 077
    mkdir -p "$BACKUP_ROOT"
    if [ -e "$MARKER" ]; then
        RUN_DIR=$(cat "$MARKER")
        if [ ! -d "$RUN_DIR" ]; then
            echo "ERROR: $MARKER points at $RUN_DIR, which is gone." >&2
            echo "       If no upgrade is really in progress, delete $MARKER and run this again." >&2
            exit 1
        fi
        if [ "$TAKE_BACKUP" = true ] && [ ! -s "$RUN_DIR/postgres.dump" ]; then
            echo "ERROR: the unfinished upgrade in $RUN_DIR has no dump. Pass --skip-backup to carry on without one." >&2
            exit 1
        fi
        echo "   Carrying on with the unfinished upgrade in $RUN_DIR"
        return 0
    fi

    RUN_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$RUN_DIR"
    RUN_DIR_INCOMPLETE=true
    save_objects
    if [ "$TAKE_BACKUP" = true ]; then
        dump_postgres
    else
        echo "   WARNING: --skip-backup. There is no way back after the new gateway hashes the keys."
    fi
    echo "$RUN_DIR" >"$MARKER"
    RUN_DIR_INCOMPLETE=false
}

# The count to come back up with. Reads what was running before the first attempt, as a
# failed attempt may have left it at 0.
gateway_replicas_wanted() {
    local saved
    saved=$(cat "$RUN_DIR/gateway-replicas" 2>/dev/null || true)
    if [[ "$saved" =~ ^[1-9][0-9]*$ ]]; then
        echo "$saved"
    else
        echo 1
    fi
}

## After the gateway's up

# Warnings only. /health uses neither store by design, so it says little about them.
check_after_upgrade() {
    local plaintext ping
    plaintext=$(_psql_query "SELECT count(*) FROM api_keys WHERE api_key NOT LIKE 'sha256:%';" || echo unknown)
    if [ "$plaintext" != 0 ]; then
        echo "   WARNING: API keys not hashed after the gateway started: $plaintext. See: kubectl -n $NAMESPACE logs deployment/gateway"
    fi
    ping=$(kubectl exec -n "$NAMESPACE" deploy/redis -- redis-cli ping 2>/dev/null || true)
    if [ "$ping" != PONG ]; then
        echo "   WARNING: Redis didn't answer a ping with its password: ${ping:-no answer}"
    fi
}

upgrade() {
    local needs_cut=false replicas current manifest

    # Taking Redis to a password with a gateway that can't send one would be an outage.
    if ! grep -q 'REDIS_PASSWORD' "$SCRIPT_DIR/gateway/main.py"; then
        echo "ERROR: gateway/main.py doesn't read REDIS_PASSWORD. Upgrading Redis now would take the API down." >&2
        echo "       Bring in the gateway change first." >&2
        exit 1
    fi
    require_tools
    require_install
    require_monitor_stopped

    if gateway_predates_redis_auth || ! redis_requires_password; then
        needs_cut=true
        echo "This upgrade stops the API for about 1 to 2 minutes, 5 at most if Redis's volume is"
        echo "slow to reattach. From the moment the old gateway stops until the new one is ready,"
        echo "clients get a 5xx from Traefik or a refused connection, not a hang."
    elif [ -e "$MARKER" ]; then
        echo "An earlier run of this upgrade didn't finish. This one carries on from it."
    else
        echo "Redis and the gateway both use the Redis password already, so the gateway rolls"
        echo "without stopping, apart from a Redis restart if its manifest changed."
    fi
    echo "Nothing stops until the checks and the backup below have passed."

    echo ""
    echo "==> Checking what can be checked before anything stops"
    echo "   Manifests against the API server"
    check_manifests_render
    if [ "$CHECK_DEPS" = true ]; then
        echo "   Images and the pip lock, in a throwaway pod"
        check_deps_in_a_throwaway_pod
    else
        echo "   --skip-deps-check: the images and the pip lock will first be tried for real"
    fi

    echo ""
    echo "==> Backup"
    prepare_backup
    replicas=$(gateway_replicas_wanted)

    stage "Redis password secret"
    ensure_redis_secret

    if [ "$needs_cut" = true ]; then
        stage "Stopping the old gateway. The outage starts here"
        API_DOWN=true
        kubectl scale deployment/gateway -n "$NAMESPACE" --replicas=0
        kubectl wait --for=delete pod -l app=llmapi-gateway -n "$NAMESPACE" --timeout=120s
    fi

    stage "Redis, now requiring the password"
    apply_manifest "$SCRIPT_DIR/manifests/redis.yaml"
    kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=300s

    # After the old gateway is gone, as these narrow what it may do.
    stage "Gateway RBAC"
    kubectl apply -f "$SCRIPT_DIR/manifests/gateway-rbac.yaml"

    stage "Gateway"
    WAIT_TIMEOUT="$GATEWAY_TIMEOUT" bash "$SCRIPT_DIR/deploy-gateway.sh"

    # At 0 replicas deploy-gateway.sh had nothing to wait for.
    current=$(kubectl get deployment gateway -n "$NAMESPACE" -o 'jsonpath={.spec.replicas}')
    if [ "$current" = 0 ]; then
        stage "Starting the new gateway: $replicas replica(s), pip install first"
        API_DOWN=true
        kubectl scale deployment/gateway -n "$NAMESPACE" --replicas="$replicas"
        kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout="$GATEWAY_TIMEOUT"
    fi
    API_DOWN=false
    echo "   The gateway is ready. Any outage ends here."
    check_after_upgrade

    stage "Service label, for the ServiceMonitor"
    kubectl label service llmapi -n "$NAMESPACE" app=llmapi-gateway --overwrite

    if [ "$WITH_BACKENDS" = true ]; then
        stage "Backends (running ones restart)"
        ship_model_downloader_lock "$SCRIPT_DIR"
        for manifest in vllm llamacpp embedding ollama; do
            apply_manifest "$SCRIPT_DIR/manifests/$manifest.yaml"
        done
    fi

    # Last, so that if the API stops answering here, this is what did it.
    if [ "$APPLY_NETWORK_POLICY" = true ]; then
        stage "NetworkPolicy"
        kubectl apply -f "$SCRIPT_DIR/manifests/networkpolicy.yaml"
        echo ""
        echo "Check the public API now. If it stopped responding, back out with:"
        echo "  kubectl delete networkpolicy -n $NAMESPACE --all"
    else
        echo ""
        echo "NetworkPolicy skipped"
    fi

    rm -f "$MARKER"
    echo ""
    echo "Upgrade complete."
    if [ "$WITH_BACKENDS" = false ]; then
        echo "Backends were not touched. Run again with --with-backends at a time when vLLM can restart."
    fi
    echo "Saved: $RUN_DIR (holds raw API keys if it has a dump; delete it when you're sure you won't roll back)"
    echo "If you stopped the health monitor, install this version of it and start it again:"
    echo "  sudo bash $SCRIPT_DIR/health-check.sh --install-monitor"
}

## Rollback

restore_object() {
    local kind="${1%%/*}" name="${1#*/}" file="$RUN_DIR/objects/${1//\//-}"
    if [ -f "$file.json" ]; then
        replace_or_create_from_stdin "$kind" "$name" <"$file.json"
    elif [ -f "$file.absent" ]; then
        kubectl delete "$kind" "$name" -n "$NAMESPACE" --ignore-not-found
    fi
}

confirm_rollback() {
    local answer
    echo "This puts back what was saved in $RUN_DIR:"
    echo "  - The API stops for about 2 minutes."
    echo "  - The database returns to the dump. API keys created, keys revoked and usage"
    echo "    recorded since then are lost."
    echo "  - Redis goes back to no password, and the old gateway code, RBAC and NetworkPolicy return."
    echo "  - Backends aren't changed back, if --with-backends changed them."
    echo "  - An older gateway template pip-installs unpinned, so it gets today's releases."
    if [ "$ASSUME_YES" = true ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "ERROR: pass --yes to roll back without a terminal to confirm on." >&2
        exit 1
    fi
    read -r -p "Type 'rollback' to continue: " answer
    if [ "$answer" != rollback ]; then
        echo "Stopped."
        exit 1
    fi
}

rollback() {
    local missing=false required replicas restored_policies

    if [ -d "$ROLLBACK_PATH" ]; then
        RUN_DIR="$(cd "$ROLLBACK_PATH" && pwd)"
    elif [ -f "$ROLLBACK_PATH" ]; then
        RUN_DIR="$(cd "$(dirname "$ROLLBACK_PATH")" && pwd)"
    else
        echo "ERROR: $ROLLBACK_PATH not found." >&2
        exit 1
    fi
    for required in postgres.dump postgres.dump.sha256 objects/deployment-gateway.json objects/deployment-redis.json \
        objects/configmap-gateway-code.json objects/networkpolicies.json; do
        if [ ! -s "$RUN_DIR/$required" ]; then
            echo "ERROR: $RUN_DIR/$required is missing." >&2
            missing=true
        fi
    done
    if [ "$missing" = true ]; then
        echo "       --rollback needs a directory saved by this script. A dump from the backup" >&2
        echo "       CronJob restores with scripts/backup/llmapi-postgres-restore-job.yaml." >&2
        exit 1
    fi

    require_tools
    require_install
    require_monitor_stopped
    if ! (cd "$RUN_DIR" && sha256sum --quiet -c postgres.dump.sha256); then
        echo "ERROR: $RUN_DIR/postgres.dump doesn't match its checksum." >&2
        exit 1
    fi
    verify_dump "$RUN_DIR/postgres.dump"
    confirm_rollback

    stage "Stopping the gateway. The outage starts here"
    API_DOWN=true
    kubectl scale deployment/gateway -n "$NAMESPACE" --replicas=0
    kubectl wait --for=delete pod -l app=llmapi-gateway -n "$NAMESPACE" --timeout=120s

    # One transaction, so a failure leaves the database as it was.
    stage "Restoring Postgres from the dump"
    kubectl exec -i -n "$NAMESPACE" deploy/llmapi-postgres -- \
        pg_restore -U llmapi -d llmapi --clean --if-exists --no-owner --no-privileges \
        --single-transaction --exit-on-error <"$RUN_DIR/postgres.dump"

    # Scaled to 0 first because the volume is ReadWriteOnce, and the saved Deployment may
    # roll instead of recreate.
    stage "Redis as it was"
    kubectl scale deployment/redis -n "$NAMESPACE" --replicas=0
    kubectl wait --for=delete pod -l app=redis -n "$NAMESPACE" --timeout=120s
    restore_object deployment/redis
    kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=300s

    stage "RBAC, gateway code and static files as they were"
    for required in $RBAC_OBJECTS configmap/gateway-code configmap/gateway-static; do
        restore_object "$required"
    done

    stage "Gateway as it was"
    replicas=$(gateway_replicas_wanted)
    restore_object deployment/gateway
    kubectl scale deployment/gateway -n "$NAMESPACE" --replicas="$replicas"
    kubectl rollout status deployment/gateway -n "$NAMESPACE" --timeout="$GATEWAY_TIMEOUT"
    API_DOWN=false

    stage "NetworkPolicy as it was"
    kubectl delete networkpolicy -n "$NAMESPACE" --all
    restored_policies=$(jq '.items | length' "$RUN_DIR/objects/networkpolicies.json")
    if [ "$restored_policies" -gt 0 ]; then
        kubectl apply -f "$RUN_DIR/objects/networkpolicies.json"
    fi

    rm -f "$MARKER"
    echo ""
    echo "Rollback complete. The Secret llmapi-redis-auth stays, unused."
    echo "$RUN_DIR still holds raw API keys. Delete it when you no longer need it."
}

if [ "$MODE" = rollback ]; then
    rollback
else
    upgrade
fi
