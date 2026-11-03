#!/bin/bash
###############################################################################
# Tests for the public-routing scripts.
#
# Everything runs against stubs shadowed on PATH (kubectl, curl, ssh, sudo,
# systemctl, tailscale, docker) with HOME and every config path in a temp dir. No
# real cluster, VPS or /etc file is touched.
#
#   bash scripts/tests/routing/run-tests.sh [name-filter]
###############################################################################

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FILTER="${1:-}"
TOKEN="test-token-must-not-reach-argv"
PASS=0
FAIL=0
FAILED_NAMES=()

STUBS=(kubectl curl ssh systemctl sudo tailscale docker getent mountpoint)
# The commit before these fixes, for running the old clients against the new server.
OLD_COMMIT="3461b65"
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/routing-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# Real server responses, written by TestWriteContractFixtures in cmd/config-api.
CONTRACT="$ROOT/contract"
CONTRACT_STATE="unset"
load_contract_fixtures() {
    if [[ ! -x "$GO_BIN" ]]; then
        CONTRACT_STATE="no-go"
        return
    fi
    if (cd "$REPO" && ROUTING_CONTRACT_DIR="$CONTRACT" "$GO_BIN" test -count=1 \
        -run '^TestWriteContractFixtures$' ./cmd/config-api/ >"$ROOT/contract.log" 2>&1); then
        CONTRACT_STATE="ready"
    else
        CONTRACT_STATE="failed"
    fi
}

# True when the contract tests can run. A build failure counts as a test failure, so
# a broken server can't pass by skipping them.
contract_ready() {
    [[ "$CONTRACT_STATE" == "unset" ]] && load_contract_fixtures
    case "$CONTRACT_STATE" in
        ready) return 0 ;;
        no-go)
            echo "    skipped: $GO_BIN not found"
            return 1
            ;;
        *)
            CHECK_FAILED=1
            echo "    FAILED: could not generate server fixtures"
            sed 's/^/      /' "$ROOT/contract.log"
            return 1
            ;;
    esac
}

# Serves one scenario through the curl stub: live, empty or broken.
serve() {
    cp "$CONTRACT/$1"/* "$T/api/"
    api /api/v1/heartbeat 200 '{"status":"ok"}'
}

# Writes a script from the old commit to $2 with its fixed system paths moved into the
# test's temp dir. Fails if any /etc path is left, so it can't reach the real ones.
old_script() {
    git -C "$REPO" show "$OLD_COMMIT:$1" 2>/dev/null |
        sed -e "s#/etc/mynodeone#$T/etc-mynodeone#g" \
            -e "s#/etc/hosts#$T/hosts#g" \
            -e "s#/etc/traefik#$T/etc-traefik#g" \
            -e "s#/tmp/mynodeone-routes.yml#$T/old-temp-routes.yml#g" \
            -e 's/delay=5/delay=0/' \
            -e 's/^sleep 3$/sleep 0/' >"$2"
    [[ -s "$2" ]] && ! grep -q '/etc/' "$2"
}

old_commit_ready() {
    if git -C "$REPO" cat-file -e "$OLD_COMMIT" 2>/dev/null; then
        return 0
    fi
    echo "    skipped: commit $OLD_COMMIT not available"
    return 1
}

###############################################################################
# Harness
###############################################################################

setup() {
    T="$ROOT/$1"
    mkdir -p "$T"/{bin,k8s/cm,api,ssh,systemd,docker,home/.mynodeone,vps/traefik/config,traefik}
    local stub
    for stub in "${STUBS[@]}"; do
        install -m 755 "$HERE/stubs/$stub" "$T/bin/$stub"
    done
    : >"$T/kubeconfig"
    OUT="$T/output.log"
    RC=0
}

# Runs a command in the stubbed environment. Output goes to $OUT, status to $RC.
run() {
    RC=0
    env -u SUDO_USER -u PROJECT_ROOT -u CLUSTER_DOMAIN -u API_TOKEN -u CONTROL_PLANE_IP -u INVOCATION_ID \
        PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" \
        HOME="$T/home" \
        ACTUAL_HOME="$T/home" \
        ACTUAL_USER="$(id -un)" \
        KUBECONFIG="$T/kubeconfig" \
        FAKE_K8S="$T/k8s" FAKE_API="$T/api" FAKE_SSH="$T/ssh" FAKE_SYSTEMD="$T/systemd" \
        FAKE_DOCKER="$T/docker" FAKE_VPS_HOME="$T/vps" \
        AGENT_CONFIG_FILE="$T/agent.env" \
        AGENT_HOSTS_FILE="$T/hosts" \
        AGENT_HOSTS_BACKUP="$T/hosts.bak" \
        AGENT_STATE_FILE="$T/agent.state" \
        FETCH_RETRY_DELAY=0 \
        MYNODEONE_HOSTS_FILE="$T/hosts" \
        MYNODEONE_CONFIG_API_BIN="$T/no-such-binary" \
        MYNODEONE_API_TOKEN_FILE="$T/no-such-api-token" \
        SR_CAS_RETRY_DELAY=0 \
        VISIBILITY_MAX_WAIT=0 \
        VISIBILITY_POLL_INTERVAL=1 \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$@" >"$OUT" 2>&1 </dev/null || RC=$?
}
EXTRA_ENV=()

check() {
    local description="$1"
    shift
    if "$@" >/dev/null; then
        return 0
    fi
    CHECK_FAILED=1
    echo "    FAILED: $description"
}

contains() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
equals() { [[ "$1" == "$2" ]]; }
differs() { [[ "$1" != "$2" ]]; }
same_file() { cmp -s "$1" "$2"; }
no_file() { [[ ! -e "$1" ]]; }

set_cm() {
    # set_cm <name> <key> <value>
    local file="$T/k8s/cm/$1.json" current='{}'
    [[ -f "$file" ]] && current=$(cat "$file")
    jq --arg n "$1" --arg k "$2" --arg v "$3" \
        '.metadata = {name: $n, resourceVersion: (.metadata.resourceVersion // "1")} | .data[$k] = $v' \
        <<<"$current" >"$file"
}
services_json() { jq -r '.data["services.json"]' "$T/k8s/cm/service-registry.json"; }
routing_json() { jq -r '.data["routing.json"]' "$T/k8s/cm/domain-registry.json"; }

api() {
    # api <path> <code> <body>
    local key="${1//\//_}"
    printf '%s\n' "$2" >"$T/api/$key.code"
    printf '%s' "$3" >"$T/api/$key.body"
}

write_agent_env() {
    cat >"$T/agent.env" <<EOF
CONTROL_PLANE_IP=100.64.0.9
NODE_NAME=test-node
NODE_TYPE=$1
API_TOKEN=$TOKEN
CLUSTER_DOMAIN=testcluster
TRAEFIK_CONFIG_DIR=$T/traefik
EOF
}

ROUTES_ONE=$'# Generated: 2026-01-01\nhttp:\n  routers:\n    a:\n      rule: "Host(`a.example.com`)"\n      service: a\n  services:\n    a:\n      loadBalancer:\n        servers:\n          - url: "http://100.64.1.1:80"\n'
ROUTES_TWO=$'# Generated: 2026-01-02\nhttp:\n  routers:\n    b:\n      rule: "Host(`b.example.com`)"\n      service: b\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: "http://100.64.1.1:80"\n'
ROUTES_NONE=$'# Generated: 2026-01-03\nhttp:\n  routers: {}\n'

OLD_REGISTRY='{"llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":true},"demo":{"namespace":"default","service":"demo","ip":"100.64.1.6","port":80,"local_name":"demo","public":false}}'
LIVE_ROUTING='{"llmapi":{"expose":["api.example.com"],"vps_nodes":["100.64.0.2"],"strategy":"round-robin"}}'

svc_item() {
    # svc_item <namespace> <name> <ip> <subdomain-annotation>
    jq -cn --arg ns "$1" --arg n "$2" --arg ip "$3" --arg a "${4:-}" '{
        metadata: {namespace: $ns, name: $n, annotations: (if $a == "" then {} else {"mynodeone.io/subdomain": $a} end)},
        spec: {type: "LoadBalancer", ports: [{port: 80}]},
        status: {loadBalancer: {ingress: [{ip: $ip}]}}}'
}

###############################################################################
# The harness itself
###############################################################################

test_harness_shadows_every_real_tool() {
    run bash -c 'for tool in "$@"; do command -v "$tool"; done' _ "${STUBS[@]}"
    check "all tools found" equals "$(wc -l <"$OUT")" "${#STUBS[@]}"
    check "every tool resolves to a stub" equals "$(grep -cF "$T/bin/" "$OUT")" "${#STUBS[@]}"
}

###############################################################################
# S2 + R9: real server responses through the real clients
###############################################################################

test_contract_agent_installs_live_route() {
    contract_ready || return 0
    write_agent_env vps
    serve live
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "real rule installed" contains "$T/traefik/mynodeone-routes.yml" 'Host(`llmapi.example.com`)'
    check "nothing blocked by default" lacks "$T/traefik/mynodeone-routes.yml" '!PathPrefix'
    check "backend installed" contains "$T/traefik/mynodeone-routes.yml" 'http://100.72.41.10:80'
}

test_contract_agent_applies_confirmed_empty() {
    contract_ready || return 0
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    serve empty
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "route removed" lacks "$T/traefik/mynodeone-routes.yml" 'a.example.com'
    check "file still valid for Traefik" contains "$T/traefik/mynodeone-routes.yml" 'http:'
}

test_contract_agent_keeps_routes_when_server_is_broken() {
    contract_ready || return 0
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    serve broken
    check "server answers 503 for the config" contains "$T/api/_api_v1_config_vps.code" 503
    check "server answers 503 for the YAML" contains "$T/api/_api_v1_config_vps_traefik-config.code" 503
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_contract_agent_hosts_follow_the_server() {
    contract_ready || return 0
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    serve live
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "live: exits 0" equals "$RC" 0
    check "live: entry added" contains "$T/hosts" 'llm.testcluster.local'
    serve broken
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "broken: reports failure" differs "$RC" 0
    check "broken: entry kept" contains "$T/hosts" 'llm.testcluster.local'
    serve empty
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "empty: exits 0" equals "$RC" 0
    check "empty: entry removed" lacks "$T/hosts" 'llm.testcluster.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
}

test_contract_vps_sync_follows_the_server() {
    contract_ready || return 0
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    serve broken
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "broken: reports failure" differs "$RC" 0
    check "broken: routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    serve empty
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "empty: exits 0" equals "$RC" 0
    check "empty: route removed" lacks "$T/traefik/mynodeone-routes.yml" 'a.example.com'
    serve live
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "live: exits 0" equals "$RC" 0
    check "live: route installed" contains "$T/traefik/mynodeone-routes.yml" 'llmapi.example.com'
}

###############################################################################
# Mixed versions: the clients from before these fixes against the new server
###############################################################################

check_old_agent_on_new_server() {
    old_commit_ready || return 0
    contract_ready || return 0
    local path="$1" agent="$T/old/agent.sh"
    mkdir -p "$T/old" "$T/etc-mynodeone"
    check "old agent prepared" old_script "$path" "$agent"
    # The old scripts/lib agent sources this file from its own directory.
    check "old helper prepared" old_script scripts/lib/config-paths.sh "$T/old/config-paths.sh"

    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    serve broken
    run bash "$agent" sync
    check "vps, broken: reports failure" differs "$RC" 0
    check "vps, broken: routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    serve empty
    run bash "$agent" sync
    check "vps, empty: no error" equals "$RC" 0
    check "vps, empty: nothing wiped" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    serve live
    run bash "$agent" sync
    check "vps, live: no error" equals "$RC" 0
    check "vps, live: rule reaches Traefik" contains "$T/traefik/mynodeone-routes.yml" 'Host(`llmapi.example.com`)'

    write_agent_env laptop
    printf '127.0.0.1 localhost\n100.64.1.5 chat.testcluster.local chat\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    serve broken
    run bash "$agent" sync
    check "laptop, broken: hosts untouched" same_file "$T/before" "$T/hosts"
    serve empty
    run bash "$agent" sync
    check "laptop, empty: hosts untouched" same_file "$T/before" "$T/hosts"
    serve live
    run bash "$agent" sync
    check "laptop, live: entry added" contains "$T/hosts" 'llm.testcluster.local'
}

test_old_vps_agent_on_new_server() {
    check_old_agent_on_new_server scripts/lib/node-agent.sh
}

test_old_control_plane_agent_on_new_server() {
    check_old_agent_on_new_server scripts/installation/mynodeone-node-agent
}

test_old_vps_sync_on_new_server() {
    old_commit_ready || return 0
    contract_ready || return 0
    write_vps_config
    local script="$T/old-sync.sh"
    check "old script prepared" old_script scripts/vps/sync-vps-routes.sh "$script"
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    serve broken
    run bash "$script"
    check "broken: reports failure" differs "$RC" 0
    check "broken: routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    serve live
    run bash "$script"
    check "live: exits 0" equals "$RC" 0
    check "live: route installed" contains "$T/traefik/mynodeone-routes.yml" 'llmapi.example.com'
}

###############################################################################
# S2 + R9: the agent and "confirmed empty" versus "don't know"
###############################################################################

test_agent_empty_list_removes_routes() {
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    api /api/v1/config/vps 200 '{"version":"v2","routes":[]}'
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "route removed" lacks "$T/traefik/mynodeone-routes.yml" 'a.example.com'
    check "state records version" contains "$T/agent.state" 'VERSION=v2'
}

test_agent_error_response_keeps_routes() {
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps 503 '{"error":"registry unavailable"}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    check "no version recorded" no_file "$T/agent.state"
}

test_agent_unreachable_api_keeps_routes() {
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    touch "$T/api/down"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_agent_missing_field_keeps_routes_old_server() {
    # What an old server sends both for no routes and for a failed kubectl.
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps 200 '{"version":"v2"}'
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    check "version not recorded as applied" no_file "$T/agent.state"
}

test_agent_garbage_200_keeps_routes() {
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps 200 '<html>proxy error</html>'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_agent_failed_yaml_fetch_keeps_routes() {
    write_agent_env vps
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps 200 '{"version":"v2","routes":[{"service":"b","domain":"b.example.com","backend":"100.64.1.1:80"}]}'
    api /api/v1/config/vps/traefik-config 503 'unavailable'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_agent_installs_new_routes_and_keeps_token_out_of_argv() {
    write_agent_env vps
    api /api/v1/config/vps 200 '{"version":"v3","routes":[{"service":"b","domain":"b.example.com","backend":"100.64.1.1:80"}]}'
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_TWO"
    api /api/v1/heartbeat 200 '{"status":"ok"}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "route installed" contains "$T/traefik/mynodeone-routes.yml" 'b.example.com'
    check "token not in any curl argv" lacks "$T/api/argv.log" "$TOKEN"
    check "token sent via config stream" contains "$T/api/config.log" "X-API-Token: $TOKEN"
}

###############################################################################
# R19 and S13: /etc/hosts
###############################################################################

test_agent_writes_hosts_in_place() {
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    local inode
    inode=$(stat -c %i "$T/hosts")
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "entry added" contains "$T/hosts" 'chat.testcluster.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
    check "same inode, so a bind mount survives" equals "$(stat -c %i "$T/hosts")" "$inode"
}

test_agent_hosts_explicit_empty_removes_absent_keeps() {
    write_agent_env laptop
    printf '127.0.0.1 localhost\n100.64.1.5 chat.testcluster.local chat\n' >"$T/hosts"
    api /api/v1/config/laptop 200 '{"version":"v1"}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "missing field keeps entries" contains "$T/hosts" 'chat.testcluster.local'
    api /api/v1/config/laptop 200 '{"version":"v2","dns_entries":[]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "explicit empty exits 0" equals "$RC" 0
    check "explicit empty removes" lacks "$T/hosts" 'chat.testcluster.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
}

test_agent_rejects_hostile_dns_entries() {
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    local body
    body=$(jq -cn '{version: "v1", dns_entries: [
        {name: "good", ip: "100.64.1.5"},
        {name: "evil\n1.2.3.4 bank.example.com", ip: "100.64.1.6"},
        {name: "trailing\n", ip: "100.64.1.7"},
        {name: "a.b", ip: "100.64.1.8"},
        {name: "localhost", ip: "6.6.6.6"},
        {name: "badip", ip: "100.64.1.9 extra.example.com"},
        {name: "nlip", ip: "100.64.1.10\n"}]}')
    api /api/v1/config/laptop 200 "$body"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "good entry written" contains "$T/hosts" 'good.testcluster.local'
    check "newline injection blocked" lacks "$T/hosts" 'bank.example.com'
    check "trailing newline name blocked" lacks "$T/hosts" 'trailing'
    check "dotted name blocked" lacks "$T/hosts" 'a.b.testcluster'
    check "reserved name blocked" lacks "$T/hosts" '6.6.6.6'
    check "bad IP blocked" lacks "$T/hosts" 'extra.example.com'
    check "IP with newline blocked" lacks "$T/hosts" '100.64.1.10'
}

test_agent_hosts_write_failure_is_not_ok() {
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "    skipped: root ignores file modes"
        return 0
    fi
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    chmod 444 "$T/hosts"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "no [OK] line" lacks "$OUT" '[OK]'
    check "version not recorded" no_file "$T/agent.state"
}

test_agent_defers_hosts_to_active_timer() {
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    touch "$T/systemd/timer-active"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "hosts untouched" same_file "$T/before" "$T/hosts"
}

test_sync_dns_filters_hostile_entries_in_place() {
    printf '127.0.0.1 localhost\n10.0.0.1 old.testcluster.local\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    local inode reg
    inode=$(stat -c %i "$T/hosts")
    reg=$(jq -cn '{
        "a/good": {ip: "100.64.1.5", local_name: "good"},
        "a/dash": {ip: "100.64.1.6", local_name: "dashboard"},
        "a/evil": {ip: "100.64.1.7", local_name: "evil\n1.2.3.4 bank.example.com"},
        "a/trail": {ip: "100.64.1.8", local_name: "trailing\n"},
        "a/lo": {ip: "6.6.6.6", local_name: "localhost"},
        "a/badip": {ip: "100.64.1.9 x.example.com", local_name: "badip"},
        "a/none": {local_name: "noip"}}')
    set_cm service-registry services.json "$reg"
    run bash "$REPO/scripts/domains/sync-dns.sh" --quiet
    check "exits 0" equals "$RC" 0
    check "good entry" contains "$T/hosts" 'good.testcluster.local'
    check "dashboard gets the bare domain too" grep -qP '^100\.64\.1\.6\ttestcluster\.local$' "$T/hosts"
    check "marker kept for sync-controller" contains "$T/hosts" 'MyNodeOne Services'
    check "stale entry gone" lacks "$T/hosts" 'old.testcluster.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
    check "newline injection blocked" lacks "$T/hosts" 'bank.example.com'
    check "trailing newline blocked" lacks "$T/hosts" 'trailing'
    check "reserved name blocked" lacks "$T/hosts" '6.6.6.6'
    check "bad IP blocked" lacks "$T/hosts" 'x.example.com'
    check "same inode" equals "$(stat -c %i "$T/hosts")" "$inode"
}

test_sync_dns_unchanged_makes_no_backup() {
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"a/good":{"ip":"100.64.1.5","local_name":"good"}}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    local first
    first=$(find "$T" -maxdepth 1 -name 'hosts.backup.*' | wc -l)
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "second run says up to date" contains "$OUT" 'already up to date'
    check "no new backup" equals "$(find "$T" -maxdepth 1 -name 'hosts.backup.*' | wc -l)" "$first"
    check "block not duplicated" equals "$(grep -c 'MyNodeOne Services' "$T/hosts")" 1
}

test_sync_dns_failed_read_keeps_hosts() {
    printf '127.0.0.1 localhost\n100.64.1.5 good.testcluster.local\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    touch "$T/k8s/fail-get-configmap"
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "reports failure" differs "$RC" 0
    check "hosts untouched" same_file "$T/before" "$T/hosts"
}

test_sync_dns_blank_registry_keeps_hosts() {
    printf '127.0.0.1 localhost\n100.64.1.5 good.testcluster.local\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json ''
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "reports failure" differs "$RC" 0
    check "hosts untouched" same_file "$T/before" "$T/hosts"
}

test_sync_dns_confirmed_empty_removes() {
    printf '127.0.0.1 localhost\n\n# MyNodeOne Services - old\n100.64.1.5\tgood.testcluster.local\n\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "exits 0" equals "$RC" 0
    check "entry removed" lacks "$T/hosts" 'good.testcluster.local'
    check "message sync-controller looks for" contains "$OUT" 'No services found in registry'
}

test_dropin_makes_traefik_dir_writable() {
    # shellcheck disable=SC1091
    (
        NODE_AGENT_SYSTEMD_DIR="$T/systemd"
        source "$REPO/scripts/lib/node-agent-install.sh"
        node_agent_write_sandbox_dropin "$T/vps/traefik/config"
    )
    check "drop-in lists the directory" contains \
        "$T/systemd/mynodeone-node-agent.service.d/10-traefik.conf" "ReadWritePaths=-$T/vps/traefik/config"
    check "unit allows /etc/hosts" contains "$REPO/scripts/lib/mynodeone-node-agent.service" '/etc/hosts'
    check "only one agent copy" no_file "$REPO/scripts/installation/mynodeone-node-agent"
}

###############################################################################
# S10: registry keys and migration
###############################################################################

test_migration_keeps_live_public_route() {
    set_cm service-registry services.json "$OLD_REGISTRY"
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    local reg
    reg=$(services_json)
    check "keyed on namespace/name" jq -e 'has("llmapi/llmapi") and has("default/demo")' <<<"$reg"
    check "bare keys gone" jq -e '(has("llmapi") or has("demo")) | not' <<<"$reg"
    check "llmapi still public" jq -e '.["llmapi/llmapi"].public == true' <<<"$reg"
    check "demo still private" jq -e '.["default/demo"].public == false' <<<"$reg"
    check "old name recorded" jq -e '.["llmapi/llmapi"].legacy_key == "llmapi"' <<<"$reg"
    check "other fields kept" jq -e '.["llmapi/llmapi"].ip == "100.64.1.5" and .["llmapi/llmapi"].port == 80' <<<"$reg"

    local version
    version=$(jq -r '.metadata.resourceVersion' "$T/k8s/cm/service-registry.json")
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "second run exits 0" equals "$RC" 0
    check "second run writes nothing" equals "$(jq -r '.metadata.resourceVersion' "$T/k8s/cm/service-registry.json")" "$version"
}

test_migration_waits_for_config_api() {
    set_cm service-registry services.json "$OLD_REGISTRY"
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    : >"$T/fake-api-binary"
    EXTRA_ENV=("MYNODEONE_CONFIG_API_BIN=$T/fake-api-binary")
    api /api/v1/health 200 '{"status":"healthy"}'
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "explicit migrate refuses" differs "$RC" 0
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"

    # Opted in by an earlier migrate, with this API not ready yet.
    set_cm service-registry migration.json '{"opted_in":true}'
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5)" '{items: [$a]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "sync skips without failing" equals "$RC" 0
    check "sync says so" contains "$OUT" 'Skipping registry sync'
    check "registry still untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"

    api /api/v1/health 200 '{"status":"healthy","registry_schema":2}'
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "migrates once the API advertises schema 2" equals "$RC" 0
    check "public survived" jq -e '.["llmapi/llmapi"].public == true' <<<"$(services_json)"
    EXTRA_ENV=()
}

test_same_name_in_two_namespaces_do_not_collide() {
    set_cm service-registry services.json '{}'
    jq -cn --argjson a "$(svc_item team-a web 100.64.2.1)" --argjson b "$(svc_item team-b web 100.64.2.2)" \
        '{items: [$a, $b]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "both kept" jq -e '.["team-a/web"].ip == "100.64.2.1" and .["team-b/web"].ip == "100.64.2.2"' <<<"$(services_json)"
    run bash "$REPO/scripts/lib/service-registry.sh" resolve web
    check "bare name is ambiguous" differs "$RC" 0
}

test_sync_failed_list_changes_nothing() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":true}}'
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    touch "$T/k8s/fail-get-svc"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "reports failure" differs "$RC" 0
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"

    rm -f "$T/k8s/fail-get-svc"
    printf '{"items":[]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "empty list reports failure" differs "$RC" 0
    check "registry still untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"
}

test_blank_registry_is_not_overwritten() {
    set_cm service-registry services.json ''
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    printf '%s' "$(svc_item a web 100.64.2.1)" | jq -c '{items: [.]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "reports failure" differs "$RC" 0
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"
}

test_concurrent_writer_is_not_lost() {
    set_cm service-registry services.json '{"a/one":{"namespace":"a","service":"one","ip":"100.64.2.1","port":80,"local_name":"one","public":false}}'
    # Another writer adds a/two between our read and our patch.
    jq -cn --arg v '{"a/one":{"namespace":"a","service":"one","ip":"100.64.2.1","port":80,"local_name":"one","public":false},"a/two":{"namespace":"a","service":"two","ip":"100.64.2.2","port":80,"local_name":"two","public":false}}' \
        '{"services.json": $v}' >"$T/k8s/race-service-registry"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public a/one
    check "exits 0" equals "$RC" 0
    local reg
    reg=$(services_json)
    check "our change landed" jq -e '.["a/one"].public == true' <<<"$reg"
    check "their entry survived" jq -e 'has("a/two")' <<<"$reg"
    check "the conflict was retried" contains "$OUT" 'retrying'
}

test_hostile_annotation_does_not_execute() {
    local marker="$T/pwned"
    set_cm service-registry services.json '{}'
    jq -cn --argjson a "$(svc_item a web 100.64.2.1 "\$(touch $marker)")" \
        --argjson b "$(svc_item a web2 100.64.2.2 "\`touch $marker\`")" \
        --argjson c "$(svc_item a web3 100.64.2.3 "x; touch $marker #")" \
        '{items: [$a, $b, $c]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "nothing executed" no_file "$marker"
    check "hostile value dropped" jq -e '.["a/web"].local_name == "web"' <<<"$(services_json)"
    check "hostile value not stored anywhere" lacks "$T/k8s/cm/service-registry.json" 'touch'
    run bash "$REPO/scripts/lib/service-registry.sh" export-dns testcluster.local
    check "export executed nothing" no_file "$marker"

    # A hostile value already in the registry, reaching the other scripts.
    set_cm service-registry services.json "$(jq -cn --arg evil "\$(touch $marker)" \
        '{"a/web": {namespace: "a", service: "web", ip: "100.64.2.1", port: 80, local_name: $evil, public: true}}')"
    run bash "$REPO/scripts/lib/service-registry.sh" export-dns testcluster.local
    check "export executed nothing" no_file "$marker"
    check "export dropped the value" lacks "$OUT" 'touch'
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private "\$(touch $marker)"
    check "bad name is refused" differs "$RC" 0
    check "CLI argument executed nothing" no_file "$marker"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private a/web
    check "private executed nothing" no_file "$marker"
}

###############################################################################
# S2: manage-app-visibility.sh must verify on the VPS or say it hasn't
###############################################################################

setup_public_llmapi() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","legacy_key":"llmapi","public":true}}'
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    printf 'http:\n  routers:\n    a:\n      rule: "Host(`api.example.com`) && !PathPrefix(`/admin`)"\n' \
        >"$T/vps/traefik/config/mynodeone-routes.yml"
}

test_private_verified_when_route_is_gone() {
    setup_public_llmapi
    printf 'http:\n  routers: {}\n' >"$T/vps/traefik/config/mynodeone-routes.yml"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "exits 0" equals "$RC" 0
    check "says verified" contains "$OUT" 'Verified on VPS nodes'
    check "public false" jq -e '.["llmapi/llmapi"].public == false' <<<"$(services_json)"
    check "bare routing key removed" jq -e 'has("llmapi") | not' <<<"$(routing_json)"
}

test_private_falls_back_to_ssh_sync_then_rechecks() {
    setup_public_llmapi
    touch "$T/ssh/sync-cleans"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "exits 0" equals "$RC" 0
    check "used the fallback" contains "$T/ssh/sync.log" 'sync'
    check "says verified" contains "$OUT" 'Verified on VPS nodes'
}

test_private_not_verified_when_route_stays() {
    setup_public_llmapi
    # The sync reports success but the route is still there, as with an old agent.
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "distinct exit code" equals "$RC" 3
    check "says not verified" contains "$OUT" 'NOT VERIFIED'
    check "names the domain" contains "$OUT" 'api.example.com'
    check "doesn't claim success" lacks "$OUT" 'Verified on VPS nodes'
    check "registry was updated" jq -e '.["llmapi/llmapi"].public == false' <<<"$(services_json)"
}

test_private_not_verified_when_vps_unreachable() {
    setup_public_llmapi
    touch "$T/ssh/down"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "distinct exit code" equals "$RC" 3
    check "says not verified" contains "$OUT" 'NOT VERIFIED'
}

test_private_failed_read_changes_nothing() {
    setup_public_llmapi
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    touch "$T/k8s/fail-get-configmap"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "reports failure" equals "$RC" 1
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"
}

test_private_not_verified_when_vps_has_no_route_files() {
    # No file to look in isn't evidence that the route has gone.
    setup_public_llmapi
    rm -f "$T/vps/traefik/config/mynodeone-routes.yml"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "distinct exit code" equals "$RC" 3
    check "says not verified" contains "$OUT" 'NOT VERIFIED'
}

test_private_sees_route_left_in_another_file() {
    # A route from the older per-app generator keeps serving, so it must count.
    setup_public_llmapi
    printf 'http:\n  routers: {}\n' >"$T/vps/traefik/config/mynodeone-routes.yml"
    printf 'http:\n  routers:\n    a:\n      rule: "Host(`api.example.com`)"\n' >"$T/vps/traefik/config/llmapi.yml"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    check "distinct exit code" equals "$RC" 3
    check "says not verified" contains "$OUT" 'NOT VERIFIED'
}

###############################################################################
# S24: infrastructure services
###############################################################################

test_public_refuses_infrastructure_without_flag() {
    set_cm service-registry services.json '{"longhorn-system/longhorn-frontend":{"namespace":"longhorn-system","service":"longhorn-frontend","ip":"100.64.1.5","port":80,"local_name":"longhorn","public":false}}'
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public longhorn-system/longhorn-frontend
    check "refused" differs "$RC" 0
    check "explains how" contains "$OUT" '--allow-infrastructure'
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/service-registry.json"

    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public longhorn-system/longhorn-frontend --allow-infrastructure
    check "allowed with the flag" equals "$RC" 0
    check "warns about authentication" contains "$OUT" 'adds no login'
    check "now public" jq -e '.["longhorn-system/longhorn-frontend"].public == true' <<<"$(services_json)"
}

test_public_ordinary_service_needs_no_flag() {
    set_cm service-registry services.json '{"a/blog":{"namespace":"a","service":"blog","ip":"100.64.1.5","port":80,"local_name":"blog","public":false}}'
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public blog
    check "exits 0" equals "$RC" 0
    check "bare name resolved to key" jq -e '.["a/blog"].public == true' <<<"$(services_json)"
    check "says the route wasn't configured" contains "$OUT" 'no public route was configured'
}

###############################################################################
# S21 edge: blocked paths in the shell generators
###############################################################################

test_export_leaves_llmapi_paths_open_by_default() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","legacy_key":"llmapi","public":true}}'
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    run bash "$REPO/scripts/domains/multi-domain-registry.sh" export-vps-routes 100.64.0.2 100.64.0.9
    check "exits 0" equals "$RC" 0
    check "rule has no blocked paths" contains "$OUT" 'rule: "Host(`api.example.com`)"'
    check "nothing excluded" lacks "$OUT" '!PathPrefix'
    check "router name has no slash" lacks "$OUT" 'llmapi/llmapi'
    check "keeps the live service name" contains "$OUT" 'llmapi-service:'
    check "backend present" contains "$OUT" 'http://100.64.1.5:80'
}

test_export_honours_field_and_drops_malformed() {
    set_cm service-registry services.json '{"a/ok":{"namespace":"a","service":"ok","ip":"100.64.1.5","port":80,"public":true,"public_blocked_paths":["/internal"]},"a/off":{"namespace":"llmapi","service":"off","legacy_key":"llmapi","ip":"100.64.1.6","port":80,"public":true,"public_blocked_paths":[]},"a/bad":{"namespace":"a","service":"bad","ip":"100.64.1.7","port":80,"public":true,"public_blocked_paths":["no-slash`)"]},"a/priv":{"namespace":"a","service":"priv","ip":"100.64.1.8","port":80,"public":false}}'
    set_cm domain-registry routing.json '{"a/ok":{"expose":["ok.example.com"],"vps_nodes":["100.64.0.2"]},"a/off":{"expose":["off.example.com"],"vps_nodes":["100.64.0.2"]},"a/bad":{"expose":["bad.example.com"],"vps_nodes":["100.64.0.2"]},"a/priv":{"expose":["priv.example.com"],"vps_nodes":["100.64.0.2"]}}'
    run bash "$REPO/scripts/domains/multi-domain-registry.sh" export-vps-routes 100.64.0.2 100.64.0.9
    check "field is used" contains "$OUT" 'Host(`ok.example.com`) && !PathPrefix(`/internal`)'
    check "explicit [] blocks nothing" contains "$OUT" 'rule: "Host(`off.example.com`)"'
    check "malformed entry dropped" lacks "$OUT" 'rule: "Host(`bad.example.com`)'
    check "private service not exported" lacks "$OUT" 'rule: "Host(`priv.example.com`)'
}

test_configure_routing_uses_key_and_replaces_bare_alias() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"legacy_key":"llmapi","public":true}}'
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    run bash "$REPO/scripts/domains/multi-domain-registry.sh" configure-routing llmapi api.example.com 100.64.0.2
    check "exits 0" equals "$RC" 0
    check "own bare key isn't a conflict" lacks "$OUT" 'already used by'
    local routing
    routing=$(routing_json)
    check "filed under the key" jq -e '.["llmapi/llmapi"].expose == ["api.example.com"]' <<<"$routing"
    check "bare alias replaced" jq -e 'has("llmapi") | not' <<<"$routing"
}

###############################################################################
# R20: sync-vps-routes.sh
###############################################################################

write_vps_config() {
    cat >"$T/home/.mynodeone/config.env" <<EOF
CONTROL_PLANE_IP=100.64.0.9
PUBLIC_DOMAIN=example.com
API_TOKEN=$TOKEN
TRAEFIK_CONFIG_DIR=$T/traefik
EOF
}

test_vps_sync_installs_atomically_without_restart() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_TWO"
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "exits 0" equals "$RC" 0
    check "installed" contains "$T/traefik/mynodeone-routes.yml" 'b.example.com'
    check "token not in argv" lacks "$T/api/argv.log" "$TOKEN"
    check "no restart" lacks "$T/docker/calls.log" 'restart'
    check "no temp file left" equals "$(find "$T/traefik" -name '.mynodeone-routes.*' | wc -l)" 0
}

test_vps_sync_unchanged_does_nothing() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    # Same routes, a later timestamp.
    api /api/v1/config/vps/traefik-config 200 "${ROUTES_ONE/2026-01-01/2026-01-09}"
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "exits 0" equals "$RC" 0
    check "says unchanged" contains "$OUT" 'Routes unchanged'
    check "no backup" equals "$(find "$T/traefik" -name '*.backup.*' | wc -l)" 0
}

test_vps_sync_prunes_backups() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    local i
    for i in 1 2 3 4 5 6 7 8; do
        touch -d "2026-01-0$i" "$T/traefik/mynodeone-routes.yml.backup.2026010${i}_000000"
    done
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_TWO"
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "exits 0" equals "$RC" 0
    check "keeps the newest five" equals "$(find "$T/traefik" -name '*.backup.*' | wc -l)" 5
}

test_vps_sync_error_keeps_routes() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps/traefik-config 503 'unavailable'
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_vps_sync_garbage_200_keeps_routes() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps/traefik-config 200 '<html>bad gateway</html>'
    # A new server, so the old-server check can't be what rejects this.
    api /api/v1/health 200 '{"status":"ok","registry_schema":2}'
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "reports failure" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_vps_sync_old_server_cannot_wipe_routes() {
    write_vps_config
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    api /api/v1/health 200 '{"status":"healthy"}'
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "refuses" differs "$RC" 0
    check "routes untouched" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"

    api /api/v1/health 200 '{"status":"healthy","registry_schema":2}'
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "schema 2 can confirm empty" equals "$RC" 0
    check "route removed" lacks "$T/traefik/mynodeone-routes.yml" 'a.example.com'
    check "message sync-controller looks for" contains "$OUT" 'No public services configured'
}

test_vps_sync_starts_stopped_traefik_only() {
    write_vps_config
    touch "$T/docker/stopped"
    mkdir -p "$T/home/traefik"
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_ONE"
    run bash "$REPO/scripts/vps/sync-vps-routes.sh"
    check "starts it" contains "$T/docker/calls.log" 'compose up -d'
    check "no restart" lacks "$T/docker/calls.log" 'restart'
}

###############################################################################
# R20 and R10: sync-controller.sh
###############################################################################

# Runs a snippet with the controller's functions loaded and push_sync_all stubbed.
controller() {
    cat >"$T/snippet.sh" <<EOF
source "$REPO/scripts/lib/sync-controller.sh"
$1
EOF
    run bash "$T/snippet.sh"
}

test_watch_keeps_version_until_push_succeeds() {
    set_cm service-registry services.json '{}'
    controller '
        calls=0
        push_sync_all() { calls=$((calls + 1)); [[ -e "$FAKE_K8S/push-works" ]]; }
        WATCH_MIN_BACKOFF=0

        watch_tick
        [[ -z "$WATCH_LAST_VERSION" ]] || { echo "BAD: advanced after a failed push"; exit 1; }
        [[ "$calls" -eq 1 ]] || { echo "BAD: calls=$calls"; exit 1; }

        WATCH_MIN_BACKOFF=1000
        WATCH_RETRY_DELAY=0
        watch_tick
        [[ "$calls" -eq 2 ]] || { echo "BAD: retry did not happen, calls=$calls"; exit 1; }
        watch_tick
        [[ "$calls" -eq 2 ]] || { echo "BAD: ignored backoff, calls=$calls"; exit 1; }

        WATCH_NEXT_RETRY=0
        touch "$FAKE_K8S/push-works"
        watch_tick
        [[ "$WATCH_LAST_VERSION" == "1" ]] || { echo "BAD: did not advance, last=$WATCH_LAST_VERSION"; exit 1; }
        [[ "$WATCH_RETRY_DELAY" -eq 0 ]] || { echo "BAD: backoff not reset"; exit 1; }

        watch_tick
        [[ "$calls" -eq 3 ]] || { echo "BAD: pushed an unchanged version, calls=$calls"; exit 1; }
        echo PASSED
    '
    check "state machine" contains "$OUT" 'PASSED'
}

test_watch_newer_version_skips_backoff() {
    set_cm service-registry services.json '{}'
    controller '
        calls=0
        push_sync_all() { calls=$((calls + 1)); return 1; }
        WATCH_MIN_BACKOFF=1000
        watch_tick
        watch_tick
        [[ "$calls" -eq 1 ]] || { echo "BAD: backoff ignored, calls=$calls"; exit 1; }
        jq ".metadata.resourceVersion = \"2\"" "$FAKE_K8S/cm/service-registry.json" >"$FAKE_K8S/new"
        mv "$FAKE_K8S/new" "$FAKE_K8S/cm/service-registry.json"
        watch_tick
        [[ "$calls" -eq 2 ]] || { echo "BAD: newer version waited, calls=$calls"; exit 1; }
        echo PASSED
    '
    check "newer version pushed at once" contains "$OUT" 'PASSED'
}

test_reconcile_loop_is_restarted() {
    controller '
        periodic_reconciliation() { touch "$FAKE_K8S/started.$BASHPID"; exit 0; }
        RECONCILE_HOURS=1
        start_reconciliation
        wait "$RECONCILE_PID" || true
        first=$RECONCILE_PID
        supervise_reconciliation
        [[ "$RECONCILE_PID" != "$first" ]] || { echo "BAD: not restarted"; exit 1; }
        wait "$RECONCILE_PID" || true
        echo PASSED
    '
    check "restarted" contains "$OUT" 'PASSED'
    check "ran twice" equals "$(find "$T/k8s" -name 'started.*' | wc -l)" 2
}

test_node_record_update_survives_jq_failure() {
    printf '{"vps_nodes":[{"ip":"100.64.0.2","status":"x"}]}' >"$T/registry.json"
    cp "$T/registry.json" "$T/before"
    controller "
        update_node_record '$T/registry.json' vps_nodes 100.64.0.2 '(.status = \"ok\")' || echo BAD
        jq -e '.vps_nodes[0].status == \"ok\"' '$T/registry.json' >/dev/null && echo UPDATED
        cp '$T/before' '$T/registry.json'
        update_node_record '$T/registry.json' vps_nodes 100.64.0.2 'this is not jq(' && echo BAD
        cmp -s '$T/before' '$T/registry.json' && echo INTACT
    "
    check "updates" contains "$OUT" 'UPDATED'
    check "failure leaves the file intact" contains "$OUT" 'INTACT'
    check "failure is reported" lacks "$OUT" 'BAD'
}

test_stop_is_a_clean_exit() {
    controller '
        RECONCILE_PID=""
        stop_daemon
    '
    check "exit 0" equals "$RC" 0
}

###############################################################################
# Readers work on both registry formats. These are the same two services before and
# after migration, so each consumer has to give the same answer for both.
###############################################################################

NEW_REGISTRY='{"llmapi/llmapi":{"legacy_key":"llmapi","namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":true},"default/demo":{"legacy_key":"demo","namespace":"default","service":"demo","ip":"100.64.1.6","port":80,"local_name":"","public":false}}'

# A helper call against the stubs. $1 is the shell snippet; $2... reach it as "$@".
lib_call() {
    local snippet="$1"
    shift
    run bash -c 'source "$REGISTRY_LIB"; '"$snippet" _ "$@"
}

helper_finds() {
    # helper_finds <description> <services-json> <name> <expected-key>
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    lib_call 'sr_lookup_entry "$1" "$2" | jq -r .namespace; sr_resolve_key "$1" "$2"' "$2" "$3"
    EXTRA_ENV=()
    check "$1: exits 0" equals "$RC" 0
    check "$1: entry found" equals "$(sed -n 1p "$OUT")" "${5:-llmapi}"
    check "$1: key" equals "$(sed -n 2p "$OUT")" "$4"
}

test_lookup_entry_reads_both_formats() {
    helper_finds "old format, bare name" "$OLD_REGISTRY" llmapi llmapi
    helper_finds "old format, namespace/name" "$OLD_REGISTRY" llmapi/llmapi llmapi
    helper_finds "new format, bare name" "$NEW_REGISTRY" llmapi llmapi/llmapi
    helper_finds "new format, namespace/name" "$NEW_REGISTRY" llmapi/llmapi llmapi/llmapi
    helper_finds "old format, other service" "$OLD_REGISTRY" default/demo demo default
    helper_finds "new format, other service" "$NEW_REGISTRY" demo default/demo default
}

test_lookup_entry_refuses_to_guess() {
    local two='{"a/web":{"namespace":"a","service":"web"},"b/web":{"namespace":"b","service":"web"}}'
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    lib_call 'sr_lookup_entry "$1" nosuch' "$OLD_REGISTRY"
    check "unknown is rc 1" equals "$RC" 1
    check "unknown prints no entry" equals "$(wc -c <"$OUT")" 0
    lib_call 'sr_lookup_entry "$1" web' "$two"
    check "ambiguous is rc 2" equals "$RC" 2
    check "ambiguous prints no entry" lacks "$OUT" '"namespace"'
    lib_call 'sr_lookup_entry "$1" b/web | jq -r .namespace' "$two"
    check "namespace/name still resolves" equals "$(cat "$OUT")" b
    EXTRA_ENV=()
}

test_service_field_reads_both_formats() {
    local registry
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    for registry in "$OLD_REGISTRY" "$NEW_REGISTRY"; do
        set_cm service-registry services.json "$registry"
        lib_call 'sr_service_field llmapi/llmapi local_name'
        check "local_name" equals "$(cat "$OUT")" llmapi
        lib_call 'sr_service_field llmapi public'
        check "false and true print as themselves" equals "$(cat "$OUT")" true
        lib_call 'sr_service_field default/demo public'
        check "false isn't treated as missing" equals "$(cat "$OUT")" false
        lib_call 'sr_service_field llmapi/llmapi nosuchfield'
        check "missing field is empty" equals "$(wc -c <"$OUT")" 1
        check "missing field is success" equals "$RC" 0
        lib_call 'sr_service_field nosuch local_name'
        check "unknown service fails" differs "$RC" 0
    done
    set_cm service-registry services.json "$NEW_REGISTRY"
    lib_call 'sr_service_field default/demo local_name'
    check "blank local_name is empty, not null" equals "$(cat "$OUT")" ""
    touch "$T/k8s/fail-get-configmap"
    lib_call 'sr_service_field llmapi local_name'
    check "unreadable registry fails" differs "$RC" 0
    EXTRA_ENV=()
}

test_installers_use_the_shared_lookup() {
    local script
    for script in homepage/install-homepage immich/install-immich jellyfin/install-jellyfin nextcloud/install-nextcloud; do
        check "$script uses the helper" grep -q 'sr_service_field "\$NAMESPACE/' "$REPO/scripts/apps/$script.sh"
    done
    # Nothing outside the library, tests and the fallback aliases may index the
    # registry by a bare name, because that stops matching after migration.
    local hits
    hits=$(cd "$REPO" && git ls-files 'scripts/apps/*.sh' |
        xargs grep -nE "jq -r '?\"?\.(homepage|jellyfin|nextcloud|\\\\?\"immich-server)" 2>/dev/null ||
        true)
    check "no bare-key installer lookups: $hits" equals "$hits" ""
}

test_paperless_hook_reads_both_formats() {
    local registry
    for registry in "$OLD_REGISTRY" "$NEW_REGISTRY"; do
        set_cm service-registry services.json "${registry//llmapi/paperless}"
        : >"$T/k8s/calls.log"
        EXTRA_ENV=(CLUSTER_DOMAIN=testcluster)
        run bash "$REPO/scripts/apps/paperless/post-public-hook.sh" paperless paper.example.com
        EXTRA_ENV=()
        check "exits 0" equals "$RC" 0
        check "namespace found" grep -q 'set env deployment/paperless -n paperless' "$T/k8s/calls.log"
        check "local host allowed" contains "$T/k8s/calls.log" 'paperless.testcluster.local'
        check "public host allowed" contains "$T/k8s/calls.log" 'paper.example.com'
    done
}

test_paperless_hook_stops_when_service_is_unknown() {
    set_cm service-registry services.json "$NEW_REGISTRY"
    run bash "$REPO/scripts/apps/paperless/post-public-hook.sh" paperless paper.example.com
    check "fails" differs "$RC" 0
    check "says why" contains "$OUT" 'Could not find paperless'
    check "changes nothing" lacks "$T/k8s/calls.log" 'set env'
}

test_remove_domain_labels_both_formats() {
    local registry
    for registry in "$OLD_REGISTRY" "$NEW_REGISTRY"; do
        set_cm service-registry services.json "$(jq -c 'map_values(if .service == "llmapi" then .local_name = "chat" else . end)' <<<"$registry")"
        set_cm domain-registry routing.json '{"llmapi":{"expose":["api.example.com"]},"default/demo":{"expose":["demo.example.com"]}}'
        set_cm domain-registry domains.json '{"domains":{"example.com":{}},"vps_nodes":[]}'
        run bash -c 'echo no | bash "$1" example.com' _ "$REPO/scripts/domains/remove-domain.sh"
        check "lists the service by local name" contains "$OUT" 'chat'
        check "stops at the prompt" contains "$OUT" 'cancelled'
        check "nothing written" no_file "$T/k8s/patches.log"
    done
}

export_services_output() {
    sed -n '/^export_services() {/,/^}/p' "$REPO/website/export-services.sh" >"$T/export-fn.sh"
    mkdir -p "$T/www"
    run bash -c 'log() { :; }; OUTPUT_DIR="$1"; source "$2"; export_services' _ "$T/www" "$T/export-fn.sh"
}

test_dashboard_export_reads_both_formats() {
    local old new
    set_cm service-registry services.json "$OLD_REGISTRY"
    export_services_output
    check "old: exits 0" equals "$RC" 0
    old=$(jq -cS 'map(del(.key))' "$T/www/services.json")
    set_cm service-registry services.json "$NEW_REGISTRY"
    export_services_output
    check "new: exits 0" equals "$RC" 0
    new=$(jq -cS 'map(del(.key))' "$T/www/services.json")
    check "old: name stays bare" equals "$(jq -r '[.[].name] | sort | join(",")' <<<"$old")" demo,llmapi
    check "new: name stays bare" equals "$(jq -r '[.[].name] | sort | join(",")' <<<"$new")" demo,llmapi
    check "new: full key kept" equals "$(jq -r 'map(.key) | sort | join(",")' "$T/www/services.json")" default/demo,llmapi/llmapi
    check "new: blank local_name kept" equals "$(jq -r '.[] | select(.name == "demo") | .local_name' <<<"$new")" ""
    check "same entry either way" equals "$(jq -c '.[] | select(.name == "llmapi")' <<<"$old")" "$(jq -c '.[] | select(.name == "llmapi")' <<<"$new")"
}

audit_run() {
    run bash -c 'cd "$1" && bash scripts/operations/audit-registry-consistency.sh' _ "$REPO"
}

audit_setup() {
    set_cm service-registry services.json "$1"
    set_cm domain-registry routing.json "$2"
    set_cm domain-registry domains.json '{"domains":{},"vps_nodes":[]}'
    set_cm sync-controller-registry registry.json '{"control_plane":[],"workers":[],"vps_nodes":[],"management_laptops":[]}'
}

test_audit_accepts_both_formats() {
    audit_setup "$OLD_REGISTRY" "$LIVE_ROUTING"
    audit_run
    check "old: runs to the summary" contains "$OUT" 'Audit Summary'
    check "old: reported as pending" contains "$OUT" 'still has bare keys'
    check "old: routes resolve" lacks "$OUT" 'does not identify'
    audit_setup "$NEW_REGISTRY" "$LIVE_ROUTING"
    audit_run
    check "new: runs to the summary" contains "$OUT" 'Audit Summary'
    check "new: reported as done" contains "$OUT" 'uses namespace/name keys'
    check "new: bare route still resolves" lacks "$OUT" 'does not identify'
    audit_setup "$NEW_REGISTRY" '{"gone":{"expose":["x.example.com"]}}'
    audit_run
    check "route with no service is reported" contains "$OUT" "'gone' does not identify"
}

validate_function() {
    # Loads the script without its main, so one check can run without the others.
    sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=$REPO/scripts/lib#" -e '/^main "\$@"$/d' \
        "$REPO/scripts/lib/validate-installation.sh" >"$T/validate.sh"
}

test_validate_lists_services_in_both_formats() {
    local registry
    validate_function
    for registry in "$OLD_REGISTRY" "$NEW_REGISTRY"; do
        set_cm service-registry services.json "$registry"
        echo '{"items":[]}' >"$T/k8s/svcs.json"
        EXTRA_ENV=(CLUSTER_DOMAIN=testcluster K3S_DATA_DIR="$T/k3s")
        run bash -c 'source "$1"; run_test() { :; }; validate_control_plane' _ "$T/validate.sh"
        EXTRA_ENV=()
        check "count" contains "$OUT" 'has 2 registered services'
        check "host listed" contains "$OUT" 'llmapi.testcluster.local → 100.64.1.5'
    done
    check "blank local_name is the bare domain" contains "$OUT" '• testcluster.local → 100.64.1.6'
}

join_token_check() {
    validate_function
    EXTRA_ENV=(K3S_DATA_DIR="$T/k3s")
    run bash -c 'source "$1"; check_join_token; echo "warned=$TESTS_WARNED"' _ "$T/validate.sh"
    EXTRA_ENV=()
}

test_join_token_check_looks_where_the_token_is() {
    mkdir -p "$T/k3s/server"
    printf 'secret-join-token\n' >"$T/k3s/server/agent-token"
    join_token_check
    check "present is success" contains "$OUT" 'Join token present'
    check "shows how to read it" contains "$OUT" "sudo cat $T/k3s/server/agent-token"
    check "no warning" contains "$OUT" 'warned=0'
    check "never prints it" lacks "$OUT" 'secret-join-token'

    rm "$T/k3s/server/agent-token"
    join_token_check
    check "missing is a warning" contains "$OUT" 'Join token not found'
    check "missing is counted" contains "$OUT" 'warned=1'

    printf '#!/bin/bash\nexit 1\n' >"$T/bin/sudo"
    join_token_check
    if [[ "$(id -u)" -ne 0 ]]; then
        check "without root it can't tell, and says so" contains "$OUT" 'Could not check the join token'
        check "not counted as a problem" contains "$OUT" 'warned=0'
    fi
    install -m 755 "$HERE/stubs/sudo" "$T/bin/sudo"

    printf 'old\n' >"$T/home/mynodeone-join-token.txt"
    printf 'secret-join-token\n' >"$T/k3s/server/agent-token"
    join_token_check
    check "old home copy is flagged" contains "$OUT" 'Old join token copy found'
    check "old copy is counted" contains "$OUT" 'warned=1'
}

###############################################################################
# MinIO aliases: both formats, through the conditional write
###############################################################################

MINIO_OLD='{"minio":{"namespace":"minio","service":"minio","ip":"100.64.1.7","local_name":"minio"},"minio-api":{"namespace":"minio","service":"minio","ip":"100.64.1.7"},"minio-node1":{"namespace":"minio-node1","service":"minio","ip":"100.64.1.8","local_name":"minio-node1"},"demo":{"namespace":"default","service":"demo","ip":"100.64.1.6"}}'
MINIO_NEW='{"minio/minio":{"legacy_key":"minio","namespace":"minio","service":"minio","ip":"100.64.1.7","local_name":"minio"},"minio/minio-console":{"legacy_key":"minio-console","namespace":"minio","service":"minio-console","ip":"100.64.1.7"},"minio-node1/minio":{"legacy_key":"minio-node1","namespace":"minio-node1","service":"minio","ip":"100.64.1.8","local_name":"minio-node1"},"default/demo":{"legacy_key":"demo","namespace":"default","service":"demo","ip":"100.64.1.6"}}'

test_cleanup_minio_old_format() {
    set_cm service-registry services.json "$MINIO_OLD"
    run bash "$REPO/scripts/utils/cleanup-minio-aliases.sh"
    check "exits 0" equals "$RC" 0
    check "only the real entries are left" equals "$(services_json | jq -r 'keys | join(",")')" demo,minio-node1
    check "written with a resourceVersion" grep -q resourceVersion "$T/k8s/patches.log"
    check "lists what is left" contains "$OUT" 'minio-node1 → minio-node1'
}

test_cleanup_minio_new_format() {
    set_cm service-registry services.json "$MINIO_NEW"
    run bash "$REPO/scripts/utils/cleanup-minio-aliases.sh"
    check "exits 0" equals "$RC" 0
    check "generic entries removed, per-node kept" \
        equals "$(services_json | jq -r 'keys | join(",")')" default/demo,minio-node1/minio
    check "stays in the new format" equals "$(services_json | jq -r '.["minio-node1/minio"].legacy_key')" minio-node1
}

test_cleanup_minio_keeps_a_concurrent_change() {
    set_cm service-registry services.json "$MINIO_NEW"
    local other
    other=$(jq -c '. + {"apps/new":{"legacy_key":"new","namespace":"apps","service":"new","ip":"100.64.1.9"}}' <<<"$MINIO_NEW")
    jq -cn --arg v "$other" '{"services.json":$v}' >"$T/k8s/race-service-registry"
    run bash "$REPO/scripts/utils/cleanup-minio-aliases.sh"
    check "exits 0" equals "$RC" 0
    check "other writer's entry kept" equals "$(services_json | jq -r 'has("apps/new")')" true
    check "aliases still removed" equals "$(services_json | jq -r 'has("minio/minio")')" false
}

test_cleanup_minio_read_failure_changes_nothing() {
    set_cm service-registry services.json "$MINIO_NEW"
    cp "$T/k8s/cm/service-registry.json" "$T/before"
    touch "$T/k8s/fail-get-configmap"
    run bash "$REPO/scripts/utils/cleanup-minio-aliases.sh"
    rm "$T/k8s/fail-get-configmap"
    check "reports failure" differs "$RC" 0
    check "doesn't claim nothing to clean" lacks "$OUT" 'nothing to clean'
    check "registry unchanged" same_file "$T/before" "$T/k8s/cm/service-registry.json"
}

test_cleanup_minio_without_aliases_writes_nothing() {
    set_cm service-registry services.json "$NEW_REGISTRY"
    run bash "$REPO/scripts/utils/cleanup-minio-aliases.sh"
    check "exits 0" equals "$RC" 0
    check "says so" contains "$OUT" 'No generic MinIO aliases'
    check "no write" no_file "$T/k8s/patches.log"
}

###############################################################################
# R10: add_domain and remove_domain go through the conditional write
###############################################################################

# The script's functions, without its command dispatch.
domain_functions() {
    sed -e "s#^source .*service-registry-lib.sh\"\$#source \"$REPO/scripts/lib/service-registry-lib.sh\"#" \
        -e '/^case "\${1:-}" in$/,$d' \
        "$REPO/scripts/domains/multi-domain-registry.sh" >"$T/mdr.sh"
}

domain_call() {
    domain_functions
    run bash -c 'source "$1"; shift; "$@"' _ "$T/mdr.sh" "$@"
}

DOMAIN_ROUTES='{"llmapi":{"expose":["api.example.com"],"vps_nodes":[]},"demo":{"expose":["demo.example.com"],"vps_nodes":[]}}'

domain_setup() {
    set_cm domain-registry domains.json '{"domains":{"example.com":{}},"vps_nodes":[]}'
    set_cm domain-registry routing.json "$DOMAIN_ROUTES"
}

test_add_domain_retries_after_conflict() {
    domain_setup
    jq -cn --arg v "$(jq -c '.demo.expose += ["other.example.com"]' <<<"$DOMAIN_ROUTES")" \
        '{"routing.json":$v}' >"$T/k8s/race-domain-registry"
    domain_call add_domain llmapi new.example.com
    check "exits 0" equals "$RC" 0
    check "the race fired" no_file "$T/k8s/race-domain-registry"
    check "domain added" equals "$(routing_json | jq -r '.llmapi.expose | join(",")')" api.example.com,new.example.com
    check "other writer's change kept" equals "$(routing_json | jq -r '.demo.expose | join(",")')" demo.example.com,other.example.com
    check "exactly one write landed" equals "$(grep -c '"resourceVersion"' "$T/k8s/patches.log")" 1
    check "write carries a resourceVersion" grep -q resourceVersion "$T/k8s/patches.log"
    check "routing.json is still valid JSON" jq -e 'type == "object"' <<<"$(routing_json)"
}

test_remove_domain_retries_after_conflict() {
    domain_setup
    jq -cn --arg v "$(jq -c '.demo.expose += ["other.example.com"]' <<<"$DOMAIN_ROUTES")" \
        '{"routing.json":$v}' >"$T/k8s/race-domain-registry"
    domain_call remove_domain llmapi api.example.com
    check "exits 0" equals "$RC" 0
    check "the race fired" no_file "$T/k8s/race-domain-registry"
    check "domain removed" equals "$(routing_json | jq -c '.llmapi.expose')" '[]'
    check "other writer's change kept" equals "$(routing_json | jq -r '.demo.expose | join(",")')" demo.example.com,other.example.com
}

test_add_domain_read_failure_changes_nothing() {
    domain_setup
    cp "$T/k8s/cm/domain-registry.json" "$T/before"
    touch "$T/k8s/fail-get-configmap"
    domain_call add_domain llmapi new.example.com
    rm "$T/k8s/fail-get-configmap"
    check "reports failure" differs "$RC" 0
    check "no write" no_file "$T/k8s/patches.log"
    check "registry unchanged" same_file "$T/before" "$T/k8s/cm/domain-registry.json"
}

test_add_domain_gives_up_when_conflicts_continue() {
    domain_setup
    cat >"$T/bin/kubectl" <<EOF
#!/bin/bash
if [[ "\$1" == patch ]]; then
    echo patch >>"$T/patch-attempts"
    echo 'Error from server (Conflict): the object has been modified' >&2
    exit 1
fi
exec bash "$HERE/stubs/kubectl" "\$@"
EOF
    EXTRA_ENV=(SR_CAS_ATTEMPTS=3)
    domain_call add_domain llmapi new.example.com
    EXTRA_ENV=()
    check "reports failure" differs "$RC" 0
    check "tried the allowed number of times" equals "$(wc -l <"$T/patch-attempts")" 3
    check "registry unchanged" equals "$(routing_json | jq -cS .)" "$(jq -cS . <<<"$DOMAIN_ROUTES")"
}

test_add_domain_needs_an_existing_route() {
    domain_setup
    domain_call add_domain nosuch new.example.com
    check "reports failure" differs "$RC" 0
    check "says why" contains "$OUT" 'not found in routing config'
    check "no write" no_file "$T/k8s/patches.log"
}

test_domain_filters_never_create_a_route() {
    local filter
    domain_functions
    for filter in add_domain_filter remove_domain_filter; do
        run bash -c 'source "$1"; echo "{}" | "$2" nosuch new.example.com' _ "$T/mdr.sh" "$filter"
        check "$filter: error" differs "$RC" 0
        check "$filter: no output to write" lacks "$OUT" '"nosuch":'
    done
}

###############################################################################
# /etc/hosts has one writer per host
###############################################################################

hosts_setup() {
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/hosts.before"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json "$OLD_REGISTRY"
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5 llmapi)" '{items: [$a]}' >"$T/k8s/svcs.json"
}

post_install() {
    EXTRA_ENV=(CLUSTER_DOMAIN=testcluster)
    run bash -c 'source "$1" llmapi 80 llmapi llmapi llmapi' _ "$REPO/scripts/lib/post-install-routing.sh"
    EXTRA_ENV=()
}

test_hosts_writer_is_detected() {
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    lib_call sr_hosts_writer
    check "neither" equals "$(cat "$OUT")" none
    touch "$T/systemd/agent-active"
    lib_call sr_hosts_writer
    check "agent" equals "$(cat "$OUT")" agent
    touch "$T/systemd/timer-active"
    lib_call sr_hosts_writer
    check "timer wins, the agent stands down for it" equals "$(cat "$OUT")" timer
    lib_call 'PATH=/nonexistent; sr_hosts_writer'
    EXTRA_ENV=()
    check "no systemd at all" equals "$(cat "$OUT")" none
}

test_post_install_triggers_the_timer_service() {
    hosts_setup
    touch "$T/systemd/timer-active"
    post_install
    check "timer's service started" contains "$T/systemd/calls.log" 'start mynodeone-local-dns-sync.service'
    check "hosts not written directly" same_file "$T/hosts.before" "$T/hosts"
    check "reports success" contains "$OUT" 'Local DNS updated'
}

test_post_install_defers_to_the_node_agent() {
    hosts_setup
    touch "$T/systemd/agent-active"
    post_install
    check "hosts not written" same_file "$T/hosts.before" "$T/hosts"
    check "agent not restarted" lacks "$T/systemd/calls.log" 'restart'
    check "says when it will appear" contains "$OUT" 'next poll'
    check "doesn't claim it is done" lacks "$OUT" 'Local DNS updated'
    check "shows the address" contains "$OUT" 'llmapi.testcluster.local'
}

test_post_install_writes_once_with_no_owner() {
    hosts_setup
    post_install
    check "name added" contains "$T/hosts" 'llmapi.testcluster.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
    check "reports success" contains "$OUT" 'Local DNS updated'
    local before
    before=$(grep -c 'llmapi.testcluster.local' "$T/hosts")
    post_install
    check "a second run doesn't duplicate it" equals "$(grep -c 'llmapi.testcluster.local' "$T/hosts")" "$before"
}

test_post_install_reports_a_failed_refresh() {
    hosts_setup
    touch "$T/systemd/timer-active"
    cat >"$T/bin/systemctl" <<EOF
#!/bin/bash
case "\$*" in
    start*) exit 1 ;;
    *) exec bash "$HERE/stubs/systemctl" "\$@" ;;
esac
EOF
    post_install
    check "warns" contains "$OUT" 'Could not update local DNS'
    check "doesn't claim success" lacks "$OUT" 'Local DNS updated'
}

fix_duplicate() {
    printf '127.0.0.1 localhost\n# MyNodeOne Apps\n100.64.1.5 old.testcluster.local\n# End MyNodeOne Apps\n100.64.1.5 demoapp.other.local\n' >"$T/hosts"
    EXTRA_ENV=(CLUSTER_DOMAIN=testcluster)
    run bash -c 'echo y | bash "$1"' _ "$REPO/scripts/domains/fix-duplicate-dns.sh"
    EXTRA_ENV=()
}

test_fix_duplicate_removes_retired_names_then_defers() {
    hosts_setup
    touch "$T/systemd/timer-active"
    fix_duplicate
    check "exits 0" equals "$RC" 0
    check "retired block removed" lacks "$T/hosts" 'old.testcluster.local'
    check "retired name under another domain removed" lacks "$T/hosts" 'demoapp.other.local'
    check "user entry kept" contains "$T/hosts" 'localhost'
    check "backup made" compgen -G "$T/hosts.backup.*"
    check "timer's service started" contains "$T/systemd/calls.log" 'start mynodeone-local-dns-sync.service'
    check "current names not written here" lacks "$T/hosts" 'llmapi.testcluster.local'
}

test_fix_duplicate_writes_current_names_with_no_owner() {
    hosts_setup
    fix_duplicate
    check "exits 0" equals "$RC" 0
    check "retired block removed" lacks "$T/hosts" 'old.testcluster.local'
    check "current name added" contains "$T/hosts" 'llmapi.testcluster.local'
}

test_fix_duplicate_on_agent_host_leaves_names_to_the_agent() {
    hosts_setup
    touch "$T/systemd/agent-active"
    fix_duplicate
    check "exits 0" equals "$RC" 0
    check "retired block removed" lacks "$T/hosts" 'old.testcluster.local'
    check "current names not written here" lacks "$T/hosts" 'llmapi.testcluster.local'
    check "says who does" contains "$OUT" 'node agent manages DNS'
}

test_no_script_appends_to_hosts_outside_the_writers() {
    local script
    for script in scripts/lib/post-install-routing.sh scripts/operations/deploy-demo-app.sh scripts/domains/fix-duplicate-dns.sh; do
        check "$script doesn't append to hosts" lacks "$REPO/$script" 'tee -a /etc/hosts'
        check "$script doesn't export entries itself" lacks "$REPO/$script" 'export-dns'
    done
    check "demo app uses the shared refresh" contains "$REPO/scripts/operations/deploy-demo-app.sh" 'sr_refresh_hosts'
}

###############################################################################
# The API token stays out of argv
###############################################################################

# A fake installer that records its arguments and what it was handed.
fake_node_agent_installer() {
    mkdir -p "$T/project/scripts/installation"
    cat >"$T/project/scripts/installation/install-node-agent.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >"$T/installer-argv"
while ((\$#)); do
    if [[ "\$1" == --api-token-file ]]; then
        printf '%s' "\$2" >"$T/installer-token-path"
        stat -c '%a' "\$2" >"$T/installer-token-mode"
        cp "\$2" "$T/installer-token-copy"
    fi
    shift
done
exit \${FAKE_INSTALLER_RC:-0}
EOF
    chmod +x "$T/project/scripts/installation/install-node-agent.sh"
}

laptop_install() {
    sed -n '/^install_laptop_node_agent() {/,/^}/p' "$REPO/scripts/setup/setup-laptop.sh" >"$T/fn.sh"
    run bash -c 'set -e
        log_success() { echo "OK: $1"; }
        log_warn() { echo "WARN: $1"; }
        ssh_with_control() { printf "%s\n" "$FAKE_TOKEN"; }
        PROJECT_ROOT="$1"; export TMPDIR="$2"; source "$3"; NODE_AGENT_TOKEN_TMP=""
        install_laptop_node_agent admin 100.64.0.9 laptop1
        echo "after=$NODE_AGENT_TOKEN_TMP"' _ "$T/project" "$T/tmp" "$T/fn.sh"
}

test_laptop_token_goes_through_a_private_file() {
    fake_node_agent_installer
    mkdir -p "$T/tmp"
    EXTRA_ENV=(FAKE_TOKEN="$TOKEN")
    laptop_install
    check "exits 0" equals "$RC" 0
    check "installer called" contains "$T/installer-argv" '--api-token-file'
    check "token not in argv" lacks "$T/installer-argv" "$TOKEN"
    check "no --api-token flag" lacks "$T/installer-argv" '--api-token '
    check "file is mode 600" equals "$(cat "$T/installer-token-mode")" 600
    check "file holds the token" contains "$T/installer-token-copy" "$TOKEN"
    check "file removed afterwards" no_file "$(cat "$T/installer-token-path")"
    check "temp dir empty" equals "$(find "$T/tmp" -type f | wc -l)" 0
    check "reports success" contains "$OUT" 'OK: Node agent installed'
    check "tracker cleared" contains "$OUT" 'after='
    EXTRA_ENV=()
}

test_laptop_installer_failure_warns_and_cleans_up() {
    fake_node_agent_installer
    mkdir -p "$T/tmp"
    EXTRA_ENV=(FAKE_TOKEN="$TOKEN" FAKE_INSTALLER_RC=1)
    laptop_install
    EXTRA_ENV=()
    check "laptop setup carries on" equals "$RC" 0
    check "warns" contains "$OUT" 'WARN: Node agent installation failed'
    check "file removed afterwards" no_file "$(cat "$T/installer-token-path")"
    check "temp dir empty" equals "$(find "$T/tmp" -type f | wc -l)" 0
    check "token not printed" lacks "$OUT" "$TOKEN"
}

test_laptop_without_token_skips_the_installer() {
    fake_node_agent_installer
    mkdir -p "$T/tmp"
    EXTRA_ENV=(FAKE_TOKEN="")
    laptop_install
    EXTRA_ENV=()
    # printf "%s\n" gives a bare newline, which command substitution strips to empty.
    check "exits 0" equals "$RC" 0
    check "warns" contains "$OUT" 'Could not fetch API token'
    check "installer not called" no_file "$T/installer-argv"
    check "no temp file" equals "$(find "$T/tmp" -type f | wc -l)" 0
}

test_laptop_exit_trap_removes_the_token_file() {
    check "main's trap covers the temp file" grep -q 'trap .*rm -f .*NODE_AGENT_TOKEN_TMP' "$REPO/scripts/setup/setup-laptop.sh"
    check "old flag gone" lacks "$REPO/scripts/setup/setup-laptop.sh" '--api-token "'
}

bootstrap_install() {
    sed -n '/^install_control_plane_node_agent() {/,/^}/p' "$REPO/scripts/installation/bootstrap-control-plane.sh" |
        sed -e "s#/etc/mynodeone#$T/etc-mynodeone#g" >"$T/fn.sh"
    check "function extracted, no real /etc path left" lacks "$T/fn.sh" '/etc/mynodeone/'
    run bash -c 'set -e
        log_info() { :; }; log_success() { echo "OK: $1"; }; log_warn() { echo "WARN: $1"; }
        PROJECT_ROOT="$1"; NODE_NAME=control1; TAILSCALE_IP=100.64.0.9
        source "$2"; install_control_plane_node_agent' _ "$T/project" "$T/fn.sh"
}

test_bootstrap_token_goes_through_its_file() {
    fake_node_agent_installer
    mkdir -p "$T/etc-mynodeone"
    printf '%s\n' "$TOKEN" >"$T/etc-mynodeone/api-token"
    chmod 600 "$T/etc-mynodeone/api-token"
    bootstrap_install
    check "exits 0" equals "$RC" 0
    check "points at the root-only file" contains "$T/installer-argv" "--api-token-file $T/etc-mynodeone/api-token"
    check "token not in argv" lacks "$T/installer-argv" "$TOKEN"
    check "file stays, the config API needs it" contains "$T/etc-mynodeone/api-token" "$TOKEN"
}

test_bootstrap_without_token_file_leaves_it_to_the_installer() {
    fake_node_agent_installer
    bootstrap_install
    check "exits 0" equals "$RC" 0
    check "installer called" contains "$T/installer-argv" '--node-type'
    check "no token flag at all" lacks "$T/installer-argv" '--api-token'
}

###############################################################################
# Runner
###############################################################################

# Only a user who can write /etc/hosts could change it here, and on a real control
# plane the DNS timer legitimately rewrites it during the run.
###############################################################################
# /etc/hosts growth. The old sync-dns.sh added a blank line and a backup on every
# run, which on one host came to 232,000 lines and 25 GiB of backups.
###############################################################################

# The script under test. Set this to run these tests against another copy of it.
SYNC_DNS="${SYNC_DNS_SCRIPT:-$REPO/scripts/domains/sync-dns.sh}"

sync_setup() {
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"a/good":{"ip":"100.64.1.5","local_name":"good"},"a/dash":{"ip":"100.64.1.6","local_name":"dashboard"}}'
}
hosts_backups() { find "$T" -maxdepth 1 -name 'hosts.backup.*' | wc -l; }
nul_bytes() { tr -cd '\000' <"$1" | wc -c; }
longest_blank_run() { awk 'NF { run = 0; next } { if (++run > most) most = run } END { print most + 0 }' "$1"; }
non_blank_lines() { awk 'NF' "$1"; }
blanks() { yes '' | head -n "$1"; }

# The shape the old script left on a real host: exactly 232,000 blank lines, a line of
# NUL bytes from two writers overlapping, and other tools' lines among them.
runaway_hosts() {
    {
        printf '127.0.0.1\tlocalhost\n127.0.1.1\tbox\n\n# IPv6 hosts\n::1 ip6-localhost ip6-loopback\n'
        blanks 100000
        printf '# MyNodeOne services\n# Note: MinIO uses node-specific domains\n# End MyNodeOne services\n'
        blanks 50000
        head -c 562 /dev/zero
        echo
        blanks 30000
        printf '172.18.0.3 other-app-inference\n10.1.1.1 nas.home\n'
        blanks 51998
        printf '# MyNodeOne Services - Auto-synced old\n100.64.1.9\told.testcluster.local\n\n'
    } >"$T/hosts"
    cat >"$T/kept" <<'EOF'
127.0.0.1	localhost
127.0.1.1	box
# IPv6 hosts
::1 ip6-localhost ip6-loopback
# MyNodeOne services
# Note: MinIO uses node-specific domains
# End MyNodeOne services
172.18.0.3 other-app-inference
10.1.1.1 nas.home
EOF
}

test_hosts_growth_collapses_232000_blank_lines() {
    sync_setup
    runaway_hosts
    check "fixture has 232,000 blank lines" equals "$(tr -d '\000' <"$T/hosts" | awk '!NF' | wc -l)" 232001
    cp "$T/hosts" "$T/original"
    local inode
    inode=$(stat -c %i "$T/hosts")

    run bash "$SYNC_DNS" --quiet
    check "exits 0" equals "$RC" 0
    non_blank_lines "$T/hosts" | head -n "$(wc -l <"$T/kept")" >"$T/first-lines"
    check "every other line kept, in order" same_file "$T/kept" "$T/first-lines"
    check "blank runs collapsed" equals "$(longest_blank_run "$T/hosts")" 1
    check "file is small again" equals "$(($(wc -l <"$T/hosts") < 30))" 1
    check "NUL bytes gone" equals "$(nul_bytes "$T/hosts")" 0
    check "stale block replaced" lacks "$T/hosts" 'old.testcluster.local'
    check "new entries written" contains "$T/hosts" 'good.testcluster.local'
    check "one backup" equals "$(hosts_backups)" 1
    check "the backup is the original" same_file "$T/original" "$(find "$T" -maxdepth 1 -name 'hosts.backup.*')"
    check "same inode, so a bind mount survives" equals "$(stat -c %i "$T/hosts")" "$inode"

    cp "$T/hosts" "$T/after-first"
    sleep 1 # backup names only have whole seconds, so a second one could hide in the first
    run bash "$SYNC_DNS" --quiet
    check "second run exits 0" equals "$RC" 0
    check "second run is byte-identical" same_file "$T/after-first" "$T/hosts"
    check "no second backup" equals "$(hosts_backups)" 1
}

test_hosts_growth_normalises_with_no_dns_change() {
    sync_setup
    printf '127.0.0.1 localhost\n\n# a comment\n10.1.1.1 nas.home\n' >"$T/hosts"
    run bash "$SYNC_DNS" --quiet
    cp "$T/hosts" "$T/settled"
    local before
    before=$(hosts_backups)
    sleep 1 # backup names only have whole seconds
    { sed -n 1p "$T/settled"; blanks 5000; sed -n '2,$p' "$T/settled"; blanks 5000; } >"$T/grown"
    cat "$T/grown" >"$T/hosts"
    run bash "$SYNC_DNS" --quiet
    check "exits 0" equals "$RC" 0
    # The write updates the block's timestamp, and nothing else.
    check "back to the same lines" same_file <(grep -v '# MyNodeOne Services' "$T/settled") <(grep -v '# MyNodeOne Services' "$T/hosts")
    check "one backup for the change" equals "$(hosts_backups)" "$((before + 1))"
    run bash "$SYNC_DNS" --quiet
    check "then settled" contains "$OUT" 'already up to date'
    check "no further backup" equals "$(hosts_backups)" "$((before + 1))"
}

test_hosts_growth_nul_bytes_do_not_hide_a_dns_change() {
    sync_setup
    { printf '127.0.0.1 localhost\n'; head -c 562 /dev/zero; printf '\n# MyNodeOne Services - old\n100.64.1.99\tgood.testcluster.local\n'; } >"$T/hosts"
    run bash "$SYNC_DNS" --quiet
    check "exits 0" equals "$RC" 0
    check "new address written" grep -qP '^100\.64\.1\.5\tgood\.testcluster\.local$' "$T/hosts"
    check "old address gone" lacks "$T/hosts" '100.64.1.99'
    check "NUL bytes gone" equals "$(nul_bytes "$T/hosts")" 0
}

test_hosts_growth_keeps_lines_touching_the_block() {
    sync_setup
    printf '127.0.0.1 localhost\n# MyNodeOne Services - old\n100.64.1.99\told.testcluster.local\n10.1.1.1 nas.home\n# my note\n' >"$T/hosts"
    run bash "$SYNC_DNS" --quiet
    check "stale entry gone" lacks "$T/hosts" 'old.testcluster.local'
    check "host below the block kept" contains "$T/hosts" '10.1.1.1 nas.home'
    check "comment below the block kept" contains "$T/hosts" '# my note'
    check "line above the block kept" contains "$T/hosts" '127.0.0.1 localhost'
}

test_hosts_growth_prune_keeps_newest_and_oldest() {
    sync_setup
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    local i
    for i in $(seq -w 1 20); do
        touch -d "2026-01-$i 00:00:00" "$T/hosts.backup.202601${i}_000000"
    done
    touch "$T/hosts.backup.foo" "$T/hosts.backup.1_2x" "$T/hosts.backup.123" "$T/hosts.bak.1"
    mv "$T/bin/sudo" "$T/bin/real-sudo"
    # shellcheck disable=SC2016  # expanded by the stub
    printf '#!/bin/bash\necho "$*" >>"$FAKE_K8S/sudo.log"\nexec "$(dirname "$0")/real-sudo" "$@"\n' >"$T/bin/sudo"
    chmod +x "$T/bin/sudo"

    run bash "$SYNC_DNS" --quiet
    check "exits 0" equals "$RC" 0
    check "newest five and the oldest remain" equals \
        "$(find "$T" -maxdepth 1 -name 'hosts.backup.[0-9]*_[0-9]*' ! -name '*x' | wc -l)" 6
    check "oldest kept" test -e "$T/hosts.backup.20260101_000000"
    check "newest old one kept" test -e "$T/hosts.backup.20260120_000000"
    check "fifth newest gone" no_file "$T/hosts.backup.20260116_000000"
    check "second oldest gone" no_file "$T/hosts.backup.20260102_000000"
    check "other names left alone" test -e "$T/hosts.backup.foo" -a -e "$T/hosts.backup.1_2x" -a -e "$T/hosts.backup.123" -a -e "$T/hosts.bak.1"
    check "rm ran once, not per file" equals "$(grep -c '^rm ' "$T/k8s/sudo.log")" 1
}

test_hosts_growth_agent_host_is_left_to_the_agent() {
    sync_setup
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    touch "$T/systemd/agent-active"
    run bash "$SYNC_DNS"
    check "exits 0, as an installer's call must" equals "$RC" 0
    check "hosts untouched" same_file "$T/before" "$T/hosts"
    check "no backup" equals "$(hosts_backups)" 0
    check "says why" contains "$OUT" 'node agent manages'
}

test_hosts_growth_timer_runs_are_let_through() {
    sync_setup
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    touch "$T/systemd/timer-active" "$T/systemd/agent-active"
    run bash "$SYNC_DNS" --quiet
    check "exits 0" equals "$RC" 0
    check "timer's run writes" contains "$T/hosts" 'good.testcluster.local'

    printf '127.0.0.1 localhost\n' >"$T/hosts"
    rm "$T/systemd/timer-active" "$T/systemd/agent-active"
    run bash "$SYNC_DNS" --quiet
    check "no writer at all: a direct run writes" contains "$T/hosts" 'good.testcluster.local'
}

test_hosts_growth_refresh_does_not_recurse() {
    sync_setup
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    touch "$T/systemd/agent-active"
    run timeout 30 bash -c 'source "$REGISTRY_LIB"; sr_refresh_hosts'
    check "agent host defers" equals "$(cat "$OUT")" deferred
    check "agent host: hosts untouched" same_file "$T/before" "$T/hosts"
    rm "$T/systemd/agent-active"
    touch "$T/systemd/timer-active"
    run timeout 30 bash -c 'source "$REGISTRY_LIB"; sr_refresh_hosts'
    check "timer host hands over to the unit" contains "$T/systemd/calls.log" 'start mynodeone-local-dns-sync.service'
    check "timer host: hosts untouched here" same_file "$T/before" "$T/hosts"
    rm "$T/systemd/timer-active"
    run timeout 30 bash -c 'source "$REGISTRY_LIB"; sr_refresh_hosts'
    EXTRA_ENV=()
    check "neither: returns" equals "$(cat "$OUT")" updated
    check "neither: writes" contains "$T/hosts" 'good.testcluster.local'
    check "sync-dns doesn't call the refresh helper" bash -c '! grep -v "^ *#" "$1" | grep -q sr_refresh_hosts' _ "$REPO/scripts/domains/sync-dns.sh"
}

test_hosts_growth_node_agent_writer_is_stable() {
    write_agent_env laptop
    { printf '127.0.0.1 localhost\n'; blanks 300; printf '10.1.1.1 nas.home\n'; blanks 300; } >"$T/hosts"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    cp "$T/hosts" "$T/first"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "same config: byte-identical" same_file "$T/first" "$T/hosts"
    local i lines
    lines=$(wc -l <"$T/hosts")
    for i in 6 7 8 9; do
        api /api/v1/config/laptop 200 '{"version":"v'"$i"'","dns_entries":[{"name":"chat","ip":"100.64.1.'"$i"'"}]}'
        run bash "$REPO/scripts/lib/node-agent.sh" sync
        check "entry $i written" contains "$T/hosts" "100.64.1.$i"
        check "no growth on change $i" equals "$(wc -l <"$T/hosts")" "$lines"
    done
    check "one backup, not one per write" equals "$(find "$T" -maxdepth 1 -name 'hosts.*' ! -name 'hosts.bak' | wc -l)" 0
    check "other lines kept" contains "$T/hosts" 'nas.home'
}

###############################################################################
# The other /etc/hosts writers: run by hand or an installer, not on a timer.
###############################################################################

# Lifts one function out of a script, pointed at the test's hosts file.
hosts_function() {
    sed -n "/^$2() {/,/^}/p" "$REPO/$1" | sed "s#/etc/hosts#$T/hosts#g" >"$T/fn.sh"
    ! grep -q '/etc/' "$T/fn.sh"
}

LOG_FUNCTIONS='log_info() { :; }; log_warn() { :; }; log_success() { :; }; print_header() { :; }'

# Three runs in a row must settle: same bytes, and no backup beyond the first two.
hosts_writer_settles() {
    local description="$1" size backups
    shift
    printf '127.0.0.1 localhost\n10.1.1.1 nas.home\n' >"$T/hosts"
    run "$@"
    check "$description: exits 0" equals "$RC" 0
    check "$description: user lines kept" contains "$T/hosts" 'nas.home'
    check "$description: entries written" contains "$T/hosts" '# MyNodeOne services'
    cp "$T/hosts" "$T/first"
    run "$@"
    backups=$(find "$T" -maxdepth 1 -name 'hosts.bak.*' | wc -l)
    size=$(wc -l <"$T/hosts")
    check "$description: second run adds nothing" same_file "$T/first" "$T/hosts"
    sleep 1 # the backup names only have whole seconds
    run "$@"
    run "$@"
    check "$description: no blank line per run" equals "$(wc -l <"$T/hosts")" "$size"
    check "$description: no backup per run" equals "$(find "$T" -maxdepth 1 -name 'hosts.bak.*' | wc -l)" "$backups"
    check "$description: at most two backups" equals "$((backups <= 2))" 1
}

test_hosts_writer_update_laptop_dns_settles() {
    check "function found" hosts_function scripts/domains/update-laptop-dns.sh update_hosts_file
    hosts_writer_settles update-laptop-dns bash -c "set -euo pipefail; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; DNS_ENTRIES="100.64.1.5 a.test.local"; source "$1"; update_hosts_file' _ "$T/fn.sh"
}

test_hosts_writer_management_laptop_settles() {
    check "function found" hosts_function scripts/setup/setup-management-laptop.sh update_dns_entries
    jq -n '{items: [{metadata: {name: "demo", namespace: "default"}, spec: {type: "LoadBalancer"}, status: {loadBalancer: {ingress: [{ip: "100.64.1.5"}]}}}]}' >"$T/k8s/svcs.json"
    hosts_writer_settles setup-management-laptop bash -c "set -euo pipefail; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; CLUSTER_DOMAIN=test; source "$1"; update_dns_entries' _ "$T/fn.sh"
}

test_hosts_writer_setup_local_dns_settles() {
    check "function found" hosts_function scripts/setup/setup-local-dns.sh update_hosts_file
    hosts_writer_settles setup-local-dns bash -c "set -e; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; CLUSTER_DOMAIN=test; source "$1"; update_hosts_file' _ "$T/fn.sh"
}

test_hosts_writer_client_script_settles() {
    sed -n "/<<'SCRIPT_EOF'\$/,/^SCRIPT_EOF\$/p" "$REPO/scripts/setup/setup-local-dns.sh" | sed '1d;$d' |
        sed "s#/etc/hosts#$T/hosts#g" >"$T/client.sh"
    hosts_writer_settles setup-client-dns bash "$T/client.sh"
}

###############################################################################
# Domain registry: lookalike domains, conditional writes, failed reads.
###############################################################################

domains_json() { jq -r '.data["domains.json"]' "$T/k8s/cm/domain-registry.json"; }

DOMAIN_SEED='{"domains":{"example.com":{},"gone.com":{}},"vps_nodes":[{"tailscale_ip":"100.64.1.1","public_ip":"192.0.2.1"}]}'

test_remove_domain_leaves_lookalike_domains() {
    set_cm service-registry services.json '{}'
    set_cm domain-registry domains.json '{"domains":{"example.com":{},"notexample.com":{}},"vps_nodes":[]}'
    set_cm domain-registry routing.json '{"both":{"expose":["example.com","api.example.com","api.notexample.com"],"vps_nodes":[]},"svc-other":{"expose":["notexample.com"],"vps_nodes":[]}}'
    run bash -c 'echo yes | bash "$1" example.com' _ "$REPO/scripts/domains/remove-domain.sh"
    check "exits 0" equals "$RC" 0
    check "the domain's own URLs gone, the lookalike's kept" equals "$(routing_json | jq -r '.both.expose | join(",")')" api.notexample.com
    check "lookalike's service untouched" equals "$(routing_json | jq -r '."svc-other".expose | join(",")')" notexample.com
    check "lookalike's service not listed" lacks "$OUT" 'svc-other'
    check "domain unregistered" equals "$(domains_json | jq -c '.domains | keys')" '["notexample.com"]'
}

# Another writer gets in first. The operation must land, and so must the other change.
domain_op_races() {
    local description="$1" applied="$2"
    shift 2
    set_cm domain-registry domains.json "$DOMAIN_SEED"
    rm -f "$T/k8s/patches.log"
    jq -cn --arg v "$(jq -c '.domains["other.com"] = {} | .vps_nodes += [{tailscale_ip: "100.64.9.9"}]' <<<"$DOMAIN_SEED")" \
        '{"domains.json":$v}' >"$T/k8s/race-domain-registry"
    domain_call "$@"
    check "$description: exits 0" equals "$RC" 0
    check "$description: the race fired" no_file "$T/k8s/race-domain-registry"
    check "$description: applied" jq -e "$applied" <<<"$(domains_json)"
    check "$description: other writer's change kept" jq -e '.domains["other.com"] and any(.vps_nodes[]; .tailscale_ip == "100.64.9.9")' <<<"$(domains_json)"
    check "$description: one write landed" equals "$(grep -c '"resourceVersion"' "$T/k8s/patches.log")" 1
    check "$description: write is conditional" grep -q resourceVersion "$T/k8s/patches.log"
}

test_domain_registry_writes_survive_a_conflict() {
    domain_op_races register_domain '.domains["new.com"].status == "active" and .domains["example.com"]' register_domain new.com "a description"
    domain_op_races unregister_domain '(.domains | has("gone.com") | not) and .domains["example.com"]' unregister_domain gone.com
    domain_op_races register_vps 'any(.vps_nodes[]; .tailscale_ip == "100.64.1.2" and .public_ip == "192.0.2.2" and .location == "eu")' register_vps 100.64.1.2 192.0.2.2 eu contabo
    domain_op_races unregister_vps 'all(.vps_nodes[]; .tailscale_ip != "100.64.1.1")' unregister_vps 100.64.1.1
}

# The bug: a failed read became an empty registry, and the write then replaced the real one.
domain_op_read_fails() {
    local description="$1"
    shift
    set_cm domain-registry domains.json "$DOMAIN_SEED"
    set_cm domain-registry routing.json '{}'
    cp "$T/k8s/cm/domain-registry.json" "$T/before"
    rm -f "$T/k8s/patches.log"
    touch "$T/k8s/fail-get-configmap"
    domain_call "$@"
    rm "$T/k8s/fail-get-configmap"
    check "$description: reports failure" differs "$RC" 0
    check "$description: no write" no_file "$T/k8s/patches.log"
    check "$description: registry unchanged" same_file "$T/before" "$T/k8s/cm/domain-registry.json"
}

test_domain_registry_failed_read_changes_nothing() {
    domain_op_read_fails register_domain register_domain new.com
    domain_op_read_fails unregister_domain unregister_domain example.com
    domain_op_read_fails register_vps register_vps 100.64.1.2 192.0.2.2 eu
    domain_op_read_fails unregister_vps unregister_vps 100.64.1.1
}

# The way this really happens: the existence check passes, then the read fails.
test_domain_registry_read_failing_after_init_changes_nothing() {
    mv "$T/bin/kubectl" "$T/bin/real-kubectl"
    cat >"$T/bin/kubectl" <<'EOF'
#!/bin/bash
if [[ "$1 $2" == "get configmap" && "$*" == *" -o "* && "$*" != *" -o name"* ]]; then
    echo "The connection to the server localhost:6443 was refused" >&2
    exit 1
fi
exec "$(dirname "$0")/real-kubectl" "$@"
EOF
    chmod +x "$T/bin/kubectl"
    set_cm domain-registry domains.json "$DOMAIN_SEED"
    cp "$T/k8s/cm/domain-registry.json" "$T/before"
    domain_call register_domain new.com
    check "domain: reports failure" differs "$RC" 0
    check "domain: registry unchanged" same_file "$T/before" "$T/k8s/cm/domain-registry.json"
    domain_call register_vps 100.64.1.2 192.0.2.2 eu
    check "VPS: reports failure" differs "$RC" 0
    check "VPS: registry unchanged" same_file "$T/before" "$T/k8s/cm/domain-registry.json"
    check "no write" no_file "$T/k8s/patches.log"
}

test_domain_registry_failed_write_is_an_error() {
    set_cm domain-registry domains.json "$DOMAIN_SEED"
    touch "$T/k8s/fail-patch-configmap"
    domain_call register_domain new.com
    check "reports failure" differs "$RC" 0
    check "no success message" lacks "$OUT" 'Domain registered'
}

test_domain_registry_register_on_nothing() {
    domain_call register_domain new.com
    check "creates the registry and registers" equals "$RC" 0
    check "domain there" jq -e '.domains["new.com"]' <<<"$(domains_json)"
    check "both keys created" jq -e '.data | has("routing.json")' "$T/k8s/cm/domain-registry.json"

    set_cm domain-registry domains.json ''
    domain_call register_vps 100.64.1.2 192.0.2.2 eu
    check "blank key: exits 0" equals "$RC" 0
    check "blank key: VPS there" jq -e '.vps_nodes[0].tailscale_ip == "100.64.1.2" and .domains == {}' <<<"$(domains_json)"
}

test_domain_registry_unregister_missing_is_harmless() {
    set_cm domain-registry domains.json "$DOMAIN_SEED"
    domain_call unregister_domain nosuch.com
    check "unknown domain: exits 0" equals "$RC" 0
    check "unknown domain: says so" contains "$OUT" 'not found'
    domain_call unregister_vps 100.64.9.1
    check "unknown VPS: exits 0" equals "$RC" 0
    check "no write" no_file "$T/k8s/patches.log"
    rm "$T/k8s/cm/domain-registry.json"
    domain_call unregister_domain nosuch.com
    check "no registry: exits 0" equals "$RC" 0
    check "no registry: nothing created" no_file "$T/k8s/cm/domain-registry.json"
}

test_domain_registry_handles_old_shape_and_awkward_values() {
    set_cm domain-registry domains.json '{"old.com":{},"keep.com":{}}'
    domain_call unregister_domain old.com
    check "flat registry: exits 0" equals "$RC" 0
    check "flat registry: removed" equals "$(domains_json | jq -c 'keys')" '["keep.com"]'

    set_cm domain-registry domains.json "$DOMAIN_SEED"
    domain_call register_domain new.com 'has "quotes" and \ a backslash'
    check "awkward description: exits 0" equals "$RC" 0
    check "awkward description: intact" equals "$(domains_json | jq -r '.domains["new.com"].description')" 'has "quotes" and \ a backslash'
}

###############################################################################
# unregister-vps.sh: conditional writes on all three keys, and failures are failures.
###############################################################################

VPS_GONE="100.64.1.1"
VPS_DOMAINS='{"domains":{"example.com":{"status":"active"}},"vps_nodes":[{"tailscale_ip":"100.64.1.1","public_ip":"192.0.2.1"},{"tailscale_ip":"100.64.1.2","public_ip":"192.0.2.2"}]}'
VPS_ROUTING='{"svc-a":{"expose":["a.example.com"],"vps_nodes":["100.64.1.1","100.64.1.2"],"strategy":"round-robin"},"svc-b":{"expose":["b.example.com"],"vps_nodes":["100.64.1.2"]},"svc-c":{"expose":["c.example.com"]}}'
VPS_SYNC='{"vps_nodes":[{"name":"gone","ip":"100.64.1.1","tailscale_ip":"100.64.1.1"},{"name":"gone-too","tailscale_ip":"100.64.1.1"},{"name":"stays","ip":"100.64.1.2","tailscale_ip":"100.64.1.2"}],"worker_nodes":[{"name":"w1","ip":"100.64.1.9"}],"metadata":{"version":"1"}}'
VPS_MESSAGE='has been unregistered'

vps_seed() {
    set_cm domain-registry domains.json "$VPS_DOMAINS"
    set_cm domain-registry routing.json "$VPS_ROUTING"
    set_cm domain-registry other.json 'kept'
    set_cm sync-controller-registry registry.json "$VPS_SYNC"
    set_cm sync-controller-registry other.json 'kept'
    printf '{}' >"$T/home/.mynodeone/node-registry.json"
}

# The stub has no cluster-info, which is how the script spots direct access. FAIL_READ=<n>
# makes the nth read of a ConfigMap's contents fail, as a brief API outage would.
vps_direct_kubectl() {
    mv "$T/bin/kubectl" "$T/bin/real-kubectl"
    cat >"$T/bin/kubectl" <<'EOF'
#!/bin/bash
[[ "$1" == cluster-info ]] && exit 0
if [[ -n "${FAIL_READ:-}" && "$1 $2" == "get configmap" && "$*" == *" -o "* && "$*" != *" -o name"* ]]; then
    count=$(($(cat "$FAKE_K8S/read-count" 2>/dev/null || echo 0) + 1))
    echo "$count" >"$FAKE_K8S/read-count"
    if ((count == FAIL_READ)); then
        echo "The connection to the server localhost:6443 was refused" >&2
        exit 1
    fi
fi
exec "$(dirname "$0")/real-kubectl" "$@"
EOF
    chmod +x "$T/bin/kubectl"
}

vps_unregister() {
    run bash -c 'echo y | bash "$1" "$2"' _ "$REPO/scripts/nodes/unregister-vps.sh" "${1:-$VPS_GONE}"
}

sync_registry_json() { jq -r '.data["registry.json"]' "$T/k8s/cm/sync-controller-registry.json"; }

vps_is_gone_from_all_three() {
    check "$1: gone from the VPS list" jq -e --arg ip "$VPS_GONE" 'all(.vps_nodes[]; .tailscale_ip != $ip)' <<<"$(domains_json)"
    check "$1: gone from routes" jq -e --arg ip "$VPS_GONE" 'all(.[]; (.vps_nodes // []) | index($ip) | not)' <<<"$(routing_json)"
    check "$1: gone from sync targets" jq -e --arg ip "$VPS_GONE" 'all(.vps_nodes[]; .ip != $ip and .tailscale_ip != $ip)' <<<"$(sync_registry_json)"
}

vps_others_survive() {
    check "$1: other VPS kept in the list" jq -e 'any(.vps_nodes[]; .tailscale_ip == "100.64.1.2" and .public_ip == "192.0.2.2")' <<<"$(domains_json)"
    check "$1: domains kept" jq -e '.domains["example.com"].status == "active"' <<<"$(domains_json)"
    check "$1: other VPS kept in a shared route" jq -e '.["svc-a"].vps_nodes | index("100.64.1.2")' <<<"$(routing_json)"
    check "$1: route settings kept" jq -e '.["svc-a"].strategy == "round-robin" and .["svc-a"].expose == ["a.example.com"]' <<<"$(routing_json)"
    check "$1: other route untouched" jq -e '.["svc-b"] == {expose: ["b.example.com"], vps_nodes: ["100.64.1.2"]}' <<<"$(routing_json)"
    check "$1: route with no VPS list untouched" jq -e '.["svc-c"] == {expose: ["c.example.com"]}' <<<"$(routing_json)"
    check "$1: other sync target kept" jq -e 'any(.vps_nodes[]; .name == "stays")' <<<"$(sync_registry_json)"
    check "$1: other sync sections kept" jq -e '.worker_nodes[0].name == "w1" and .metadata.version == "1"' <<<"$(sync_registry_json)"
    check "$1: other key on domain-registry kept" jq -e '.data["other.json"] == "kept"' "$T/k8s/cm/domain-registry.json"
    check "$1: other key on sync registry kept" jq -e '.data["other.json"] == "kept"' "$T/k8s/cm/sync-controller-registry.json"
}

test_unregister_vps_removes_it_and_keeps_the_rest() {
    vps_direct_kubectl
    vps_seed
    vps_unregister
    check "exits 0" equals "$RC" 0
    check "says so" contains "$OUT" "$VPS_MESSAGE"
    vps_is_gone_from_all_three "first VPS"
    vps_others_survive "first VPS"
    check "local cache cleaned" no_file "$T/home/.mynodeone/node-registry.json"
    check "no apply, which can drop keys" lacks "$T/k8s/calls.log" 'apply'
    check "every write is conditional" jq -se 'length == 3 and all(.metadata.resourceVersion | length > 0)' "$T/k8s/patches.log"

    # What the old script lost on its second run: routing.json.
    vps_unregister "100.64.1.2"
    check "second VPS: exits 0" equals "$RC" 0
    check "second VPS: every route is still there" jq -e 'keys == ["svc-a", "svc-b", "svc-c"]' <<<"$(routing_json)"
    check "second VPS: its routes emptied" jq -e '.["svc-a"].vps_nodes == [] and .["svc-b"].vps_nodes == []' <<<"$(routing_json)"
    check "second VPS: domains kept" jq -e '.domains["example.com"]' <<<"$(domains_json)"

    rm -f "$T/k8s/patches.log"
    vps_unregister "100.64.1.2"
    check "unknown VPS: exits 0" equals "$RC" 0
    check "unknown VPS: no write" no_file "$T/k8s/patches.log"
}

vps_read_fails_changes_nothing() {
    local description="$1"
    check "$description: reports failure" differs "$RC" 0
    check "$description: no false success" lacks "$OUT" "$VPS_MESSAGE"
    check "$description: no write" no_file "$T/k8s/patches.log"
    check "$description: domain registry unchanged" same_file "$T/before-domain" "$T/k8s/cm/domain-registry.json"
    check "$description: sync registry unchanged" same_file "$T/before-sync" "$T/k8s/cm/sync-controller-registry.json"
    check "$description: local cache kept" test -e "$T/home/.mynodeone/node-registry.json"
}

test_unregister_vps_failed_read_changes_nothing() {
    vps_direct_kubectl
    vps_seed
    cp "$T/k8s/cm/domain-registry.json" "$T/before-domain"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before-sync"

    touch "$T/k8s/fail-get-configmap"
    vps_unregister
    rm "$T/k8s/fail-get-configmap"
    vps_read_fails_changes_nothing "every read fails"

    local n
    for n in 1 2 3; do
        rm -f "$T/k8s/read-count"
        EXTRA_ENV=(FAIL_READ="$n")
        vps_unregister
        EXTRA_ENV=()
        vps_read_fails_changes_nothing "read $n fails"
    done
}

# Past the first look, a failed read can leave earlier keys done, but never harms one,
# and a second run finishes the job.
test_unregister_vps_later_failed_read_loses_nothing() {
    vps_direct_kubectl
    local n
    for n in 4 5 6 7 8 9; do
        rm -f "$T/k8s/read-count" "$T/k8s/patches.log"
        vps_seed
        EXTRA_ENV=(FAIL_READ="$n")
        vps_unregister
        EXTRA_ENV=()
        check "read $n: reports failure" differs "$RC" 0
        check "read $n: no false success" lacks "$OUT" "$VPS_MESSAGE"
        vps_others_survive "read $n"
        vps_unregister
        check "read $n: second run exits 0" equals "$RC" 0
        vps_is_gone_from_all_three "read $n, second run"
        vps_others_survive "read $n, second run"
    done
}

test_unregister_vps_bad_data_changes_nothing() {
    vps_direct_kubectl
    vps_seed
    set_cm domain-registry routing.json 'not json'
    cp "$T/k8s/cm/domain-registry.json" "$T/before-domain"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before-sync"
    vps_unregister
    vps_read_fails_changes_nothing "routing.json is not JSON"
}

test_unregister_vps_write_failure_is_an_error() {
    vps_direct_kubectl
    vps_seed
    touch "$T/k8s/fail-patch-configmap"
    vps_unregister
    check "reports failure" differs "$RC" 0
    check "no false success" lacks "$OUT" "$VPS_MESSAGE"
}

# Another writer gets in first on each key. Its change and ours must both land.
test_unregister_vps_conflict_retries() {
    vps_direct_kubectl

    vps_seed
    jq -cn --arg v "$(jq -c '.domains["other.com"] = {} | .vps_nodes += [{tailscale_ip: "100.64.9.9"}]' <<<"$VPS_DOMAINS")" \
        '{"domains.json":$v}' >"$T/k8s/race-domain-registry"
    vps_unregister
    check "domains: exits 0" equals "$RC" 0
    check "domains: the race fired" no_file "$T/k8s/race-domain-registry"
    check "domains: said it retried" contains "$OUT" 'retrying'
    vps_is_gone_from_all_three "domains"
    vps_others_survive "domains"
    check "domains: other writer kept" jq -e '.domains["other.com"] and any(.vps_nodes[]; .tailscale_ip == "100.64.9.9")' <<<"$(domains_json)"

    # With the VPS already off the list, the routing write is the first to race.
    vps_seed
    set_cm domain-registry domains.json '{"domains":{"example.com":{"status":"active"}},"vps_nodes":[{"tailscale_ip":"100.64.1.2","public_ip":"192.0.2.2"}]}'
    jq -cn --arg v "$(jq -c '.["svc-new"] = {expose: ["n.example.com"], vps_nodes: ["100.64.1.1", "100.64.1.2"]}' <<<"$VPS_ROUTING")" \
        '{"routing.json":$v}' >"$T/k8s/race-domain-registry"
    vps_unregister
    check "routing: exits 0" equals "$RC" 0
    check "routing: the race fired" no_file "$T/k8s/race-domain-registry"
    vps_is_gone_from_all_three "routing"
    vps_others_survive "routing"
    check "routing: other writer kept, and cleaned too" jq -e '.["svc-new"].vps_nodes == ["100.64.1.2"]' <<<"$(routing_json)"

    vps_seed
    jq -cn --arg v "$(jq -c '.vps_nodes += [{name: "new", ip: "100.64.9.9"}]' <<<"$VPS_SYNC")" \
        '{"registry.json":$v}' >"$T/k8s/race-sync-controller-registry"
    vps_unregister
    check "sync: exits 0" equals "$RC" 0
    check "sync: the race fired" no_file "$T/k8s/race-sync-controller-registry"
    vps_is_gone_from_all_three "sync"
    vps_others_survive "sync"
    check "sync: other writer kept" jq -e 'any(.vps_nodes[]; .name == "new")' <<<"$(sync_registry_json)"
}

test_unregister_vps_missing_pieces_are_fine() {
    vps_direct_kubectl
    vps_unregister
    check "no registries: exits 0" equals "$RC" 0
    check "no registries: nothing created" no_file "$T/k8s/cm/domain-registry.json"
    check "no registries: nothing created (sync)" no_file "$T/k8s/cm/sync-controller-registry.json"

    set_cm domain-registry domains.json "$VPS_DOMAINS"
    set_cm sync-controller-registry registry.json ''
    vps_unregister
    check "blank keys: exits 0" equals "$RC" 0
    check "blank keys: the list is still cleaned" jq -e 'all(.vps_nodes[]; .tailscale_ip != "100.64.1.1")' <<<"$(domains_json)"
    check "blank routing not written" jq -e '.data | has("routing.json") | not' "$T/k8s/cm/domain-registry.json"
    check "blank sync registry not written" equals "$(sync_registry_json)" ''
}

# Over SSH the stub runs the real command in a temp "control plane" whose checkout is
# this one.
vps_over_ssh() {
    printf 'CONTROL_PLANE_IP=100.64.0.9\nCONTROL_PLANE_SSH_USER=tester\n' >"$T/home/.mynodeone/config.env"
    ln -s "$REPO" "$T/vps/MyNodeOne"
}

test_unregister_vps_over_ssh() {
    vps_over_ssh
    vps_seed
    vps_unregister
    check "exits 0" equals "$RC" 0
    check "went over SSH" contains "$OUT" 'Using remote kubectl'
    check "says so" contains "$OUT" "$VPS_MESSAGE"
    vps_is_gone_from_all_three "SSH"
    vps_others_survive "SSH"
    check "writes are conditional" contains "$T/k8s/patches.log" 'resourceVersion'
    check "local cache cleaned" no_file "$T/home/.mynodeone/node-registry.json"
}

test_unregister_vps_over_ssh_failures_are_errors() {
    vps_over_ssh
    vps_seed
    cp "$T/k8s/cm/domain-registry.json" "$T/before-domain"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before-sync"

    touch "$T/ssh/down"
    vps_unregister
    rm "$T/ssh/down"
    vps_read_fails_changes_nothing "SSH down"
    check "SSH down: says what to run" contains "$OUT" 'multi-domain-registry.sh purge-vps 100.64.1.1'

    touch "$T/k8s/fail-get-configmap"
    vps_unregister
    rm "$T/k8s/fail-get-configmap"
    vps_read_fails_changes_nothing "read fails on the control plane"
}

# A control plane that hasn't been updated must fail, not half do the job and say it's done.
test_unregister_vps_over_ssh_to_an_old_checkout_changes_nothing() {
    old_commit_ready || return 0
    printf 'CONTROL_PLANE_IP=100.64.0.9\nCONTROL_PLANE_SSH_USER=tester\n' >"$T/home/.mynodeone/config.env"
    mkdir -p "$T/vps/MyNodeOne/scripts/domains"
    git -C "$REPO" archive "$OLD_COMMIT" scripts/domains/multi-domain-registry.sh scripts/lib | tar -x -C "$T/vps/MyNodeOne"
    vps_seed
    cp "$T/k8s/cm/domain-registry.json" "$T/before-domain"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before-sync"
    vps_unregister
    vps_read_fails_changes_nothing "old checkout"
    check "says to update it" contains "$OUT" 'older than this one'
}

###############################################################################
# validate-installation.sh runs every check and reports them all.
###############################################################################

validate_stubs() {
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    printf '#!/bin/bash\nexit %s\n' "$1" >"$T/bin/ping"
    chmod +x "$T/bin/ping"
}

test_validate_installation_runs_to_the_end() {
    local type_and_last type last
    validate_stubs 1
    touch "$T/k8s/fail-all"
    for type_and_last in "control-plane|Default storage class set" "management-laptop|Testing HTTP access" "vps-edge|Public IP"; do
        type="${type_and_last%%|*}"
        last="${type_and_last#*|}"
        run bash "$REPO/scripts/lib/validate-installation.sh" "$type"
        check "$type: reaches its last check" contains "$OUT" "$last"
        check "$type: prints the summary" contains "$OUT" 'Validation Summary'
    done
    run bash "$REPO/scripts/lib/validate-installation.sh" control-plane
    check "failures: exits non-zero" equals "$RC" 1
    check "more than one failure counted" grep -qE '[1-9][0-9]+ critical test' "$OUT"
}

test_validate_installation_warnings_do_not_fail() {
    # vps-edge passes with the stubs apart from ping, which is only a warning.
    validate_stubs 1
    printf '#!/bin/bash\nexit 0\n' >"$T/bin/systemctl"
    chmod +x "$T/bin/systemctl"
    run bash "$REPO/scripts/lib/validate-installation.sh" vps-edge
    check "exits 0" equals "$RC" 0
    check "the warning was counted, and the run went on" contains "$OUT" 'Public IP'
}

###############################################################################
# The config-sync installer takes its token from a file, so it stays out of ps.
###############################################################################

test_token_helper_passes_a_private_file() {
    cat >"$T/bin/see-args" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$FAKE_K8S/args"
shift 2
stat -c %a "$1" >"$FAKE_K8S/mode"
cp "$1" "$FAKE_K8S/token"
echo "$1" >"$FAKE_K8S/path"
exit "${SEE_ARGS_RC:-0}"
EOF
    chmod +x "$T/bin/see-args"
    local snippet='source "$HELPER"; trap "echo caller-trap-ran" EXIT; node_agent_run_with_token_file "$1" see-args plain-arg; echo "rc=$?"'
    EXTRA_ENV=(HELPER="$REPO/scripts/lib/node-agent-install.sh")
    run bash -c "$snippet" _ "$TOKEN"
    check "exits 0" equals "$RC" 0
    check "token not in the arguments" lacks "$T/k8s/args" "$TOKEN"
    check "argument order kept, option added" contains "$T/k8s/args" 'plain-arg --api-token-file '
    check "file is mode 600" equals "$(cat "$T/k8s/mode")" 600
    check "file holds the token" equals "$(cat "$T/k8s/token")" "$TOKEN"
    check "file removed" no_file "$(cat "$T/k8s/path")"
    check "caller's exit trap survives" contains "$OUT" 'caller-trap-ran'

    rm -f "$T/k8s/path"
    EXTRA_ENV=(HELPER="$REPO/scripts/lib/node-agent-install.sh" SEE_ARGS_RC=7)
    run bash -c "$snippet" _ "$TOKEN"
    check "failure comes back" contains "$OUT" 'rc=7'
    check "file removed after a failure" no_file "$(cat "$T/k8s/path")"

    EXTRA_ENV=(HELPER="$REPO/scripts/lib/node-agent-install.sh")
    run bash -c 'source "$HELPER"; node_agent_run_with_token_file "" echo plain-arg'
    EXTRA_ENV=()
    check "no token: no option" equals "$(cat "$OUT")" plain-arg
}

config_sync_main() {
    run bash -c 'source "$1"; shift; install_node_agent() { printf "%s|" "$@"; echo; }; main "$@"' _ "$REPO/scripts/lib/install-config-sync.sh" "$@"
}

test_config_sync_reads_token_file() {
    printf '%s\n' "$TOKEN" >"$T/token"
    chmod 600 "$T/token"
    config_sync_main laptop 100.64.0.9 "" node-a me --api-token-file "$T/token"
    check "exits 0" equals "$RC" 0
    check "token read, the rest in place" contains "$OUT" "laptop|100.64.0.9|$TOKEN|node-a|me|"
    check "no warning" lacks "$OUT" 'visible in ps'

    config_sync_main worker 100.64.0.9 --api-token-file "$T/token"
    check "short form" contains "$OUT" "worker|100.64.0.9|$TOKEN|"

    config_sync_main vps 100.64.0.9 "$TOKEN" node-a
    check "old form still works" contains "$OUT" "vps|100.64.0.9|$TOKEN|node-a|"
    check "and warns" contains "$OUT" 'visible in ps'

    config_sync_main laptop 100.64.0.9 --api-token-file "$T/no-such-file"
    check "missing file: fails" differs "$RC" 0
    check "missing file: no install" lacks "$OUT" 'laptop|'
}

test_config_sync_callers_keep_token_off_the_command_line() {
    local file
    for file in scripts/setup/setup-management-laptop.sh scripts/nodes/add-worker-node.sh scripts/setup/setup-vps-node.sh; do
        check "$file uses the file" contains "$REPO/$file" 'node_agent_run_with_token_file "$API_TOKEN"'
        check "$file passes no token" bash -c '! grep "install-config-sync.sh\" .*\"\$API_TOKEN\"" "$1"' _ "$REPO/$file"
    done
}

###############################################################################
# Registry names: a route has to survive the name it was published under.
###############################################################################

# What external-apps/scripts/deploy.sh leaves: the key is the app, the service isn't.
EXT_REGISTRY='{"myapp":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"local_name":"myapp","public":true}}'
EXT_ROUTING='{"myapp":{"expose":["app.example.com"],"vps_nodes":["100.64.1.1"]}}'
EXT_MIGRATED='{"myapp/myapp-web":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"local_name":"myapp","legacy_key":"myapp","public":true}}'

ext_cluster() {
    jq -n --argjson a "$(svc_item myapp myapp-web 100.64.1.7)" '{items: [$a]}' >"$T/k8s/svcs.json"
}

test_migration_files_external_app_route_under_its_new_key() {
    set_cm service-registry services.json "$EXT_REGISTRY"
    set_cm domain-registry routing.json "$EXT_ROUTING"
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    check "keeps the name it was published under" jq -e '.["myapp/myapp-web"].legacy_key == "myapp"' <<<"$(services_json)"
    check "still public" jq -e '.["myapp/myapp-web"].public == true' <<<"$(services_json)"
    check "route moved to the new key" jq -e '.["myapp/myapp-web"].expose == ["app.example.com"]' <<<"$(routing_json)"
    check "bare route gone" jq -e 'has("myapp") | not' <<<"$(routing_json)"
}

test_migration_prefers_the_name_that_has_a_route() {
    # Both old keys collapse to one entry, and the one sorting last has no route.
    set_cm service-registry services.json '{"myapp":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"public":true},"myapp-web":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"public":false}}'
    set_cm domain-registry routing.json "$EXT_ROUTING"
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    check "route's name kept" jq -e '.["myapp/myapp-web"].legacy_key == "myapp"' <<<"$(services_json)"
}

test_migration_prefers_a_name_differing_from_the_service() {
    set_cm service-registry services.json '{"myapp":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"public":true},"myapp-web":{"namespace":"myapp","service":"myapp-web","ip":"100.64.1.7","port":80,"public":false}}'
    set_cm domain-registry routing.json '{}'
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    check "the app's name kept" jq -e '.["myapp/myapp-web"].legacy_key == "myapp"' <<<"$(services_json)"
}

test_migration_routing_rewrite_survives_a_conflict() {
    set_cm service-registry services.json "$EXT_REGISTRY"
    set_cm domain-registry routing.json "$EXT_ROUTING"
    jq -cn --arg v '{"myapp":{"expose":["app.example.com"],"vps_nodes":["100.64.1.1"]},"other":{"expose":["o.example.com"]}}' \
        '{"routing.json":$v}' >"$T/k8s/race-domain-registry"
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    check "the race fired" no_file "$T/k8s/race-domain-registry"
    check "the other write survived" jq -e '.other.expose == ["o.example.com"]' <<<"$(routing_json)"
    check "route still moved" jq -e 'has("myapp/myapp-web") and (has("myapp") | not)' <<<"$(routing_json)"
}

test_migration_leaves_a_shared_record_bare() {
    # Two public services claim it, so the API publishes neither. Which one it was
    # meant for is a question for the operator.
    set_cm service-registry services.json '{"ns1/foo":{"namespace":"ns1","service":"foo","ip":"100.64.1.7","port":80,"legacy_key":"foo","public":true},"ns2/foo":{"namespace":"ns2","service":"foo","ip":"100.64.1.8","port":80,"legacy_key":"foo","public":true},"bar":{"namespace":"default","service":"bar","ip":"100.64.1.9","port":80,"public":false}}'
    set_cm domain-registry routing.json '{"foo":{"expose":["foo.example.com"]}}'
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "exits 0" equals "$RC" 0
    check "record stays bare" jq -e 'keys == ["foo"]' <<<"$(routing_json)"
}

test_sync_never_replaces_legacy_key() {
    set_cm service-registry services.json "$EXT_MIGRATED"
    set_cm domain-registry routing.json "$EXT_ROUTING"
    ext_cluster
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "published name kept" jq -e '.["myapp/myapp-web"].legacy_key == "myapp"' <<<"$(services_json)"
    check "still public" jq -e '.["myapp/myapp-web"].public == true' <<<"$(services_json)"
}

test_register_never_replaces_legacy_key() {
    set_cm service-registry services.json "$EXT_MIGRATED"
    set_cm domain-registry routing.json "$EXT_ROUTING"
    ext_cluster
    run bash "$REPO/scripts/lib/service-registry.sh" register myapp-web myapp-web myapp myapp-web 80 true
    check "exits 0" equals "$RC" 0
    check "published name kept" jq -e '.["myapp/myapp-web"].legacy_key == "myapp"' <<<"$(services_json)"
}

test_sync_succeeds_on_a_populated_registry() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":true},"gone/old":{"namespace":"gone","service":"old","ip":"100.64.1.9","port":80,"local_name":"old","public":false}}'
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5)" '{items: [$a]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "live entry kept" jq -e 'has("llmapi/llmapi")' <<<"$(services_json)"
}

###############################################################################
# One name in two namespaces
###############################################################################

SAME_NAME='{"ns1/foo":{"namespace":"ns1","service":"foo","ip":"100.64.1.7","port":80,"local_name":"foo","legacy_key":"foo","public":true},"ns2/foo":{"namespace":"ns2","service":"foo","ip":"100.64.1.8","port":80,"local_name":"foo2","public":false}}'
FOO_ROUTING='{"foo":{"expose":["foo.example.com"],"vps_nodes":["100.64.1.1"]}}'

same_name_cluster() {
    jq -n --argjson a "$(svc_item ns1 foo 100.64.1.7)" --argjson b "$(svc_item ns2 foo 100.64.1.8)" '{items: [$a, $b]}' >"$T/k8s/svcs.json"
}

test_sync_gives_no_alias_to_the_same_name_elsewhere() {
    set_cm service-registry services.json "$SAME_NAME"
    set_cm domain-registry routing.json "$FOO_ROUTING"
    same_name_cluster
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "no alias from the name alone" jq -e '.["ns2/foo"] | has("legacy_key") | not' <<<"$(services_json)"
}

test_private_takes_its_record_when_a_private_service_shares_the_name() {
    set_cm service-registry services.json "$SAME_NAME"
    set_cm domain-registry routing.json "$FOO_ROUTING"
    printf 'http:\n  routers:\n    a:\n      rule: "Host(`foo.example.com`)"\n' >"$T/vps/traefik/config/mynodeone-routes.yml"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private ns1/foo
    check "record removed" jq -e 'has("foo") | not' <<<"$(routing_json)"
    check "route still on the VPS is seen" differs "$RC" 0
    check "says not verified" contains "$OUT" 'NOT VERIFIED'
    check "names the domain" contains "$OUT" 'foo.example.com'
}

test_public_does_not_inherit_another_services_domain() {
    set_cm service-registry services.json '{"ns1/foo":{"namespace":"ns1","service":"foo","ip":"100.64.1.7","port":80,"local_name":"foo","legacy_key":"foo","public":false},"ns2/foo":{"namespace":"ns2","service":"foo","ip":"100.64.1.8","port":80,"local_name":"foo2","legacy_key":"foo","public":false}}'
    set_cm domain-registry routing.json "$FOO_ROUTING"
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public ns2/foo
    check "refuses" differs "$RC" 0
    check "not public" jq -e '.["ns2/foo"].public == false' <<<"$(services_json)"
    check "record untouched" jq -e '.foo.expose == ["foo.example.com"]' <<<"$(routing_json)"
}

test_publishing_the_same_name_keeps_the_live_route() {
    set_cm service-registry services.json '{"ns1/foo":{"namespace":"ns1","service":"foo","ip":"100.64.1.7","port":80,"local_name":"foo","legacy_key":"foo","public":true},"ns2/foo":{"namespace":"ns2","service":"foo","ip":"100.64.1.8","port":80,"local_name":"foo2","legacy_key":"foo","public":false}}'
    set_cm domain-registry routing.json "$FOO_ROUTING"
    set_cm domain-registry domains.json '{"domains":{"example.com":{}},"vps_nodes":[{"tailscale_ip":"100.64.1.1","public_ip":"192.0.2.1"}]}'
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" public ns2/foo foo2.example.com 100.64.1.1
    check "now public" jq -e '.["ns2/foo"].public == true' <<<"$(services_json)"
    check "new service's own record" jq -e '.["ns2/foo"].expose == ["foo2.example.com"]' <<<"$(routing_json)"
    check "live record moved to its owner" jq -e '.["ns1/foo"].expose == ["foo.example.com"]' <<<"$(routing_json)"
    check "no bare record left" jq -e 'has("foo") | not' <<<"$(routing_json)"
}

###############################################################################
# Explicit migration, and the SSH fallback
###############################################################################

test_sync_does_not_migrate_without_opt_in() {
    set_cm service-registry services.json "$OLD_REGISTRY"
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    cp "$T/k8s/cm/domain-registry.json" "$T/before-routing"
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5)" --argjson b "$(svc_item default demo 100.64.1.6)" '{items: [$a, $b]}' >"$T/k8s/svcs.json"
    api /api/v1/health 200 '{"status":"healthy","registry_schema":2}'
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "exits 0" equals "$RC" 0
    check "keys stay bare" jq -e 'has("llmapi") and has("demo")' <<<"$(services_json)"
    check "says how to migrate" contains "$OUT" 'service-registry.sh migrate'
    check "routing untouched" same_file "$T/before-routing" "$T/k8s/cm/domain-registry.json"
}

test_sync_forced_migration_is_available() {
    set_cm service-registry services.json "$OLD_REGISTRY"
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5)" --argjson b "$(svc_item default demo 100.64.1.6)" '{items: [$a, $b]}' >"$T/k8s/svcs.json"
    EXTRA_ENV=(MYNODEONE_REGISTRY_FORCE_MIGRATE=1)
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    EXTRA_ENV=()
    check "exits 0" equals "$RC" 0
    check "migrated" jq -e 'has("llmapi/llmapi")' <<<"$(services_json)"
}

test_sync_migrates_stragglers_after_opt_in() {
    set_cm service-registry services.json "$OLD_REGISTRY"
    jq -n --argjson a "$(svc_item llmapi llmapi 100.64.1.5)" --argjson b "$(svc_item default demo 100.64.1.6)" '{items: [$a, $b]}' >"$T/k8s/svcs.json"
    run bash "$REPO/scripts/lib/service-registry.sh" migrate
    check "migrate exits 0" equals "$RC" 0
    check "opt-in recorded" jq -e '.data["migration.json"] | fromjson | .opted_in == true' "$T/k8s/cm/service-registry.json"
    # An old client still running writes a bare key afterwards.
    set_cm service-registry services.json "$(services_json | jq -c '. + {"late":{"namespace":"default","service":"demo","ip":"100.64.1.6","port":80,"public":false}}')"
    run bash "$REPO/scripts/lib/service-registry.sh" sync
    check "sync exits 0" equals "$RC" 0
    check "straggler moved" jq -e 'has("late") | not' <<<"$(services_json)"
}

test_vps_push_refused_when_api_renders_nothing_with_routes_published() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"legacy_key":"llmapi","public":true}}'
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    printf '%s' "$TOKEN" >"$T/api-token"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh" "MYNODEONE_API_TOKEN_FILE=$T/api-token")
    lib_call 'sr_vps_push_loses_routes && echo REFUSE || echo PUSH'
    check "refused" contains "$OUT" REFUSE
    check "token not in any curl argv" lacks "$T/api/argv.log" "$TOKEN"
    check "token sent via config stream" contains "$T/api/config.log" "X-API-Token: $TOKEN"

    api /api/v1/config/vps/traefik-config 200 "$ROUTES_ONE"
    lib_call 'sr_vps_push_loses_routes && echo REFUSE || echo PUSH'
    check "routes rendered: pushes" contains "$OUT" PUSH

    api /api/v1/config/vps/traefik-config 500 'broken'
    lib_call 'sr_vps_push_loses_routes && echo REFUSE || echo PUSH'
    check "unknown: the VPS script decides" contains "$OUT" PUSH

    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    set_cm domain-registry routing.json '{}'
    lib_call 'sr_vps_push_loses_routes && echo REFUSE || echo PUSH'
    check "nothing published: empty is correct" contains "$OUT" PUSH
    EXTRA_ENV=()
}

test_private_ssh_fallback_refused_when_it_could_wipe_other_routes() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"legacy_key":"llmapi","public":true},"default/demo":{"namespace":"default","service":"demo","ip":"100.64.1.6","port":80,"public":true}}'
    set_cm domain-registry routing.json "$(jq -c '. + {"default/demo":{"expose":["demo.example.com"]}}' <<<"$LIVE_ROUTING")"
    printf 'http:\n  routers:\n    a:\n      rule: "Host(`api.example.com`)"\n' >"$T/vps/traefik/config/mynodeone-routes.yml"
    printf '%s' "$TOKEN" >"$T/api-token"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    touch "$T/ssh/sync-cleans"
    EXTRA_ENV=("MYNODEONE_API_TOKEN_FILE=$T/api-token")
    run bash "$REPO/scripts/operations/manage-app-visibility.sh" private llmapi
    EXTRA_ENV=()
    check "not verified" differs "$RC" 0
    check "says why" contains "$OUT" 'Not syncing'
    check "nothing pushed" no_file "$T/ssh/sync.log"
}

test_controller_refuses_vps_push_that_would_wipe_routes() {
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"legacy_key":"llmapi","public":true}}'
    set_cm domain-registry routing.json "$LIVE_ROUTING"
    printf '%s' "$TOKEN" >"$T/api-token"
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_NONE"
    EXTRA_ENV=("MYNODEONE_API_TOKEN_FILE=$T/api-token")
    controller '
        sleep() { :; }
        if push_sync_to_node vps_nodes 100.64.1.1 tester; then echo PUSHED; else echo REFUSED; fi
    '
    EXTRA_ENV=()
    check "refused" contains "$OUT" REFUSED
    check "nothing pushed" no_file "$T/ssh/sync.log"
}

###############################################################################
# Route downloads
###############################################################################

agent_vps_with_good_routes() {
    write_agent_env vps
    mkdir -p "$T/traefik"
    printf '%s' "$ROUTES_ONE" >"$T/traefik/mynodeone-routes.yml"
    cp "$T/traefik/mynodeone-routes.yml" "$T/before"
    api /api/v1/config/vps 200 '{"version":"v9","routes":[{"service":"b","domain":"b.example.com","backend":"100.64.1.1:80"}]}'
    api /api/v1/heartbeat 200 '{"status":"ok"}'
}

test_agent_cut_off_download_keeps_routes() {
    agent_vps_with_good_routes
    api /api/v1/config/vps/traefik-config 200 "$ROUTES_TWO"
    echo 18 >"$T/api/_api_v1_config_vps_traefik-config.exit"
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes kept" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    check "version not recorded" no_file "$T/agent.state"
}

test_agent_rejects_routers_with_no_service_defined() {
    agent_vps_with_good_routes
    api /api/v1/config/vps/traefik-config 200 $'http:\n  routers:\n    b:\n      rule: "Host(`b.example.com`)"\n      service: b\n'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "reports failure" differs "$RC" 0
    check "routes kept" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
    check "version not recorded" no_file "$T/agent.state"

    api /api/v1/config/vps/traefik-config 200 $'http:\n  routers:\n    b:\n      rule: "Host(`b.example.com`)"\n'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "router without a service: failure" differs "$RC" 0
    check "router without a service: routes kept" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"

    api /api/v1/config/vps/traefik-config 200 $'http:\n  routers:\n    b:\n      rule: "Host(`b.example.com`)"\n      service: b\n  services:\n    b:\n      loadBalancer:\n        servers:\n'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "service without a backend: failure" differs "$RC" 0
    check "service without a backend: routes kept" same_file "$T/before" "$T/traefik/mynodeone-routes.yml"
}

test_agent_accepts_other_spellings_of_a_complete_file() {
    agent_vps_with_good_routes
    api /api/v1/config/vps/traefik-config 200 $'http:\n    routers:\n        "b":\n            rule: "Host(`b.example.com`)"\n            service: "b"\n            tls:\n                certResolver: le\n        c:\n            rule: "Host(`c.example.com`)"\n            service: api@internal\n    services:\n        "b":\n            loadBalancer:\n                servers:\n                    - url: "http://100.64.1.1:80"\n'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "installed" contains "$T/traefik/mynodeone-routes.yml" 'c.example.com'
}

###############################################################################
# /etc/hosts: the sandboxed agent, in-place writes, what counts as ours
###############################################################################

agent_with_unwritable_hosts() {
    write_agent_env laptop
    echo 'POLL_INTERVAL=1' >>"$T/agent.env"
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    chmod 444 "$T/hosts"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    api /api/v1/heartbeat 200 '{"status":"ok"}'
}

test_agent_exits_for_a_new_namespace_when_hosts_mount_is_gone() {
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "    skipped: root ignores file modes"
        return 0
    fi
    agent_with_unwritable_hosts
    touch "$T/systemd/hosts-detached"
    EXTRA_ENV=(INVOCATION_ID=test)
    run timeout 8 bash "$REPO/scripts/lib/node-agent.sh" run
    EXTRA_ENV=()
    check "exits itself, non-zero" equals "$RC" 1
    check "says why" contains "$OUT" 'systemd restarts the agent'
}

test_agent_keeps_running_on_other_hosts_write_failures() {
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "    skipped: root ignores file modes"
        return 0
    fi
    agent_with_unwritable_hosts
    EXTRA_ENV=(INVOCATION_ID=test)
    run timeout 3 bash "$REPO/scripts/lib/node-agent.sh" run
    check "mount intact: still polling" equals "$RC" 124
    touch "$T/systemd/hosts-detached"
    EXTRA_ENV=()
    run timeout 3 bash "$REPO/scripts/lib/node-agent.sh" run
    check "not under systemd: still polling" equals "$RC" 124
}

test_agent_hosts_handling_matches_its_sandbox() {
    local unit="$REPO/scripts/lib/mynodeone-node-agent.service" agent="$REPO/scripts/lib/node-agent.sh"
    check "unit file found" grep -q 'ReadWritePaths=' "$unit"
    check "hosts is a writable path" grep -qE 'ReadWritePaths=.*(/etc/hosts)( |$)' "$unit"
    check "/etc stays read-only" grep -q 'ProtectSystem=strict' "$unit"
    check "restarts after it exits" grep -q 'Restart=always' "$unit"
    check "no rename onto hosts" bash -c '! grep -vE "^\s*#" "$1" | grep -E "(mv|install|cp) .*HOSTS_FILE\"?\s*$|sed -i"' _ "$agent"
    check "backup lives in the writable config dir" grep -qE 'HOSTS_BACKUP="?\$\{AGENT_HOSTS_BACKUP:-/etc/mynodeone/' "$agent"
}

HOSTS_NO_END=$'127.0.0.1 localhost\n# MyNodeOne services\n100.64.1.5 stale-entry.test.local\n\n# added by hand\n10.0.0.1 nas\n192.168.1.9 printer.home\n'

# Each script's block removal, on a file whose End marker is gone.
assert_keeps_rest() {
    check "$1: entry removed" lacks "$T/hosts" 'stale-entry.test.local'
    check "$1: hand-added comment kept" contains "$T/hosts" '# added by hand'
    check "$1: hand-added entries kept" contains "$T/hosts" '10.0.0.1 nas'
    check "$1: last line kept" contains "$T/hosts" 'printer.home'
}

hosts_block_case() {
    # hosts_block_case <description> <contents> <command...>: runs it and checks the
    # file was changed through the same inode.
    local description="$1" inode
    printf '%s' "$2" >"$T/hosts"
    inode=$(stat -c %i "$T/hosts")
    shift 2
    run "$@"
    check "$description: exits 0" equals "$RC" 0
    check "$description: written in place" equals "$(stat -c %i "$T/hosts")" "$inode"
}

test_hosts_block_removal_with_no_end_marker_keeps_the_rest() {
    check "function found" hosts_function scripts/domains/update-laptop-dns.sh update_hosts_file
    hosts_block_case update-laptop-dns "$HOSTS_NO_END" bash -c "set -euo pipefail; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; DNS_ENTRIES="100.64.1.6 b.test.local"; source "$1"; update_hosts_file' _ "$T/fn.sh"
    assert_keeps_rest update-laptop-dns

    check "function found" hosts_function scripts/setup/setup-local-dns.sh update_hosts_file
    hosts_block_case setup-local-dns "$HOSTS_NO_END" bash -c "set -e; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; CLUSTER_DOMAIN=test; source "$1"; update_hosts_file' _ "$T/fn.sh"
    assert_keeps_rest setup-local-dns

    jq -n '{items: [{metadata: {name: "demo", namespace: "default"}, spec: {type: "LoadBalancer"}, status: {loadBalancer: {ingress: [{ip: "100.64.1.6"}]}}}]}' >"$T/k8s/svcs.json"
    check "function found" hosts_function scripts/setup/setup-management-laptop.sh update_dns_entries
    hosts_block_case setup-management-laptop "$HOSTS_NO_END" bash -c "set -euo pipefail; $LOG_FUNCTIONS; source '$REPO/scripts/lib/hosts-block.sh'"'; CLUSTER_DOMAIN=test; source "$1"; update_dns_entries' _ "$T/fn.sh"
    assert_keeps_rest setup-management-laptop

    sed -n "/<<'SCRIPT_EOF'\$/,/^SCRIPT_EOF\$/p" "$REPO/scripts/setup/setup-local-dns.sh" | sed '1d;$d' |
        sed "s#/etc/hosts#$T/hosts#g" >"$T/client.sh"
    hosts_block_case setup-client-dns "$HOSTS_NO_END" bash "$T/client.sh"
    assert_keeps_rest setup-client-dns
}

test_fix_duplicate_writes_in_place_and_keeps_the_rest() {
    hosts_setup
    local inode
    printf '127.0.0.1 localhost\n# MyNodeOne Apps\n100.64.1.5 old.testcluster.local\n\n# added by hand\n10.0.0.1 nas\n100.64.1.5 demoapp.other.local\n' >"$T/hosts"
    inode=$(stat -c %i "$T/hosts")
    EXTRA_ENV=(CLUSTER_DOMAIN=testcluster)
    run bash -c 'echo y | bash "$1"' _ "$REPO/scripts/domains/fix-duplicate-dns.sh"
    EXTRA_ENV=()
    check "exits 0" equals "$RC" 0
    check "same inode" equals "$(stat -c %i "$T/hosts")" "$inode"
    check "retired entry removed" lacks "$T/hosts" 'old.testcluster.local'
    check "demo entry removed" lacks "$T/hosts" 'demoapp.other.local'
    check "hand-added comment kept" contains "$T/hosts" '# added by hand'
    check "hand-added entry kept" contains "$T/hosts" '10.0.0.1 nas'
}

test_hosts_block_markers_are_whole_lines() {
    printf '%s\n' '127.0.0.1 localhost' '10.0.0.2 box # see # MyNodeOne services docs' '# MyNodeOne services' \
        '100.64.1.5 a.test.local' '# End MyNodeOne services' '10.0.0.3 other # after # End MyNodeOne services' >"$T/hosts"
    run bash -c 'source "$1"; hosts_without_block "$2" "# MyNodeOne services" "# End MyNodeOne services"' _ "$REPO/scripts/lib/hosts-block.sh" "$T/hosts"
    check "exits 0" equals "$RC" 0
    check "block removed" lacks "$OUT" 'a.test.local'
    check "line quoting the start kept" contains "$OUT" '10.0.0.2 box'
    check "line quoting the end kept" contains "$OUT" '10.0.0.3 other'
}

test_hosts_block_restores_after_a_failed_write() {
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    printf 'new\n' >"$T/new"
    # The first write leaves the file short, as a full disk would.
    run bash -c 'source "$1" || exit 9
        writes=0
        hosts_replace_contents() { writes=$((writes + 1)); if ((writes == 1)); then : >"$2"; else cat "$1" >"$2"; fi; }
        hosts_write_in_place "$2" "$3" && echo WROTE || echo FAILED' _ "$REPO/scripts/lib/hosts-block.sh" "$T/new" "$T/hosts"
    check "lib loaded" equals "$RC" 0
    check "reported" contains "$OUT" FAILED
    check "old contents back" contains "$T/hosts" 'localhost'
}

USER_HOSTS=(
    '127.0.0.1 localhost'
    '127.0.1.1 laptop laptop.testcluster.local'
    '10.0.0.1 nas # was foo.testcluster.local'
    '10.0.0.2 box # MyNodeOne DNS entries live below'
    '10.0.0.3 other # MyNodeOne Services are elsewhere'
    '# a note about # MyNodeOne DNS entries'
    '100.64.1.9 stale.testcluster.local'
)

check_user_hosts_kept() {
    check "only the matching name goes" grep -qxE '127\.0\.1\.1 laptop' "$T/hosts"
    check "a name in a comment is not a name" grep -qxF '10.0.0.1 nas # was foo.testcluster.local' "$T/hosts"
    check "line quoting the agent's marker kept" grep -qxF '10.0.0.2 box # MyNodeOne DNS entries live below' "$T/hosts"
    check "line quoting the timer's marker kept" grep -qxF '10.0.0.3 other # MyNodeOne Services are elsewhere' "$T/hosts"
    check "comment quoting a marker kept" grep -qxF '# a note about # MyNodeOne DNS entries' "$T/hosts"
    check "stale entry removed" lacks "$T/hosts" 'stale.testcluster.local'
}

test_agent_removes_only_its_own_names() {
    write_agent_env laptop
    printf '%s\n' "${USER_HOSTS[@]}" >"$T/hosts"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check_user_hosts_kept
    check "new entry added" contains "$T/hosts" 'chat.testcluster.local'
    cp "$T/hosts" "$T/first"
    api /api/v1/config/laptop 200 '{"version":"v2","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "second run changes nothing" same_file "$T/first" "$T/hosts"
}

test_sync_dns_removes_only_its_own_names() {
    printf '%s\n' "${USER_HOSTS[@]}" >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":false}}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "exits 0" equals "$RC" 0
    check_user_hosts_kept
    check "new entry added" contains "$T/hosts" 'llmapi.testcluster.local'
}

test_sync_dns_takes_over_the_agents_block() {
    printf '127.0.0.1 localhost\n\n# MyNodeOne DNS entries (managed by node-agent)\n100.64.1.5 chat.testcluster.local chat\n100.64.1.6 other.home.local other\n10.0.0.1 nas\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":false}}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "exits 0" equals "$RC" 0
    check "agent's block gone" lacks "$T/hosts" 'chat.testcluster.local'
    check "short name went with it" bash -c '! grep -qE "^100\.64\.1\.5 chat$" "$1"' _ "$T/hosts"
    check "hand-added entry below kept" contains "$T/hosts" '10.0.0.1 nas'
}

###############################################################################
# Who writes /etc/hosts while the timer is stopped
###############################################################################

test_stopped_timer_still_owns_hosts() {
    EXTRA_ENV=(REGISTRY_LIB="$REPO/scripts/lib/service-registry-lib.sh")
    touch "$T/systemd/agent-active" "$T/systemd/timer-enabled"
    lib_call sr_hosts_writer
    EXTRA_ENV=()
    check "the enabled timer owns it" equals "$(cat "$OUT")" timer

    printf '127.0.0.1 localhost\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":false}}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "running the service does its work" contains "$T/hosts" 'llmapi.testcluster.local'
}

test_agent_stays_out_while_an_enabled_timer_is_stopped() {
    write_agent_env laptop
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    touch "$T/systemd/timer-enabled"
    api /api/v1/config/laptop 200 '{"version":"v1","dns_entries":[{"name":"chat","ip":"100.64.1.5"}]}'
    run bash "$REPO/scripts/lib/node-agent.sh" sync
    check "exits 0" equals "$RC" 0
    check "hosts untouched" same_file "$T/before" "$T/hosts"
}

test_installers_still_defer_to_a_real_agent_host() {
    touch "$T/systemd/agent-active"
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    cp "$T/hosts" "$T/before"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":false}}'
    run bash "$REPO/scripts/domains/sync-dns.sh"
    check "exits 0" equals "$RC" 0
    check "no second writer" same_file "$T/before" "$T/hosts"
}

test_timer_service_run_always_writes() {
    touch "$T/systemd/agent-active"
    printf '127.0.0.1 localhost\n' >"$T/hosts"
    printf 'CLUSTER_DOMAIN=testcluster\n' >"$T/home/.mynodeone/config.env"
    set_cm service-registry services.json '{"llmapi/llmapi":{"namespace":"llmapi","service":"llmapi","ip":"100.64.1.5","port":80,"local_name":"llmapi","public":false}}'
    printf '0::/system.slice/mynodeone-local-dns-sync.service\n' >"$T/cgroup"
    EXTRA_ENV=("MYNODEONE_CGROUP_FILE=$T/cgroup")
    run bash "$REPO/scripts/domains/sync-dns.sh"
    EXTRA_ENV=()
    check "exits 0" equals "$RC" 0
    check "wrote" contains "$T/hosts" 'llmapi.testcluster.local'
}

###############################################################################
# Which Traefik directory the agent manages
###############################################################################

traefik_dir_call() {
    # traefik_dir_call [flag]: answers with candidates limited to $T/dirs.
    EXTRA_ENV=("NODE_AGENT_ENV_FILE=$T/existing.env" "NODE_AGENT_TRAEFIK_SEARCH=$T/dirs/*/config" "NODE_AGENT_TRAEFIK_DEFAULT=$T/default")
    run bash -c 'source "$1"; node_agent_detect_traefik_dir "${2:-}"' _ "$REPO/scripts/lib/node-agent-install.sh" "${1:-}"
    EXTRA_ENV=()
}

test_traefik_dir_prefers_what_is_known() {
    mkdir -p "$T/dirs/stale/config" "$T/dirs/live/config"
    touch "$T/dirs/live/config/mynodeone-routes.yml"
    traefik_dir_call
    check "the directory holding the routes" equals "$(cat "$OUT")" "$T/dirs/live/config"

    printf 'TRAEFIK_CONFIG_DIR=/srv/current\nOTHER=1\n' >"$T/existing.env"
    traefik_dir_call
    check "the current setting beats it" equals "$(cat "$OUT")" /srv/current

    traefik_dir_call /srv/flag
    check "the flag beats both" equals "$(cat "$OUT")" /srv/flag
}

test_traefik_dir_refuses_to_guess() {
    mkdir -p "$T/dirs/one/config" "$T/dirs/two/config"
    traefik_dir_call
    check "several empty: refuses" differs "$RC" 0
    check "names the flag" contains "$OUT" '--traefik-config-dir'

    touch "$T/dirs/one/config/mynodeone-routes.yml" "$T/dirs/two/config/mynodeone-routes.yml"
    traefik_dir_call
    check "several holding routes: refuses" differs "$RC" 0

    traefik_dir_call /srv/flag
    check "the flag settles it" equals "$(cat "$OUT")" /srv/flag

    rm -rf "$T/dirs/two" "$T/dirs/one/config/mynodeone-routes.yml"
    traefik_dir_call
    check "one that exists" equals "$(cat "$OUT")" "$T/dirs/one/config"

    rm -rf "$T/dirs"
    traefik_dir_call
    check "none: the default" equals "$(cat "$OUT")" "$T/default"
}

test_traefik_dir_preference_only_settles_a_tie_with_no_routes() {
    mkdir -p "$T/dirs/one/config" "$T/dirs/two/config"
    EXTRA_ENV=("NODE_AGENT_ENV_FILE=$T/existing.env" "NODE_AGENT_TRAEFIK_SEARCH=$T/dirs/*/config" "NODE_AGENT_TRAEFIK_DEFAULT=$T/default")
    run bash -c 'source "$1"; node_agent_detect_traefik_dir "" "$2"' _ "$REPO/scripts/lib/node-agent-install.sh" "$T/dirs/two/config"
    check "no routes yet: the preferred one" equals "$(cat "$OUT")" "$T/dirs/two/config"
    touch "$T/dirs/one/config/mynodeone-routes.yml"
    run bash -c 'source "$1"; node_agent_detect_traefik_dir "" "$2"' _ "$REPO/scripts/lib/node-agent-install.sh" "$T/dirs/two/config"
    EXTRA_ENV=()
    check "routes elsewhere: follows them" equals "$(cat "$OUT")" "$T/dirs/one/config"
}

test_both_installers_share_the_traefik_dir_rule() {
    local script
    for script in scripts/installation/install-node-agent.sh scripts/lib/install-config-sync.sh; do
        check "$script uses it" grep -q 'node_agent_detect_traefik_dir' "$REPO/$script"
        check "$script keeps unknown settings" grep -q 'node_agent_keep_unknown_settings' "$REPO/$script"
        check "$script writes agent.env whole or not at all" grep -q 'mv -f .* /etc/mynodeone/agent.env' "$REPO/$script"
    done
    check "the installer takes the flag" grep -q -- '--traefik-config-dir)' "$REPO/scripts/installation/install-node-agent.sh"
}

test_agent_env_rewrite_keeps_unknown_settings() {
    printf 'NODE_NAME="old"\nCUSTOM_SETTING=keep\n# a comment\nANOTHER="also keep"\n' >"$T/existing.env"
    printf 'NODE_NAME="new"\nCONTROL_PLANE_IP="100.64.0.9"\n' >"$T/new.env"
    EXTRA_ENV=("NODE_AGENT_ENV_FILE=$T/existing.env")
    run bash -c 'source "$1"; node_agent_keep_unknown_settings "$2"' _ "$REPO/scripts/lib/node-agent-install.sh" "$T/new.env"
    EXTRA_ENV=()
    check "exits 0" equals "$RC" 0
    check "unknown key kept" contains "$T/new.env" 'CUSTOM_SETTING=keep'
    check "second unknown key kept" contains "$T/new.env" 'ANOTHER="also keep"'
    check "new value wins" equals "$(grep -c '^NODE_NAME=' "$T/new.env")" 1
    check "new value is the new one" contains "$T/new.env" 'NODE_NAME="new"'
}

test_agent_finds_the_directory_holding_the_routes() {
    mkdir -p "$T/first" "$T/second"
    touch "$T/second/mynodeone-routes.yml"
    sed -n '/^find_traefik_config_dir() {/,/^}/p' "$REPO/scripts/lib/node-agent.sh" |
        sed "s#search_dirs+=(/home/\*/traefik/config /root/traefik/config /etc/traefik/config)#search_dirs=($T/first $T/second)#" >"$T/fn.sh"
    check "search list replaced" grep -qF "$T/first" "$T/fn.sh"
    run bash -c 'source "$1"; find_traefik_config_dir' _ "$T/fn.sh"
    check "picks it" equals "$(cat "$OUT")" "$T/second"
}

###############################################################################
# Removing a node from the sync registry
###############################################################################

SYNC_REG='{"management_laptops":[{"name":"laptop-1","ip":"100.64.0.10"},{"name":"laptop-2","ip":"100.64.0.11"}],"worker_nodes":[{"name":"worker-1","ip":"100.64.0.9"}],"vps_nodes":[{"name":"vps-1","ip":"100.64.1.1"}]}'

sync_reg_json() { jq -r '.data["registry.json"]' "$T/k8s/cm/sync-controller-registry.json"; }

remove_node_call() {
    {
        echo 'log_info() { echo "$1"; }; log_success() { echo "$1"; }; log_warn() { echo "$1"; }; log_error() { echo "$1"; }'
        echo "source '$REPO/scripts/lib/service-registry-lib.sh'"
        sed -n '/^remove_from_configmap_registry() {/,/^}/p;/^registry_remove_node_filter() {/,/^}/p' "$REPO/scripts/nodes/remove-node.sh"
        echo 'remove_from_configmap_registry "$1"'
    } >"$T/fn.sh"
    run bash "$T/fn.sh" "$1"
}

test_remove_node_uses_a_conditional_update() {
    set_cm sync-controller-registry registry.json "$SYNC_REG"
    remove_node_call laptop-1
    check "function found" grep -q 'remove_from_configmap_registry()' "$T/fn.sh"
    check "exits 0" equals "$RC" 0
    check "node gone" jq -e 'all(.management_laptops[]; .name != "laptop-1")' <<<"$(sync_reg_json)"
    check "others kept" jq -e '(.management_laptops | length) == 1 and (.worker_nodes | length) == 1 and (.vps_nodes | length) == 1' <<<"$(sync_reg_json)"
    check "write is conditional" contains "$T/k8s/patches.log" 'resourceVersion'
}

test_remove_node_keeps_a_concurrent_change() {
    set_cm sync-controller-registry registry.json "$SYNC_REG"
    jq -cn --arg v "$(jq -c '.worker_nodes += [{"name":"worker-2","ip":"100.64.0.12"}]' <<<"$SYNC_REG")" '{"registry.json":$v}' >"$T/k8s/race-sync-controller-registry"
    remove_node_call laptop-1
    check "exits 0" equals "$RC" 0
    check "the race fired" no_file "$T/k8s/race-sync-controller-registry"
    check "node gone" jq -e 'all(.management_laptops[]; .name != "laptop-1")' <<<"$(sync_reg_json)"
    check "concurrent addition kept" jq -e 'any(.worker_nodes[]; .name == "worker-2")' <<<"$(sync_reg_json)"
}

test_remove_node_failed_read_wipes_nothing() {
    set_cm sync-controller-registry registry.json "$SYNC_REG"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before"
    touch "$T/k8s/fail-get-configmap"
    remove_node_call laptop-1
    rm "$T/k8s/fail-get-configmap"
    check "reports failure" differs "$RC" 0
    check "says so" contains "$OUT" 'Could not read'
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/sync-controller-registry.json"
}

uninstall_unregister_call() {
    {
        echo 'log_info() { echo "$1"; }; log_success() { echo "$1"; }; log_warn() { echo "$1"; }; log_error() { echo "$1"; }'
        echo "source '$REPO/scripts/lib/service-registry-lib.sh'"
        sed -n '/^unregister_from_sync_registry() {/,/^}/p;/^sync_registry_drop_filter() {/,/^}/p' "$REPO/scripts/installation/uninstall-mynodeone.sh"
        echo 'unregister_from_sync_registry "$1" "$2"'
    } >"$T/fn.sh"
    run bash "$T/fn.sh" "$1" "$2"
}

test_uninstall_removes_this_node_from_the_array() {
    set_cm sync-controller-registry registry.json "$SYNC_REG"
    uninstall_unregister_call management_laptops 100.64.0.10
    check "function found" grep -q 'unregister_from_sync_registry()' "$T/fn.sh"
    check "exits 0" equals "$RC" 0
    check "node gone" jq -e '.management_laptops == [{"name":"laptop-2","ip":"100.64.0.11"}]' <<<"$(sync_reg_json)"
    check "write is conditional" contains "$T/k8s/patches.log" 'resourceVersion'
}

test_uninstall_failed_read_wipes_nothing() {
    set_cm sync-controller-registry registry.json "$SYNC_REG"
    cp "$T/k8s/cm/sync-controller-registry.json" "$T/before"
    touch "$T/k8s/fail-get-configmap"
    uninstall_unregister_call management_laptops 100.64.0.10
    rm "$T/k8s/fail-get-configmap"
    check "function found" grep -q 'unregister_from_sync_registry()' "$T/fn.sh"
    check "reports failure" differs "$RC" 0
    check "registry untouched" same_file "$T/before" "$T/k8s/cm/sync-controller-registry.json"
}

test_uninstall_on_a_vps_takes_its_routes_too() {
    local script="$REPO/scripts/installation/uninstall-mynodeone.sh"
    check "uses purge-vps" grep -q 'multi-domain-registry.sh" purge-vps' "$script"
    check "not the partial removal" bash -c '! grep -q "multi-domain-registry.sh\" unregister-vps" "$1"' _ "$script"
    check "knows where the repo is" grep -q '^PROJECT_ROOT=' "$script"
    check "no unconditional patch of the sync registry" bash -c '! grep -q "kubectl patch configmap sync-controller-registry" "$1"' _ "$script"
}

# remove-vps-edge-node.sh in a temp tree that doesn't need root, with the tools it would
# otherwise run for real shadowed.
vps_edge_setup() {
    mkdir -p "$T/tree/scripts/nodes" "$T/home/.mynodeone/vps-nodes/vps-1"
    sed -e 's|if \[ "$EUID" -ne 0 \]; then|if false; then|' "$REPO/scripts/nodes/remove-vps-edge-node.sh" >"$T/tree/scripts/nodes/remove-vps-edge-node.sh"
    ln -s "$REPO/scripts/domains" "$T/tree/scripts/domains"
    ln -s "$REPO/scripts/lib" "$T/tree/scripts/lib"
    printf 'VPS_TAILSCALE_IP="100.64.1.1"\n' >"$T/home/.mynodeone/vps-nodes/vps-1/config.env"
    for tool in su ssh-keygen; do
        printf '#!/bin/bash\nexit 0\n' >"$T/bin/$tool"
        chmod +x "$T/bin/$tool"
    done
    vps_seed
}

vps_edge_remove() {
    run bash -c 'echo y | bash "$1" vps-1' _ "$T/tree/scripts/nodes/remove-vps-edge-node.sh"
}

test_remove_vps_edge_node_purges_routes() {
    vps_edge_setup
    vps_edge_remove
    check "exits 0" equals "$RC" 0
    vps_is_gone_from_all_three "edge removal"
    vps_others_survive "edge removal"
    check "local config removed" no_file "$T/home/.mynodeone/vps-nodes/vps-1"
    check "says done" contains "$OUT" 'Removal Complete'
}

test_remove_vps_edge_node_failure_keeps_local_config() {
    vps_edge_setup
    cp "$T/k8s/cm/domain-registry.json" "$T/before-domain"
    touch "$T/k8s/fail-get-configmap"
    vps_edge_remove
    rm "$T/k8s/fail-get-configmap"
    check "reports failure" differs "$RC" 0
    check "local config kept" test -f "$T/home/.mynodeone/vps-nodes/vps-1/config.env"
    check "registry untouched" same_file "$T/before-domain" "$T/k8s/cm/domain-registry.json"
    check "no false success" lacks "$OUT" 'Removal Complete'
}

hosts_guard=false
if [[ -w /etc/hosts ]]; then
    hosts_guard=true
    hosts_before=$(sha256sum /etc/hosts)
fi

names=$(declare -F | awk '{print $3}' | grep '^test_')
for name in $names; do
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        continue
    fi
    CHECK_FAILED=0
    setup "$name"
    "$name"
    if [[ "$CHECK_FAILED" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "ok   $name"
    else
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
        echo "FAIL $name"
        if [[ -n "${VERBOSE:-}" ]]; then
            sed 's/^/      /' "$OUT"
        fi
    fi
done

if "$hosts_guard" && [[ "$(sha256sum /etc/hosts)" != "$hosts_before" ]]; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("/etc/hosts changed during the run")
fi

echo ""
echo "$PASS passed, $FAIL failed"
if ((FAIL > 0)); then
    printf '  %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
