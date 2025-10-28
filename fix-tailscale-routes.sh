#!/bin/bash

# Fix Tailscale Routing for MetalLB LoadBalancer IPs
# This enables direct access to services via .local domains

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 Tailscale Subnet Route Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This will configure the control plane to advertise"
echo "the MetalLB IP range (100.118.5.200-250) to your"
echo "Tailscale network."
echo ""
echo "Required: Run this ON THE CONTROL PLANE (canada-pc-0001)"
echo ""

read -p "Are you running this on the control plane? [y/N]: " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Please run this script on the control plane:"
    echo "  ssh canada-pc-0001@100.118.5.68"
    echo "  cd ~/MyNodeOne"
    echo "  ./fix-tailscale-routes.sh"
    exit 1
fi

echo ""
echo "Step 1: Enable IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# Make it permanent
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

echo "✅ IP forwarding enabled"
echo ""
echo "Step 2: Advertise MetalLB subnet to Tailscale..."
sudo tailscale up --advertise-routes=100.118.5.0/24 --accept-routes

echo "✅ Subnet route advertised"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  IMPORTANT: Approve the Route in Tailscale Admin"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Go to: https://login.tailscale.com/admin/machines"
echo ""
echo "1. Find 'canada-pc-0001' in the list"
echo "2. Click '...' menu → 'Edit route settings'"
echo "3. Toggle ON the subnet route: 100.118.5.0/24"
echo "4. Click 'Save'"
echo ""
echo "Once approved, services will be accessible at:"
echo "  • http://grafana.mynodeone.local"
echo "  • https://argocd.mynodeone.local"
echo "  • http://minio.mynodeone.local:9001"
echo "  • http://open-webui.mynodeone.local"
echo ""
echo "✅ Setup complete! Don't forget to approve the route."
echo ""
