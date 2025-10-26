#!/bin/bash

###############################################################################
# MyNodeOne Unattended Installation Script
# 
# This script automates the installation by providing default answers
# to all interactive prompts.
###############################################################################

set -euo pipefail

# Get the current hostname
HOSTNAME=$(hostname)
# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "100.0.0.1")

# Prepare automated answers
# Format: each line is an answer to a prompt in the order they appear
cat > /tmp/mynodeone-answers.txt <<EOF
y
2
y
y
y
control-plane
mynodeone
${HOSTNAME}
home
0
n
y
y
y
y
EOF

# Run the installation with automated answers
echo "Starting unattended MyNodeOne installation..."
echo "Using hostname: ${HOSTNAME}"
echo "Using Tailscale IP: ${TAILSCALE_IP}"
echo

cat /tmp/mynodeone-answers.txt | sudo ./scripts/mynodeone

# Clean up
rm -f /tmp/mynodeone-answers.txt
