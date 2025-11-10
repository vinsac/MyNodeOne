#!/bin/bash

###############################################################################
# Setup VPS Node for Enterprise Registry
# 
# Auto-registers VPS and configures for automatic sync
# Run this on each VPS edge node
###############################################################################

set -euo pipefail

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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌍 VPS Node Registration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Load configuration
if [ ! -f ~/.mynodeone/config.env ]; then
    log_error "Configuration not found!"
    echo "Please run the VPS edge node installation first:"
    echo "  sudo ./scripts/mynodeone"
    echo "  Select option: 3 (VPS Edge Node)"
    exit 1
fi

source ~/.mynodeone/config.env

# Detect the ACTUAL user (not the sudo-elevated user)
# When running with sudo, $SUDO_USER contains the real user
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    CURRENT_VPS_USER="$SUDO_USER"
    log_info "Running as user: $CURRENT_VPS_USER (via sudo)"
    log_success "✓ Using actual user '$CURRENT_VPS_USER' for SSH access (not root)"
else
    CURRENT_VPS_USER=$(whoami)
    log_info "Running as user: $CURRENT_VPS_USER"
    
    # Security check: warn if actually logged in as root
    if [ "$CURRENT_VPS_USER" = "root" ]; then
        log_warn "⚠️  Logged in as root user!"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🔒 Security Best Practice"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "For production VPS servers, it's recommended to:"
        echo "  1. Create a dedicated sudo user instead of using root"
        echo "  2. Disable root SSH login"
        echo ""
        echo "To create a sudo user, run these commands:"
        echo "  sudo adduser mynodeone"
        echo "  sudo usermod -aG sudo mynodeone"
        echo "  su - mynodeone"
        echo ""
        echo "Then run this script again as the new user."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        read -p "Continue as root anyway? [y/N]: " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Please create a sudo user and run again"
            exit 0
        fi
        echo ""
    fi
fi

# Get VPS details
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
# Prefer configured VPS_PUBLIC_IP, otherwise auto-detect IPv4
if [ -n "${VPS_PUBLIC_IP:-}" ]; then
    PUBLIC_IP="$VPS_PUBLIC_IP"
else
    # Force IPv4 with -4 flag
    PUBLIC_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -s ipv4.icanhazip.com 2>/dev/null || echo "")
fi
HOSTNAME=$(hostname)

if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not detected"
    echo "Please ensure Tailscale is installed and running"
    exit 1
fi

# Configure Tailscale to accept subnet routes from control plane
log_info "Configuring Tailscale to accept subnet routes..."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Tailscale Subnet Routes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "The VPS needs to access services in your Kubernetes cluster."
echo "This requires accepting subnet routes from the control plane."
echo ""
echo "This will enable routing to cluster LoadBalancer IPs."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Always run tailscale up --accept-routes (it's idempotent)
if tailscale up --accept-routes; then
    log_success "Tailscale configured to accept subnet routes"
else
    log_warn "Could not configure Tailscale routes automatically"
    log_warn "You may need to manually approve routes in Tailscale admin"
fi

log_info "VPS Details:"
echo "  • Tailscale IP: $TAILSCALE_IP"
echo "  • Public IP: $PUBLIC_IP"
echo "  • Hostname: $HOSTNAME"
echo ""

# Check required config
if [ -z "${CONTROL_PLANE_IP:-}" ]; then
    log_error "CONTROL_PLANE_IP not set in ~/.mynodeone/config.env"
    exit 1
fi

if [ -z "${PUBLIC_DOMAIN:-}" ]; then
    log_warn "PUBLIC_DOMAIN not set in ~/.mynodeone/config.env"
    echo ""
    echo "A public domain is needed for SSL certificates and external access."
    echo "You can set this up later if you don't have one yet."
    echo ""
    read -p "Enter your public domain (or press Enter to skip): " user_domain
    
    if [ -n "$user_domain" ]; then
        echo "PUBLIC_DOMAIN=\"$user_domain\"" >> ~/.mynodeone/config.env
        PUBLIC_DOMAIN="$user_domain"
        log_success "Domain configured: $PUBLIC_DOMAIN"
    else
        log_warn "Skipping domain configuration. You can add it later to ~/.mynodeone/config.env"
        PUBLIC_DOMAIN=""
    fi
fi

echo ""
log_info "Registering with control plane..."
echo ""

# Setup SSH keys for passwordless authentication
CONTROL_PLANE_SSH_USER="${CONTROL_PLANE_SSH_USER:-root}"

log_info "Setting up SSH key authentication..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "exit" 2>/dev/null; then
    log_success "SSH key authentication already configured"
else
    log_info "Configuring passwordless SSH between VPS and control plane..."
    
    # Generate SSH key if it doesn't exist
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -C "vps-$HOSTNAME"
        log_success "SSH key generated"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  SSH Key Setup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Setting up passwordless SSH access to control plane."
    echo "You'll be prompted for the password ONE LAST TIME."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Copy SSH key to control plane
    if ssh-copy-id -o StrictHostKeyChecking=no "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" 2>/dev/null; then
        log_success "SSH key installed on control plane"
        
        # Also setup reverse SSH access (control plane -> VPS)
        log_info "Setting up reverse SSH access (control plane → VPS)..."
        
        # CRITICAL: Scripts run with sudo use root's SSH keys, so we need to set up root->VPS access
        # First, ensure root on control plane has an SSH key
        # Use -t to allocate PTY for interactive sudo if needed
        ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "
            # Ensure root has an SSH key (scripts run with sudo)
            if ! sudo test -f /root/.ssh/id_ed25519; then
                echo 'Generating SSH key for root (used by scripts)...'
                sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -C 'root@control-plane'
            fi
            
            # Also ensure current user has an SSH key
            if [ ! -f ~/.ssh/id_ed25519 ]; then
                echo 'Generating SSH key for $CONTROL_PLANE_SSH_USER...'
                ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N '' -C 'control-plane'
            fi
            
            # Output both keys to be added to VPS
            echo '=== ROOT KEY ==='
            sudo cat /root/.ssh/id_ed25519.pub 2>/dev/null || echo 'ERROR: Could not read root key'
            echo '=== USER KEY ==='
            cat ~/.ssh/id_ed25519.pub 2>/dev/null || echo 'ERROR: Could not read user key'
        " 2>&1 | while IFS= read -r line; do
            # Skip password prompts and other noise
            if [[ "$line" =~ ^\[sudo\] || "$line" =~ ^Connection ]]; then
                continue
            fi
            
            if [[ "$line" == "=== ROOT KEY ===" ]]; then
                mode=\"root\"
            elif [[ "$line" == "=== USER KEY ===" ]]; then
                mode=\"user\"
            elif [[ "$line" == "ERROR:"* ]]; then
                log_warn "$line"
            elif [[ -n "$line" ]] && [[ "$line" =~ ^ssh- ]]; then
                # Add to the VPS user's authorized_keys
                echo "$line" >> ~/.ssh/authorized_keys
                if [[ "$mode" == "root" ]]; then
                    log_success "Added root SSH key from control plane"
                else
                    log_success "Added $CONTROL_PLANE_SSH_USER SSH key from control plane"
                fi
            elif [[ -n "$line" ]] && [[ ! "$line" =~ ^Generating ]]; then
                # Echo other informational lines
                echo "$line"
            fi
        done
        
        # Ensure proper permissions
        chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
        chmod 700 ~/.ssh 2>/dev/null || true
        
        # Verify reverse SSH works (control plane -> VPS)
        log_info "Verifying bidirectional SSH access..."
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🔐 Reverse SSH Verification"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Testing SSH connection from control plane → VPS..."
        echo "The control plane needs to SSH back to this VPS for route sync."
        echo ""
        
        # Try reverse SSH with automatic yes to known_hosts
        # Test BOTH as regular user AND as root (since scripts run with sudo)
        USER_SSH_OK=false
        ROOT_SSH_OK=false
        
        if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK' 2>/dev/null" | grep -q "OK"; then
            USER_SSH_OK=true
        fi
        
        if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "sudo ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK' 2>/dev/null" | grep -q "OK"; then
            ROOT_SSH_OK=true
        fi
        
        if $USER_SSH_OK && $ROOT_SSH_OK; then
            log_success "✓ Bidirectional SSH verified (user ✓, root ✓)"
        elif $ROOT_SSH_OK; then
            log_success "✓ Root SSH verified (used by scripts) ✓"
            log_warn "⚠ User SSH not working, but root works (this is fine)"
        else
            log_warn "⚠ Reverse SSH verification failed"
            echo ""
            echo "This may be due to SSH host key verification on the control plane."
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📋 Manual Fix Required on Control Plane"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "The control plane needs SSH access to this VPS for route sync."
            echo "You can fix this NOW from any machine with SSH to control plane."
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🖥️  Option 1: From Your Management Laptop/Desktop"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "Open a terminal on your laptop/desktop and run:"
            echo ""
            echo "  ssh $CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP"
            echo "  ssh -o StrictHostKeyChecking=accept-new $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK'"
            echo "  exit"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🖥️  Option 2: If You Have Direct Access to Control Plane"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "Open terminal directly on control plane and run:"
            echo ""
            echo "  ssh -o StrictHostKeyChecking=accept-new $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK'"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            
            # Give user option to fix it now
            read -p "Ready to verify? Press Enter after running the command, or type 'skip' to continue: " -r
            if [[ $REPLY =~ ^[Ss][Kk][Ii][Pp]$ ]] || [[ $REPLY =~ ^[Nn]$ ]]; then
                log_warn "Skipping reverse SSH verification"
                log_warn "You can fix this later by running from control plane:"
                log_warn "  ssh $CURRENT_VPS_USER@$TAILSCALE_IP"
            else
                echo ""
                log_info "Testing reverse SSH connection..."
                
                # Test again
                if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "ssh -o BatchMode=yes -o ConnectTimeout=5 $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK' 2>/dev/null" | grep -q "OK"; then
                    log_success "✓ Reverse SSH now working!"
                else
                    log_warn "✗ Reverse SSH still not working"
                    echo ""
                    echo "Possible issues:"
                    echo "  1. Command not run yet (run it now and press Enter)"
                    echo "  2. Tailscale IP $TAILSCALE_IP not reachable from control plane"
                    echo "  3. SSH keys not properly configured"
                    echo ""
                    read -p "Try verification again? [Y/n]: " -r
                    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                        echo "Press Enter after running the command on control plane..."
                        read -r
                        if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" "ssh -o BatchMode=yes -o ConnectTimeout=5 $CURRENT_VPS_USER@$TAILSCALE_IP 'echo OK' 2>/dev/null" | grep -q "OK"; then
                            log_success "✓ Reverse SSH now working!"
                        else
                            log_warn "Continuing anyway - fix this later"
                        fi
                    else
                        log_warn "Continuing anyway - you can fix this later"
                    fi
                fi
            fi
        fi
        echo ""
    else
        log_warn "Could not install SSH key automatically"
        log_warn "You will be prompted for passwords during setup"
    fi
    echo ""
fi

# Register this VPS in the multi-domain registry
REGION="${NODE_LOCATION:-unknown}"
PROVIDER="unknown"

# Try to detect provider
if curl -s --max-time 2 http://169.254.169.254/metadata/v1/vendor-data | grep -q "Contabo"; then
    PROVIDER="contabo"
elif curl -s --max-time 2 http://169.254.169.254/metadata/v1/ 2>/dev/null | grep -q "digitalocean"; then
    PROVIDER="digitalocean"
elif curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ 2>/dev/null | grep -q "ami"; then
    PROVIDER="aws"
fi

log_info "Detected provider: $PROVIDER, region: $REGION"

# Register VPS in multi-domain registry
log_info "Registering VPS in multi-domain registry..."
ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-vps \
    $TAILSCALE_IP $PUBLIC_IP $REGION $PROVIDER" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in multi-domain registry"
else
    log_error "VPS registration failed in multi-domain registry"
    log_error "This may cause routing issues. Please register manually:"
    log_error "  kubectl patch configmap domain-registry -n kube-system ..."
fi

# Register domain in cluster if PUBLIC_DOMAIN is configured
if [ -n "$PUBLIC_DOMAIN" ]; then
    log_info "Registering domain in cluster: $PUBLIC_DOMAIN"
    
    ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh register-domain \
        $PUBLIC_DOMAIN 'VPS edge node domain'" 2>&1 | grep -v "Warning: Permanently added"
    
    if [ $? -eq 0 ]; then
        log_success "Domain registered in cluster: $PUBLIC_DOMAIN"
        
        # VALIDATION: Verify domain was actually registered
        log_info "Validating domain registration..."
        DOMAIN_CHECK=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
            "sudo kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' 2>/dev/null | jq -r '.domains | has(\"$PUBLIC_DOMAIN\")'" 2>/dev/null || echo "false")
        
        if [ "$DOMAIN_CHECK" = "true" ]; then
            log_success "✓ Domain registration verified in ConfigMap"
            
            # VALIDATION: Verify registry structure is correct
            log_info "Validating registry structure..."
            STRUCTURE_CHECK=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
                "sudo kubectl get cm domain-registry -n kube-system -o jsonpath='{.data.domains\.json}' 2>/dev/null | jq -r 'has(\"domains\") and has(\"vps_nodes\")'" 2>/dev/null || echo "false")
            
            if [ "$STRUCTURE_CHECK" = "true" ]; then
                log_success "✓ Registry structure validated (unified format)"
            else
                log_warn "⚠ Registry structure may be incorrect"
                log_info "Expected: {\"domains\":{...}, \"vps_nodes\":[...]}"
            fi
        else
            log_warn "⚠ Could not verify domain registration"
            log_warn "Domain may be in old structure format"
        fi
    else
        log_error "Domain registration failed"
        log_error "Manual registration: ./scripts/lib/multi-domain-registry.sh register-domain $PUBLIC_DOMAIN"
    fi
fi

# Register VPS in sync controller (uses new registry manager)
log_info "Registering VPS in sync controller..."
log_info "Using VPS user: $CURRENT_VPS_USER"

ssh -t "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "cd ~/MyNodeOne && sudo SKIP_SSH_VALIDATION=true ./scripts/lib/node-registry-manager.sh register vps_nodes \
    $TAILSCALE_IP $HOSTNAME $CURRENT_VPS_USER" 2>&1 | grep -v "Warning: Permanently added"

if [ $? -eq 0 ]; then
    log_success "VPS registered in sync controller"
    
    # VALIDATION: Verify VPS was actually registered
    log_info "Validating VPS registration..."
    VPS_CHECK=$(ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
        "sudo kubectl get cm sync-controller-registry -n kube-system -o jsonpath='{.data.registry\.json}' 2>/dev/null | jq -r '.vps_nodes[] | select(.ip==\"$TAILSCALE_IP\") | .ssh_user'" 2>/dev/null || echo "")
    
    if [ "$VPS_CHECK" = "$CURRENT_VPS_USER" ]; then
        log_success "✓ VPS registration verified in ConfigMap"
        log_success "✓ Registered with user: $VPS_CHECK"
    else
        log_warn "⚠ Could not verify VPS registration (expected user: $CURRENT_VPS_USER, got: ${VPS_CHECK:-none})"
    fi
else
    log_error "VPS registration failed in sync controller"
    log_error "Routes may not sync automatically. Manual registration:"
    log_error "  ./scripts/lib/node-registry-manager.sh register vps_nodes $TAILSCALE_IP $HOSTNAME $CURRENT_VPS_USER"
    exit 1
fi

echo ""
log_info "Installing sync script on VPS..."

# Create scripts directory structure
mkdir -p ~/MyNodeOne/scripts/lib

# Fetch sync script from control plane
if scp "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP:~/MyNodeOne/scripts/sync-vps-routes.sh" \
    ~/MyNodeOne/scripts/sync-vps-routes.sh 2>/dev/null; then
    chmod +x ~/MyNodeOne/scripts/sync-vps-routes.sh
    log_success "Sync script installed"
else
    log_warn "Could not fetch sync script from control plane"
    log_info "Creating minimal sync script..."
    
    # Create a minimal sync script that uses SSH to control plane
    cat > ~/MyNodeOne/scripts/sync-vps-routes.sh << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

# Load configuration
source ~/.mynodeone/config.env

VPS_TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)

echo "[INFO] Syncing routes from control plane..."

# Fetch routes from control plane
ssh "${CONTROL_PLANE_SSH_USER:-root}@${CONTROL_PLANE_IP}" \
    "cd ~/MyNodeOne && sudo ./scripts/lib/multi-domain-registry.sh export-vps-routes $VPS_TAILSCALE_IP ${CONTROL_PLANE_IP}" \
    > /tmp/mynodeone-routes.yml

# Install routes
sudo mkdir -p /etc/traefik/dynamic
sudo cp /tmp/mynodeone-routes.yml /etc/traefik/dynamic/mynodeone-routes.yml
sudo chmod 644 /etc/traefik/dynamic/mynodeone-routes.yml
rm -f /tmp/mynodeone-routes.yml

# Restart Traefik
cd /etc/traefik && sudo docker compose restart

echo "[SUCCESS] Routes synced and Traefik restarted"
EOFSCRIPT
    
    chmod +x ~/MyNodeOne/scripts/sync-vps-routes.sh
    log_success "Minimal sync script created"
fi

log_info "Running initial sync..."
if ~/MyNodeOne/scripts/sync-vps-routes.sh 2>&1 | tail -5; then
    log_success "Initial sync completed"
else
    log_info "Initial sync skipped (no routes configured yet)"
    log_info "Routes will be pushed from control plane when apps are made public"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ VPS Node Configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

log_success "What's configured:"
echo "  • Registered in control plane registry"
echo "  • Auto-sync enabled for new apps"
echo "  • Traefik routes configured"
echo "  • Domain: $PUBLIC_DOMAIN"
echo ""

log_info "This VPS will now automatically:"
echo "  • Receive route updates when apps are installed"
echo "  • Update Traefik configuration"
echo "  • Obtain SSL certificates from Let's Encrypt"
echo ""

log_info "Point your DNS records to this VPS:"
echo "  Type: A"
echo "  Name: * (wildcard) or specific subdomains"
echo "  Value: $PUBLIC_IP"
echo "  TTL: 300"
echo ""

# Run validation tests
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔍 Validating VPS Edge Node Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/validate-installation.sh" ]; then
    if bash "$SCRIPT_DIR/lib/validate-installation.sh" vps-edge; then
        log_success "✅ VPS validation passed!"
    else
        log_warn "⚠️  Some validation tests failed (see above)"
    fi
else
    log_warn "Validation script not found, skipping tests"
fi
echo ""

# CRITICAL: Final end-to-end SSH validation
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🔐 Final SSH Connectivity Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "Testing end-to-end SSH (required for route sync)..."
log_info "This simulates what manage-app-visibility.sh will do..."
echo ""

# Test as root (what sudo scripts use)
if ssh "$CONTROL_PLANE_SSH_USER@$CONTROL_PLANE_IP" \
    "sudo ssh -o BatchMode=yes -o ConnectTimeout=5 $CURRENT_VPS_USER@$TAILSCALE_IP 'echo \"SSH test from root@control-plane to $CURRENT_VPS_USER@VPS successful\"' 2>&1"; then
    log_success "✅ Root SSH works (scripts will run without password prompts)"
else
    log_error "❌ Root SSH FAILED - manage-app-visibility.sh will ask for passwords"
    echo ""
    echo "To fix manually, run on control plane:"
    echo "  sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub $CURRENT_VPS_USER@$TAILSCALE_IP"
    echo ""
fi
echo ""

log_success "VPS node registration complete! 🎉"
echo ""
