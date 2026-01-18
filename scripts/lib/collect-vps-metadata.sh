#!/bin/bash

###############################################################################
# VPS Metadata Collection Script
#
# Collects comprehensive metadata about a VPS edge node similar to cluster nodes.
# This script is designed to be run on the VPS itself.
#
# Usage:
#   ./collect-vps-metadata.sh [--output json|env]
###############################################################################

set -euo pipefail

# Output format (default: json)
OUTPUT_FORMAT="${1:-json}"

# Load configuration if available (to get VPS_LOCATION, NODE_NAME, etc.)
# Check multiple possible locations on the VPS
if [ -f "$HOME/.mynodeone/config.env" ]; then
    source "$HOME/.mynodeone/config.env"
elif [ -f "/root/.mynodeone/config.env" ]; then
    source "/root/.mynodeone/config.env"
elif [ -f "/etc/mynodeone/agent.env" ]; then
    # Fallback to agent config if main config is missing
    source "/etc/mynodeone/agent.env"
fi

# Detect OS information
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        echo "Unknown"
    fi
}

# Detect CPU information
detect_cpu() {
    if [ -f /proc/cpuinfo ]; then
        grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs
    else
        echo "Unknown CPU"
    fi
}

# Detect RAM
detect_ram() {
    if command -v free &>/dev/null; then
        free -h | awk '/^Mem:/ {print $2}'
    else
        echo "Unknown"
    fi
}

# Detect disk space
detect_disk() {
    df -h / | awk 'NR==2 {print $2}'
}

# Detect provider (heuristic-based)
detect_provider() {
    local provider="unknown"
    
    # Check DMI information
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
        local vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
        local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        
        case "$vendor" in
            *DigitalOcean*)
                provider="digitalocean"
                ;;
            *Amazon*)
                provider="aws"
                ;;
            *Google*)
                provider="gcp"
                ;;
            *Microsoft*)
                provider="azure"
                ;;
            *QEMU*|*KVM*)
                # Check for specific providers using hostname or other methods
                if echo "$product" | grep -qi "vultr"; then
                    provider="vultr"
                elif echo "$product" | grep -qi "linode"; then
                    provider="linode"
                elif echo "$product" | grep -qi "hetzner"; then
                    provider="hetzner"
                else
                    provider="kvm"
                fi
                ;;
        esac
    fi
    
    # Check for cloud-init metadata (DigitalOcean, AWS, etc.)
    if [ "$provider" = "unknown" ] && command -v curl &>/dev/null; then
        # DigitalOcean metadata
        if curl -s --connect-timeout 1 http://169.254.169.254/metadata/v1/id &>/dev/null; then
            provider="digitalocean"
        # AWS metadata
        elif curl -s --connect-timeout 1 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
            provider="aws"
        fi
    fi
    
    echo "$provider"
}

# Detect region/location (provider-specific)
detect_region() {
    local provider="$1"
    local region="unknown"
    
    case "$provider" in
        digitalocean)
            if command -v curl &>/dev/null; then
                region=$(curl -s --connect-timeout 2 http://169.254.169.254/metadata/v1/region 2>/dev/null || echo "unknown")
            fi
            ;;
        aws)
            if command -v curl &>/dev/null; then
                region=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "unknown")
            fi
            ;;
        *)
            # Use hostname or manual configuration
            region="${VPS_LOCATION:-unknown}"
            ;;
    esac
    
    echo "$region"
}

# Get public IP
get_public_ip() {
    local public_ip=""
    
    # Try multiple services
    if command -v curl &>/dev/null; then
        public_ip=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || \
                    curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
                    curl -s --connect-timeout 3 https://icanhazip.com 2>/dev/null || \
                    echo "")
    fi
    
    # Fallback to configured value
    if [ -z "$public_ip" ]; then
        public_ip="${VPS_PUBLIC_IP:-unknown}"
    fi
    
    echo "$public_ip"
}

# Get Tailscale IP
get_tailscale_ip() {
    if command -v tailscale &>/dev/null; then
        tailscale ip -4 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get Tailscale hostname
get_tailscale_hostname() {
    local ts_ip="$1"
    if [ "$ts_ip" != "unknown" ]; then
        echo "${ts_ip}.tailscale.net"
    else
        echo "unknown"
    fi
}

# Check if Traefik is installed
check_traefik() {
    if docker ps 2>/dev/null | grep -q traefik; then
        echo "true"
    else
        echo "false"
    fi
}

# Get Traefik version
get_traefik_version() {
    if docker ps 2>/dev/null | grep -q traefik; then
        docker inspect traefik 2>/dev/null | jq -r '.[0].Config.Image' | cut -d: -f2 || echo "unknown"
    else
        echo "not_installed"
    fi
}

# Get Docker version
get_docker_version() {
    if command -v docker &>/dev/null; then
        docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "unknown"
    else
        echo "not_installed"
    fi
}

# Get uptime in seconds
get_uptime_seconds() {
    cat /proc/uptime | awk '{print int($1)}'
}

# Main collection function
collect_metadata() {
    local node_name="${NODE_NAME:-$(hostname)}"
    local provider=$(detect_provider)
    local region=$(detect_region "$provider")
    local public_ip=$(get_public_ip)
    local tailscale_ip=$(get_tailscale_ip)
    local tailscale_hostname=$(get_tailscale_hostname "$tailscale_ip")
    local os=$(detect_os)
    local cpu=$(detect_cpu)
    local ram=$(detect_ram)
    local disk=$(detect_disk)
    local traefik_enabled=$(check_traefik)
    local traefik_version=$(get_traefik_version)
    local docker_version=$(get_docker_version)
    local uptime=$(get_uptime_seconds)
    local timestamp=$(date -Iseconds)
    
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        # Output as JSON
        jq -n \
            --arg name "$node_name" \
            --arg role "edge" \
            --arg location "$region" \
            --arg provider "$provider" \
            --arg public_ip "$public_ip" \
            --arg tailscale_ip "$tailscale_ip" \
            --arg tailscale_hostname "$tailscale_hostname" \
            --arg os "$os" \
            --arg cpu "$cpu" \
            --arg ram "$ram" \
            --arg disk "$disk" \
            --arg traefik_enabled "$traefik_enabled" \
            --arg traefik_version "$traefik_version" \
            --arg docker_version "$docker_version" \
            --argjson uptime "$uptime" \
            --arg timestamp "$timestamp" \
            '{
                name: $name,
                role: $role,
                location: $location,
                provider: $provider,
                public_ip: $public_ip,
                tailscale_ip: $tailscale_ip,
                tailscale_hostname: $tailscale_hostname,
                hardware: {
                    cpu: $cpu,
                    ram: $ram,
                    disk: $disk,
                    os: $os
                },
                traefik: {
                    enabled: ($traefik_enabled == "true"),
                    version: $traefik_version
                },
                installation: {
                    docker_version: $docker_version,
                    mynodeone_version: "1.5.0"
                },
                uptime_seconds: $uptime,
                last_updated: $timestamp
            }'
    else
        # Output as environment variables
        cat <<EOF
VPS_NODE_NAME="$node_name"
VPS_ROLE="edge"
VPS_LOCATION="$region"
VPS_PROVIDER="$provider"
VPS_PUBLIC_IP="$public_ip"
VPS_TAILSCALE_IP="$tailscale_ip"
VPS_TAILSCALE_HOSTNAME="$tailscale_hostname"
VPS_OS="$os"
VPS_CPU="$cpu"
VPS_RAM="$ram"
VPS_DISK="$disk"
VPS_TRAEFIK_ENABLED="$traefik_enabled"
VPS_TRAEFIK_VERSION="$traefik_version"
VPS_DOCKER_VERSION="$docker_version"
VPS_UPTIME_SECONDS="$uptime"
VPS_LAST_UPDATED="$timestamp"
EOF
    fi
}

# Run collection
collect_metadata
