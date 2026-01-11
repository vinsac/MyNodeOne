# VPS Management Scripts

This directory contains scripts specifically for managing VPS (Virtual Private Server) edge nodes that provide public internet access to cluster applications.

## VPS Routing

### `configure-vps-route.sh`
Configure routing rules for a VPS edge node.

**Usage:**
```bash
sudo ./scripts/vps/configure-vps-route.sh
```

**Features:**
- Automatic VPS detection from registry
- Route configuration for public access
- Traffic forwarding setup
- NAT configuration
- Firewall rules

**What it does:**
- Sets up routing from public IP to Tailscale network
- Configures port forwarding
- Updates routing tables
- Enables IP forwarding
- Configures iptables rules

### `sync-vps-routes.sh`
Synchronize routing configuration across all VPS nodes.

**Usage:**
```bash
sudo ./scripts/vps/sync-vps-routes.sh
```

**Features:**
- Multi-VPS synchronization
- Automatic retry on failure
- Configuration validation
- Route testing
- Rollback on errors

## Use Cases

### Public Web Access
VPS routes enable public internet access to your applications:
- Domain names point to VPS public IP
- VPS forwards traffic through Tailscale
- Apps remain secure on private network

### Load Balancing
Multiple VPS nodes can distribute traffic:
- Geographic distribution
- High availability
- DDoS protection
- Traffic splitting

### Edge Caching
VPS can cache content at the edge:
- Reduced latency
- Lower bandwidth costs
- Improved performance

## Notes

- VPS nodes must be registered in the node registry
- Tailscale must be running on all nodes
- Public IP addresses must be configured
- Firewall rules may need adjustment
- DNS records should point to VPS public IPs
- Route changes may take a few seconds to apply
- Use `sync-vps-routes.sh` after adding new VPS nodes
