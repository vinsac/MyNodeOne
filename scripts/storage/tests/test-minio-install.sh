#!/bin/bash

# Reinstalling MinIO over an existing one: install-minio.sh run end to end against a fake
# kubectl. Each case stops at `kubectl wait`, once every manifest has been applied.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

SCRIPT="$REPO_ROOT/scripts/storage/minio/install-minio.sh"
NS=minio-node1

# Not disk or cluster tools, but they aren't on the sandbox PATH either.
write_stub df 'echo "1B-blocks"; echo "500G"'
write_stub openssl 'echo "GENERATEDpasswordGENERATEDpassword"'
write_stub nl 'cat'
write_stub stat 'exit 1'
write_stub hostname 'echo node1'
write_stub getent 'exit 2'

# Old credentials, as they'd come back from the cluster. One has characters a sed would trip on.
OLD_USER=keeper
OLD_PASSWORD='old/pass&word|x'
OLD_USER_B64=$(printf '%s' "$OLD_USER" | base64 -w0)
OLD_PASSWORD_B64=$(printf '%s' "$OLD_PASSWORD" | base64 -w0)

# write_cluster NAMESPACE_EXISTS PV_PATH [USER_B64] [PASSWORD_B64]
write_cluster() {
    local ns_rc=1
    [[ "$1" == yes ]] && ns_rc=0
    jq -n --argjson ns_rc "$ns_rc" --arg pv "$2" --arg user "${3-$OLD_USER_B64}" --arg pw "${4-$OLD_PASSWORD_B64}" '{kubectl: [
      {match: "^get nodes$", stdout: "node1 Ready"},
      {match: "get nodes -o custom-columns", stdout: "node1 Ready worker\n"},
      {match: "get nodes -o jsonpath", stdout: "node1"},
      {match: "get node node1", stdout: "node/node1"},
      {match: "get configmap -n kube-system cluster-info", stdout: "mynodeone"},
      {match: "get namespace minio-node1", rc: $ns_rc},
      {match: "get pv minio-data-node1 -o jsonpath=\\{.spec.hostPath.path\\}", stdout: $pv},
      {match: "get pv minio-data-node1 -o jsonpath=\\{.status.phase\\}", stdout: "Released"},
      {match: "get secret minio-credentials -n minio-node1 -o jsonpath=\\{.data.rootUser\\}", stdout: $user},
      {match: "get secret minio-credentials -n minio-node1 -o jsonpath=\\{.data.rootPassword\\}", stdout: $pw},
      {match: "delete namespace minio-node1"},
      {match: "patch pv"},
      {match: "apply -f -"},
      {match: "wait --for=condition=ready", rc: 9}
    ]}' > "$FAKE_SCENARIO"
}

run_install() {
    local input="$1"
    shift
    sandbox_pty "$input" "${*:+export $*;} source '$SCRIPT'"
}

expect_cli() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$FAKE_CLI_LOG"; then
        pass "$name: called /$pattern/"
    else
        fail "$name: no call matching /$pattern/" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    fi
}

expect_cluster_untouched() {
    local name="$1" found
    found="$("$BIN/grep" -E ' delete | patch | apply ' "$FAKE_CLI_LOG" || true)"
    if [[ -z "$found" ]]; then
        pass "$name: nothing changed in the cluster"
    else
        fail "$name: changed the cluster" "$found"
    fi
}

expect_node_untouched() {
    local name="$1" found
    found="$("$BIN/grep" -E '^(mkdir|chmod|chown|wipefs|mkfs|parted|mount) ' "$CALLS" || true)"
    if [[ -z "$found" ]]; then
        pass "$name: nothing changed on the node"
    else
        fail "$name: changed the node" "$found"
    fi
}

# The line number of the first call matching a pattern, or 0.
line_of() {
    local n
    n="$("$BIN/grep" -nE -- "$1" "$FAKE_CLI_LOG" | "$BIN/head" -1 | "$BIN/cut" -d: -f1)"
    echo "${n:-0}"
}

expect_secret() {
    local name="$1" user="$2" password="$3"
    if "$BIN/grep" -q "rootUser: $user\$" "$FAKE_STDIN_LOG" && "$BIN/grep" -q "rootPassword: $password\$" "$FAKE_STDIN_LOG"; then
        pass "$name: Secret has those credentials"
    else
        fail "$name: Secret has other credentials" "$("$BIN/grep" -E 'rootUser|rootPassword' "$FAKE_STDIN_LOG" || true)"
    fi
    if "$BIN/grep" -q PLACEHOLDER "$FAKE_STDIN_LOG"; then
        fail "$name: a placeholder was left in" "$("$BIN/grep" PLACEHOLDER "$FAKE_STDIN_LOG")"
    else
        pass "$name: no placeholder left"
    fi
}

expect_no_secret_on_argv() {
    local name="$1" pattern
    for pattern in "$OLD_PASSWORD" "$OLD_PASSWORD_B64" GENERATEDpassword; do
        if "$BIN/grep" -qF -- " $pattern" "$CALLS" || "$BIN/grep" -E '(apply|create) ' "$FAKE_CLI_LOG" | "$BIN/grep" -qF -- "$pattern"; then
            fail "$name: a password was on a command line"
            return
        fi
    done
    pass "$name: no password on a command line"
}

fixture() {
    reset_state
    use_fixture data-disks
}

echo "--- Existing path, same PV path: data and credentials are both kept"

fixture
write_cluster yes /mnt/minio
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "reinstall on the same path" 1
expect_output "reinstall on the same path" 'MinIO pod failed to become ready'
expect_output "reinstall on the same path" 'Keeping the existing root credentials'
expect_cli "reinstall on the same path" "delete namespace $NS"
expect_secret "reinstall on the same path" "$OLD_USER_B64" "$OLD_PASSWORD_B64"
expect_no_secret_on_argv "reinstall on the same path"
expect_no_output "reinstall on the same path" 'Generating credentials'
if "$BIN/grep" -q '^mkfs\|^wipefs\|^parted' "$CALLS"; then
    fail "reinstall on the same path: formatted something" "$("$BIN/cat" "$CALLS")"
else
    pass "reinstall on the same path: nothing formatted"
fi
read_at=$(line_of 'get secret minio-credentials .*rootPassword')
pv_at=$(line_of 'get pv minio-data-node1 -o jsonpath=\{.spec.hostPath')
delete_at=$(line_of "delete namespace $NS")
if [[ "$read_at" -gt 0 && "$pv_at" -gt 0 && "$read_at" -lt "$delete_at" && "$pv_at" -lt "$delete_at" ]]; then
    pass "reinstall on the same path: read the PV and password before deleting"
else
    fail "reinstall on the same path: order was pv $pv_at, password $read_at, delete $delete_at" "$("$BIN/cat" "$FAKE_CLI_LOG")"
fi
if ! "$BIN/grep" -q "$OLD_PASSWORD" <<<"$OUT"; then
    pass "reinstall on the same path: password not printed while reinstalling"
else
    fail "reinstall on the same path: password printed" "$OUT"
fi

fixture
write_cluster yes /mnt/minio/
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_cli "a trailing slash on the PV is the same path" "delete namespace $NS"

echo
echo "--- A PV at another path can't be changed, so nothing starts"

# This was the trap: namespace gone first, then the PV apply refused.
fixture
write_cluster yes /mnt/old-disk
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "existing path, PV elsewhere" 1
expect_cluster_untouched "existing path, PV elsewhere"
expect_node_untouched "existing path, PV elsewhere"
expect_output "existing path, PV elsewhere" 'points at /mnt/old-disk'
expect_output "existing path, PV elsewhere" 'MINIO_EXISTING_PATH=/mnt/old-disk'
expect_output "existing path, PV elsewhere" "kubectl delete pv minio-data-node1"
expect_output "existing path, PV elsewhere" 'configure-backup.sh'

# Choosing the OS folder has the same problem.
fixture
write_cluster yes /mnt/minio
run_install "1|0|$NS"
expect_rc "OS folder, PV elsewhere" 1
expect_cluster_untouched "OS folder, PV elsewhere"
expect_node_untouched "OS folder, PV elsewhere"
expect_output "OS folder, PV elsewhere" 'points at /mnt/minio'

# A namespace already gone leaves the PV behind, at its old path.
fixture
write_cluster no /mnt/old-disk
run_install "1" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "no namespace, PV elsewhere" 1
expect_cluster_untouched "no namespace, PV elsewhere"

# And a disk must not be formatted for an install that can't work.
fixture
write_cluster yes /mnt/old-disk
run_install "1|1|/dev/sdc|$NS"
expect_rc "new disk, PV elsewhere" 1
expect_cluster_untouched "new disk, PV elsewhere"
expect_node_untouched "new disk, PV elsewhere"

echo
echo "--- Credentials that can't be read mean nothing is deleted"

fixture
write_cluster yes /mnt/minio "$OLD_USER_B64" ""
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "no password in the Secret" 1
expect_cluster_untouched "no password in the Secret"
expect_output "no password in the Secret" 'Could not read the existing credentials'

fixture
write_cluster yes /mnt/minio "" "$OLD_PASSWORD_B64"
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "no user in the Secret" 1
expect_cluster_untouched "no user in the Secret"

fixture
write_cluster yes /mnt/minio "$OLD_USER_B64" "@@not-base64@@"
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "a corrupt password" 1
expect_cluster_untouched "a corrupt password"
expect_output "a corrupt password" 'not valid'

# kubectl failing is not the same as there being no PV.
fixture
write_cluster yes /mnt/minio
jq '.kubectl |= [{match: "get pv minio-data-node1 -o jsonpath=\\{.spec.hostPath", rc: 1, stderr: "connection refused"}] + .' \
    "$FAKE_SCENARIO" > "$WORK/s.json" && "$BIN/cat" "$WORK/s.json" > "$FAKE_SCENARIO"
run_install "1|$NS" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "PV can't be read" 1
expect_cluster_untouched "PV can't be read"
expect_output "PV can't be read" 'Could not read PersistentVolume'

echo
echo "--- The confirmation"

fixture
write_cluster yes /mnt/minio
run_install "1|y" MINIO_EXISTING_PATH=/mnt/minio
expect_rc "'y' isn't the namespace" 0
expect_output "'y' isn't the namespace" 'Installation cancelled'
expect_cluster_untouched "'y' isn't the namespace"
expect_node_untouched "'y' isn't the namespace"

# No terminal: the answer to the node prompt comes from a pipe.
fixture
write_cluster yes /mnt/minio
OUT="$(env -i PATH="$BIN" HOME="$WORK/home" WORK="$WORK" CALLS="$CALLS" FAKE_STATE="$FAKE_STATE" \
    FAKE_FIXTURE="$FAKE_FIXTURE" FAKE_SCENARIO="$FAKE_SCENARIO" FAKE_CLI_LOG="$FAKE_CLI_LOG" \
    FAKE_STDIN_LOG="$FAKE_STDIN_LOG" STUB_MOUNTPOINT_RC=0 DISK_SAFETY_CRYPTTAB="$WORK/crypttab" \
    MINIO_EXISTING_PATH=/mnt/minio "$REAL_BASH" "$SCRIPT" 2>&1 <<<"1
$NS")"
# shellcheck disable=SC2034  # read by expect_rc
RC=$?
expect_rc "no terminal" 1
expect_output "no terminal" 'needs a terminal'
expect_cluster_untouched "no terminal"

echo
echo "--- Without MINIO_EXISTING_PATH the credentials are new, and it says so"

fixture
write_cluster yes /var/lib/minio
run_install "1|0|$NS"
expect_rc "OS folder reinstall" 1
expect_output "OS folder reinstall" 'creates new ones'
expect_output "OS folder reinstall" 'configure-backup.sh'
expect_cli "OS folder reinstall" "delete namespace $NS"
expect_secret "OS folder reinstall" "$(printf admin | base64 -w0)" "$(printf GENERATEDpasswordGENERATEDpassword | cut -c1-25 | tr -d '\n' | base64 -w0)"
delete_at=$(line_of "delete namespace $NS")
if [[ "$delete_at" -gt 0 ]] && "$BIN/grep" -q '^mkdir -p /var/lib/minio$' "$CALLS"; then
    pass "OS folder reinstall: directory created"
else
    fail "OS folder reinstall: directory not created" "$("$BIN/cat" "$CALLS")"
fi

echo
echo "--- A first install doesn't change"

fixture
write_cluster no ""
run_install "1|0"
expect_rc "first install" 1
expect_output "first install" 'MinIO pod failed to become ready'
if "$BIN/grep" -q ' delete ' "$FAKE_CLI_LOG"; then
    fail "first install: deleted something" "$("$BIN/cat" "$FAKE_CLI_LOG")"
else
    pass "first install: nothing deleted"
fi
expect_no_output "first install" 'to reinstall'
expect_secret "first install" "$(printf admin | base64 -w0)" "$(printf GENERATEDpasswordGENERATEDpassword | cut -c1-25 | tr -d '\n' | base64 -w0)"

finish
