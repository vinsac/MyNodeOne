#!/bin/bash

# Tests for velero/configure-backup.sh and velero/install.sh, against a fake kubectl
# and velero. Nothing reaches a cluster or a backup destination.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

CONFIGURE="$REPO_ROOT/scripts/storage/velero/configure-backup.sh"
INSTALL="$REPO_ROOT/scripts/storage/velero/install.sh"

# The root check can't be met in a test, so it's replaced. Everything else is real.
RUN_MAIN="source '$CONFIGURE'; check_requirements() { :; }; main"

scenario() {
    "$BIN/cat" > "$FAKE_SCENARIO"
}

no_cluster_calls() {
    local name="$1"
    if [[ -s "$FAKE_CLI_LOG" ]]; then
        fail "$name: touched the cluster" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    else
        pass "$name: no kubectl or velero call"
    fi
}

expect_cli() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$FAKE_CLI_LOG"; then
        pass "$name: called /$pattern/"
    else
        fail "$name: no call matching /$pattern/" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    fi
}

expect_no_cli() {
    local name="$1" pattern="$2"
    if "$BIN/grep" -qE -- "$pattern" "$FAKE_CLI_LOG"; then
        fail "$name: unwanted call /$pattern/" "$("$BIN/cat" "$FAKE_CLI_LOG")"
    else
        pass "$name: no call matching /$pattern/"
    fi
}

echo "--- There's no default destination"

reset_state
sandbox_bash "'$REAL_BASH' '$CONFIGURE'"
expect_rc_nonzero "nothing configured"
expect_output "nothing configured" "No backup destination is configured"
expect_output "nothing configured" "backup.env.example"
no_cluster_calls "nothing configured"

reset_state
sandbox_bash "VELERO_BACKUP_TARGET=nas '$REAL_BASH' '$CONFIGURE'"
expect_rc_nonzero "unknown target"
no_cluster_calls "unknown target"

reset_state
sandbox_bash "VELERO_BACKUP_TARGET=minio '$REAL_BASH' '$CONFIGURE'"
expect_rc_nonzero "minio with no bucket"
expect_output "minio with no bucket" "needs VELERO_BUCKET"
no_cluster_calls "minio with no bucket"

: > "$WORK/creds"
for missing in VELERO_S3_URL VELERO_BUCKET VELERO_REGION VELERO_CREDENTIALS_FILE; do
    reset_state
    settings="VELERO_BACKUP_TARGET=s3 VELERO_S3_URL=https://s3.example.com VELERO_BUCKET=b1 VELERO_REGION=r1 VELERO_CREDENTIALS_FILE=$WORK/creds"
    settings="$(printf '%s' "$settings" | "$BIN/sed" -E "s#$missing=[^ ]+##")"
    sandbox_bash "$settings '$REAL_BASH' '$CONFIGURE'"
    expect_rc_nonzero "s3 without $missing"
    expect_output "s3 without $missing" "needs $missing"
    no_cluster_calls "s3 without $missing"
done

reset_state
sandbox_bash "VELERO_BACKUP_TARGET=s3 VELERO_S3_URL='http://x\$(id)' VELERO_BUCKET=b1 VELERO_REGION=r1 VELERO_CREDENTIALS_FILE=$WORK/creds '$REAL_BASH' '$CONFIGURE'"
expect_rc_nonzero "URL with shell text"
no_cluster_calls "URL with shell text"

echo
echo "--- Retention"

for pair in "180 4320h0m0s" "30 720h0m0s" "1 24h0m0s"; do
    days="${pair% *}"
    want="${pair#* }"
    sandbox_bash "source '$CONFIGURE'; retention_days_to_ttl $days"
    if [[ "$OUT" == "$want" ]]; then
        pass "$days days is $want"
    else
        fail "$days days: expected $want, got $OUT"
    fi
done

for bad in 0 -1 abc 1.5 ""; do
    sandbox_bash "source '$CONFIGURE'; retention_days_to_ttl '$bad'"
    expect_rc_nonzero "retention '$bad'"
done

reset_state
sandbox_bash "VELERO_BACKUP_TARGET=minio VELERO_BUCKET=b1 VELERO_FULL_RETENTION_DAYS=abc '$REAL_BASH' '$CONFIGURE'"
expect_rc_nonzero "bad retention setting"
no_cluster_calls "bad retention setting"

echo
echo "--- Config file"

"$BIN/cat" > "$WORK/good.env" <<EOF
# comment

VELERO_BACKUP_TARGET=s3
VELERO_S3_URL=https://s3.example.com
VELERO_BUCKET="quoted-bucket"
VELERO_REGION=file-region
VELERO_FULL_SCHEDULE=0 2 1 * *
EOF
sandbox_bash "VELERO_REGION=env-region; source '$CONFIGURE'; load_config_file '$WORK/good.env' && echo \"\$VELERO_BACKUP_TARGET|\$VELERO_BUCKET|\$VELERO_REGION|\$VELERO_FULL_SCHEDULE\""
if [[ "$OUT" == *"s3|quoted-bucket|env-region|0 2 1 * *"* ]]; then
    pass "config file parsed, quotes removed, environment wins"
else
    fail "config file parse" "$OUT"
fi

# Only an absent file proves the command wasn't run, so the marker is in the sandbox.
"$BIN/cat" > "$WORK/evil.env" <<EOF
VELERO_BUCKET=\$(: > $WORK/pwned1)
\`: > $WORK/pwned2\`
EOF
sandbox_bash "source '$CONFIGURE'; load_config_file '$WORK/evil.env'"
expect_rc_nonzero "config with a command line"
"$BIN/cat" > "$WORK/evil2.env" <<EOF
VELERO_BUCKET=\$(: > $WORK/pwned1)
EOF
sandbox_bash "source '$CONFIGURE'; load_config_file '$WORK/evil2.env'; validate_config"
expect_rc_nonzero "config value with a command substitution"
if [[ -e "$WORK/pwned1" || -e "$WORK/pwned2" ]]; then
    fail "config file ran a command"
else
    pass "config file is parsed, not executed"
fi

echo 'PATH=/tmp/evil' > "$WORK/unknown.env"
sandbox_bash "source '$CONFIGURE'; load_config_file '$WORK/unknown.env'"
expect_rc_nonzero "unknown setting"
expect_output "unknown setting" "Unknown setting"

sandbox_bash "'$REAL_BASH' '$CONFIGURE' --config '$WORK/absent.env'"
expect_rc_nonzero "missing config file"

# The shipped example must parse, and must not choose a destination by itself.
EXAMPLE="$REPO_ROOT/scripts/storage/velero/backup.env.example"
reset_state
sandbox_bash "'$REAL_BASH' '$CONFIGURE' --config '$EXAMPLE'"
expect_rc_nonzero "example file as shipped"
expect_output "example file as shipped" "No backup destination is configured"
no_cluster_calls "example file as shipped"

"$BIN/sed" -E 's/^# (VELERO_[A-Z0-9_]+=)/\1/' "$EXAMPLE" > "$WORK/uncommented.env"
sandbox_bash "source '$CONFIGURE'; load_config_file '$WORK/uncommented.env' && echo \"\$VELERO_S3_URL|\$VELERO_DAILY_SCHEDULE\""
expect_rc "example with every setting filled in" 0
expect_output "example with every setting filled in" '^https://s3.example.com\|0 2 \* \* \*$'

echo
echo "--- MinIO namespace detection"

base_rules='
    {"match": "get namespaces -l app=minio", "stdout": "__NAMESPACES__"},
    {"match": "get svc minio -n minio-node1"},
    {"match": "get pods -n minio-node1 -l app=minio", "stdout": "true"},
    {"match": "get secret minio-credentials -n minio-node1 -o jsonpath=.*rootUser", "stdout": "dXNlcg=="},
    {"match": "get secret minio-credentials -n minio-node1 -o jsonpath=.*rootPassword", "stdout": "cGFzcw=="},
    {"match": "create secret generic cloud-credentials", "stdout": "kind: Secret\n"},
    {"match": "apply -f -"},
    {"match": "get backupstoragelocation default", "stdout": "Available"},
    {"match": "get crd prometheusrules", "rc": 1},
    {"match": "get backup test-connectivity", "stdout": "__BACKUP_PHASE__"},
    {"match": "get schedule monthly-full-backup", "stdout": "__EXISTING_TTL__"}
'
velero_rules='
    {"match": "schedule get monthly-full-backup", "rc": __MONTHLY_EXISTS__},
    {"match": "schedule get", "rc": 1},
    {"match": "schedule create"},
    {"match": "schedule delete"},
    {"match": "backup create"},
    {"match": "backup delete"}
'

# write_scenario NAMESPACES BACKUP_PHASE MONTHLY_EXISTS EXISTING_TTL
write_scenario() {
    local kube="$base_rules" vel="$velero_rules"
    kube="${kube//__NAMESPACES__/$1}"
    kube="${kube//__BACKUP_PHASE__/$2}"
    kube="${kube//__EXISTING_TTL__/${4:-}}"
    vel="${vel//__MONTHLY_EXISTS__/${3:-1}}"
    printf '{"kubectl": [%s], "velero": [%s]}\n' "$kube" "$vel" | scenario
}

MINIO_ENV="VELERO_BACKUP_TARGET=minio VELERO_BUCKET=velero-backups"

reset_state
write_scenario 'minio-node1\nminio-node2\n' Completed
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc_nonzero "two instances and no node chosen"
expect_output "two instances and no node chosen" "Found 2 MinIO instances"
expect_output "two instances lists them" "node2"
expect_no_cli "two instances and no node chosen" "apply|schedule create"

reset_state
write_scenario '' Completed
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc_nonzero "no instance"
expect_output "no instance" "No MinIO instance found"
expect_no_cli "no instance" "apply|schedule create"

reset_state
write_scenario 'minio\n' Completed
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc_nonzero "bare 'minio' namespace isn't an instance"

reset_state
printf '{"kubectl": [{"match": "get namespaces", "rc": 1}]}\n' | scenario
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc_nonzero "listing namespaces fails"
expect_no_cli "listing namespaces fails" "apply|schedule create"

reset_state
"$BIN/cat" > "$FAKE_SCENARIO" <<'EOF'
{"kubectl": [
  {"match": "get svc minio -n minio-node1"},
  {"match": "get pods -n minio-node1", "stdout": "false"}
]}
EOF
sandbox_bash "$MINIO_ENV VELERO_MINIO_NODE=node1; $RUN_MAIN"
expect_rc_nonzero "MinIO pod not running"
expect_output "MinIO pod not running" "is not running"
expect_no_cli "MinIO pod not running" "apply|schedule create"

echo
echo "--- Successful setup against MinIO"

reset_state
write_scenario 'minio-node1\n' Completed
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "one instance" 0
expect_output "warns about same-machine destination" "does not protect against losing the machine"
if "$BIN/grep" -q 's3Url: http://minio.minio-node1.svc.cluster.local:9000' "$FAKE_STDIN_LOG"; then
    pass "backup location points at minio-node1"
else
    fail "backup location has the wrong URL" "$("$BIN/cat" "$FAKE_STDIN_LOG")"
fi
if "$BIN/grep" -q 'bucket: velero-backups' "$FAKE_STDIN_LOG"; then
    pass "backup location uses the configured bucket"
else
    fail "backup location has the wrong bucket" "$("$BIN/cat" "$FAKE_STDIN_LOG")"
fi
if "$REAL_PYTHON" -c "
import sys, yaml
docs = open(sys.argv[1]).read().split('\n---\n')
found = [d for d in map(yaml.safe_load, docs) if d and d.get('kind') == 'BackupStorageLocation']
assert found and found[0]['spec']['default'] is True and found[0]['spec']['credential']['name'] == 'cloud-credentials'
" "$FAKE_STDIN_LOG" 2>/dev/null; then
    pass "backup location manifest parses as YAML"
else
    fail "backup location manifest doesn't parse" "$("$BIN/cat" "$FAKE_STDIN_LOG")"
fi
expect_cli "monthly retention" 'schedule create monthly-full-backup .*--ttl=4320h0m0s'
expect_cli "daily retention" 'schedule create daily-incremental-backup .*--ttl=720h0m0s'
expect_cli "snapshots off by default" 'schedule create monthly-full-backup .*--snapshot-volumes=false'
expect_cli "test backup" 'backup create test-connectivity'
expect_no_cli "no in-pod commands" 'kubectl exec'

reset_state
write_scenario 'minio-node1\n' Completed
sandbox_bash "$MINIO_ENV VELERO_SNAPSHOT_VOLUMES=true; $RUN_MAIN"
expect_rc "snapshots can be turned on" 0
expect_cli "snapshots can be turned on" 'schedule create monthly-full-backup .*--snapshot-volumes=true'

reset_state
write_scenario 'minio-node1\n' Failed
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "test backup fails" 1
expect_output "test backup fails" "finished as 'Failed'"
expect_no_output "test backup fails" "Configuration Complete"

reset_state
write_scenario 'minio-node1\n' Completed 0 '4320h0m0s'
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "existing schedule with the right retention" 0
expect_no_cli "existing schedule with the right retention" 'patch schedule'
expect_no_cli "existing schedule isn't recreated" 'schedule create monthly-full-backup'

"$BIN/cat" > "$WORK/ttl-rule.py" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['kubectl'].insert(0, {'match': 'patch schedule'})
json.dump(d, open(p, 'w'))
EOF
reset_state
write_scenario 'minio-node1\n' Completed 0 '180h0m0s'
"$REAL_PYTHON" -I "$WORK/ttl-rule.py" "$FAKE_SCENARIO"
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "schedule made by the old days-as-hours bug" 0
expect_cli "schedule made by the old days-as-hours bug" 'patch schedule monthly-full-backup .*4320h0m0s'

# Schedule creation failing must stop the run
reset_state
write_scenario 'minio-node1\n' Completed
"$REAL_PYTHON" -I -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['velero'].insert(0, {'match': 'schedule create', 'rc': 1})
json.dump(d, open(p, 'w'))
" "$FAKE_SCENARIO"
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "schedule creation fails" 1
expect_output "schedule creation fails" "Could not create schedule"

# Backup location never becoming available
reset_state
write_scenario 'minio-node1\n' Completed
"$REAL_PYTHON" -I -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['kubectl'].insert(0, {'match': 'get backupstoragelocation', 'stdout': 'Unavailable'})
json.dump(d, open(p, 'w'))
" "$FAKE_SCENARIO"
sandbox_bash "$MINIO_ENV; $RUN_MAIN"
expect_rc "backup location unavailable" 1
expect_output "backup location unavailable" "bucket 'velero-backups' exists"
expect_no_cli "backup location unavailable" "schedule create"

echo
echo "--- Successful setup against S3"

echo '[default]' > "$WORK/creds"
"$BIN/cat" > "$FAKE_SCENARIO" <<'EOF'
{"kubectl": [
  {"match": "create secret generic cloud-credentials", "stdout": "kind: Secret\n"},
  {"match": "apply -f -"},
  {"match": "get backupstoragelocation default", "stdout": "Available"},
  {"match": "get crd prometheusrules", "rc": 1},
  {"match": "get backup test-connectivity", "stdout": "Completed"}
],
"velero": [
  {"match": "schedule get", "rc": 1},
  {"match": "schedule create"},
  {"match": "backup create"},
  {"match": "backup delete"}
]}
EOF
reset_state
sandbox_bash "VELERO_BACKUP_TARGET=s3 VELERO_S3_URL=https://s3.example.com VELERO_BUCKET=my-bucket VELERO_REGION=eu-west-1 VELERO_CREDENTIALS_FILE=$WORK/creds VELERO_PREFIX=cluster1; $RUN_MAIN"
expect_rc "s3 target" 0
expect_cli "s3 target uses the credentials file" "from-file=cloud=$WORK/creds"
expect_no_cli "s3 target doesn't read MinIO" "minio-credentials|get namespaces"
for pattern in 's3Url: https://s3.example.com' 'bucket: my-bucket' 'region: eu-west-1' 'prefix: cluster1'; do
    if "$BIN/grep" -q "$pattern" "$FAKE_STDIN_LOG"; then
        pass "s3 target: backup location has $pattern"
    else
        fail "s3 target: backup location lacks $pattern" "$("$BIN/cat" "$FAKE_STDIN_LOG")"
    fi
done

echo
echo "--- Static checks"

check_absent() {
    local name="$1" pattern="$2" file="$3" found
    found="$("$BIN/grep" -nE -- "$pattern" "$file" || true)"
    if [[ -z "$found" ]]; then
        pass "$name"
    else
        fail "$name" "$found"
    fi
}

check_absent "install.sh has no hard-coded bucket" '--bucket|velero-backups' "$INSTALL"
check_absent "install.sh has no hard-coded endpoint" 's3Url|minio:9000' "$INSTALL"
check_absent "install.sh has no --provider, which Velero rejects here" '^[[:space:]]+--provider' "$INSTALL"
check_absent "install.sh doesn't use eval" 'eval ' "$INSTALL"
check_absent "configure-backup.sh has no hard-coded destination" 'velero-backups|minio:9000|\* 24h' "$CONFIGURE"
check_absent "configure-backup.sh doesn't download binaries" 'dl\.min\.io|curl |wget ' "$CONFIGURE"
if "$BIN/grep" -q -- '--no-default-backup-location' "$INSTALL"; then
    pass "install.sh installs with no backup location"
else
    fail "install.sh should install with no backup location"
fi

# No installer may start Velero by default.
found="$("$BIN/grep" -rlE 'storage/velero/(install|configure-backup)\.sh' "$REPO_ROOT/scripts/installation" 2>/dev/null \
    | while IFS= read -r file; do "$BIN/grep" -nE '^[^#]*(bash|sudo|\./)[^#]*storage/velero/(install|configure-backup)\.sh' "$file" || true; done)"
if [[ -z "$found" ]]; then
    pass "no installer runs Velero"
else
    fail "an installer runs Velero" "$found"
fi

finish
