#!/bin/bash

###############################################################################
# MyNodeOne - Project Root Detection Utility
# 
# Provides standardized PROJECT_ROOT detection for all scripts.
# This ensures consistent path resolution regardless of where the script is called from.
#
# Usage:
#   source "$SCRIPT_DIR/../lib/project-root.sh"  # From scripts/ subdirectories
#   source "$SCRIPT_DIR/lib/project-root.sh"    # From scripts/ directory
#   source "$SCRIPT_DIR/../../lib/project-root.sh" # From apps/ subdirectories
#
# After sourcing, $PROJECT_ROOT will be available as the absolute path to MyNodeOne root.
###############################################################################

# Detect project root using multiple fallback methods
detect_project_root() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    
    # Method 1: From scripts/ subdirectory (most common)
    if [[ "$script_dir" == */scripts/* ]]; then
        echo "$(cd "$script_dir/../.." && pwd)"
        return 0
    fi
    
    # Method 2: From scripts/ directory itself
    if [[ "$script_dir" == */scripts ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 3: From apps/ subdirectory
    if [[ "$script_dir" == */apps/* ]]; then
        echo "$(cd "$script_dir/../.." && pwd)"
        return 0
    fi
    
    # Method 4: From setup/ subdirectory
    if [[ "$script_dir" == */setup ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 5: From lib/ directory
    if [[ "$script_dir" == */lib ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 6: From operations/ subdirectory
    if [[ "$script_dir" == */operations ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 7: From domains/ subdirectory
    if [[ "$script_dir" == */domains ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 8: From storage/ subdirectory
    if [[ "$script_dir" == */storage/* ]]; then
        echo "$(cd "$script_dir/../.." && pwd)"
        return 0
    fi
    
    # Method 9: From nodes/ subdirectory
    if [[ "$script_dir" == */nodes ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
        return 0
    fi
    
    # Method 10: Generic fallback - go up until we find .git or scripts/ directory
    local current_dir="$script_dir"
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if [ -d "$current_dir/scripts" ] || [ -d "$current_dir/.git" ] || [ -f "$current_dir/README.md" ]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
        ((attempt++))
    done
    
    # Method 11: Last resort - assume we're in MyNodeOne and use pwd
    echo "$(pwd)"
    return 0
}

# Set PROJECT_ROOT for immediate use
if [ -z "${PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$(detect_project_root)"
    export PROJECT_ROOT
fi

# Convenience function for other scripts to use
get_project_root() {
    echo "$PROJECT_ROOT"
}

# Validate that we found the right project root
validate_project_root() {
    if [ ! -d "$PROJECT_ROOT/scripts" ] && [ ! -f "$PROJECT_ROOT/README.md" ]; then
        echo "WARNING: Project root validation failed for: $PROJECT_ROOT" >&2
        echo "This might not be the MyNodeOne project root directory." >&2
        return 1
    fi
    return 0
}

# Auto-validate when sourced
validate_project_root || true
