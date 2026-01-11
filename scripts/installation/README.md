# Installation Scripts

This directory contains scripts for installing and uninstalling MyNodeOne components.

## Main Scripts

### `install-mynodeone.sh`
Main installation wizard that guides you through setting up MyNodeOne on any node type.

**Usage:**
```bash
sudo ./scripts/installation/install-mynodeone.sh
```

**Options:**
1. Control Plane - Sets up the main cluster controller
2. Worker Node - Adds compute capacity to existing cluster
3. VPS Edge Node - Enables public internet access
4. Management Workstation - Sets up admin laptop/desktop

### `bootstrap-control-plane.sh`
Low-level script that performs the actual control plane installation. Called by `install-mynodeone.sh`.

### `uninstall-mynodeone.sh`
Completely removes MyNodeOne from a node.

**Usage:**
```bash
sudo ./scripts/installation/uninstall-mynodeone.sh [--keep-config]
```

## Component Installers

### `install-config-api.sh`
Installs the Config API server for configuration distribution to nodes.

### `install-node-agent.sh`
Installs the Node Agent daemon that polls for configuration updates.

### `install-vps-edge-node.sh`
Specialized installer for VPS edge nodes that provide public access.

### `interactive-setup.sh`
Interactive configuration wizard for gathering installation parameters.

## Notes

- All installation scripts must be run with `sudo`
- Scripts handle prerequisites checking and validation
- Configuration is stored in `~/.mynodeone/config.env`
- Detailed logs are written to `/var/log/mynodeone/`
