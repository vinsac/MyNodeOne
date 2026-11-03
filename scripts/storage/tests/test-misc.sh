#!/bin/bash

# Tests for the credentials writer (S27) and the two R20 script fixes.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

MINIO="$REPO_ROOT/scripts/storage/minio/install-minio.sh"

echo "--- Credentials file (function cut from the installer; installer not run)"

extract_function() {
    "$BIN/awk" -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$1"
}

"$(command -v mkdir)" -p "$WORK/creds-home"
{
    echo 'log_warn() { echo "WARN $*"; }'
    extract_function "$MINIO" write_credentials_file
    echo 'write_credentials_file "$1" "$(id -un)" <<EOF'
    echo 'secret-value'
    echo 'EOF'
} > "$WORK/write-creds.sh"

# The real commands run here, on the normal PATH, but only write inside the temp directory.
CREDS="$WORK/creds-home/creds.txt"

umask 022
"$REAL_BASH" "$WORK/write-creds.sh" "$CREDS"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$(stat -c '%a' "$CREDS")" == "600" ]]; then
    pass "new file is mode 600 under umask 022"
else
    fail "new file: exit $rc, mode $(stat -c '%a' "$CREDS" 2>/dev/null)"
fi
if [[ "$("$BIN/cat" "$CREDS")" == "secret-value" ]]; then
    pass "new file has the contents"
else
    fail "new file has the wrong contents"
fi

"$REAL_RM" -f "$CREDS"
echo old-secret > "$CREDS"
"$REAL_CHMOD" 644 "$CREDS"
"$REAL_BASH" "$WORK/write-creds.sh" "$CREDS"
if [[ "$(stat -c '%a' "$CREDS")" == "600" && "$("$BIN/cat" "$CREDS")" == "secret-value" ]]; then
    pass "replacing a file that was mode 644 leaves mode 600"
else
    fail "replacing a 644 file: mode $(stat -c '%a' "$CREDS")"
fi

leftover="$("$BIN/ls" -A "$WORK/creds-home" | "$BIN/grep" -v '^creds.txt$' || true)"
if [[ -z "$leftover" ]]; then
    pass "no temp file left behind"
else
    fail "temp file left behind" "$leftover"
fi

# The temp file is mode 600 before any secret reaches it: mktemp alone guarantees
# this, but the umask in the function is what covers the rest. Check both are there.
function_text="$(extract_function "$MINIO" write_credentials_file)"
if [[ "$function_text" == *"umask 077"* && "$function_text" == *'mktemp "${dest}.XXXXXX"'* ]]; then
    pass "writer uses umask 077 and a temp file"
else
    fail "writer lacks umask 077 or the temp file"
fi

"$(command -v mkdir)" -p "$WORK/readonly"
"$REAL_CHMOD" 555 "$WORK/readonly"
"$REAL_BASH" "$WORK/write-creds.sh" "$WORK/readonly/creds.txt" 2>/dev/null
rc=$?
"$REAL_CHMOD" 755 "$WORK/readonly"
if [[ "$rc" -ne 0 ]]; then
    pass "unwritable directory is reported as a failure"
else
    fail "unwritable directory reported success"
fi

if "$BIN/grep" -nE 'chmod .*(CREDS_FILE|credentials)' "$MINIO" >/dev/null; then
    fail "installer still sets the mode with chmod afterwards"
else
    pass "installer doesn't chmod the file afterwards"
fi
if "$BIN/grep" -qE 'cat > "\$CREDS_FILE"' "$MINIO"; then
    fail "installer still writes the file directly"
else
    pass "installer writes through the safe writer"
fi

echo
echo "--- add-disk-to-longhorn.sh"

ADD_DISK="$REPO_ROOT/scripts/longhorn-maintenance/scripts/add-disk-to-longhorn.sh"
if "$REAL_BASH" -n "$ADD_DISK"; then
    pass "add-disk-to-longhorn.sh parses"
else
    fail "add-disk-to-longhorn.sh doesn't parse"
fi

# Only the lines that load the libraries, run on the sandbox PATH with no SCRIPT_DIR set.
"$BIN/sed" -n '1,/k8s-utils.sh/p' "$ADD_DISK" > "$WORK/add-disk-head.sh"
"$BIN/cat" >> "$WORK/add-disk-head.sh" <<'EOF'
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "PROJECT_ROOT=$PROJECT_ROOT"
EOF
"$(command -v mkdir)" -p "$WORK/repo-copy/scripts/longhorn-maintenance/scripts" "$WORK/repo-copy/scripts/lib"
"$(command -v cp)" "$WORK/add-disk-head.sh" "$WORK/repo-copy/scripts/longhorn-maintenance/scripts/add-disk-head.sh"
"$(command -v cp)" "$REPO_ROOT/scripts/lib/project-root.sh" "$WORK/repo-copy/scripts/lib/project-root.sh"
echo ': library loaded' > "$WORK/repo-copy/scripts/lib/k8s-utils.sh"
sandbox_bash "unset SCRIPT_DIR; source '$WORK/repo-copy/scripts/longhorn-maintenance/scripts/add-disk-head.sh'"
expect_rc "libraries load with SCRIPT_DIR unset" 0
expect_output "SCRIPT_DIR is resolved" "^SCRIPT_DIR=$WORK/repo-copy/scripts/longhorn-maintenance/scripts$"
expect_no_output "no missing-file errors" "No such file"

if "$BIN/grep" -nE 'longhorn-system (get|patch) node ' "$ADD_DISK" >/dev/null; then
    fail "still queries the core Node resource, which has no spec.disks"
else
    pass "queries nodes.longhorn.io"
fi

echo
echo "--- node-registry-manager.sh"

REGISTRY="$REPO_ROOT/scripts/lib/node-registry-manager.sh"
if "$BIN/grep" -n 'update_minio_config' "$REGISTRY" >/dev/null; then
    fail "update_minio_config is still called"
else
    pass "undefined update_minio_config is gone"
fi

# The script only needs these for labels and hardware details. The registry lives in
# the sandbox's HOME, and mkdir is a stub, so its directory is made here.
write_stub hostname 'echo testhost'
write_stub xargs 'cat'
"$(command -v mkdir)" -p "$WORK/home/.mynodeone"

"$BIN/cat" > "$FAKE_SCENARIO" <<'EOF'
{"kubectl": [
  {"match": "version --client"},
  {"match": "version --short", "stdout": "Server Version: v1\n"},
  {"match": "get configmap sync-controller-registry", "stdout": "{\"management_laptops\":[],\"vps_nodes\":[],\"worker_nodes\":[],\"cluster_nodes\":[{\"name\":\"node1\",\"minio\":{\"enabled\":false,\"namespace\":\"minio\"},\"installation\":{\"installed_components\":[]}}],\"metadata\":{}}"},
  {"match": "patch configmap"}
]}
EOF

reset_state
sandbox_bash "'$REAL_BASH' '$REGISTRY' update-minio --name node1 --endpoint http://x:9000; echo RC=\$?; cat \"\$HOME/.mynodeone/node-registry.json\""
expect_no_output "update-minio dispatches to a real function" "command not found"
expect_output "update-minio runs" "RC=0"
expect_output "namespace defaults to minio-<node>" '"namespace": *"minio-node1"'
expect_output "console is derived from the endpoint" '"console": *"http://x:9001"'
if "$BIN/grep" -q 'patch configmap sync-controller-registry' "$FAKE_CLI_LOG"; then
    pass "update-minio writes the registry back"
else
    fail "update-minio didn't write the registry back" "$("$BIN/cat" "$FAKE_CLI_LOG")"
fi

reset_state
sandbox_bash "'$REAL_BASH' '$REGISTRY' update-minio --name node1 --endpoint http://x:9000 --namespace custom-ns; echo RC=\$?; cat \"\$HOME/.mynodeone/node-registry.json\""
expect_output "explicit namespace runs" "RC=0"
expect_output "an explicit namespace is kept" '"namespace": *"custom-ns"'

reset_state
sandbox_bash "'$REAL_BASH' '$REGISTRY' register-cluster-node --name node9 --tailscale-ip 100.64.0.9 --ssh-user ops --role worker; echo RC=\$?; cat \"\$HOME/.mynodeone/node-registry.json\""
expect_output "register runs" "RC=0"
expect_output "new nodes get minio-<node>" '"namespace": *"minio-node9"'

finish
