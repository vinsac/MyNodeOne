#!/bin/bash

###############################################################################
# Optional: passwordless sudo for kubectl on the MyNodeOne control plane
#
# VPS and management node setup run 'sudo kubectl' over SSH, which needs this
# rule. It is powerful: 'sudo kubectl' can read every Secret and start privileged
# pods, so it is equal to root on every node for anyone who gets this account or
# its SSH key. For that reason it is only added with your consent.
#
# Usage: sudo ./scripts/setup/setup-control-plane-sudo.sh
#
# Non-interactive runs add or remove nothing unless told to:
#   MYNODEONE_SUDO_CONSENT=yes   Add or keep the rule
#   MYNODEONE_SUDO_CONSENT=no    Do not add it, and remove it if present
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/mynodeone}"
SETUP_COMMAND="sudo $(realpath "${BASH_SOURCE[0]}")"

# Detect actual user (works with or without sudo)
if [ -n "${SUDO_USER:-}" ]; then
    # Running with sudo - use SUDO_USER
    ACTUAL_USER="$SUDO_USER"
elif [ "$EUID" -eq 0 ]; then
    # Running as root without sudo - not allowed
    log_error "Do not run this script directly as root."
    log_error "Run as your regular user: ./scripts/setup/setup-control-plane-sudo.sh"
    log_error "Or with sudo: sudo ./scripts/setup/setup-control-plane-sudo.sh"
    exit 1
else
    # Running as regular user without sudo
    ACTUAL_USER="$USER"
fi

rule_exists() {
    sudo test -f "$SUDOERS_FILE"
}

# Prints yes, no or unset. Only an explicit answer can change anything.
decide_consent() {
    local answer=""

    case "${MYNODEONE_SUDO_CONSENT:-}" in
        yes|no)
            echo "$MYNODEONE_SUDO_CONSENT"
            return 0
            ;;
        "") ;;
        *)
            log_warn "Ignoring MYNODEONE_SUDO_CONSENT='$MYNODEONE_SUDO_CONSENT' (use yes or no)" >&2
            ;;
    esac

    if [ "${UNATTENDED:-0}" = "1" ] || [ ! -t 0 ]; then
        echo "unset"
        return 0
    fi

    {
        echo
        echo "Passwordless 'sudo kubectl' for user '$ACTUAL_USER' lets VPS and management"
        echo "node setup run over SSH without a password prompt."
        echo
        echo "Risk: 'sudo kubectl' can read every Secret and start privileged pods. Anyone"
        echo "who gets this account or its SSH key gets root on every node."
        echo
    } >&2

    if rule_exists; then
        read -r -p "A rule already exists. Remove it? [y/N]: " answer
        case "$answer" in
            [Yy]*) echo "no" ;;
            *) echo "yes" ;;
        esac
    else
        read -r -p "Allow it? [y/N]: " answer
        case "$answer" in
            [Yy]*) echo "yes" ;;
            *) echo "no" ;;
        esac
    fi
}

install_rule() {
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    cat > "$tmp" <<EOF
# MyNodeOne: passwordless sudo for kubectl, added with the user's consent.
# Remove with: MYNODEONE_SUDO_CONSENT=no $SETUP_COMMAND
# Generated: $(date)

# Allow specific environment variables to pass through sudo
# Required for VPS registration scripts
Defaults:$ACTUAL_USER env_keep += "SKIP_SSH_VALIDATION"

# Allow kubectl without password
$ACTUAL_USER ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl, /usr/bin/kubectl
EOF

    # Checked before install: a broken file in sudoers.d can lock out sudo entirely
    if ! sudo visudo -c -f "$tmp" >/dev/null; then
        log_error "Generated sudoers rule failed validation. Nothing was changed."
        exit 1
    fi

    sudo install -o root -g root -m 440 "$tmp" "$SUDOERS_FILE"
    log_success "Passwordless kubectl configured for $ACTUAL_USER"
}

consent=$(decide_consent)

case "$consent" in
    yes)
        install_rule
        log_info "To verify from a VPS or laptop: ssh $ACTUAL_USER@<control-plane-ip> 'sudo -n kubectl version --client'"
        ;;
    no)
        if rule_exists; then
            sudo rm -f "$SUDOERS_FILE"
            log_success "Removed the passwordless kubectl rule"
        else
            log_info "Passwordless kubectl not added"
        fi
        log_info "VPS and management node setup need this rule. To add it later: $SETUP_COMMAND"
        ;;
    unset)
        if rule_exists; then
            log_warn "Left the existing rule in $SUDOERS_FILE as it is (no consent answer given)."
            log_warn "It may still hold an old, unused scripts line. Review it with: $SETUP_COMMAND"
        else
            log_info "Passwordless kubectl not added (non-interactive run with no consent given)."
            log_info "VPS and management node setup need this rule. To add it: $SETUP_COMMAND"
        fi
        ;;
esac
