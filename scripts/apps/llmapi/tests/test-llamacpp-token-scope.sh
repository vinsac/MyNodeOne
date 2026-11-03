#!/bin/bash
# S22 (manifest side): the HF token only goes to Hugging Face. Runs the block from
# manifests/llamacpp.yaml under sh, as the init container does.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

BLOCK=$(sed -n '/# BEGIN token-scope/,/# END token-scope/p' "$LLMAPI_DIR/manifests/llamacpp.yaml")

token_for() {
    MODEL_URL="$1" HF_TOKEN="${2-secret}" sh -c "$BLOCK"'
printf "%s" "$AUTH_TOKEN"' | tail -n1 | grep -x secret || true
}

expect_sent() {
    assert_equals "token sent: $1" "$(token_for "$1")" "secret"
}

expect_withheld() {
    assert_equals "token withheld: $1" "$(token_for "$1")" ""
}

expect_sent "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/model.gguf"
expect_sent "https://cdn.huggingface.co/x/model.gguf"
expect_sent "https://huggingface.co"
expect_sent "https://huggingface.co?x=1"

expect_withheld "http://huggingface.co/x.gguf"
expect_withheld "https://evil.example/huggingface.co/x.gguf"
expect_withheld "https://huggingface.co.evil.example/x.gguf"
expect_withheld "https://evilhuggingface.co/x.gguf"
expect_withheld "https://huggingface.co@evil.example/x.gguf"
expect_withheld "https://evil.example#.huggingface.co"
expect_withheld "https://evil.example?.huggingface.co"
expect_withheld "https://evil.example\\.huggingface.co/x.gguf"
expect_withheld "https://huggingface.co:443@evil.example/x.gguf"
expect_withheld "HTTPS://evil.example/x.gguf"
expect_withheld "file:///etc/passwd"
expect_withheld ""

# No uses of the raw token left in the download commands.
SCRIPT=$(grep -v '^[[:space:]]*#' "$LLMAPI_DIR/manifests/llamacpp.yaml")
USES=$(grep -n 'HF_TOKEN' <<<"$SCRIPT" | grep -vE 'HF_TOKEN:-|AUTH_TOKEN="\$HF_TOKEN"|name: HF_TOKEN' || true)
assert_equals "download commands only use the scoped token" "$USES" ""

finish
