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
    
    # Create SSH control socket
    SSH_CONTROL_OPTS="-o ControlMaster=auto -o ControlPath=$control_path -o ControlPersist=600"
    
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
    local vps_ssh_dir="$5"  # Actual user's .ssh directory
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🔐 Reverse SSH Setup (Control Plane → VPS)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    log_info "Setting up SSH keys on control plane for automation..."
    log_info "This enables passwordless route sync (manage-app-visibility.sh)"
    echo ""
    
    # Use SSH ControlMaster if available
    local ssh_opts="${SSH_CONTROL_OPTS:-}"
    
    # Run remote setup script to generate/fetch SSH keys
    local remote_script="
        # Detect actual user on control plane (handle sudo)
        REMOTE_ACTUAL_USER=\"\${SUDO_USER:-\$(whoami)}\"
        if [ -n \"\${SUDO_USER:-}\" ] && [ \"\$SUDO_USER\" != \"root\" ]; then
            REMOTE_ACTUAL_HOME=\$(getent passwd \"\$SUDO_USER\" | cut -d: -f6)
        else
            REMOTE_ACTUAL_HOME=\"\$HOME\"
        fi
        
        echo \"[INFO] Setting up SSH keys for user: \$REMOTE_ACTUAL_USER\"
        
        # 1. Ensure actual user has SSH key (used when scripts run with sudo)
        if ! sudo test -f \"\$REMOTE_ACTUAL_HOME/.ssh/id_ed25519\"; then
            echo \"[INFO] Generating SSH key for \$REMOTE_ACTUAL_USER (script user)...\"
            sudo -u \"\$REMOTE_ACTUAL_USER\" mkdir -p \"\$REMOTE_ACTUAL_HOME/.ssh\" 2>/dev/null || true
            sudo -u \"\$REMOTE_ACTUAL_USER\" chmod 700 \"\$REMOTE_ACTUAL_HOME/.ssh\" 2>/dev/null || true
            sudo -u \"\$REMOTE_ACTUAL_USER\" ssh-keygen -t ed25519 -f \"\$REMOTE_ACTUAL_HOME/.ssh/id_ed25519\" -N '' -C \"\$REMOTE_ACTUAL_USER@control-plane-scripts\" 2>/dev/null || {
                echo \"[WARN] Could not generate SSH key for \$REMOTE_ACTUAL_USER\"
            }
            if sudo test -f \"\$REMOTE_ACTUAL_HOME/.ssh/id_ed25519\"; then
                echo \"[SUCCESS] SSH key generated for \$REMOTE_ACTUAL_USER\"
            fi
        else
            echo \"[INFO] SSH key already exists for \$REMOTE_ACTUAL_USER\"
        fi
        
        # 2. Also ensure current SSH user has key
        if [ ! -f ~/.ssh/id_ed25519 ]; then
            echo \"[INFO] Generating SSH key for SSH user...\"
            ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C 'control-plane-ssh-user'
            echo \"[SUCCESS] SSH key generated for SSH user\"
        else
            echo \"[INFO] SSH key already exists for SSH user\"
        fi
        
        # 3. Pre-accept VPS host key for both users
        echo \"[INFO] Pre-accepting host key for VPS ($vps_ip)...\"
        
        # For script user (actual user)
        sudo -u \"\$REMOTE_ACTUAL_USER\" ssh-keyscan -H $vps_ip >> \"\$REMOTE_ACTUAL_HOME/.ssh/known_hosts\" 2>/dev/null || true
        
        # For SSH user
        ssh-keyscan -H $vps_ip >> ~/.ssh/known_hosts 2>/dev/null || true
        
        echo \"[SUCCESS] Host key pre-accepted\"
        
        # 4. Test reverse SSH connections
        echo \"[INFO] Testing reverse SSH connections...\"
        
        # Test as script user
        if sudo -u \"\$REMOTE_ACTUAL_USER\" ssh -o BatchMode=yes -o ConnectTimeout=5 $vps_user@$vps_ip 'echo OK' 2>/dev/null | grep -q OK; then
            echo \"[SUCCESS] Script user SSH test passed\"
        else
            # Try to setup the connection
            echo \"[INFO] Setting up script user SSH access...\"
            if sudo test -f \"\$REMOTE_ACTUAL_HOME/.ssh/id_ed25519.pub\"; then
                echo \"=== SCRIPT_USER_KEY ===\"
                sudo cat \"\$REMOTE_ACTUAL_HOME/.ssh/id_ed25519.pub\" 2>/dev/null || echo \"[WARN] Could not read script user key\"
            else
                echo \"[WARN] Script user key file not found: \$REMOTE_ACTUAL_HOME/.ssh/id_ed25519.pub\"
            fi
        fi
        
        # Test as SSH user
        if ssh -o BatchMode=yes -o ConnectTimeout=5 $vps_user@$vps_ip 'echo OK' 2>/dev/null | grep -q OK; then
            echo \"[SUCCESS] SSH user test passed\"
        else
            echo \"[INFO] Setting up SSH user access...\"
            if [ -f ~/.ssh/id_ed25519.pub ]; then
                echo \"=== SSH_USER_KEY ===\"
                cat ~/.ssh/id_ed25519.pub
            fi
        fi
    "
    
    # Execute remote script and capture keys to install
    local output
    output=$(ssh $ssh_opts "$control_plane_user@$control_plane_ip" "$remote_script" 2>&1)
    
    # Parse output and install keys
    local in_script_key=false
    local in_ssh_key=false
    
    while IFS= read -r line; do
        # Filter out noise
        if [[ "$line" =~ ^\[sudo\]|^Warning:|^Connection ]]; then
            continue
        fi
        
        # Display informational messages
        if [[ "$line" =~ ^\[INFO\]|^\[SUCCESS\] ]]; then
            echo "$line"
            continue
        fi
        
        # Handle key markers
        if [[ "$line" == "=== SCRIPT_USER_KEY ===" ]]; then
            in_script_key=true
            in_ssh_key=false
            continue
        elif [[ "$line" == "=== SSH_USER_KEY ===" ]]; then
            in_script_key=false
            in_ssh_key=true
            continue
        fi
        
        # Install SSH public keys
        if [[ "$line" =~ ^ssh- ]]; then
            if [ "$in_script_key" = true ]; then
                echo "$line" >> "$vps_ssh_dir/authorized_keys"
                log_success "Added script user key from control plane"
            elif [ "$in_ssh_key" = true ]; then
                echo "$line" >> "$vps_ssh_dir/authorized_keys"
                log_success "Added SSH user key from control plane"
            fi
        fi
    done <<< "$output"
    
    # Ensure proper permissions and ownership
    chown "$vps_user:$vps_user" "$vps_ssh_dir/authorized_keys" 2>/dev/null || true
    chown "$vps_user:$vps_user" "$vps_ssh_dir" 2>/dev/null || true
    chmod 600 "$vps_ssh_dir/authorized_keys" 2>/dev/null || true
    chmod 700 "$vps_ssh_dir" 2>/dev/null || true
    
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
