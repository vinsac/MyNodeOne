#!/bin/bash
#
# Tests for external-apps/scripts/deploy.sh, run against stubs (see lib.sh):
#   - a failed apply or wait exits non-zero and never reports success
#   - memory, CPU and storage values reach the generated manifests
#   - datastores never get a LoadBalancer, whatever else their name suggests
#
# Usage: bash external-apps/tests/test-deploy.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Answers for the interactive path: app, subdomain, one service called web, its
# image and port, memory, CPU, storage, no public access.
INTERACTIVE_ANSWERS=$'myapp\n\n1\nweb\nexample/web:1.0.0\n8080\n512Mi\n500m\n10Gi\nn\n'

# Answers for a docker-compose app: app, subdomain, memory, CPU, storage, no public access.
COMPOSE_ANSWERS=$'myapp\n\n256Mi\n250m\nnone\nn\n'

COMPOSE_FILE_CONTENT='services:
  web:
    image: example/web:1.0.0
    ports:
      - "8080:3000"
  api-server:
    image: example/api:1.0.0
    ports:
      - "9000:9000"
  mysql-server:
    image: mysql:8.0.46
  redis-server:
    image: redis:7.4.12
    expose:
      - "6379"
  web-db:
    image: postgres:16.15
  celery-worker:
    image: example/worker:1.0.0
'

# run_deploy <answers> [app_dir]: runs deploy.sh in the sandbox. Sets RC and OUTPUT.
run_deploy() {
    local answers="$1" app_dir="${2:-$SANDBOX/app}"
    mkdir -p "$SANDBOX/external-apps/scripts" "$app_dir"
    cp "$REPO_ROOT/external-apps/scripts/deploy.sh" "$SANDBOX/external-apps/scripts/"
    OUTPUT="$SANDBOX/output.log"
    (
        cd "$SANDBOX" || exit 1
        PATH="$SANDBOX/bin:$PATH" TMPDIR="$SANDBOX/tmp" TERM=dumb \
            bash "$SANDBOX/external-apps/scripts/deploy.sh" "$app_dir" <<< "$answers"
    ) > "$OUTPUT" 2>&1
    RC=$?
}

# service_type <manifest>: the "type:" of the Service in a generated manifest.
service_type() {
    awk '/^kind: Service/ { s = 1 } s && $1 == "type:" { print $2; exit }' "$1"
}

new_compose_sandbox() {
    new_sandbox
    mkdir -p "$SANDBOX/app"
    printf '%s' "$COMPOSE_FILE_CONTENT" > "$SANDBOX/app/docker-compose.yml"
}

echo "R16: failures are reported"

new_sandbox
FAIL_APPLY=1 run_deploy "$INTERACTIVE_ANSWERS"
assert_eq "apply failure exits non-zero" 1 "$RC"
assert_contains "apply failure is explained" "simulated apply failure" "$OUTPUT"
assert_not_contains "apply failure does not claim success" "Deployment complete" "$OUTPUT"

new_sandbox
FAIL_WAIT=1 run_deploy "$INTERACTIVE_ANSWERS"
assert_eq "wait failure exits non-zero" 1 "$RC"
assert_contains "wait failure names the problem" "did not become available" "$OUTPUT"
assert_not_contains "wait failure does not claim success" "Deployment complete" "$OUTPUT"
assert_not_contains "wait failure skips registration" "Registering with MyNodeOne" "$OUTPUT"
assert_contains "wait failure keeps the manifests" "Generated manifests kept for debugging" "$OUTPUT"

new_sandbox
run_deploy "$INTERACTIVE_ANSWERS"
assert_eq "successful deployment exits zero" 0 "$RC"
assert_contains "success is reported" "Deployment complete" "$OUTPUT"

echo "R16: generated manifests (interactive path)"

MANIFEST="$STUB_CAPTURE/20-web.yaml"
if [[ -f "$MANIFEST" ]]; then pass "a Deployment manifest is generated"; else fail "a Deployment manifest is generated"; fi
assert_contains "memory limit is doubled" 'memory: "1024Mi"' "$MANIFEST"
assert_contains "cpu limit is doubled" 'cpu: "1000m"' "$MANIFEST"
assert_not_contains "no empty limits" 'memory: ""' "$MANIFEST"
assert_contains "claim name is expanded" 'claimName: myapp-data' "$MANIFEST"
assert_not_contains "no literal variable in the claim" 'APP_NAME' "$MANIFEST"
assert_contains "a volume-backed Deployment has one replica" 'replicas: 1' "$MANIFEST"
assert_eq "the primary service gets a LoadBalancer" LoadBalancer "$(service_type "$MANIFEST")"
assert_eq "manifest directory is private" 700 "$(cat "$STUB_CAPTURE/.dir-mode")"
if [[ -e "$(cat "$STUB_CAPTURE/.dir-path")" ]]; then
    fail "manifest directory is removed after success"
else
    pass "manifest directory is removed after success"
fi

new_sandbox
run_deploy $'myapp\n\n1\nweb\nexample/web:1.0.0\n8080\n1Gi\n2\nnone\nn\n'
MANIFEST="$STUB_CAPTURE/20-web.yaml"
assert_contains "Gi limit is doubled" 'memory: "2Gi"' "$MANIFEST"
assert_contains "whole-core cpu limit is doubled" 'cpu: "4"' "$MANIFEST"
assert_contains "no volume keeps two replicas" 'replicas: 2' "$MANIFEST"
assert_not_contains "no volume is mounted without storage" 'volumeMounts' "$MANIFEST"

echo "S28: service classification (docker-compose path, no kompose)"

new_compose_sandbox
run_deploy "$COMPOSE_ANSWERS"
assert_eq "compose deployment exits zero" 0 "$RC"
for svc_and_type in web:LoadBalancer api-server:LoadBalancer mysql-server:ClusterIP \
    redis-server:ClusterIP web-db:ClusterIP celery-worker:ClusterIP; do
    svc="${svc_and_type%%:*}"
    assert_eq "$svc is ${svc_and_type##*:}" "${svc_and_type##*:}" "$(service_type "$STUB_CAPTURE/20-$svc.yaml")"
done
assert_contains "container port comes from the ports list" 'containerPort: 3000' "$STUB_CAPTURE/20-web.yaml"
assert_contains "a database's port is not guessed as 80" 'containerPort: 3306' "$STUB_CAPTURE/20-mysql-server.yaml"
assert_contains "expose is honoured" 'containerPort: 6379' "$STUB_CAPTURE/20-redis-server.yaml"
assert_contains "a database has one replica" 'replicas: 1' "$STUB_CAPTURE/20-mysql-server.yaml"
assert_contains "the subdomain goes on the frontend" 'mynodeone.io/subdomain: "myapp"' "$STUB_CAPTURE/20-web.yaml"

echo "S28: service classification (kompose path)"

new_compose_sandbox
KOMPOSE_OK=1 KOMPOSE_SERVICES="web api-server mysql-server redis-server web-db celery-worker" \
    run_deploy $'myapp\n\nn\n'
assert_eq "kompose deployment exits zero" 0 "$RC"
for svc_and_type in web:LoadBalancer api-server:LoadBalancer mysql-server:ClusterIP \
    redis-server:ClusterIP web-db:ClusterIP celery-worker:ClusterIP; do
    svc="${svc_and_type%%:*}"
    assert_eq "kompose: $svc is ${svc_and_type##*:}" "${svc_and_type##*:}" \
        "$(service_type "$STUB_CAPTURE/$svc-service.yaml")"
done

echo "S28: names that only look like datastores"

new_sandbox
mkdir -p "$SANDBOX/app"
cat > "$SANDBOX/app/docker-compose.yml" <<'EOF'
services:
  feedback-web:
    image: example/feedback:1.0.0
  sandbox-api:
    image: example/sandbox:1.0.0
  tenants-api:
    image: example/tenants:1.0.0
  mongo-express:
    image: mongo-express:1.0.2
  admin-db:
    image: postgres:16.15
EOF
run_deploy "$COMPOSE_ANSWERS"
assert_eq "feedback-web is not a database" LoadBalancer "$(service_type "$STUB_CAPTURE/20-feedback-web.yaml")"
assert_eq "sandbox-api is not a database" LoadBalancer "$(service_type "$STUB_CAPTURE/20-sandbox-api.yaml")"
assert_eq "tenants-api is not a broker" LoadBalancer "$(service_type "$STUB_CAPTURE/20-tenants-api.yaml")"
assert_eq "a database admin tool stays internal" ClusterIP "$(service_type "$STUB_CAPTURE/20-mongo-express.yaml")"
assert_eq "a database called admin-db is a database" ClusterIP "$(service_type "$STUB_CAPTURE/20-admin-db.yaml")"
assert_contains "admin-db has one replica" 'replicas: 1' "$STUB_CAPTURE/20-admin-db.yaml"

echo "S28: an interactive datastore as the first service is not exposed"

new_sandbox
run_deploy $'myapp\n\n2\nmysql-server\nmysql:8.0.46\n3306\nweb\nexample/web:1.0.0\n8080\n512Mi\n500m\nnone\nn\n'
assert_eq "first-listed mysql-server is internal" ClusterIP "$(service_type "$STUB_CAPTURE/20-mysql-server.yaml")"
assert_eq "web is the primary" LoadBalancer "$(service_type "$STUB_CAPTURE/20-web.yaml")"

finish
