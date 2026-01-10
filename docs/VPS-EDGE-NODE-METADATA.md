# VPS Edge Node Metadata Management

## Overview

VPS edge nodes in MyNodeOne now store comprehensive metadata similar to cluster nodes (control plane and workers). This metadata includes hardware specifications, location, provider information, and software versions.

## Metadata Structure

VPS edge nodes store the following information in the cluster registry:

### Basic Information
- **name**: Node name (e.g., `vps-edge-0001`)
- **ip / tailscale_ip**: Tailscale private IP for cluster communication
- **tailscale_hostname**: Tailscale hostname (e.g., `100.99.197.116.tailscale.net`)
- **public_ip**: Internet-facing public IP address
- **ssh_user**: SSH username for remote access
- **role**: Always `edge` for VPS nodes
- **location**: Geographic location/region (e.g., `nyc3`, `lon1`, `sgp1`)
- **provider**: Cloud provider (e.g., `digitalocean`, `vultr`, `aws`, `gcp`)

### Hardware Information
```json
{
  "cpu": "Intel Xeon E5-2650 v4 @ 2.20GHz",
  "ram": "4.0Gi",
  "disk": "80G",
  "os": "Ubuntu 22.04.3 LTS"
}
```

### Traefik Configuration
```json
{
  "enabled": true,
  "version": "v2.10"
}
```

### Installation Metadata
```json
{
  "docker_version": "24.0.7",
  "mynodeone_version": "1.5.0"
}
```

### Timestamps
- **registered**: Initial registration timestamp
- **last_sync**: Last configuration sync timestamp
- **last_updated**: Last metadata update timestamp
- **status**: Node status (`active`, `inactive`)

## Automatic Metadata Collection During Installation

When you install a VPS edge node using the orchestrated installation flow, metadata is automatically collected and registered:

```bash
# From control plane
sudo ./scripts/install-vps-edge-node.sh \
  --name vps-edge-0001 \
  --ip 100.99.197.116 \
  --user sammy \
  --public-ip 203.0.113.10 \
  --domain vps.example.com \
  --location nyc3
```

The installation process:
1. Installs MyNodeOne on the VPS
2. Collects comprehensive metadata from the VPS
3. Registers the VPS with full metadata in the cluster registry
4. Validates the registration

## Updating VPS Metadata Post-Installation

You can update VPS metadata at any time using the `update-vps-metadata.sh` script.

### Option 1: Update from the VPS Itself

Run this command on the VPS to update its own metadata:

```bash
# On the VPS
sudo ./scripts/update-vps-metadata.sh
```

This will:
- Collect current metadata from the local system
- Update the cluster registry via the control plane
- Validate the update

### Option 2: Update from Control Plane

Run this command on the control plane to update a remote VPS:

```bash
# On control plane
sudo ./scripts/update-vps-metadata.sh --name vps-edge-0001 --ip 100.99.197.116
```

This will:
- SSH into the VPS
- Collect metadata remotely
- Update the cluster registry
- Validate the update

## Manual Metadata Update

For advanced use cases, you can manually update specific metadata fields:

```bash
# Collect metadata JSON
METADATA=$(ssh sammy@100.99.197.116 "sudo bash ~/mynodeone/scripts/lib/collect-vps-metadata.sh json")

# Update using registry manager
sudo ./scripts/lib/node-registry-manager.sh update-vps-metadata \
  --name vps-edge-0001 \
  --metadata-json "$METADATA"
```

## Viewing VPS Metadata

### View All VPS Nodes

```bash
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | jq '.vps_nodes'
```

### View Specific VPS Node

```bash
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | \
  jq '.vps_nodes[] | select(.name=="vps-edge-0001")'
```

### Compare with Cluster Nodes

```bash
# View control plane metadata
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | \
  jq '.cluster_nodes[] | select(.role=="control-plane")'

# View worker node metadata
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | \
  jq '.cluster_nodes[] | select(.role=="worker")'
```

## Metadata Collection Details

The metadata collector (`scripts/lib/collect-vps-metadata.sh`) automatically detects:

### Hardware Detection
- **CPU**: From `/proc/cpuinfo`
- **RAM**: Using `free -h`
- **Disk**: Using `df -h /`
- **OS**: From `/etc/os-release`

### Provider Detection
The script uses heuristics to detect the cloud provider:
- Checks DMI information (`/sys/class/dmi/id/`)
- Queries cloud metadata APIs (DigitalOcean, AWS, GCP)
- Falls back to manual configuration if auto-detection fails

### Location Detection
- **DigitalOcean**: Queries metadata API for region
- **AWS**: Queries metadata API for availability zone
- **Other providers**: Uses `VPS_LOCATION` environment variable or manual configuration

### Software Detection
- **Docker**: Version from `docker --version`
- **Traefik**: Status and version from Docker containers
- **Public IP**: Queries multiple services (ipify.org, ifconfig.me, icanhazip.com)

## When to Update Metadata

Update VPS metadata when:

1. **Hardware changes**: VPS upgraded/downgraded
2. **Software updates**: Docker or Traefik version changes
3. **Location changes**: VPS migrated to different region
4. **Provider changes**: Moved to different cloud provider
5. **Periodic maintenance**: Recommended monthly to keep data fresh

## Automation

### Automatic Updates via Cron

Set up automatic metadata updates on the VPS:

```bash
# On the VPS, add to crontab
sudo crontab -e

# Add this line to update metadata daily at 3 AM
0 3 * * * /home/sammy/mynodeone/scripts/update-vps-metadata.sh >> /var/log/mynodeone-metadata-update.log 2>&1
```

### Automatic Updates via Node Agent

The Node Agent can be configured to periodically update metadata:

```bash
# Edit Node Agent configuration
sudo nano /etc/mynodeone/node-agent.conf

# Add or modify:
METADATA_UPDATE_INTERVAL=86400  # Update every 24 hours
```

## Troubleshooting

### Metadata Collection Fails

If metadata collection fails:

```bash
# Test metadata collector directly
sudo bash ~/mynodeone/scripts/lib/collect-vps-metadata.sh json

# Check for missing dependencies
which jq curl docker

# Install missing dependencies
sudo apt-get update
sudo apt-get install -y jq curl
```

### Registry Update Fails

If registry update fails:

```bash
# Verify connectivity to control plane
ping -c 3 <control-plane-tailscale-ip>

# Check kubectl access (on control plane)
kubectl get configmap sync-controller-registry -n kube-system

# Manually verify node exists
kubectl get configmap sync-controller-registry -n kube-system \
  -o jsonpath='{.data.registry\.json}' | jq '.vps_nodes[] | select(.name=="vps-edge-0001")'
```

### SSH Access Issues

If remote metadata collection fails:

```bash
# Test SSH access from control plane
ssh -o ConnectTimeout=10 sammy@100.99.197.116 "echo OK"

# Verify Tailscale connectivity
tailscale ping 100.99.197.116

# Check SSH keys
ls -la ~/.ssh/mynodeone_vps_installer
```

## Best Practices

1. **Update metadata after changes**: Always update metadata after hardware upgrades, software updates, or migrations
2. **Automate updates**: Set up cron jobs or use Node Agent for automatic updates
3. **Verify after updates**: Always check that metadata was updated correctly
4. **Document manual changes**: If you manually edit the registry, document the changes
5. **Backup before major changes**: Backup the ConfigMap before making significant metadata changes

## Migration from Legacy Registration

If you have VPS nodes registered with the old basic registration (without comprehensive metadata):

```bash
# Update existing VPS with comprehensive metadata
sudo ./scripts/update-vps-metadata.sh --name vps-edge-0001 --ip 100.99.197.116
```

This will:
- Preserve existing registration
- Add comprehensive metadata
- Maintain backward compatibility

## Example: Complete VPS Metadata

```json
{
  "name": "vps-edge-0001",
  "ip": "100.99.197.116",
  "tailscale_ip": "100.99.197.116",
  "tailscale_hostname": "100.99.197.116.tailscale.net",
  "public_ip": "203.0.113.10",
  "ssh_user": "sammy",
  "webhook_port": 8080,
  "repo_path": "",
  "role": "edge",
  "location": "nyc3",
  "provider": "digitalocean",
  "hardware": {
    "cpu": "Intel Xeon E5-2650 v4 @ 2.20GHz",
    "ram": "4.0Gi",
    "disk": "80G",
    "os": "Ubuntu 22.04.3 LTS"
  },
  "traefik": {
    "enabled": true,
    "version": "v2.10"
  },
  "installation": {
    "docker_version": "24.0.7",
    "mynodeone_version": "1.5.0"
  },
  "registered": "2026-01-09T22:34:55-05:00",
  "last_sync": "2026-01-10T12:00:00-05:00",
  "last_updated": "2026-01-10T12:00:00-05:00",
  "status": "active"
}
```

## See Also

- [VPS Edge Node Installation Guide](../external-apps/GETTING-STARTED.md)
- [Node Registry Manager Documentation](../docs/architecture/NODE-REGISTRY.md)
- [Cluster Node Metadata](../docs/architecture/CLUSTER-NODES.md)
