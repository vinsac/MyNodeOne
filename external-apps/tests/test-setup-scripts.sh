#!/bin/bash
#
# Tests for the security-sensitive parts of the setup, uninstall and app scripts, run
# against stubs (see lib.sh). Installers cannot be run whole here, so single functions
# are lifted out of them and exercised in a temporary directory.
#
# Usage: bash external-apps/tests/test-setup-scripts.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# extract_function <file> <name>: print one top-level function from a script.
extract_function() {
    awk -v start="^$2\\\\(\\\\) \\\\{" '$0 ~ start { on = 1 } on { print } on && /^}/ { exit }' "$1"
}

LAPTOP="$REPO_ROOT/scripts/setup/setup-laptop.sh"
UNINSTALL="$REPO_ROOT/scripts/installation/uninstall-mynodeone.sh"

LOG_STUBS='log_info() { echo "$1"; }; log_success() { echo "$1"; }; log_warn() { echo "$1"; }; log_error() { echo "$1"; }; print_header() { :; }'

###############################################################################
echo "S8: passwordless sudo is opt-in and validated"
###############################################################################

laptop_sudo_script() { # <stdin_is_terminal result>
    {
        echo "$LOG_STUBS"
        extract_function "$LAPTOP" configure_passwordless_sudo
        echo "stdin_is_terminal() { $1; }"
        echo 'ACTUAL_USER=first.last'
        echo 'configure_passwordless_sudo'
    } > "$SANDBOX/run.sh"
}

new_sandbox
laptop_sudo_script false
PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 < /dev/null
assert_not_contains "non-interactive: never grants" "install" "$STUB_LOG"

new_sandbox
laptop_sudo_script true
PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< ""
assert_not_contains "pressing Enter: no grant" "install" "$STUB_LOG"

new_sandbox
laptop_sudo_script true
PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< "y"
assert_not_contains "a bare y is not enough" "install" "$STUB_LOG"

new_sandbox
laptop_sudo_script true
PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< "grant"
assert_contains "explicit grant: validated with visudo" "sudo visudo -c -f" "$STUB_LOG"
assert_contains "explicit grant: installed read-only" "sudo install -m 0440" "$STUB_LOG"
assert_contains "the file name has no dot, which sudo would ignore" "/etc/sudoers.d/first_last-nopasswd" "$STUB_LOG"
assert_contains "the prompt explains the risk" "become root without" "$SANDBOX/out"

new_sandbox
laptop_sudo_script true
FAIL_VISUDO=1 PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< "grant"
assert_contains "invalid rule: reported" "failed validation" "$SANDBOX/out"
assert_not_contains "invalid rule: not installed" "install" "$STUB_LOG"

###############################################################################
echo "S8: uninstall removes only what MyNodeOne wrote"
###############################################################################

run_sudoers_removal() { # <user>
    {
        echo "$LOG_STUBS"
        extract_function "$UNINSTALL" remove_mynodeone_sudoers
        echo "remove_mynodeone_sudoers '$1' '$SANDBOX/sudoers.d'"
    } > "$SANDBOX/run.sh"
    bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1
}

new_sandbox
mkdir -p "$SANDBOX/sudoers.d"
echo 'alice ALL=(ALL) NOPASSWD: ALL' > "$SANDBOX/sudoers.d/alice-nopasswd"
echo '# MyNodeOne Passwordless Sudo Configuration' > "$SANDBOX/sudoers.d/mynodeone"
echo 'bob ALL=(ALL) NOPASSWD: ALL' > "$SANDBOX/sudoers.d/bob-nopasswd"
echo 'admins ALL=(ALL) ALL' > "$SANDBOX/sudoers.d/admins"
run_sudoers_removal alice
assert_eq "our rule is removed" no "$([[ -e "$SANDBOX/sudoers.d/alice-nopasswd" ]] && echo yes || echo no)"
assert_eq "our scoped file is removed" no "$([[ -e "$SANDBOX/sudoers.d/mynodeone" ]] && echo yes || echo no)"
assert_eq "another user's rule stays" yes "$([[ -e "$SANDBOX/sudoers.d/bob-nopasswd" ]] && echo yes || echo no)"
assert_eq "an unrelated file stays" yes "$([[ -e "$SANDBOX/sudoers.d/admins" ]] && echo yes || echo no)"

new_sandbox
mkdir -p "$SANDBOX/sudoers.d"
printf 'alice ALL=(ALL) NOPASSWD: ALL\nalice ALL=(ALL) NOPASSWD: /bin/extra\n' > "$SANDBOX/sudoers.d/alice-nopasswd"
run_sudoers_removal alice
assert_eq "an edited rule stays" yes "$([[ -e "$SANDBOX/sudoers.d/alice-nopasswd" ]] && echo yes || echo no)"
assert_contains "and the user is told" "Left" "$SANDBOX/out"

new_sandbox
mkdir -p "$SANDBOX/sudoers.d"
echo 'first.last ALL=(ALL) NOPASSWD: ALL' > "$SANDBOX/sudoers.d/first_last-nopasswd"
run_sudoers_removal first.last
assert_eq "a dotted user's rule is found" no "$([[ -e "$SANDBOX/sudoers.d/first_last-nopasswd" ]] && echo yes || echo no)"

new_sandbox
mkdir -p "$SANDBOX/sudoers.d"
echo 'someone ALL=(ALL) ALL' > "$SANDBOX/sudoers.d/mynodeone"
run_sudoers_removal alice
assert_eq "a file merely called mynodeone stays" yes "$([[ -e "$SANDBOX/sudoers.d/mynodeone" ]] && echo yes || echo no)"

###############################################################################
echo "S15: kubeconfig is streamed into a private file"
###############################################################################

# Stands in for the real SSH helper. FAKE_SSH decides what the "remote" command does.
kubeconfig_script() {
    {
        echo "$LOG_STUBS"
        extract_function "$LAPTOP" fetch_kubeconfig
        cat <<'EOF'
ssh_with_control() {
    echo "ssh $*" >> "$STUB_LOG"
    case "$FAKE_SSH" in
        works)
            printf 'apiVersion: v1\nserver: https://127.0.0.1:6443\n'
            ;;
        needs-password)
            if [[ "$*" == *"sudo -n"* ]]; then return 1; fi
            read -r supplied_password
            echo "password=$supplied_password" >> "$STUB_STATE/remote-stdin"
            printf 'apiVersion: v1\nserver: https://127.0.0.1:6443\n'
            ;;
        garbage)
            echo 'sudo: a password is required'
            ;;
    esac
}
ACTUAL_USER="$(id -un)"
CONTROL_PLANE_USER=admin
CONTROL_PLANE_IP=100.64.0.1
OSTYPE=linux-gnu
set -euo pipefail
fetch_kubeconfig
EOF
    } > "$SANDBOX/run.sh"
}

new_sandbox
kubeconfig_script
ACTUAL_HOME="$SANDBOX/home" FAKE_SSH=works PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 < /dev/null
RC=$?
assert_eq "succeeds" 0 "$RC"
assert_eq "the file is private" 600 "$(stat -c '%a' "$SANDBOX/home/.kube/config" 2>/dev/null)"
assert_contains "the server address is rewritten" "https://100.64.0.1:6443" "$SANDBOX/home/.kube/config"
assert_not_contains "nothing is copied to /tmp on the control plane" "/tmp/" "$STUB_LOG"
assert_not_contains "no world-readable copy" "chmod 644" "$STUB_LOG"
assert_eq "no temporary file is left" no "$([[ -e "$SANDBOX/home/.kube/config.new" ]] && echo yes || echo no)"

new_sandbox
kubeconfig_script
ACTUAL_HOME="$SANDBOX/home" FAKE_SSH=needs-password PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< "hunter2"
assert_contains "a password goes over stdin" "password=hunter2" "$STUB_STATE/remote-stdin"
assert_not_contains "and never in the arguments" "hunter2" "$STUB_LOG"
assert_eq "the fallback also produces a private file" 600 "$(stat -c '%a' "$SANDBOX/home/.kube/config" 2>/dev/null)"

new_sandbox
kubeconfig_script
mkdir -p "$SANDBOX/home/.kube"
echo 'previous' > "$SANDBOX/home/.kube/config"
export FAIL_GET=1
ACTUAL_HOME="$SANDBOX/home" FAKE_SSH=garbage PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/run.sh" > "$SANDBOX/out" 2>&1 <<< "wrong"
RC=$?
unset FAIL_GET
assert_eq "output that is not a kubeconfig fails" 1 "$RC"
assert_contains "and the previous config is untouched" "previous" "$SANDBOX/home/.kube/config"
assert_eq "and no temporary file is left" no "$([[ -e "$SANDBOX/home/.kube/config.new" ]] && echo yes || echo no)"

###############################################################################
echo "S14: Traefik dashboard"
###############################################################################

EDGE_HELPERS="$REPO_ROOT/scripts/setup/edge-install-helpers.sh"

new_sandbox
bash -c "source '$EDGE_HELPERS'; traefik_dashboard_user_entry '$SANDBOX/creds'" > "$SANDBOX/first"
bash -c "source '$EDGE_HELPERS'; traefik_dashboard_user_entry '$SANDBOX/creds'" > "$SANDBOX/second"
assert_eq "credentials are private" 600 "$(stat -c '%a' "$SANDBOX/creds")"
assert_contains "the entry is a hash" 'admin:$apr1$' "$SANDBOX/first"
PASSWORD_ONE=$(cut -d: -f2 "$SANDBOX/creds")
assert_not_contains "the password is not in the entry" "$PASSWORD_ONE" "$SANDBOX/first"
assert_eq "the hash matches the stored password on a re-run" \
    "$(cut -d: -f2 "$SANDBOX/second")" \
    "$(printf '%s\n' "$PASSWORD_ONE" | openssl passwd -apr1 -salt "$(cut -d'$' -f3 "$SANDBOX/second")" -stdin)"

new_sandbox
bash -c "source '$EDGE_HELPERS'; traefik_dashboard_user_entry '$SANDBOX/creds'" > /dev/null
OTHER_PASSWORD=$(cut -d: -f2 "$SANDBOX/creds")
if [[ "$OTHER_PASSWORD" != "$PASSWORD_ONE" ]]; then pass "each machine gets its own password"; else fail "each machine gets its own password"; fi

if bash -c "source '$EDGE_HELPERS'; traefik_dashboard_is_enabled"; then fail "the dashboard is off by default"; else pass "the dashboard is off by default"; fi
if TRAEFIK_DASHBOARD_ENABLED=true bash -c "source '$EDGE_HELPERS'; traefik_dashboard_is_enabled"; then pass "it can be enabled"; else fail "it can be enabled"; fi

SHARED_HASH=$(grep -rlF 'H6uskkkW' "$REPO_ROOT/scripts/setup" "$REPO_ROOT/manifests/examples" "$REPO_ROOT/external-apps/scripts" || true)
assert_eq "the shared admin hash is gone" "" "$SHARED_HASH"
assert_not_contains "the VPS has no unauthenticated dashboard labels" "traefik.enable=true" "$REPO_ROOT/scripts/setup/setup-vps-node.sh"

###############################################################################
echo "S30: Docker comes from the verified apt repository"
###############################################################################

docker_install() { # <fingerprint> [os id]
    new_sandbox
    mkdir -p "$SANDBOX/root/etc"
    printf 'ID=%s\nVERSION_CODENAME=noble\n' "${2:-ubuntu}" > "$SANDBOX/root/etc/os-release"
    for tool in apt-get systemctl; do
        printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\n' "$tool" > "$SANDBOX/bin/$tool"
    done
    printf '#!/bin/bash\necho "curl $*" >> "$STUB_LOG"\nwhile [[ $# -gt 0 ]]; do if [[ "$1" == "-o" ]]; then echo key > "$2"; fi; shift; done\n' > "$SANDBOX/bin/curl"
    printf '#!/bin/bash\necho "fpr:::::::::%s:"\n' "$1" > "$SANDBOX/bin/gpg"
    printf '#!/bin/bash\necho amd64\n' > "$SANDBOX/bin/dpkg"
    chmod +x "$SANDBOX/bin/"*
    EDGE_INSTALL_ROOT="$SANDBOX/root" PATH="$SANDBOX/bin:$PATH" \
        bash -c "source '$EDGE_HELPERS'; install_docker_from_apt" > "$SANDBOX/out" 2>&1
    RC=$?
}

docker_install 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
assert_eq "the expected key installs" 0 "$RC"
assert_contains "the repository is signed" "signed-by=/etc/apt/keyrings/docker.asc" "$SANDBOX/root/etc/apt/sources.list.d/docker.list"
assert_contains "Docker is installed from it" "install -y -qq docker-ce" "$STUB_LOG"
assert_not_contains "the convenience script is not used" "get.docker.com" "$STUB_LOG"

docker_install 0000000000000000000000000000000000000000
assert_eq "an unexpected key stops the installation" 1 "$RC"
assert_contains "and says so" "unexpected fingerprint" "$SANDBOX/out"
assert_not_contains "and Docker is not installed" "docker-ce" "$STUB_LOG"
assert_eq "and the key is not trusted" no "$([[ -e "$SANDBOX/root/etc/apt/keyrings/docker.asc" ]] && echo yes || echo no)"

docker_install 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 fedora
assert_eq "an unsupported system stops with an explanation" 1 "$RC"
assert_contains "naming the system" "fedora" "$SANDBOX/out"

###############################################################################
echo "S25: databases deployed by manage-apps.sh"
###############################################################################

manage_apps_sandbox() {
    new_sandbox
    mkdir -p "$SANDBOX/scripts/operations" "$SANDBOX/scripts/apps/lib" "$SANDBOX/manifests/apps"
    cp "$REPO_ROOT/scripts/operations/manage-apps.sh" "$SANDBOX/scripts/operations/"
    cp "$REPO_ROOT/scripts/apps/lib/install-helpers.sh" "$SANDBOX/scripts/apps/lib/"
}
manage_apps() {
    PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/scripts/operations/manage-apps.sh" "$@" > "$SANDBOX/out" 2>&1
    RC=$?
}

for app in postgresql mysql; do
    manage_apps_sandbox
    manage_apps deploy "$app"
    assert_eq "$app: deploys" 0 "$RC"
    assert_not_contains "$app: no default password in the manifest" "changeme123" "$STUB_CAPTURE/stdin.yaml"
    assert_not_contains "$app: no default password in the output" "changeme123" "$SANDBOX/out"
    assert_contains "$app: reads the password from a Secret" "secretKeyRef" "$STUB_CAPTURE/stdin.yaml"
    assert_contains "$app: explains how to get the password" "kubectl get secret ${app}-credentials" "$SANDBOX/out"
done

manage_apps_sandbox
manage_apps deploy postgresql
assert_contains "postgresql: pinned" "image: postgres:16.15-alpine" "$STUB_CAPTURE/stdin.yaml"
manage_apps_sandbox
manage_apps deploy mysql
assert_contains "mysql: pinned" "image: mysql:8.0.46" "$STUB_CAPTURE/stdin.yaml"
manage_apps_sandbox
manage_apps deploy redis
assert_contains "redis: pinned" "image: redis:7.4.12-alpine" "$STUB_CAPTURE/stdin.yaml"

# Re-run: the same password
manage_apps_sandbox
printf 'keep-this-one' | base64 > "$STUB_STATE/secret.postgresql-credentials.password"
touch "$STUB_STATE/pvc.postgres-pvc"
manage_apps deploy postgresql
assert_eq "a re-run keeps working" 0 "$RC"
assert_contains "a re-run keeps the password" "password: $(printf 'keep-this-one' | base64)" "$STUB_CAPTURE/stdin.yaml"

# An older install: the data on disk needs the password held in the Deployment
manage_apps_sandbox
touch "$STUB_STATE/pvc.postgres-pvc"
echo "postgres:16.15-alpine" > "$STUB_STATE/deployment.postgresql"
echo "changeme123" > "$STUB_STATE/env.postgresql.POSTGRES_PASSWORD"
manage_apps deploy postgresql
assert_eq "an older install upgrades" 0 "$RC"
assert_contains "and keeps its password" "password: $(printf 'changeme123' | base64)" "$STUB_CAPTURE/stdin.yaml"
assert_contains "and the user is told" "moved into Secret" "$SANDBOX/out"

# Data with no known password must not get a new one
manage_apps_sandbox
touch "$STUB_STATE/pvc.postgres-pvc"
manage_apps deploy postgresql
assert_eq "data with an unknown password stops the deployment" 1 "$RC"

###############################################################################
echo "S25: generate-template.sh"
###############################################################################

new_sandbox
mkdir -p "$SANDBOX/external-apps/scripts"
cp "$REPO_ROOT/external-apps/scripts/generate-template.sh" "$SANDBOX/external-apps/scripts/"
TERM=dumb PATH="$SANDBOX/bin:$PATH" bash "$SANDBOX/external-apps/scripts/generate-template.sh" \
    --name demo --type api --database --redis --output "$SANDBOX/demo" > "$SANDBOX/out" 2>&1 < /dev/null
RC=$?
DB="$SANDBOX/demo/kubernetes/10-database.yaml"
assert_eq "generates" 0 "$RC"
assert_eq "the file with the password is private" 600 "$(stat -c '%a' "$DB" 2>/dev/null)"
assert_not_contains "no placeholder password" "CHANGE-ME" "$DB"
GENERATED=$(awk -F'"' '/POSTGRES_PASSWORD/ { print $2 }' "$DB")
assert_contains "the database URL uses the same password" "demo:$GENERATED@postgres" "$DB"
assert_contains "the secret reference is expanded" "name: demo-db-credentials" "$SANDBOX/demo/kubernetes/20-app.yaml"
assert_contains "the password file is git-ignored" "kubernetes/10-database.yaml" "$SANDBOX/demo/.gitignore"
MOVING_TAGS=$(grep -rnE 'image: [^ ]+:(latest|[0-9]+-alpine|alpine)$' "$SANDBOX/demo/kubernetes" || true)
assert_eq "no moving image tags" "" "$MOVING_TAGS"
(cd "$SANDBOX/demo" && FAIL_WAIT=1 PATH="$SANDBOX/bin:$PATH" bash scripts/deploy.sh) > "$SANDBOX/deploy-out" 2>&1 < /dev/null
assert_eq "the generated deploy script reports a failed wait" 1 "$?"

###############################################################################
echo "S30: dashboard pod"
###############################################################################

dashboard_sandbox() {
    new_sandbox
    mkdir -p "$SANDBOX/website" "$SANDBOX/home"
    cp "$REPO_ROOT/website/"*.html "$REPO_ROOT/website/"*.sh "$SANDBOX/website/"
    ACTUAL_HOME="$SANDBOX/home" TMPDIR="$SANDBOX/tmp" PATH="$SANDBOX/bin:$PATH" \
        bash "$SANDBOX/website/deploy-dashboard.sh" > "$SANDBOX/out" 2>&1 < /dev/null
    RC=$?
}

# Checks the manifests the script sent to the API server, and prints one line per problem.
check_dashboard_manifest() {
    python3 - "$STUB_CAPTURE/stdin.yaml" <<'PY'
import sys
import yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
deployment = next(d for d in docs if d['kind'] == 'Deployment')
service = next(d for d in docs if d['kind'] == 'Service')
spec = deployment['spec']['template']['spec']
containers = {c['name']: c for c in spec['containers']}
web, exporter = containers['nginx'], containers['service-exporter']
sa_path = '/var/run/secrets/kubernetes.io/serviceaccount'

checks = {
    'the pod does not run as root': spec['securityContext'].get('runAsNonRoot') is True,
    'the service account token is not automounted': spec.get('automountServiceAccountToken') is False,
    'the web server has no token': all(m['mountPath'] != sa_path for m in web['volumeMounts']),
    'the exporter has a read-only token': any(
        m['mountPath'] == sa_path and m.get('readOnly') for m in exporter['volumeMounts']),
    'the service reaches the port nginx listens on':
        service['spec']['ports'][0]['targetPort'] == web['ports'][0]['containerPort'],
    'every mounted volume exists': all(
        m['name'] in {v['name'] for v in spec['volumes']}
        for c in containers.values() for m in c['volumeMounts']),
    'no moving image tags': all(
        ':' in c['image'] and c['image'].split(':')[1] not in ('latest', 'alpine')
        for c in containers.values()),
}
for name, ok in checks.items():
    if not ok:
        print(name)
PY
}

dashboard_sandbox
assert_eq "the dashboard deploys" 0 "$RC"
assert_eq "its manifests parse and meet the pod requirements" "" "$(check_dashboard_manifest 2>&1)"
assert_contains "links to dashboard.html have a page behind them" "dashboard.html=" "$STUB_LOG"

export FAIL_WAIT=1
dashboard_sandbox
unset FAIL_WAIT
assert_eq "a pod that never starts is reported as a failure" 1 "$RC"
assert_not_contains "and not as a success" "deployed successfully" "$SANDBOX/out"

finish
