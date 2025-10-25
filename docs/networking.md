# MyNodeOne Networking Guide

Complete guide to networking in MyNodeOne, including Tailscale setup, alternatives, and CLI management.

## Table of Contents

1. [Tailscale Overview](#tailscale-overview)
2. [Tailscale CLI Management](#tailscale-cli-management)
3. [Alternative Solutions](#alternative-solutions)
4. [Comparison & Recommendations](#comparison--recommendations)

---

## Tailscale Overview

### What is Tailscale?

Tailscale creates a **secure mesh VPN** between your machines using WireGuard protocol.

**Key Benefits:**
- ✅ Zero Configuration
- ✅ Secure (WireGuard encryption)
- ✅ Fast (peer-to-peer when possible)
- ✅ Cross-platform
- ✅ NAT Traversal
- ✅ Free Tier (up to 20 devices)

### Why MyNodeOne Uses It

**Problem:** Home servers behind NAT can't be reached from internet.

**Solution:** Tailscale gives each machine a persistent private IP (100.x.x.x) that works everywhere.

---

## Tailscale CLI Management

### Installation

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### Connect to Network

```bash
# Basic connection (opens browser for auth)
sudo tailscale up

# With custom settings
sudo tailscale up --accept-routes --accept-dns=false

# With hostname
sudo tailscale up --hostname="mynodeone-control-01"
```

### Get Your IP

```bash
# Get IPv4
tailscale ip -4

# Show all info
tailscale status
```

### Check Network

```bash
# List all devices
tailscale status

# Get JSON output
tailscale status --json | jq

# Ping another node
tailscale ping 100.x.x.x
```

### Manage Connection

```bash
# Disconnect
tailscale down

# Reconnect
tailscale up

# Logout
tailscale logout
```

### Advanced Usage

```bash
# Use auth key (for automation)
sudo tailscale up --authkey=tskey-auth-xxxxx

# Advertise routes (subnet routing)
sudo tailscale up --advertise-routes=192.168.1.0/24

# Accept routes from others
sudo tailscale up --accept-routes

# Exit node (route all traffic through this machine)
sudo tailscale up --advertise-exit-node
```

### Web Admin Console

Access at: **https://login.tailscale.com/admin**

**Features:**
- View all connected devices
- Generate auth keys
- Configure ACLs
- Enable/disable devices
- View connection logs
- DNS configuration

### Programmatic Access

```bash
# Get all peer IPs
tailscale status --json | jq -r '.Peer[].TailscaleIPs[]'

# Check if peer is online
tailscale status --json | jq -r '.Peer[] | select(.HostName=="myserver") | .Online'

# List peer hostnames
tailscale status --json | jq -r '.Peer[].HostName'
```

### Authentication Keys

For automated deployment:

1. Go to https://login.tailscale.com/admin/settings/keys
2. Generate auth key (reusable or one-time)
3. Use in scripts:

```bash
sudo tailscale up --authkey=tskey-auth-xxxxx
```

---

## Alternative Solutions

### 1. Headscale (Recommended Self-Hosted)

**What:** Open-source Tailscale control server

**Pros:**
- ✅ Fully open source (BSD license)
- ✅ No device limits
- ✅ Complete control
- ✅ Works with Tailscale clients

**Cons:**
- ❌ Requires server for coordination
- ❌ Manual setup

**Setup:**

```bash
# Install Headscale
wget https://github.com/juanfont/headscale/releases/latest/download/headscale_linux_amd64
sudo mv headscale_linux_amd64 /usr/local/bin/headscale
sudo chmod +x /usr/local/bin/headscale

# Create config
sudo mkdir -p /etc/headscale
sudo headscale config example > /etc/headscale/config.yaml

# Edit config
sudo nano /etc/headscale/config.yaml

# Start service
sudo headscale serve &

# Create user
headscale users create mynodeone

# Generate auth key
headscale preauthkeys create --user mynodeone --expiration 24h

# On clients
tailscale up --login-server=https://your-headscale:8080 --authkey=xxx
```

### 2. Netmaker

**What:** WireGuard mesh with web UI

**Pros:**
- ✅ Full web interface
- ✅ Advanced features
- ✅ Good for large networks

**Cons:**
- ❌ Complex setup
- ❌ License restrictions (SSPL)

**Setup:**

```bash
wget https://raw.githubusercontent.com/gravitl/netmaker/master/scripts/nm-quick.sh
chmod +x nm-quick.sh
sudo ./nm-quick.sh
```

### 3. ZeroTier

**What:** Alternative mesh VPN

**Pros:**
- ✅ Easy to use
- ✅ Mature product
- ✅ Self-hostable

**Cons:**
- ❌ Free tier: 25 devices
- ❌ Proprietary protocol
- ❌ Slower than WireGuard

**Setup:**

```bash
curl -s https://install.zerotier.com | sudo bash
sudo zerotier-cli join <network-id>
```

### 4. WireGuard (Manual)

**What:** DIY mesh network

**Pros:**
- ✅ Maximum control
- ✅ No external dependencies
- ✅ Fastest performance

**Cons:**
- ❌ Manual configuration for each peer
- ❌ No NAT traversal
- ❌ Complex key management

**Setup:**

```bash
# Install
sudo apt install wireguard

# Generate keys
wg genkey | tee privatekey | wg pubkey > publickey

# Create config
sudo nano /etc/wireguard/wg0.conf

# Start
sudo wg-quick up wg0
```

### 5. Nebula (by Slack)

**What:** Overlay mesh network

**Pros:**
- ✅ Open source
- ✅ Certificate-based auth
- ✅ Good for enterprise

**Cons:**
- ❌ Requires CA setup
- ❌ More complex than Tailscale

---

## Comparison & Recommendations

### Feature Comparison

| Feature | Tailscale | Headscale | Netmaker | ZeroTier | WireGuard | Nebula |
|---------|-----------|-----------|----------|----------|-----------|---------|
| **Ease of Use** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐ |
| **Setup Time** | 5 min | 30 min | 45 min | 10 min | 60 min | 45 min |
| **Self-Hosted** | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **NAT Traversal** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Free Devices** | 20 | ∞ | ∞ | 25 | ∞ | ∞ |
| **Web UI** | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ |
| **Open Source** | Client | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| **Performance** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Mobile Apps** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |

### MyNodeOne Default: **Tailscale** ⭐

**Tailscale is the default and recommended networking solution for MyNodeOne.**

All scripts are configured to use Tailscale by default. No additional setup needed beyond running the installer.

#### Why Tailscale is Default:
- ✅ **Works immediately** - 5 minute setup
- ✅ **Zero configuration** - Just works
- ✅ **Free for personal use** - 20 devices
- ✅ **Best NAT traversal** - Works behind any firewall
- ✅ **Automatic updates** - Always secure
- ✅ **Cross-platform** - Linux, Windows, Mac, mobile
- ✅ **Perfect for MyNodeOne** - Designed for this use case

**Bottom line:** Use Tailscale unless you have a specific reason not to.

---

### Alternative Options (Advanced Users)

> **Note:** The alternatives below require additional setup and are only needed for specific use cases.
> Most users should stick with Tailscale.

#### For Privacy Advocates: **Headscale**
- 100% self-hosted control server
- Open source alternative to Tailscale
- No device limits
- Requires running your own coordination server

#### For Large Enterprises: **Netmaker**
- Web UI for management
- Good for 50+ nodes
- Advanced networking features

#### For DIY Enthusiasts: **WireGuard**
- Maximum control
- Manual configuration
- No automatic NAT traversal

### Recommendation: Use Tailscale

**Why:**
1. Get MyNodeOne running in 30 minutes
2. Focus on applications, not networking
3. Can switch to Headscale later (same clients)
4. Free tier is generous (20 devices)
5. Best documentation and support

**When to switch to Headscale:**
- You need 20+ devices
- Privacy is critical (no cloud dependency)
- You want 100% control
- You have time for setup/maintenance

---

## Tailscale in MyNodeOne

### How MyNodeOne Uses Tailscale

```
┌─────────────────┐
│  Home Network   │
│  192.168.1.0/24 │
│                 │
│  ┌───────────┐  │      ┌──────────┐
│  │toronto-001│──┼──────│ Internet │
│  │100.x.x.x  │  │      └─────┬────┘
│  └───────────┘  │            │
└─────────────────┘            │
                               │
┌─────────────────┐      ┌─────┴────┐      ┌──────────────┐
│  Home Network   │      │Tailscale │      │  VPS Server  │
│  192.168.2.0/24 │      │  Relay   │      │  Public IP   │
│                 │      └─────┬────┘      │              │
│  ┌───────────┐  │            │           │ ┌──────────┐ │
│  │toronto-002│──┼────────────┴───────────┼─│ VPS-Edge │ │
│  │100.y.y.y  │  │                        │ │100.z.z.z │ │
│  └───────────┘  │                        │ └──────────┘ │
└─────────────────┘                        └──────────────┘
```

**Key Points:**
1. All nodes get Tailscale IPs (100.x.x.x)
2. K3s uses Tailscale IPs for cluster communication
3. VPS routes public traffic to home via Tailscale
4. No port forwarding on home router needed
5. End-to-end encryption

### Configuration in MyNodeOne Scripts

```bash
# scripts/interactive-setup.sh installs Tailscale
# Gets Tailscale IP automatically
TAILSCALE_IP=$(tailscale ip -4 | head -n1)

# Saves to ~/.mynodeone/config.env
echo "TAILSCALE_IP=$TAILSCALE_IP" >> ~/.mynodeone/config.env

# Other scripts read this config
source ~/.mynodeone/config.env

# K3s configured to use Tailscale interface
cat > /etc/rancher/k3s/config.yaml <<EOF
node-ip: "$TAILSCALE_IP"
flannel-iface: tailscale0
EOF
```

---

## Troubleshooting

### Can't Connect to Tailscale

```bash
# Check service status
sudo systemctl status tailscaled

# Restart service
sudo systemctl restart tailscaled

# Try reconnecting
sudo tailscale up
```

### Can't Reach Peer

```bash
# Check if peer is online
tailscale status | grep peer-name

# Ping peer
tailscale ping 100.x.x.x

# Check firewall
sudo ufw status
sudo ufw allow in on tailscale0
```

### Performance Issues

```bash
# Check if using relay (DERP) or direct connection
tailscale status

# Enable DERP logs
tailscale debug derp

# Check latency
tailscale ping 100.x.x.x
```

### Reset Tailscale

```bash
# Logout
sudo tailscale logout

# Stop service
sudo systemctl stop tailscaled

# Remove state
sudo rm -rf /var/lib/tailscale

# Restart
sudo systemctl start tailscaled
sudo tailscale up
```

---

## Summary

**For MyNodeOne:**
- ✅ **Use Tailscale** for easiest setup
- ✅ All CLI commands available
- ✅ Can switch to Headscale later if needed
- ✅ Works great for 1-20 devices
- ✅ No networking knowledge required

**Alternative:** Use Headscale if you need full self-hosting.

For more help:
- Tailscale Docs: https://tailscale.com/kb
- Headscale Repo: https://github.com/juanfont/headscale
- MyNodeOne FAQ: ../FAQ.md
