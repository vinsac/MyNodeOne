#!/bin/bash
###############################################################################
# What install-node-agent.sh and install-config-sync.sh have in common, so the
# two installers cannot drift apart again. Source this file; it runs nothing.
#
# The one agent script is scripts/lib/node-agent.sh and the one unit is
# scripts/lib/mynodeone-node-agent.service. Paths can be overridden for tests.
###############################################################################

NODE_AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_AGENT_BIN="${NODE_AGENT_BIN:-/usr/local/bin/mynodeone-node-agent}"
NODE_AGENT_SYSTEMD_DIR="${NODE_AGENT_SYSTEMD_DIR:-/etc/systemd/system}"
NODE_AGENT_ENV_FILE="${NODE_AGENT_ENV_FILE:-/etc/mynodeone/agent.env}"

# node_agent_run_with_token_file <token> <command> [args...]
# Runs the command with --api-token-file <path> added, so the token stays out of `ps`.
# The file is mode 600 and goes away when the command ends, however it ends. It has its
# own subshell so the caller's EXIT trap is left alone. An empty token adds nothing,
# which leaves the installer to find one itself.
node_agent_run_with_token_file() {
    local token="$1"
    shift
    if [[ -z "$token" ]]; then
        "$@"
        return
    fi
    (
        token_file=$(mktemp) || exit 1
        trap 'rm -f "$token_file"' EXIT
        chmod 600 "$token_file" || exit 1
        printf '%s\n' "$token" >"$token_file" || exit 1
        "$@" --api-token-file "$token_file"
    )
}

# Always installs the repo's copy, replacing whatever is there. The rename matters:
# bash reads a running script as it goes, so overwriting it in place could make a
# running daemon execute garbage.
node_agent_install_files() {
    local src="$NODE_AGENT_LIB_DIR/node-agent.sh"
    local unit="$NODE_AGENT_LIB_DIR/mynodeone-node-agent.service"
    local tmp

    if [[ ! -f "$src" || ! -f "$unit" ]]; then
        echo "Node agent files not found in $NODE_AGENT_LIB_DIR" >&2
        return 1
    fi
    tmp=$(mktemp "${NODE_AGENT_BIN}.XXXXXX") || return 1
    if ! cp "$src" "$tmp" || ! chmod 755 "$tmp" || ! mv -f "$tmp" "$NODE_AGENT_BIN"; then
        rm -f "$tmp"
        return 1
    fi
    cp "$unit" "$NODE_AGENT_SYSTEMD_DIR/mynodeone-node-agent.service"
}

# The unit's ProtectSystem=strict and ProtectHome=read-only leave the Traefik
# config directory read-only unless it is listed. The unit lists the fixed
# locations; a directory under /home differs per host and ReadWritePaths does not
# expand variables, hence this drop-in. The "-" prefix keeps the unit starting if
# the directory is later removed; the agent then reports it can't write there.
node_agent_write_sandbox_dropin() {
    local traefik_dir="${1:-}"
    local dropin_dir="$NODE_AGENT_SYSTEMD_DIR/mynodeone-node-agent.service.d"
    local dropin="$dropin_dir/10-traefik.conf"

    if [[ -z "$traefik_dir" ]]; then
        rm -f "$dropin"
        return 0
    fi
    if [[ "$traefik_dir" != /* || "$traefik_dir" =~ [[:space:]] ]]; then
        echo "Traefik config directory must be an absolute path without spaces: $traefik_dir" >&2
        return 1
    fi
    # It has to exist before the unit starts or the sandbox skips it.
    mkdir -p "$traefik_dir" || return 1
    mkdir -p "$dropin_dir" || return 1
    printf '# Written by the node agent installer\n[Service]\nReadWritePaths=-%s\n' "$traefik_dir" >"$dropin"
}

# Prints API_TOKEN from an existing agent.env so a reconfigure doesn't lose it.
node_agent_existing_token() {
    [[ -f "$NODE_AGENT_ENV_FILE" ]] || return 0
    local line
    line=$(grep -E '^API_TOKEN=' "$NODE_AGENT_ENV_FILE" | tail -n1) || return 0
    line="${line#API_TOKEN=}"
    line="${line%\"}"
    line="${line#\"}"
    printf '%s' "$line"
}

# Prints one value from an existing agent.env.
node_agent_existing_value() {
    [[ -f "$NODE_AGENT_ENV_FILE" ]] || return 0
    local line
    line=$(grep -E "^$1=" "$NODE_AGENT_ENV_FILE" | tail -n1) || return 0
    line="${line#"$1"=}"
    line="${line%\"}"
    line="${line#\"}"
    printf '%s' "$line"
}

# node_agent_detect_traefik_dir [explicit-dir] [preferred-dir]
# Prints the directory the agent should manage routes in. A wrong answer leaves the live
# routes unmanaged, so it takes what is known first: the flag, the current setting, then
# the one directory holding the routes file, then the one directory that exists. With
# several candidates it refuses (returns 1) rather than guess. preferred-dir settles a
# tie only when no directory holds routes, so there are none to strand.
node_agent_detect_traefik_dir() {
    local explicit="${1:-}" preferred="${2:-}" current dir
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    current=$(node_agent_existing_value TRAEFIK_CONFIG_DIR)
    if [[ -n "$current" ]]; then
        printf '%s\n' "$current"
        return 0
    fi

    local -a holding=() existing=()
    # shellcheck disable=SC2086  # the list holds globs on purpose
    for dir in ${NODE_AGENT_TRAEFIK_SEARCH:-/home/*/traefik/config /root/traefik/config /etc/traefik/config}; do
        [[ -d "$dir" ]] || continue
        existing+=("$dir")
        [[ -f "$dir/mynodeone-routes.yml" ]] && holding+=("$dir")
    done

    local -a candidates=("${existing[@]+"${existing[@]}"}")
    ((${#holding[@]} == 0)) || candidates=("${holding[@]}")
    if ((${#holding[@]} == 0)) && [[ -n "$preferred" && -d "$preferred" ]]; then
        candidates=("$preferred")
    fi
    case "${#candidates[@]}" in
        0) printf '%s\n' "${NODE_AGENT_TRAEFIK_DEFAULT:-/etc/traefik/config}" ;;
        1) printf '%s\n' "${candidates[0]}" ;;
        *)
            {
                echo "Several Traefik config directories found:"
                printf '  %s\n' "${candidates[@]}"
                echo "Choose the one Traefik reads with --traefik-config-dir <dir>"
            } >&2
            return 1
            ;;
    esac
}

# node_agent_keep_unknown_settings <new-env-file>
# Appends settings from the current agent.env that the new one doesn't set, so a
# reconfigure doesn't drop something added by hand or by a later version.
node_agent_keep_unknown_settings() {
    local new="$1" extra
    [[ -f "$NODE_AGENT_ENV_FILE" ]] || return 0
    extra=$(awk '
        NR == FNR { if (match($0, /^[A-Za-z_][A-Za-z0-9_]*=/)) known[substr($0, 1, RLENGTH)] = 1; next }
        match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) && !(substr($0, 1, RLENGTH) in known)
    ' "$new" "$NODE_AGENT_ENV_FILE") || return 1
    if [[ -n "$extra" ]]; then
        printf '\n# Kept from the previous configuration\n%s\n' "$extra" >>"$new"
    fi
}

# agent.env is sourced by a root process, so nothing unexpected can go in it.
node_agent_valid_env_value() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._~+/=:@-]*$ ]]
}
