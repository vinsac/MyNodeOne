# Operations Scripts

This directory contains scripts for day-to-day cluster operations, app management, and maintenance tasks.

## Application Management

### `manage-apps.sh`
Interactive menu for managing deployed applications.

**Usage:**
```bash
sudo ./scripts/operations/manage-apps.sh
```

**Features:**
- List all deployed apps
- Start/stop applications
- View app status
- Delete applications

### `manage-app-visibility.sh`
Configure public internet access for applications via VPS edge nodes.

**Usage:**
```bash
sudo ./scripts/operations/manage-app-visibility.sh
```

### `create-app.sh`
Create a new application from templates.

**Usage:**
```bash
sudo ./scripts/operations/create-app.sh
```

### `deploy-demo-app.sh`
Deploy demonstration applications for testing.

### `app-store.sh`
Browse and install applications from the MyNodeOne app store.

**Usage:**
```bash
sudo ./scripts/operations/app-store.sh
```

## Cluster Management

### `admin.sh`
Main administrative interface for cluster management.

**Usage:**
```bash
sudo ./scripts/operations/admin.sh
```

### `cluster-status.sh`
Display comprehensive cluster health and status.

**Usage:**
```bash
sudo ./scripts/operations/cluster-status.sh
```

### `validate-cluster.sh`
Validate cluster configuration and detect issues.

**Usage:**
```bash
sudo ./scripts/operations/validate-cluster.sh
```

### `audit-registry-consistency.sh`
Audit node registry for consistency issues.

### `upgrade-sync-controller.sh`
Upgrade the sync controller to the latest version.

## Notes

- Most operations scripts require `sudo` privileges
- Scripts provide interactive menus for ease of use
- Changes are logged to `/var/log/mynodeone/`
- Use `cluster-status.sh` for quick health checks
- Run `validate-cluster.sh` after making configuration changes
