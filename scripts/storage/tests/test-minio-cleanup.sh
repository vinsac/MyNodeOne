#!/bin/bash

# Tests for minio/cleanup-node-minio.sh, against a fake kubectl.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

SCRIPT="$REPO_ROOT/scripts/storage/minio/cleanup-node-minio.sh"

expect_cli() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$FAKE_CLI_LOG"; then
        pass "$name: called /$pattern/"
    else
        fail "$name: no call matching /$pattern/" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    fi
}

expect_no_delete() {
    local name="$1" found
    found="$("$BIN/grep" -E ' delete | patch ' "$FAKE_CLI_LOG" || true)"
    if [[ -z "$found" ]]; then
        pass "$name: nothing deleted"
    else
        fail "$name: deleted something" "$found"
    fi
}

# A cluster where node2 is gone and its MinIO resources are left behind.
# RECLAIM is the PV's reclaim policy.
write_cluster() {
    local reclaim="${1:-Retain}"
    "$BIN/cat" > "$FAKE_SCENARIO" <<EOF
{"kubectl": [
  {"match": "get node node1 ", "stdout": "node/node1"},
  {"match": "get node node2 ", "stdout": ""},
  {"match": "get node node3 ", "stdout": ""},
  {"match": "get namespaces -l app=minio", "stdout": "minio-node1\nminio-node2\n"},
  {"match": "get namespace minio-node1 ", "stdout": "namespace/minio-node1"},
  {"match": "get namespace minio-node2 ", "stdout": "namespace/minio-node2"},
  {"match": "get namespace minio-node3 ", "stdout": ""},
  {"match": "get pvc -n minio-node2", "stdout": "minio-data-minio-0 Bound 16Ti\n"},
  {"match": "get pvc -n minio-node1", "stdout": "minio-data-minio-0 Bound 16Ti\n"},
  {"match": "get pods -n minio-node2", "stdout": "minio-0 Pending\n"},
  {"match": "get pods -n minio-node1", "stdout": "minio-0 Running\n"},
  {"match": "get pv -l app=minio,node=node1", "stdout": "minio-data-node1\n"},
  {"match": "get pv -l app=minio,node=node2", "stdout": "minio-data-node2\n"},
  {"match": "get pv -l app=minio,node=node3", "stdout": ""},
  {"match": "persistentVolumeReclaimPolicy", "stdout": "$reclaim"},
  {"match": "status.phase", "stdout": "Bound"},
  {"match": "hostPath.path", "stdout": "/mnt/minio"},
  {"match": "delete namespace minio-node2"},
  {"match": "delete pv minio-data-node2"}
]}
EOF
}

echo "--- Reporting changes nothing"

reset_state
write_cluster
sandbox_bash "'$REAL_BASH' '$SCRIPT'"
expect_rc "no arguments" 2

reset_state
sandbox_bash "'$REAL_BASH' '$SCRIPT' --node 'bad;name'"
expect_rc "bad node name" 2

reset_state
sandbox_bash "'$REAL_BASH' '$SCRIPT' --list"
expect_rc "list" 0
expect_output "list marks the left-behind instance" "Node node2: NOT in the cluster"
expect_output "list reports node1 as present" "Node node1: in the cluster"
expect_output "list counts them" "whose node is gone: 1"
expect_no_delete "list"

reset_state
sandbox_bash "'$REAL_BASH' '$SCRIPT' --node node2"
expect_rc "report" 0
expect_output "report shows the namespace" "Namespace: minio-node2"
expect_output "report shows the PVC" "PVC: minio-data-minio-0"
expect_output "report shows the PV" "PV: minio-data-node2 .*reclaim policy: Retain"
expect_output "report shows the data path" "/mnt/minio"
expect_output "report offers the delete command" "--node node2 --delete"
expect_no_delete "report"

reset_state
sandbox_bash "'$REAL_BASH' '$SCRIPT' --node node3"
expect_rc "nothing left behind" 0
expect_output "nothing left behind" "No MinIO resources found"

echo
echo "--- kubectl failures aren't read as nothing left"

for failing in "get node node2" "get namespace minio-node2" "get pv -l" "get pvc" "get pods"; do
    reset_state
    write_cluster
    "$REAL_PYTHON" -I -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['kubectl'].insert(0, {'match': sys.argv[2], 'rc': 1, 'stderr': 'connection refused'})
json.dump(d, open(p, 'w'))
" "$FAKE_SCENARIO" "$failing"
    sandbox_bash "'$REAL_BASH' '$SCRIPT' --node node2"
    expect_rc "report when '$failing' fails" 1
    expect_no_output "report when '$failing' fails" "No MinIO resources found"

    sandbox_pty "minio-node2" "'$REAL_BASH' '$SCRIPT' --node node2 --delete"
    expect_rc "delete when '$failing' fails" 1
    expect_no_delete "delete when '$failing' fails"
done

echo
echo "--- Deleting is opt-in"

reset_state
write_cluster
sandbox_pty "minio-node1" "'$REAL_BASH' '$SCRIPT' --node node1 --delete"
expect_rc "node still in the cluster" 1
expect_output "node still in the cluster" "still in the cluster"
expect_no_delete "node still in the cluster"

reset_state
sandbox_bash "echo minio-node2 | '$REAL_BASH' '$SCRIPT' --node node2 --delete"
expect_rc "no terminal, correct name piped in" 1
expect_no_delete "no terminal, correct name piped in"

for wrong in "y" "yes" "node2" "minio-node1" ""; do
    reset_state
    sandbox_pty "$wrong" "'$REAL_BASH' '$SCRIPT' --node node2 --delete"
    expect_rc "typed '$wrong'" 1
    expect_no_delete "typed '$wrong'"
done

reset_state
write_cluster Delete
sandbox_pty "minio-node2" "'$REAL_BASH' '$SCRIPT' --node node2 --delete"
expect_rc "reclaim policy Delete" 1
expect_output "reclaim policy Delete" "could also delete its data"
expect_no_delete "reclaim policy Delete"

reset_state
write_cluster
sandbox_pty "minio-node2" "'$REAL_BASH' '$SCRIPT' --node node2 --delete"
expect_rc "confirmed" 0
expect_cli "confirmed" 'delete namespace minio-node2'
expect_cli "confirmed" 'delete pv minio-data-node2'
order="$("$BIN/grep" ' delete ' "$FAKE_CLI_LOG" | "$BIN/cut" -d' ' -f3 | "$BIN/tr" '\n' ' ')"
if [[ "$order" == "namespace pv " ]]; then
    pass "confirmed: namespace goes first, then the PV"
else
    fail "confirmed: wrong order: $order"
fi

reset_state
sandbox_pty "minio-node3" "'$REAL_BASH' '$SCRIPT' --node node3 --delete"
expect_rc "nothing to delete" 0
expect_output "nothing to delete" "Nothing to delete"
expect_no_delete "nothing to delete"

finish
