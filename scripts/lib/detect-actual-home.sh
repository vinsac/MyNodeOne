#!/bin/bash

###############################################################################
# Detect Actual User and Home Directory
# 
# This library provides a single source of truth for detecting the actual user
# and their home directory, even when scripts are run with sudo.
#
# Usage:
#   source "$SCRIPT_DIR/lib/detect-actual-home.sh"
#   # Then use $ACTUAL_USER and $ACTUAL_HOME
###############################################################################

# Detect actual user (not the sudo-elevated user)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"

# Detect actual user's home directory
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # Running normally (either as regular user or as root directly)
    ACTUAL_HOME="$HOME"
fi

# Export for use in subshells
export ACTUAL_USER
export ACTUAL_HOME

# Config directory is always in actual user's home
CONFIG_DIR="$ACTUAL_HOME/.mynodeone"
CONFIG_FILE="$CONFIG_DIR/config.env"

export CONFIG_DIR
export CONFIG_FILE
