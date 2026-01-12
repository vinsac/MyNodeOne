# Uninstalling MyNodeOne

This guide covers how to completely remove MyNodeOne from your machines.

> **⚠️ Important:** Uninstalling will remove your cluster and applications. Always backup important data before proceeding.

---

## Quick Uninstall

Run on **any node** (control plane, worker, management laptop, or VPS):

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh
```

The script will detect the node type and guide you through the removal process.

---

## Uninstall Options

### Interactive Mode (Default)

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh
```

You'll be asked what to keep or remove:
- Kubernetes cluster and apps
- Application data (photos, videos, etc.)
- Configuration files
- Container images
- Tailscale

### Keep Configuration for Reinstall

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh --keep-config
```

Preserves `~/.mynodeone/` so you can reinstall with the same settings.

### Keep Application Data

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh --keep-data
```

Preserves Longhorn volumes (your app data stays on disk).

### Complete Removal

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh --full
```

Removes everything except Tailscale and formatted disks.

### Non-Interactive Mode

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh --full --yes
```

Skips all prompts and removes everything (useful for automation).

### Remove Tailscale Too

```bash
sudo ./scripts/installation/uninstall-mynodeone.sh --full --remove-tailscale --yes
```

Also removes Tailscale from the machine.

---

## What Gets Removed

| Component | Default | With --keep-config | With --keep-data |
|-----------|---------|-------------------|------------------|
| Kubernetes cluster (K3s) | Removed | Removed | Removed |
| Running pods and services | Removed | Removed | Removed |
| Container images | Removed | Removed | Removed |
| ConfigMaps (registries) | Removed | Kept | Removed |
| Configuration files | Removed | Kept | Removed |
| Application data (PVCs) | Removed | Removed | Kept |
| DNS configurations | Removed | Removed | Removed |
| Systemd services | Removed | Removed | Removed |
| Node Agent service | Removed | Removed | Removed |
| VPS Traefik setup | Removed | Kept | Removed |
| Tailscale | Kept | Kept | Kept |
| Formatted disks | Kept | Kept | Kept |

---

## Uninstalling Specific Node Types

### Control Plane

```bash
# ON CONTROL PLANE:
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- K3s server and all cluster data
- Longhorn storage system
- Sync controller service
- Node Agent service
- All ConfigMaps and service registries
- DNS configurations
- SSH keys (root and user)
- Credential files and join tokens

### Worker Node

```bash
# ON WORKER NODE:
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- K3s agent
- Node Agent service
- Local storage mounts (unmounted)
- SSH configurations
- DNS configurations

### Management Laptop

```bash
# ON MANAGEMENT LAPTOP:
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- kubectl configuration
- Node Agent service
- DNS entries in /etc/hosts
- MyNodeOne config files
- SSH keys for cluster access

### VPS Edge Node

```bash
# ON VPS:
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- Traefik reverse proxy
- Docker containers and volumes
- Route configurations
- Node Agent service
- Sync cron jobs
- SSH configurations

---

## Manual Cleanup (If Needed)

After uninstall, you may want to manually remove:

```bash
# Remove formatted disk data (WARNING: This permanently deletes data)
sudo rm -rf /mnt/longhorn-disks/

# Remove Tailscale
sudo apt remove tailscale

# Remove any remaining config
rm -rf ~/.mynodeone
rm -rf ~/.kube

# Remove Git repository
rm -rf ~/MyNodeOne

# Remove Traefik config (VPS only)
sudo rm -rf /etc/traefik

# Clean systemd services
sudo systemctl list-units | grep mynodeone
sudo systemctl reset-failed mynodeone-node-agent 2>/dev/null || true
```

---

## Reinstalling After Uninstall

If you kept configuration (`--keep-config`):
```bash
sudo ./scripts/installation/install-mynodeone.sh
# Will use existing configuration
```

If you removed everything:
```bash
git clone https://github.com/vinsac/MyNodeOne.git
cd MyNodeOne
sudo ./scripts/installation/install-mynodeone.sh
# Will ask for new configuration
```

---

## Troubleshooting

### K3s Won't Uninstall

```bash
# Force stop K3s
sudo systemctl stop k3s
sudo killall k3s-server k3s-agent 2>/dev/null

# Run uninstall script manually
sudo /usr/local/bin/k3s-uninstall.sh
```

### Leftover Processes

```bash
# Check for remaining processes
ps aux | grep -E "k3s|containerd|kubelet|mynodeone-node-agent"

# Kill if necessary
sudo killall containerd-shim-runc-v2 2>/dev/null || true
sudo killall mynodeone-node-agent 2>/dev/null || true
```

### Stuck Mounts

```bash
# Force unmount Longhorn disks
sudo umount -l /mnt/longhorn-disks/* 2>/dev/null || true

# Remove from fstab if persistent
sudo sed -i '/longhorn-disks/d' /etc/fstab 2>/dev/null || true
```
