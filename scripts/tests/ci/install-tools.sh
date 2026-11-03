#!/bin/bash
###############################################################################
# Installs the CI's standalone tools at pinned versions, checking each download
# against a pinned SHA-256. CI and local runs get the same binaries from here.
#
#   scripts/tests/ci/install-tools.sh DIR [gitleaks|actionlint|helm|promtool|kubeconform]...
#
# Installs into DIR, and with no tool names installs them all. Add DIR to PATH to use
# them, or pass it to scripts/tests/run-all.sh as CI_TOOLS_DIR. Linux on x86-64 only.
#
# The SHA-256 values come from each release's published checksum file. When changing
# a version, take the new value from that file.
###############################################################################

set -euo pipefail

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
KUBECONFORM_VERSION=0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
# The same as HELM_VERSION in scripts/lib/versions.sh.
HELM_VERSION=3.15.3
HELM_SHA256=ad871aecb0c9fd96aa6702f6b79e87556c8998c2e714a4959bf71ee31282ac9c
# The Prometheus that PROMETHEUS_STACK_VERSION (kube-prometheus-stack 65.8.0) runs.
PROMETHEUS_VERSION=2.55.0
PROMETHEUS_SHA256=7a6b6d5ea003e8d59def294392c64e28338da627bf760cf268e788d6a8832a23

if [[ $# -lt 1 ]]; then
    echo "usage: $0 DIR [tool]..." >&2
    exit 2
fi
DEST="$1"
shift
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-tools.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Downloads to the work dir, stops on a checksum mismatch, and copies one member of
# the archive into DEST.
install_from_tarball() {
    local url="$1" sha256="$2" member="$3" tool archive
    tool="$(basename "$member")"
    archive="$WORK/$tool.tar.gz"
    curl -fsSL --retry 3 --max-time 300 -o "$archive" "$url"
    echo "$sha256  $archive" | sha256sum -c --status || {
        echo "ERROR: $tool: the download does not match the pinned SHA-256: $url" >&2
        exit 1
    }
    tar -xzf "$archive" -C "$WORK" "$member"
    install -m 0755 "$WORK/$member" "$DEST/$tool"
    echo "installed $tool: $url"
}

install_tool() {
    case "$1" in
        gitleaks)
            install_from_tarball \
                "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
                "$GITLEAKS_SHA256" gitleaks
            ;;
        actionlint)
            install_from_tarball \
                "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
                "$ACTIONLINT_SHA256" actionlint
            ;;
        kubeconform)
            install_from_tarball \
                "https://github.com/yannh/kubeconform/releases/download/v$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
                "$KUBECONFORM_SHA256" kubeconform
            ;;
        helm)
            install_from_tarball \
                "https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz" \
                "$HELM_SHA256" linux-amd64/helm
            ;;
        promtool)
            install_from_tarball \
                "https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz" \
                "$PROMETHEUS_SHA256" "prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool"
            ;;
        *)
            echo "ERROR: unknown tool: $1" >&2
            exit 2
            ;;
    esac
}

if [[ $# -eq 0 ]]; then
    set -- gitleaks actionlint kubeconform helm promtool
fi
for tool in "$@"; do
    install_tool "$tool"
done
