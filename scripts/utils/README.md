# Utility Scripts

This directory contains utility and helper scripts for various administrative and troubleshooting tasks.

## Credential Management

### `show-credentials.sh`
Display stored credentials for installed services.

**Usage:**
```bash
sudo ./scripts/utils/show-credentials.sh
```

**Shows:**
- Longhorn dashboard credentials
- MinIO access keys
- Grafana admin password
- Other service credentials

## Prerequisites & Validation

### `check-prerequisites.sh`
Check if prerequisites are met before installation.

**Usage:**
```bash
./scripts/utils/check-prerequisites.sh <type> [control-plane-ip] [ssh-user]
```

**Types:**
- `control-plane` - Check control plane prerequisites
- `vps` - Check VPS prerequisites
- `management` - Check management laptop prerequisites

### `enforce-prerequisites.sh`
Enforce that prerequisites are met (with failure on missing requirements).

**Usage:**
```bash
sudo ./scripts/utils/enforce-prerequisites.sh <node-type> [control-plane-ip] [ssh-user]
```

## Cluster Configuration

### `create-cluster-info-configmap.sh`
Create or update the cluster-info ConfigMap with cluster metadata.

**Usage:**
```bash
sudo ./scripts/utils/create-cluster-info-configmap.sh
```

## Troubleshooting

### `check-certificates.sh`
Check SSL/TLS certificate validity and expiration.

**Usage:**
```bash
sudo ./scripts/utils/check-certificates.sh
```

### `fix-usb-disk-boot.sh`
Fix USB disk boot issues on nodes.

**Usage:**
```bash
sudo ./scripts/utils/fix-usb-disk-boot.sh
```

## Cleanup

### `cleanup-minio-aliases.sh`
Clean up stale MinIO client aliases.

**Usage:**
```bash
./scripts/utils/cleanup-minio-aliases.sh
```

## Legal

### `show-disclaimer.sh`
Display legal disclaimer and usage terms.

**Usage:**
```bash
source ./scripts/utils/show-disclaimer.sh
```

## Notes

- Most utility scripts require `sudo` privileges
- Credential scripts never write credentials to logs
- Prerequisites checks are non-destructive
- Troubleshooting scripts are safe to run multiple times
- Some scripts are sourced rather than executed directly