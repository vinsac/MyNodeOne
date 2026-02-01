# Setup Scripts

This directory contains scripts for initial configuration and setup of various MyNodeOne components and features.

## Node Setup Scripts

### `setup-management-laptop.sh`
Configures a management laptop for cluster administration.

**Usage:**
```bash
sudo ./scripts/setup/setup-management-laptop.sh
```

### `setup-vps-node.sh`
Configures a VPS for edge node deployment.

### `setup-edge-node.sh`
Sets up edge routing and public access configuration.

### `setup-laptop.sh`
General laptop setup for MyNodeOne access. Includes automatic registration in enterprise registry for DNS sync.

## Infrastructure Setup

### `setup-local-dns.sh`
Configures local DNS resolution for `.local` domains.

### `setup-app-proxy.sh`
Sets up reverse proxy for application access.

### `setup-admin-dashboard.sh`
Deploys and configures the admin dashboard.

### `setup-enterprise-registry.sh`
Configures enterprise container registry.

### `setup-swap.sh`
Configures swap space for memory management.

## SSH Configuration

### `setup-management-laptop-ssh.sh`
Establishes SSH keys between control plane and management laptop.

**Usage:**
```bash
./scripts/setup/setup-management-laptop-ssh.sh <control-plane-user> <control-plane-ip> <laptop-user> <laptop-ip>
```

### `setup-control-plane-sudo.sh`
Configures passwordless sudo for control plane operations.

## Security

### `enable-security-hardening.sh`
Applies security hardening configurations to the cluster.

### `enable-sync-controller-service.sh`
Enables and starts the sync controller systemd service.

## Notes

- Most setup scripts require `sudo` privileges
- Scripts are idempotent - safe to run multiple times
- Configuration changes are logged to `/var/log/mynodeone/`
- Some scripts require Tailscale to be installed and authenticated