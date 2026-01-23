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
CONFIG_LOADED=false

# If running with sudo, try to find the actual user's config
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    ACTUAL_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [ -f "$ACTUAL_USER_HOME/.mynodeone/config.env" ]; then
        source "$ACTUAL_USER_HOME/.mynodeone/config.env"
        CONFIG_LOADED=true
    fi
fi

# If not loaded yet, try standard locations
if [ "$CONFIG_LOADED" = false ]; then
    if [ -f "$HOME/.mynodeone/config.env" ]; then
        source "$HOME/.mynodeone/config.env"
    elif [ -f "/root/.mynodeone/config.env" ]; then
        source "/root/.mynodeone/config.env"
    elif [ -f "/etc/mynodeone/agent.env" ]; then
        # Fallback to agent config if main config is missing
        source "/etc/mynodeone/agent.env"
    fi
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
        local ram_bytes=$(free -b | awk '/^Mem:/ {print $2}')
        # Convert to human readable format
        if [ "$ram_bytes" -gt 1073741824 ]; then
            echo "$(echo "scale=1; $ram_bytes / 1073741824" | bc)Gi"
        elif [ "$ram_bytes" -gt 1048576 ]; then
            echo "$(echo "scale=1; $ram_bytes / 1048576" | bc)Mi"
        else
            echo "${ram_bytes}B"
        fi
    else
        echo "Unknown"
    fi
}

# Detect disk space
detect_disk() {
    if command -v df &>/dev/null; then
        df -h / | awk 'NR==2 {print $2}'
    else
        echo "Unknown"
    fi
}

# Detect provider
detect_provider() {
    local provider="unknown"
    
    # Check for common virtualization signatures
    if [ -f /sys/class/dmi/id/product_name ]; then
        local product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        case "$product" in
            *VirtualBox*|*vbox*)
                provider="virtualbox"
                ;;
            *VMware*|*vmware*)
                provider="vmware"
                ;;
            *KVM*|*QEMU*)
                provider="kvm"
                ;;
            *Xen*|*xen*)
                provider="xen"
                ;;
            *Hyper-V*|*microsoft*)
                provider="hyperv"
                ;;
            *DigitalOcean*)
                provider="digitalocean"
                ;;
            *Amazon*|*EC2*)
                provider="aws"
                ;;
            *Google*)
                provider="gcp"
                ;;
            *Hetzner*)
                provider="hetzner"
                ;;
            *)
                provider="kvm"
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
        public_ip=$(curl -s --connect-timeout 2 ifconfig.me 2>/dev/null || echo "")
    fi
    
    if [ -z "$public_ip" ] && command -v wget &>/dev/null; then
        public_ip=$(wget -qO- --timeout=2 ifconfig.me 2>/dev/null || echo "")
    fi
    
    echo "$public_ip"
}

# Get Tailscale IP
get_tailscale_ip() {
    if command -v tailscale &>/dev/null; then
        tailscale ip -4 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get uptime
get_uptime() {
    if [ -f /proc/uptime ]; then
        cat /proc/uptime | cut -d' ' -f1 | cut -d. -f1
    else
        echo "0"
    fi
}

# Get Docker version
get_docker_version() {
    if command -v docker &>/dev/null; then
        docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
    else
        echo ""
    fi
}

# Get node name (from config or hostname)
get_node_name() {
    echo "${NODE_NAME:-$(hostname)}"
}

# Main collection
collect_metadata() {
    local node_name=$(get_node_name)
    local provider=$(detect_provider)
    local region=$(detect_region "$provider")
    local public_ip="${VPS_PUBLIC_IP:-$(get_public_ip)}"
    local tailscale_ip="${TAILSCALE_IP:-$(get_tailscale_ip)}"
    local tailscale_hostname="${tailscale_ip}.tailscale.net"
    local cpu=$(detect_cpu)
    local ram=$(detect_ram)
    local disk=$(detect_disk)
    local os=$(detect_os)
    local docker_version=$(get_docker_version)
    local uptime=$(get_uptime)
    local mynodeone_version="1.5.0"
    
    # Check if Traefik is running
    local traefik_enabled="false"
    local traefik_version=""
    if command -v docker &>/dev/null; then
        if docker ps --format 'table {{.Names}}' | grep -q "^traefik$" 2>/dev/null; then
            traefik_enabled="true"
            traefik_version=$(docker exec traefik traefik version 2>/dev/null | grep -oE 'Version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' | cut -d: -f2 | xargs || echo "unknown")
        fi
    fi
    
    # Output in requested format
    case "$OUTPUT_FORMAT" in
        json)
            jq -n \
                --arg name "$node_name" \
                --arg role "edge" \
                --arg location "$region" \
                --arg provider "$provider" \
                --arg public_ip "$public_ip" \
                --arg tailscale_ip "$tailscale_ip" \
                --arg tailscale_hostname "$tailscale_hostname" \
                --argjson hardware "$(jq -n \
                    --arg cpu "$cpu" \
                    --arg ram "$ram" \
                    --arg disk "$disk" \
                    --arg os "$os" \
                    '{cpu: $cpu, ram: $ram, disk: $disk, os: $os}')" \
                --argjson traefik "$(jq -n \
                    --arg enabled "$traefik_enabled" \
                    --arg version "$traefik_version" \
                    '{enabled: ($enabled == "true"), version: $version}')" \
                --argjson installation "$(jq -n \
                    --arg docker_version "$docker_version" \
                    --arg mynodeone_version "$mynodeone_version" \
                    '{docker_version: $docker_version, mynodeone_version: $mynodeone_version}')" \
                --argjson uptime "$uptime" \
                --arg last_updated "$(date -Iseconds)" \
                '{
                    name: $name,
                    role: $role,
                    location: $location,
                    provider: $provider,
                    public_ip: $public_ip,
                    tailscale_ip: $tailscale_ip,
                    tailscale_hostname: $tailscale_hostname,
                    hardware: $hardware,
                    traefik: $traefik,
                    installation: $installation,
                    uptime_seconds: $uptime,
                    last_updated: $last_updated
                }'
            ;;
        env)
            cat <<EOF
VPS_NODE_NAME="$node_name"
VPS_ROLE="edge"
VPS_LOCATION="$region"
VPS_PROVIDER="$provider"
VPS_PUBLIC_IP="$public_ip"
VPS_TAILSCALE_IP="$tailscale_ip"
VPS_TAILSCALE_HOSTNAME="$tailscale_hostname"
VPS_CPU="$cpu"
VPS_RAM="$ram"
VPS_DISK="$disk"
VPS_OS="$os"
VPS_TRAEFIK_ENABLED="$traefik_enabled"
VPS_TRAEFIK_VERSION="$traefik_version"
VPS_DOCKER_VERSION="$docker_version"
VPS_MYNODEONE_VERSION="$mynodeone_version"
VPS_UPTIME="$uptime"
EOF
            ;;
        *)
            echo "Unknown output format: $OUTPUT_FORMAT"
            echo "Usage: $0 [json|env]"
            exit 1
            ;;
    esac
}

# Run collection
collect_metadata
