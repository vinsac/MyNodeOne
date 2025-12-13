#!/bin/bash

###############################################################################
# Fetch Cluster Info from Control Plane
# 
# This script fetches kubeconfig and cluster information from the control plane
# Used during management laptop setup to auto-detect cluster configuration
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect actual user and their home directory (even when run with sudo)
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    # Running under sudo - use actual user's home directory and SSH keys
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    SSH_CMD="sudo -u $SUDO_USER ssh"
else
    # Running normally
    ACTUAL_HOME="$HOME"
    SSH_CMD="ssh"
fi

CONFIG_DIR="$ACTUAL_HOME/.mynodeone"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

fetch_cluster_info() {
    local control_plane_ip=""
    local ssh_user=""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📡 Fetching Cluster Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "To auto-detect your cluster settings, I need your control plane details"
    echo

    # Prompt for control plane IP
    while [ -z "$control_plane_ip" ]; do
        read -p "? Control plane Tailscale IP (e.g., 100.x.x.x): " control_plane_ip
        if [ -z "$control_plane_ip" ]; then
            log_warn "IP address is required"
        elif ! [[ "$control_plane_ip" =~ ^100\. ]]; then
            log_warn "Expected a Tailscale IP starting with 100."
            control_plane_ip=""
        fi
    done

    # Prompt for SSH username
    read -p "? SSH username on control plane [root]: " ssh_user
    ssh_user="${ssh_user:-root}"
    echo

    log_info "Connecting to control plane and fetching configuration..."
    log_info "You may be prompted for your SSH password."
    echo
    
    # Create temp file for output
    local temp_output=$(mktemp)
    local temp_kubeconfig=$(mktemp)
    
    # Cleanup on exit
    trap "rm -f '$temp_output' '$temp_kubeconfig' 2>/dev/null" RETURN
    
    # Run a single SSH command that collects all the data we need
    # This way user only enters SSH password ONCE
    # The remote script checks for passwordless sudo first
    if ! $SSH_CMD -o ConnectTimeout=15 "$ssh_user@$control_plane_ip" bash << 'REMOTE_EOF' > "$temp_output" 2>&1
#!/bin/bash
# This script runs on the CONTROL PLANE
# It collects all config and outputs in a parseable format

echo "===MARKER_START==="

# Check if we have passwordless sudo access
if sudo -n true 2>/dev/null; then
    echo "SUDO_TYPE=passwordless"
else
    echo "===NEEDS_SUDO_PASSWORD==="
    exit 1
fi

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || echo "")
echo "TAILSCALE_IP=$TAILSCALE_IP"

# Get cluster info from config.env (single source of truth)
# This is the same file VPS installation reads from
CONFIG_FILE=""

# First try $HOME (most reliable)
if [ -f "$HOME/.mynodeone/config.env" ]; then
    CONFIG_FILE="$HOME/.mynodeone/config.env"
else
    # Fallback: search common locations
    for cfg in /home/*/.mynodeone/config.env /root/.mynodeone/config.env; do
        if [ -f "$cfg" ] 2>/dev/null; then
            CONFIG_FILE="$cfg"
            break
        fi
    done
fi

# Debug: show what we found
echo "DEBUG_HOME=$HOME"
echo "DEBUG_CONFIG_EXISTS=$([ -f "$HOME/.mynodeone/config.env" ] && echo 'yes' || echo 'no')"

if [ -n "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "CONFIG_FILE=$CONFIG_FILE"
fi
echo "CLUSTER_NAME=${CLUSTER_NAME:-}"
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-}"

# Get repo path from config or detect it
REPO_PATH="${CONTROL_PLANE_REPO_PATH:-}"
if [ -z "$REPO_PATH" ]; then
    # Try to find MyNodeOne directory
    for p in /home/*/MyNodeOne /root/MyNodeOne /opt/MyNodeOne; do
        if [ -d "$p" ]; then
            REPO_PATH="$p"
            break
        fi
    done
fi
echo "REPO_PATH=$REPO_PATH"

# Get API token
API_TOKEN=""
if [ -f /etc/mynodeone/api-token ]; then
    API_TOKEN=$(sudo cat /etc/mynodeone/api-token 2>/dev/null || echo "")
fi
echo "API_TOKEN=$API_TOKEN"

# Get kubeconfig (base64 encoded to preserve formatting)
echo "===KUBECONFIG_START==="
sudo cat /etc/rancher/k3s/k3s.yaml 2>/dev/null | base64
echo "===KUBECONFIG_END==="

echo "===MARKER_END==="
REMOTE_EOF
    then
        # SSH command failed - check why
        if grep -q "===NEEDS_SUDO_PASSWORD===" "$temp_output" 2>/dev/null; then
            log_info "Passwordless sudo not available on control plane."
            log_info "Prompting for sudo password..."
            echo
            
            # Prompt for sudo password
            read -s -p "Enter sudo password for $ssh_user on control plane: " sudo_pass
            echo
            echo
            
            # Retry with sudo password
            # Use -tt for pseudo-terminal allocation needed for sudo password
            if ! $SSH_CMD -o ConnectTimeout=15 -tt "$ssh_user@$control_plane_ip" bash << REMOTE_SUDO_EOF > "$temp_output" 2>&1
#!/bin/bash
echo "$sudo_pass" | sudo -S true 2>/dev/null
if [ \$? -ne 0 ]; then
    echo "===SUDO_FAILED==="
    exit 1
fi

echo "===MARKER_START==="
echo "SUDO_TYPE=password"

TAILSCALE_IP=\$(tailscale ip -4 2>/dev/null | head -n1 || echo "")
echo "TAILSCALE_IP=\$TAILSCALE_IP"

# Get cluster info from config.env (single source of truth)
CONFIG_FILE=""

# First try \$HOME (most reliable)
if [ -f "\$HOME/.mynodeone/config.env" ]; then
    CONFIG_FILE="\$HOME/.mynodeone/config.env"
else
    # Fallback: search common locations
    for cfg in /home/*/.mynodeone/config.env /root/.mynodeone/config.env; do
        if [ -f "\$cfg" ] 2>/dev/null; then
            CONFIG_FILE="\$cfg"
            break
        fi
    done
fi

# Debug: show what we found
echo "DEBUG_HOME=\$HOME"
echo "DEBUG_CONFIG_EXISTS=\$([ -f \"\$HOME/.mynodeone/config.env\" ] && echo 'yes' || echo 'no')"

if [ -n "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
    echo "CONFIG_FILE=\$CONFIG_FILE"
fi
echo "CLUSTER_NAME=\${CLUSTER_NAME:-}"
echo "CLUSTER_DOMAIN=\${CLUSTER_DOMAIN:-}"

# Get repo path from config or detect it
REPO_PATH="\${CONTROL_PLANE_REPO_PATH:-}"
if [ -z "\$REPO_PATH" ]; then
    for p in /home/*/MyNodeOne /root/MyNodeOne /opt/MyNodeOne; do
        if [ -d "\$p" ]; then
            REPO_PATH="\$p"
            break
        fi
    done
fi
echo "REPO_PATH=\$REPO_PATH"

API_TOKEN=""
if [ -f /etc/mynodeone/api-token ]; then
    API_TOKEN=\$(echo "$sudo_pass" | sudo -S cat /etc/mynodeone/api-token 2>/dev/null || echo "")
fi
echo "API_TOKEN=\$API_TOKEN"

echo "===KUBECONFIG_START==="
echo "$sudo_pass" | sudo -S cat /etc/rancher/k3s/k3s.yaml 2>/dev/null | base64
echo "===KUBECONFIG_END==="

echo "===MARKER_END==="
REMOTE_SUDO_EOF
            then
                if grep -q "===SUDO_FAILED===" "$temp_output" 2>/dev/null; then
                    log_error "Sudo password incorrect"
                    return 1
                fi
                log_error "Failed to connect to control plane"
                cat "$temp_output" 2>/dev/null | grep -v "===" | head -5
                return 1
            fi
        else
            log_error "SSH connection failed"
            cat "$temp_output" 2>/dev/null | head -5
            return 1
        fi
    fi
    
    # Parse the output
    if ! grep -q "===MARKER_START===" "$temp_output" || ! grep -q "===MARKER_END===" "$temp_output"; then
        log_error "Failed to get valid response from control plane"
        cat "$temp_output" 2>/dev/null | head -10
        return 1
    fi
    
    log_success "Connected to control plane"
    
    # Debug: Show raw output for troubleshooting
    if [ "${DEBUG:-}" = "1" ]; then
        log_info "DEBUG: Raw output from control plane:"
        cat "$temp_output"
        echo "---END DEBUG---"
    fi
    
    # Extract values from output - handle both with and without terminal escape sequences
    # The output may have terminal control characters from -tt, so we clean aggressively
    local config_file=$(grep "CONFIG_FILE=" "$temp_output" | tail -1 | sed 's/.*CONFIG_FILE=//' | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g')
    local cluster_name=$(grep "CLUSTER_NAME=" "$temp_output" | tail -1 | sed 's/.*CLUSTER_NAME=//' | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g')
    local cluster_domain=$(grep "CLUSTER_DOMAIN=" "$temp_output" | tail -1 | sed 's/.*CLUSTER_DOMAIN=//' | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g')
    local repo_path=$(grep "REPO_PATH=" "$temp_output" | tail -1 | sed 's/.*REPO_PATH=//' | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g')
    local api_token=$(grep "API_TOKEN=" "$temp_output" | tail -1 | sed 's/.*API_TOKEN=//' | tr -d '\r\n' | sed 's/\x1b\[[0-9;]*m//g')
    
    # Extract and decode kubeconfig
    local kubeconfig_b64=$(sed -n '/===KUBECONFIG_START===/,/===KUBECONFIG_END===/p' "$temp_output" | grep -v "===" | tr -d '\r\n')
    
    # Log where config was found
    if [ -n "$config_file" ]; then
        log_info "Config source: $config_file (on control plane)"
    else
        log_warn "No config.env found on control plane"
    fi
    
    if [ -z "$cluster_name" ] || [ -z "$cluster_domain" ]; then
        log_error "Could not read cluster configuration from control plane"
        log_info "Make sure ~/.mynodeone/config.env exists on control plane"
        log_info "DEBUG: Showing raw output for diagnosis:"
        echo "--- START RAW OUTPUT ---"
        cat "$temp_output" | head -30
        echo "--- END RAW OUTPUT ---"
        return 1
    fi
    
    log_success "Cluster info retrieved from config.env:"
    echo "  • Cluster Name: $cluster_name"
    echo "  • Domain: ${cluster_domain}.local"
    echo "  • Control Plane: $control_plane_ip"
    if [ -n "$api_token" ]; then
        echo "  • API Token: ****${api_token: -4}"
    fi
    
    # Decode and install kubeconfig
    if [ -n "$kubeconfig_b64" ]; then
        log_info "Installing kubeconfig..."
        mkdir -p "$ACTUAL_HOME/.kube"
        echo "$kubeconfig_b64" | base64 -d | sed "s/127.0.0.1/$control_plane_ip/g" > "$ACTUAL_HOME/.kube/config"
        chmod 600 "$ACTUAL_HOME/.kube/config"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.kube/config"
        log_success "Kubeconfig installed to $ACTUAL_HOME/.kube/config"
    else
        log_warn "Could not retrieve kubeconfig"
    fi
    
    # Save configuration
    log_info "Saving configuration..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.env" << EOF
# MyNodeOne Configuration
# Auto-generated on $(date)
# Fetched from control plane: $control_plane_ip

CLUSTER_NAME="$cluster_name"
CLUSTER_DOMAIN="$cluster_domain"
CONTROL_PLANE_IP="$control_plane_ip"
CONTROL_PLANE_SSH_USER="$ssh_user"
EOF

    if [ -n "$repo_path" ]; then
        echo "CONTROL_PLANE_REPO_PATH=\"$repo_path\"" >> "$CONFIG_DIR/config.env"
    fi
    
    if [ -n "$api_token" ]; then
        echo "API_TOKEN=\"$api_token\"" >> "$CONFIG_DIR/config.env"
    fi
    
    chmod 600 "$CONFIG_DIR/config.env"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$CONFIG_DIR"
    
    log_success "Configuration saved to $CONFIG_DIR/config.env"
    echo
    
    return 0
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    fetch_cluster_info
fi
