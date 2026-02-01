# Networking Architecture

MyNodeOne uses Tailscale as its default networking layer to create a secure mesh VPN between all cluster nodes.

---

## Overview

### The Problem

Home servers behind NAT cannot be reached from the internet without complex port forwarding or dynamic DNS configuration.

### The Solution

Tailscale assigns each machine a persistent private IP (100.x.x.x) that works from anywhere, regardless of NAT or firewall configuration.

---

## How MyNodeOne Uses Tailscale

```
┌─────────────────┐
│  Home Network   │
│  192.168.1.0/24 │
│                 │
│  ┌───────────┐  │      ┌──────────┐
│  │Control    │──┼──────│ Internet │
│  │Plane      │  │      └─────┬────┘
│  │100.x.x.x  │  │            │
│  └───────────┘  │            │
└─────────────────┘            │
                               │
┌─────────────────┐      ┌─────┴────┐      ┌──────────────┐
│  Other Network  │      │Tailscale │      │  VPS Server  │
│  192.168.2.0/24 │      │  Relay   │      │  Public IP   │
│                 │      └─────┬────┘      │              │
│  ┌───────────┐  │            │           │ ┌──────────┐ │
│  │  Worker   │──┼────────────┴───────────┼─│ VPS Edge │ │
│  │100.y.y.y  │  │                        │ │100.z.z.z │ │
│  └───────────┘  │                        │ └──────────┘ │
└─────────────────┘                        └──────────────┘
```

**Key Points:**
- All nodes get Tailscale IPs (100.x.x.x)
- K3s uses Tailscale IPs for cluster communication
- VPS routes public traffic to home via Tailscale
- No port forwarding on home router needed
- End-to-end WireGuard encryption

---

## Subnet Routes

### What Are Subnet Routes?

MetalLB assigns LoadBalancer IPs in a specific range (e.g., 100.118.5.200-250). These IPs only exist on the control plane's network. Subnet routes advertise this range through Tailscale, making services accessible from any device on your Tailscale network.

### Configuration

**Control Plane (automatic during installation):**
```bash
sudo tailscale up --advertise-routes=100.118.5.0/24 --accept-routes
```

**Management Laptop (automatic during setup):**
```bash
sudo tailscale up --accept-routes
```

### Required Steps

1. Control plane advertises the subnet
2. Approve the route in Tailscale admin console (https://login.tailscale.com/admin/machines)
3. Laptop accepts routes from control plane

Without step 3, your laptop can reach the control plane but not the services running on it.

---

## Tailscale CLI Reference

### Basic Commands

```bash
# Connect to network
sudo tailscale up

# Get your IP
tailscale ip -4

# Check status
tailscale status

# Disconnect
tailscale down
```

### Advanced Options

```bash
# Accept routes from other nodes
sudo tailscale up --accept-routes

# Advertise subnet routes
sudo tailscale up --advertise-routes=192.168.1.0/24

# Use auth key (for automation)
sudo tailscale up --authkey=tskey-auth-xxxxx

# Set hostname
sudo tailscale up --hostname="mynodeone-control"
```

---

## K3s Network Configuration

MyNodeOne configures K3s to use Tailscale:

```yaml
# /etc/rancher/k3s/config.yaml
node-ip: "100.x.x.x"        # Tailscale IP
flannel-iface: tailscale0   # Use Tailscale interface
```

This ensures all cluster traffic flows over the encrypted Tailscale mesh.

---

## Why Tailscale?

| Benefit | Description |
|---------|-------------|
| Zero configuration | Works immediately, no networking expertise needed |
| NAT traversal | Works behind any firewall or NAT |
| Security | WireGuard encryption, no public exposure |
| Cross-platform | Linux, Windows, Mac, iOS, Android |
| Free tier | Up to 100 devices for personal use |

---

## Alternative Solutions

For users who need full self-hosting or have specific requirements:

### Headscale (Self-Hosted Tailscale)

Open-source Tailscale control server. Uses the same Tailscale clients but you run the coordination server.

**When to use:**
- Need more than 100 devices
- Require 100% self-hosted solution
- Privacy-critical deployments

**Setup complexity:** Moderate (30-45 minutes)

### ZeroTier

Alternative mesh VPN with similar ease of use.

**When to use:**
- Already using ZeroTier
- Prefer their ecosystem

**Trade-offs:** Proprietary protocol, slightly slower than WireGuard

### Manual WireGuard

Direct WireGuard configuration without a coordination service.

**When to use:**
- Maximum control needed
- Static network topology
- No NAT traversal required

**Trade-offs:** Manual key management, no automatic NAT traversal

---

## Troubleshooting

### Cannot Connect to Services

```bash
# Check if accepting routes
tailscale status --self
# Look for "accept-routes is false" warning

# Enable route acceptance
sudo tailscale up --accept-routes

# Verify subnet route approved in admin console
```

### Cannot Reach Peer

```bash
# Check peer status
tailscale status | grep peer-name

# Test connectivity
tailscale ping 100.x.x.x

# Check firewall
sudo ufw allow in on tailscale0
```

### Performance Issues

```bash
# Check connection type (direct vs relay)
tailscale status
# "relay" indicates traffic going through DERP server

# Check latency
tailscale ping 100.x.x.x
```

### Reset Tailscale

```bash
sudo tailscale logout
sudo systemctl stop tailscaled
sudo rm -rf /var/lib/tailscale
sudo systemctl start tailscaled
sudo tailscale up
```

---

## Security Considerations

### What Tailscale Provides

- End-to-end WireGuard encryption
- No public IP exposure for home servers
- Identity-based access (tied to Tailscale account)
- Automatic key rotation

### What You Should Do

- Enable 2FA on your Tailscale account
- Review connected devices periodically
- Use ACLs for multi-user setups
- Keep Tailscale client updated

---

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - Overall system architecture
- [SYNC-CONTROLLER.md](SYNC-CONTROLLER.md) - How nodes communicate
- Tailscale Documentation: https://tailscale.com/kb
- Headscale Repository: https://github.com/juanfont/headscale