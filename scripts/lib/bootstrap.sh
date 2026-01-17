#!/bin/bash

###############################################################################
# Universal Bootstrap Helper
#
# Source this from ANY script in the MyNodeOne tree to get PROJECT_ROOT.
# No directory counting needed - auto-discovers project root.
#
# Usage (works from any depth):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$(cd "$SCRIPT_DIR" && while [ ! -f "scripts/lib/bootstrap.sh" ] && [ "$PWD" != "/" ]; do cd ..; done && echo "$PWD/scripts/lib/bootstrap.sh")"
#
# Or simpler, use the find_and_source pattern below in your script.
###############################################################################

# Auto-discover PROJECT_ROOT by searching upward for project markers
_discover_project_root() {
    local search_dir="$1"
    
    while [ "$search_dir" != "/" ]; do
        # Check for project markers
        if [ -d "$search_dir/scripts" ] && [ -f "$search_dir/scripts/lib/project-root.sh" ]; then
            echo "$search_dir"
            return 0
        fi
        
        # Also check for .git directory as a marker
        if [ -d "$search_dir/.git" ] && [ -d "$search_dir/scripts" ]; then
            echo "$search_dir"
            return 0
        fi
        
        search_dir="$(dirname "$search_dir")"
    done
    
    echo "ERROR: Could not find MyNodeOne project root from: $1" >&2
    return 1
}

# Detect and set PROJECT_ROOT
if [ -z "${PROJECT_ROOT:-}" ]; then
    # Get the calling script's directory
    _caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    
    PROJECT_ROOT="$(_discover_project_root "$_caller_dir")"
    
    if [ -z "$PROJECT_ROOT" ]; then
        echo "FATAL: Bootstrap failed - could not locate project root" >&2
        exit 1
    fi
    
    export PROJECT_ROOT
    
    # Now source the full project-root.sh for validation and helper functions
    if [ -f "$PROJECT_ROOT/scripts/lib/project-root.sh" ]; then
        source "$PROJECT_ROOT/scripts/lib/project-root.sh"
    fi
fi
