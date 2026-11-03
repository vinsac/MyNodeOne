#!/bin/bash
#
# Tests for scripts/apps/lib/install-helpers.sh, run against the kubectl stub (see
# lib.sh): credentials survive a re-run, an API error never rotates them, and a
# re-run never changes the version a running app is on.
#
# Usage: bash external-apps/tests/test-install-helpers.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

HELPERS="$REPO_ROOT/scripts/apps/lib/install-helpers.sh"

# in_sandbox <script>: runs the script with the helpers loaded. Sets RC and RESULT.
in_sandbox() {
    RESULT=$(PATH="$SANDBOX/bin:$PATH" bash -c "set -euo pipefail; source '$HELPERS'; $1" 2>"$SANDBOX/stderr")
    RC=$?
}

echo "R4: credentials"

new_sandbox
in_sandbox 'app_load_or_create_secret_value V ns s k "" -- echo generated; echo "$V"'
assert_eq "generates when there is no Secret" generated "$RESULT"

new_sandbox
printf 'existing' | base64 > "$STUB_STATE/secret.s.k"
in_sandbox 'app_load_or_create_secret_value V ns s k "" -- echo generated; echo "$V"'
assert_eq "reuses an existing value" existing "$RESULT"

new_sandbox
printf 'existing' | base64 > "$STUB_STATE/secret.s.k"
printf 'db-existing' | base64 > "$STUB_STATE/secret.s.db-password"
in_sandbox 'app_load_or_create_secret_value V ns s db-password "" -- echo generated; echo "$V"'
assert_eq "reads a key with a hyphen" db-existing "$RESULT"

new_sandbox
export FAIL_GET=1
in_sandbox 'app_load_or_create_secret_value V ns s k "" -- echo generated; echo "reached:$V"'
unset FAIL_GET
assert_eq "an API error stops the installer" 1 "$RC"
assert_eq "an API error never generates a value" "" "$RESULT"
assert_contains "an API error is explained" "Kubernetes API error" "$SANDBOX/stderr"

new_sandbox
touch "$STUB_STATE/pvc.data"
in_sandbox 'app_load_or_create_secret_value V ns s k data -- echo generated; echo "reached:$V"'
assert_eq "existing data without its password stops the installer" 1 "$RC"
assert_eq "existing data is never given a new password" "" "$RESULT"

new_sandbox
printf 'existing' | base64 > "$STUB_STATE/secret.s.k"
touch "$STUB_STATE/pvc.data"
in_sandbox 'app_load_or_create_secret_value V ns s k data -- echo generated; echo "$V"'
assert_eq "existing data with its password carries on" existing "$RESULT"

new_sandbox
in_sandbox 'app_load_or_create_secret_value V ns s k data -- echo generated; echo "$V"'
assert_eq "a guard PVC that does not exist yet does not block a new install" generated "$RESULT"

new_sandbox
in_sandbox 'app_load_or_create_secret_value V ns s k "" -- false; echo "reached:$V"'
assert_eq "a failed generator stops the installer" 1 "$RC"

echo "S29: images"

check_pinned() { # image expected
    new_sandbox
    in_sandbox "if app_image_is_pinned '$1'; then echo yes; else echo no; fi"
    assert_eq "$1 pinned: $2" "$2" "$RESULT"
}
check_pinned postgres:15.19-alpine yes
check_pinned ghcr.io/immich-app/immich-server:v1.132.3 yes
check_pinned tensorchord/pgvecto-rs:pg14-v0.2.0 yes
check_pinned jellyfin/jellyfin:12.4.20261026-211555 yes
check_pinned redis@sha256:abc yes
check_pinned postgres:16.15 yes
check_pinned docker.io/library/postgres:16.15 yes
check_pinned postgres:16 no
check_pinned postgres:16-alpine no
check_pinned redis:7-alpine no
check_pinned mysql:8.0 no
check_pinned nginx no
check_pinned ghcr.io/open-webui/open-webui:main no
check_pinned ghcr.io/immich-app/immich-server:release no
check_pinned registry.local:5000/app no

new_sandbox
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "$I"'
assert_eq "a new install uses the pinned default" default:1.0.0 "$RESULT"

new_sandbox
in_sandbox 'app_resolve_image I ns d c default:1.0.0 override:2.0.0; echo "$I"'
assert_eq "an override wins" override:2.0.0 "$RESULT"

new_sandbox
echo "app:0.9.0" > "$STUB_STATE/deployment.d"
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "$I"'
assert_eq "an existing pinned version is kept, never downgraded or jumped" app:0.9.0 "$RESULT"

new_sandbox
echo "app:0.9.0" > "$STUB_STATE/deployment.d"
in_sandbox 'app_resolve_image I ns d c default:1.0.0 override:2.0.0; echo "$I"'
assert_eq "an override upgrades an existing install" override:2.0.0 "$RESULT"

new_sandbox
echo "ghcr.io/org/app:latest" > "$STUB_STATE/deployment.d"
echo "ghcr.io/org/app@sha256:feed" > "$STUB_STATE/imageid.d"
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "$I"'
assert_eq "a moving tag is frozen at the running digest" "ghcr.io/org/app@sha256:feed" "$RESULT"

new_sandbox
echo "registry.local:5000/app" > "$STUB_STATE/deployment.d"
echo "registry.local:5000/app@sha256:feed" > "$STUB_STATE/imageid.d"
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "$I"'
assert_eq "a registry port is not mistaken for a tag" "registry.local:5000/app@sha256:feed" "$RESULT"

new_sandbox
echo "app:latest" > "$STUB_STATE/deployment.d"
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "$I"'
assert_eq "a moving tag with no running pod is kept, not replaced" app:latest "$RESULT"
assert_contains "and the user is told" "no running pod" "$SANDBOX/stderr"

new_sandbox
export FAIL_GET=1
in_sandbox 'app_resolve_image I ns d c default:1.0.0; echo "reached:$I"'
unset FAIL_GET
assert_eq "an API error stops the installer" 1 "$RC"

finish
