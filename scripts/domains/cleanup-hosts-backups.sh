#!/bin/bash
###############################################################################
# One-off cleanup of the /etc/hosts.backup.* files left by the old sync-dns.sh,
# which made one a minute. Update the script the timer runs first, or they come back.
#
# Shows what it would do unless given --apply. Keeps the newest N files and the
# oldest, which is the closest thing to the file from before MyNodeOne managed it.
# Only regular files named hosts.backup.<digits>_<digits> directly in the directory
# are candidates. Safe with hundreds of thousands of them: nothing goes through a
# shell glob and rm runs in batches.
#
#   bash scripts/domains/cleanup-hosts-backups.sh [--keep N] [--dir DIR]
#   sudo bash scripts/domains/cleanup-hosts-backups.sh --apply [--keep N] [--dir DIR]
###############################################################################

set -euo pipefail

export LC_ALL=C

DIR=/etc
KEEP=5
APPLY=false

usage() {
    cat <<'EOF'
Usage: cleanup-hosts-backups.sh [--apply] [--keep N] [--dir DIR]

Reports the hosts.backup.<digits>_<digits> files in DIR and what would be kept.
Deletes nothing without --apply.

  --apply     Delete the files instead of reporting them. Needs write access to DIR.
  --keep N    Keep the newest N files, plus the oldest (default 5, at least 1).
  --dir DIR   Directory to look in (default /etc).
EOF
}

die() {
    echo "Error: $1" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --keep)
            [[ $# -ge 2 ]] || die "--keep needs a value"
            KEEP="$2"
            shift 2
            ;;
        --dir)
            [[ $# -ge 2 ]] || die "--dir needs a value"
            DIR="$2"
            shift 2
            ;;
        -h | --help) usage; exit 0 ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a whole number of at least 1, got: $KEEP"

# Without the trailing slash, -L would look through a symlink instead of at it.
while [[ "$DIR" == */ && "$DIR" != / ]]; do
    DIR="${DIR%/}"
done
[[ ! -L "$DIR" ]] || die "$DIR is a symlink; give the real directory"
[[ -d "$DIR" ]] || die "not a directory: $DIR"
cd "$DIR"
DIR="$PWD"

# Anything here that isn't a regular file wasn't made by a backup and shouldn't be
# acted on. A symlink could point anywhere. find doesn't follow it, but stop and ask.
unexpected=$(find . -mindepth 1 -maxdepth 1 -name 'hosts.backup.*' ! -type f -printf '  %f (%y) %l\n' | head -n 20)
if [[ -n "$unexpected" ]]; then
    echo "Error: $DIR has entries named hosts.backup.* that aren't regular files:" >&2
    printf '%s\n' "$unexpected" >&2
    die "refusing to continue; deal with them first"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Newest first, with the name deciding ties: <mtime> <bytes> <name>
find . -mindepth 1 -maxdepth 1 -type f -regextype posix-extended \
    -regex '\./hosts\.backup\.[0-9]+_[0-9]+' -printf '%T@ %s %f\n' |
    sort -t ' ' -k1,1nr -k3,3r >"$WORK/all"

human() {
    awk -v bytes="$1" 'BEGIN {
        split("B KiB MiB GiB TiB", unit, " ")
        i = 1
        while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
        if (i == 1) printf "%d B\n", bytes
        else printf "%.1f %s\n", bytes, unit[i]
    }'
}

total_size() { awk '{ sum += $2 } END { printf "%.0f\n", sum }' "$1"; }

TOTAL=$(wc -l <"$WORK/all")
TOTAL=$((TOTAL + 0))

echo "Directory: $DIR"
echo "Backups:   $TOTAL files, $(human "$(total_size "$WORK/all")")"

if ((TOTAL == 0)); then
    echo "Nothing to do."
    exit 0
fi

awk -v keep="$KEEP" -v total="$TOTAL" 'NR <= keep || NR == total' "$WORK/all" >"$WORK/kept"
awk -v keep="$KEEP" -v total="$TOTAL" 'NR > keep && NR < total' "$WORK/all" >"$WORK/doomed"
DELETE_COUNT=$(wc -l <"$WORK/doomed")
DELETE_COUNT=$((DELETE_COUNT + 0))
DELETE_SIZE=$(human "$(total_size "$WORK/doomed")")

echo "Keeping:   the newest $KEEP and the oldest"
while read -r mtime size name; do
    printf '  %s  %s  %s\n' "$name" "$(date -d "@${mtime%.*}" '+%Y-%m-%d %H:%M:%S')" "$(human "$size")"
done <"$WORK/kept"

# A very recent backup suggests something is still writing them.
newest=$(awk 'NR == 1 { print int($1) }' "$WORK/all")
age=$(($(date +%s) - newest))
if ((age < 300)); then
    echo "Warning: the newest backup is ${age}s old. If the timer still runs the old"
    echo "         sync-dns.sh, update it first or the backups will come back."
fi

if ((DELETE_COUNT == 0)); then
    echo "Nothing to delete."
    exit 0
fi

if ! "$APPLY"; then
    echo "Would delete: $DELETE_COUNT files, $DELETE_SIZE"
    echo "Dry run, nothing deleted. Re-run with --apply to delete them."
    exit 0
fi

[[ -w . ]] || die "no write access to $DIR; run this with sudo"

# Names are digits and dots by now (the regex above), so they can't split or look
# like options, and they are relative to this directory.
awk '{ print $3 }' "$WORK/doomed" | tr '\n' '\0' | xargs -0 -r rm -f --

REMAINING=$(find . -mindepth 1 -maxdepth 1 -type f -regextype posix-extended \
    -regex '\./hosts\.backup\.[0-9]+_[0-9]+' -printf '.' | wc -c)
echo "Deleted $DELETE_COUNT files, $DELETE_SIZE. $((REMAINING + 0)) backups remain."
