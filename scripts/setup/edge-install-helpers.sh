#!/bin/bash

###############################################################################
# Shared by setup-edge-node.sh and setup-vps-node.sh
#
# These machines have public IP addresses, so what they install is verified and
# the Traefik dashboard stays off unless it is asked for.
###############################################################################

# Published at https://docs.docker.com/engine/install/ubuntu/
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# install_docker_from_apt: install Docker Engine and the compose plugin from
# Docker's apt repository, after checking the repository key against the published
# fingerprint. Replaces piping the convenience script from get.docker.com into sh.
# EDGE_INSTALL_ROOT prefixes the paths written, for testing.
install_docker_from_apt() {
    local root="${EDGE_INSTALL_ROOT:-}"
    local os_id os_codename arch key_file actual_fingerprint

    if [ ! -f "$root/etc/os-release" ]; then
        echo "Error: cannot identify this system (no /etc/os-release)." >&2
        return 1
    fi
    os_id=$(. "$root/etc/os-release" && echo "${ID:-}")
    os_codename=$(. "$root/etc/os-release" && echo "${VERSION_CODENAME:-}")
    case "$os_id" in
        ubuntu|debian) ;;
        *)
            echo "Error: automatic Docker installation supports Ubuntu and Debian, not '${os_id:-unknown}'." >&2
            echo "Install Docker from https://docs.docker.com/engine/install/ and run this again." >&2
            return 1
            ;;
    esac
    if [ -z "$os_codename" ]; then
        echo "Error: cannot read the release codename from /etc/os-release." >&2
        return 1
    fi

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    key_file=$(mktemp)
    if ! curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o "$key_file"; then
        rm -f "$key_file"
        echo "Error: could not download Docker's repository key." >&2
        return 1
    fi

    actual_fingerprint=$(gpg --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    if [ "$actual_fingerprint" != "$DOCKER_GPG_FINGERPRINT" ]; then
        rm -f "$key_file"
        echo "Error: Docker's repository key has an unexpected fingerprint: ${actual_fingerprint:-none}" >&2
        echo "Expected: $DOCKER_GPG_FINGERPRINT" >&2
        echo "Docker was not installed." >&2
        return 1
    fi

    mkdir -p "$root/etc/apt/keyrings" "$root/etc/apt/sources.list.d"
    cp "$key_file" "$root/etc/apt/keyrings/docker.asc"
    chmod 0644 "$root/etc/apt/keyrings/docker.asc"
    rm -f "$key_file"

    arch=$(dpkg --print-architecture)
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${os_codename} stable" \
        > "$root/etc/apt/sources.list.d/docker.list"

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

# traefik_dashboard_is_enabled: the dashboard shows every route and backend on a
# public machine, so it needs TRAEFIK_DASHBOARD_ENABLED=true in the environment or
# in config.env.
traefik_dashboard_is_enabled() {
    [ "${TRAEFIK_DASHBOARD_ENABLED:-false}" = "true" ]
}

# traefik_dashboard_user_entry <credentials_file>: print the basicAuth entry for the
# dashboard. The password is generated once, unique to this machine, and kept in a
# private file so that re-running setup does not change it.
traefik_dashboard_user_entry() {
    local credentials_file="$1" password hash

    if ! command -v openssl > /dev/null 2>&1; then
        echo "Error: openssl is needed to create the dashboard password." >&2
        return 1
    fi

    if [ -s "$credentials_file" ]; then
        password=$(cut -d: -f2- "$credentials_file")
    else
        password=$(openssl rand -hex 16)
        (umask 077; printf 'admin:%s\n' "$password" > "$credentials_file")
    fi
    chmod 600 "$credentials_file"

    hash=$(printf '%s\n' "$password" | openssl passwd -apr1 -stdin)
    [ -n "$hash" ] || return 1
    printf 'admin:%s' "$hash"
}
