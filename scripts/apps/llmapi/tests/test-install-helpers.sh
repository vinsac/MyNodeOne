#!/bin/bash
# R4: re-running the installer converges. Existing Secrets, ConfigMaps, replica counts and
# API keys are kept. Also covers shipping gateway/static/.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
start_sandbox

export STATE="$SANDBOX/state"
mkdir -p "$STATE/objects"
export NAMESPACE=llmapi
export API_KEY_RETRY_SLEEP=0
export API_KEY_SCHEMA_ATTEMPTS=3
: >"$STATE/applied"

# A small fake API server. An object exists if there's a file named kind/name, and
# jsonpath replies come from files under $STATE/values.
write_stub kubectl '
echo "kubectl $*" >>"$CALLS"
obj() { echo "$STATE/objects/$(tr "[:upper:]" "[:lower:]" <<<"$1")-$2"; }
[ ! -e "$STATE/api-down" ] || case "$*" in exec*) ;; *) exit 1 ;; esac
case "$1 $2" in
    "get "*)
        kind="$2"; name="$3"
        [ -e "$(obj "$kind" "$name")" ] || {
            case "$*" in *--ignore-not-found*) exit 0 ;; esac
            exit 1
        }
        case "$*" in
            *"-o name"*) echo "$kind/$name" ;;
            *jsonpath*spec.replicas*) cat "$STATE/replicas-$name" 2>/dev/null ;;
            *go-template*) cat "$(obj "$kind" "$name")" ;;
            *jsonpath*generation*) cat "$STATE/generation-$name" 2>/dev/null ;;
        esac
        exit 0 ;;
    "apply -f") cat >>"$STATE/applied"; echo "---END-APPLY---" >>"$STATE/applied"; exit 0 ;;
    "create -n") cat >"$STATE/created-secret"; touch "$STATE/objects/secret-$(sed -n "s/^  name: //p" "$STATE/created-secret")"; exit 0 ;;
    "create configmap")
        name="$3"; echo "$*" >"$STATE/cm-args-$name"
        for arg in "$@"; do
            case "$arg" in
                --from-file=*/*)
                    path="${arg#--from-file=}"; path="${path#*=}"
                    if [ -d "$path" ]; then cat "$path"/*; else cat "$path"; fi ;;
            esac
        done
        exit 0 ;;
    "create -f") cat >"$STATE/created-$RANDOM"; exit 0 ;;
    "replace -f") cat >"$STATE/replaced-$RANDOM"; exit 0 ;;
    "delete configmap") rm -f "$(obj configmap "$3")"; exit 0 ;;
    "exec -n")
        sql="${*: -1}"
        echo "$sql" >>"$STATE/sql"
        [ ! -e "$STATE/db-down" ] || exit 1
        case "$sql" in
            "SELECT 1 FROM information_schema"*)
                # Absent until the gateway has run: never, or after this many checks.
                if [ -e "$STATE/schema-after" ]; then
                    left=$(cat "$STATE/schema-after")
                    echo $((left - 1)) >"$STATE/schema-after"
                    [ "$left" -gt 0 ] || echo 1
                elif [ ! -e "$STATE/no-schema" ]; then
                    echo 1
                fi ;;
            "SELECT count"*) cat "$STATE/key-count" ;;
            "SELECT api_key"*) cat "$STATE/stored-key" 2>/dev/null ;;
        esac
        exit 0 ;;
esac
exit 0
'

source "$LLMAPI_DIR/lib/install-helpers.sh"
source "$LLMAPI_DIR/lib/gateway-code.sh"

reset() {
    rm -rf "$STATE/objects"
    mkdir -p "$STATE/objects"
    rm -f "$STATE"/replicas-* "$STATE"/created-* "$STATE"/replaced-* "$STATE"/cm-args-* "$STATE/sql" "$STATE/api-down" "$STATE/db-down" "$STATE/stored-key" "$STATE/no-schema" "$STATE/schema-after"
    unset _HASHED_SCHEMA_TIMED_OUT
    : >"$STATE/applied"
    : >"$CALLS"
}

## Secrets

reset
ensure_postgres_secret >/dev/null
assert_contains "first install: Postgres secret created" "$(cat "$STATE/created-secret")" "postgres-password:"
PASSWORD_ON_ARGV=$(grep -c 'from-literal' "$CALLS")
assert_equals "first install: password not on the command line" "$PASSWORD_ON_ARGV" 0

reset
touch "$STATE/objects/secret-llmapi-db"
ensure_postgres_secret >/dev/null
assert_not_contains "re-run: Postgres secret untouched" "$(cat "$CALLS")" "create"
assert_not_contains "re-run: Postgres secret not applied" "$(cat "$CALLS")" "apply"

reset
touch "$STATE/objects/pvc-llmapi-postgres-data"
if (ensure_postgres_secret >/dev/null 2>&1); then
    fail "missing secret next to existing database: refuses"
else
    pass "missing secret next to existing database: refuses"
fi
assert_not_contains "missing secret next to existing database: nothing created" "$(cat "$CALLS")" "create"

reset
ensure_redis_secret >/dev/null
CREATED=$(cat "$STATE/created-secret")
assert_contains "Redis secret: expected name" "$CREATED" "name: llmapi-redis-auth"
assert_contains "Redis secret: expected key" "$CREATED" "password:"
ENCODED=$(sed -n 's/^  password: //p' <<<"$CREATED")
if [[ "$(base64 -d <<<"$ENCODED")" =~ ^[0-9a-f]{64}$ ]]; then
    pass "Redis secret: 64 hex characters, safe in a config line"
else
    fail "Redis secret: 64 hex characters, safe in a config line"
fi

reset
touch "$STATE/objects/secret-llmapi-redis-auth"
ensure_redis_secret >/dev/null
assert_not_contains "re-run: Redis secret untouched" "$(cat "$CALLS")" "create"

## Applying manifests

MANIFEST="$SANDBOX/manifest.yaml"
cat >"$MANIFEST" <<'EOF'
# leading comment only
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-config
data:
  MODEL: "default"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  labels:
    name: not-this-one
spec:
  replicas: 0
  template:
    spec:
      containers:
      - name: main
---
apiVersion: v1
kind: Service
metadata:
  name: demo
spec:
  replicas: not-a-workload-field
EOF

reset
apply_manifest "$MANIFEST" 2>/dev/null
APPLIED=$(cat "$STATE/applied")
assert_contains "first install: ConfigMap applied" "$APPLIED" "name: demo-config"
assert_contains "first install: manifest replicas used" "$APPLIED" "replicas: 0"

reset
touch "$STATE/objects/configmap-demo-config" "$STATE/objects/deployment-demo"
echo 3 >"$STATE/replicas-demo"
apply_manifest "$MANIFEST" 2>/dev/null
APPLIED=$(cat "$STATE/applied")
assert_not_contains "re-run: existing ConfigMap not overwritten" "$APPLIED" "demo-config"
assert_contains "re-run: running replica count kept" "$APPLIED" "  replicas: 3"
assert_contains "re-run: Service still applied" "$APPLIED" "kind: Service"
assert_contains "re-run: Service left as written" "$APPLIED" "replicas: not-a-workload-field"

reset
touch "$STATE/api-down"
apply_manifest "$MANIFEST" 2>/dev/null
assert_not_contains "API error: ConfigMap defaults not applied" "$(cat "$STATE/applied")" "demo-config"

## ConfigMap values

reset
cat >"$STATE/objects/configmap-gateway-config" <<'EOF'
VLLM_URLS=http://live-vllm
TUNED=live "quoted" value
MAX_INFLIGHT=64
EOF
RESULT=$(keep_existing_configmap_values gateway-config "VLLM_URLS" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-config
data:
  VLLM_URLS: "http://new-vllm"
  TUNED: "default"
  # a comment
  MAX_INFLIGHT: "32"
  BRAND_NEW: "new-default"
EOF
)
assert_contains "gateway-config: key being set takes the new value" "$RESULT" 'VLLM_URLS: "http://new-vllm"'
assert_contains "gateway-config: live value kept and escaped" "$RESULT" 'TUNED: "live \"quoted\" value"'
assert_contains "gateway-config: tuned number kept" "$RESULT" 'MAX_INFLIGHT: "64"'
assert_contains "gateway-config: new key gets its default" "$RESULT" 'BRAND_NEW: "new-default"'
assert_contains "gateway-config: metadata untouched" "$RESULT" "name: gateway-config"

reset
RESULT=$(keep_existing_configmap_values gateway-config "" <<'EOF'
data:
  VLLM_URLS: "http://first-install"
EOF
)
assert_contains "gateway-config: first install uses generated values" "$RESULT" 'VLLM_URLS: "http://first-install"'

## Whether the running gateway can send a Redis password

cp "$SANDBOX/bin/kubectl" "$SANDBOX/kubectl.real-stub"
gateway_env_stub() {
    write_stub kubectl "printf '%s' '$1'; exit ${2:-0}"
}

gateway_env_stub 'gateway POSTGRES_HOST REDIS_PASSWORD'
if gateway_predates_redis_auth; then fail "gateway with the password: not old" "said old"; else pass "gateway with the password: not old"; fi
gateway_env_stub 'gateway POSTGRES_HOST'
if gateway_predates_redis_auth; then pass "gateway without the password: old"; else fail "gateway without the password: old" "said not old"; fi
gateway_env_stub 'gateway NOT_REDIS_PASSWORD_REALLY'
if gateway_predates_redis_auth; then pass "similar name doesn't count"; else fail "similar name doesn't count" "said not old"; fi
gateway_env_stub ''
if gateway_predates_redis_auth; then fail "no gateway yet: not old" "said old"; else pass "no gateway yet: not old"; fi
gateway_env_stub '' 1
if gateway_predates_redis_auth; then fail "API error: not reported as old" "said old"; else pass "API error: not reported as old"; fi
GUARD_LINE=$(grep -n 'if gateway_predates_redis_auth' "$LLMAPI_DIR/install-llmapi.sh" | cut -d: -f1)
REDIS_LINE=$(grep -n 'apply_manifest "$SCRIPT_DIR/manifests/redis.yaml"' "$LLMAPI_DIR/install-llmapi.sh" | cut -d: -f1)
if [ -n "$GUARD_LINE" ] && [ "$GUARD_LINE" -lt "$REDIS_LINE" ]; then pass "installer: refuses before touching Redis"; else fail "installer: refuses before touching Redis" "guard at ${GUARD_LINE:-none}, Redis at $REDIS_LINE"; fi

cp "$SANDBOX/kubectl.real-stub" "$SANDBOX/bin/kubectl"

## API keys

KEY_DIR="$SANDBOX/keys"
key_case() {
    reset
    rm -rf "$KEY_DIR"
    mkdir -p "$KEY_DIR"
    echo "$1" >"$STATE/key-count"
}

inserts() {
    grep -c '^INSERT' "$STATE/sql" 2>/dev/null || true
}

key_case 0
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "no key yet: one minted" "$(inserts)" 1
assert_equals "no key yet: state" "$ENSURED_KEY_STATE" new
assert_contains "no key yet: saved to file" "$(cat "$KEY_DIR/key")" "sk-mynodeone-"
assert_equals "no key yet: file is private" "$(stat -c %a "$KEY_DIR/key")" 600

key_case 1
echo "sk-mynodeone-existing" >"$KEY_DIR/key"
_api_key_id "sk-mynodeone-existing" >"$STATE/stored-key"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "re-run with file: nothing minted" "$(inserts)" 0
assert_equals "re-run with file: state" "$ENSURED_KEY_STATE" reused
assert_equals "re-run with file: key reused" "$ENSURED_KEY" "sk-mynodeone-existing"
assert_equals "re-run with file: file unchanged" "$(cat "$KEY_DIR/key")" "sk-mynodeone-existing"
assert_not_contains "re-run with file: the file's key isn't sent to the database" "$(cat "$STATE/sql")" "sk-mynodeone-existing"

# The file holds a key the database doesn't have: revoked, or from an earlier install.
key_case 1
echo "sk-mynodeone-old-one" >"$KEY_DIR/key"
_api_key_id "sk-mynodeone-current" >"$STATE/stored-key"
ensure_api_key prometheus metrics 100 1000000 200000 "$KEY_DIR/key"
assert_equals "stale file: state" "$ENSURED_KEY_STATE" stale
assert_equals "stale file: its key is not used" "$ENSURED_KEY" ""
assert_equals "stale file: nothing minted" "$(inserts)" 0
assert_equals "stale file: file left for the admin" "$(cat "$KEY_DIR/key")" "sk-mynodeone-old-one"

key_case 1
echo "sk-mynodeone-old-one" >"$KEY_DIR/key"
echo "sk-mynodeone-from-db" >"$STATE/stored-key"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "stale file, raw row: restored from the row" "$ENSURED_KEY_STATE" restored
assert_equals "stale file, raw row: file corrected" "$(cat "$KEY_DIR/key")" "sk-mynodeone-from-db"

key_case 1
echo "sk-mynodeone-from-db" >"$KEY_DIR/key"
echo "sk-mynodeone-from-db" >"$STATE/stored-key"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "file matches an unmigrated row: reused" "$ENSURED_KEY_STATE" reused

key_case 1
echo "sk-mynodeone-from-db" >"$STATE/stored-key"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "file lost: nothing minted" "$(inserts)" 0
assert_equals "file lost: restored" "$ENSURED_KEY_STATE" restored
assert_equals "file lost: file restored" "$(cat "$KEY_DIR/key")" "sk-mynodeone-from-db"

# What a hashed api_key column would hold: the raw value can't be recovered.
key_case 1
echo "sha256:abcdef" >"$STATE/stored-key"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "hashed key in the database: nothing minted" "$(inserts)" 0
assert_equals "hashed key in the database: state" "$ENSURED_KEY_STATE" elsewhere
assert_equals "hashed key in the database: hash not written to the key file" "$(ls "$KEY_DIR")" ""

key_case 0
touch "$STATE/db-down"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
STATUS=$?
assert_equals "database down: reports failure" "$STATUS" 1
assert_equals "database down: state" "$ENSURED_KEY_STATE" unknown
assert_equals "database down: nothing minted" "$(inserts)" 0

key_case not-a-number
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "garbled count: state" "$ENSURED_KEY_STATE" unknown
assert_equals "garbled count: nothing minted" "$(inserts)" 0

## API keys: what reaches Postgres

sql_with() {
    grep -c -- "$1" "$STATE/sql" 2>/dev/null || true
}

key_case 0
OUTPUT=$(ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key" 2>&1)
assert_equals "new key: nothing printed by the helper" "$OUTPUT" ""
RAW=$(cat "$KEY_DIR/key")
ANSWERS=$(RAW="$RAW" MAIN="$LLMAPI_DIR/gateway/main.py" python3 - <<'PY'
# The gateway's own functions, without importing its dependencies.
import ast
import hashlib
import os
import re

source = open(os.environ["MAIN"]).read()
wanted = {"hash_api_key", "api_key_display_prefix"}
scope = {"hashlib": hashlib, "API_KEY_ID_PREFIX": re.search(r'^API_KEY_ID_PREFIX = "(.*)"$', source, re.M).group(1)}
for node in ast.parse(source).body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        exec(ast.get_source_segment(source, node), scope)
print(scope["hash_api_key"](os.environ["RAW"]))
print(scope["api_key_display_prefix"](os.environ["RAW"]))
PY
)
KEY_ID=$(sed -n 1p <<<"$ANSWERS")
KEY_PREFIX=$(sed -n 2p <<<"$ANSWERS")
assert_contains "new key: main.py's functions ran" "$KEY_ID" "sha256:"
assert_equals "new key: id matches main.py" "$(_api_key_id "$RAW")" "$KEY_ID"
assert_equals "new key: prefix matches main.py" "$(_api_key_prefix "$RAW")" "$KEY_PREFIX"
assert_contains "new key: id inserted" "$(cat "$STATE/sql")" "VALUES ('$KEY_ID', '$KEY_PREFIX', 'admin-ui'"
assert_contains "new key: names the column" "$(cat "$STATE/sql")" "(api_key, key_prefix, name,"
assert_not_contains "new key: raw key not in the SQL" "$(cat "$STATE/sql")" "$RAW"
assert_not_contains "new key: raw key not in any kubectl argument" "$(cat "$CALLS")" "$RAW"

assert_equals "short key: prefix is at most half" "$(_api_key_prefix "sk-abcdef")" "sk-a"

key_case 0
touch "$STATE/no-schema"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
STATUS=$?
assert_equals "schema never appears: reports failure" "$STATUS" 1
assert_equals "schema never appears: state" "$ENSURED_KEY_STATE" unknown
assert_equals "schema never appears: nothing minted" "$(inserts)" 0
assert_equals "schema never appears: no key file" "$(ls "$KEY_DIR")" ""
assert_equals "schema never appears: checked up to the limit" "$(sql_with 'information_schema')" 3

ensure_api_key prometheus metrics 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "schema timed out: the next key only checks once" "$(sql_with 'information_schema')" 4
assert_equals "schema timed out: next key also unknown" "$ENSURED_KEY_STATE" unknown

key_case 0
echo 2 >"$STATE/schema-after"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "schema appears during the wait: key created" "$ENSURED_KEY_STATE" new
assert_equals "schema appears during the wait: one key" "$(inserts)" 1

key_case 0
touch "$STATE/no-schema"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
rm "$STATE/no-schema"
ensure_api_key admin-ui admin 1000 10000000 200000 "$KEY_DIR/key"
assert_equals "schema appears after a timeout: next key is created" "$ENSURED_KEY_STATE" new

## Prometheus token Secret

reset
printf '%s' "sk-mynodeone-stubprom" | put_secret_from_stdin llmapi-prometheus-token token
assert_not_contains "new Secret: value not in any kubectl argument" "$(cat "$CALLS")" "sk-mynodeone-stubprom"
assert_not_contains "new Secret: no apply, so no last-applied copy" "$(cat "$CALLS")" "apply"
assert_contains "new Secret: created" "$(cat "$STATE"/created-* 2>/dev/null)" "token: $(printf '%s' sk-mynodeone-stubprom | base64 -w0)"
assert_contains "new Secret: in the namespace" "$(cat "$STATE"/created-* 2>/dev/null)" "namespace: llmapi"

reset
touch "$STATE/objects/secret-llmapi-prometheus-token"
printf '%s' "sk-mynodeone-stubprom" | put_secret_from_stdin llmapi-prometheus-token token
assert_contains "existing Secret: replaced" "$(cat "$STATE"/replaced-* 2>/dev/null)" "name: llmapi-prometheus-token"

INSTALL_TEXT=$(cat "$LLMAPI_DIR/install-llmapi.sh")
assert_not_contains "installer: no --from-literal for tokens" "$INSTALL_TEXT" "--from-literal=token"
assert_contains "installer: Prometheus key goes through stdin" "$INSTALL_TEXT" "| put_secret_from_stdin llmapi-prometheus-token token"

## Gateway code and static files

APP="$SANDBOX/app"
mkdir -p "$APP/gateway" "$APP/manifests"
echo 'print("gateway")' >"$APP/gateway/main.py"
echo 'fastapi==1 --hash=sha256:aa' >"$APP/gateway/requirements.lock"
cat >"$APP/manifests/gateway-deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: __NAMESPACE__
spec:
  replicas: 1
  template:
    metadata:
      annotations:
        sha: "__GATEWAY_CODE_SHA__"
EOF

reset
ship_gateway_static "$APP"
assert_equals "static directory absent: succeeds" "$?" 0
assert_contains "static directory absent: stale ConfigMap removed" "$(cat "$CALLS")" "delete configmap gateway-static"
SHA_NO_STATIC=$(gateway_code_sha "$APP")

mkdir -p "$APP/gateway/static"
reset
ship_gateway_static "$APP"
assert_equals "static directory empty: succeeds" "$?" 0
assert_contains "static directory empty: no ConfigMap" "$(cat "$CALLS")" "delete configmap gateway-static"
assert_equals "static directory empty: hash unchanged" "$(gateway_code_sha "$APP")" "$SHA_NO_STATIC"

echo 'console.log(1)' >"$APP/gateway/static/app.js"
reset
ship_gateway_static "$APP"
assert_equals "flat static files: succeeds" "$?" 0
assert_contains "flat static files: shipped from the directory" "$(cat "$STATE/cm-args-gateway-static")" "--from-file=$APP/gateway/static"
SHA_WITH_STATIC=$(gateway_code_sha "$APP")
if [ "$SHA_WITH_STATIC" != "$SHA_NO_STATIC" ]; then
    pass "static file changes the code hash, so the Deployment rolls"
else
    fail "static file changes the code hash, so the Deployment rolls"
fi

mkdir -p "$APP/gateway/static/sub"
echo nested >"$APP/gateway/static/sub/nested.js"
reset
OUTPUT=$(ship_gateway_static "$APP" 2>&1)
assert_equals "nested static file: refused" "$?" 1
assert_contains "nested static file: named in the error" "$OUTPUT" "nested.js"
rm -rf "$APP/gateway/static/sub"

head -c 1100000 /dev/zero | tr '\0' 'a' >"$APP/gateway/static/big.js"
reset
OUTPUT=$(ship_gateway_static "$APP" 2>&1)
assert_equals "static files over the ConfigMap limit: refused" "$?" 1
assert_contains "static files over the ConfigMap limit: explained" "$OUTPUT" "1 MiB"
rm -f "$APP/gateway/static/big.js"

reset
ship_gateway_code "$APP" >/dev/null
assert_contains "gateway code ships main.py" "$(cat "$STATE/cm-args-gateway-code")" "main.py="
assert_contains "gateway code ships the lockfile" "$(cat "$STATE/cm-args-gateway-code")" "requirements.lock="

reset
touch "$STATE/objects/deployment-gateway"
echo 2 >"$STATE/replicas-gateway"
apply_gateway_deployment "$APP" "deadbeef" >/dev/null 2>&1
APPLIED=$(cat "$STATE/applied")
assert_contains "gateway Deployment: placeholders filled" "$APPLIED" 'sha: "deadbeef"'
assert_contains "gateway Deployment: namespace filled" "$APPLIED" "namespace: llmapi"
assert_contains "gateway Deployment: scaled-up replicas kept" "$APPLIED" "  replicas: 2"
assert_not_contains "gateway Deployment: no placeholder left" "$APPLIED" "__"

finish
