# Uninstalling MyNodeOne

This guide covers how to remove MyNodeOne from your machines.

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

Skips all prompts (useful for automation).

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
| VPS Traefik setup | Removed | Kept | Removed |
| Tailscale | Kept | Kept | Kept |
| Formatted disks | Kept | Kept | Kept |

---

## Uninstalling Specific Node Types

### Control Plane

```bash
# On control plane
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- K3s server
- All cluster data and ConfigMaps
- Longhorn storage system
- Sync controller service

### Worker Node

```bash
# On worker node
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- K3s agent
- Local storage mounts

### Management Laptop

```bash
# On management laptop
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- kubectl configuration
- DNS entries in /etc/hosts
- MyNodeOne config files

### VPS Edge Node

```bash
# On VPS
sudo ./scripts/installation/uninstall-mynodeone.sh
```

This removes:
- Traefik reverse proxy
- Docker containers
- Route configurations
- Sync cron jobs

---

## Manual Cleanup (If Needed)

After uninstall, you may want to manually remove:

```bash
# Remove formatted disk data
sudo rm -rf /mnt/longhorn-disks/

# Remove Tailscale
sudo apt remove tailscale

# Remove any remaining config
rm -rf ~/.mynodeone
rm -rf ~/.kube

# Remove Git repository
rm -rf ~/MyNodeOne
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
ps aux | grep -E "k3s|containerd|kubelet"

# Kill if necessary
sudo killall containerd-shim-runc-v2 2>/dev/null
```

### Stuck Mounts

```bash
# Force unmount
sudo umount -l /mnt/longhorn-disks/*
```
