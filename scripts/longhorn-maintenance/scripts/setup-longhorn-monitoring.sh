#!/bin/bash

###############################################################################
# Setup Longhorn Disk Monitoring
# 
# Installs cron job and systemd service for Longhorn disk monitoring
# Integrates with Prometheus node-exporter
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Setup Longhorn Disk Monitoring${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORTER_SCRIPT="$SCRIPT_DIR/longhorn-disk-exporter.sh"

if [ ! -f "$EXPORTER_SCRIPT" ]; then
    log_error "Exporter script not found: $EXPORTER_SCRIPT"
    exit 1
fi

# Make exporter executable
chmod +x "$EXPORTER_SCRIPT"
log_success "Exporter script ready: $EXPORTER_SCRIPT"

# Create node-exporter textfile directory
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
mkdir -p "$TEXTFILE_DIR"
log_success "Created metrics directory: $TEXTFILE_DIR"

# Install cron job for periodic metrics collection
log_info "Installing cron jobs for monitoring and maintenance..."

# Run daily at 3 AM (low system load time)
METRICS_CRON="0 3 * * * $EXPORTER_SCRIPT > /dev/null 2>&1"

# Run quarterly maintenance on 1st of Jan/Apr/Jul/Oct at 2 AM
MAINTENANCE_SCRIPT="$SCRIPT_DIR/quarterly-longhorn-maintenance.sh"
QUARTERLY_CRON="0 2 1 1,4,7,10 * $MAINTENANCE_SCRIPT"

# Remove old cron jobs
crontab -l 2>/dev/null | grep -v "longhorn-disk-exporter.sh" | grep -v "quarterly-longhorn-maintenance.sh" | crontab - 2>/dev/null || true

# Add new cron jobs
(crontab -l 2>/dev/null; echo "$METRICS_CRON"; echo "$QUARTERLY_CRON") | crontab -

log_success "Cron jobs installed:"
log_info "  • Metrics export: Daily at 3 AM"
log_info "  • Quarterly maintenance: 1st of Jan/Apr/Jul/Oct at 2 AM"

# Run exporter once to generate initial metrics
log_info "Generating initial metrics..."
if "$EXPORTER_SCRIPT"; then
    log_success "Initial metrics generated"
    
    # Show sample metrics
    if [ -f "$TEXTFILE_DIR/longhorn_disk_balance.prom" ]; then
        echo
        log_info "Sample metrics:"
        head -20 "$TEXTFILE_DIR/longhorn_disk_balance.prom" | grep -v "^#" | head -5
        echo "  ..."
    fi
else
    log_warn "Failed to generate initial metrics (Longhorn may not be ready yet)"
fi

echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_success "Longhorn disk monitoring configured"
echo
log_info "Metrics are exported to: $TEXTFILE_DIR/longhorn_disk_balance.prom"
log_info "Prometheus node-exporter will automatically collect these metrics"
echo
log_info "Available metrics:"
log_info "  • longhorn_disk_capacity_bytes - Total disk capacity"
log_info "  • longhorn_disk_scheduled_bytes - Scheduled storage"
log_info "  • longhorn_disk_reserved_bytes - Reserved storage"
log_info "  • longhorn_disk_usage_ratio - Usage ratio (0.0-1.0)"
log_info "  • longhorn_disk_replica_count - Number of replicas"
log_info "  • longhorn_node_disk_imbalance_ratio - Disk imbalance (0.0=balanced)"
echo
log_info "Automated schedules:"
log_info "  • Metrics export: Daily at 3 AM"
log_info "  • Quarterly maintenance: 1st of Jan/Apr/Jul/Oct at 2 AM"
log_info "    (Fixes disk reservations + rebalances if needed)"
echo
log_info "Maintenance logs: /var/log/mynodeone/longhorn-maintenance-*.log"
echo
log_info "To view metrics in Prometheus:"
log_info "  Query: longhorn_disk_usage_ratio"
log_info "  Alert on: longhorn_node_disk_imbalance_ratio > 0.2"
echo
log_info "Manual maintenance scripts (optional):"
log_info "  • ~/MyNodeOne/scripts/longhorn-maintenance/scripts/fix-longhorn-disk-reservation.sh"
log_info "  • ~/MyNodeOne/scripts/longhorn-maintenance/scripts/balance-longhorn-replicas.sh"
log_info "  • ~/MyNodeOne/scripts/longhorn-maintenance/scripts/quarterly-longhorn-maintenance.sh"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
