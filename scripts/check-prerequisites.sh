#!/bin/bash

###############################################################################
# Check MyNodeOne Installation Prerequisites
#
# Run this script to verify that prerequisites are met before installation.
#
# Usage:
#   ./scripts/check-prerequisites.sh vps <control-plane-ip> [ssh-user]
#   ./scripts/check-prerequisites.sh management <control-plane-ip> [ssh-user]
#   ./scripts/check-prerequisites.sh control-plane
#
# Examples:
#   ./scripts/check-prerequisites.sh vps 100.67.210.15 vinaysachdeva
#   ./scripts/check-prerequisites.sh management 100.67.210.15
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the preflight checks library
source "$SCRIPT_DIR/lib/preflight-checks.sh"

# Show usage
show_usage() {
    echo "Usage: $0 <type> [control-plane-ip] [ssh-user]"
    echo ""
    echo "Types:"
    echo "  vps              Check prerequisites for VPS edge node"
    echo "  management       Check prerequisites for management laptop"
    echo "  control-plane    Check prerequisites for control plane"
    echo ""
    echo "Examples:"
    echo "  $0 vps 100.67.210.15 vinaysachdeva"
    echo "  $0 management 100.67.210.15"
    echo "  $0 control-plane"
    echo ""
}

# Get absolute script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect actual user and home directory
source "$SCRIPT_DIR/lib/detect-actual-home.sh"

# Source preflight checks library
source "$SCRIPT_DIR/lib/preflight-checks.sh"

# Parse arguments
CHECK_TYPE="$1"
CONTROL_PLANE_IP="${2:-}"
SSH_USER="${3:-$(whoami)}"

# Load config if exists (CONFIG_FILE set by detect-actual-home.sh)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-${CONTROL_PLANE_IP:-}}"
    SSH_USER="${SSH_USER:-${CONTROL_PLANE_SSH_USER:-$(whoami)}}"
fi

# Run checks
case "$CHECK_TYPE" in
    vps|management)
        if [ -z "$CONTROL_PLANE_IP" ]; then
            echo "Error: Control plane IP required for $CHECK_TYPE checks"
            echo ""
            show_usage
            exit 1
        fi
        
        run_preflight_checks "$CHECK_TYPE" "$CONTROL_PLANE_IP" "$SSH_USER"
        ;;
        
    control-plane)
        run_preflight_checks "control-plane"
        ;;
        
    *)
        echo "Error: Unknown check type: $CHECK_TYPE"
        echo ""
        show_usage
        exit 1
        ;;
esac

exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo "✅ Ready to proceed with $CHECK_TYPE installation!"
else
    echo "❌ Prerequisites not met. Fix the issues above before installing."
fi

exit $exit_code
