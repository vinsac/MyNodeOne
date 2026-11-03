#!/bin/bash

###############################################################################
# MyNodeOne Control Plane Bootstrap Script
# 
# This script sets up the control plane node with:
# - K3s server (lightweight Kubernetes)
# - Helm package manager
# - Cert-Manager for SSL certificates
# - Traefik ingress controller
# - Longhorn distributed storage
# - MinIO object storage
# - Prometheus + Grafana + Loki monitoring
# - ArgoCD for GitOps
#
# IMPORTANT: Run ./scripts/installation/interactive-setup.sh first!
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../scripts/lib/project-root.sh" 2>/dev/null

# ACTUAL_USER and ACTUAL_HOME are inherited from the main mynodeone script
# If not set (standalone execution), detect them here
if [ -z "${ACTUAL_USER:-}" ]; then
    export ACTUAL_USER="${SUDO_USER:-$(whoami)}"
fi

if [ -z "${ACTUAL_HOME:-}" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        export ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    else
        export ACTUAL_HOME="$HOME"
    fi
fi

# CONFIG_FILE is also inherited, but we provide a fallback for standalone execution
: "${CONFIG_FILE:=$ACTUAL_HOME/.mynodeone/config.env}"

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Configuration not found!${NC}"
    echo "Expected location: $CONFIG_FILE"
    echo "Please run: ./scripts/installation/interactive-setup.sh first"
    exit 1
fi

source "$CONFIG_FILE"

# Export key variables to be available in sub-scripts
export CLUSTER_NAME
export CLUSTER_DOMAIN
export NODE_NAME
export NODE_LOCATION

# Load centralized version configuration
source "$PROJECT_ROOT/scripts/lib/versions.sh"

# Set kubeconfig for K3s (so kubectl and helm work)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# K3s locations. Overridable so the key-retention logic can be tested against a
# temp directory; nothing sets them in a normal install.
: "${K3S_CONFIG_DIR:=/etc/rancher/k3s}"
: "${K3S_DATA_DIR:=/var/lib/rancher/k3s}"
: "${K3S_BINARY:=/usr/local/bin/k3s}"
: "${K3S_SERVICE_UNIT:=/etc/systemd/system/k3s.service}"
: "${SECRETS_BACKUP_DIR:=/var/lib/mynodeone/secrets-backup}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Retry logic for network operations
retry_command() {
    local max_attempts="$1"
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Command failed (attempt $attempt/$max_attempts). Retrying in 5 seconds..."
            sleep 5
        fi
        attempt=$((attempt + 1))
    done
    
    log_error "Command failed after $max_attempts attempts: $cmd"
    return 1
}

# Components that failed but didn't stop the install. main exits non-zero at the end
# if any are listed, so the rest of the cluster still gets set up on the way there.
declare -a FAILED_COMPONENTS=()

component_failed() {
    local name="$1" item
    for item in "${FAILED_COMPONENTS[@]}"; do
        [ "$item" = "$name" ] && return 0
    done
    FAILED_COMPONENTS+=("$name")
}

# Installs or upgrades a chart and returns helm's exit code. --timeout is what keeps a
# stuck rollout (the reason this wrapper exists: an install used to hang for good on
# slow DNS or a Pending PVC) from blocking forever, and a timeout comes back as a failure.
#
# Running pods prove nothing on a re-run, because the old version's pods are still up.
# This wrapper used to treat them as success and kill helm, which left the release
# stuck in pending-upgrade. A rollout that's slow is reported, and helm is left to finish.
helm_install_safe() {
    local release_name="$1"
    local chart="$2"
    local namespace="$3"
    shift 3

    log_info "Installing $release_name (waits for it to be ready, up to 10m)..."

    local rc=0
    helm upgrade --install "$release_name" "$chart" \
        --namespace "$namespace" \
        --wait \
        --timeout 10m \
        "$@" || rc=$?

    if [ "$rc" -eq 0 ]; then
        log_success "$release_name installed successfully"
        return 0
    fi

    log_error "$release_name: helm exited with code $rc. It was not installed or upgraded cleanly."
    log_info "Pods in $namespace that aren't Running or Completed:"
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -vE '[[:space:]](Running|Completed)[[:space:]]' || true

    local status=""
    status=$(helm status "$release_name" -n "$namespace" 2>/dev/null | awk '/^STATUS:/ { print $2; exit }') || true
    if [[ "$status" == pending-* ]]; then
        log_warn "The $release_name release is stuck in $status, which blocks every later upgrade."
        log_warn "Check it, then roll back: helm history $release_name -n $namespace; helm rollback $release_name -n $namespace"
    fi
    return "$rc"
}

# Check DNS connectivity before operations
check_dns() {
    log_info "Verifying DNS connectivity..."
    
    # Test with Google DNS as fallback
    if ! timeout 5 nslookup github.com 8.8.8.8 > /dev/null 2>&1; then
        log_warn "DNS issues detected, this may cause delays"
        return 1
    fi
    
    log_success "DNS is working"
    return 0
}

# Prompt for user confirmation
prompt_confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    # Check if running in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        response="$default"
        echo -e "${BLUE}[INFO]${NC} $prompt [using default: $default]"
    elif [ "$default" = "y" ]; then
        read -p "$(echo -e ${GREEN}?)${NC}) $prompt [Y/n]: " response
        response="${response:-y}"
    else
        read -p "$(echo -e ${GREEN}?)${NC}) $prompt [y/N]: " response
        response="${response:-n}"
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# Generic failsafe installation function
# Usage: install_tool_failsafe "tool_name" "snap_package" "curl_script_url" "version" "binary_url_template"
install_tool_failsafe() {
    local TOOL_NAME=$1
    local SNAP_PACKAGE=$2
    local CURL_SCRIPT=$3
    local VERSION=$4
    local BINARY_URL_TEMPLATE=$5
    
    log_info "Installing $TOOL_NAME..."
    
    # Check if already installed
    if command -v "$TOOL_NAME" &> /dev/null; then
        local CURRENT_VERSION=$("$TOOL_NAME" version --short 2>/dev/null || "$TOOL_NAME" --version 2>/dev/null || echo "unknown")
        log_warn "$TOOL_NAME already installed ($CURRENT_VERSION), skipping..."
        return 0
    fi
    
    log_info "Attempting $TOOL_NAME installation with multiple fallback methods..."
    
    # Method 1: Try snap (if available)
    if [ -n "$SNAP_PACKAGE" ] && command -v snap &> /dev/null; then
        log_info "Method 1: Trying snap installation..."
        if snap install "$SNAP_PACKAGE" --classic 2>/dev/null; then
            log_success "$TOOL_NAME installed via snap"
            return 0
        else
            log_warn "Snap installation failed, trying next method..."
        fi
    fi
    
    # Method 2: Official script (if provided)
    if [ -n "$CURL_SCRIPT" ]; then
        log_info "Method 2: Trying official installation script..."
        if curl -fsSL "$CURL_SCRIPT" | bash; then
            log_success "$TOOL_NAME installed via official script"
            return 0
        else
            log_warn "Official script failed, trying next method..."
        fi
    fi
    
    # Method 3: Direct binary download (if template provided)
    if [ -n "$BINARY_URL_TEMPLATE" ]; then
        log_info "Method 3: Trying direct binary download..."
        
        local ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l) ARCH="arm" ;;
        esac
        
        local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        local BINARY_URL=$(echo "$BINARY_URL_TEMPLATE" | sed "s/\${VERSION}/$VERSION/g" | sed "s/\${ARCH}/$ARCH/g" | sed "s/\${OS}/$OS/g")
        
        if curl -fsSL "$BINARY_URL" -o "/tmp/${TOOL_NAME}.tar.gz"; then
            tar -zxvf "/tmp/${TOOL_NAME}.tar.gz" -C /tmp
            # Find the binary (might be in subdirectory)
            find /tmp -name "$TOOL_NAME" -type f -executable -exec mv {} /usr/local/bin/ \;
            chmod +x "/usr/local/bin/$TOOL_NAME"
            rm -rf "/tmp/${TOOL_NAME}.tar.gz" /tmp/${OS}-${ARCH}
            log_success "$TOOL_NAME installed via direct binary download"
            return 0
        else
            log_error "Direct binary download failed"
        fi
    fi
    
    # All methods failed
    log_error "CRITICAL: All $TOOL_NAME installation methods failed"
    return 1
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    # Check Ubuntu version
    if ! grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
        log_warn "This script is tested on Ubuntu 24.04 LTS"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check Tailscale
    if ! command -v tailscale &> /dev/null; then
        log_error "Tailscale not found. Please install Tailscale first:"
        log_error "  curl -fsSL https://tailscale.com/install.sh | sh"
        exit 1
    fi
    
    if [ -z "$TAILSCALE_IP" ]; then
        log_error "Tailscale is not connected. Please run: sudo tailscale up --accept-dns=false"
        exit 1
    fi
    
    log_success "Tailscale IP: $TAILSCALE_IP"
    
    # Check disk space (at least 50GB free)
    AVAILABLE_SPACE=$(df / | tail -1 | awk '{print $4}')
    if [ "$AVAILABLE_SPACE" -lt 52428800 ]; then  # 50GB in KB
        log_warn "Less than 50GB free disk space available"
    fi
    
    log_success "Prerequisites check passed"
}

ensure_tailscale_ready() {
    log_info "Ensuring Tailscale interface is ready..."

    if ! command -v ip &>/dev/null; then
        log_error "ip command not found (iproute2 missing). Install with: sudo apt-get install -y iproute2"
        exit 1
    fi

    if ! command -v tailscale &>/dev/null; then
        log_error "tailscale command not found. Install with: curl -fsSL https://tailscale.com/install.sh | sh"
        exit 1
    fi

    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active tailscaled &>/dev/null; then
            log_error "tailscaled is not running. Start it with: sudo systemctl start tailscaled"
            exit 1
        fi
    else
        log_warn "systemctl not found; skipping tailscaled service check"
    fi

    local attempts=0
    local max_attempts=12
    while [ $attempts -lt $max_attempts ]; do
        if ip link show tailscale0 &>/dev/null; then
            local ts_ip
            ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
            if [ -n "$ts_ip" ]; then
                log_success "Tailscale interface ready: $ts_ip"
                return 0
            fi
        fi

        attempts=$((attempts + 1))
        log_warn "Tailscale interface not ready yet (attempt $attempts/$max_attempts). Waiting..."
        sleep 5
    done

    log_error "Tailscale interface not ready after ${max_attempts} attempts."
    log_error "Run: sudo tailscale up --accept-dns=false"
    exit 1
}

configure_k8s_network_prereqs() {
    log_info "Configuring kernel prerequisites for Kubernetes networking..."

    # Ensure required modules load on boot
    mkdir -p /etc/modules-load.d /etc/sysctl.d
    cat > /etc/modules-load.d/mynodeone-k8s.conf <<'EOF'
br_netfilter
vxlan
EOF

    if command -v modprobe &>/dev/null; then
        modprobe br_netfilter 2>/dev/null || log_warn "Failed to load kernel module br_netfilter"
        modprobe vxlan 2>/dev/null || log_warn "Failed to load kernel module vxlan"
    else
        log_warn "modprobe not found; kernel modules may not load automatically"
    fi

    # Persist sysctl settings for pod networking
    cat > /etc/sysctl.d/99-mynodeone-k8s.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF

    if command -v sysctl &>/dev/null; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log_warn "Could not set net.ipv4.ip_forward=1"
        sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || log_warn "Could not set net.bridge.bridge-nf-call-iptables=1"
        sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || log_warn "Could not set net.bridge.bridge-nf-call-ip6tables=1"
        sysctl --system >/dev/null 2>&1 || log_warn "sysctl --system failed; reboot may be required"
    else
        log_warn "sysctl not found; kernel networking settings may not be applied"
    fi

    log_success "Kernel networking prerequisites configured"
}

configure_k3s_service_dependencies() {
    local service_name="$1"
    log_info "Configuring $service_name to start after Tailscale..."

    if ! command -v systemctl &>/dev/null; then
        log_warn "systemctl not found; cannot set service dependencies"
        return 0
    fi

    local drop_in_dir="/etc/systemd/system/${service_name}.service.d"
    mkdir -p "$drop_in_dir"
    cat > "$drop_in_dir/10-tailscale.conf" <<'EOF'
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target
EOF

    systemctl daemon-reload
    log_success "$service_name dependency on tailscaled configured"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        python3-yaml \
        python3-pip \
        open-iscsi \
        nfs-common \
        util-linux \
        ufw \
        fail2ban
    
    # Enable and start iSCSI (required for Longhorn)
    systemctl enable --now iscsid
    
    log_success "Dependencies installed"
}

install_kompose() {
    log_info "Installing Kompose (docker-compose to Kubernetes converter)..."
    
    # Check if already installed
    if command -v kompose &> /dev/null; then
        local KOMPOSE_VERSION=$(kompose version 2>/dev/null | grep -oP 'v[0-9.]+' || echo "unknown")
        log_warn "Kompose already installed ($KOMPOSE_VERSION), skipping..."
        return 0
    fi
    
    # Detect architecture
    local ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
    esac
    
    local OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    local KOMPOSE_URL="https://github.com/kubernetes/kompose/releases/download/${KOMPOSE_VERSION}/kompose-${OS}-${ARCH}"
    
    log_info "Downloading Kompose ${KOMPOSE_VERSION} for ${OS}-${ARCH}..."
    
    if curl -fsSL "$KOMPOSE_URL" -o /usr/local/bin/kompose; then
        chmod +x /usr/local/bin/kompose
        
        # Verify installation
        if command -v kompose &> /dev/null; then
            local INSTALLED_VERSION=$(kompose version 2>/dev/null | head -1 || echo "unknown")
            log_success "Kompose installed successfully: $INSTALLED_VERSION"
            return 0
        else
            log_error "Kompose binary installed but not executable"
            return 1
        fi
    else
        log_warn "Kompose installation failed (non-critical)"
        log_info "External app deployment will use fallback parser"
        return 0  # Non-critical failure
    fi
}

configure_firewall() {
    log_info "Configuring firewall..."
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH (critical - don't lock yourself out!)
    ufw allow 22/tcp comment 'SSH'
    
    # Allow full access on Tailscale interface
    ufw allow in on tailscale0 comment 'Tailscale mesh network'
    
    # Flannel VXLAN needs no rule of its own: every k3s config in this repo sets
    # flannel-iface: tailscale0, so VXLAN packets arrive on tailscale0 and the
    # rule above covers them. Clean up the Anywhere rule older installs added.
    remove_public_vxlan_rule

    # Allow K3s API server (only from Tailscale)
    # Note: K3s already binds to Tailscale IP
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed  # Required for Kubernetes CNI pod routing
    
    # Enable fail2ban for SSH brute force protection
    systemctl enable --now fail2ban
    
    log_success "Firewall configured (UFW enabled, Kubernetes networking allowed)"
    log_warn "SSH and Tailscale traffic allowed. All other incoming traffic blocked."
    log_info "Kubernetes pod routing enabled (VXLAN over tailscale0, routed policy allow)"
}

# Older installs opened 8472/udp to Anywhere. Only remove it when VXLAN is known
# to run over tailscale0: a fresh install (no config yet) or a config that says so.
remove_public_vxlan_rule() {
    local config_file="$K3S_CONFIG_DIR/config.yaml"

    if ! ufw status 2>/dev/null | grep -E '^8472/udp( \(v6\))?[[:space:]]+ALLOW' >/dev/null; then
        return 0
    fi

    if [ -f "$config_file" ] && ! grep -Eq '^flannel-iface:[[:space:]]*"?tailscale0"?[[:space:]]*$' "$config_file"; then
        log_warn "Leaving the 8472/udp UFW rule: $config_file does not set flannel-iface: tailscale0"
        return 0
    fi

    ufw delete allow 8472/udp || log_warn "Could not remove the 8472/udp UFW rule"
    log_success "Removed the 8472/udp rule that was open to Anywhere (VXLAN stays on tailscale0)"
}

optimize_system_for_containers() {
    log_info "Optimizing system for containerized applications..."
    
    # Increase inotify limits for file watching in containers
    # Many apps (Jellyfin, Immich, etc.) use file watchers that hit default limits
    log_info "Configuring inotify limits..."
    sysctl -w fs.inotify.max_user_instances=1024 > /dev/null
    sysctl -w fs.inotify.max_user_watches=524288 > /dev/null
    
    # Make changes permanent (use sysctl.d drop-in for consistency)
    if [ ! -f /etc/sysctl.d/99-mynodeone-inotify.conf ]; then
        cat > /etc/sysctl.d/99-mynodeone-inotify.conf <<EOF
# Increased limits for containerized applications (MyNodeOne)
fs.inotify.max_user_instances=1024
fs.inotify.max_user_watches=524288
EOF
        log_success "inotify limits increased (persistent via /etc/sysctl.d/99-mynodeone-inotify.conf)"
    fi
    
    log_success "System optimizations applied"
}

# True if this file holds at least one encryption key.
encryption_config_is_valid() {
    [ -s "$1" ] && grep -Eq '^[[:space:]]*secret:[[:space:]]*[^[:space:]]+' "$1"
}

# True if K3s has already stored cluster data on this machine.
k3s_datastore_exists() {
    [ -d "$K3S_DATA_DIR/server/db" ] && [ -n "$(ls -A "$K3S_DATA_DIR/server/db" 2>/dev/null)" ]
}

k3s_is_installed() {
    [ -x "$K3S_BINARY" ] && [ -f "$K3S_SERVICE_UNIT" ]
}

# Copy the encryption key to a root-only directory. Timestamped and never
# overwritten, so an older key stays recoverable. Identical copies are skipped.
backup_encryption_key() {
    local src="$K3S_CONFIG_DIR/encryption-config.yaml"
    local existing dest

    (umask 077 && mkdir -p "$SECRETS_BACKUP_DIR") || return 1
    chmod 700 "$SECRETS_BACKUP_DIR" || return 1

    for existing in "$SECRETS_BACKUP_DIR"/encryption-config-*.yaml; do
        if [ -f "$existing" ] && cmp -s "$src" "$existing"; then
            chmod 600 "$existing" || return 1
            log_info "Encryption key already backed up: $existing"
            return 0
        fi
    done

    dest="$SECRETS_BACKUP_DIR/encryption-config-$(date -u +%Y%m%dT%H%M%SZ)-$$.yaml"
    install -m 600 "$src" "$dest" || return 1
    log_success "Encryption key backed up to $dest"
}

prepare_encryption_config() {
    log_info "Configuring secrets encryption at rest..."

    local cfg="$K3S_CONFIG_DIR/encryption-config.yaml"

    # An existing key decrypts every Secret in the datastore. Replacing it makes
    # them all unreadable, so it is backed up and kept.
    if encryption_config_is_valid "$cfg"; then
        if ! backup_encryption_key; then
            log_error "Could not back up $cfg to $SECRETS_BACKUP_DIR. Stopping before any change."
            return 1
        fi
        chmod 600 "$cfg"
        log_success "Keeping the existing encryption key: $cfg"
        return 0
    fi

    # A datastore without its key must never get a new one.
    if k3s_datastore_exists; then
        log_error "$K3S_DATA_DIR/server/db exists but $cfg is missing or holds no key."
        log_error "A new key would leave the existing Secrets unreadable, so nothing was changed."
        log_error "Restore the key from $SECRETS_BACKUP_DIR or your off-machine backup, then re-run."
        log_error "To really start over, run /usr/local/bin/k3s-uninstall.sh first (this deletes the cluster)."
        return 1
    fi

    if [ -e "$cfg" ]; then
        log_warn "Moving aside unusable $cfg (no cluster data exists yet)"
        mv "$cfg" "$cfg.invalid-$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    local encryption_key tmp
    encryption_key=$(head -c 32 /dev/urandom | base64)
    tmp=$(mktemp "$K3S_CONFIG_DIR/.encryption-config.XXXXXX")

    cat > "$tmp" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${encryption_key}
      - identity: {}  # Fallback for reading old unencrypted data
EOF

    chmod 600 "$tmp"
    mv -f "$tmp" "$cfg"
    log_success "Encryption configuration created"

    if ! backup_encryption_key; then
        log_error "Could not back up $cfg to $SECRETS_BACKUP_DIR. Stopping before K3s starts."
        return 1
    fi
}

prepare_audit_config() {
    log_info "Configuring audit logging..."

    local policy="$K3S_CONFIG_DIR/audit-policy.yaml"
    local source_policy="$PROJECT_ROOT/manifests/security/audit-policy.yaml"

    if [ -s "$policy" ]; then
        log_success "Keeping the existing audit policy: $policy"
        # Never replaced here: a new policy needs an API server restart, which a re-run
        # must not cause unprompted. The check prints the steps if there's a problem.
        bash "$PROJECT_ROOT/scripts/setup/check-audit-policy.sh" "$policy" \
            || log_warn "The audit policy needs attention, see above. Continuing without changing it."
        if ! cmp -s "$policy" "$source_policy"; then
            log_info "It differs from $source_policy. To adopt that one, copy it over and restart k3s."
        fi
        return 0
    fi

    if [ ! -s "$source_policy" ]; then
        log_error "Audit policy not found: $source_policy"
        return 1
    fi

    install -m 644 "$source_policy" "$policy"
    log_success "Audit policy configured"
}

prepare_pod_security_config() {
    log_info "Configuring Pod Security Standards..."

    local cfg="$K3S_CONFIG_DIR/pod-security-config.yaml"

    if [ -s "$cfg" ]; then
        log_success "Keeping the existing Pod Security configuration: $cfg"
        return 0
    fi

    cat > "$cfg" <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: [kube-system, kube-public, kube-node-lease, longhorn-system, metallb-system, cert-manager]
EOF

    chmod 644 "$cfg"
    log_success "Pod Security Standards configured"
}

# Workers join with this token, not the server token, so a leaked worker token
# cannot join a new control-plane node. New clusters only: setting it later
# changes the password that K3s holds for already-joined agents.
prepare_agent_token() {
    local token_file="$K3S_CONFIG_DIR/agent-token"

    if [ -s "$token_file" ]; then
        chmod 600 "$token_file"
        return 0
    fi

    if k3s_datastore_exists; then
        return 1
    fi

    local tmp
    tmp=$(mktemp "$K3S_CONFIG_DIR/.agent-token.XXXXXX")
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$token_file"
    log_success "Separate agent join token created"
}

write_k3s_server_config() {
    local config_file="$1"
    local agent_token_line="# agent-token-file not set: this datastore already exists"

    if prepare_agent_token; then
        agent_token_line="agent-token-file: \"$K3S_CONFIG_DIR/agent-token\""
    else
        log_warn "Existing datastore without an agent token: workers keep using the server token"
    fi

    cat > "$config_file" <<EOF
cluster-init: true
write-kubeconfig-mode: "0600"
node-name: "$NODE_NAME"
node-ip: "$TAILSCALE_IP"
flannel-iface: tailscale0
${agent_token_line}
tls-san:
  - "$TAILSCALE_IP"
  - "$NODE_NAME"
  - "127.0.0.1"
disable:
  - traefik  # We'll install Traefik separately with custom config
  - servicelb  # We'll use MetalLB
disable-cloud-controller: true
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 5
kubelet-arg:
  - "max-pods=250"
kube-proxy-arg:
  - "nodeport-addresses=100.64.0.0/10"  # Tailscale range: NodePorts stay off the LAN
kube-apiserver-arg:
  - "encryption-provider-config=$K3S_CONFIG_DIR/encryption-config.yaml"
  - "audit-log-path=/var/log/k3s-audit.log"
  - "audit-policy-file=$K3S_CONFIG_DIR/audit-policy.yaml"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "audit-log-compress=true"
  - "admission-control-config-file=$K3S_CONFIG_DIR/pod-security-config.yaml"
EOF
}

install_k3s() {
    log_info "Installing K3s server..."

    # Prepare K3s configuration
    mkdir -p "$K3S_CONFIG_DIR"

    # Setup security configs BEFORE K3s starts
    prepare_encryption_config || exit 1
    prepare_audit_config || exit 1
    prepare_pod_security_config

    local config_file="$K3S_CONFIG_DIR/config.yaml"

    # config.yaml of a live cluster holds its settings, so a re-run leaves it alone.
    if [ -s "$config_file" ] && { k3s_is_installed || k3s_datastore_exists; }; then
        log_success "Keeping the existing K3s configuration: $config_file"
    else
        write_k3s_server_config "$config_file"
    fi

    if k3s_is_installed; then
        log_success "K3s is already installed, keeping it (not reinstalled, upgraded or restarted)"
        if ! systemctl is-active --quiet k3s; then
            log_warn "K3s service is not running, starting it..."
            systemctl start k3s
        fi
    else
        # Install K3s
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
    fi

    # Wait for K3s to be ready
    log_info "Waiting for K3s to be ready..."
    until kubectl get nodes &> /dev/null; do
        sleep 2
    done
    
    # Wait for THIS node to register (can take 10-30 seconds)
    log_info "Waiting for node '$NODE_NAME' to register with Kubernetes..."
    WAIT_COUNT=0
    until kubectl get node "$NODE_NAME" &> /dev/null; do
        sleep 3
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -gt 20 ]; then
            log_error "Node $NODE_NAME did not register after 60 seconds"
            log_info "Current nodes:"
            kubectl get nodes
            exit 1
        fi
        echo -n "."
    done
    echo ""
    log_success "Node $NODE_NAME is registered"
    
    # Label this node as control plane and worker
    kubectl label node "$NODE_NAME" node-role.kubernetes.io/worker=true --overwrite
    kubectl label node "$NODE_NAME" mynodeone.io/location=${NODE_LOCATION:-unknown} --overwrite
    kubectl label node "$NODE_NAME" mynodeone.io/storage=true --overwrite
    
    # Register cluster node in node registry
    log_info "Registering cluster node in node registry..."
    if [ -f "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" ]; then
        source "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh"
        
        # Get Kubernetes node name (may differ from hostname)
        K8S_NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "$NODE_NAME")
        
        # Get Tailscale IP
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
        
        # Register cluster node
        register_cluster_node \
            --name "$NODE_NAME" \
            --k8s-node-name "$K8S_NODE_NAME" \
            --role "control-plane" \
            --location "${NODE_LOCATION:-home}" \
            --tailscale-ip "$TAILSCALE_IP" \
            --ssh-user "${SUDO_USER:-$(whoami)}" || log_warn "Could not register cluster node"
    else
        log_warn "Node registry manager not found, skipping node registration"
    fi
    
    log_success "K3s installed successfully"
    
    # Save kubeconfig for regular user
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
            mkdir -p "$USER_HOME/.kube"
            cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
            chmod 600 "$USER_HOME/.kube/config"
            chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.kube"
            log_success "Kubeconfig saved to $USER_HOME/.kube/config"
            
            # Add KUBECONFIG to user's shell config (persists across sessions)
            if [ -f "$USER_HOME/.bashrc" ]; then
                if ! grep -q "export KUBECONFIG=\$HOME/.kube/config" "$USER_HOME/.bashrc"; then
                    echo '' >> "$USER_HOME/.bashrc"
                    echo '# Added by MyNodeOne installer - ensures kubectl works without sudo' >> "$USER_HOME/.bashrc"
                    echo 'export KUBECONFIG=$HOME/.kube/config' >> "$USER_HOME/.bashrc"
                    chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.bashrc"
                    log_success "Added KUBECONFIG to $USER_HOME/.bashrc"
                fi
            fi
        fi
    fi
    
    # Fix CoreDNS to use public DNS instead of /etc/resolv.conf
    # This is needed because systemd-resolved uses 127.0.0.53 which doesn't work from inside pods
    fix_coredns_upstream_dns
}

# Fix CoreDNS to use public upstream DNS servers
# systemd-resolved uses 127.0.0.53 which is inaccessible from inside pods
fix_coredns_upstream_dns() {
    log_info "Configuring CoreDNS with public upstream DNS..."
    
    # Wait for CoreDNS to be available
    local retries=30
    while ! kubectl get configmap -n kube-system coredns &>/dev/null && [ $retries -gt 0 ]; do
        sleep 2
        ((retries--))
    done
    
    if [ $retries -eq 0 ]; then
        log_warn "CoreDNS configmap not found, skipping DNS fix"
        return 0
    fi
    
    # Check current config
    local current_forward
    current_forward=$(kubectl get configmap -n kube-system coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "forward")
    
    if echo "$current_forward" | grep -q "/etc/resolv.conf"; then
        log_info "Patching CoreDNS to use 8.8.8.8 and 1.1.1.1 instead of /etc/resolv.conf"
        
        # Patch the configmap
        kubectl get configmap -n kube-system coredns -o json | \
            jq '.data.Corefile = (.data.Corefile | sub("forward . /etc/resolv.conf"; "forward . 8.8.8.8 1.1.1.1"))' | \
            kubectl apply -f - &>/dev/null
        
        # Restart CoreDNS to pick up changes
        kubectl rollout restart deployment coredns -n kube-system &>/dev/null
        kubectl rollout status deployment coredns -n kube-system --timeout=60s &>/dev/null
        
        log_success "CoreDNS configured with public DNS servers"
    else
        log_info "CoreDNS already configured with upstream DNS"
    fi
    
    # Install DNS Guardian for persistent protection
    install_dns_guardian
}

# Install CoreDNS DNS Guardian for persistent DNS fix protection
install_dns_guardian() {
    log_info "Installing CoreDNS DNS Guardian for persistent protection..."
    
    # Copy the guardian script to system location
    local guardian_script="/usr/local/bin/coredns-dns-guardian.sh"
    cp "$SCRIPT_DIR/../domains/coredns-dns-guardian.sh" "$guardian_script"
    chmod +x "$guardian_script"
    
    # Create systemd service
    cat > /etc/systemd/system/coredns-dns-guardian.service << 'EOF'
[Unit]
Description=CoreDNS DNS Guardian
After=k3s.service
Wants=k3s.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/coredns-dns-guardian.sh
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create systemd timer for periodic checks
    cat > /etc/systemd/system/coredns-dns-guardian.timer << 'EOF'
[Unit]
Description=Run CoreDNS DNS Guardian every 5 minutes
Requires=coredns-dns-guardian.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start the service
    systemctl daemon-reload
    systemctl enable coredns-dns-guardian.timer
    systemctl start coredns-dns-guardian.timer
    
    log_success "DNS Guardian installed - will check DNS configuration every 5 minutes"
    
    # Install permanent host-level DNS fix
    install_permanent_host_dns_fix
}

# Install permanent fix for Tailscale DNS override on host system
# This prevents Tailscale from breaking host DNS resolution after restarts
install_permanent_host_dns_fix() {
    log_info "Installing permanent host-level DNS fix for Tailscale override..."
    
    # Copy the permanent DNS fix script to system location
    cp "$SCRIPT_DIR/../domains/fix-tailscale-dns-permanent.sh" /usr/local/bin/
    chmod +x /usr/local/bin/fix-tailscale-dns-permanent.sh
    
    # Apply the permanent fix
    /usr/local/bin/fix-tailscale-dns-permanent.sh
    
    log_success "Permanent host DNS fix installed - will persist across reboots"
}

# GPU Setup for Kubernetes (after K3s is installed)
# Using shared gpu-setup.sh script for consistency with worker nodes
setup_gpu_support() {
    # Only run if NVIDIA GPU is detected
    if ! lspci | grep -i nvidia &> /dev/null; then
        return 0
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configuring GPU Support for Kubernetes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use shared GPU setup script
    local GPU_SETUP_SCRIPT="$PROJECT_ROOT/scripts/lib/gpu-setup.sh"
    if [ ! -f "$GPU_SETUP_SCRIPT" ]; then
        log_error "GPU setup script not found: $GPU_SETUP_SCRIPT"
        return 1
    fi
    
    # Source the shared script and run setup
    # Pass true to deploy device plugin on control plane
    source "$GPU_SETUP_SCRIPT"
    setup_gpu true
    
    return 0
}


# Deploy NVIDIA Device Plugin (called after cluster is ready)
deploy_nvidia_device_plugin() {
    # Only run if NVIDIA GPU is detected and driver is working
    if ! lspci | grep -i nvidia &> /dev/null; then
        return 0
    fi
    
    if ! command -v nvidia-smi &>/dev/null || ! nvidia-smi &>/dev/null; then
        return 0
    fi
    
    log_info "Deploying NVIDIA Device Plugin..."
    
    # K3s v1.28+ auto-creates RuntimeClass for nvidia when it detects nvidia-container-runtime
    # Verify it exists
    if kubectl get runtimeclass nvidia &>/dev/null; then
        log_success "NVIDIA RuntimeClass exists (auto-created by K3s)"
    else
        log_warn "NVIDIA RuntimeClass not found - K3s may not have detected nvidia-container-runtime"
        echo "    Check: grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml"
    fi
    
    # Deploy the device plugin with runtimeClassName: nvidia
    # This ensures the plugin pod runs with nvidia runtime and can access GPU libraries
    local LOCAL_MANIFEST="$PROJECT_ROOT/manifests/gpu/nvidia-device-plugin.yaml"
    
    local PLUGIN_DEPLOYED=false
    if [ -f "$LOCAL_MANIFEST" ]; then
        if kubectl apply -f "$LOCAL_MANIFEST" 2>/dev/null; then
            log_success "NVIDIA Device Plugin deployed"
            PLUGIN_DEPLOYED=true
        fi
    fi
    
    if [ "$PLUGIN_DEPLOYED" = false ]; then
        # Fallback: use remote manifest but it lacks runtimeClassName
        log_warn "Local manifest not found, using remote (may not work without runtimeClassName)"
        local REMOTE_MANIFEST="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml"
        if kubectl apply -f "$REMOTE_MANIFEST" 2>/dev/null; then
            log_success "NVIDIA Device Plugin deployed (remote manifest)"
            PLUGIN_DEPLOYED=true
        else
            log_error "Failed to deploy NVIDIA Device Plugin"
            echo "    Try manually: kubectl apply -f $REMOTE_MANIFEST"
            return 1
        fi
    fi
    
    # Wait for device plugin to be ready and verify GPU
    log_info "Waiting for GPU to be detected by Kubernetes..."
    echo -n "  Waiting for device plugin"
    
    local GPU_VISIBLE=false
    for i in $(seq 1 12); do
        sleep 5
        echo -n "."
        local GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")
        if [ -n "$GPU_COUNT" ] && [ "$GPU_COUNT" != "0" ]; then
            GPU_VISIBLE=true
            break
        fi
    done
    echo ""
    
    if [ "$GPU_VISIBLE" = true ]; then
        log_success "GPU detected: $GPU_COUNT GPU(s) available in Kubernetes"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ✓ GPU Setup Complete"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Your GPU is ready! Use 'nvidia.com/gpu' in pod resource requests."
        echo "Example:"
        echo "  resources:"
        echo "    limits:"
        echo "      nvidia.com/gpu: 1"
        echo ""
    else
        log_warn "GPU not yet visible to Kubernetes"
        echo "    Device plugin may still be starting. Check with:"
        echo "      kubectl get pods -n kube-system | grep nvidia"
        echo "      kubectl describe node | grep nvidia"
    fi
}

install_helm() {
    # Helm installation with multiple failsafe methods. The first two install
    # exactly $HELM_VERSION from versions.sh; snap cannot pin it, so it is last.
    # 1. get-helm-3 script taken from the same tag (verifies the checksum)
    # 2. Direct binary download
    # 3. Snap (if available)

    log_info "Installing Helm with failsafe methods..."

    # Check if already installed
    if command -v helm &> /dev/null; then
        local EXISTING_VERSION
        EXISTING_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
        log_warn "Helm already installed ($EXISTING_VERSION), skipping..."
        return 0
    fi

    local success=false

    # Method 1: get-helm-3 from the pinned tag, not from main
    log_info "Method 1: Trying official Helm installation script ($HELM_VERSION)..."
    if curl -fsSL "https://raw.githubusercontent.com/helm/helm/${HELM_VERSION}/scripts/get-helm-3" | DESIRED_VERSION="$HELM_VERSION" bash 2>/dev/null; then
        log_success "Helm installed via official script"
        success=true
    else
        log_warn "Official script failed, trying next method..."
    fi

    # Method 2: Direct binary download
    if [ "$success" = false ]; then
        log_info "Method 2: Trying direct binary download..."

        local ARCH=$(uname -m)

        case $ARCH in
            x86_64) ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l) ARCH="arm" ;;
        esac

        local HELM_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"

        if curl -fsSL "$HELM_URL" -o /tmp/helm.tar.gz 2>/dev/null; then
            tar -zxf /tmp/helm.tar.gz -C /tmp 2>/dev/null
            mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
            chmod +x /usr/local/bin/helm
            rm -rf /tmp/helm.tar.gz /tmp/linux-${ARCH}
            log_success "Helm installed via direct binary download"
            success=true
        else
            log_warn "Direct binary download failed, trying next method..."
        fi
    fi

    # Method 3: Snap, which installs whatever the channel currently serves
    if [ "$success" = false ] && command -v snap &> /dev/null; then
        log_info "Method 3: Trying snap installation (version not pinned)..."
        if snap install helm --classic 2>/dev/null; then
            log_warn "Helm installed via snap, which may not be $HELM_VERSION"
            success=true
        else
            log_warn "Snap installation failed"
        fi
    fi

    # Check final result
    if [ "$success" = false ]; then
        log_error "CRITICAL: All Helm installation methods failed"
        log_error "Attempted methods:"
        log_error "  1. Official get-helm-3 script ($HELM_VERSION)"
        log_error "  2. Direct binary download ($HELM_VERSION)"
        log_error "  3. Snap (if available)"
        echo
        log_error "Please install Helm manually:"
        log_error "  https://github.com/helm/helm/releases/tag/${HELM_VERSION}"
        echo
        return 1
    fi

    # Verify installation
    if command -v helm &> /dev/null; then
        local INSTALLED_VERSION=$(helm version --short 2>/dev/null || echo "unknown")
        log_success "Helm successfully installed: $INSTALLED_VERSION"
        return 0
    else
        log_error "Helm installation verification failed"
        return 1
    fi
}

create_priority_classes() {
    log_info "Creating PriorityClasses for resource management..."
    
    # Apply shared PriorityClass manifest
    cat <<EOF | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: mynodeone-infrastructure
value: 2000
globalDefault: false
description: "Priority class for MyNodeOne infrastructure components (databases, caches, monitoring, GitOps)"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: mynodeone-app
value: 1000
globalDefault: false
description: "Priority class for MyNodeOne user-facing applications"
EOF
    
    log_success "PriorityClasses created (mynodeone-infrastructure: 2000, mynodeone-app: 1000)"
}

install_cert_manager() {
    log_info "Installing cert-manager..."
    
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "$CERT_MANAGER_VERSION" \
        --set installCRDs=true \
        --wait
    
    log_success "cert-manager installed"
}

install_longhorn() {
    log_info "Installing Longhorn storage (interactive)..."
    
    # Use new interactive installation script
    if [ -f "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh" ]; then
        local exit_code=0
        bash "$PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh" || exit_code=$?
        if [ $exit_code -eq 0 ]; then
            log_success "Longhorn installed successfully"
        else
            log_error "Longhorn installation failed with exit code $exit_code"
            log_error "Continuing with bootstrap process..."
            log_error "You can manually fix Longhorn issues after installation completes"
            log_error "Check 'kubectl get sc longhorn -o yaml' for StorageClass status"
            # Don't exit - continue with other components
        fi
    else
        log_error "Longhorn installation script not found: $PROJECT_ROOT/scripts/storage/longhorn/install-interactive.sh"
        log_warn "Falling back to basic installation..."
        
        # Fallback: basic installation
        # Respect LONGHORN_REPLICA_COUNT environment variable (default: 1)
        local replica_count="${LONGHORN_REPLICA_COUNT:-1}"
        log_info "Using Longhorn replica count: $replica_count"
        
        apt-get install -y open-iscsi util-linux
        systemctl enable --now iscsid
        
        kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
        
        helm repo add longhorn https://charts.longhorn.io
        helm repo update
        
        helm upgrade --install longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --version "$LONGHORN_VERSION" \
            --set defaultSettings.defaultReplicaCount=$replica_count \
            --set persistence.defaultClassParameter.numberOfReplicas=$replica_count \
            --set defaultSettings.replicaReplenishmentWaitInterval=432000 \
            --set defaultSettings.replicaAutoBalance="best-effort" \
            --set defaultSettings.fastReplicaRebuildEnabled=true \
            --wait
        
        kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
        
        # Verify and fix StorageClass parameters (defensive programming)
        log_info "Verifying Longhorn StorageClass configuration..."
        local max_wait=30
        local wait_count=0
        local replicas_correct=false
        
        while [ $wait_count -lt $max_wait ]; do
            if kubectl get storageclass longhorn &>/dev/null; then
                local current_replicas=$(kubectl get storageclass longhorn -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || echo "3")
                if [ "$current_replicas" = "$replica_count" ]; then
                    replicas_correct=true
                    break
                else
                    log_warn "StorageClass has wrong replica count ($current_replicas), fixing..."
                    # Delete and recreate with correct parameters
                    kubectl delete storageclass longhorn --ignore-not-found=true
                    kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "$replica_count"
  staleReplicaTimeout: "30"
  fromBackup: ""
  fsType: "ext4"
  dataLocality: "disabled"
EOF
                    if [ $? -eq 0 ]; then
                        replicas_correct=true
                        break
                    else
                        log_error "Failed to recreate StorageClass, retrying..."
                    fi
                fi
            else
                log_info "Waiting for StorageClass to be created..."
            fi
            sleep 2
            wait_count=$((wait_count + 2))
        done
        
        if [ "$replicas_correct" = true ]; then
            log_success "StorageClass correctly configured with numberOfReplicas=$replica_count"
        else
            log_error "Failed to configure StorageClass after $max_wait seconds"
            log_error "Manual intervention required: check 'kubectl get sc longhorn -o yaml'"
        fi
        
        kubectl patch svc longhorn-frontend -n longhorn-system -p '{"spec":{"type":"LoadBalancer"}}'
        
        log_success "Longhorn installed (basic)"
    fi
}

install_metallb() {
    log_info "Installing MetalLB load balancer..."
    
    kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add metallb https://metallb.github.io/metallb
    helm repo update
    
    # Pinned from versions.sh. Earlier installs were unpinned and may be on a newer
    # chart, and a re-run must not downgrade a working load balancer by surprise.
    local metallb_chart_version="$METALLB_VERSION"
    local installed_metallb
    installed_metallb=$(helm list -n metallb-system -f '^metallb$' -o json 2>/dev/null | jq -r '.[0].chart // empty' 2>/dev/null | sed 's/^metallb-//') || true
    if [ -n "$installed_metallb" ] && [ "$installed_metallb" != "$METALLB_VERSION" ]; then
        log_warn "MetalLB chart $installed_metallb is installed, versions.sh pins $METALLB_VERSION. Keeping $installed_metallb."
        log_warn "To settle this, update METALLB_VERSION in scripts/lib/versions.sh or run a deliberate helm upgrade."
        metallb_chart_version="$installed_metallb"
    fi

    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --version "$metallb_chart_version" \
        --wait
    
    # Configure IP address pool (using Tailscale subnet)
    TAILSCALE_SUBNET=$(echo "$TAILSCALE_IP" | cut -d. -f1-3)
    
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: metallb-system
spec:
  addresses:
  - ${TAILSCALE_SUBNET}.200-${TAILSCALE_SUBNET}.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tailscale-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - tailscale-pool
EOF
    
    log_success "MetalLB installed"
}

configure_tailscale_subnet_routes() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Configuring Tailscale Network Routes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Setting up subnet routes for LoadBalancer access..."
    echo
    
    # Get the MetalLB subnet (same as Tailscale subnet)
    TAILSCALE_SUBNET=$(echo "$TAILSCALE_IP" | cut -d. -f1-3)
    
    # Enable IP forwarding (required for subnet routes)
    log_info "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    
    # Make IP forwarding permanent
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
        log_success "IP forwarding enabled (persistent)"
    fi
    
    # Advertise MetalLB subnet to Tailscale network
    # Note: --accept-dns=false prevents Tailscale from overwriting /etc/resolv.conf
    # This avoids DNS resolution issues when Tailscale's internal DNS (100.100.100.100) fails
    # Subnet routing and all other Tailscale features still work normally
    log_info "Advertising subnet ${TAILSCALE_SUBNET}.0/24 to Tailscale..."
    if tailscale up --advertise-routes=${TAILSCALE_SUBNET}.0/24 --accept-routes --accept-dns=false 2>/dev/null; then
        log_success "Subnet route advertised to Tailscale (DNS managed by system)"
    else
        log_warn "Could not advertise subnet automatically. This is not critical."
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ⚠️  ACTION REQUIRED: Approve Subnet Route in Tailscale"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "To enable direct access to services from other devices:"
    echo
    echo "1. Go to: https://login.tailscale.com/admin/machines"
    echo "2. Find this machine in the list"
    echo "3. Click '...' menu → 'Edit route settings'"
    echo "4. Toggle ON the subnet route: ${TAILSCALE_SUBNET}.0/24"
    echo "5. Click 'Save'"
    echo
    echo "Once approved, you can access services directly at:"
    echo "  • http://grafana.${CLUSTER_DOMAIN}.local"
    echo "  • http://argocd.${CLUSTER_DOMAIN}.local"
    echo
    log_info "This step takes 30 seconds in Tailscale admin console"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # Pause installation to let user approve the subnet route
    # Note: Subnet route approval is CRITICAL for LoadBalancer IPs to work
    # The subsequent IP allocations to services depend on this being approved
    if [ "${UNATTENDED:-0}" != "1" ]; then
        echo
        log_warn "IMPORTANT: The installer will PAUSE here to let you approve the subnet route."
        log_info "Services need this route to be approved before they receive proper IP addresses."
        echo
        if ! prompt_confirm "Have you approved the subnet route in Tailscale?" "n"; then
            log_warn "Subnet route not approved yet. Installation will continue, but:"
            echo "  ⚠️  LoadBalancer services may not get proper IPs"
            echo "  ⚠️  You'll need to approve it later and restart services"
            echo "  ⚠️  To fix later: kubectl rollout restart -n <namespace> deployment/<service>"
            echo
            if ! prompt_confirm "Continue anyway?" "n"; then
                log_error "Installation cancelled by user"
                echo
                echo "After approving the subnet route, run:"
                echo "  sudo ./scripts/installation/install-mynodeone.sh"
                exit 1
            fi
        else
            log_success "Subnet route approved! Continuing with installation..."
        fi
    else
        log_warn "UNATTENDED mode: Assuming subnet route will be approved manually"
    fi
    echo
}

install_traefik() {
    log_info "Installing Traefik ingress controller..."
    
    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
    
    helm repo add traefik https://helm.traefik.io/traefik
    helm repo update
    
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        --version "$TRAEFIK_VERSION" \
        --set ports.web.port=80 \
        --set ports.websecure.port=443 \
        --set ports.websecure.tls.enabled=true \
        --set service.type=LoadBalancer \
        --wait
    
    log_success "Traefik installed"
}

# Velero removed - user doesn't need automated cluster backups

install_monitoring() {
    log_info "Installing monitoring stack (Prometheus, Grafana, Loki)..."
    
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # node-exporter and promtail need hostPath/hostNetwork/hostPID, which the
    # cluster-wide baseline default rejects. Relax enforcement for this namespace
    # only; the restricted audit and warn defaults stay as they are.
    kubectl label --overwrite namespace monitoring \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/enforce-version=latest

    # Check DNS before adding repos
    check_dns || log_warn "DNS may be slow, continuing anyway..."
    
    # Install kube-prometheus-stack (Prometheus + Grafana)
    log_info "Adding helm repositories..."
    retry_command 3 "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>&1" || true
    retry_command 3 "helm repo add grafana https://grafana.github.io/helm-charts 2>&1" || true
    
    # Update repos with timeout
    log_info "Updating helm repositories (may take a moment)..."
    timeout 120 helm repo update 2>&1 || log_warn "Helm repo update slow/timed out, but continuing..."
    
    # Keep the Grafana password on a re-run. Grafana's database keeps the old one
    # anyway, so a new value would only make the Secret and saved credentials wrong.
    GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode 2>/dev/null) || true
    if [ -z "$GRAFANA_PASSWORD" ]; then
        GRAFANA_PASSWORD="$(openssl rand -base64 32 | tr -d '=/+' | cut -c1-32)"
    fi

    # Optional alert destination: only used if the user created this file.
    # Without it Alertmanager keeps its default 'null' receiver.
    local alertmanager_values_file="${ALERTMANAGER_VALUES_FILE:-/etc/mynodeone/alertmanager-values.yaml}"
    local alertmanager_args=""
    if [ -s "$alertmanager_values_file" ]; then
        alertmanager_args="-f $alertmanager_values_file"
        log_info "Using Alertmanager destination from $alertmanager_values_file"
    else
        log_warn "No alert destination set: alerts stay visible in Prometheus and Alertmanager but are not sent anywhere"
        log_info "To set one, see $PROJECT_ROOT/scripts/monitoring/README.md"
    fi
    
    # Install kube-prometheus-stack with safe wrapper and optimized resources for homelab
    helm_install_safe "kube-prometheus-stack" "prometheus-community/kube-prometheus-stack" "monitoring" \
        --version "$PROMETHEUS_STACK_VERSION" \
        -f "$PROJECT_ROOT/scripts/monitoring/kube-prometheus-stack-values.yaml" \
        $alertmanager_args \
        --set prometheus.prometheusSpec.retention=30d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=100Gi \
        --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
        --set prometheus.prometheusSpec.resources.requests.cpu=200m \
        --set prometheus.prometheusSpec.resources.limits.memory=8Gi \
        --set prometheus.prometheusSpec.priorityClassName=mynodeone-infrastructure \
        --set grafana.adminPassword="$GRAFANA_PASSWORD" \
        --set grafana.service.type=LoadBalancer \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.storageClassName=longhorn \
        --set grafana.persistence.size=10Gi \
        --set grafana.resources.requests.memory=128Mi \
        --set grafana.resources.requests.cpu=50m \
        --set grafana.resources.limits.memory=2Gi \
        --set grafana.priorityClassName=mynodeone-infrastructure \
        --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
        --set alertmanager.alertmanagerSpec.resources.requests.cpu=50m \
        --set alertmanager.alertmanagerSpec.resources.limits.memory=512Mi \
        --set alertmanager.alertmanagerSpec.priorityClassName=mynodeone-infrastructure \
        --set prometheusOperator.resources.requests.memory=128Mi \
        --set prometheusOperator.resources.requests.cpu=50m \
        --set prometheusOperator.resources.limits.memory=512Mi \
        --set prometheusOperator.priorityClassName=mynodeone-infrastructure \
        --set kube-state-metrics.resources.requests.memory=64Mi \
        --set kube-state-metrics.resources.requests.cpu=50m \
        --set kube-state-metrics.resources.limits.memory=256Mi \
        --set kube-state-metrics.priorityClassName=mynodeone-infrastructure \
    || {
        log_error "kube-prometheus-stack failed. Its pods may still be running an older version, and that doesn't count as installed."
        log_warn "Continuing with the other components. The install reports this at the end and exits non-zero."
        component_failed "kube-prometheus-stack"
    }
    
    # Alert rules and the Longhorn scrape config (non-critical, allow failure)
    kubectl apply -f "$PROJECT_ROOT/scripts/monitoring/longhorn-servicemonitor.yaml" \
        -f "$PROJECT_ROOT/scripts/monitoring/prometheus-alerts/" \
        || log_warn "Could not apply MyNodeOne alert rules. Retry with: sudo $PROJECT_ROOT/scripts/monitoring/apply-monitoring-config.sh"

    # Install Loki for logs (non-critical, allow failure)
    log_info "Installing Loki (log aggregation)..."
    helm_install_safe "loki" "grafana/loki-stack" "monitoring" \
        --version "$LOKI_VERSION" \
        --set loki.persistence.enabled=true \
        --set loki.persistence.storageClassName=longhorn \
        --set loki.persistence.size=100Gi \
        --set promtail.enabled=true \
    || {
        log_warn "Loki failed. Continuing, and the install reports this at the end."
        component_failed "loki"
    }
    
    # Get generated Grafana password from secret (with retry)
    sleep 5
    log_info "Retrieving Grafana credentials..."
    local attempts=0
    while [ $attempts -lt 10 ]; do
        GRAFANA_PASSWORD=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode 2>/dev/null) || true
        if [ -n "$GRAFANA_PASSWORD" ]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 3
    done
    
    # Save Grafana credentials securely
    cat > $ACTUAL_HOME/mynodeone-grafana-credentials.txt <<EOF
Grafana Credentials
===================
Username: admin
Password: $GRAFANA_PASSWORD
URL: http://$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-grafana-credentials.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-grafana-credentials.txt
    
    if [[ " ${FAILED_COMPONENTS[*]} " == *" kube-prometheus-stack "* || " ${FAILED_COMPONENTS[*]} " == *" loki "* ]]; then
        log_warn "Monitoring stack is not fully installed: see the errors above"
    else
        log_success "Monitoring stack installed"
    fi
    log_warn "Grafana credentials saved to $ACTUAL_HOME/mynodeone-grafana-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file"
}

install_minio() {
    log_info "MinIO (S3-compatible object storage)..."
    log_info "MinIO is now installed as an app (like Immich, LLM API)"
    log_info ""
    log_info "To install MinIO on this or any node:"
    log_info "  sudo $SCRIPT_DIR/../storage/minio/install-minio.sh"
    log_info ""
    log_info "MinIO can be installed multiple times on different nodes"
    log_info "Each installation gets independent credentials and .local domain"
    log_info ""
    log_info "Skipping automatic installation - install manually if needed"
}

install_argocd() {
    log_info "Installing ArgoCD for GitOps..."
    
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Add ArgoCD helm repo
    log_info "Adding ArgoCD helm repository..."
    retry_command 3 "helm repo add argo https://argoproj.github.io/argo-helm 2>&1" || true
    timeout 60 helm repo update 2>&1 || log_warn "Helm repo update timed out, continuing..."
    
    # Install ArgoCD using helm with optimized resources for homelab
    helm_install_safe "argocd" "argo/argo-cd" "argocd" \
        --version "$ARGOCD_VERSION" \
        --set server.service.type=LoadBalancer \
        --set global.priorityClassName=mynodeone-infrastructure \
        --set controller.resources.requests.memory=256Mi \
        --set controller.resources.requests.cpu=100m \
        --set controller.resources.limits.memory=2Gi \
        --set server.resources.requests.memory=128Mi \
        --set server.resources.requests.cpu=50m \
        --set server.resources.limits.memory=1Gi \
        --set repoServer.resources.requests.memory=128Mi \
        --set repoServer.resources.requests.cpu=50m \
        --set repoServer.resources.limits.memory=1Gi \
        --set dex.resources.requests.memory=64Mi \
        --set dex.resources.requests.cpu=25m \
        --set dex.resources.limits.memory=256Mi \
        --set redis.resources.requests.memory=64Mi \
        --set redis.resources.requests.cpu=50m \
        --set redis.resources.limits.memory=512Mi \
        --set applicationSet.resources.requests.memory=64Mi \
        --set applicationSet.resources.requests.cpu=25m \
        --set applicationSet.resources.limits.memory=256Mi \
        --set notifications.resources.requests.memory=64Mi \
        --set notifications.resources.requests.cpu=25m \
        --set notifications.resources.limits.memory=256Mi \
    || {
        # The plain manifest would overwrite what helm manages, so it's only a fallback
        # for when helm never created a release, such as the chart failing to download.
        if helm status argocd -n argocd &>/dev/null; then
            log_error "ArgoCD helm release exists but its install or upgrade failed. Not applying the fallback manifest over it."
            log_warn "Continuing with the other components. The install reports this at the end and exits non-zero."
            component_failed "argocd"
        else
            log_error "ArgoCD helm install failed, trying kubectl method..."
            # Fallback to kubectl method
            retry_command 2 "timeout 120 kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_FALLBACK_MANIFEST_VERSION}/manifests/install.yaml" || {
                log_error "ArgoCD installation failed"
                return 1
            }

            # Wait for ArgoCD to be ready (with timeout)
            log_info "Waiting for ArgoCD to be ready..."
            timeout 300 kubectl wait --for=condition=available deployment/argocd-server -n argocd 2>&1 || log_warn "ArgoCD wait timed out"

            # Expose ArgoCD with LoadBalancer
            kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}' || log_warn "Failed to patch ArgoCD service"
        fi
    }
    
    # Get initial admin password (with retry and timeout)
    log_info "Retrieving ArgoCD password..."
    local attempts=0
    ARGOCD_PASSWORD=""
    while [ $attempts -lt 30 ]; do
        ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null) || true
        if [ -n "$ARGOCD_PASSWORD" ]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 2
    done
    
    if [ -z "$ARGOCD_PASSWORD" ]; then
        log_warn "Could not retrieve ArgoCD password yet (it may not be ready)"
        ARGOCD_PASSWORD="<retrieve with: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d>"
    fi
    
    # Save credentials securely
    cat > $ACTUAL_HOME/mynodeone-argocd-credentials.txt <<EOF
ArgoCD Credentials
==================
Username: admin
Password: $ARGOCD_PASSWORD
URL: https://$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

WARNING: Store these credentials securely and delete this file after saving them elsewhere.
EOF
    chmod 600 $ACTUAL_HOME/mynodeone-argocd-credentials.txt
    chown $ACTUAL_USER:$ACTUAL_USER $ACTUAL_HOME/mynodeone-argocd-credentials.txt
    
    if [[ " ${FAILED_COMPONENTS[*]} " == *" argocd "* ]]; then
        log_warn "ArgoCD is not fully installed: see the errors above"
    else
        log_success "ArgoCD installed"
    fi
    log_warn "ArgoCD credentials saved to $ACTUAL_HOME/mynodeone-argocd-credentials.txt (chmod 600)"
    log_warn "IMPORTANT: Save these credentials securely and delete the file"
}

deploy_dashboard() {
    log_info "Deploying MyNodeOne Dashboard..."
    
    # Deploy the dashboard once, capture output to check for errors
    local deploy_output
    deploy_output=$(bash "$PROJECT_ROOT/website/deploy-dashboard.sh" 2>&1) || true
    
    if echo "$deploy_output" | grep -qE "error|Error|ERROR|failed|Failed|FAILED"; then
        log_warn "Dashboard deployment had issues, but continuing..."
        echo "$deploy_output" | grep -E "error|Error|ERROR|failed|Failed|FAILED" >&2
    else
        log_success "Dashboard deployed - accessible at http://${CLUSTER_DOMAIN}.local"
    fi
}

create_cluster_info() {
    log_info "Creating cluster information configmap..."
    
    # Use PROJECT_ROOT which is already correctly set by project-root.sh at script startup
    REPO_PATH="$PROJECT_ROOT"
    
    # Detect control plane user from repo path (e.g., /home/your-username/MyNodeOne -> your-username)
    CONTROL_PLANE_USER=$(echo "$REPO_PATH" | sed 's|/home/\([^/]*\)/.*|\1|')
    if [ -z "$CONTROL_PLANE_USER" ] || [ "$CONTROL_PLANE_USER" = "$REPO_PATH" ]; then
        CONTROL_PLANE_USER="$ACTUAL_USER"
    fi
    
    # Create configmap with cluster metadata for management laptops and workers to discover
    kubectl create configmap cluster-info \
        --from-literal=cluster-name="$CLUSTER_NAME" \
        --from-literal=cluster-domain="$CLUSTER_DOMAIN" \
        --from-literal=control-plane-ip="$TAILSCALE_IP" \
        --from-literal=control-plane-user="$CONTROL_PLANE_USER" \
        --from-literal=repo-path="$REPO_PATH" \
        --namespace=kube-system \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "Cluster info configmap created"
    log_info "Repository path saved: $REPO_PATH"
    log_info "Control plane user: $CONTROL_PLANE_USER"
}

create_cluster_token() {
    log_info "Checking the node join token..."

    # The token already lives in a root-only file, so no copy is kept in the home
    # directory. Remove the one that older installs wrote.
    local old_token_file="$ACTUAL_HOME/mynodeone-join-token.txt"
    if [ -f "$old_token_file" ]; then
        shred -fz -n 3 "$old_token_file" 2>/dev/null || true
        rm -f "$old_token_file"
        log_success "Removed the old join token copy: $old_token_file"
    fi

    # Without agent-token-file, K3s makes server/agent-token a link to the server token.
    local agent_token_path="$K3S_DATA_DIR/server/agent-token"
    if [ -L "$agent_token_path" ]; then
        log_warn "This cluster has no separate agent token: workers join with the server token"
    fi

    log_success "To add a worker, run scripts/nodes/add-worker-node.sh on it and give it:"
    log_info "  Server URL: https://$TAILSCALE_IP:6443"
    log_info "  Token:      sudo cat $agent_token_path"
}

initialize_service_registries() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Initializing Service Registry System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    log_info "Creating service registry..."
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" init || true
    
    log_info "Creating multi-domain registry..."
    bash "$PROJECT_ROOT/scripts/domains/multi-domain-registry.sh" init || true
    
    log_info "Initializing enterprise node registry..."
    bash "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" init || {
        log_warn "Could not initialize node registry (kubectl may not be ready yet)"
        log_info "Registry will be initialized on first node registration"
    }
    
    # VALIDATION: Verify ConfigMaps were created
    log_info "Validating registry initialization..."
    local validation_passed=true
    
    if ! kubectl get cm service-registry -n kube-system &>/dev/null; then
        log_warn "⚠ service-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ service-registry ConfigMap exists"
    fi
    
    if ! kubectl get cm domain-registry -n kube-system &>/dev/null; then
        log_warn "⚠ domain-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ domain-registry ConfigMap exists"
    fi
    
    if ! kubectl get cm sync-controller-registry -n kube-system &>/dev/null; then
        log_warn "⚠ sync-controller-registry ConfigMap not found"
        validation_passed=false
    else
        log_success "✓ sync-controller-registry ConfigMap exists"
    fi
    
    if [ "$validation_passed" = "true" ]; then
        log_success "✓ All registries initialized successfully"
    else
        log_warn "Some registries failed to initialize - may need manual creation"
    fi
    
    log_info "Syncing existing services to registry..."
    bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" sync || true
    
    # Register platform services in the registry
    log_info "Registering platform services..."
    
    # Wait a moment for services to be fully ready
    sleep 5
    
    # Register Grafana
    if kubectl get svc -n monitoring kube-prometheus-stack-grafana &>/dev/null; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "kube-prometheus-stack-grafana" "grafana" "monitoring" \
            "kube-prometheus-stack-grafana" "80" "false" 2>/dev/null || \
            log_warn "Could not register Grafana (will retry later)"
    fi
    
    # Register ArgoCD
    if kubectl get svc -n argocd argocd-server &>/dev/null; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "argocd-server" "argocd" "argocd" \
            "argocd-server" "80" "false" 2>/dev/null || \
            log_warn "Could not register ArgoCD (will retry later)"
    fi
    
    # MinIO is now installed on worker node (not control plane)
    # Registration will happen when worker joins
    
    # Register Longhorn (if LoadBalancer type)
    if kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.spec.type}' 2>/dev/null | grep -q "LoadBalancer"; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "longhorn-frontend" "longhorn" "longhorn-system" \
            "longhorn-frontend" "80" "false" 2>/dev/null || \
            log_warn "Could not register Longhorn (will retry later)"
    fi
    
    # Register Dashboard
    if kubectl get svc -n mynodeone-dashboard dashboard &>/dev/null; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" register \
            "dashboard" "dashboard" "mynodeone-dashboard" \
            "dashboard" "80" "false" 2>/dev/null || \
            log_warn "Could not register Dashboard (will retry later)"
    fi
    
    log_success "Platform services registered in service registry"
    log_success "Service registry initialized"
    
    # Install sync controller as systemd service
    if [ ! -f /etc/systemd/system/mynodeone-sync-controller.service ]; then
        log_info "Installing sync controller service..."
        
        # Update the service file with correct paths
        sed "s|MYNODEONE_INSTALL_PATH|$PROJECT_ROOT|g" \
            "$PROJECT_ROOT/scripts/lib/mynodeone-sync-controller.service" | \
            sudo tee /etc/systemd/system/mynodeone-sync-controller.service > /dev/null
        
        sudo systemctl daemon-reload
        sudo systemctl enable mynodeone-sync-controller
        sudo systemctl start mynodeone-sync-controller
        
        # Verify service actually started
        sleep 2
        if sudo systemctl is-active --quiet mynodeone-sync-controller; then
            log_success "Sync controller service started successfully"
        else
            log_warn "Sync controller service may not have started correctly"
            log_info "Check status: sudo systemctl status mynodeone-sync-controller"
        fi
        
        # Install local DNS sync timer (updates control plane /etc/hosts every 1 minute)
        if [ ! -f /etc/systemd/system/mynodeone-local-dns-sync.timer ]; then
            log_info "Enabling periodic local DNS sync..."
            if bash "$PROJECT_ROOT/scripts/setup/enable-local-dns-sync.sh" > /dev/null 2>&1; then
                log_success "Local DNS sync timer enabled (updates every 1 minute)"
            else
                log_warn "Local DNS sync setup failed (non-critical)"
            fi
        else
            log_info "Local DNS sync timer already enabled"
        fi
    else
        log_info "Sync controller service already installed"
        # Ensure it's running
        if ! sudo systemctl is-active --quiet mynodeone-sync-controller; then
            log_info "Starting sync controller service..."
            sudo systemctl start mynodeone-sync-controller
        fi
        
        # Check if local DNS sync timer is already enabled
        if [ -f /etc/systemd/system/mynodeone-local-dns-sync.timer ]; then
            log_info "Local DNS sync timer already enabled"
        else
            log_info "Enabling periodic local DNS sync..."
            if bash "$PROJECT_ROOT/scripts/setup/enable-local-dns-sync.sh" > /dev/null 2>&1; then
                log_success "Local DNS sync timer enabled (updates every 1 minute)"
            else
                log_warn "Local DNS sync setup failed (non-critical)"
            fi
        fi
    fi
    
    # Register control plane itself as a management laptop
    # This ensures it receives DNS updates when apps are installed from remote laptops
    log_info "Registering control plane for automatic DNS updates..."
    
    CONTROL_PLANE_HOSTNAME=$(hostname)
    CONTROL_PLANE_USER="${SUDO_USER:-$(whoami)}"
    
    # Use sudo for registration (needs root to update ConfigMap)
    if sudo bash "$PROJECT_ROOT/scripts/lib/node-registry-manager.sh" register \
        "management_laptops" "$TAILSCALE_IP" "$CONTROL_PLANE_HOSTNAME" \
        "$CONTROL_PLANE_USER" "" "$PROJECT_ROOT"; then
        log_success "✓ Control plane registered for DNS sync"
        log_info "  • Control plane will receive DNS updates from remote installations"
        log_info "  • Local installations will update DNS immediately"
    else
        log_warn "Could not register control plane (DNS sync may require manual updates)"
        log_info "You can register manually later: sudo ./scripts/lib/node-registry-manager.sh register ..."
    fi
    
    # Install Config API Server (V2 sync system)
    if [ -f "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/install-config-sync.sh" control-plane; then
            log_success "Config API Server installed"
            
            # Installers log to files and terminals, so name the file, not the token
            if [ -f /etc/mynodeone/api-token ]; then
                log_info "API token for node agents is stored in /etc/mynodeone/api-token (root only)"
                log_info "Needed when adding VPS/worker nodes: sudo cat /etc/mynodeone/api-token"
            fi
        else
            log_warn "Config API Server installation had issues"
            log_warn "You can install manually later: sudo ./scripts/lib/install-config-sync.sh control-plane"
        fi
    else
        log_warn "Config sync installer not found, skipping"
    fi
    
    echo
    log_success "Registry system ready"
    log_info "  • Service registry: Tracks all cluster services"
    log_info "  • Multi-domain registry: Supports multiple domains and VPS"
    log_info "  • Sync controller (V1): SSH-based push to nodes"
    log_info "  • Config API (V2): HTTP-based pull with heartbeat"
    log_info "  • Control plane: Receives automatic DNS updates"
    echo
}

display_credentials() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 IMPORTANT: YOUR SERVICE CREDENTIALS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "⚠️  SAVE THESE CREDENTIALS NOW - They won't be shown again"
    echo
    
    # Get IPs
    DASHBOARD_IP=$(kubectl get svc -n mynodeone-dashboard dashboard -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    GRAFANA_IP=$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    ARGOCD_IP=$(kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    
    # Longhorn uses NodePort by default, so get the LoadBalancer IP or fall back to node IP:port
    LONGHORN_LB_IP=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$LONGHORN_LB_IP" ]; then
        LONGHORN_URL="http://$LONGHORN_LB_IP"
    else
        # Use NodePort (default is 30080)
        LONGHORN_PORT=$(kubectl get svc -n longhorn-system longhorn-frontend -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30080")
        LONGHORN_URL="http://${TAILSCALE_IP}:${LONGHORN_PORT}"
    fi
    
    # Get passwords
    GRAFANA_PASS=$(kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "See file below")
    
    # Get MinIO credentials if available
    MINIO_USER=$(kubectl get secret -n minio minio-credentials -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    MINIO_PASS=$(kubectl get secret -n minio minio-credentials -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
    MINIO_API_IP=$(kubectl get svc -n minio -o jsonpath='{.items[?(@.metadata.name=="minio-'$(hostname)'")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    MINIO_CONSOLE_IP=$(kubectl get svc -n minio -o jsonpath='{.items[?(@.metadata.name=="minio-console-'$(hostname)'")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    echo "🏠 MYNODEONE DASHBOARD:"
    echo "   URL: http://$DASHBOARD_IP (also at http://${CLUSTER_DOMAIN}.local)"
    echo "   Features: Cluster status, one-click apps, script browser"
    echo
    
    echo "📊 GRAFANA (Monitoring Dashboard):"
    echo "   URL: http://$GRAFANA_IP (also http://grafana.${CLUSTER_DOMAIN}.local)"
    echo "   Username: admin"
    echo "   Password: $GRAFANA_PASS"
    echo
    
    echo "🚀 ARGOCD (GitOps):"
    echo "   URL: https://$ARGOCD_IP (also http://argocd.${CLUSTER_DOMAIN}.local)"
    if [ -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt ]; then
        cat $ACTUAL_HOME/mynodeone-argocd-credentials.txt | grep -E "Username|Password" | sed 's/^/   /'
    fi
    echo
    
    echo "📦 LONGHORN (Storage Dashboard):"
    echo "   URL: $LONGHORN_URL (also http://longhorn.${CLUSTER_DOMAIN}.local)"
    echo "   Authentication: None (protected by Tailscale VPN)"
    echo
    
    # Show MinIO credentials if installed
    if [ -n "$MINIO_USER" ] && [ -n "$MINIO_PASS" ]; then
        echo "🗄️ MINIO (Object Storage):"
        local NODE_NAME=$(hostname)
        if [ -n "$MINIO_API_IP" ]; then
            echo "   API URL: http://$MINIO_API_IP:9000 (also http://minio-${NODE_NAME}.${CLUSTER_DOMAIN}.local:9000)"
        fi
        if [ -n "$MINIO_CONSOLE_IP" ]; then
            echo "   Console: http://$MINIO_CONSOLE_IP:9001 (also http://minio-console-${NODE_NAME}.${CLUSTER_DOMAIN}.local:9001)"
        fi
        echo "   Username: $MINIO_USER"
        echo "   Password: $MINIO_PASS"
        echo
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📝 CRITICAL SECURITY STEP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "⚠️  IMPORTANT: Save these credentials NOW"
    echo
    echo "🔐 SAVE TO PASSWORD MANAGER:"
    echo "   Install on YOUR LAPTOP (not this machine):"
    echo "   • 1Password (https://1password.com) - Paid, best UX"
    echo "   • Bitwarden (https://bitwarden.com) - Free & Open Source"
    echo "   • KeePassXC (https://keepassxc.org) - Free, Offline"
    echo
    echo "📋 ACTION: Copy ALL credentials above to your password manager NOW"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    # In unattended mode, keep credentials for display at the end
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Credentials will be displayed at the end of installation"
        log_info "They will remain visible so you can copy them to your password manager"
        # Don't delete yet - will delete after final display
        return
    else
        echo
        echo "⏱️  Take your time to save the credentials above."
        echo
        read -p "Have you saved ALL credentials to your password manager? [y/N]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            delete_credential_files
        else
            echo
            log_warn "Credential files are still on disk until you confirm they are saved."
            log_warn "For security, delete them once they are in your password manager."
            echo
            echo "Options:"
            echo "  1. Save credentials now and re-run this confirmation"
            echo "  2. View credentials again: sudo $SCRIPT_DIR/../utils/show-credentials.sh"
            echo "  3. Credentials are in: $ACTUAL_HOME/mynodeone-*-credentials.txt"
            echo
            read -p "Try again - Have you saved credentials? [y/N]: " -r
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                delete_credential_files
            else
                log_error "Please save credentials and manually delete files:"
                echo "  sudo rm $ACTUAL_HOME/mynodeone-*-credentials.txt"
                echo
                # Only a warning, so the steps after this one still run. Stopping here
                # would leave this node with no backup timer, not a safer credentials file.
                log_warn "WARNING: Leaving credential files on disk is a security risk"
            fi
        fi
    fi
    
    echo
    echo "📖 Next steps:"
    echo "   • Change default passwords (first login to each service)"
    echo "   • Full security guide: cat $PROJECT_ROOT/SECURITY_CREDENTIALS_GUIDE.md"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

delete_credential_files() {
    log_info "Securely deleting credential files..."
    
    local files_deleted=0
    
    if [ -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt ]; then
        shred -vfz -n 3 $ACTUAL_HOME/mynodeone-argocd-credentials.txt 2>/dev/null || rm -f $ACTUAL_HOME/mynodeone-argocd-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    # MinIO credentials now saved on worker node (not control plane)
    
    if [ -f $ACTUAL_HOME/mynodeone-grafana-credentials.txt ]; then
        shred -vfz -n 3 $ACTUAL_HOME/mynodeone-grafana-credentials.txt 2>/dev/null || rm -f $ACTUAL_HOME/mynodeone-grafana-credentials.txt
        files_deleted=$((files_deleted + 1))
    fi
    
    # The join token is not a file here: read it from the k3s data directory when needed

    if [ $files_deleted -gt 0 ]; then
        log_success "✅ Credential files securely deleted ($files_deleted files)"
        log_info "To add a node, read the join token with: sudo cat $K3S_DATA_DIR/server/agent-token"
    else
        log_warn "No credential files found to delete"
    fi
}

print_summary() {
    local monitoring_mark="✓" argocd_mark="✓"
    if [[ " ${FAILED_COMPONENTS[*]} " == *" kube-prometheus-stack "* || " ${FAILED_COMPONENTS[*]} " == *" loki "* ]]; then
        monitoring_mark="✗"
    fi
    if [[ " ${FAILED_COMPONENTS[*]} " == *" argocd "* ]]; then
        argocd_mark="✗"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "${#FAILED_COMPONENTS[@]}" -gt 0 ]; then
        echo "  MyNodeOne Control Plane Installed, But These Failed: ${FAILED_COMPONENTS[*]}"
    else
        echo "  🎉 MyNodeOne Control Plane Installed Successfully"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Installed Components:"
    echo "  ✓ K3s Kubernetes"
    echo "  ✓ Helm"
    echo "  ✓ cert-manager (Certificate Management)"
    echo "  ✓ MetalLB (Load Balancer)"
    echo "  ✓ Traefik (Ingress Controller)"
    echo "  ✓ Longhorn (Distributed Storage)"
    echo "  $monitoring_mark Prometheus + Grafana + Loki (Monitoring)"
    echo "  $argocd_mark ArgoCD (GitOps)"
    echo "  ✓ Tailscale Subnet Routes (Network Access)"
    
    # Show GPU status if NVIDIA GPU is present
    if lspci | grep -i nvidia &> /dev/null && command -v nvidia-smi &>/dev/null; then
        local GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")
        if [ -n "$GPU_COUNT" ] && [ "$GPU_COUNT" != "0" ]; then
            echo "  ✓ NVIDIA GPU Support ($GPU_COUNT GPU(s) available)"
        else
            echo "  ⚠ NVIDIA GPU Support (device plugin starting...)"
        fi
    fi
    echo
    
    # Display credentials prominently
    display_credentials
    
    echo
    echo "⚠️  IMPORTANT: Approve Tailscale Subnet Route"
    echo "   To access services from your laptop, approve the subnet route:"
    echo "   → https://login.tailscale.com/admin/machines"
    echo "   → Find this machine → Edit route settings → Enable subnet"
    echo "   (Takes 30 seconds, enables .local domain access)"
    echo
    echo "📄 What To Do Next:"
    echo "  🎯 READ THIS FIRST: $PROJECT_ROOT/docs/guides/POST_INSTALLATION_GUIDE.md"
    echo "  • Shows exactly what to do after installation"
    echo "  • How to access from your laptop"
    echo "  • Deploying your first app"
    echo "  • Monitoring and managing the cluster"
    echo
    echo "📄 Additional Resources:"
    echo "  • View credentials anytime: sudo $SCRIPT_DIR/../utils/show-credentials.sh"
    echo "  • Demo app guide: $PROJECT_ROOT/docs/guides/DEMO_APP_GUIDE.md"
    echo "  • Deploy apps easily: $PROJECT_ROOT/docs/guides/APP_DEPLOYMENT_GUIDE.md"
    echo "  • Security guide: $PROJECT_ROOT/docs/guides/SECURITY_CREDENTIALS_GUIDE.md"
    echo "  • Quick reference: $PROJECT_ROOT/docs/reference/ACCESS_INFORMATION.md"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "🎯 WHAT TO DO NEXT:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Your control plane is running! Here's what to do next:"
    echo
    
    # Show VPS setup if configured
    if [ "${VPS_COUNT:-0}" -gt 0 ]; then
        echo "📡 STEP 1: Configure Your VPS Edge Node(s)"
        echo "   You said you have $VPS_COUNT VPS node(s) for public internet access."
        echo
        echo "   On EACH VPS machine, run:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ cd ~/MyNodeOne                                              │"
        echo "   │ sudo ./scripts/installation/install-mynodeone.sh                                    │"
        echo "   │ # Select 'VPS Edge Node' when asked                        │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
        echo "   This will:"
        echo "     • Install Tailscale and join your VPN"
        echo "     • Set up reverse proxy (Caddy with auto-HTTPS)"
        echo "     • Configure domains for public access"
        echo
    fi
    
    echo "📊 STEP ${VPS_COUNT:+2}: Verify Your Cluster is Healthy"
    echo "   Check that all components are running:"
    echo "   ┌─────────────────────────────────────────────────────────────┐"
    echo "   │ kubectl get nodes                                           │"
    echo "   │ kubectl get pods -A                                         │"
    echo "   └─────────────────────────────────────────────────────────────┘"
    echo
    echo "   All pods should be 'Running' or 'Completed' within 5-10 minutes."
    echo
    
    echo "🌐 STEP ${VPS_COUNT:+3}: Access Web Dashboards"
    echo "   These are available via Tailscale (100.x.x.x addresses):"
    echo
    echo "   📊 Grafana (Metrics & Logs):"
    echo "      URL: http://$GRAFANA_IP"
    echo "      Also: http://grafana.${CLUSTER_DOMAIN}.local"
    echo "      Username: admin"
    echo "      Password: Run this command to get it:"
    echo "      kubectl get secret -n monitoring kube-prometheus-stack-grafana \\"
    echo "        -o jsonpath=\"{.data.admin-password}\" | base64 -d && echo"
    echo
    echo "   🚀 ArgoCD (GitOps Deployments):"
    echo "      URL: https://$ARGOCD_IP"
    echo "      Also: http://argocd.${CLUSTER_DOMAIN}.local"
    echo "      Credentials: cat $ACTUAL_HOME/mynodeone-argocd-credentials.txt"
    echo
    echo "   📦 Longhorn UI (Block Storage):"
    echo "      URL: $LONGHORN_URL"
    echo "      Also: http://longhorn.${CLUSTER_DOMAIN}.local"
    echo "      (No authentication required - protected by Tailscale VPN)"
    echo
    echo "   📘 For complete access information, see:"
    echo "      cat $PROJECT_ROOT/ACCESS_INFORMATION.md"
    echo
    
    echo "🚀 STEP ${VPS_COUNT:+4}: Deploy Your First Application"
    echo "   Example: Deploy a test web app"
    echo "   ┌─────────────────────────────────────────────────────────────┐"
    echo "   │ # Create a simple nginx deployment                          │"
    echo "   │ kubectl create deployment nginx --image=nginx               │"
    echo "   │ kubectl expose deployment nginx --port=80 --type=LoadBalancer│"
    echo "   │                                                              │"
    echo "   │ # Check the external IP assigned                            │"
    echo "   │ kubectl get svc nginx                                       │"
    echo "   │                                                              │"
    echo "   │ # Access via browser: http://<EXTERNAL-IP>                  │"
    echo "   └─────────────────────────────────────────────────────────────┘"
    echo
    
    # Show LLM-specific guidance if enabled
    if [ "${RUN_LLMS:-false}" = "true" ]; then
        echo "🤖 BONUS: Run LLMs (You enabled AI support!)"
        echo "   Deploy Ollama for local LLM hosting:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ # Install Ollama on Kubernetes                              │"
        echo "   │ kubectl create namespace ollama                             │"
        echo "   │ # See: docs/ollama-deployment.md for full guide             │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
    fi
    
    # Show database guidance if enabled
    if [ "${RUN_DATABASES:-false}" = "true" ]; then
        echo "🗄️  BONUS: Deploy Databases (You enabled database support!)"
        echo "   Easy database deployment with operators:"
        echo "   ┌─────────────────────────────────────────────────────────────┐"
        echo "   │ # PostgreSQL example                                        │"
        echo "   │ kubectl create namespace postgres                           │"
        echo "   │ # See: docs/database-examples.md for guides                 │"
        echo "   └─────────────────────────────────────────────────────────────┘"
        echo
    fi
    
    echo "📚 MORE RESOURCES:"
    echo "   • Getting Started Guide: $PROJECT_ROOT/docs/guides/GETTING-STARTED.md"
    echo "   • Operations Guide: $PROJECT_ROOT/docs/operations/ADMIN-GUIDE.md"
    echo "   • FAQ: $PROJECT_ROOT/docs/reference/FAQ.md"
    echo "   • Troubleshooting: $PROJECT_ROOT/docs/operations/troubleshooting.md"
    echo
    echo "💡 HELPFUL COMMANDS:"
    echo "   kubectl get all -A              # See everything"
    echo "   kubectl logs -n <ns> <pod>      # View pod logs"
    echo "   kubectl describe node <name>    # Node details"
    echo "   k9s                              # Terminal UI (if installed)"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "🎉 CONGRATULATIONS! Your MyNodeOne cluster is ready"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

offer_security_hardening() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔒 Core Security: Already Enabled"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_success "These security features are enabled on your cluster:"
    echo "  ✅ Secrets encryption at rest (AES-256)"
    echo "  ✅ Kubernetes audit logging"
    echo "  ✅ Pod Security Standards (baseline enforcement)"
    echo "  ✅ Firewall enabled (UFW)"
    echo "  ✅ Fail2ban protection"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🛡️  Optional: Additional Security Enhancements"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy optional security enhancements?"
    echo
    echo "This adds:"
    echo "  • Network policies (default deny + explicit allow)"
    echo "  • Resource quotas (prevent DoS attacks)"
    echo "  • Traefik security headers (HSTS, CSP, XSS protection)"
    echo
    echo "Recommended: YES for production, OPTIONAL for home/testing"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping optional security enhancements"
        log_info "You can add them later with: sudo $SCRIPT_DIR/../setup/enable-security-hardening.sh"
        return
    fi
    
    read -p "Deploy optional security enhancements? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying optional security enhancements..."
        if bash "$PROJECT_ROOT/scripts/setup/enable-security-hardening.sh"; then
            log_success "Optional security enhancements deployed"
            echo
            echo "✅ Network policies active"
            echo "✅ Resource quotas enforced"
            echo "✅ Traefik security headers configured"
        else
            log_warn "Deployment had issues. You can try again later with:"
            echo "  sudo $PROJECT_ROOT/scripts/setup/enable-security-hardening.sh"
        fi
    else
        echo
        log_info "Skipping optional enhancements. Your cluster still has strong core security."
        echo
        log_info "You can add them anytime with:"
        echo "  sudo $PROJECT_ROOT/scripts/setup/enable-security-hardening.sh"
    fi
}

setup_local_dns() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Setting Up Local DNS Resolution"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Configuring easy-to-remember domain names for services..."
    echo
    
    # Wait for all LoadBalancer IPs to be assigned (with retry)
    log_info "Waiting for LoadBalancer IPs to be assigned..."
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local pending=$(kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.status.loadBalancer.ingress == null) | .metadata.name' | wc -l)
        if [ "$pending" -eq 0 ]; then
            log_success "All LoadBalancer IPs assigned"
            break
        fi
        echo -n "."
        sleep 2
        waited=$((waited + 2))
    done
    echo
    
    if [ $waited -ge $max_wait ]; then
        log_warn "Some LoadBalancer IPs still pending after ${max_wait}s"
        log_info "Services with pending IPs:"
        kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.status.loadBalancer.ingress == null) | "\(.metadata.namespace)/\(.metadata.name)"'
        echo
    fi
    
    log_info "Setting up local DNS for .local domains..."
    log_info "Waiting 30 seconds for LoadBalancer IPs to be assigned..."
    sleep 30
    
    local dns_retry=0
    local dns_max_retries=3
    local dns_success=false
    
    while [ $dns_retry -lt $dns_max_retries ]; do
        if bash "$PROJECT_ROOT/scripts/setup/setup-local-dns.sh"; then
            dns_success=true
            break
        else
            log_warn "DNS setup failed (attempt $((dns_retry + 1))/$dns_max_retries)"
            log_info "Waiting 15 more seconds for services to be ready..."
            sleep 15
            dns_retry=$((dns_retry + 1))
        fi
    done
    
    if [ "$dns_success" = true ]; then
        log_success "Local DNS setup complete"
        echo
        
        # Verify DNS resolution works
        log_info "Verifying DNS resolution..."
        local dns_ok=true
        for service in "grafana.${CLUSTER_DOMAIN}.local" "argocd.${CLUSTER_DOMAIN}.local"; do
            if getent hosts "$service" >/dev/null 2>&1; then
                echo "  ✓ $service"
            else
                echo "  ✗ $service (not resolving)"
                dns_ok=false
            fi
        done
        echo
        
        if [ "$dns_ok" = true ]; then
            log_success "DNS verification passed"
        else
            log_warn "Some DNS entries not resolving yet. May need a few seconds to propagate."
        fi
        
        echo "✅ You can now use .local domain names on this server"
        echo
        log_info "To access from other devices (laptop, phone):"
        echo "  1. Ensure Tailscale is installed and connected"
        echo "  2. Copy the setup script: $PROJECT_ROOT/setup-client-dns.sh"
        echo "  3. Run: sudo bash setup-client-dns.sh"
    else
        log_warn "Local DNS setup failed after $dns_max_retries attempts."
        log_warn "You can set it up later with:"
        echo "  sudo $SCRIPT_DIR/../setup/setup-local-dns.sh"
    fi
}

run_final_validation() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔍 Final Validation: Testing Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Running comprehensive installation validation..."
    log_info "This verifies: Kubernetes, services, registry, DNS, and more"
    echo
    
    # Run unified validation script
    if [ -f "$PROJECT_ROOT/scripts/lib/validate-installation.sh" ]; then
        if bash "$PROJECT_ROOT/scripts/lib/validate-installation.sh" control-plane; then
            echo
            log_success "🎉 INSTALLATION VALIDATION PASSED"
            log_info "Your control plane is fully operational"
            
            # Save validation timestamp
            echo "LAST_VALIDATION=$(date -Iseconds)" >> $ACTUAL_HOME/.mynodeone/config.env
            echo "VALIDATION_STATUS=passed" >> $ACTUAL_HOME/.mynodeone/config.env
        else
            echo
            log_error "❌ INSTALLATION VALIDATION FAILED"
            log_warn "Some components may need attention (see details above)"
            log_info "You can re-run validation anytime:"
            echo "  sudo bash $PROJECT_ROOT/scripts/lib/validate-installation.sh control-plane"
            
            # Save validation status
            echo "LAST_VALIDATION=$(date -Iseconds)" >> $ACTUAL_HOME/.mynodeone/config.env
            echo "VALIDATION_STATUS=failed" >> $ACTUAL_HOME/.mynodeone/config.env
            
            # Ask if user wants to continue
            if [ "${UNATTENDED:-0}" != "1" ]; then
                echo
                read -p "Continue despite validation failures? [y/N]: " -r
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_info "Installation paused. Fix issues and re-run validation."
                    exit 1
                fi
            fi
        fi
    else
        log_warn "Validation script not found at: $SCRIPT_DIR/../lib/validate-installation.sh"
        log_info "Skipping automated validation"
    fi
}

offer_demo_app() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🚀 Optional: Deploy Demo Application"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy a demo web application to test your cluster?"
    echo
    echo "This will deploy a secure demo app that showcases:"
    echo "  • Proper Pod Security Standards compliance"
    echo "  • LoadBalancer service integration"
    echo "  • Working storage and networking"
    echo
    echo "You can remove it anytime with: kubectl delete namespace demo-apps"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping demo app deployment"
        return
    fi
    
    read -p "Deploy demo app now? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying demo application..."
        if bash "$PROJECT_ROOT/scripts/operations/deploy-demo-app.sh" deploy; then
            log_success "Demo app deployment complete"
        else
            log_warn "Demo app deployment had issues. You can deploy it later with:"
            echo "  sudo $PROJECT_ROOT/scripts/operations/deploy-demo-app.sh"
        fi
    else
        echo
        log_info "Skipping demo app. You can deploy it anytime with:"
        echo "  sudo $PROJECT_ROOT/scripts/operations/deploy-demo-app.sh"
    fi
}

offer_llm_chat() {
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🤖 Optional: Deploy LLM Chat Application"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Would you like to deploy a local AI chat application?"
    echo
    echo "This deploys Open WebUI + Ollama for:"
    echo "  • 100% local AI chat (no cloud API needed)"
    echo "  • Your data stays on your cluster"
    echo "  • ChatGPT-like interface"
    echo "  • Multiple LLM models available"
    echo
    echo "Requirements: 4GB+ RAM available, 50GB+ storage"
    echo
    echo "You can remove it anytime with: kubectl delete namespace llm-chat"
    echo
    
    # Skip prompt in unattended mode
    if [ "${UNATTENDED:-0}" = "1" ]; then
        log_info "UNATTENDED mode: Skipping LLM chat deployment"
        return
    fi
    
    read -p "Deploy LLM chat app now? [y/N]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        log_info "Deploying LLM chat application..."
        # Use the new app store installation script (auto-skips prompts for subdomain/VPS during bootstrap)
        export AUTO_INSTALL_MODE=true
        if bash "$PROJECT_ROOT/scripts/apps/llm-chat/install-llm-chat.sh"; then
            log_success "LLM chat deployment complete"
            echo
            log_info "LLM Chat installed locally. To add public internet access later:"
            echo "  sudo bash scripts/apps/llm-chat/install-llm-chat.sh"
        else
            log_warn "LLM chat deployment had issues. You can deploy it later with:"
            echo "  sudo bash scripts/apps/llm-chat/install-llm-chat.sh"
        fi
        unset AUTO_INSTALL_MODE
    else
        echo
        log_info "Skipping LLM chat. You can deploy it anytime with:"
        echo "  sudo bash scripts/apps/llm-chat/install-llm-chat.sh"
    fi
}

install_control_plane_node_agent() {
    # Use the local installation script
    if [ -f "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" ]; then
        # The installer reads the token we just generated/verified from this root-only
        # file, so it never appears in `ps`. If the file is missing, the installer keeps
        # the token in an existing agent.env, or fails and we warn below.
        local token_args=()
        if [ -f /etc/mynodeone/api-token ]; then
            token_args=(--api-token-file /etc/mynodeone/api-token)
        fi

        # Determine the best IP for the agent to reach the API
        # On the control plane, 127.0.0.1 is always safer as a fallback
        local agent_target_ip="${TAILSCALE_IP:-}"
        if [ -z "$agent_target_ip" ]; then
            agent_target_ip=$(tailscale ip -4 2>/dev/null || echo "127.0.0.1")
        fi
        
        # Run agent installer
        # Using node-type=laptop for control plane to ensure local DNS syncing behavior
        if bash "$PROJECT_ROOT/scripts/installation/install-node-agent.sh" \
            --control-plane-ip "$agent_target_ip" \
            --node-type "laptop" \
            --node-name "$NODE_NAME" \
            ${token_args[@]+"${token_args[@]}"}; then
            log_success "Node Agent installed on Control Plane"
        else
            log_warn "Node Agent installation failed"
            log_warn "You can install it manually later with:"
            log_warn "  sudo ./scripts/installation/install-node-agent.sh --control-plane-ip 127.0.0.1 --node-type laptop --node-name $NODE_NAME"
        fi
    else
        log_warn "Node Agent installer not found ($PROJECT_ROOT/scripts/installation/install-node-agent.sh)"
    fi
}

display_final_credentials_unattended() {
    echo
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "  🔐 FINAL STEP: SAVE YOUR CREDENTIALS"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_warn "UNATTENDED MODE: Installation complete! Now save these credentials:"
    echo
    
    # Display all credentials again
    display_credentials
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "📋 IMPORTANT: Copy ALL credentials above to your password manager NOW"
    echo
    echo "Recommended password managers:"
    echo "  • 1Password (https://1password.com)"
    echo "  • Bitwarden (https://bitwarden.com)"
    echo "  • KeePassXC (https://keepassxc.org)"
    echo
    echo "⚠️  After you save them, delete the credential files for security:"
    echo "   sudo rm $ACTUAL_HOME/mynodeone-*-credentials.txt"
    echo
    echo "💡 You can view credentials anytime with:"
    echo "   sudo $SCRIPT_DIR/../utils/show-credentials.sh"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
}

main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MyNodeOne Control Plane Bootstrap"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    check_requirements
    ensure_tailscale_ready
    install_dependencies
    configure_k8s_network_prereqs
    configure_firewall
    optimize_system_for_containers
    install_k3s
    configure_k3s_service_dependencies "k3s"
    setup_gpu_support  # Configure GPU after K3s is installed (if NVIDIA GPU present)
    install_helm
    install_kompose  # For external app deployment (docker-compose conversion)
    create_priority_classes  # Create PriorityClasses before installing infrastructure
    install_cert_manager
    install_metallb
    configure_tailscale_subnet_routes
    install_traefik
    install_longhorn  # Interactive Longhorn installation
    install_minio     # Interactive MinIO installation (optional)
    install_monitoring
    install_argocd
    deploy_dashboard
    create_cluster_info
    create_cluster_token
    initialize_service_registries
    deploy_nvidia_device_plugin  # Deploy GPU device plugin after cluster is ready
    
    echo
    print_summary
    
    # Offer security hardening
    offer_security_hardening
    
    # Setup local DNS automatically
    setup_local_dns
    
    # Run comprehensive validation AFTER DNS is setup
    run_final_validation
    
    # Offer to deploy demo app
    offer_demo_app
    
    # Offer to deploy LLM chat app
    offer_llm_chat
    
    # Config API Server already installed during initialize_service_registries()
    # Verify it's running
    if [ -f /etc/mynodeone/api-token ]; then
        log_success "Config API Server verified (installed during registry setup)"
        log_info "API token stored in: /etc/mynodeone/api-token"
    else
        log_warn "Config API Server may not have installed correctly during registry setup"
        log_warn "You can install manually: sudo ./scripts/lib/install-config-sync.sh control-plane"
    fi
    echo
    
    # Install Node Agent on Control Plane (Self-monitoring & Config Pull)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Installing Node Agent (Control Plane)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    log_info "Installing Node Agent on control plane..."
    
    install_control_plane_node_agent
    echo
    
    # Final sync: Ensure all services are registered and DNS is updated
    log_info "Final sync: Registering all services and updating DNS..."
    if [ -f "$PROJECT_ROOT/scripts/lib/service-registry.sh" ]; then
        bash "$PROJECT_ROOT/scripts/lib/service-registry.sh" sync 2>/dev/null || true
    fi
    if [ -f "$PROJECT_ROOT/scripts/domains/sync-dns.sh" ]; then
        bash "$PROJECT_ROOT/scripts/domains/sync-dns.sh" 2>/dev/null || true
    fi
    log_success "All services registered and DNS updated"
    echo
    
    # Install Flannel health monitor (auto-recovery for missing flannel.1 interface)
    if [ -f "$PROJECT_ROOT/scripts/validation/monitor-flannel-health.sh" ]; then
        log_info "Installing Flannel health monitor..."
        bash "$PROJECT_ROOT/scripts/validation/monitor-flannel-health.sh" --install || \
            log_warn "Flannel health monitor installation failed (non-critical)"
    fi
    
    # Local backup of the encryption key, tokens and etcd snapshots
    if [ -f "$PROJECT_ROOT/scripts/backup/backup-control-plane-state.sh" ]; then
        log_info "Installing control plane state backup..."
        bash "$PROJECT_ROOT/scripts/backup/backup-control-plane-state.sh" --install || \
            log_warn "Control plane backup: the timer install or its first backup failed, so this node has no good backup yet. Check the messages above."
        log_warn "These backups stay on this machine until you set BACKUP_REMOTE in /etc/mynodeone/backup.env"
    fi

    # Passwordless sudo for kubectl gives this user full control of the cluster, so
    # the script only adds it with the user's consent. Without it, VPS setup and
    # management scripts ask for a password or tell you to run this script.
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Final Step: Optional Passwordless Sudo for kubectl"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    if [ -f "$PROJECT_ROOT/scripts/setup/setup-control-plane-sudo.sh" ]; then
        # Don't fail the installation if this fails
        bash "$PROJECT_ROOT/scripts/setup/setup-control-plane-sudo.sh" 2>&1 || {
            log_warn "Passwordless sudo configuration had issues (non-critical)"
            log_info "To retry: $PROJECT_ROOT/scripts/setup/setup-control-plane-sudo.sh"
        }
    else
        log_warn "setup-control-plane-sudo.sh not found, skipping"
    fi
    echo

    # In unattended mode, display credentials at the end
    if [ "${UNATTENDED:-0}" = "1" ]; then
        display_final_credentials_unattended
    fi

    if [ "${#FAILED_COMPONENTS[@]}" -gt 0 ]; then
        echo
        log_error "These components did not install cleanly: ${FAILED_COMPONENTS[*]}"
        log_error "The rest of the install finished. Fix the cause shown above, then run this script again."
        exit 1
    fi
}

# Run main function
main "$@"
