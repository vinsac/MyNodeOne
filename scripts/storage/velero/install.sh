#!/bin/bash

###############################################################################
# Velero Installation Script
# 
# Installs the Velero CLI and server. No installer calls this script.
# It sets up no backup destination: run configure-backup.sh afterwards, which
# needs one chosen by you. Until then Velero runs but takes no backups.
#
# Optional environment variable:
#   VELERO_AWS_PLUGIN_IMAGE  Default: velero/velero-plugin-for-aws:v1.8.2
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap with fallback pattern (auto-discovers if path is wrong)
source "$SCRIPT_DIR/../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../../../scripts/lib/project-root.sh" 2>/dev/null || \
source "$SCRIPT_DIR/../../scripts/lib/project-root.sh" 2>/dev/null

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

retry_command() {
    local max_attempts=$1
    shift
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 5
    done
    
    return 1
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        return 1
    fi
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install Kubernetes first."
        return 1
    fi
    
    # Check if cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    log_success "Prerequisites check passed"
    return 0
}

install_velero_cli() {
    log_info "Installing Velero CLI..."
    
    # Check if already installed
    if command -v velero &> /dev/null; then
        VELERO_VERSION=$(velero version --client-only 2>/dev/null | grep -oP 'Version: v\K[0-9.]+' || echo "unknown")
        log_info "Velero CLI already installed (version: $VELERO_VERSION)"
        return 0
    fi
    
    local VELERO_VERSION="v1.12.3"
    local ARCH=$(uname -m)
    
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac
    
    log_info "Downloading Velero $VELERO_VERSION for $ARCH..."
    
    local TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    if retry_command 3 curl -fsSL "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-${ARCH}.tar.gz" -o velero.tar.gz; then
        tar -xzf velero.tar.gz
        mv velero-${VELERO_VERSION}-linux-${ARCH}/velero /usr/local/bin/
        chmod +x /usr/local/bin/velero
        rm -rf "$TEMP_DIR"
        
        # Verify installation
        if command -v velero &> /dev/null; then
            log_success "Velero CLI installed: $(velero version --client-only 2>/dev/null | head -1)"
            return 0
        else
            log_error "Velero CLI installation failed verification"
            return 1
        fi
    else
        rm -rf "$TEMP_DIR"
        log_error "Failed to download Velero CLI after 3 attempts"
        return 1
    fi
}

install_velero_server() {
    log_info "Installing Velero server components..."
    
    # Create namespace
    kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if Velero is already installed
    if kubectl get deployment velero -n velero &> /dev/null; then
        log_info "Velero server already installed"
        
        # Check if running
        local READY=$(kubectl get deployment velero -n velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "$READY" -gt 0 ]; then
            log_success "Velero server is running"
            return 0
        else
            log_warn "Velero server exists but not ready, will reinstall"
        fi
    fi
    
    # Installed with no backup location. configure-backup.sh adds the one you choose.
    # Velero rejects --provider with --no-default-backup-location and no snapshots.
    log_info "Installing Velero server..."

    if retry_command 2 velero install \
        --plugins "${VELERO_AWS_PLUGIN_IMAGE:-velero/velero-plugin-for-aws:v1.8.2}" \
        --no-default-backup-location \
        --no-secret \
        --use-volume-snapshots=false \
        --wait; then

        log_success "Velero server installed"
    else
        log_error "Velero server installation failed"
        return 1
    fi
    
    # Wait for Velero to be ready
    log_info "Waiting for Velero to be ready..."
    if kubectl wait --for=condition=available --timeout=120s deployment/velero -n velero; then
        log_success "Velero is ready"
    else
        log_warn "Velero deployment timeout, but continuing (may still be initializing)"
    fi
    
    return 0
}

verify_installation() {
    log_info "Verifying Velero installation..."
    
    # Check CLI
    if ! command -v velero &> /dev/null; then
        log_error "Velero CLI not found"
        return 1
    fi
    
    # Check server deployment
    if ! kubectl get deployment velero -n velero &> /dev/null; then
        log_error "Velero server deployment not found"
        return 1
    fi
    
    # Check pod status
    local POD_STATUS=$(kubectl get pods -n velero -l component=velero -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [ "$POD_STATUS" != "Running" ]; then
        log_warn "Velero pod is not running (status: $POD_STATUS)"
        log_warn "This may be normal if backup storage is not configured yet"
    else
        log_success "Velero pod is running"
    fi
    
    log_success "Velero installation verified"
    log_warn "No backup destination is set yet, so no backups will run."
    log_info "Choose one, then run: sudo ./scripts/storage/velero/configure-backup.sh --config <file>"
    log_info "Settings are described in scripts/storage/velero/backup.env.example"
    
    return 0
}

main() {
    log_info "===== Velero Installation ====="
    
    if ! check_requirements; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    if ! install_velero_cli; then
        log_error "Velero CLI installation failed"
        exit 1
    fi
    
    if ! install_velero_server; then
        log_error "Velero server installation failed"
        exit 1
    fi
    
    if ! verify_installation; then
        log_error "Velero verification failed"
        exit 1
    fi
    
    echo
    log_success "===== Velero Installation Complete ====="
    log_warn "Velero has no backup destination until configure-backup.sh is run."
}

main "$@"
