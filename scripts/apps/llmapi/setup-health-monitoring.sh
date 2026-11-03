#!/bin/bash

# LLMAPI Health Monitoring - Installation and Setup Guide
# This script integrates health monitoring into the LLMAPI installation process

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  LLMAPI Health Monitoring Setup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if running as part of LLMAPI installation
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK_SCRIPT="$SCRIPT_DIR/health-check.sh"

if [[ ! -f "$HEALTH_CHECK_SCRIPT" ]]; then
    echo -e "${RED}Error: Health check script not found at $HEALTH_CHECK_SCRIPT${NC}"
    exit 1
fi

echo "🔧 LLMAPI Health Monitoring Features:"
echo ""
echo "  ✅ Reports PVCs stuck in deletion (no automatic action)"
echo "  ✅ Restarts a Deployment when its pod is crash looping or stays not Ready, within a restart budget"
echo "  ✅ Longhorn storage system health checks"
echo "  ✅ Service availability verification"
echo "  ✅ Logging with rotation"
echo "  ✅ Systemd timer integration (5-minute intervals, first run 15 minutes after boot)"
echo ""

# Install monitoring if running as root
if [[ "$EUID" -eq 0 ]]; then
    echo "🚀 Installing automated health monitoring..."
    
    # Install systemd service and timer
    if bash "$HEALTH_CHECK_SCRIPT" --install-monitor; then
        echo -e "${GREEN}✓ Health monitoring successfully installed${NC}"
        echo ""
        echo "📊 Monitoring Status:"
        echo "  • Timer: Active (runs every 5 minutes)"
        echo "  • Logs: /var/log/llmapi/llmapi-health-monitor.sh.log"
        echo "  • Status: sudo systemctl status llmapi-health-monitor.timer"
        echo ""
        echo "🔧 Management Commands:"
        echo "  • View logs: sudo tail -f /var/log/llmapi/llmapi-health-monitor.sh.log"
        echo "  • Run manually: sudo /usr/local/bin/llmapi-health-monitor.sh"
        echo "  • Disable: sudo systemctl disable llmapi-health-monitor.timer"
        echo ""
        echo "🚨 What Gets Monitored:"
        echo "  • PVCs stuck in deletion in namespace 'llmapi' (reported, never forced)"
        echo "  • Deployments restarted when a pod crash loops for 15m or stays not Ready for 30m"
        echo "    (at most 3 restarts per day, with backoff; StatefulSets are only reported)"
        echo "  • Longhorn storage health"
        echo "  • All LLMAPI services (Redis, Gateway, Embedding, Postgres)"
        echo "  • Resource availability and connectivity"
    else
        echo -e "${RED}✗ Health monitoring installation failed${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ Root privileges required for automated monitoring${NC}"
    echo ""
    echo "To install monitoring later, run:"
    echo "  sudo bash $HEALTH_CHECK_SCRIPT --install-monitor"
    echo ""
    echo "Or run manual health checks:"
    echo "  bash $HEALTH_CHECK_SCRIPT"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Health Monitoring Setup Complete${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
