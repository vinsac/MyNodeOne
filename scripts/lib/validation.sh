#!/bin/bash

###############################################################################
# MyNodeOne - Input Validation Library
# 
# Comprehensive validation functions for all user inputs
# Prevents invalid configurations and improves resilience
###############################################################################

# Validate IP address format
validate_ip() {
    local ip="$1"
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! $ip =~ $ip_regex ]]; then
        return 1
    fi
    
    # Check each octet is 0-255
    IFS='.' read -ra OCTETS <<< "$ip"
    for octet in "${OCTETS[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    
    return 0
}

# Validate Tailscale IP address (must be in 100.x.x.x range)
validate_tailscale_ip() {
    local ip="$1"
    
    if ! validate_ip "$ip"; then
        return 1
    fi
    
    # Tailscale IPs are in 100.64.0.0/10 range (CGNAT)
    # First octet must be 100, second must be 64-127
    IFS='.' read -ra OCTETS <<< "$ip"
    if [ "${OCTETS[0]}" -ne 100 ]; then
        return 1
    fi
    
    if [ "${OCTETS[1]}" -lt 64 ] || [ "${OCTETS[1]}" -gt 127 ]; then
        return 1
    fi
    
    return 0
}

# Validate cluster name (Kubernetes-compatible)
validate_cluster_name() {
    local name="$1"
    
    # Empty check
    if [ -z "$name" ]; then
        return 1
    fi
    
    # Length check (max 63 characters)
    if [ ${#name} -gt 63 ]; then
        return 1
    fi
    
    # Kubernetes label value validation
    # Must: start with alphanumeric, contain only [a-z0-9-], end with alphanumeric
    if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate domain name (DNS-compatible)
validate_domain() {
    local domain="$1"
    
    # Empty check
    if [ -z "$domain" ]; then
        return 1
    fi
    
    # Length check
    if [ ${#domain} -gt 253 ]; then
        return 1
    fi
    
    # RFC 1123 hostname/domain validation
    # Lowercase letters, numbers, hyphens, dots
    # Each label max 63 chars, can't start/end with hyphen
    if [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate node name (hostname)
validate_node_name() {
    local name="$1"
    
    # Empty check
    if [ -z "$name" ]; then
        return 1
    fi
    
    # Length check (max 63 characters)
    if [ ${#name} -gt 63 ]; then
        return 1
    fi
    
    # Hostname validation: lowercase letters, numbers, hyphens
    # Can't start or end with hyphen
    if [[ "$name" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate disk path
validate_disk_path() {
    local disk="$1"
    
    # Must start with /dev/
    if [[ ! "$disk" =~ ^/dev/ ]]; then
        return 1
    fi
    
    # Must exist as block device
    if [ ! -b "$disk" ]; then
        return 1
    fi
    
    return 0
}

# Validate number (positive integer)
validate_positive_integer() {
    local num="$1"
    
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Validate URL
validate_url() {
    local url="$1"
    
    if [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Check if value is empty
is_empty() {
    local value="$1"
    if [ -z "$value" ] || [ "$value" = "" ]; then
        return 0
    else
        return 1
    fi
}

# Sanitize input (remove dangerous characters)
sanitize_input() {
    local input="$1"
    # Remove: backticks, $(), ${}, semicolons, pipes, redirects, quotes
    echo "$input" | sed 's/[$`();|<>&"'\'']//g'
}

# Validate input with retries
validate_input_with_retry() {
    local prompt="$1"
    local validation_func="$2"
    local max_attempts="${3:-3}"
    local value=""
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        read -p "$prompt: " value
        
        if $validation_func "$value"; then
            echo "$value"
            return 0
        else
            echo "Invalid input. Please try again (attempt $attempt/$max_attempts)." >&2
            attempt=$((attempt + 1))
        fi
    done
    
    echo "Maximum attempts reached. Aborting." >&2
    return 1
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Check if port is available
is_port_available() {
    local port="$1"
    ! netstat -tuln 2>/dev/null | grep -q ":$port " && ! ss -tuln 2>/dev/null | grep -q ":$port "
}

# Validate network connectivity to host
validate_network_connectivity() {
    local host="$1"
    local timeout="${2:-5}"
    
    if timeout "$timeout" ping -c 1 "$host" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if disk has enough space (in GB)
has_enough_disk_space() {
    local path="$1"
    local required_gb="$2"
    
    local available_gb=$(df -BG "$path" | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_gb" -ge "$required_gb" ]; then
        return 0
    else
        return 1
    fi
}

# Check if system has enough RAM (in GB)
has_enough_ram() {
    local required_gb="$1"
    local available_gb=$(free -g | awk '/^Mem:/{print $2}')
    
    if [ "$available_gb" -ge "$required_gb" ]; then
        return 0
    else
        return 1
    fi
}

# Validate that a service is running
is_service_running() {
    local service="$1"
    systemctl is-active --quiet "$service"
}

# Validate file is readable
is_file_readable() {
    local file="$1"
    [ -f "$file" ] && [ -r "$file" ]
}

# Validate directory is writable
is_directory_writable() {
    local dir="$1"
    [ -d "$dir" ] && [ -w "$dir" ]
}
