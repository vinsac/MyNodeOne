#!/bin/bash

###############################################################################
# MyNodeOne - Config Path Detection Utility
#
# Provides standardized config file detection for all MyNodeOne scripts.
# This ensures consistent config file discovery regardless of:
# - Installation location (not just home directory)
# - User running the script (sudo vs regular user)
# - Multi-user environments
#
# Usage:
#   source "$SCRIPT_DIR/../lib/config-paths.sh"  # From scripts/ subdirectories
#   source "$SCRIPT_DIR/lib/config-paths.sh"    # From scripts/ directory
#
# After sourcing, these functions are available:
#   - find_user_configs()     # Returns array of user config paths
#   - find_agent_config()     # Returns agent config path
#   - get_primary_user_config() # Returns the main user config path
###############################################################################

# Find all user config files on the system
# Returns an array of absolute paths to config.env files
find_user_configs() {
    local config_files=()
    
    # If running with sudo, check the actual user's home first
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        local actual_user_home
        actual_user_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "")
        if [[ -n "$actual_user_home" && -f "$actual_user_home/.mynodeone/config.env" ]]; then
            config_files+=("$actual_user_home/.mynodeone/config.env")
        fi
    fi
    
    # Check current user's HOME (if set)
    if [[ -n "${HOME:-}" && -f "$HOME/.mynodeone/config.env" ]]; then
        # Avoid duplicates
        local found=false
        for existing in "${config_files[@]}"; do
            if [[ "$existing" == "$HOME/.mynodeone/config.env" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            config_files+=("$HOME/.mynodeone/config.env")
        fi
    fi
    
    # Check all user homes in /home (for multi-user systems)
    for user_home in /home/*/.mynodeone/config.env; do
        if [[ -f "$user_home" ]]; then
            # Avoid duplicates
            local found=false
            for existing in "${config_files[@]}"; do
                if [[ "$existing" == "$user_home" ]]; then
                    found=true
                    break
                fi
            done
            if [[ "$found" == false ]]; then
                config_files+=("$user_home")
            fi
        fi
    done
    
    # Check root's home
    if [[ -f "/root/.mynodeone/config.env" ]]; then
        # Avoid duplicates
        local found=false
        for existing in "${config_files[@]}"; do
            if [[ "$existing" == "/root/.mynodeone/config.env" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            config_files+=("/root/.mynodeone/config.env")
        fi
    fi
    
    # Return the array
    echo "${config_files[@]}"
}

# Find the agent config file (always in /etc/mynodeone)
find_agent_config() {
    echo "/etc/mynodeone/agent.env"
}

# Get the primary user config file
# This tries to find the most appropriate config file for the current context
get_primary_user_config() {
    local configs=()
    read -ra configs <<< "$(find_user_configs)"
    
    # If running with sudo, prefer the actual user's config
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        local actual_user_home
        actual_user_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "")
        for config in "${configs[@]}"; do
            if [[ "$config" == "$actual_user_home/.mynodeone/config.env" ]]; then
                echo "$config"
                return 0
            fi
        done
    fi
    
    # Prefer current user's HOME if set
    if [[ -n "${HOME:-}" ]]; then
        for config in "${configs[@]}"; do
            if [[ "$config" == "$HOME/.mynodeone/config.env" ]]; then
                echo "$config"
                return 0
            fi
        done
    fi
    
    # Return the first found config
    if [[ ${#configs[@]} -gt 0 ]]; then
        echo "${configs[0]}"
        return 0
    fi
    
    # No config found
    return 1
}

# Check if a config file exists and is readable
config_exists() {
    local config_file="$1"
    [[ -f "$config_file" && -r "$config_file" ]]
}

# Logging functions for consistent output
log_info() {
    echo "[INFO] $*" >&2
}

log_success() {
    echo "[SUCCESS] $*" >&2
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    # Only show debug if DEBUG environment variable is set
    if [[ -n "${DEBUG:-}" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Get a value from a config file
# Usage: get_config_value "CLUSTER_DOMAIN" "/path/to/config.env"
# Priority: User config > Agent config (for cluster-wide settings)
get_config_value() {
    local key="$1"
    local config_file="${2:-}"
    
    # If no config file specified, find configs in proper priority order
    if [[ -z "$config_file" ]]; then
        # Priority 1: User config (highest priority for cluster settings)
        config_file=$(get_primary_user_config 2>/dev/null || echo "")
        log_debug "Primary user config: ${config_file:-'none'}"
        
        # Priority 2: Check other user configs if primary not found
        if [[ -z "$config_file" || ! -f "$config_file" ]]; then
            for user_home in /home/*/.mynodeone/config.env; do
                if [[ -f "$user_home" ]]; then
                    config_file="$user_home"
                    log_debug "Found alternative user config: $config_file"
                    break
                fi
            done
        fi
        
        # Priority 3: Root user config
        if [[ -z "$config_file" || ! -f "$config_file" ]]; then
            if [[ -f "/root/.mynodeone/config.env" ]]; then
                config_file="/root/.mynodeone/config.env"
                log_debug "Using root user config: $config_file"
            fi
        fi
        
        # Priority 4: Agent config (lowest priority, fallback only)
        if [[ -z "$config_file" || ! -f "$config_file" ]]; then
            config_file=$(find_agent_config)
            log_debug "Using agent config as fallback: ${config_file:-'none'}"
        fi
    fi
    
    # Extract the value
    if [[ -f "$config_file" ]]; then
        local value=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "")
        log_debug "get_config_value('$key') from '$config_file': '${value:-'not found'}'"
        echo "$value"
    else
        log_debug "No config file found for key: $key"
        echo ""
    fi
}

# List all found config files (for debugging)
list_config_files() {
    echo "=== MyNodeOne Config Files ==="
    echo ""
    
    echo "User Configs:"
    local configs=()
    read -ra configs <<< "$(find_user_configs)"
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo "  (none found)"
    else
        for config in "${configs[@]}"; do
            local owner
            owner=$(stat -c '%U' "$config" 2>/dev/null || echo "unknown")
            echo "  - $config (owner: $owner)"
        done
    fi
    
    echo ""
    echo "Agent Config:"
    local agent_config
    agent_config=$(find_agent_config)
    if [[ -f "$agent_config" ]]; then
        echo "  - $agent_config"
    else
        echo "  (not found)"
    fi
    
    echo ""
    echo "Primary User Config:"
    local primary
    primary=$(get_primary_user_config 2>/dev/null || echo "(none)")
    echo "  - $primary"
}

# Validate that we can find at least one config
validate_config_access() {
    local has_user_config=false
    local has_agent_config=false
    
    # Check user configs
    local configs=()
    read -ra configs <<< "$(find_user_configs)"
    if [[ ${#configs[@]} -gt 0 ]]; then
        has_user_config=true
    fi
    
    # Check agent config
    local agent_config
    agent_config=$(find_agent_config)
    if [[ -f "$agent_config" ]]; then
        has_agent_config=true
    fi
    
    if [[ "$has_user_config" == false && "$has_agent_config" == false ]]; then
        echo "WARNING: No MyNodeOne config files found" >&2
        echo "Expected locations:" >&2
        echo "  User: ~/.mynodeone/config.env" >&2
        echo "  Agent: /etc/mynodeone/agent.env" >&2
        return 1
    fi
    
    return 0
}

# Auto-validate when sourced (but don't fail, just warn)
validate_config_access || true
