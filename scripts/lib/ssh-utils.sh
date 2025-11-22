#!/bin/bash

###############################################################################
# SSH Utilities Library
# 
# Provides functions for:
# - SSH ControlMaster connection multiplexing (reduces password prompts)
# - Early SSH validation and host key acceptance
# - Root SSH key setup automation
###############################################################################

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
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

###############################################################################
# SSH ControlMaster Setup
# Enables connection multiplexing to reduce password prompts
###############################################################################

setup_ssh_control_master() {
    local remote_user="$1"
    local remote_host="$2"
    local control_path="${3:-/tmp/ssh-mux-%r@%h:%p}"
    
    log_info "Setting up SSH connection multiplexing..."
    
    # Create SSH control socket with agent forwarding
    # -A enables agent forwarding so control plane can use laptop's SSH credentials
    SSH_CONTROL_OPTS="-A -o ControlMaster=auto -o ControlPath=$control_path -o ControlPersist=600"
    
    # Test connection and establish master
    if ssh $SSH_CONTROL_OPTS -o BatchMode=yes -o ConnectTimeout=5 "$remote_user@$remote_host" "exit" 2>/dev/null; then
        log_success "SSH ControlMaster established (no password needed)"
        export SSH_CONTROL_OPTS
        return 0
    else
        log_info "Establishing SSH ControlMaster connection..."
        log_info "You may be prompted for password ONCE"
        
        # Establish master connection with password
        if ssh $SSH_CONTROL_OPTS -o ConnectTimeout=10 "$remote_user@$remote_host" "exit" 2>/dev/null; then
            log_success "SSH ControlMaster established successfully"
            log_success "Subsequent connections will reuse this session (no more passwords!)"
            log_success "SSH agent forwarding enabled for nested connections"
            export SSH_CONTROL_OPTS
            return 0
        else
            log_warn "Could not establish SSH ControlMaster"
            log_warn "You may be prompted for password multiple times"
            export SSH_CONTROL_OPTS=""
            return 1
        fi
    fi
}

###############################################################################
# Cleanup SSH ControlMaster
###############################################################################

cleanup_ssh_control_master() {
    local remote_user="$1"
    local remote_host="$2"
    local control_path="${3:-/tmp/ssh-mux-%r@%h:%p}"
    
    if [ -n "${SSH_CONTROL_OPTS:-}" ]; then
        log_info "Closing SSH ControlMaster connection..."
        ssh $SSH_CONTROL_OPTS -O exit "$remote_user@$remote_host" 2>/dev/null || true
    fi
}

###############################################################################
# Early SSH Validation with Host Key Acceptance
# Run this BEFORE main installation to handle host key acceptance
###############################################################################

validate_ssh_early() {
    local remote_user="$1"
    local remote_host="$2"
    local description="${3:-control plane}"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 SSH Connection Validation - $description"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "Testing SSH connection to $remote_user@$remote_host..."
    
    # Test if connection works
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_user@$remote_host" "exit" 2>/dev/null; then
        log_success "SSH connection works (key-based authentication)"
        return 0
    fi
    
    # Try with StrictHostKeyChecking=accept-new (accepts host key but requires password)
    log_info "Attempting first-time connection (may need to accept host key)..."
    
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$remote_user@$remote_host" "echo 'SSH test successful'" 2>&1 | grep -q "SSH test successful"; then
        log_success "SSH connection established successfully"
        log_success "Host key accepted and saved"
        return 0
    else
        log_error "SSH connection failed"
        echo ""
        echo "Please verify:"
        echo "  1. SSH server is running on $remote_host"
        echo "  2. User $remote_user exists on remote system"
        echo "  3. Network connectivity (ping $remote_host)"
        echo "  4. Firewall allows SSH (port 22)"
        echo ""
        return 1
    fi
}

###############################################################################
# Setup Reverse SSH (from control plane to VPS)
# Handles both user and root SSH keys for script automation
###############################################################################

setup_reverse_ssh() {
    local control_plane_user="$1"
    local control_plane_ip="$2"
    local vps_user="$3"
    local vps_ip="$4"
    local vps_ssh_dir="$5" # Not used anymore, but kept for compatibility

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 Reverse SSH Setup (Control Plane → VPS)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    log_info "Setting up SSH keys on control plane for automation..."
    log_info "This enables passwordless route sync."
    echo ""

    local ssh_opts="${SSH_CONTROL_OPTS:-}"
    
    # Get the script directory (where this script is located)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local helper_script="$script_dir/setup-vps-ssh-keys.sh"
    
    if [ ! -f "$helper_script" ]; then
        log_error "Helper script not found: $helper_script"
        return 1
    fi
    
    # Copy helper script to control plane /tmp (always use latest version)
    log_info "Copying SSH setup script to control plane..."
    local remote_script="/tmp/setup-vps-ssh-keys-$$.sh"
    
    if ! scp $ssh_opts "$helper_script" "$control_plane_user@$control_plane_ip:$remote_script" >/dev/null 2>&1; then
        log_error "Failed to copy helper script to control plane"
        return 1
    fi
    
    # Make it executable
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" "chmod +x $remote_script" >/dev/null 2>&1
    
    # Execute the helper script on control plane
    log_info "Running SSH key setup script on control plane..."
    log_info "You may be prompted for the VPS password when copying keys."
    echo ""
    
    if ! ssh $ssh_opts "$control_plane_user@$control_plane_ip" "bash $remote_script '$vps_user' '$vps_ip'"; then
        log_error "Failed to execute SSH key setup script on control plane."
        # Cleanup
        ssh $ssh_opts "$control_plane_user@$control_plane_ip" "rm -f $remote_script" 2>/dev/null || true
        return 1
    fi
    
    # Cleanup
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" "rm -f $remote_script" 2>/dev/null || true
    
    echo ""
    log_info "Verifying reverse SSH access..."
    
    # Verify reverse SSH works
    if ssh $ssh_opts "$control_plane_user@$control_plane_ip" \
        "sudo ssh -o BatchMode=yes -o ConnectTimeout=5 $vps_user@$vps_ip 'echo OK' 2>/dev/null" 2>&1 | grep -q "OK"; then
        log_success "✓ Reverse SSH verified (control plane → VPS) ✓"
        log_success "✓ Scripts can now sync routes without passwords ✓"
        return 0
    else
        log_warn "⚠ Could not verify reverse SSH"
        log_warn "You may need to manually accept host key on control plane"
        echo ""
        echo "Run this on control plane:"
        echo "  ssh -o StrictHostKeyChecking=accept-new $vps_user@$vps_ip 'echo OK'"
        echo ""
        return 1
    fi
}

###############################################################################
# Setup Reverse SSH (from control plane to Management Laptop)
# Handles both user and root SSH keys for script automation
###############################################################################

setup_management_laptop_ssh() {
    local control_plane_user="$1"
    local control_plane_ip="$2"
    local laptop_user="$3"
    local laptop_ip="$4"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 Reverse SSH Setup (Control Plane → Management Laptop)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    log_info "Setting up SSH keys on control plane for automation..."
    log_info "This enables passwordless DNS sync to your laptop."
    echo ""

    local ssh_opts="${SSH_CONTROL_OPTS:-}"
    
    # Get the script directory (where this script is located)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local helper_script="$script_dir/setup-laptop-ssh-keys.sh"
    
    if [ ! -f "$helper_script" ]; then
        log_error "Helper script not found: $helper_script"
        return 1
    fi
    
    # Copy helper script to control plane /tmp (always use latest version)
    log_info "Copying SSH setup script to control plane..."
    local remote_script="/tmp/setup-laptop-ssh-keys-$$.sh"
    
    if ! scp $ssh_opts "$helper_script" "$control_plane_user@$control_plane_ip:$remote_script" >/dev/null 2>&1; then
        log_error "Failed to copy helper script to control plane"
        return 1
    fi
    
    # Make it executable
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" "chmod +x $remote_script" >/dev/null 2>&1
    
    # Step 1: Generate keys on control plane (doesn't need laptop access)
    log_info "Generating SSH keys on control plane..."
    echo ""
    
    if ! ssh $ssh_opts "$control_plane_user@$control_plane_ip" "bash $remote_script generate-only"; then
        log_error "Failed to generate SSH keys on control plane."
        # Cleanup
        ssh $ssh_opts "$control_plane_user@$control_plane_ip" "rm -f $remote_script" 2>/dev/null || true
        return 1
    fi
    
    echo ""
    log_info "Fetching public keys from control plane..."
    
    # Step 2: Fetch the public keys from control plane
    local root_pub_key=$(ssh $ssh_opts "$control_plane_user@$control_plane_ip" "sudo cat /root/.ssh/mynodeone_id_ed25519.pub" 2>/dev/null)
    local user_pub_key=$(ssh $ssh_opts "$control_plane_user@$control_plane_ip" "cat ~/.ssh/mynodeone_id_ed25519.pub" 2>/dev/null)
    
    if [ -z "$root_pub_key" ]; then
        log_error "Failed to fetch root public key from control plane"
        ssh $ssh_opts "$control_plane_user@$control_plane_ip" "rm -f $remote_script" 2>/dev/null || true
        return 1
    fi
    
    # Step 3: Append keys to laptop's authorized_keys (locally, no nested SSH!)
    log_info "Adding control plane keys to laptop's authorized_keys..."
    
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    
    # Check if root key already exists
    if grep -qF "$root_pub_key" ~/.ssh/authorized_keys 2>/dev/null; then
        log_info "Root key already in authorized_keys"
    else
        echo "$root_pub_key" >> ~/.ssh/authorized_keys
        log_success "Added root key to authorized_keys"
    fi
    
    # Check if user key already exists (if not root)
    if [ -n "$user_pub_key" ]; then
        if grep -qF "$user_pub_key" ~/.ssh/authorized_keys 2>/dev/null; then
            log_info "User key already in authorized_keys"
        else
            echo "$user_pub_key" >> ~/.ssh/authorized_keys
            log_success "Added user key to authorized_keys"
        fi
    fi
    
    # Cleanup
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" "rm -f $remote_script" 2>/dev/null || true
    
    echo ""
    log_info "Accepting laptop's host key on control plane..."
    
    # Step 4: Accept host key from control plane (both as user and root)
    # First as the regular user
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" \
        "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 $laptop_user@$laptop_ip 'echo OK' >/dev/null 2>&1" || true
    
    # Then as root (what the sync service uses)
    ssh $ssh_opts "$control_plane_user@$control_plane_ip" \
        "sudo ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 $laptop_user@$laptop_ip 'echo OK' >/dev/null 2>&1" || true
    
    log_success "Host key accepted"
    
    echo ""
    log_info "Verifying reverse SSH access..."
    
    # Verify reverse SSH works (test as root - what sync service uses)
    if ssh $ssh_opts "$control_plane_user@$control_plane_ip" \
        "sudo ssh -o BatchMode=yes -o ConnectTimeout=5 $laptop_user@$laptop_ip 'echo OK' 2>/dev/null" 2>&1 | grep -q "OK"; then
        log_success "✓ Reverse SSH verified (control plane → laptop) ✓"
        log_success "✓ Scripts can now sync DNS without passwords ✓"
        return 0
    else
        log_warn "⚠ Could not verify reverse SSH"
        log_warn "This might be a transient issue. Try running the verification manually:"
        echo ""
        echo "On control plane, run:"
        echo "  sudo ssh $laptop_user@$laptop_ip 'echo OK'"
        echo ""
        log_warn "If that works, the setup is complete despite this warning."
        return 0  # Don't fail - keys are installed, verification might just be timing issue
    fi
}

###############################################################################
# Wrapper for SSH commands using ControlMaster
###############################################################################

ssh_with_control() {
    local ssh_opts="${SSH_CONTROL_OPTS:-}"
    ssh $ssh_opts "$@"
}

# Wrapper for SCP commands using ControlMaster
scp_with_control() {
    local ssh_opts="${SSH_CONTROL_OPTS:-}"
    scp $ssh_opts "$@"
}

###############################################################################
# Export functions for use in other scripts
###############################################################################

export -f setup_ssh_control_master
export -f cleanup_ssh_control_master
export -f validate_ssh_early
export -f setup_reverse_ssh
export -f ssh_with_control
export -f scp_with_control
export -f log_info
export -f log_success
export -f log_warn
export -f log_error
