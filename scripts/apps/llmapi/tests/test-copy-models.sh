#!/bin/bash
# R20: the copy script must report what really happened and put replicas back as they were.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox sleep

export PRE_DOWNLOAD_DIR="$SANDBOX/models"
export STATE="$SANDBOX/state"
mkdir -p "$PRE_DOWNLOAD_DIR/vllm" "$STATE"
echo weights >"$PRE_DOWNLOAD_DIR/vllm/model.safetensors"

write_stub sleep 'exit 0'
write_stub kubectl '
echo "kubectl $*" >>"$CALLS"
case "$*" in
    "get pvc "*jsonpath*) echo Bound ;;
    "get pvc "*) [ -e "$STATE/pvc" ] ;;
    "get statefulset/vllm "*) echo 2 ;;
    "apply -f -") cat >/dev/null ;;
    "wait "*) [ ! -e "$STATE/copy-fails" ] ;;
esac
'

run_copy_script() {
    : >"$CALLS"
    OUTPUT=$(bash "$LLMAPI_DIR/copy-predownloaded-models.sh" 2>&1)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

rm -f "$STATE"/*
run_copy_script
assert_equals "no PVC: exits 0" "$STATUS" 0
assert_contains "no PVC: says it skipped" "$OUTPUT" "Skipped, no matching PVC: vllm"
assert_not_contains "no PVC: doesn't claim a copy" "$OUTPUT" "Copied:"
assert_not_contains "no PVC: service left running" "$CALL_LOG" "scale"
assert_not_contains "no PVC: stale script not mentioned" "$OUTPUT" "download-models.sh"

touch "$STATE/pvc"
run_copy_script
assert_equals "copy works: exits 0" "$STATUS" 0
assert_contains "copy works: reported" "$OUTPUT" "Copied: vllm"
assert_contains "copy works: scaled down first" "$CALL_LOG" "scale statefulset/vllm --replicas=0"
assert_contains "copy works: original replica count restored" "$CALL_LOG" "scale statefulset/vllm --replicas=2"
assert_not_contains "copy works: not scaled to a fixed count" "$CALL_LOG" "--replicas=1"

touch "$STATE/copy-fails"
run_copy_script
assert_equals "copy fails: exits non-zero" "$STATUS" 1
assert_contains "copy fails: reported" "$OUTPUT" "Failed: vllm"
assert_not_contains "copy fails: not reported as copied" "$OUTPUT" "Copied:"
assert_contains "copy fails: service brought back" "$CALL_LOG" "scale statefulset/vllm --replicas=2"

rm -rf "$PRE_DOWNLOAD_DIR/vllm"
run_copy_script
assert_equals "nothing to copy: exits 0" "$STATUS" 0
assert_contains "nothing to copy: says so" "$OUTPUT" "No pre-downloaded models found"

finish
