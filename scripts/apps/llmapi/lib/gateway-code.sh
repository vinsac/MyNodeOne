#!/bin/bash
# Ships the gateway's code and rolls it out. Used by install-llmapi.sh, deploy-gateway.sh
# and upgrade-llmapi.sh, so they all deploy the same thing. Source lib/install-helpers.sh
# first. Everything is relative to scripts/apps/llmapi, passed in as $1.

# Hash of everything the gateway pod loads from ConfigMaps. It goes in a pod template
# annotation, so a change to any of these files rolls the Deployment.
gateway_code_sha() {
    local app_dir="$1" static_dir="$1/gateway/static" file
    {
        sha256sum <"$app_dir/gateway/main.py"
        sha256sum <"$app_dir/gateway/requirements.lock"
        if [ -d "$static_dir" ]; then
            while IFS= read -r file; do
                basename "$file"
                sha256sum <"$file"
            done < <(find "$static_dir" -maxdepth 1 -type f | LC_ALL=C sort)
        fi
    } | sha256sum | awk '{print $1}'
}

ship_gateway_code() {
    local app_dir="$1"
    kubectl create configmap gateway-code -n "${NAMESPACE:-llmapi}" \
        --from-file=main.py="$app_dir/gateway/main.py" \
        --from-file=requirements.lock="$app_dir/gateway/requirements.lock" \
        --dry-run=client -o yaml | replace_or_create_from_stdin configmap gateway-code
}

# Prints the gateway-static ConfigMap, built from gateway/static/, or nothing when the
# directory is absent or empty. ConfigMap keys can't hold paths, so the files have to sit
# directly in gateway/static/.
render_gateway_static() {
    local static_dir="$1/gateway/static" manifest size nested file_count=0
    if [ -d "$static_dir" ]; then
        file_count=$(find "$static_dir" -maxdepth 1 -type f | wc -l)
    fi
    [ "$file_count" -gt 0 ] || return 0

    nested=$(find "$static_dir" -mindepth 2 -type f -print -quit)
    if [ -n "$nested" ]; then
        echo "ERROR: gateway/static/ must be flat for the gateway-static ConfigMap, but found: $nested" >&2
        return 1
    fi

    manifest=$(kubectl create configmap gateway-static -n "${NAMESPACE:-llmapi}" --from-file="$static_dir" --dry-run=client -o yaml)
    size=$(wc -c <<<"$manifest")
    if [ "$size" -gt 1000000 ]; then
        echo "ERROR: gateway/static/ comes to $size bytes as a ConfigMap, over the 1 MiB limit." >&2
        return 1
    fi
    printf '%s\n' "$manifest"
}

# Ships gateway/static/ as the gateway-static ConfigMap, mounted at /app/static. Works
# when the directory is absent or empty.
ship_gateway_static() {
    local manifest
    manifest=$(render_gateway_static "$1") || return 1
    if [ -z "$manifest" ]; then
        kubectl delete configmap gateway-static -n "${NAMESPACE:-llmapi}" --ignore-not-found >/dev/null
        return 0
    fi
    replace_or_create_from_stdin configmap gateway-static <<<"$manifest"
}

# Applies the Deployment. The replica count is kept by render_manifest.
apply_gateway_deployment() {
    local app_dir="$1" sha="$2" ns="${NAMESPACE:-llmapi}" rendered
    rendered=$(render_manifest <(sed -e "s/__NAMESPACE__/$ns/g" -e "s/__GATEWAY_CODE_SHA__/$sha/g" \
        "$app_dir/manifests/gateway-deployment.yaml"))
    kubectl apply -f - <<<"$rendered"
}
