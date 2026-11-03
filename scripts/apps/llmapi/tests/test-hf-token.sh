#!/bin/bash
# The HuggingFace token Secret: only ever written with a real token, over stdin, with no
# last-applied copy, and the path named by the gateway's 409 message works.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "PyYAML is needed to run this test"
    exit 2
fi

export STATE="$SANDBOX/state"
export HOME="$SANDBOX/home"
mkdir -p "$STATE" "$HOME"
unset HF_TOKEN NAMESPACE

write_stub kubectl '
echo "kubectl $*" >>"$CALLS"
case "$*" in
    "get namespace llmapi"*) [ ! -e "$STATE/no-namespace" ] ;;
    "get secret hf-token"*) [ -e "$STATE/secret-exists" ] ;;
    "create -f -") [ ! -e "$STATE/write-fails" ] && cat >"$STATE/created" ;;
    "replace -f -") [ ! -e "$STATE/write-fails" ] && cat >"$STATE/replaced" ;;
    *) exit 1 ;;
esac
'

TOKEN="hf_stubtokenvalue123"
ENCODED=$(printf '%s' "$TOKEN" | base64 -w0)
REPO_ROOT="$(cd "$LLMAPI_DIR/../../.." && pwd)"
# The way the 409 message says to run it, with no bash in front.
CLI="$REPO_ROOT/scripts/apps/llmapi/lib/hf-token.sh"

reset() {
    rm -f "$STATE"/*
    rm -rf "${HOME:?}/.config"
    : >"$CALLS"
}

## set, from the prompt

reset
OUTPUT=$(printf '%s\n' "$TOKEN" | "$CLI" set 2>&1)
assert_equals "prompt: succeeds" "$?" 0
assert_contains "prompt: creates the Secret" "$(cat "$STATE/created" 2>/dev/null)" "name: hf-token"
assert_contains "prompt: in namespace llmapi" "$(cat "$STATE/created" 2>/dev/null)" "namespace: llmapi"
assert_contains "prompt: value under key token" "$(cat "$STATE/created" 2>/dev/null)" "token: $ENCODED"
assert_not_contains "prompt: no token in any kubectl argument" "$(cat "$CALLS")" "$TOKEN"
assert_not_contains "prompt: no apply, so no last-applied copy" "$(cat "$CALLS")" "apply"
assert_not_contains "prompt: no --from-literal" "$(cat "$CALLS")" "from-literal"
assert_not_contains "prompt: no annotation in the manifest" "$(cat "$STATE/created" 2>/dev/null)" "annotations"
assert_not_contains "prompt: token isn't echoed" "$OUTPUT" "$TOKEN"
assert_contains "prompt: says a restart is needed" "$OUTPUT" "kubectl rollout restart statefulset/vllm -n llmapi"
assert_equals "prompt: local file is private" "$(stat -c %a "$HOME/.config/llmapi/hf-token")" 600

## set, with an argument

reset
"$CLI" set "$TOKEN" >/dev/null 2>&1
assert_equals "argument: succeeds" "$?" 0
assert_contains "argument: creates the Secret" "$(cat "$STATE/created" 2>/dev/null)" "token: $ENCODED"

## Existing Secret, which is the one the Admin UI can then patch

reset
touch "$STATE/secret-exists"
"$CLI" set "$TOKEN" >/dev/null 2>&1
assert_equals "existing Secret: succeeds" "$?" 0
assert_contains "existing Secret: replaced" "$(cat "$STATE/replaced" 2>/dev/null)" "token: $ENCODED"
if [ -e "$STATE/created" ]; then fail "existing Secret: not created again"; else pass "existing Secret: not created again"; fi

## No token

reset
printf '\n' | "$CLI" set >/dev/null 2>&1
assert_equals "blank input: not an error" "$?" 0
assert_not_contains "blank input: no Secret" "$(cat "$CALLS")" "create"
assert_not_contains "blank input: no Secret replaced" "$(cat "$CALLS")" "replace"

reset
printf 'not-a-token\n' | "$CLI" set >/dev/null 2>&1
assert_not_contains "wrong format: no Secret" "$(cat "$CALLS")" "create"

reset
# shellcheck source=/dev/null
(source "$CLI"; write_hf_secret "")
assert_equals "empty value: refused" "$?" 1
assert_equals "empty value: no kubectl call" "$(cat "$CALLS")" ""

## Failures

reset
touch "$STATE/write-fails"
"$CLI" set "$TOKEN" >/dev/null 2>&1
assert_equals "kubectl write fails: reported" "$?" 1

reset
touch "$STATE/write-fails"
printf '%s\n' "$TOKEN" | "$CLI" set >/dev/null 2>&1
assert_equals "kubectl write fails at the prompt: reported" "$?" 1

reset
touch "$STATE/no-namespace"
"$CLI" set "$TOKEN" >/dev/null 2>&1
assert_equals "no namespace yet: local save still succeeds" "$?" 0
assert_not_contains "no namespace yet: no Secret" "$(cat "$CALLS")" "create"

## The gateway's message points here

MAIN="$LLMAPI_DIR/gateway/main.py"
assert_contains "409 message names this command" "$(cat "$MAIN")" "scripts/apps/llmapi/lib/hf-token.sh set"
if [ -x "$CLI" ]; then pass "the command is executable"; else fail "the command is executable"; fi

## The installer

INSTALL=$(cat "$LLMAPI_DIR/install-llmapi.sh")
assert_not_contains "installer: no secret on a command line" "$INSTALL" "--from-literal"
assert_contains "installer: uses the stdin path" "$INSTALL" 'write_hf_secret "$HF_TOKEN" "$NAMESPACE"'
assert_not_contains "installer: prompt doesn't echo the token" "$INSTALL" 'read -p "Enter HuggingFace token'
UNGUARDED=$(awk '
    /write_hf_secret "\$HF_TOKEN"/ && prev !~ /if \[ -n "\$HF_TOKEN" \]/ && prev2 !~ /if \[ -n "\$HF_TOKEN" \]/ { print FILENAME ":" NR }
    { prev2 = prev; prev = $0 }
' "$LLMAPI_DIR/install-llmapi.sh")
assert_equals "installer: Secret only written under a non-empty token check" "$UNGUARDED" ""
if grep -rlE '^\s*name: hf-token\s*$' "$LLMAPI_DIR/manifests" >/dev/null; then
    # Every mention must be a reference. A manifest creating it would make it non-absent.
    python3 - "$LLMAPI_DIR/manifests" <<'PY'
import pathlib
import sys

import yaml

for path in pathlib.Path(sys.argv[1]).glob("*.yaml"):
    for doc in yaml.safe_load_all(path.read_text()):
        if doc and doc.get("kind") == "Secret" and doc["metadata"]["name"] == "hf-token":
            sys.exit(f"{path} creates Secret hf-token")
PY
    assert_equals "no manifest creates Secret hf-token" "$?" 0
fi

## RBAC and the pod references

RESULT=$(python3 - "$LLMAPI_DIR/manifests" <<'PY'
import pathlib
import sys

import yaml

manifests = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all((manifests / "gateway-rbac.yaml").read_text()) if d]
rules = [
    (d["kind"], d["metadata"]["name"], rule)
    for d in docs if d["kind"] in ("Role", "ClusterRole")
    for rule in d["rules"]
]
secret_rules = [r for r in rules if "secrets" in r[2].get("resources", [])]
expected = {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["hf-token"], "verbs": ["patch"]}
print("exact-rule", secret_rules == [("Role", "gateway-backend-manager", expected)])
print("no-wildcards", not any("*" in r[2].get(f, []) for r in rules for f in ("apiGroups", "resources", "verbs")))

# Every reference optional, so a missing Secret leaves HF_TOKEN unset and the pod runs.
def walk(node):
    if isinstance(node, dict):
        ref = node.get("secretKeyRef")
        if ref and ref.get("name") == "hf-token":
            yield ref
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)

refs = [ref for path in manifests.glob("*.yaml") for doc in yaml.safe_load_all(path.read_text()) for ref in walk(doc)]
print("refs-found", len(refs) > 0)
print("refs-optional", all(ref.get("optional") is True for ref in refs))
PY
)
assert_contains "RBAC: the one Secret rule is exactly patch on hf-token" "$RESULT" "exact-rule True"
assert_contains "RBAC: no wildcards" "$RESULT" "no-wildcards True"
assert_contains "pods: reference the Secret" "$RESULT" "refs-found True"
assert_contains "pods: every reference is optional" "$RESULT" "refs-optional True"

finish
