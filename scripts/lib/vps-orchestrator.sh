#!/bin/bash

###############################################################################
# VPS Orchestrator
# 
# Handles VPS installation from control plane with:
# - SSH key exchange with validation and retry
# - Config file generation and transfer
# - Remote script execution with validation
# - Proper permission and ownership management
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

###############################################################################
# SSH Key Exchange with Validation
###############################################################################

setup_ssh_access() {
    local vps_ip="$1"
    local vps_user="$2"
    local max_retries="${3:-3}"
    local retry_count=0
    
    print_info "Setting up SSH access to VPS ($vps_user@$vps_ip)..."
    
    # Generate SSH key if it doesn't exist
    local ssh_key="$ACTUAL_HOME/.ssh/mynodeone_vps_installer"
    if [ ! -f "$ssh_key" ]; then
        print_info "Generating SSH key for VPS access..."
        sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "mynodeone-vps-installer"
        print_success "SSH key generated: $ssh_key"
    fi
    
    # Test if SSH already works without password
    print_info "Testing SSH connection..."
    if sudo -u "$ACTUAL_USER" ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$vps_user@$vps_ip" "exit" 2>/dev/null; then
        print_success "SSH access already configured"
        return 0
    fi
    
    # SSH doesn't work - need to copy key
    print_warning "SSH key not yet authorized on VPS"
    echo
    echo "We need to copy the SSH public key to the VPS."
    echo "You will be prompted for the VPS password ONCE."
    echo
    
    while [ $retry_count -lt $max_retries ]; do
        print_info "Attempt $((retry_count + 1))/$max_retries: Copying SSH key to VPS..."
        
        if sudo -u "$ACTUAL_USER" ssh-copy-id -i "$ssh_key" -o StrictHostKeyChecking=no "$vps_user@$vps_ip" 2>/dev/null; then
            print_success "SSH key copied successfully"
            
            # Verify it works
            if sudo -u "$ACTUAL_USER" ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=5 "$vps_user@$vps_ip" "exit" 2>/dev/null; then
                print_success "SSH passwordless access verified"
                return 0
            else
                print_error "SSH key copied but authentication still fails"
            fi
        else
            print_error "Failed to copy SSH key"
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo
            read -p "Try again? (y/n): " response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done
    
    print_error "Failed to set up SSH access after $max_retries attempts"
    return 1
}

###############################################################################
# Verify VPS Sudo Access
###############################################################################

verify_vps_sudo() {
    local vps_ip="$1"
    local vps_user="$2"
    local ssh_key="$ACTUAL_HOME/.ssh/mynodeone_vps_installer"
    
    print_info "Verifying passwordless sudo on VPS..."
    
    # Test if sudo works without password
    if sudo -u "$ACTUAL_USER" ssh -i "$ssh_key" -o BatchMode=yes -o ConnectTimeout=10 "$vps_user@$vps_ip" "sudo -n echo 'sudo test' 2>/dev/null" | grep -q "sudo test"; then
        print_success "Passwordless sudo verified on VPS"
        return 0
    else
        print_error "Passwordless sudo is NOT configured on VPS"
        echo
        echo "Please configure passwordless sudo for user '$vps_user' on the VPS:"
        echo
        echo "1. SSH into the VPS manually:"
        echo "   ssh $vps_user@$vps_ip"
        echo
        echo "2. Run these commands:"
        echo "   echo '$vps_user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$vps_user"
        echo "   sudo chmod 0440 /etc/sudoers.d/$vps_user"
        echo
        echo "3. Test it:"
        echo "   sudo -n echo 'sudo works'"
        echo
        return 1
    fi
}

###############################################################################
# Generate VPS Config File
###############################################################################

generate_vps_config() {
    local vps_node_name="$1"
    local vps_tailscale_ip="$2"
    local vps_user="$3"
    local vps_public_ip="$4"
    local vps_domain="$5"
    local ssl_email="$6"
    local vps_location="$7"
    local control_plane_ip="$8"
    local control_plane_user="$9"
    local cluster_name="${10}"
    local cluster_domain="${11}"
    
    local config_file="/tmp/mynodeone-vps-config-$(date +%s).env"
    
    # Send messages to stderr so they don't get captured in variable assignment
    print_info "Generating VPS configuration file..." >&2
    
    cat > "$config_file" << EOF
# MyNodeOne VPS Edge Node Configuration
# Generated on: $(date)
# Generated by: $ACTUAL_USER@$(hostname)

# Node Configuration
NODE_TYPE="edge"
NODE_ROLE="VPS Edge Node"
NODE_NAME="$vps_node_name"

# Cluster Information
CLUSTER_NAME="$cluster_name"
CLUSTER_DOMAIN="$cluster_domain"
CONTROL_PLANE_IP="$control_plane_ip"
CONTROL_PLANE_SSH_USER="$control_plane_user"

# VPS Information
TAILSCALE_IP="$vps_tailscale_ip"
VPS_PUBLIC_IP="$vps_public_ip"
VPS_DOMAIN="$vps_domain"
VPS_LOCATION="$vps_location"

# VPS-specific variables for mynodeone orchestration
VPS_NODE_NAME="$vps_node_name"
VPS_TAILSCALE_IP="$vps_tailscale_ip"
VPS_SSH_USER="$vps_user"

# SSL Configuration
SSL_EMAIL="$ssl_email"

# Storage (VPS typically uses minimal storage)
LONGHORN_PATH="/var/lib/longhorn"

# Network Configuration
ENABLE_TRAEFIK="true"
ENABLE_CERT_MANAGER="true"

# Installation Flags
SKIP_INTERACTIVE="true"
UNATTENDED="1"
VPS_ORCHESTRATED="true"
EOF
    
    # Set proper ownership
    chown "$ACTUAL_USER:$ACTUAL_USER" "$config_file"
    chmod 600 "$config_file"
    
    # Send messages to stderr so they don't get captured in variable assignment
    print_success "VPS config generated: $config_file" >&2
    
    # Only echo the filename to stdout (this gets captured in vps_config variable)
    echo "$config_file"
}

###############################################################################
# Transfer Files to VPS
###############################################################################

transfer_to_vps() {
    local vps_ip="$1"
    local vps_user="$2"
    local local_path="$3"
    local remote_path="$4"
    local max_retries="${5:-3}"
    
    local ssh_key="$ACTUAL_HOME/.ssh/mynodeone_vps_installer"
    local retry_count=0
    
    print_info "Transferring $local_path to VPS..."
    
    # DEBUG: Show file info
    if [ -f "$local_path" ]; then
        echo "[DEBUG] File exists: $local_path"
        echo "[DEBUG] File ownership: $(ls -lh "$local_path" | awk '{print $3":"$4}')"
        echo "[DEBUG] File permissions: $(stat -c '%a' "$local_path")"
        
        # Ensure the file is readable by ACTUAL_USER
        chmod 644 "$local_path" 2>/dev/null || true
        echo "[DEBUG] After chmod 644: $(stat -c '%a' "$local_path")"
    elif [ -d "$local_path" ]; then
        echo "[DEBUG] Directory exists: $local_path"
        echo "[DEBUG] Directory ownership: $(ls -ldh "$local_path" | awk '{print $3":"$4}')"
    else
        print_error "Source path does not exist: $local_path"
        return 1
    fi
    
    # DEBUG: Show variables
    echo "[DEBUG] ACTUAL_USER: $ACTUAL_USER"
    echo "[DEBUG] ACTUAL_HOME: $ACTUAL_HOME"
    echo "[DEBUG] SSH key: $ssh_key"
    echo "[DEBUG] SSH key exists: $([ -f "$ssh_key" ] && echo 'YES' || echo 'NO')"
    echo "[DEBUG] VPS target: $vps_user@$vps_ip:$remote_path"
    echo "[DEBUG] SCP command: sudo -u $ACTUAL_USER scp -i $ssh_key -o ConnectTimeout=10 -r $local_path $vps_user@$vps_ip:$remote_path"
    
    while [ $retry_count -lt $max_retries ]; do
        # Capture error output for debugging
        local error_output
        if error_output=$(sudo -u "$ACTUAL_USER" scp -i "$ssh_key" -o ConnectTimeout=10 -r "$local_path" "$vps_user@$vps_ip:$remote_path" 2>&1); then
            print_success "Transfer complete"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            print_warning "Transfer failed, retrying ($retry_count/$max_retries)..."
            echo "[DEBUG] Error output: $error_output"
            sleep 2
        else
            # Show error on final failure
            print_error "SCP error: $error_output"
        fi
    done
    
    print_error "Failed to transfer files after $max_retries attempts"
    return 1
}

###############################################################################
# Execute Command on VPS with Validation
###############################################################################

execute_on_vps() {
    local vps_ip="$1"
    local vps_user="$2"
    local command="$3"
    local max_retries="${4:-1}"
    
    local ssh_key="$ACTUAL_HOME/.ssh/mynodeone_vps_installer"
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        print_info "Executing on VPS: $command"
        
        if sudo -u "$ACTUAL_USER" ssh -i "$ssh_key" -o ConnectTimeout=30 "$vps_user@$vps_ip" "$command"; then
            print_success "Command executed successfully"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            print_warning "Command failed, retrying ($retry_count/$max_retries)..."
            sleep 3
        fi
    done
    
    print_error "Command failed after $max_retries attempts"
    return 1
}

###############################################################################
# Main VPS Orchestration Function
###############################################################################

orchestrate_vps_installation() {
    local vps_node_name="$1"
    local vps_tailscale_ip="$2"
    local vps_user="$3"
    local vps_public_ip="$4"
    local vps_domain="$5"
    local ssl_email="$6"
    local vps_location="$7"
    local control_plane_ip="$8"
    local control_plane_user="$9"
    local cluster_name="${10}"
    local cluster_domain="${11}"
    
    print_info "Starting VPS installation orchestration..."
    echo
    print_info "VPS Node: $vps_node_name ($vps_tailscale_ip)"
    echo
    
    # Step 1: Set up SSH access (use Tailscale IP for SSH)
    if ! setup_ssh_access "$vps_tailscale_ip" "$vps_user" 3; then
        print_error "Failed to set up SSH access to VPS"
        return 1
    fi
    echo
    
    # Step 2: Verify sudo access
    if ! verify_vps_sudo "$vps_tailscale_ip" "$vps_user"; then
        print_error "VPS sudo configuration required"
        return 1
    fi
    echo
    
    # Step 3: Generate VPS config file
    local vps_config
    vps_config=$(generate_vps_config "$vps_node_name" "$vps_tailscale_ip" "$vps_user" "$vps_public_ip" "$vps_domain" "$ssl_email" "$vps_location" "$control_plane_ip" "$control_plane_user" "$cluster_name" "$cluster_domain")
    echo
    
    # Step 4: Create remote directory structure with proper permissions
    print_info "Preparing VPS directory structure..."
    local remote_home="/home/$vps_user"
    local remote_mynodeone="$remote_home/mynodeone"
    
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "mkdir -p $remote_mynodeone" || return 1
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "mkdir -p $remote_home/.mynodeone" || return 1
    echo
    
    # Step 5: Transfer MyNodeOne scripts to VPS (only scripts directory, not entire repo)
    print_info "Transferring MyNodeOne scripts to VPS..."
    local scripts_dir="$PROJECT_ROOT/scripts"
    if ! transfer_to_vps "$vps_tailscale_ip" "$vps_user" "$scripts_dir" "$remote_mynodeone/" 3; then
        print_error "Failed to transfer scripts to VPS"
        return 1
    fi
    echo
    
    # Step 6: Transfer config file to VPS
    print_info "Transferring config file to VPS..."
    local temp_config="mynodeone-config-temp.env"
    if ! transfer_to_vps "$vps_tailscale_ip" "$vps_user" "$vps_config" "$remote_home/$temp_config" 3; then
        print_error "Failed to transfer config to VPS"
        rm -f "$vps_config"
        return 1
    fi
    
    # Move config to proper location on VPS
    print_info "Installing config file on VPS..."
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "mv $remote_home/$temp_config $remote_home/.mynodeone/config.env" || return 1
    
    # Clean up local temp config
    rm -f "$vps_config"
    echo
    
    # Step 7: Set proper permissions on VPS
    print_info "Setting proper permissions on VPS..."
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "chmod 600 $remote_home/.mynodeone/config.env" || return 1
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "chmod +x $remote_mynodeone/scripts/mynodeone" || return 1
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "chmod +x $remote_mynodeone/scripts/*.sh" || return 1
    execute_on_vps "$vps_tailscale_ip" "$vps_user" "chmod +x $remote_mynodeone/scripts/lib/*.sh" 2>/dev/null || true
    echo
    
    # Step 8: Execute installation on VPS
    print_info "Starting installation on VPS..."
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Remote VPS Installation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    local ssh_key="$ACTUAL_HOME/.ssh/mynodeone_vps_installer"
    if ! sudo -u "$ACTUAL_USER" ssh -i "$ssh_key" -t "$vps_user@$vps_tailscale_ip" "cd $remote_mynodeone && sudo ./scripts/mynodeone --config-file $remote_home/.mynodeone/config.env"; then
        print_error "VPS installation failed"
        echo
        echo "Troubleshooting:"
        echo "  1. SSH into VPS: ssh $vps_user@$vps_tailscale_ip"
        echo "  2. Check logs: journalctl -xe"
        echo "  3. Re-run manually: cd $remote_mynodeone && sudo ./scripts/mynodeone --config-file $remote_home/.mynodeone/config.env"
        return 1
    fi
    
    # Final sync: Register VPS and update DNS
    print_info "Syncing service registry and DNS..."
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$script_dir/service-registry.sh" ]; then
        bash "$script_dir/service-registry.sh" sync 2>/dev/null || true
    fi
    if [ -f "$(dirname "$script_dir")/sync-dns.sh" ]; then
        bash "$(dirname "$script_dir")/sync-dns.sh" 2>/dev/null || true
    fi
    print_success "Service registry and DNS updated"
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "VPS installation completed successfully! 🎉"
    echo
    
    return 0
}
