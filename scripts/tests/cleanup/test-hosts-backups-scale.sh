#!/bin/bash
###############################################################################
# Proves the /etc/hosts backup cleanup works at the scale a real host reached.
#
# Makes 250,000 empty files in a temp dir, so this takes a minute and isn't part of
# run-tests.sh. Stubs stand in for everything that could reach the real system, and
# the sync-dns.sh prune runs against the temp dir only.
#
#   bash scripts/tests/cleanup/test-hosts-backups-scale.sh [file-count]
###############################################################################

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
COUNT="${1:-250000}"
CLEANUP="$REPO/scripts/domains/cleanup-hosts-backups.sh"
ROUTING_STUBS="$REPO/scripts/tests/routing/stubs"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok() { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAILED: $1"; }
matching() { find "$1" -maxdepth 1 -type f -name 'hosts.backup.[0-9]*_[0-9]*' -printf '.' | wc -c; }

# <dir>: $COUNT empty backups, oldest first, each a second newer than the last.
fill() {
    mkdir -p "$1"
    (
        cd "$1" || exit 1
        awk -v n="$COUNT" 'BEGIN { for (i = 1; i <= n; i++) printf "hosts.backup.20260101_%09d\n", i }' |
            xargs touch
        touch -d '2026-01-01 00:00:00' hosts.backup.20260101_000000001
        touch -d '+1 day' "$(printf 'hosts.backup.20260101_%09d' "$COUNT")"
        touch hosts hosts.bak.1 hosts.backup.foo
    )
    echo "  $(matching "$1") files in $1"
}

kept_ok() {
    local dir="$1" expected="$2"
    if [ "$(matching "$dir")" = "$expected" ]; then
        ok "$expected backups remain"
    else
        bad "$expected backups remain (found $(matching "$dir"))"
    fi
    if [ -e "$dir/hosts.backup.20260101_000000001" ]; then ok "oldest kept"; else bad "oldest kept"; fi
    if [ -e "$dir/$(printf 'hosts.backup.20260101_%09d' "$COUNT")" ]; then ok "newest kept"; else bad "newest kept"; fi
    if [ -e "$dir/hosts" ] && [ -e "$dir/hosts.bak.1" ] && [ -e "$dir/hosts.backup.foo" ]; then
        ok "other files untouched"
    else
        bad "other files untouched"
    fi
}

###############################################################################
echo "cleanup-hosts-backups.sh with $COUNT files"
###############################################################################

DIR="$WORK/tool"
fill "$DIR"

# The failure this guards against: a glob of this many names doesn't fit in argv.
if (cd "$DIR" && /bin/ls -1t hosts.backup.[0-9]*_[0-9]* >/dev/null 2>"$WORK/ls.err"); then
    echo "  note: the old ls glob did not hit the limit here ($COUNT files)"
elif grep -q 'Argument list too long' "$WORK/ls.err"; then
    ok "an ls glob of these names hits the argument limit, as it did for the old prune"
else
    echo "  note: the ls glob failed differently: $(cat "$WORK/ls.err")"
fi

bash "$CLEANUP" --dir "$DIR" >"$WORK/dry.out" 2>&1
status=$?
if [ "$status" = 0 ]; then ok "dry run succeeds"; else bad "dry run succeeds (exit $status)"; sed 's/^/    /' "$WORK/dry.out"; fi
if grep -qF "Backups:   $COUNT files" "$WORK/dry.out"; then ok "dry run counts them"; else bad "dry run counts them"; fi
if grep -qF "Would delete: $((COUNT - 6)) files" "$WORK/dry.out"; then ok "dry run reports the deletions"; else bad "dry run reports the deletions"; fi
if [ "$(matching "$DIR")" = "$COUNT" ]; then ok "dry run deletes nothing"; else bad "dry run deletes nothing"; fi

bash "$CLEANUP" --dir "$DIR" --apply >"$WORK/apply.out" 2>&1
status=$?
if [ "$status" = 0 ]; then ok "--apply succeeds"; else bad "--apply succeeds (exit $status)"; sed 's/^/    /' "$WORK/apply.out"; fi
kept_ok "$DIR" 6
tail -n 1 "$WORK/apply.out" | sed 's/^/  /'
rm -rf "$DIR"

###############################################################################
echo "sync-dns.sh prune with $COUNT files"
###############################################################################

DIR="$WORK/sync"
fill "$DIR"
BIN="$WORK/bin"
K8S="$WORK/k8s"
HOME_DIR="$WORK/home"
mkdir -p "$BIN" "$K8S/cm" "$WORK/systemd" "$HOME_DIR/.mynodeone"
for stub in kubectl curl ssh systemctl sudo tailscale docker getent; do
    install -m 755 "$ROUTING_STUBS/$stub" "$BIN/$stub"
done
printf 'CLUSTER_DOMAIN=testcluster\n' >"$HOME_DIR/.mynodeone/config.env"
jq -n --arg v '{"a/good":{"ip":"100.64.1.5","local_name":"good"}}' \
    '{metadata: {name: "service-registry", resourceVersion: "1"}, data: {"services.json": $v}}' \
    >"$K8S/cm/service-registry.json"
printf '127.0.0.1 localhost\n' >"$DIR/hosts"
: >"$WORK/kubeconfig"

env -u SUDO_USER -u PROJECT_ROOT -u CLUSTER_DOMAIN \
    PATH="$BIN:/usr/local/bin:/usr/bin:/bin" HOME="$HOME_DIR" ACTUAL_HOME="$HOME_DIR" \
    KUBECONFIG="$WORK/kubeconfig" FAKE_K8S="$K8S" FAKE_SYSTEMD="$WORK/systemd" \
    FAKE_API="$WORK" FAKE_SSH="$WORK" FAKE_DOCKER="$WORK" \
    MYNODEONE_HOSTS_FILE="$DIR/hosts" \
    bash "$REPO/scripts/domains/sync-dns.sh" --quiet >"$WORK/sync.out" 2>&1
status=$?
if [ "$status" = 0 ]; then ok "sync-dns.sh succeeds"; else bad "sync-dns.sh succeeds (exit $status)"; sed 's/^/    /' "$WORK/sync.out"; fi
if grep -q 'Could not prune' "$WORK/sync.out"; then bad "prune didn't warn"; else ok "prune didn't warn"; fi
if grep -q 'good.testcluster.local' "$DIR/hosts"; then ok "hosts written"; else bad "hosts written"; fi
# The newest five of what's there include the backup this run made.
kept_oldest_newest=true
[ "$(matching "$DIR")" = 6 ] || kept_oldest_newest=false
[ -e "$DIR/hosts.backup.20260101_000000001" ] || kept_oldest_newest=false
if "$kept_oldest_newest"; then ok "pruned to the newest 5 and the oldest"; else bad "pruned to the newest 5 and the oldest (found $(matching "$DIR"))"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
