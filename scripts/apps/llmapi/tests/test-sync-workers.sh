#!/bin/bash
# R7: one failing worker must not abort the sync or the installer, and the caller must be
# told the sync was incomplete.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox ssh rsync

export SOURCE_DIR="$SANDBOX/models"
mkdir -p "$SOURCE_DIR/vllm/models--Org--Model/snapshots/main" "$SOURCE_DIR/llamacpp" "$SOURCE_DIR/embedding"
echo weights >"$SOURCE_DIR/vllm/models--Org--Model/snapshots/main/model.safetensors"
echo gguf >"$SOURCE_DIR/llamacpp/model.gguf"
echo gguf >"$SOURCE_DIR/embedding/model.gguf"

export WORKERS_JSON="$SANDBOX/workers.json"
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
unset SUDO_USER || true

write_stub kubectl '
case "$*" in
    "get nodes") exit 0 ;;
    "get configmap -n kube-system cluster-info "*) [ -z "${NO_CLUSTER_INFO:-}" ] || exit 1; echo ops ;;
    "get nodes --selector="*) cat "$WORKERS_JSON" ;;
    "get node "*) echo ops ;;
    *) exit 0 ;;
esac
'

# Drains stdin, as a real ssh can. Without the fix, this ends the loop over workers after
# the first one.
write_stub ssh '
cat >/dev/null
echo "ssh $*" >>"$CALLS"
case "$*" in
    *10.0.0.2*) exit 1 ;;
esac
echo connected
'

write_stub rsync '
cat >/dev/null
echo "rsync $*" >>"$CALLS"
case "$*" in
    *10.0.0.4*) echo "rsync failed" ; exit 23 ;;
esac
'

# Usage: set_workers <ip>...
set_workers() {
    local ip args=()
    for ip in "$@"; do
        args+=("$ip")
    done
    jq -n '{items: ($ARGS.positional | map({metadata: {name: ("node-" + .), labels: {"mynodeone.io/worker-ip": .}}}))}' \
        --args "${args[@]}" >"$WORKERS_JSON"
}

run_sync() {
    : >"$CALLS"
    OUTPUT=$(bash "$LLMAPI_DIR/sync-models-to-workers.sh" 2>&1)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

set_workers 10.0.0.1 10.0.0.3
run_sync
assert_equals "two healthy workers: exits 0" "$STATUS" 0
assert_contains "two healthy workers: first synced" "$CALL_LOG" "@10.0.0.1:"
assert_contains "two healthy workers: second synced, stdin not eaten" "$CALL_LOG" "@10.0.0.3:"
assert_contains "two healthy workers: counted" "$OUTPUT" "Successfully synced to 2 worker node(s)"
assert_contains "llama.cpp models synced" "$CALL_LOG" "/llamacpp/"
assert_contains "embedding models synced" "$CALL_LOG" "/embedding/"
assert_contains "vLLM models synced" "$CALL_LOG" "/vllm/"

set_workers 10.0.0.2 10.0.0.3
run_sync
assert_equals "first worker unreachable: exits non-zero" "$STATUS" 1
assert_contains "first worker unreachable: later worker still synced" "$CALL_LOG" "@10.0.0.3:"
assert_contains "first worker unreachable: failure counted" "$OUTPUT" "Failed to sync to 1 worker node(s)"
assert_contains "first worker unreachable: summary printed" "$OUTPUT" "Sync Summary"

set_workers 10.0.0.1 10.0.0.4 10.0.0.3
run_sync
assert_equals "rsync fails on the middle worker: exits non-zero" "$STATUS" 1
assert_contains "rsync fails on the middle worker: last worker still synced" "$CALL_LOG" "@10.0.0.3:"
assert_contains "rsync fails on the middle worker: counted" "$OUTPUT" "Successfully synced to 2 worker node(s)"

set_workers 10.0.0.2
run_sync
assert_equals "only worker fails: exits non-zero" "$STATUS" 1
assert_contains "only worker fails: reaches the summary" "$OUTPUT" "Sync Summary"
assert_contains "only worker fails: says which" "$OUTPUT" "SSH access check failed for 10.0.0.2"

set_workers 10.0.0.1
export NO_CLUSTER_INFO=1
run_sync
assert_equals "cluster-info ConfigMap missing: still syncs" "$STATUS" 0
assert_contains "cluster-info ConfigMap missing: worker synced" "$CALL_LOG" "@10.0.0.1:"
unset NO_CLUSTER_INFO

# The installer has to survive a failed sync under set -e. Run the same if/else shape the
# installer uses against this script.
INSTALLER_BLOCK=$(grep -n 'sync-models-to-workers.sh"; then' "$LLMAPI_DIR/install-llmapi.sh")
assert_contains "installer calls the sync inside an if" "$INSTALLER_BLOCK" 'if "$SCRIPT_DIR/sync-models-to-workers.sh"; then'
BARE_CALL=$(grep -nE '^[[:space:]]*"\$SCRIPT_DIR/sync-models-to-workers.sh"' "$LLMAPI_DIR/install-llmapi.sh" || true)
assert_equals "installer has no bare sync call that set -e could abort on" "$BARE_CALL" ""

set_workers 10.0.0.2
SURVIVED=$(bash -c '
    set -euo pipefail
    if bash "$1/sync-models-to-workers.sh" >/dev/null 2>&1; then echo synced; else echo incomplete; fi
    echo continued
' _ "$LLMAPI_DIR")
assert_contains "under set -e: failure takes the warning branch" "$SURVIVED" "incomplete"
assert_contains "under set -e: the caller carries on" "$SURVIVED" "continued"

finish
