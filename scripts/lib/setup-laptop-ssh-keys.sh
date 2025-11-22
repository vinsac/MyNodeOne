#!/bin/bash

###############################################################################
# Setup SSH Keys for Management Laptop Access
# 
# This script runs ON THE CONTROL PLANE to:
# 1. Generate SSH keys for root and current user
# 2. Copy them to the management laptop
#
# Called by setup-management-laptop-ssh.sh via SSH
#
# Usage:
#   ./setup-laptop-ssh-keys.sh <laptop-user> <laptop-ip>
###############################################################################

set -euo pipefail

MODE="${1:-full}"
LAPTOP_USER="${2:-}"
LAPTOP_IP="${3:-}"
MAX_RETRIES=3
RETRY_DELAY=2

if [ "$MODE" = "generate-only" ]; then
    echo "[INFO] Generating SSH keys on control plane (generate-only mode)..."
else
    echo "[INFO] Setting up SSH keys for management laptop access..."
    echo "[INFO] Target: $LAPTOP_USER@$LAPTOP_IP"
fi

# Detect actual user on control plane
REMOTE_ACTUAL_USER="${SUDO_USER:-$(whoami)}"

if [ "$REMOTE_ACTUAL_USER" = "root" ]; then
    REMOTE_ACTUAL_HOME="/root"
else
    REMOTE_ACTUAL_HOME=$(getent passwd "$REMOTE_ACTUAL_USER" | cut -d: -f6)
fi

echo "[DEBUG] Running as user: $REMOTE_ACTUAL_USER"
echo "[DEBUG] Home dir: $REMOTE_ACTUAL_HOME"

###############################################################################
# 1. Ensure root user has a MyNodeOne-specific SSH key
###############################################################################

ROOT_KEY_PATH="/root/.ssh/mynodeone_id_ed25519"
ROOT_PUB_KEY_PATH="/root/.ssh/mynodeone_id_ed25519.pub"

# Check if root key exists
if sudo [ -f "$ROOT_KEY_PATH" ] && sudo [ -f "$ROOT_PUB_KEY_PATH" ]; then
    echo "[INFO] Root SSH key already exists at $ROOT_KEY_PATH"
    
    # Verify key is valid
    if sudo ssh-keygen -l -f "$ROOT_KEY_PATH" >/dev/null 2>&1; then
        echo "[INFO] Root SSH key is valid"
    else
        echo "[WARN] Root SSH key exists but is invalid, regenerating..."
        sudo rm -f "$ROOT_KEY_PATH" "$ROOT_PUB_KEY_PATH"
    fi
fi

# Generate root key if it doesn't exist
if ! sudo [ -f "$ROOT_KEY_PATH" ]; then
    echo "[INFO] Generating MyNodeOne SSH key for root user..."
    
    # Ensure .ssh directory exists
    sudo mkdir -p /root/.ssh
    sudo chmod 700 /root/.ssh
    
    # Generate key
    if sudo ssh-keygen -t ed25519 -f "$ROOT_KEY_PATH" -N '' -C 'root@control-plane-mynodeone'; then
        echo "[INFO] Root SSH key generated successfully"
    else
        echo "[ERROR] Failed to generate root SSH key"
        exit 1
    fi
    
    # Set permissions
    sudo chmod 600 "$ROOT_KEY_PATH"
    sudo chmod 644 "$ROOT_PUB_KEY_PATH"
    
    # Confirm key was created and is valid
    if sudo [ -f "$ROOT_KEY_PATH" ] && sudo ssh-keygen -l -f "$ROOT_KEY_PATH" >/dev/null 2>&1; then
        echo "[SUCCESS] Root SSH key created and verified"
    else
        echo "[ERROR] Root SSH key creation failed verification"
        exit 1
    fi
fi

###############################################################################
# 2. Ensure actual user has a MyNodeOne-specific SSH key
###############################################################################

if [ "$REMOTE_ACTUAL_USER" != "root" ]; then
    USER_KEY_PATH="$REMOTE_ACTUAL_HOME/.ssh/mynodeone_id_ed25519"
    USER_PUB_KEY_PATH="$REMOTE_ACTUAL_HOME/.ssh/mynodeone_id_ed25519.pub"
    
    # Check if user key exists
    if [ -f "$USER_KEY_PATH" ] && [ -f "$USER_PUB_KEY_PATH" ]; then
        echo "[INFO] User SSH key already exists at $USER_KEY_PATH"
        
        # Verify key is valid
        if ssh-keygen -l -f "$USER_KEY_PATH" >/dev/null 2>&1; then
            echo "[INFO] User SSH key is valid"
        else
            echo "[WARN] User SSH key exists but is invalid, regenerating..."
            rm -f "$USER_KEY_PATH" "$USER_PUB_KEY_PATH"
        fi
    fi
    
    # Generate user key if it doesn't exist
    if [ ! -f "$USER_KEY_PATH" ]; then
        echo "[INFO] Generating MyNodeOne SSH key for user $REMOTE_ACTUAL_USER..."
        
        # Ensure .ssh directory exists
        mkdir -p "$REMOTE_ACTUAL_HOME/.ssh"
        chmod 700 "$REMOTE_ACTUAL_HOME/.ssh"
        
        # Generate key
        if ssh-keygen -t ed25519 -f "$USER_KEY_PATH" -N '' -C "$REMOTE_ACTUAL_USER@control-plane-mynodeone"; then
            echo "[INFO] User SSH key generated successfully"
        else
            echo "[ERROR] Failed to generate user SSH key"
            exit 1
        fi
        
        # Set permissions
        chmod 600 "$USER_KEY_PATH"
        chmod 644 "$USER_PUB_KEY_PATH"
        
        # Confirm key was created and is valid
        if [ -f "$USER_KEY_PATH" ] && ssh-keygen -l -f "$USER_KEY_PATH" >/dev/null 2>&1; then
            echo "[SUCCESS] User SSH key created and verified"
        else
            echo "[ERROR] User SSH key creation failed verification"
            exit 1
        fi
    fi
fi

# If generate-only mode, exit here (keys are generated, copying will be done from laptop side)
if [ "$MODE" = "generate-only" ]; then
    echo ""
    echo "[SUCCESS] ✅ SSH keys generated successfully!"
    echo "[INFO] Keys are ready at:"
    echo "  - Root: $ROOT_KEY_PATH"
    if [ "$REMOTE_ACTUAL_USER" != "root" ]; then
        echo "  - User: $USER_KEY_PATH"
    fi
    exit 0
fi

###############################################################################
# 3. Copy keys to laptop with retry logic
###############################################################################

# Helper function to check if key is already on laptop
check_key_on_laptop() {
    local key_content="$1"
    local key_fingerprint=$(echo "$key_content" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}')
    
    if [ -z "$key_fingerprint" ]; then
        return 1
    fi
    
    # Check if key fingerprint exists in authorized_keys
    if ssh -o ConnectTimeout=5 "$LAPTOP_USER@$LAPTOP_IP" "grep -q '$key_fingerprint' ~/.ssh/authorized_keys 2>/dev/null || ssh-keygen -l -f ~/.ssh/authorized_keys 2>/dev/null | grep -q '$key_fingerprint'"; then
        return 0
    else
        return 1
    fi
}

# Copy ROOT key with retry
echo '[INFO] Copying root MyNodeOne SSH key to laptop...'
ROOT_PUB_KEY=$(sudo cat "$ROOT_PUB_KEY_PATH")

if [ -z "$ROOT_PUB_KEY" ]; then
    echo "[ERROR] Failed to read root public key"
    exit 1
fi

# Check if key already exists on laptop
if check_key_on_laptop "$ROOT_PUB_KEY"; then
    echo "[INFO] Root key already exists on laptop, skipping copy"
else
    # Try to copy with retries
    retry_count=0
    copy_success=false
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        echo "[INFO] Copying root key (attempt $((retry_count + 1))/$MAX_RETRIES)..."
        
        if echo "$ROOT_PUB_KEY" | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$LAPTOP_USER@$LAPTOP_IP" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"; then
            echo "[INFO] Root key copied successfully"
            copy_success=true
            break
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $MAX_RETRIES ]; then
                echo "[WARN] Copy failed, retrying in ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
            fi
        fi
    done
    
    if [ "$copy_success" = false ]; then
        echo "[ERROR] Failed to copy root key after $MAX_RETRIES attempts"
        exit 1
    fi
    
    # Verify key was copied
    if check_key_on_laptop "$ROOT_PUB_KEY"; then
        echo "[SUCCESS] Root key verified on laptop"
    else
        echo "[WARN] Root key copy succeeded but verification failed"
    fi
fi

# Copy USER key with retry
if [ "$REMOTE_ACTUAL_USER" != "root" ]; then
    echo "[INFO] Copying user ($REMOTE_ACTUAL_USER) MyNodeOne SSH key to laptop..."
    USER_PUB_KEY=$(cat "$USER_PUB_KEY_PATH")
    
    if [ -z "$USER_PUB_KEY" ]; then
        echo "[ERROR] Failed to read user public key"
        exit 1
    fi
    
    # Check if key already exists on laptop
    if check_key_on_laptop "$USER_PUB_KEY"; then
        echo "[INFO] User key already exists on laptop, skipping copy"
    else
        # Try to copy with retries
        retry_count=0
        copy_success=false
        
        while [ $retry_count -lt $MAX_RETRIES ]; do
            echo "[INFO] Copying user key (attempt $((retry_count + 1))/$MAX_RETRIES)..."
            
            if ssh-copy-id -i "$USER_PUB_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$LAPTOP_USER@$LAPTOP_IP" >/dev/null 2>&1; then
                echo "[INFO] User key copied successfully"
                copy_success=true
                break
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $MAX_RETRIES ]; then
                    echo "[WARN] Copy failed, retrying in ${RETRY_DELAY}s..."
                    sleep $RETRY_DELAY
                fi
            fi
        done
        
        if [ "$copy_success" = false ]; then
            echo "[ERROR] Failed to copy user key after $MAX_RETRIES attempts"
            exit 1
        fi
        
        # Verify key was copied
        if check_key_on_laptop "$USER_PUB_KEY"; then
            echo "[SUCCESS] User key verified on laptop"
        else
            echo "[WARN] User key copy succeeded but verification failed"
        fi
    fi
fi

echo ""
echo "[SUCCESS] ✅ SSH keys configured and verified successfully!"
