#!/bin/bash

###############################################################################
# Setup Swap Space for LLM Workloads
# 
# Creates a large swap file to prevent OOM crashes when running large models
# Recommended: 64GB for systems with 256GB RAM
###############################################################################

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Default swap size (in GB)
DEFAULT_SWAP_SIZE=64
SWAPPINESS=10

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Swap Space Setup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Check current swap
CURRENT_SWAP=$(free -g | awk '/^Swap:/ {print $2}')
echo "Current swap: ${CURRENT_SWAP}GB"
echo ""

if [ "$CURRENT_SWAP" -gt 0 ]; then
    echo -e "${YELLOW}Swap already configured!${NC}"
    echo ""
    free -h
    echo ""
    swapon --show
    echo ""
    
    read -p "Do you want to reconfigure swap? [y/N]: " RECONFIGURE
    if [ "${RECONFIGURE,,}" != "y" ]; then
        echo "Exiting without changes."
        exit 0
    fi
    
    echo ""
    echo "Disabling current swap..."
    swapoff -a
    
    # Remove old swap entries from fstab
    sed -i '/swap/d' /etc/fstab
fi

# Check available disk space
AVAILABLE_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
echo "Available disk space: ${AVAILABLE_GB}GB"
echo ""

# Suggest swap size based on RAM
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
echo "Total RAM: ${TOTAL_RAM_GB}GB"
echo ""

# Calculate suggested swap size
if [ "$TOTAL_RAM_GB" -ge 256 ]; then
    SUGGESTED_SWAP=64
elif [ "$TOTAL_RAM_GB" -ge 128 ]; then
    SUGGESTED_SWAP=32
elif [ "$TOTAL_RAM_GB" -ge 64 ]; then
    SUGGESTED_SWAP=16
else
    SUGGESTED_SWAP=8
fi

echo "💡 Swap size recommendations:"
echo "   • 64GB RAM or less:    8-16GB swap"
echo "   • 128GB RAM:           16-32GB swap"
echo "   • 256GB RAM:           32-64GB swap (for 70B models)"
echo "   • 512GB+ RAM:          64-128GB swap"
echo ""
echo "   Suggested for your system: ${SUGGESTED_SWAP}GB"
echo ""

read -p "Enter swap size in GB [default: $SUGGESTED_SWAP]: " SWAP_SIZE
SWAP_SIZE="${SWAP_SIZE:-$SUGGESTED_SWAP}"

# Validate swap size
if ! [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Invalid swap size. Must be a number.${NC}"
    exit 1
fi

if [ "$SWAP_SIZE" -gt "$AVAILABLE_GB" ]; then
    echo -e "${RED}Not enough disk space! Available: ${AVAILABLE_GB}GB, Requested: ${SWAP_SIZE}GB${NC}"
    exit 1
fi

echo ""
echo "Creating ${SWAP_SIZE}GB swap file..."
echo "⏳ This may take 1-2 minutes..."
echo ""

# Remove old swap files
rm -f /swapfile /swap.img

# Create new swap file
dd if=/dev/zero of=/swapfile bs=1G count="$SWAP_SIZE" status=progress

# Set proper permissions
chmod 600 /swapfile

# Format as swap
mkswap /swapfile

# Enable swap
swapon /swapfile

# Add to fstab for persistence
if ! grep -q "^/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# Set swappiness (how aggressive to use swap)
sysctl vm.swappiness=$SWAPPINESS

# Make swappiness persistent
if ! grep -q "^vm.swappiness" /etc/sysctl.conf; then
    echo "vm.swappiness=$SWAPPINESS" >> /etc/sysctl.conf
else
    sed -i "s/^vm.swappiness=.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Swap Configured Successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Show status
free -h
echo ""
swapon --show
echo ""

echo "Configuration:"
echo "  • Swap size:    ${SWAP_SIZE}GB"
echo "  • Swappiness:   $SWAPPINESS (only swap when needed)"
echo "  • File:         /swapfile"
echo "  • Persistent:   Yes (via /etc/fstab)"
echo ""

echo "📊 What This Means:"
echo ""
echo "  ✅ System won't crash if memory is exhausted"
echo "  ✅ Large models can use overflow space"
echo "  ✅ Performance degrades instead of crashing"
echo "  ✅ Automatic across reboots"
echo ""

echo "⚠️  Important Notes:"
echo ""
echo "  • Swap is MUCH slower than RAM (expect 50-100x slower)"
echo "  • Swappiness=10 means: avoid swap unless critical"
echo "  • When swap is used, model inference will be slower"
echo "  • Monitor with: watch -n 2 'free -h'"
echo ""

echo "🎯 For Best Performance:"
echo ""
echo "  1. Keep memory usage under 128GB (RAM limit)"
echo "  2. Swap is emergency overflow only"
echo "  3. If swap is used frequently, reduce model size"
echo "  4. Consider using quantized models (Q4_K_M)"
echo ""
