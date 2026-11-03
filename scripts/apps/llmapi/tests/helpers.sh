#!/bin/bash
# Shared by the tests in this directory. Every test runs against stubs, and start_sandbox
# refuses to continue unless the stubs really shadow the real binaries.

LLMAPI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0

# Usage: start_sandbox <command to stub>...
# Each command needs a stub in $SANDBOX/bin, which the test writes with write_stub. Until
# then, these commands fail rather than reach the real one.
start_sandbox() {
    SANDBOX=$(mktemp -d)
    trap 'rm -rf "$SANDBOX"' EXIT
    mkdir -p "$SANDBOX/bin"
    CALLS="$SANDBOX/calls.log"
    : >"$CALLS"
    PATH="$SANDBOX/bin:$PATH"
    export PATH SANDBOX CALLS
    hash -r
    local name
    for name in kubectl helm sudo systemctl "$@"; do
        write_stub "$name" 'echo "unexpected call: '"$name"' $*" >>"$CALLS"; exit 127'
        if [ "$(command -v "$name")" != "$SANDBOX/bin/$name" ]; then
            echo "ABORT: stub for $name does not shadow the real command" >&2
            exit 2
        fi
    done
}

write_stub() {
    printf '#!/bin/bash\n%s\n' "$2" >"$SANDBOX/bin/$1"
    # command -p: a test may stub chmod itself.
    command -p chmod +x "$SANDBOX/bin/$1"
    hash -r
}

pass() {
    PASSED=$((PASSED + 1))
    echo "ok   - $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "FAIL - $1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/       /'
    fi
}

# Usage: assert_contains <description> <haystack> <needle>
assert_contains() {
    if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1" "expected to find: $3
in: $2"; fi
}

assert_not_contains() {
    if grep -qF -- "$3" <<<"$2"; then fail "$1" "did not expect: $3
in: $2"; else pass "$1"; fi
}

assert_equals() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $3
got: $2"; fi
}

finish() {
    echo ""
    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}
