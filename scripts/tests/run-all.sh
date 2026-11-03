#!/bin/bash
###############################################################################
# Runs the repo's test suites and lint checks. CI calls this same script, one suite at
# a time, so a green local run and a green CI job mean the same thing.
#
#   scripts/tests/run-all.sh              # everything
#   scripts/tests/run-all.sh routing go   # just these
#   scripts/tests/run-all.sh --list
#
# A suite that needs a missing tool shows SKIP in the summary with the reason. Under CI
# (CI=true, which GitHub Actions sets) that counts as a failure, so a tool that goes
# missing there can't silently take its tests with it. Exits non-zero if anything failed.
#
# Getting the tools, in a directory outside the repo:
#   scripts/tests/ci/install-tools.sh DIR                  # gitleaks, helm, promtool...
#   python3 -m venv VENV && VENV/bin/pip install --require-hashes \
#       -r scripts/tests/ci/requirements-ci.txt            # shellcheck, ruff, PyYAML
#   python3.11 -m venv GW && GW/bin/pip install --require-hashes \
#       -r scripts/apps/llmapi/gateway/requirements.lock
#   GW/bin/pip install --require-hashes \
#       -r scripts/apps/llmapi/gateway/requirements-dev.lock
#
# then point this at them, or put them on PATH:
#   CI_TOOLS_DIR    extra directory searched for tools (DIR above)
#   CI_VENV         a venv with requirements-ci.txt (VENV above)
#   GATEWAY_PYTHON  a Python with the gateway's lock and dev lock (GW/bin/python above)
#   GO_BIN          the go binary (otherwise PATH, then /usr/local/go/bin/go)
#   SUITE_TIMEOUT   seconds any one suite may take (default 1200)
###############################################################################

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GATEWAY="$REPO/scripts/apps/llmapi/gateway"
SKIP=77

ALL_SUITES=(
    gateway-deps gateway-tests gateway-lint
    go
    bash-syntax shellcheck
    routing storage llmapi external-apps bootstrap cleanup
    manifests workflows secrets
)

if [[ -n "${CI_TOOLS_DIR:-}" ]]; then
    PATH="$CI_TOOLS_DIR:$PATH"
fi
if [[ -n "${CI_VENV:-}" ]]; then
    PATH="$CI_VENV/bin:$PATH"
fi
export PATH


skip() {
    echo "SKIP: $*"
    exit "$SKIP"
}

need() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || skip "$tool is not installed"
    done
}

# PyYAML is what most checks here need from Python.
need_python_yaml() {
    need python3
    python3 -c 'import yaml' 2>/dev/null || skip "python3 here has no PyYAML (set CI_VENV, or pip install PyYAML)"
}

find_go() {
    local candidate
    for candidate in "${GO_BIN:-}" "$(command -v go 2>/dev/null)" /usr/local/go/bin/go; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# The gateway's Python: GATEWAY_PYTHON, then a venv in the gateway directory, then
# python3 if it has what's needed.
find_gateway_python() {
    local candidate
    for candidate in "${GATEWAY_PYTHON:-}" "$GATEWAY/.venv/bin/python" "$(command -v python3 2>/dev/null)"; do
        if [[ -n "$candidate" && -x "$candidate" ]] &&
            "$candidate" -c 'import fastapi, kubernetes' 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Runs each test file, carrying on past a failure so all of them report.
run_each() {
    local status=0 test_file
    for test_file in "$@"; do
        echo "=== ${test_file#"$REPO"/}"
        bash "$test_file" || status=1
    done
    return "$status"
}

suite_gateway_deps() {
    local python
    python="$(find_gateway_python)" || skip "no Python with the gateway's dependencies (set GATEWAY_PYTHON)"
    PYTHONDONTWRITEBYTECODE=1 "$python" "$HERE/ci/check-gateway-deps.py"
}

suite_gateway_tests() {
    local python log status
    python="$(find_gateway_python)" || skip "no Python with the gateway's dependencies (set GATEWAY_PYTHON)"
    "$python" -c 'import pytest, pytest_timeout' 2>/dev/null ||
        skip "$python has no pytest or pytest-timeout (install requirements-dev.lock)"
    log="$(mktemp "${TMPDIR:-/tmp}/gateway-tests.XXXXXX")"
    (cd "$GATEWAY" && PYTHONDONTWRITEBYTECODE=1 "$python" -m pytest tests -p no:cacheprovider -q -rs) 2>&1 | tee "$log"
    status="${PIPESTATUS[0]}"
    # Postgres and the browser tests skip without their optional dependencies, and
    # then the job would be green without having run them.
    if [[ "$status" == 0 && -n "${CI:-}" ]] && grep -qE '^[0-9]+ passed.* skipped' "$log"; then
        echo "FAIL: CI requires the gateway's optional tests to run, and some skipped"
        status=1
    fi
    rm -f "$log"
    return "$status"
}

suite_gateway_lint() {
    need python3 ruff
    python3 "$HERE/ci/ratchet.py" ruff check
}

suite_go() {
    local go status=0 unformatted
    go="$(find_go)" || skip "go not found on PATH or at /usr/local/go/bin/go (set GO_BIN)"
    cd "$REPO" || return 1
    "$go" version
    echo "--- go build"
    "$go" build -o /dev/null ./... || status=1
    echo "--- go vet"
    "$go" vet ./... || status=1
    echo "--- gofmt -l"
    unformatted="$("$HERE/ci/tracked-files.sh" '*.go' | xargs "$(dirname "$go")/gofmt" -l)" || status=1
    if [[ -n "$unformatted" ]]; then
        echo "not gofmt-formatted:"
        echo "$unformatted"
        status=1
    fi
    if [[ "$("$go" env CGO_ENABLED)" == 1 ]] && command -v "$("$go" env CC)" >/dev/null 2>&1; then
        echo "--- go test -race"
        "$go" test -race -count=1 ./... || status=1
    elif [[ -n "${CI:-}" ]]; then
        echo "FAIL: CI requires the race detector, which needs cgo and a C compiler"
        status=1
    else
        echo "--- SKIP: -race needs cgo and a C compiler; running go test without it"
        "$go" test -count=1 ./... || status=1
    fi
    return "$status"
}

suite_bash_syntax() {
    local count=0 failed=0 file
    cd "$REPO" || return 1
    while IFS= read -r file; do
        count=$((count + 1))
        bash -n "$file" || failed=$((failed + 1))
    done < <("$HERE/ci/tracked-files.sh" '*.sh')
    echo "bash -n: $count files, $failed failed"
    ((failed == 0))
}

suite_shellcheck() {
    need python3 shellcheck
    python3 "$HERE/ci/ratchet.py" shellcheck check
}

suite_routing() {
    local go
    if go="$(find_go)"; then
        export GO_BIN="$go"
    else
        skip "go not found, and the routing tests build their fixtures with it (set GO_BIN)"
    fi
    git -C "$REPO" cat-file -e 3461b65 2>/dev/null ||
        skip "commit 3461b65 is missing, and the old-client tests run it: this clone is too shallow"
    bash "$REPO/scripts/tests/routing/run-tests.sh"
}

suite_storage() {
    need_python_yaml
    need jq
    bash "$REPO/scripts/storage/tests/run-all.sh"
}

suite_llmapi() {
    need_python_yaml
    need jq
    run_each "$REPO"/scripts/apps/llmapi/tests/test-*.sh
}

suite_external_apps() {
    local status=0
    need node jq
    run_each "$REPO"/external-apps/tests/test-*.sh || status=1
    echo "=== external-apps/tests/test-website-xss.js"
    node "$REPO/external-apps/tests/test-website-xss.js" || status=1
    return "$status"
}

suite_bootstrap() {
    need_python_yaml
    bash "$REPO/scripts/tests/bootstrap/run-tests.sh"
}

suite_cleanup() {
    bash "$REPO/scripts/tests/cleanup/run-tests.sh"
}

suite_manifests() {
    need_python_yaml
    python3 "$HERE/ci/check-yaml.py"
}

suite_workflows() {
    need actionlint
    cd "$REPO" || return 1
    actionlint -color=false .github/workflows/*.yml && echo "actionlint: no findings"
}

# Scans a copy holding only what a commit would contain, as a clean checkout would see
# it: ignored local files can't fail this, and agent worktrees don't get scanned.
suite_secrets() {
    local tree status
    need gitleaks tar
    tree="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-tree.XXXXXX")"
    (
        cd "$REPO" || exit 1
        "$HERE/ci/tracked-files.sh" . | tar -cf - -T - | tar -xf - -C "$tree"
    ) || {
        rm -rf "$tree"
        return 1
    }
    (
        cd "$tree" || exit 1
        gitleaks dir . --no-banner --redact --config scripts/tests/ci/gitleaks.toml \
            --gitleaks-ignore-path scripts/tests/ci/gitleaksignore
    )
    status=$?
    rm -rf "$tree"
    return "$status"
}

run_one() {
    local suite="${1//-/_}"
    "suite_$suite"
}

if [[ "${1:-}" == "--run-one" ]]; then
    run_one "$2"
    exit $?
fi

if [[ "${1:-}" == "--list" ]]; then
    printf '%s\n' "${ALL_SUITES[@]}"
    exit 0
fi

if [[ $# -eq 0 ]]; then
    set -- "${ALL_SUITES[@]}"
fi
for suite in "$@"; do
    if ! printf '%s\n' "${ALL_SUITES[@]}" | grep -qxF -- "$suite"; then
        echo "Unknown suite: $suite (try --list)" >&2
        exit 2
    fi
done

SUMMARY=()
FAILED=0
LOG="$(mktemp "${TMPDIR:-/tmp}/run-all.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

# Adds up every suite's "N passed, M failed" lines, and pytest's and bootstrap's forms.
counts_from_log() {
    sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" | awk '
        /^[[:space:]]*[0-9]+ passed, [0-9]+ failed[[:space:]]*$/ { passed += $1; failed += $3; found = 1 }
        /^bootstrap: [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped/ { passed += $2; failed += $4; skipped += $6; found = 1 }
        /^[0-9]+ (passed|failed).* in [0-9.]+s/ {
            for (i = 2; i <= NF; i++) {
                word = $i; gsub(/,/, "", word)
                if (word == "passed") passed += $(i-1)
                if (word == "failed") failed += $(i-1)
                if (word == "skipped") skipped += $(i-1)
                if (word == "error" || word == "errors") failed += $(i-1)
            }
            found = 1
        }
        /^ok[[:space:]]+[^[:space:]]+[[:space:]]+[0-9.]+s$/ { packages++ }
        /^(yaml|kubeconform|bash -n|gateway dependencies|shellcheck|ruff|actionlint):/ { line = $0 }
        /no leaks found/ { line = "gitleaks: no leaks found" }
        END {
            if (found) printf "%d passed, %d failed, %d skipped", passed, failed, skipped
            else if (packages) printf "%d Go packages passed", packages
            else if (line) print line
        }'
}

for suite in "$@"; do
    echo
    echo "################################################################################"
    echo "# $suite"
    echo "################################################################################"
    started=$SECONDS
    timeout "${SUITE_TIMEOUT:-1200}" bash "${BASH_SOURCE[0]}" --run-one "$suite" 2>&1 | tee "$LOG"
    status="${PIPESTATUS[0]}"
    elapsed=$((SECONDS - started))
    detail="$(counts_from_log)"
    reason="$(grep -m1 '^SKIP: ' "$LOG" | sed 's/^SKIP: //')"
    if [[ "$status" == "$SKIP" ]]; then
        if [[ -n "${CI:-}" ]]; then
            result="FAIL"
            detail="CI requires this suite: $reason"
            FAILED=1
        else
            result="SKIP"
            detail="$reason"
        fi
    elif [[ "$status" == 0 ]]; then
        result="ok"
    elif [[ "$status" == 124 ]]; then
        result="FAIL"
        detail="timed out after ${SUITE_TIMEOUT:-1200}s"
        FAILED=1
    else
        result="FAIL"
        FAILED=1
    fi
    SUMMARY+=("$(printf '%-5s %-14s %5ss  %s' "$result" "$suite" "$elapsed" "$detail")")
done

echo
echo "################################################################################"
echo "# Summary"
echo "################################################################################"
printf '%s\n' "${SUMMARY[@]}"
exit "$FAILED"
