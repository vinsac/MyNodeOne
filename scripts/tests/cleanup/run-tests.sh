#!/bin/bash
###############################################################################
# Tests for the cleanup fixes: validate-network.sh --fix, the uninstaller's removal
# of host units, remove-node.sh's MinIO report, and dead code staying deleted.
#
# Everything runs against stubs shadowed on PATH, with HOME and every path in a temp
# dir. No real firewall, unit, /etc file or cluster is touched. The uninstaller is
# never run whole: its functions are lifted out and pointed at a temp root.
#
#   bash scripts/tests/cleanup/run-tests.sh
###############################################################################

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PASS=0
FAIL=0

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAILED: $1"; }

assert_has() { # <description> <file> <fixed string>
    if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (no '$3' in $(basename "$2"))"; fi
}

assert_lacks() { # <description> <file> <fixed string>
    if grep -qF -- "$3" "$2"; then bad "$1 (found '$3' in $(basename "$2"))"; else ok "$1"; fi
}

assert_exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_gone() { if [ -e "$2" ]; then bad "$1 (still there: $2)"; else ok "$1"; fi; }

# make_stub <bin dir> <name> <body>: the stub logs its arguments, then runs the body.
make_stub() {
    { echo '#!/bin/bash'; echo "echo \"$2 \$*\" >>\"\$STUB_LOG\""; echo "$3"; } >"$1/$2"
    chmod +x "$1/$2"
}

# extract_function <file> <name>: print one top-level function from a script.
extract_function() {
    awk -v start="^$2\\\\(\\\\) \\\\{" '$0 ~ start { on = 1 } on { print } on && /^}/ { exit }' "$1"
}

###############################################################################
echo "validate-network.sh: VXLAN must not be reopened"
###############################################################################

NET_BIN="$SANDBOX/net-bin"
mkdir -p "$NET_BIN"

UFW_DEFAULTS='Status: active
Default: deny (incoming), allow (outgoing), allow (routed)'
TAILSCALE_RULE='Anywhere on tailscale0      ALLOW       Anywhere'
VXLAN_RULE='8472/udp                   ALLOW       Anywhere
8472/udp (v6)              ALLOW       Anywhere (v6)'
VXLAN_LIMITED_RULE='8472/udp                   ALLOW       100.64.0.0/10'

make_stub "$NET_BIN" ufw 'case "$1" in status) printf "%s\n" "$STUB_UFW" ;; esac'
# Like real ssh, this reads stdin unless given -n, which would swallow a node list
make_stub "$NET_BIN" ssh '
[[ " $* " == *" -n "* ]] || cat >/dev/null
case "$*" in
    *"grep -Eq"*) [ "$STUB_REMOTE_IFACE" = yes ]; exit $? ;;
    *"ufw status verbose"*) echo "Default: deny (incoming), allow (outgoing), allow (routed)" ;;
    *"ufw status"*) printf "%s\n" "$STUB_REMOTE_UFW" ;;
    *"echo ok"*) echo ok ;;
    *"ip route"*) echo "10.42.1.0/24 via 10.42.1.0 dev flannel.1" ;;
esac
exit 0'
make_stub "$NET_BIN" kubectl '
case "$*" in
    "get nodes -o jsonpath"*) printf "node-a\t100.64.0.1\nnode-b\t100.64.0.2\nnode-c\t100.64.0.3\n" ;;
    "get nodes --no-headers"*) printf "node-a Ready\nnode-b Ready\nnode-c Ready\n" ;;
esac
exit 0'
make_stub "$NET_BIN" ip '
case "$*" in
    "-4 addr show flannel.1") echo "    inet 10.42.0.0/32 scope global flannel.1" ;;
    route*) echo "10.42.1.0/24 via 10.42.1.0 dev flannel.1" ;;
esac
exit 0'
make_stub "$NET_BIN" ss 'echo "UNCONN 0 0 0.0.0.0:8472 0.0.0.0:*"'
make_stub "$NET_BIN" systemctl '[ "$*" = "is-active k3s" ] || [ "$1" = restart ]'
make_stub "$NET_BIN" hostname 'echo node-a'
for tool in tailscale ping sudo curl; do
    make_stub "$NET_BIN" "$tool" 'exit 0'
done

# run_network <name> <local ufw rules> <remote ufw rules> <local iface yes|no> <remote iface yes|no> [flags]
# Leaves the log in $NET_DIR/$name.log and the output in $NET_DIR/$name.out
NET_DIR="$SANDBOX/net"
mkdir -p "$NET_DIR"
run_network() {
    local name="$1" local_rules="$2" remote_rules="$3" local_iface="$4" remote_iface="$5"
    shift 5
    local config="$NET_DIR/$name.yaml"
    if [ "$local_iface" = yes ]; then
        echo 'flannel-iface: "tailscale0"' >"$config"
    else
        echo 'write-kubeconfig-mode: "0600"' >"$config"
    fi
    PATH="$NET_BIN:$PATH" HOME="$SANDBOX" ACTUAL_HOME="$SANDBOX" CONFIG_FILE=/dev/null \
        K3S_CONFIG_FILE="$config" STUB_LOG="$NET_DIR/$name.log" \
        STUB_UFW="$UFW_DEFAULTS"$'\n'"$local_rules" STUB_REMOTE_UFW="$UFW_DEFAULTS"$'\n'"$remote_rules" \
        STUB_REMOTE_IFACE="$remote_iface" \
        bash "$REPO/scripts/validation/validate-network.sh" "$@" \
        >"$NET_DIR/$name.out" 2>&1 </dev/null
    touch "$NET_DIR/$name.log"
}

failed_count() { sed 's/\x1b\[[0-9;]*m//g' "$NET_DIR/$1.out" | awk '/Failed:/ { print $2; exit }'; }

OPEN="$TAILSCALE_RULE"$'\n'"$VXLAN_RULE"

run_network open "$OPEN" "$OPEN" yes yes --fix
assert_lacks "--fix never opens 8472 locally" "$NET_DIR/open.log" "ufw allow 8472"
assert_lacks "--fix never opens 8472 remotely" "$NET_DIR/open.log" "sudo ufw allow 8472"
assert_has "--fix removes an open rule" "$NET_DIR/open.log" "ufw delete allow 8472/udp"
assert_has "--fix removes it on node-b" "$NET_DIR/open.log" "@100.64.0.2 sudo ufw delete allow 8472/udp"
assert_has "--fix reaches the node after a node that used ssh" "$NET_DIR/open.log" "@100.64.0.3 sudo ufw delete allow 8472/udp"
assert_has "--fix run reaches the summary" "$NET_DIR/open.out" "Results Summary"

run_network other-iface "$OPEN" "$OPEN" no no --fix
assert_lacks "rule stays when VXLAN isn't known to use tailscale0" "$NET_DIR/other-iface.log" "ufw delete allow 8472/udp"
assert_has "operator is told why it stays" "$NET_DIR/other-iface.out" "does not set flannel-iface: tailscale0"

run_network clean "$TAILSCALE_RULE" "$TAILSCALE_RULE" yes yes --fix
assert_lacks "--fix on a clean node leaves 8472 alone" "$NET_DIR/clean.log" "8472"
assert_has "clean node passes the check" "$NET_DIR/clean.out" "UFW does not open VXLAN port 8472/UDP to Anywhere"

run_network limited "$TAILSCALE_RULE"$'\n'"$VXLAN_LIMITED_RULE" "$TAILSCALE_RULE" yes yes --fix
assert_lacks "a rule limited to a source isn't removed" "$NET_DIR/limited.log" "ufw delete allow 8472/udp"

run_network no-tailscale "" "" yes yes --fix
assert_has "--fix adds the tailscale0 rule" "$NET_DIR/no-tailscale.log" "ufw allow in on tailscale0"
assert_lacks "--fix adds no 8472 rule in its place" "$NET_DIR/no-tailscale.log" "allow 8472"

run_network report "$OPEN" "$TAILSCALE_RULE" yes yes
assert_lacks "without --fix nothing is deleted" "$NET_DIR/report.log" "ufw delete"
assert_has "without --fix the fix is offered" "$NET_DIR/report.out" "ufw delete allow 8472/udp"
assert_has "a failed check doesn't end the run" "$NET_DIR/report.out" "Results Summary"

run_network all-clean "$TAILSCALE_RULE" "$TAILSCALE_RULE" yes yes
run_network remote-open "$TAILSCALE_RULE" "$OPEN" yes yes
clean_failures="$(failed_count all-clean)"
open_failures="$(failed_count remote-open)"
if [ "$open_failures" = "$((clean_failures + 2))" ]; then
    ok "failures on remote nodes count in the summary"
else
    bad "failures on remote nodes count in the summary (clean: $clean_failures, open on 2 nodes: $open_failures)"
fi

for script in validate-network.sh test-multinode.sh; do
    if grep -nE 'ufw allow 8472' "$REPO/scripts/validation/$script" >/dev/null; then
        bad "$script has no command opening 8472"
    else
        ok "$script has no command opening 8472"
    fi
done

###############################################################################
echo "uninstall-mynodeone.sh: host units and files"
###############################################################################

UNINSTALL="$REPO/scripts/installation/uninstall-mynodeone.sh"
UN_BIN="$SANDBOX/uninstall-bin"
UN_ROOT="$SANDBOX/uninstall-root"
UN_LOG="$SANDBOX/uninstall.log"
UN_OUT="$SANDBOX/uninstall.out"
LOG_STUBS='log_info() { echo "$1"; }; log_success() { echo "$1"; }; log_warn() { echo "$1"; }; log_error() { echo "$1"; }'
mkdir -p "$UN_BIN" "$UN_ROOT/etc/systemd/system/mynodeone-node-agent.service.d" \
    "$UN_ROOT/usr/local/sbin" "$UN_ROOT/var/backups/mynodeone"
make_stub "$UN_BIN" systemctl 'exit 0'

for unit in flannel-health-monitor mynodeone-state-backup mynodeone-local-dns-sync; do
    touch "$UN_ROOT/etc/systemd/system/$unit.service" "$UN_ROOT/etc/systemd/system/$unit.timer"
done
touch "$UN_ROOT/etc/systemd/system/mynodeone-node-agent.service.d/sandbox.conf" \
    "$UN_ROOT/etc/systemd/system/unrelated.service" \
    "$UN_ROOT/usr/local/sbin/mynodeone-flannel-health" \
    "$UN_ROOT/usr/local/sbin/mynodeone-state-backup" \
    "$UN_ROOT/usr/local/sbin/unrelated-tool" \
    "$UN_ROOT/var/backups/mynodeone/state.tar"

units_script="$SANDBOX/uninstall-units.sh"
{
    echo "$LOG_STUBS"
    extract_function "$UNINSTALL" remove_mynodeone_host_units
    echo 'remove_mynodeone_host_units "$1"'
} >"$units_script"

: >"$UN_LOG"
PATH="$UN_BIN:$PATH" STUB_LOG="$UN_LOG" bash "$units_script" "$UN_ROOT" >"$UN_OUT" 2>&1
un_status=$?
if [ "$un_status" = 0 ]; then ok "removal succeeds"; else bad "removal succeeds (exit $un_status)"; fi

for unit in flannel-health-monitor mynodeone-state-backup mynodeone-local-dns-sync; do
    assert_gone "$unit.service removed" "$UN_ROOT/etc/systemd/system/$unit.service"
    assert_gone "$unit.timer removed" "$UN_ROOT/etc/systemd/system/$unit.timer"
    assert_has "$unit.timer stopped first" "$UN_LOG" "systemctl stop $unit.timer"
    assert_has "$unit.timer disabled" "$UN_LOG" "systemctl disable $unit.timer"
done
assert_gone "state backup tool removed" "$UN_ROOT/usr/local/sbin/mynodeone-state-backup"
assert_gone "flannel health tool removed" "$UN_ROOT/usr/local/sbin/mynodeone-flannel-health"
assert_gone "node agent drop-in removed" "$UN_ROOT/etc/systemd/system/mynodeone-node-agent.service.d"
assert_has "systemd reloaded" "$UN_LOG" "systemctl daemon-reload"
assert_exists "unrelated unit kept" "$UN_ROOT/etc/systemd/system/unrelated.service"
assert_exists "unrelated tool kept" "$UN_ROOT/usr/local/sbin/unrelated-tool"
assert_exists "state backups kept" "$UN_ROOT/var/backups/mynodeone/state.tar"
assert_has "operator is told the backups remain" "$UN_OUT" "Kept state backups in /var/backups/mynodeone"

PATH="$UN_BIN:$PATH" STUB_LOG="$UN_LOG" bash "$units_script" "$SANDBOX/empty-root" >"$UN_OUT" 2>&1
un_status=$?
if [ "$un_status" = 0 ]; then ok "nothing to remove is not an error"; else bad "nothing to remove is not an error (exit $un_status)"; fi

if grep -qx 'remove_mynodeone_host_units' "$UNINSTALL"; then
    ok "uninstaller calls it"
else
    bad "uninstaller calls it"
fi

SUDOERS="$SANDBOX/sudoers.d"
mkdir -p "$SUDOERS"
echo 'alice ALL=(ALL) NOPASSWD: ALL' >"$SUDOERS/alice-nopasswd"
echo '# MyNodeOne: passwordless kubectl' >"$SUDOERS/mynodeone"
echo 'bob ALL=(ALL) NOPASSWD: ALL' >"$SUDOERS/bob-nopasswd"
{
    echo "$LOG_STUBS"
    extract_function "$UNINSTALL" remove_mynodeone_sudoers
    echo 'remove_mynodeone_sudoers alice "$1"'
} >"$SANDBOX/uninstall-sudoers.sh"
bash "$SANDBOX/uninstall-sudoers.sh" "$SUDOERS" >/dev/null 2>&1
assert_gone "the user's sudoers rule removed" "$SUDOERS/alice-nopasswd"
assert_gone "control plane sudoers file removed" "$SUDOERS/mynodeone"
assert_exists "another user's rule kept" "$SUDOERS/bob-nopasswd"

###############################################################################
echo "uninstall-mynodeone.sh: /etc/hosts cleanup keeps the user's lines"
###############################################################################

HOSTS_SCRIPT="$SANDBOX/uninstall-hosts.sh"
HOSTS_FILE="$SANDBOX/hosts-under-test"
{
    echo 'set -euo pipefail'
    extract_function "$UNINSTALL" remove_mynodeone_hosts_entries
    echo 'remove_mynodeone_hosts_entries "$@"'
} >"$HOSTS_SCRIPT"

# hosts_case <description> <input> <expected output> [cluster domain]
# Compares bytes, so a lost final newline or line shows. A hard link shows the file was
# written in place, which is what a bind-mounted /etc/hosts needs: a rename breaks the
# link, and holding the old inode means it can't simply be reused by a later rename.
hosts_case() {
    printf '%s' "$2" >"$HOSTS_FILE"
    chmod 640 "$HOSTS_FILE"
    printf '%s' "$3" >"$HOSTS_FILE.want"
    ln -f "$HOSTS_FILE" "$HOSTS_FILE.link"
    if ! bash "$HOSTS_SCRIPT" "$HOSTS_FILE" "${4:-}" >"$HOSTS_FILE.out" 2>&1; then
        bad "$1: exits 0 ($(cat "$HOSTS_FILE.out"))"
    elif ! cmp -s "$HOSTS_FILE.want" "$HOSTS_FILE"; then
        bad "$1: got $(od -c "$HOSTS_FILE" | head -20)"
    elif [ ! "$HOSTS_FILE" -ef "$HOSTS_FILE.link" ] || [ "$(stat -c %a "$HOSTS_FILE")" != 640 ]; then
        bad "$1: file replaced rather than written in place"
    else
        ok "$1"
    fi
}

USER_TOP=$'127.0.0.1 localhost\n10.1.1.1 nas.home\n'
USER_END=$'192.168.1.5 printer\n# my note\n10.1.1.2 backup.home\n'

hosts_case "marker with End: block goes, lines around it stay" \
    "$USER_TOP"$'# MyNodeOne services\n100.64.1.5 chat.base.local\n# Note: MinIO uses node-specific domains\n100.64.1.6 base.local\n# End MyNodeOne services\n'"$USER_END" \
    "$USER_TOP$USER_END"

hosts_case "marker with End: an odd line inside the block goes with it" \
    "$USER_TOP"$'# MyNodeOne Apps\n100.64.1.5 app.base.local\n10.9.9.9 added-inside\n# End MyNodeOne Apps\n'"$USER_END" \
    "$USER_TOP$USER_END"

hosts_case "no End and no blank line: user lines below survive" \
    "$USER_TOP"$'# MyNodeOne Services - Auto-synced on today\n100.64.1.5\tchat.base.local\n100.64.1.6\tbase.local\n'"$USER_END" \
    "$USER_TOP$USER_END"

hosts_case "no End: a note right below the block survives" \
    "$USER_TOP"$'# MyNodeOne Services - old\n100.64.1.5\tchat.base.local\n# my note about the NAS\n10.1.1.3 other.home\n' \
    "$USER_TOP"$'# my note about the NAS\n10.1.1.3 other.home\n'

hosts_case "no End: a comment between entries goes" \
    "$USER_TOP"$'# MyNodeOne Services - old\n# generated, do not edit\n100.64.1.5\tchat.base.local\n# apps\n100.64.1.6\tapp.base.local\n'"$USER_END" \
    "$USER_TOP$USER_END"

hosts_case "no End: stops at a blank line, even with .local below it" \
    "$USER_TOP"$'# MyNodeOne Services - old\n100.64.1.5\tchat.base.local\n\n10.1.1.4 printer.local\n' \
    "$USER_TOP"$'\n10.1.1.4 printer.local\n'

hosts_case "no End: an entry also naming another host survives" \
    $'# MyNodeOne Apps\n100.64.1.5 app.base.local\n10.1.1.4 printer.local nas.home\n' \
    $'10.1.1.4 printer.local nas.home\n'

hosts_case "no End: the node agent's marker at the end of the file" \
    "$USER_TOP"$'\n# MyNodeOne DNS entries (managed by node-agent)\n100.64.1.5\tchat.base.local\n' \
    "$USER_TOP"$'\n'

hosts_case "marker text mentioned mid-line stays, and starts no block" \
    $'10.1.1.1 nas.home # MyNodeOne services moved\n# ask bob about # MyNodeOne Services\n# see a # End MyNodeOne services note\n100.64.1.5 mine.local\n# chat.mynodeone.local is mentioned here\n'"$USER_END" \
    $'10.1.1.1 nas.home # MyNodeOne services moved\n# ask bob about # MyNodeOne Services\n# see a # End MyNodeOne services note\n100.64.1.5 mine.local\n# chat.mynodeone.local is mentioned here\n'"$USER_END"

hosts_case "a comment that merely starts with MyNodeOne stays" \
    $'# MyNodeOne is what runs the NAS\n10.1.1.1 nas.local\n# MyNodeOne: notes\n' \
    $'# MyNodeOne is what runs the NAS\n10.1.1.1 nas.local\n# MyNodeOne: notes\n'

hosts_case "no marker: nothing changes" "$USER_TOP$USER_END" "$USER_TOP$USER_END"
hosts_case "empty file" "" ""

hosts_case "two blocks with End" \
    "$USER_TOP"$'# MyNodeOne services\n100.64.1.5 a.base.local\n# End MyNodeOne services\n10.8.8.8 between\n# MyNodeOne Apps\n100.64.1.6 b.base.local\n# End MyNodeOne Apps\n'"$USER_END" \
    "$USER_TOP"$'10.8.8.8 between\n'"$USER_END"

hosts_case "block with no End can't reach a later block's End" \
    "$USER_TOP"$'# MyNodeOne Services - old\n100.64.1.5\ta.base.local\n10.8.8.8 between\n# MyNodeOne services\n100.64.1.6 b.base.local\n# End MyNodeOne services\n'"$USER_END" \
    "$USER_TOP"$'10.8.8.8 between\n'"$USER_END"

hosts_case "block with no End can't reach another kind's End" \
    $'# MyNodeOne Services - old\n10.8.8.8 keep-me\n# End MyNodeOne Apps\n' \
    $'10.8.8.8 keep-me\n'

hosts_case "no trailing newline, user line last" \
    $'# MyNodeOne services\n100.64.1.5 a.base.local\n# End MyNodeOne services\n10.1.1.1 nas.home' \
    $'10.1.1.1 nas.home'
hosts_case "no trailing newline, End marker last" \
    $'10.1.1.1 nas.home\n# MyNodeOne services\n100.64.1.5 a.base.local\n# End MyNodeOne services' \
    $'10.1.1.1 nas.home\n'
hosts_case "no trailing newline, entry with no End last" \
    $'10.1.1.1 nas.home\n# MyNodeOne Services - old\n100.64.1.5\ta.base.local' \
    $'10.1.1.1 nas.home\n'
hosts_case "no trailing newline, no marker" $'10.1.1.1 nas.home' $'10.1.1.1 nas.home'

hosts_case "entries outside a block under the old and cluster domains go" \
    $'100.64.1.5 chat.mynodeone.local\n100.64.1.6 mynodeone.local\n10.1.1.1 nas.home\n100.64.1.7 chat.base.local\n100.64.1.8 base.local\n10.1.1.4 printer.local\n' \
    $'10.1.1.1 nas.home\n10.1.1.4 printer.local\n' base

hosts_case "a line that also names another host stays" \
    $'100.64.1.5 chat.mynodeone.local nas.home\n100.64.1.6 chat.base.local # mine\n' \
    $'100.64.1.5 chat.mynodeone.local nas.home\n100.64.1.6 chat.base.local # mine\n' base

hosts_case "cluster domain is not read as a regex" \
    $'100.64.1.5 chat.my.cluster.local\n10.1.1.1 chat.myxcluster.local\n' \
    $'10.1.1.1 chat.myxcluster.local\n' my.cluster

hosts_case "no cluster domain: other .local names stay" \
    $'10.1.1.1 chat.base.local\n10.1.1.4 printer.local\n' \
    $'10.1.1.1 chat.base.local\n10.1.1.4 printer.local\n'

printf '127.0.0.1 localhost\n# MyNodeOne Services - old\n100.64.1.5\ta.base.local\n' >"$HOSTS_FILE"
cp "$HOSTS_FILE" "$HOSTS_FILE.want"
chmod 440 "$HOSTS_FILE"
if [ "$(id -u)" = 0 ]; then
    ok "unwritable file: skipped as root"
elif bash "$HOSTS_SCRIPT" "$HOSTS_FILE" >/dev/null 2>&1; then
    bad "unwritable file is reported"
elif ! cmp -s "$HOSTS_FILE.want" "$HOSTS_FILE"; then
    bad "unwritable file is unchanged"
else
    ok "unwritable file is reported and unchanged"
fi
chmod 640 "$HOSTS_FILE"

if bash "$HOSTS_SCRIPT" "$SANDBOX/no-such-hosts" >/dev/null 2>&1; then
    bad "missing file is reported"
else
    ok "missing file is reported"
fi

assert_has "uninstaller keeps its timestamped backup" "$UNINSTALL" 'cp /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"'
assert_has "uninstaller calls the cleanup" "$UNINSTALL" 'remove_mynodeone_hosts_entries /etc/hosts "${CLUSTER_DOMAIN:-}"'
if grep -nE "sed -i.*/etc/hosts" "$UNINSTALL" >/dev/null; then
    bad "uninstaller has no sed -i on /etc/hosts"
else
    ok "uninstaller has no sed -i on /etc/hosts"
fi

###############################################################################
echo "remove-node.sh: the MinIO report can't stop a removal"
###############################################################################

RM_TREE="$SANDBOX/remove-tree"
RM_BIN="$SANDBOX/remove-bin"
RM_LOG="$SANDBOX/remove.log"
RM_OUT="$SANDBOX/remove.out"
RM_CLEANUP="$RM_TREE/scripts/storage/minio/cleanup-node-minio.sh"
mkdir -p "$RM_TREE/scripts/nodes" "$RM_TREE/scripts/lib" "$RM_TREE/scripts/storage/minio" "$RM_BIN"
cp "$REPO/scripts/lib/service-registry-lib.sh" "$RM_TREE/scripts/lib/"

# A copy that runs without root and can't read the real token file
sed -e 's|if \[ "$EUID" -ne 0 \]; then|if false; then|' \
    -e "s|/etc/mynodeone/api-token|$SANDBOX/no-such-api-token|g" \
    "$REPO/scripts/nodes/remove-node.sh" >"$RM_TREE/scripts/nodes/remove-node.sh"
if grep -qF 'EUID' "$RM_TREE/scripts/nodes/remove-node.sh" || grep -qF '/etc/mynodeone' "$RM_TREE/scripts/nodes/remove-node.sh"; then
    bad "test copy of remove-node.sh is sandboxed"
fi

make_stub "$RM_BIN" curl '
case "$*" in
    *"/api/v1/health"*) printf 200 ;;
    *"-X DELETE"*) echo "{\"status\":\"removed\"}" ;;
    *"/api/v1/nodes"*) echo "{\"nodes\":[{\"name\":\"worker-1\",\"type\":\"worker\",\"ip\":\"100.64.0.9\"},{\"name\":\"laptop-1\",\"type\":\"laptop\",\"ip\":\"100.64.0.10\"}]}" ;;
esac
exit 0'
make_stub "$RM_BIN" kubectl 'echo "{\"metadata\":{\"resourceVersion\":\"1\"},\"data\":{\"registry.json\":\"{}\"}}"'
make_stub "$RM_BIN" tailscale 'echo 100.64.0.1'
for tool in systemctl su ssh-keygen; do
    make_stub "$RM_BIN" "$tool" 'exit 0'
done

set_cleanup() { # <exit status>
    { echo '#!/bin/bash'; echo 'echo "cleanup $*" >>"$STUB_LOG"'; echo "exit $1"; } >"$RM_CLEANUP"
}

run_remove() { # <node name> [extra PATH dir]
    : >"$RM_LOG"
    echo y | PATH="${2:+$2:}$RM_BIN:$PATH" HOME="$SANDBOX" STUB_LOG="$RM_LOG" \
        bash "$RM_TREE/scripts/nodes/remove-node.sh" "$1" >"$RM_OUT" 2>&1
    rm_status=$?
}

assert_removed() { # <description>
    if [ "$rm_status" = 0 ]; then ok "$1: exits 0"; else bad "$1: exits 0 (exit $rm_status)"; fi
    assert_has "$1: removal completes" "$RM_OUT" "Removal Complete"
    assert_has "$1: registry entry removed" "$RM_LOG" "-X DELETE"
    assert_has "$1: sync controller restarted" "$RM_LOG" "systemctl restart mynodeone-sync-controller"
}

set_cleanup 1
run_remove worker-1
assert_removed "cleanup fails"
assert_has "cleanup is asked about this node" "$RM_LOG" "cleanup --node worker-1"
assert_lacks "cleanup is never asked to delete" "$RM_LOG" "--delete"
assert_has "operator is told the check failed" "$RM_OUT" "Could not check for leftover MinIO resources"

set_cleanup 0
run_remove worker-1
assert_removed "cleanup succeeds"
assert_lacks "no warning when the check worked" "$RM_OUT" "Could not check for leftover MinIO resources"

run_remove laptop-1
assert_removed "laptop"
assert_lacks "laptops run no MinIO, so no check" "$RM_LOG" "cleanup "

rm -f "$RM_CLEANUP"
run_remove worker-1
assert_removed "cleanup script missing"

set_cleanup 0
HANG_BIN="$SANDBOX/remove-hang-bin"
mkdir -p "$HANG_BIN"
make_stub "$HANG_BIN" timeout 'exit 124'
run_remove worker-1 "$HANG_BIN"
assert_removed "cleanup hangs and is timed out"
assert_has "the check has a time limit" "$RM_LOG" "timeout 60 bash"

###############################################################################
echo "dead code and leftovers stay gone"
###############################################################################

INSTALLER="$REPO/scripts/installation/install-mynodeone.sh"
for name in detect_disks select_disks_for_setup select_individual_disks setup_disks \
    prepare_disk_for_format setup_longhorn_disks setup_minio_disks setup_raid_array \
    setup_individual_mounts warn_data_loss CRITICAL_OPERATION; do
    assert_lacks "installer has no $name" "$INSTALLER" "$name"
done
if grep -nE '\b(wipefs|mdadm|parted)\b|dd if=' "$INSTALLER" >/dev/null; then
    bad "installer has no disk-wiping commands"
else
    ok "installer has no disk-wiping commands"
fi
if bash -n "$INSTALLER"; then ok "installer parses"; else bad "installer parses"; fi

HEADERS="$REPO/manifests/security/traefik-security-headers.yaml"
count="$(grep -c 'customResponseHeaders:' "$HEADERS")"
if [ "$count" = 1 ]; then ok "one customResponseHeaders key"; else bad "one customResponseHeaders key (found $count)"; fi
assert_has "Permissions-Policy survived the merge" "$HEADERS" "Permissions-Policy:"

assert_lacks "no developer path in test-storageclass.sh" "$REPO/scripts/storage/longhorn/test-storageclass.sh" "/home/"

pin="$(env -u NODE_EXPORTER_VERSION bash -c 'source "$1"; echo "$NODE_EXPORTER_VERSION"' _ "$REPO/scripts/lib/versions.sh")"
if [ "$pin" = "1.7.0" ]; then ok "node_exporter is pinned"; else bad "node_exporter is pinned (got '$pin')"; fi

###############################################################################
echo "uninstall-mynodeone.sh: agent, config API and DNS helpers"
###############################################################################

UN2_ROOT="$SANDBOX/uninstall-root-2"
mkdir -p "$UN2_ROOT/etc/systemd/system" "$UN2_ROOT/usr/local/bin"
for unit in coredns-dns-guardian maintain-dns-config; do
    touch "$UN2_ROOT/etc/systemd/system/$unit.service" "$UN2_ROOT/etc/systemd/system/$unit.timer"
done
touch "$UN2_ROOT/etc/systemd/system/mynodeone-gpu-kernel-sync.service" \
    "$UN2_ROOT/etc/systemd/system/mynodeone-gpu-kernel-sync.timer"
for tool in mynodeone-node-agent mynodeone-config-api coredns-dns-guardian.sh maintain-dns-config.sh unrelated-tool; do
    touch "$UN2_ROOT/usr/local/bin/$tool"
done

: >"$UN_LOG"
PATH="$UN_BIN:$PATH" STUB_LOG="$UN_LOG" bash "$units_script" "$UN2_ROOT" >"$UN_OUT" 2>&1
un_status=$?
if [ "$un_status" = 0 ]; then ok "removal succeeds"; else bad "removal succeeds (exit $un_status)"; fi
for unit in coredns-dns-guardian maintain-dns-config; do
    assert_gone "$unit.service removed" "$UN2_ROOT/etc/systemd/system/$unit.service"
    assert_gone "$unit.timer removed" "$UN2_ROOT/etc/systemd/system/$unit.timer"
    assert_has "$unit.timer stopped first" "$UN_LOG" "$unit.timer"
done
for tool in mynodeone-node-agent mynodeone-config-api coredns-dns-guardian.sh maintain-dns-config.sh; do
    assert_gone "$tool removed" "$UN2_ROOT/usr/local/bin/$tool"
done
assert_exists "unrelated tool kept" "$UN2_ROOT/usr/local/bin/unrelated-tool"
assert_exists "GPU kernel sync service kept" "$UN2_ROOT/etc/systemd/system/mynodeone-gpu-kernel-sync.service"
assert_exists "GPU kernel sync timer kept" "$UN2_ROOT/etc/systemd/system/mynodeone-gpu-kernel-sync.timer"
assert_lacks "GPU kernel sync not stopped" "$UN_LOG" "mynodeone-gpu-kernel-sync"

###############################################################################
echo "Pinned versions and plain wording"
###############################################################################

EDGE="$REPO/scripts/setup/setup-edge-node.sh"
assert_has "edge node uses the Traefik pin" "$EDGE" 'image: traefik:${TRAEFIK_VPS_VERSION}'
assert_lacks "edge node has no v-prefixed Traefik tag" "$EDGE" 'traefik:v'
assert_lacks "edge node doesn't set its own node_exporter version" "$EDGE" 'NODE_EXPORTER_VERSION="'
assert_has "edge node sources versions.sh" "$EDGE" 'lib/versions.sh'
assert_has "VPS node uses the same Traefik pin" "$REPO/scripts/setup/setup-vps-node.sh" 'TRAEFIK_VPS_VERSION'
assert_lacks "no marketing claim in the bootstrap" "$REPO/scripts/installation/bootstrap-control-plane.sh" 'production-grade security'

for doc in docs/operations/troubleshooting.md docs/architecture/NETWORKING.md; do
    if grep -nE '^[[:space:]]*(sudo )?ufw allow [^#]*8472' "$REPO/$doc" >/dev/null; then
        bad "$doc has no command opening 8472"
    else
        ok "$doc has no command opening 8472"
    fi
done

###############################################################################
echo "cleanup-hosts-backups.sh"
###############################################################################

CLEANUP="$REPO/scripts/domains/cleanup-hosts-backups.sh"
HB_DIR="$SANDBOX/hosts-backups"
HB_OUT="$SANDBOX/hosts-backups.out"

# Twenty backups a day apart, and neighbours it must never touch.
fill_backup_dir() {
    local i
    rm -rf "$HB_DIR"
    mkdir -p "$HB_DIR"
    for i in $(seq -w 1 20); do
        head -c 1024 /dev/zero >"$HB_DIR/hosts.backup.202601${i}_000000"
        touch -d "2026-01-$i 00:00:00" "$HB_DIR/hosts.backup.202601${i}_000000"
    done
    touch "$HB_DIR/hosts" "$HB_DIR/hosts.bak.1" "$HB_DIR/hosts.backup.123" "$HB_DIR/hosts.backup.foo" \
        "$HB_DIR/hosts.backup.1_2x" "$HB_DIR/xhosts.backup.1_2" "$HB_DIR/hosts.backup.1_2.gz"
}
backup_count() { find "$HB_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/hosts\.backup\.[0-9]+_[0-9]+' | wc -l; }
neighbours_kept() {
    local name
    for name in hosts hosts.bak.1 hosts.backup.123 hosts.backup.foo hosts.backup.1_2x xhosts.backup.1_2 hosts.backup.1_2.gz; do
        assert_exists "$1: $name untouched" "$HB_DIR/$name"
    done
}

fill_backup_dir
bash "$CLEANUP" --dir "$HB_DIR" >"$HB_OUT" 2>&1
hb_status=$?
if [ "$hb_status" = 0 ]; then ok "dry run succeeds"; else bad "dry run succeeds (exit $hb_status)"; fi
if [ "$(backup_count)" = 20 ]; then ok "dry run deletes nothing"; else bad "dry run deletes nothing ($(backup_count) left)"; fi
assert_has "dry run gives the count and size" "$HB_OUT" "20 files, 20.0 KiB"
assert_has "dry run says what it would delete" "$HB_OUT" "Would delete: 14 files, 14.0 KiB"
assert_has "dry run lists the newest" "$HB_OUT" "hosts.backup.20260120_000000"
assert_has "dry run lists the oldest" "$HB_OUT" "hosts.backup.20260101_000000"
assert_lacks "dry run doesn't list a doomed file as kept" "$HB_OUT" "hosts.backup.20260110_000000"
neighbours_kept "dry run"

bash "$CLEANUP" --dir "$HB_DIR" --apply >"$HB_OUT" 2>&1
hb_status=$?
if [ "$hb_status" = 0 ]; then ok "--apply succeeds"; else bad "--apply succeeds (exit $hb_status)"; fi
if [ "$(backup_count)" = 6 ]; then ok "--apply leaves newest 5 plus oldest"; else bad "--apply leaves 6 ($(backup_count) left)"; fi
for name in 20260101 20260116 20260117 20260118 20260119 20260120; do
    assert_exists "$name kept" "$HB_DIR/hosts.backup.${name}_000000"
done
assert_gone "next oldest removed" "$HB_DIR/hosts.backup.20260102_000000"
assert_gone "sixth newest removed" "$HB_DIR/hosts.backup.20260115_000000"
assert_has "--apply reports the result" "$HB_OUT" "Deleted 14 files, 14.0 KiB. 6 backups remain."
neighbours_kept "--apply"

bash "$CLEANUP" --dir "$HB_DIR" --apply >"$HB_OUT" 2>&1
assert_has "second --apply has nothing to do" "$HB_OUT" "Nothing to delete."

fill_backup_dir
bash "$CLEANUP" --dir "$HB_DIR" --keep 2 --apply >"$HB_OUT" 2>&1
if [ "$(backup_count)" = 3 ]; then ok "--keep 2 leaves three"; else bad "--keep 2 leaves three ($(backup_count) left)"; fi

fill_backup_dir
for bad_keep in 0 -1 abc ""; do
    if bash "$CLEANUP" --dir "$HB_DIR" --keep "$bad_keep" --apply >"$HB_OUT" 2>&1; then
        bad "--keep '$bad_keep' refused"
    else
        ok "--keep '$bad_keep' refused"
    fi
done
if [ "$(backup_count)" = 20 ]; then ok "bad options delete nothing"; else bad "bad options delete nothing"; fi

HB_OUTSIDE="$SANDBOX/hosts-backups-outside"
mkdir -p "$HB_OUTSIDE"
touch "$HB_OUTSIDE/precious"
ln -s "$HB_OUTSIDE/precious" "$HB_DIR/hosts.backup.99990101_000000"
if bash "$CLEANUP" --dir "$HB_DIR" --apply >"$HB_OUT" 2>&1; then bad "symlink backup refused"; else ok "symlink backup refused"; fi
assert_has "the refusal names it" "$HB_OUT" "hosts.backup.99990101_000000"
assert_exists "symlink target kept" "$HB_OUTSIDE/precious"
if [ "$(backup_count)" = 20 ]; then ok "symlink refusal deletes nothing"; else bad "symlink refusal deletes nothing"; fi
rm "$HB_DIR/hosts.backup.99990101_000000"

ln -s "$HB_DIR" "$SANDBOX/hosts-backups-link"
for link in "$SANDBOX/hosts-backups-link" "$SANDBOX/hosts-backups-link/"; do
    if bash "$CLEANUP" --dir "$link" --apply >"$HB_OUT" 2>&1; then bad "--dir symlink refused ($link)"; else ok "--dir symlink refused ($link)"; fi
done
if [ "$(backup_count)" = 20 ]; then ok "--dir symlink refusal deletes nothing"; else bad "--dir symlink refusal deletes nothing"; fi

if bash "$CLEANUP" --dir "$SANDBOX/no-such-dir" >"$HB_OUT" 2>&1; then bad "missing --dir refused"; else ok "missing --dir refused"; fi
if bash "$CLEANUP" --bogus >"$HB_OUT" 2>&1; then bad "unknown option refused"; else ok "unknown option refused"; fi

touch -d '1 minute ago' "$HB_DIR/hosts.backup.20260120_000000"
bash "$CLEANUP" --dir "$HB_DIR" >"$HB_OUT" 2>&1
assert_has "warns when a backup is recent" "$HB_OUT" "update it first"

mkdir -p "$SANDBOX/hosts-backups-empty"
bash "$CLEANUP" --dir "$SANDBOX/hosts-backups-empty" >"$HB_OUT" 2>&1
assert_has "empty directory is fine" "$HB_OUT" "Nothing to do."

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
