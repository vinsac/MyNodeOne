#!/bin/bash
#
# Test helpers. Every test runs against stubs on PATH (kubectl, helm, kompose, sudo,
# docker, systemctl, sleep), so nothing here can touch a real cluster or machine.
# The script under test is copied into a temporary tree, which also keeps the real
# service-registry and DNS scripts out of reach.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  ok   - $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL - $1"; }

assert_eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

assert_contains() { # name needle file
    if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi
}

assert_not_contains() { # name needle file
    if grep -qF -- "$2" "$3"; then fail "$1 (found '$2' in $3)"; else pass "$1"; fi
}

finish() {
    echo ""
    echo "$PASSED passed, $FAILED failed"
    [[ $FAILED -eq 0 ]]
}

# new_sandbox: create $SANDBOX with stubs in $SANDBOX/bin, and a project tree holding
# only the library that locates the project root.
new_sandbox() {
    SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/mynodeone-test.XXXXXX")
    SANDBOXES+=("$SANDBOX")
    mkdir -p "$SANDBOX/bin" "$SANDBOX/captured" "$SANDBOX/tmp" "$SANDBOX/scripts/lib"
    cp "$REPO_ROOT/scripts/lib/project-root.sh" "$SANDBOX/scripts/lib/"
    cp "$TESTS_DIR/stubs/"* "$SANDBOX/bin/"
    chmod +x "$SANDBOX/bin/"*
    export STUB_LOG="$SANDBOX/calls.log"
    export STUB_CAPTURE="$SANDBOX/captured"
    export STUB_STATE="$SANDBOX/state"
    mkdir -p "$STUB_STATE"
    : > "$STUB_LOG"
}

SANDBOXES=()
cleanup_sandboxes() {
    local dir
    for dir in "${SANDBOXES[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup_sandboxes EXIT
