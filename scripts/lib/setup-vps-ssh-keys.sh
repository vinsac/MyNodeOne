#!/bin/bash

###############################################################################
# Setup SSH Keys for VPS Access
# 
# This script runs ON THE CONTROL PLANE to:
# 1. Generate SSH keys for root and current user
# 2. Copy them to the VPS
#
# Called by setup-reverse-ssh via SSH
#
# Usage:
#   ./setup-vps-ssh-keys.sh <vps-user> <vps-ip>
###############################################################################

set -euo pipefail

VPS_USER="$1"
VPS_IP="$2"

echo "[INFO] Setting up SSH keys for VPS access..."
echo "[INFO] Target: $VPS_USER@$VPS_IP"

# Detect actual user on control plane
REMOTE_ACTUAL_USER="${SUDO_USER:-$(whoami)}"

if [ "$REMOTE_ACTUAL_USER" = "root" ]; then
    REMOTE_ACTUAL_HOME="/root"
else
    REMOTE_ACTUAL_HOME=$(getent passwd "$REMOTE_ACTUAL_USER" | cut -d: -f6)
fi

echo "[DEBUG] Running as user: $REMOTE_ACTUAL_USER"
echo "[DEBUG] Home dir: $REMOTE_ACTUAL_HOME"

# 1. Ensure root user has a MyNodeOne-specific SSH key
# MUST RUN AS ROOT
if sudo [ ! -f /root/.ssh/mynodeone_id_ed25519 ]; then
    echo '[INFO] Generating MyNodeOne SSH key for root user...'
    sudo ssh-keygen -t ed25519 -f /root/.ssh/mynodeone_id_ed25519 -N '' -C 'root@control-plane-mynodeone'
    sudo chmod 600 /root/.ssh/mynodeone_id_ed25519
    sudo chmod 644 /root/.ssh/mynodeone_id_ed25519.pub
else
    echo '[INFO] Root SSH key already exists'
fi

# 2. Ensure actual user has a MyNodeOne-specific SSH key
if [ "$REMOTE_ACTUAL_USER" != "root" ] && [ ! -f "$REMOTE_ACTUAL_HOME/.ssh/mynodeone_id_ed25519" ]; then
    echo "[INFO] Generating MyNodeOne SSH key for user $REMOTE_ACTUAL_USER..."
    mkdir -p "$REMOTE_ACTUAL_HOME/.ssh"
    ssh-keygen -t ed25519 -f "$REMOTE_ACTUAL_HOME/.ssh/mynodeone_id_ed25519" -N '' -C "$REMOTE_ACTUAL_USER@control-plane-mynodeone"
else
    echo "[INFO] User SSH key already exists"
fi

# 3. Copy keys to VPS

# Copy ROOT key (must run as sudo to read /root/.ssh)
echo '[INFO] Copying root MyNodeOne SSH key to VPS...'
ROOT_PUB_KEY=$(sudo cat /root/.ssh/mynodeone_id_ed25519.pub)

# Manually copy to authorized_keys using ssh
if echo "$ROOT_PUB_KEY" | ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$VPS_USER@$VPS_IP" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"; then
    echo "[INFO] Successfully copied root key"
else
    echo "[WARN] Failed to copy root key via ssh."
    exit 1
fi

# Copy USER key
if [ "$REMOTE_ACTUAL_USER" != "root" ]; then
    echo "[INFO] Copying user ($REMOTE_ACTUAL_USER) MyNodeOne SSH key to VPS..."
    if ssh-copy-id -i "$REMOTE_ACTUAL_HOME/.ssh/mynodeone_id_ed25519.pub" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$VPS_USER@$VPS_IP"; then
        echo "[INFO] Successfully copied user key"
    else
        echo "[WARN] Failed to copy user key"
        exit 1
    fi
fi

echo "[SUCCESS] SSH keys configured successfully!"
