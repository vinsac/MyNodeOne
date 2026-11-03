#!/bin/bash
# R18: a model already on the node must be found, so the init container skips the download.
# Runs the model-downloader script from manifests/vllm.yaml with stubbed tools.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox pip python3 chown chmod

write_stub pip 'echo "pip $*" >>"$CALLS"'
write_stub python3 'cat >/dev/null; echo "python3 $*" >>"$CALLS"'
write_stub chown 'echo "chown $*" >>"$CALLS"'
write_stub chmod 'echo "chmod $*" >>"$CALLS"'

MODELS="$SANDBOX/models"
INIT_SCRIPT="$SANDBOX/init.sh"

# The script block in the manifest, with /models pointed at the sandbox. Everything up to
# the first download attempt is what's under test.
awk '
    /- name: model-downloader/ { in_init = 1 }
    in_init && /^        - \|$/ { in_args = 1; next }
    in_args && /^        [^ ]/ { exit }
    in_args { sub(/^          /, ""); print }
' "$LLMAPI_DIR/manifests/vllm.yaml" | sed "s#\([\"[:space:]]\)/models#\1$MODELS#g" >"$INIT_SCRIPT"

if ! grep -q 'Model Pre-Download' "$INIT_SCRIPT"; then
    fail "extract the init script from vllm.yaml" "$(cat "$INIT_SCRIPT")"
    finish
    exit 1
fi

run_init() {
    rm -rf "$MODELS"
    mkdir -p "$MODELS"
    : >"$CALLS"
    if [ -n "${1:-}" ]; then
        mkdir -p "$MODELS/$1/snapshots/abc123"
        echo weights >"$MODELS/$1/snapshots/abc123/${2:-model.safetensors}"
    fi
    OUTPUT=$(MODEL_NAME="Qwen/Qwen3-14B-AWQ" HF_TOKEN="" HUGGING_FACE_HUB_TOKEN="" bash "$INIT_SCRIPT" 2>&1)
    STATUS=$?
    CALL_LOG=$(cat "$CALLS")
}

run_init "models--Qwen--Qwen3-14B-AWQ"
assert_equals "cached model: exits 0" "$STATUS" 0
assert_contains "cached model: found" "$OUTPUT" "Model weights found on hostPath"
assert_not_contains "cached model: pip not run" "$CALL_LOG" "pip "
assert_not_contains "cached model: no download" "$CALL_LOG" "python3 "

run_init "hub/models--Qwen--Qwen3-14B-AWQ"
assert_contains "cached model under hub/: found" "$OUTPUT" "Model weights found on hostPath"
assert_not_contains "cached model under hub/: pip not run" "$CALL_LOG" "pip "

# The old path, from tr mapping "/" to a single "-", must not count as this model.
run_init "models-Qwen-Qwen3-14B-AWQ"
assert_contains "wrongly named directory: downloads" "$CALL_LOG" "pip "

run_init "models--Qwen--Qwen3-14B-AWQ" "config.json"
assert_contains "snapshot without weights: downloads" "$CALL_LOG" "pip "

run_init
assert_contains "nothing cached: downloads" "$CALL_LOG" "pip "
assert_contains "download installs from the hashed lockfile" "$CALL_LOG" "--require-hashes"

finish
