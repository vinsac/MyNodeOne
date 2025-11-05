#!/bin/bash

# MyNodeOne App DNS Setup for Client Devices
# Run this on your laptop/desktop to access apps via .local domains

set -e

echo "Setting up app DNS entries..."
echo

# Detect OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOSTS_FILE="/etc/hosts"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    HOSTS_FILE="C:\Windows\System32\drivers\etc\hosts"
else
    HOSTS_FILE="/etc/hosts"
fi

# Backup hosts file
sudo cp "$HOSTS_FILE" "${HOSTS_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

# Remove old app entries
sudo sed -i.tmp '/# MyNodeOne Apps/,/# End MyNodeOne Apps/d' "$HOSTS_FILE"

# Add new entries
echo "" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# MyNodeOne Apps" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "100.122.68.206        demoapp.mycloud.local" | sudo tee -a "$HOSTS_FILE" > /dev/null
echo "# End MyNodeOne Apps" | sudo tee -a "$HOSTS_FILE" > /dev/null

echo ""
echo "✅ DNS configured!"
echo ""
echo "You can now access:"
echo "  • demoapp: http://demoapp.mycloud.local"
echo ""
