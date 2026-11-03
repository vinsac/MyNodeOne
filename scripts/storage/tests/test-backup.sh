#!/bin/bash

# Tests for the llmapi Postgres backup and restore manifests.
#
# The manifests are parsed statically. Their embedded scripts then run in a temp
# directory with fake pg_dump, pg_restore, psql and createdb, so these tests prove
# the script's logic. They don't prove a dump restores on a real Postgres: the real
# round trip is described in the manifest and still has to be run on a cluster.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

if ! "$REAL_PYTHON" -c 'import yaml' 2>/dev/null; then
    echo "PyYAML is needed for these tests." >&2
    exit 2
fi

echo "--- Manifests"

if output="$("$REAL_PYTHON" "$TESTS_DIR/check_manifests.py" "$REPO_ROOT" "$WORK" 2>&1)"; then
    pass "all manifest checks ($(printf '%s\n' "$output" | "$BIN/grep" -c '^ok'))"
else
    fail "manifest checks" "$output"
fi

if [[ ! -s "$WORK/backup-job.sh" || ! -s "$WORK/restore-job.sh" ]]; then
    fail "embedded scripts were not extracted"
    finish
    exit 1
fi

# These jobs use rm, mv and ls for real, but only inside BACKUP_DIR, so they get their
# own PATH. pg tools are fakes, and what the database receives goes to PG_LOG.
PGBIN="$WORK/pgbin"
"$(command -v mkdir)" -p "$PGBIN" "$WORK/backups"
for tool in sh rm mv ls sort tail wc sha256sum sed date cat cut tr test; do
    "$REAL_LN" -s "$(command -v "$tool")" "$PGBIN/$tool"
done

pg_stub() {
    {
        echo "#!$REAL_BASH"
        printf '%s\n' "$2"
    } > "$PGBIN/$1"
    "$REAL_CHMOD" +x "$PGBIN/$1"
}

pg_stub pg_dump 'printf "%s\n" "pg_dump $*" >> "$PG_LOG"
[[ "${FAKE_DUMP:-ok}" == "fail" ]] && { echo "partial" > "${2#--file=}"; exit 1; }
[[ "${FAKE_DUMP:-ok}" == "empty" ]] && { : > "${2#--file=}"; exit 0; }
echo "fake dump of $PGDATABASE" > "${2#--file=}"'

pg_stub pg_restore 'printf "%s\n" "pg_restore $*" >> "$PG_LOG"
[[ "${FAKE_RESTORE:-ok}" == "fail" ]] && exit 1
exit 0'

pg_stub psql 'printf "%s\n" "psql $*" >> "$PG_LOG"
[[ -n "${FAKE_DB_EXISTS:-}" ]] && echo 1
exit 0'

pg_stub createdb 'printf "%s\n" "createdb $*" >> "$PG_LOG"'

run_job() {
    local script="$1"
    shift
    OUT="$(env -i PATH="$PGBIN" PG_LOG="$WORK/pg.log" BACKUP_DIR="$WORK/backups" PGDATABASE=llmapi "$@" \
        "$PGBIN/sh" "$script" 2>&1)"
    RC=$?
}

dumps() {
    "$PGBIN/ls" -1A "$WORK/backups" | "$BIN/grep" -c '^llmapi-.*\.dump$'
}

empty_backups() {
    "$REAL_RM" -rf "$WORK/backups"
    "$(command -v mkdir)" -p "$WORK/backups"
    : > "$WORK/pg.log"
}

expect_dumps() {
    local name="$1" want="$2" got
    got="$(dumps)"
    if [[ "$got" -eq "$want" ]]; then
        pass "$name: $want dump(s) on the volume"
    else
        fail "$name: expected $want dumps, found $got" "$("$PGBIN/ls" -lA "$WORK/backups")"
    fi
}

expect_pg_log() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$WORK/pg.log"; then
        pass "$name: ran /$pattern/"
    else
        fail "$name: didn't run /$pattern/" "$("$BIN/cat" "$WORK/pg.log")"
    fi
}

expect_no_pg_log() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$WORK/pg.log"; then
        fail "$name: ran unwanted /$pattern/" "$("$BIN/cat" "$WORK/pg.log")"
    else
        pass "$name: didn't run /$pattern/"
    fi
}

echo
echo "--- Dump job"

BACKUP="$WORK/backup-job.sh"
RESTORE="$WORK/restore-job.sh"

empty_backups
run_job "$BACKUP" KEEP_DUMPS=3
expect_rc "good dump" 0
expect_dumps "good dump" 1
expect_pg_log "good dump" '^pg_dump --format=custom'
expect_pg_log "dump is checked" '^pg_restore --list'
dump_file="$("$PGBIN/ls" -1 "$WORK/backups" | "$BIN/grep" '\.dump$')"
if (cd "$WORK/backups" && "$PGBIN/sha256sum" -c "$dump_file.sha256" >/dev/null 2>&1); then
    pass "good dump: checksum file names the final file and verifies"
else
    fail "good dump: checksum doesn't verify" "$("$BIN/cat" "$WORK/backups/$dump_file.sha256")"
fi
mode="$(stat -c '%a' "$WORK/backups/$dump_file")"
if [[ "$mode" == "600" ]]; then
    pass "good dump: file is mode 600"
else
    fail "good dump: file is mode $mode"
fi

for failure in "FAKE_DUMP=fail" "FAKE_DUMP=empty" "FAKE_RESTORE=fail"; do
    empty_backups
    echo "previous" > "$WORK/backups/llmapi-20200101T000000Z.dump"
    run_job "$BACKUP" KEEP_DUMPS=1 "$failure"
    expect_rc_nonzero "$failure"
    expect_dumps "$failure keeps the last good dump" 1
    if [[ -e "$WORK/backups/llmapi-20200101T000000Z.dump" ]]; then
        pass "$failure: previous dump still there"
    else
        fail "$failure: previous dump was removed"
    fi
    if "$PGBIN/ls" -1A "$WORK/backups" | "$BIN/grep" -q '\.tmp$'; then
        fail "$failure: left a temp file"
    else
        pass "$failure: no temp file left"
    fi
done

empty_backups
for day in 01 02 03 04 05; do
    echo old > "$WORK/backups/llmapi-202001${day}T000000Z.dump"
    echo sum > "$WORK/backups/llmapi-202001${day}T000000Z.dump.sha256"
done
echo stale > "$WORK/backups/.llmapi-20200101T000000Z.tmp"
echo mine > "$WORK/backups/notes.txt"
run_job "$BACKUP" KEEP_DUMPS=3
expect_rc "retention" 0
expect_dumps "retention" 3
for kept in 20200105 20200104; do
    if [[ -e "$WORK/backups/llmapi-${kept}T000000Z.dump" ]]; then
        pass "retention keeps newest: $kept"
    else
        fail "retention removed $kept"
    fi
done
if [[ -e "$WORK/backups/llmapi-20200101T000000Z.dump.sha256" ]]; then
    fail "retention left a checksum behind"
else
    pass "retention removes the checksum too"
fi
if [[ -e "$WORK/backups/.llmapi-20200101T000000Z.tmp" ]]; then
    fail "stale temp file wasn't cleaned up"
else
    pass "stale temp file cleaned up"
fi
if [[ -e "$WORK/backups/notes.txt" ]]; then
    pass "retention leaves other files alone"
else
    fail "retention removed an unrelated file"
fi

empty_backups
echo old > "$WORK/backups/llmapi-20200101T000000Z.dump"
run_job "$BACKUP" KEEP_DUMPS=0
expect_rc_nonzero "KEEP_DUMPS=0 refused"
if [[ -e "$WORK/backups/llmapi-20200101T000000Z.dump" ]]; then
    pass "KEEP_DUMPS=0 removes nothing"
else
    fail "KEEP_DUMPS=0 removed a dump"
fi

echo
echo "--- Restore job"

reset_restore() {
    empty_backups
    echo dump > "$WORK/backups/x.dump"
    (cd "$WORK/backups" && "$PGBIN/sha256sum" x.dump > x.dump.sha256)
}

restore_env=(DUMP_FILE=x.dump TARGET_DB=llmapi_restore_test OVERWRITE_LIVE=no)

reset_restore
run_job "$RESTORE" DUMP_FILE=DUMP_FILE_PLACEHOLDER TARGET_DB=TARGET_DB_PLACEHOLDER OVERWRITE_LIVE=OVERWRITE_LIVE_PLACEHOLDER
expect_rc_nonzero "placeholders left in"
expect_no_pg_log "placeholders left in" 'pg_restore'

reset_restore
run_job "$RESTORE" DUMP_FILE=x.dump TARGET_DB=llmapi OVERWRITE_LIVE=no
expect_rc_nonzero "live database without OVERWRITE_LIVE"
expect_output "live database without OVERWRITE_LIVE" "Refusing to overwrite"
expect_no_pg_log "live database without OVERWRITE_LIVE" 'pg_restore'

reset_restore
run_job "$RESTORE" DUMP_FILE=x.dump TARGET_DB=llmapi OVERWRITE_LIVE=true
expect_rc_nonzero "OVERWRITE_LIVE must be exactly yes"
expect_no_pg_log "OVERWRITE_LIVE must be exactly yes" 'pg_restore'

for bad in 'x;drop' 'X' 'a b' ''; do
    reset_restore
    run_job "$RESTORE" DUMP_FILE=x.dump "TARGET_DB=$bad" OVERWRITE_LIVE=no
    expect_rc_nonzero "target database '$bad'"
    expect_no_pg_log "target database '$bad'" 'psql|createdb|pg_restore'
done

reset_restore
run_job "$RESTORE" "${restore_env[@]}"
expect_rc "scratch restore" 0
expect_pg_log "scratch restore" '^createdb --maintenance-db=postgres llmapi_restore_test'
expect_pg_log "scratch restore" '^pg_restore --clean --if-exists --no-owner --no-privileges --single-transaction --exit-on-error --dbname=llmapi_restore_test x.dump'

reset_restore
run_job "$RESTORE" "${restore_env[@]}" FAKE_DB_EXISTS=1
expect_rc "target already exists" 0
expect_no_pg_log "target already exists" 'createdb'

reset_restore
run_job "$RESTORE" DUMP_FILE=x.dump TARGET_DB=llmapi OVERWRITE_LIVE=yes FAKE_DB_EXISTS=1
expect_rc "live restore, explicitly allowed" 0
expect_pg_log "live restore, explicitly allowed" '--dbname=llmapi x.dump'

reset_restore
echo corrupted >> "$WORK/backups/x.dump"
run_job "$RESTORE" "${restore_env[@]}"
expect_rc_nonzero "corrupted dump"
expect_no_pg_log "corrupted dump" '--dbname'

reset_restore
run_job "$RESTORE" DUMP_FILE=absent.dump TARGET_DB=llmapi_restore_test OVERWRITE_LIVE=no
expect_rc_nonzero "missing dump file"
expect_no_pg_log "missing dump file" '--dbname'

reset_restore
run_job "$RESTORE" "${restore_env[@]}" FAKE_RESTORE=fail
expect_rc_nonzero "pg_restore fails"
expect_no_output "pg_restore fails" "^Restored"

finish
