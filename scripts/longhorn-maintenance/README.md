# Longhorn Maintenance & Monitoring

Automated maintenance, monitoring, and alerting for Longhorn disk utilization and balance.

**Location:** `~/MyNodeOne/scripts/longhorn-maintenance/`

All Longhorn-related maintenance scripts, monitoring tools, and documentation are consolidated in this folder.

## Overview

This monitoring solution tracks:
- Disk capacity and usage per disk
- Replica distribution across disks
- Disk reservation levels
- Disk imbalance ratios
- Schedulability status

## Folder Structure

```
longhorn-maintenance/
├── README.md                          # This file
├── scripts/                           # All maintenance scripts
│   ├── longhorn-disk-exporter.sh     # Daily metrics export
│   ├── quarterly-longhorn-maintenance.sh  # Quarterly automated maintenance
│   ├── setup-longhorn-monitoring.sh  # Initial setup script
│   ├── fix-longhorn-disk-reservation.sh   # Fix disk reservations
│   ├── balance-longhorn-replicas.sh  # Check replica distribution
│   ├── auto-balance-longhorn-replicas.sh  # Force rebalancing
│   └── add-disk-to-longhorn.sh       # Add new disk to Longhorn
└── prometheus-alerts/                 # Prometheus alert rules
    └── longhorn-disk-alerts.yaml     # Pre-configured alerts
```

## Components

### 1. `scripts/longhorn-disk-exporter.sh`
Exports Longhorn disk metrics in Prometheus format.

**Metrics exported:**
- `longhorn_disk_capacity_bytes` - Total disk capacity
- `longhorn_disk_scheduled_bytes` - Scheduled storage
- `longhorn_disk_reserved_bytes` - Reserved storage
- `longhorn_disk_available_bytes` - Available storage
- `longhorn_disk_usage_ratio` - Usage ratio (0.0-1.0)
- `longhorn_disk_replica_count` - Number of replicas per disk
- `longhorn_disk_schedulable` - Whether disk accepts new replicas
- `longhorn_node_disk_imbalance_ratio` - Disk imbalance (0.0=balanced, 1.0=max)

**Location:** Metrics are written to `/var/lib/node_exporter/textfile_collector/longhorn_disk_balance.prom`

**Schedule:** Runs **daily at 3 AM** via cron (disk metrics change slowly, daily updates are sufficient)

### 2. `scripts/quarterly-longhorn-maintenance.sh`
Automated quarterly maintenance script that runs every 3 months.

**What it does:**
- Checks and fixes disk reservations
- Analyzes replica distribution
- Automatically rebalances if imbalance >30%
- Logs all actions to `/var/log/mynodeone/`

**Schedule:** Runs **quarterly on 1st of Jan/Apr/Jul/Oct at 2 AM** via cron

**Manual run:**
```bash
sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/quarterly-longhorn-maintenance.sh
```

### 3. `scripts/setup-longhorn-monitoring.sh`
Installation script that:
- Installs the metrics exporter
- Configures cron jobs for monitoring and maintenance
- Creates necessary directories
- Generates initial metrics

**Usage:**
```bash
sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/setup-longhorn-monitoring.sh
```

### 4. Prometheus Alerts
Pre-configured alerts for common issues:

**`prometheus-alerts/longhorn-disk-alerts.yaml`**
- `LonghornDiskImbalance` - Disk usage differs by >20% between disks
- `LonghornDiskHighUsage` - Disk >85% full
- `LonghornDiskCriticalUsage` - Disk >95% full (critical)
- `LonghornDiskExcessiveReservation` - Reserved space >15%
- `LonghornDiskNotSchedulable` - Disk not accepting replicas
- `LonghornReplicaImbalance` - Replica count differs by >10

**To apply alerts:**
```bash
kubectl apply -f ~/MyNodeOne/scripts/longhorn-maintenance/prometheus-alerts/longhorn-disk-alerts.yaml
```

## Automated Maintenance

### Quarterly Maintenance (Fully Automated)
The system runs **fully automated quarterly maintenance** every 3 months.

**Schedule:** 1st of January, April, July, October at 2 AM

**What it does automatically:**
1. ✅ Checks all disk reservations and fixes excessive ones
2. ✅ Analyzes replica distribution across disks
3. ✅ Automatically rebalances if imbalance >30%
4. ✅ Logs all actions to `/var/log/mynodeone/longhorn-maintenance-*.log`

**No manual intervention required!** The system maintains itself.

**View maintenance logs:**
```bash
ls -lh /var/log/mynodeone/longhorn-maintenance-*.log
tail -50 /var/log/mynodeone/longhorn-maintenance-*.log | tail -1
```

**Run maintenance manually (if needed):**
```bash
sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/quarterly-longhorn-maintenance.sh
```

## Manual Maintenance Scripts (Optional)

These scripts are available for manual use but are **NOT required** for normal operation.

### Fix Disk Reservation
```bash
sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/fix-longhorn-disk-reservation.sh
```

**When to use:**
- ✅ Automatically runs during installation and quarterly maintenance
- When adding new disks manually (between quarterly runs)
- For immediate fixes (don't want to wait for quarterly)

### Balance Replicas (Diagnostic Only)
```bash
~/MyNodeOne/scripts/longhorn-maintenance/scripts/balance-longhorn-replicas.sh
```

**What it does:**
- Reports replica count per disk
- Calculates imbalance ratio
- **Does NOT rebalance** (diagnostic only)

**When to use:**
- Investigating disk imbalance alerts
- Monthly health checks (optional)

### Auto-Balance Replicas (Advanced)
```bash
# Dry-run
sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/auto-balance-longhorn-replicas.sh

# Actually rebalance
DRY_RUN=0 sudo ~/MyNodeOne/scripts/longhorn-maintenance/scripts/auto-balance-longhorn-replicas.sh
```

**When to use:**
- ✅ Automatically runs quarterly if imbalance >30%
- For immediate rebalancing (don't want to wait for quarterly)
- After adding multiple new disks

**⚠️ Note:** Causes I/O load during rebalancing

## How It Works

**Natural Rebalancing (Primary Strategy):**
- ✅ New volumes automatically use least-utilized disks
- ✅ Cluster naturally balances over time
- ✅ No I/O impact

**Automated Quarterly Maintenance (Backup Strategy):**
- ✅ Fixes any disk reservation issues
- ✅ Rebalances if imbalance exceeds 30%
- ✅ Runs during low-traffic hours (2 AM)
- ✅ Fully automated - no user action needed

## Installation Integration

These scripts are **automatically run** during control plane installation:

1. `install_longhorn()` in `bootstrap-control-plane.sh` calls:
   - `longhorn-maintenance/scripts/fix-longhorn-disk-reservation.sh` - Optimizes reservations
   - `longhorn-maintenance/scripts/setup-longhorn-monitoring.sh` - Installs monitoring and cron jobs

2. Monitoring and automated maintenance start immediately after installation

## Where Scripts Run

**All scripts run ONLY on the control plane:**
- Longhorn is a cluster-wide system managed from the control plane
- Control plane has kubectl access to query all nodes
- Scripts use Longhorn API which manages all nodes automatically

**Worker nodes:** No scripts needed - Longhorn automatically manages them via the control plane

## Querying Metrics

### Prometheus Queries

**Check disk usage:**
```promql
longhorn_disk_usage_ratio
```

**Find imbalanced nodes:**
```promql
longhorn_node_disk_imbalance_ratio > 0.2
```

**Disk capacity by node:**
```promql
sum(longhorn_disk_capacity_bytes) by (node)
```

**Replica distribution:**
```promql
longhorn_disk_replica_count
```

### Grafana Dashboard

Create a dashboard with:
- Disk usage gauge per disk
- Imbalance ratio graph
- Replica count per disk
- Reserved space percentage

## Troubleshooting

### Metrics not appearing in Prometheus

1. Check if exporter is running:
   ```bash
   sudo crontab -l | grep longhorn-disk-exporter
   ```

2. Verify metrics file exists:
   ```bash
   cat /var/lib/node_exporter/textfile_collector/longhorn_disk_balance.prom
   ```

3. Check node-exporter is collecting textfile metrics:
   ```bash
   curl localhost:9100/metrics | grep longhorn_disk
   ```

### High disk imbalance

1. Check disk reservations:
   ```bash
   sudo ./fix-longhorn-disk-reservation.sh
   ```

2. Verify all disks are schedulable:
   ```bash
   kubectl get nodes.longhorn.io -n longhorn-system -o json | jq '.items[].spec.disks'
   ```

3. Check replica distribution:
   ```bash
   ./balance-longhorn-replicas.sh
   ```

### Disk not being used

**Possible causes:**
- Disk has high reservation → Run `fix-longhorn-disk-reservation.sh`
- Disk not schedulable → Check Longhorn UI
- Disk not added to Longhorn → Run `add-disk-to-longhorn.sh`

## Manual Operations

### Add new disk to monitoring
Monitoring automatically detects new disks added to Longhorn. No manual action needed.

### Disable monitoring
```bash
sudo crontab -e
# Comment out the longhorn-disk-exporter line
```

### Re-enable monitoring
```bash
sudo ./monitoring/setup-longhorn-monitoring.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Longhorn Cluster                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                 │
│  │ Disk sda │  │ Disk sdb │  │ Disk sdc │                 │
│  └──────────┘  └──────────┘  └──────────┘                 │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │  longhorn-disk-exporter.sh    │
        │  (runs every 5 min via cron)  │
        └───────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │  /var/lib/node_exporter/      │
        │  textfile_collector/          │
        │  longhorn_disk_balance.prom   │
        └───────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │    Prometheus Node Exporter   │
        │    (port 9100)                │
        └───────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │      Prometheus Server        │
        │      (scrapes metrics)        │
        └───────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │    Alertmanager + Grafana     │
        │    (alerts & visualization)   │
        └───────────────────────────────┘
```

## Best Practices

1. **Monitor imbalance ratio**: Keep it below 0.2 (20%)
2. **Fix reservations early**: Run fix script after adding disks
3. **Check alerts regularly**: Set up Slack/email notifications
4. **Plan capacity**: Alert when disks reach 85% usage
5. **Balance gradually**: Don't force-rebalance all volumes at once

## Support

For issues or questions:
1. Check logs: `journalctl -u node_exporter`
2. Verify Longhorn status: `kubectl get nodes.longhorn.io -n longhorn-system`
3. Run diagnostic: `./balance-longhorn-replicas.sh`
