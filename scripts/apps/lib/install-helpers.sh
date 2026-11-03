#!/bin/bash

###############################################################################
# Shared helpers that keep app installers safe to re-run
#
# Sourced by installers under scripts/apps/. Results are returned through a
# named variable rather than stdout so that a failure can stop the whole
# installer (an `exit` inside "$(...)" would only leave the subshell).
#
# Secret values are never echoed or logged here.
###############################################################################

# app_fail <message>: print an error and stop the installer.
app_fail() {
    echo -e "\033[0;31mError: $1\033[0m" >&2
    exit 1
}

# app_load_or_create_secret_value <var> <ns> <secret> <key> <guard_pvc> -- <generator...>
#
# Sets <var> to the value already stored in the Secret, or to the output of the
# generator when there is none, so that re-running an installer never rotates a
# credential that a database has already been initialised with.
#
# <guard_pvc> names the PVC holding data created with this credential ("" when
# nothing depends on it). A missing credential with that PVC present means the
# data's password is unknown, and generating a new one would lock the app out of
# its own database, so the installer stops. An API error also stops it: treating
# "could not read" as "does not exist" is how credentials used to get rotated.
app_load_or_create_secret_value() {
    local __var="$1" ns="$2" secret="$3" key="$4" guard_pvc="$5"
    shift 5
    [ "${1:-}" = "--" ] && shift

    local found encoded="" value=""
    if ! found=$(kubectl get secret "$secret" -n "$ns" --ignore-not-found -o name 2>/dev/null); then
        app_fail "Could not read Secret '$secret' in namespace '$ns' (Kubernetes API error). Nothing was changed."
    fi

    if [ -n "$found" ]; then
        if ! encoded=$(kubectl get secret "$secret" -n "$ns" -o "jsonpath={.data.$key}" 2>/dev/null); then
            app_fail "Could not read key '$key' of Secret '$secret' in namespace '$ns'. Nothing was changed."
        fi
        if [ -n "$encoded" ]; then
            value=$(printf '%s' "$encoded" | base64 -d) || \
                app_fail "Key '$key' of Secret '$secret' in namespace '$ns' is not valid base64."
        fi
    fi

    if [ -z "$value" ]; then
        if [ -n "$guard_pvc" ]; then
            local pvc
            if ! pvc=$(kubectl get pvc "$guard_pvc" -n "$ns" --ignore-not-found -o name 2>/dev/null); then
                app_fail "Could not check PVC '$guard_pvc' in namespace '$ns' (Kubernetes API error). Nothing was changed."
            fi
            if [ -n "$pvc" ]; then
                app_fail "PVC '$guard_pvc' in namespace '$ns' holds existing data, but key '$key' of Secret '$secret' is missing.
A new password would not match the one the data was created with. Restore the Secret, or
delete the namespace if the data is disposable (this destroys it), then run the installer again."
            fi
        fi
        value=$("$@") || app_fail "Could not generate a value for '$key' of Secret '$secret'."
        [ -n "$value" ] || app_fail "Generated an empty value for '$key' of Secret '$secret'."
    fi

    printf -v "$__var" '%s' "$value"
}

# app_image_is_pinned <image>: true for a digest or a tag naming an exact x.y.z
# release. "latest", "release", "main", "16", "7-alpine" and "8.0" all move.
# PostgreSQL is the exception: its exact releases are x.y, as in "16.15".
app_image_is_pinned() {
    local image="$1" tag
    case "$image" in
        *@sha256:*) return 0 ;;
    esac
    tag="${image##*/}"
    case "$tag" in
        *:*) tag="${tag##*:}" ;;
        *) return 1 ;;
    esac
    [[ "$tag" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] && return 0
    [[ "$image" =~ (^|/)postgres:[0-9]+\.[0-9]+(-|$) ]]
}

# app_resolve_image <var> <ns> <deployment> <container> <default_image> [override] [selector]
#
# Chooses the image for a Deployment without changing a running app's version as
# a side effect of re-running its installer, since a jump can break its data:
#   - an explicit override always wins
#   - no existing Deployment: the pinned default
#   - existing pinned image: keep it
#   - existing moving tag: freeze the digest the pod is actually running
#   - moving tag and no running pod: keep it and warn, because the default could
#     be a downgrade
# Upgrades are therefore always deliberate, through the override.
app_resolve_image() {
    local __var="$1" ns="$2" deployment="$3" container="$4" default_image="$5"
    local override="${6:-}" selector="${7:-app=$deployment}"
    local current image_id repo

    if [ -n "$override" ]; then
        printf -v "$__var" '%s' "$override"
        return 0
    fi

    if ! current=$(kubectl get deployment "$deployment" -n "$ns" --ignore-not-found \
        -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$container\")].image}" 2>/dev/null); then
        app_fail "Could not read Deployment '$deployment' in namespace '$ns' (Kubernetes API error). Nothing was changed."
    fi

    if [ -z "$current" ]; then
        printf -v "$__var" '%s' "$default_image"
        return 0
    fi

    if app_image_is_pinned "$current"; then
        printf -v "$__var" '%s' "$current"
        return 0
    fi

    image_id=$(kubectl get pods -n "$ns" -l "$selector" \
        -o "jsonpath={range .items[*].status.containerStatuses[?(@.name==\"$container\")]}{.imageID}{\"\\n\"}{end}" 2>/dev/null \
        | grep -m1 '@sha256:' || true)

    if [ -n "$image_id" ]; then
        # Keep the repository as written in the manifest; imageID may spell it differently.
        repo="${current%%@*}"
        if [[ "${repo##*/}" == *:* ]]; then
            repo="${repo%:*}"
        fi
        printf -v "$__var" '%s@%s' "$repo" "${image_id##*@}"
        echo "ℹ️  $deployment/$container runs the moving tag '$current'; freezing the running version: ${repo}@${image_id##*@}" >&2
        return 0
    fi

    echo -e "\033[1;33m⚠️  $deployment/$container uses the moving tag '$current' and has no running pod to read a version from.\033[0m" >&2
    echo "   Keeping '$current' rather than risk changing its version. Set an explicit image to pin it." >&2
    printf -v "$__var" '%s' "$current"
}

# app_warn_first_user_admin <app> <url>: these apps give admin rights to whoever
# registers first and have no setting the installer can rely on to pre-seed that
# account, so anyone who reaches the URL first owns the instance.
app_warn_first_user_admin() {
    local app="$1" url="$2"
    echo ""
    echo -e "\033[1;33m⚠️  SECURITY: $app makes the FIRST person to register the administrator.\033[0m"
    echo "   Until you have created your account, anyone who can reach this URL can take"
    echo "   over the instance: $url"
    echo "   Create your admin account NOW, and before you enable public internet access."
    echo ""
}
