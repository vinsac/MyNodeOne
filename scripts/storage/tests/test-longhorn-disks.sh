#!/bin/bash

# Tests for how the Longhorn installer registers disks and checks their UUIDs.
# The functions are cut out of the installer and run against a fake kubectl.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

LONGHORN="$REPO_ROOT/scripts/storage/longhorn/install-interactive.sh"
DISKS="$WORK/disks"
"$(command -v mkdir)" -p "$DISKS/a" "$DISKS/b"

# The mountpoint stub answers from this list, so each disk can differ.
write_stub mountpoint 'while IFS= read -r line; do
    [[ "$line" == "${*: -1}" ]] && exit 0
done < "$WORK/mounted"
exit 1'
: > "$WORK/mounted"
: > "$WORK/fstab"

extract_function() {
    "$BIN/awk" -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$1" \
        | "$BIN/sed" "s|/etc/fstab|$WORK/fstab|g"
}

{
    echo 'set -euo pipefail'
    echo 'log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }; log_success() { echo "OK $*"; }'
    echo 'get_k8s_node_name() { echo node1; }'
    echo 'kubectl_longhorn_retry() { shift 2; "$@"; }'
    echo 'declare -a MOUNTED_DISKS=(); declare -a JUST_ADDED_DISKS=()'
    extract_function "$LONGHORN" add_node_disks_to_longhorn
    extract_function "$LONGHORN" print_disk_recovery_steps
    extract_function "$LONGHORN" check_disk_uuid_mismatches
} > "$WORK/functions.sh"

# Writes the fake cluster: NODE is the node resource's JSON, REPLICAS the replicas' JSON.
write_cluster() {
    local node="$1" replicas="${2:-{\"items\":[]\}}"
    NODE="$node" REPLICAS="$replicas" "$REAL_PYTHON" -I -c '
import json, os, sys
json.dump({"kubectl": [
    {"match": "^get nodes$"},
    {"match": "get nodes.longhorn.io node1 -n longhorn-system -o json", "stdout": os.environ["NODE"]},
    {"match": "get nodes.longhorn.io node1 -n longhorn-system$"},
    {"match": "get replicas.longhorn.io", "stdout": os.environ["REPLICAS"]},
    {"match": "^patch nodes.longhorn.io"},
]}, open(sys.argv[1], "w"))
' "$FAKE_SCENARIO"
    : > "$FAKE_CLI_LOG"
}

expect_never_deleted() {
    local found
    found="$("$BIN/grep" -E ' ?delete ' "$FAKE_CLI_LOG" || true)"
    if [[ -z "$found" ]]; then
        pass "$1: nothing deleted"
    else
        fail "$1: deleted something" "$found"
    fi
}

expect_cli() {
    if "$BIN/grep" -qE -- "$2" "$FAKE_CLI_LOG"; then
        pass "$1: called /$2/"
    else
        fail "$1: no call matching /$2/" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    fi
}

expect_no_patch() {
    local found
    found="$("$BIN/grep" -E '^kubectl patch ' "$FAKE_CLI_LOG" || true)"
    if [[ -z "$found" ]]; then
        pass "$1: no patch"
    else
        fail "$1: patched" "$found"
    fi
}

check() {
    sandbox_bash "source '$WORK/functions.sh'; JUST_ADDED_DISKS=(${1:-}); check_disk_uuid_mismatches"
}

node_json() {
    # node_json NAME PATH UUID [condition JSON]
    printf '{"spec":{"disks":{"%s":{"path":"%s"}}},"status":{"diskStatus":{"%s":{"diskUUID":"%s","conditions":[%s]}}}}' \
        "$1" "$2" "$1" "$3" "${4:-}"
}

CHANGED='{"type":"Ready","status":"False","reason":"DiskFilesystemChanged","message":"cannot find disk config file, maybe due to a mount error"}'
MISMATCH_MESSAGE='{"type":"Ready","status":"False","reason":"Other","message":"record diskUUID doesnt match the one on the disk"}'
REPLICA="{\"items\":[{\"metadata\":{\"name\":\"r1\"},\"spec\":{\"nodeID\":\"node1\",\"diskPath\":\"$DISKS/a\"}},{\"metadata\":{\"name\":\"r2\"},\"spec\":{\"nodeID\":\"node2\",\"diskPath\":\"$DISKS/a\"}}]}"

echo "--- UUID check: what looks like a reformat but isn't"

# A disk added a moment ago: no cfg yet, and Longhorn has no UUID for it yet
write_cluster "$(node_json disk-a "$DISKS/a" "")"
echo "$DISKS/a" > "$WORK/mounted"
check
expect_rc "fresh disk, no status UUID" 0
expect_never_deleted "fresh disk, no status UUID"
expect_no_output "fresh disk, no status UUID" "mismatch on"

# Added in this run, even if a status UUID has shown up
write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1")"
check "'$DISKS/a'"
expect_rc "disk just added" 0
expect_never_deleted "disk just added"
expect_no_output "disk just added" "mismatch on"
expect_output "disk just added" "added just now"

# A nofail disk that failed to mount: an empty directory, and Longhorn complains too
write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1" "$CHANGED")"
: > "$WORK/mounted"
echo "UUID=x $DISKS/a ext4 defaults,nofail 0 2" > "$WORK/fstab"
check
expect_rc "unmounted fstab disk" 0
expect_never_deleted "unmounted fstab disk"
expect_output "unmounted fstab disk" "isn't mounted"
expect_no_output "unmounted fstab disk" "mismatch on"
: > "$WORK/fstab"

# A similar path in fstab doesn't count as this disk's entry
echo "UUID=x ${DISKS}/a1 ext4 defaults,nofail 0 2" > "$WORK/fstab"
write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1")"
check
expect_no_output "similar fstab path" "isn't mounted"
: > "$WORK/fstab"

# Mounted, a UUID on record, no cfg: suspicious, not proof
write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1")"
echo "$DISKS/a" > "$WORK/mounted"
check
expect_rc "mounted, cfg missing" 0
expect_never_deleted "mounted, cfg missing"
expect_output "mounted, cfg missing" "no longhorn-disk.cfg"
expect_no_output "mounted, cfg missing" "mismatch on"

# Everything agrees
echo '{"diskUUID":"uuid-1"}' > "$DISKS/a/longhorn-disk.cfg"
check
expect_rc "cfg matches" 0
expect_never_deleted "cfg matches"
expect_output "cfg matches" "No disk UUID mismatches"

echo
echo "--- UUID check: a real mismatch is reported, and nothing is changed"

echo '{"diskUUID":"uuid-2"}' > "$DISKS/a/longhorn-disk.cfg"
write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1")" "$REPLICA"
check
expect_rc "cfg differs" 0
expect_never_deleted "cfg differs"
expect_no_patch "cfg differs"
expect_output "cfg differs" "mismatch on 'disk-a'"
expect_output "cfg differs" "Replicas recorded on this disk: 1$"
expect_output "cfg differs" "Do not delete the nodes.longhorn.io"
expect_output "cfg differs" 'allowScheduling.:false'
expect_output "cfg differs" '"disk-a":null'
"$REAL_RM" -f "$DISKS/a/longhorn-disk.cfg"

write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1" "$CHANGED")"
check
expect_rc "DiskFilesystemChanged on a mounted disk" 0
expect_never_deleted "DiskFilesystemChanged on a mounted disk"
expect_no_patch "DiskFilesystemChanged on a mounted disk"
expect_output "DiskFilesystemChanged on a mounted disk" "mismatch on 'disk-a'"

write_cluster "$(node_json disk-a "$DISKS/a" "uuid-1" "$MISMATCH_MESSAGE")"
check
expect_output "mismatch only in the message" "mismatch on 'disk-a'"
expect_never_deleted "mismatch only in the message"

# Replicas that can't be read are said to be unknown, not reported as zero
"$REAL_PYTHON" -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["kubectl"] = [r for r in d["kubectl"] if "replicas" not in r["match"]]
json.dump(d, open(sys.argv[1], "w"))
' "$FAKE_SCENARIO"
check
expect_output "replicas unreadable" "Replicas recorded on this disk: unknown"
expect_never_deleted "replicas unreadable"

if "$BIN/grep" -nE '^[[:space:]]*(if ! )?(kubectl_longhorn_retry .*\\$|kubectl delete nodes\.longhorn\.io)' "$LONGHORN" \
    | "$BIN/grep" -q 'delete nodes'; then
    fail "the installer still deletes a Longhorn node"
else
    pass "the installer has no command deleting a Longhorn node"
fi

echo
echo "--- Registering disks"

add_disk() {
    sandbox_bash "source '$WORK/functions.sh'; MOUNTED_DISKS=('$1'); add_node_disks_to_longhorn true; echo \"ADDED=\${JUST_ADDED_DISKS[*]:-}\""
}

# The first disk on a re-run: defaultDataPath didn't apply, so only the node knows
write_cluster '{"spec":{"disks":{"default-disk-1":{"path":"/var/lib/longhorn"}}}}'
add_disk /mnt/longhorn-disks/disk-sda
expect_rc "first new disk" 0
expect_cli "first new disk" '^kubectl patch nodes.longhorn.io node1 .*"disk-sda":\{"path":"/mnt/longhorn-disks/disk-sda","allowScheduling":true\}'
expect_output "first new disk is tracked" "^ADDED=/mnt/longhorn-disks/disk-sda$"

if "$BIN/grep" -qE '^[[:space:]]+add_node_disks_to_longhorn( .+)$' "$LONGHORN"; then
    fail "main still tells the function to skip a disk"
else
    pass "main doesn't tell the function to skip a disk"
fi

write_cluster '{"spec":{"disks":{"default-disk-1":{"path":"/mnt/longhorn-disks/disk-sda"}}}}'
add_disk /mnt/longhorn-disks/disk-sda
expect_no_patch "path registered by defaultDataPath"
expect_output "path registered by defaultDataPath" "already registered as 'default-disk-1'"

write_cluster '{"spec":{"disks":{"default-disk-1":{"path":"/mnt/longhorn-disks/disk-sda/"}}}}'
add_disk /mnt/longhorn-disks/disk-sda
expect_no_patch "registered with a trailing slash"

write_cluster '{"spec":{"disks":{"default-disk-1":{"path":"/mnt/longhorn-disks/disk-sda1"}}}}'
add_disk /mnt/longhorn-disks/disk-sda
expect_cli "similar path isn't the same disk" '^kubectl patch nodes.longhorn.io node1'

write_cluster '{"spec":{"disks":{"disk-sda":{"path":"/somewhere/else"}}}}'
add_disk /mnt/longhorn-disks/disk-sda
expect_no_patch "name taken by another path"
expect_output "name taken by another path" "already has a disk named 'disk-sda' at /somewhere/else"

# A read that fails must not read as an empty list, which would add duplicates
write_cluster 'not json'
add_disk /mnt/longhorn-disks/disk-sda
expect_no_patch "unreadable node"
expect_output "unreadable node" "Could not read Longhorn node"

finish
