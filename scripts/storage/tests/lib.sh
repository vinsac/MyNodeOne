#!/bin/bash

# Shared harness for the storage tests.
#
# Every test command runs with PATH set to a sandbox directory holding only stubs
# and a short list of harmless text tools. No system directory is on that PATH, so
# a real wipefs, mkfs, kubectl or sudo can't be reached, and setup_sandbox aborts
# before anything runs unless each stub is what the name resolves to.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures"
REAL_BASH="$(command -v bash)"
REAL_PYTHON="$(command -v python3)"

# Harmless tools the code under test needs.
ALLOWED_TOOLS=(awk sed grep cat basename dirname tr sort cut head tail date mktemp uniq wc numfmt jq base64 id env ls)

# Everything that could change a machine or a cluster. All are stubs.
STUBBED_TOOLS=(
    wipefs mkfs mkfs.ext4 mkfs.xfs parted umount mount dd sgdisk fdisk
    kubectl helm velero sudo ssh systemctl
    mkdir tee chattr chmod chown mountpoint sleep udevadm test
    lsblk findmnt blkid swapon readlink rm mv whoami curl wget
)

PASSED=0
FAILED=0

pass() {
    PASSED=$((PASSED + 1))
    echo "ok    $1"
}

fail() {
    FAILED=$((FAILED + 1))
    echo "FAIL  $1"
    if [[ -n "${2:-}" ]]; then
        printf '%s\n' "$2" | "$REAL_SED" 's/^/      | /'
    fi
}

finish() {
    echo
    echo "$PASSED passed, $FAILED failed"
    "$REAL_RM" -rf "$WORK"
    [[ "$FAILED" -eq 0 ]]
}

write_stub() {
    local name="$1" body="$2"
    {
        echo "#!$REAL_BASH"
        printf '%s\n' "$body"
    } > "$BIN/$name"
    "$REAL_CHMOD" +x "$BIN/$name"
}

# Stubs of write commands record their call, and do nothing else.
recording_stub() {
    write_stub "$1" "printf '%s\\n' \"$1 \$*\" >> \"\$CALLS\"
exit 0"
}

setup_sandbox() {
    REAL_RM="$(command -v rm)"
    REAL_CHMOD="$(command -v chmod)"
    REAL_SED="$(command -v sed)"
    REAL_LN="$(command -v ln)"
    local real_mkdir real_mktemp
    real_mkdir="$(command -v mkdir)"
    real_mktemp="$(command -v mktemp)"

    WORK="$("$real_mktemp" -d "${TMPDIR:-/tmp}/storage-tests.XXXXXX")"
    BIN="$WORK/bin"
    CALLS="$WORK/calls.log"
    FAKE_STATE="$WORK/state"
    FAKE_FIXTURE="$WORK/fixture.json"
    FAKE_SCENARIO="$WORK/scenario.json"
    FAKE_CLI_LOG="$WORK/cli.log"
    FAKE_STDIN_LOG="$WORK/stdin.log"
    "$real_mkdir" -p "$BIN" "$FAKE_STATE" "$WORK/home"
    : > "$CALLS"
    : > "$FAKE_CLI_LOG"
    : > "$FAKE_STDIN_LOG"
    echo '{}' > "$FAKE_SCENARIO"
    export WORK CALLS FAKE_STATE FAKE_FIXTURE FAKE_SCENARIO FAKE_CLI_LOG FAKE_STDIN_LOG

    local tool
    for tool in "${ALLOWED_TOOLS[@]}"; do
        local target
        target="$(command -v "$tool" || true)"
        if [[ -z "$target" ]]; then
            echo "Missing tool for the tests: $tool" >&2
            exit 2
        fi
        "$REAL_LN" -s "$target" "$BIN/$tool"
    done

    for tool in "${STUBBED_TOOLS[@]}"; do
        recording_stub "$tool"
    done

    for tool in lsblk findmnt blkid swapon readlink; do
        write_stub "$tool" "exec \"$REAL_PYTHON\" -I \"$TESTS_DIR/fake_blockdev.py\" $tool \"\$@\""
    done
    for tool in kubectl velero; do
        write_stub "$tool" "exec \"$REAL_PYTHON\" -I \"$TESTS_DIR/fake_cli.py\" $tool \"\$@\""
    done

    write_stub wipefs 'printf "%s\n" "wipefs $*" >> "$CALLS"
exit "${STUB_WIPEFS_RC:-0}"'

    # Leaves a marker so the fake lsblk shows the new partition.
    write_stub parted 'printf "%s\n" "parted $*" >> "$CALLS"
for arg in "$@"; do
    case "$arg" in
        /dev/*) : > "$FAKE_STATE/partitioned-${arg##*/}" ;;
    esac
done
exit 0'

    write_stub test 'printf "%s\n" "test $*" >> "$CALLS"
exit "${STUB_TEST_RC:-0}"'
    write_stub mountpoint 'exit "${STUB_MOUNTPOINT_RC:-0}"'
    write_stub sleep 'exit 0'
    write_stub whoami 'echo testuser'
    write_stub tee 'printf "%s\n" "tee $*" >> "$CALLS"
cat >> "$WORK/tee.out"'

    # Runs what follows on the sandbox PATH. A shell script is recorded and kept,
    # never run, and absolute paths are refused because they'd escape the sandbox.
    write_stub sudo 'if [[ "${1:-}" == "-v" ]]; then
    exit 0
fi
if [[ "${1:-}" == "bash" ]]; then
    printf "%s\n" "sudo $*" >> "$CALLS"
    cat > "$WORK/sudo-bash-stdin.sh"
    exit 0
fi
if [[ "${1:-}" == /* ]]; then
    printf "%s\n" "REFUSED sudo $*" >> "$CALLS"
    exit 127
fi
exec "$@"'

    # Reads stdin like the real ssh does, which is what shows a prompt answer being lost.
    write_stub ssh 'printf "%s\n" "ssh $*" >> "$CALLS"
shift
if [[ -t 0 ]]; then
    printf "%s\n" "SSH_READ_TERMINAL" >> "$CALLS"
fi
if [[ "${1:-}" == "sudo" ]]; then
    exec "$@"
fi
exit 127'

    assert_sandbox_shadows
}

# Stops the whole run unless every tool resolves inside the sandbox.
assert_sandbox_shadows() {
    local tool resolved
    for tool in "${STUBBED_TOOLS[@]}" "${ALLOWED_TOOLS[@]}"; do
        resolved="$(PATH="$BIN" type -P "$tool")"
        if [[ "$resolved" != "$BIN/$tool" ]]; then
            echo "ABORT: $tool resolves to '$resolved', not the sandbox. Nothing was run." >&2
            exit 2
        fi
    done
    for tool in "${STUBBED_TOOLS[@]}"; do
        if [[ -L "$BIN/$tool" ]]; then
            echo "ABORT: $tool is a link to a real binary. Nothing was run." >&2
            exit 2
        fi
    done
}

# Forgets what earlier tests did.
reset_state() {
    : > "$CALLS"
    : > "$FAKE_CLI_LOG"
    : > "$FAKE_STDIN_LOG"
    "$REAL_RM" -f "$FAKE_STATE"/partitioned-* "$WORK/sudo-bash-stdin.sh" "$WORK/tee.out"
}

use_fixture() {
    "$BIN/cat" "$FIXTURES/$1.json" > "$FAKE_FIXTURE"
}

# sandbox_bash SCRIPT: runs a script with no terminal on stdin. Output goes to OUT.
sandbox_bash() {
    OUT="$(env -i PATH="$BIN" HOME="$WORK/home" WORK="$WORK" CALLS="$CALLS" FAKE_STATE="$FAKE_STATE" \
        FAKE_FIXTURE="$FAKE_FIXTURE" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CLI_LOG="$FAKE_CLI_LOG" \
        FAKE_STDIN_LOG="$FAKE_STDIN_LOG" STUB_WIPEFS_RC="${STUB_WIPEFS_RC:-0}" \
        STUB_TEST_RC="${STUB_TEST_RC:-0}" STUB_MOUNTPOINT_RC="${STUB_MOUNTPOINT_RC:-0}" \
        DISK_SAFETY_CRYPTTAB="$WORK/crypttab" \
        REPO_ROOT="$REPO_ROOT" "$REAL_BASH" -c "$1" 2>&1 </dev/null)"
    RC=$?
}

# sandbox_pty "line1|line2" SCRIPT: runs a script with a terminal on stdin.
sandbox_pty() {
    local inputs="$1" script="$2"
    local -a args=()
    local line
    if [[ -n "$inputs" ]]; then
        while IFS= read -r line; do
            args+=(--input "$line")
        done < <(printf '%s\n' "$inputs" | "$BIN/tr" '|' '\n')
    fi
    OUT="$(env -i PATH="$BIN" HOME="$WORK/home" WORK="$WORK" CALLS="$CALLS" FAKE_STATE="$FAKE_STATE" \
        FAKE_FIXTURE="$FAKE_FIXTURE" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CLI_LOG="$FAKE_CLI_LOG" \
        FAKE_STDIN_LOG="$FAKE_STDIN_LOG" STUB_WIPEFS_RC="${STUB_WIPEFS_RC:-0}" \
        STUB_TEST_RC="${STUB_TEST_RC:-0}" STUB_MOUNTPOINT_RC="${STUB_MOUNTPOINT_RC:-0}" \
        DISK_SAFETY_CRYPTTAB="$WORK/crypttab" REPO_ROOT="$REPO_ROOT" \
        "$REAL_PYTHON" -I "$TESTS_DIR/pty_run.py" "${args[@]}" --timeout 60 -- \
        "$REAL_BASH" -c "$script" 2>&1)"
    RC=$?
}

expect_rc() {
    local name="$1" want="$2"
    if [[ "$RC" -eq "$want" ]]; then
        pass "$name: exit $want"
    else
        fail "$name: expected exit $want, got $RC" "$OUT"
    fi
}

expect_rc_nonzero() {
    if [[ "$RC" -ne 0 ]]; then
        pass "$1: exit non-zero ($RC)"
    else
        fail "$1: expected a non-zero exit" "$OUT"
    fi
}

expect_output() {
    local name="$1" pattern="$2"
    if printf '%s\n' "$OUT" | "$BIN/grep" -qE -- "$pattern"; then
        pass "$name: output has /$pattern/"
    else
        fail "$name: output lacks /$pattern/" "$OUT"
    fi
}

expect_no_output() {
    local name="$1" pattern="$2"
    if printf '%s\n' "$OUT" | "$BIN/grep" -qE -- "$pattern"; then
        fail "$name: output has unwanted /$pattern/" "$OUT"
    else
        pass "$name: output lacks /$pattern/"
    fi
}

# Asserted from the call log, not from what the script printed.
expect_no_writes() {
    local name="$1" found
    found="$("$BIN/grep" -E '^(wipefs|mkfs|mkfs\.[a-z0-9]+|parted|mount|umount|dd|sgdisk|fdisk|chattr|chown|tee|sudo bash) ?' "$CALLS" || true)"
    if [[ -n "$found" ]]; then
        fail "$name: disk writes were called" "$found"
    else
        pass "$name: no disk write in the log"
    fi
}

expect_log() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$CALLS"; then
        pass "$name: log has /$pattern/"
    else
        fail "$name: log lacks /$pattern/" "$("$BIN/cat" "$CALLS")"
    fi
}
