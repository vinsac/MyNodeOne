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

## Kubernetes Pod Networking (Flannel VXLAN)

### How Pods Communicate Across Nodes

K3s uses **Flannel** as its Container Network Interface (CNI) with a **VXLAN** backend.
This creates an overlay network that allows any pod on any node to reach any other pod,
regardless of which physical node they run on.

```
┌──────────────────────┐         ┌──────────────────────┐
│  Node 1              │         │  Node 2              │
│  Pod Subnet:         │         │  Pod Subnet:         │
│  10.42.0.0/24        │         │  10.42.2.0/24        │
│                      │         │                      │
│  ┌────────┐          │         │          ┌────────┐  │
│  │ Pod A  │          │         │          │ Pod B  │  │
│  │10.42.0.5│         │         │         │10.42.2.3│  │
│  └───┬────┘          │         │          └───┬────┘  │
│      │               │         │              │       │
│  ┌───▼────┐          │         │          ┌───▼────┐  │
│  │  cni0  │          │         │          │  cni0  │  │
│  │ bridge │          │         │          │ bridge │  │
│  └───┬────┘          │         │          └───┬────┘  │
│      │               │         │              │       │
│  ┌───▼──────┐        │         │        ┌─────▼────┐  │
│  │flannel.1 │ VXLAN encap      │        │flannel.1 │  │
│  │ (VXLAN)  ├────────────UDP 8472──────►│ (VXLAN)  │  │
│  └───┬──────┘        │         │        └─────┬────┘  │
│      │               │         │              │       │
│  ┌───▼──────┐        │         │        ┌─────▼────┐  │
│  │tailscale0│◄───────Tailscale VPN─────►│tailscale0│  │
│  │100.x.x.x │        │         │        │100.y.y.y │  │
│  └──────────┘        │         │        └──────────┘  │
└──────────────────────┘         └──────────────────────┘
```

**Traffic flow**: Pod A (10.42.0.5) → cni0 bridge → flannel.1 → VXLAN encapsulation over
UDP port 8472 → Tailscale tunnel → flannel.1 on Node 2 → cni0 bridge → Pod B (10.42.2.3)

### Why Cross-Node Pod Networking Matters

Cross-node pod communication is a **fundamental Kubernetes requirement**, not an edge case.
Any pod on any node must be able to reach any other pod. This is needed for:

- **Storage**: Longhorn CSI plugin accessing volume replicas on remote nodes
- **DNS**: All pods reaching CoreDNS (which may run on any node)
- **Services**: ClusterIP services routing to backend pods on any node
- **Monitoring**: Prometheus scraping targets across all nodes

This must work regardless of Longhorn replica count, pod scheduling decisions, or node count.

### Firewall Requirements (UFW)

For Flannel VXLAN to work across nodes, UFW must be configured correctly:

```bash
# Required on ALL nodes (control plane AND workers):

# 1. Allow VXLAN encapsulated traffic between nodes
ufw allow 8472/udp comment 'Flannel VXLAN'

# 2. Allow forwarded/routed packets (critical for pod overlay networking)
ufw default allow routed

# 3. Allow Tailscale traffic (for node-to-node communication)
ufw allow in on tailscale0 comment 'Tailscale mesh network'
```

**Why `ufw default allow routed` is critical**: Flannel VXLAN packets arrive at a node's
network interface and must be *forwarded* to the pod's network namespace via the `cni0` bridge.
UFW's default `deny routed` policy drops these forwarded packets, breaking all cross-node
pod communication.

These rules are configured automatically by the installation scripts
(`bootstrap-control-plane.sh` and `add-worker-node.sh`).

### Flannel Interface Health

The `flannel.1` VXLAN interface is created by K3s at startup. If it disappears (e.g., after
a K3s restart or Helm upgrade), all cross-node pod networking breaks.

**Monitoring**: A systemd timer (`flannel-health-monitor`) runs every 2 minutes on each node.
If `flannel.1` is missing, it restarts K3s to recreate the interface (max 3 recoveries/hour).

```bash
# Check Flannel health monitor status
sudo bash scripts/validation/monitor-flannel-health.sh --status

# Manual check
ip link show flannel.1
```

### Validation

After adding a worker node, run the network validation script:

```bash
# Validates UFW, Flannel, VXLAN, cross-node pod connectivity, DNS, and storage
sudo bash scripts/validation/validate-network.sh

# Auto-fix detected issues
sudo bash scripts/validation/validate-network.sh --fix

# Full multi-node end-to-end test
sudo bash scripts/validation/test-multinode.sh
```

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

### Cross-Node Pod Networking Broken

**Symptom**: Pods on worker cannot reach services on control plane (or vice versa).
Longhorn CSI crashlooping. DNS failing from worker pods.

```bash
# Automated diagnosis and fix
sudo bash scripts/validation/validate-network.sh --fix

# Manual checks:
# 1. Flannel interface must exist
ip link show flannel.1

# 2. UFW must allow routed traffic
sudo ufw status verbose | grep "Default:"
# Must show: "allow (routed)"

# 3. VXLAN port must be open
sudo ufw status | grep 8472

# Fix if needed (on EVERY node):
sudo ufw default allow routed
sudo ufw allow 8472/udp comment 'Flannel VXLAN'
sudo ufw reload

# If flannel.1 is missing, restart K3s:
sudo systemctl restart k3s        # control plane
sudo systemctl restart k3s-agent  # worker
```

See [troubleshooting.md](../operations/troubleshooting.md) section 10 for full details.

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