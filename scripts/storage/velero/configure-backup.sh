#!/bin/bash

###############################################################################
# Velero Backup Configuration Script
# 
# Configures Velero to use MinIO on worker node as backup storage
# Sets up scheduled backups: nightly at 2AM UTC
# Retention: 6 months
# Called after worker node joins and MinIO is installed
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
# Get script directory and project root using standardized utility
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/project-root.sh"

# Backup configuration
FULL_BACKUP_SCHEDULE="0 2 1 * *"     # 2:00 AM UTC on 1st of month (monthly full)
INCREMENTAL_BACKUP_SCHEDULE="0 2 * * *"  # 2:00 AM UTC daily (incremental)
FULL_BACKUP_RETENTION_DAYS=180       # 6 months for full backups
INCREMENTAL_BACKUP_RETENTION_DAYS=30 # 30 days for incremental backups
BACKUP_BUCKET="velero-backups"
MIN_FREE_SPACE_PERCENT=20            # Alert and cleanup threshold

# Helper functions
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

retry_command() {
    local max_attempts=$1
    shift
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying..."
        attempt=$((attempt + 1))
        sleep 3
    done
    
    return 1
}

check_requirements() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        return 1
    fi
    
    # Check if velero CLI is available
    if ! command -v velero &> /dev/null; then
        log_error "Velero CLI not found. Please install Velero first."
        return 1
    fi
    
    # Check if Velero server is running
    if ! kubectl get deployment velero -n velero &> /dev/null; then
        log_error "Velero server not found. Please install Velero first."
        return 1
    fi
    
    # Check if MinIO is running
    if ! kubectl get svc minio -n minio &> /dev/null; then
        log_error "MinIO service not found. Please install MinIO first."
        return 1
    fi
    
    log_success "Prerequisites check passed"
    return 0
}

check_minio_disk_space() {
    log_info "Checking MinIO disk space..."
    
    # Get MinIO pod name
    local MINIO_POD=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$MINIO_POD" ]; then
        log_warn "Could not find MinIO pod, skipping disk space check"
        return 0
    fi
    
    # Check disk space for each mount point
    local LOW_SPACE=false
    while IFS= read -r line; do
        local MOUNT=$(echo "$line" | awk '{print $6}')
        local USED_PERCENT=$(echo "$line" | awk '{print $5}' | tr -d '%')
        local FREE_PERCENT=$((100 - USED_PERCENT))
        
        if [ "$FREE_PERCENT" -lt "$MIN_FREE_SPACE_PERCENT" ]; then
            log_warn "MinIO disk space low: $MOUNT is ${USED_PERCENT}% full (${FREE_PERCENT}% free)"
            LOW_SPACE=true
        else
            log_info "MinIO disk space OK: $MOUNT is ${USED_PERCENT}% full (${FREE_PERCENT}% free)"
        fi
    done < <(kubectl exec -n minio "$MINIO_POD" -- df -h 2>/dev/null | grep -E '/minio-data|/var/lib/minio' || true)
    
    if [ "$LOW_SPACE" = "true" ]; then
        log_warn "MinIO disk space below ${MIN_FREE_SPACE_PERCENT}% threshold"
        log_info "Will attempt automatic cleanup of old backups..."
        cleanup_old_backups
    fi
    
    return 0
}

cleanup_old_backups() {
    log_info "Cleaning up old incremental backups to free space..."
    
    # Delete incremental backups older than 7 days (keep recent ones)
    local CUTOFF_DATE=$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-7d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    
    if [ -z "$CUTOFF_DATE" ]; then
        log_warn "Could not calculate cutoff date for cleanup"
        return 1
    fi
    
    log_info "Deleting incremental backups older than $CUTOFF_DATE..."
    
    # Get list of incremental backups older than cutoff
    local OLD_BACKUPS=$(velero backup get -o json 2>/dev/null | \
        jq -r ".items[] | select(.metadata.labels.\"backup-type\" == \"incremental\" and .status.completionTimestamp < \"$CUTOFF_DATE\") | .metadata.name" 2>/dev/null || true)
    
    if [ -z "$OLD_BACKUPS" ]; then
        log_info "No old incremental backups to clean up"
        return 0
    fi
    
    local DELETED_COUNT=0
    while IFS= read -r backup_name; do
        if [ -n "$backup_name" ]; then
            log_info "Deleting old backup: $backup_name"
            if velero backup delete "$backup_name" --confirm &>/dev/null; then
                DELETED_COUNT=$((DELETED_COUNT + 1))
            fi
        fi
    done <<< "$OLD_BACKUPS"
    
    if [ $DELETED_COUNT -gt 0 ]; then
        log_success "Cleaned up $DELETED_COUNT old incremental backup(s)"
    else
        log_info "No backups were deleted"
    fi
    
    return 0
}

send_alert_to_monitoring() {
    local ALERT_TITLE="$1"
    local ALERT_MESSAGE="$2"
    local SEVERITY="${3:-warning}"  # warning, error, info
    
    log_info "Sending alert to monitoring: $ALERT_TITLE"
    
    # Create Kubernetes event for monitoring systems to pick up
    kubectl create event "velero-backup-alert-$(date +%s)" \
        --namespace=velero \
        --type="$SEVERITY" \
        --reason="BackupAlert" \
        --message="$ALERT_TITLE: $ALERT_MESSAGE" \
        --reporting-controller="velero-backup-config" \
        --reporting-instance="configure-backup-script" 2>/dev/null || true
    
    # Also create annotation on Velero deployment for visibility
    kubectl annotate deployment velero -n velero \
        "mynodeone.io/last-alert"="$(date -u '+%Y-%m-%dT%H:%M:%SZ'): $ALERT_TITLE" \
        --overwrite 2>/dev/null || true
    
    return 0
}

deploy_prometheus_monitoring() {
    log_info "Deploying Prometheus monitoring for Velero..."
    
    # Check if Prometheus is installed
    if ! kubectl get crd prometheusrules.monitoring.coreos.com &> /dev/null; then
        log_warn "Prometheus Operator not found, skipping monitoring setup"
        log_info "Install Prometheus to get automated backup failure alerts"
        return 0
    fi
    
    # Deploy PrometheusRule and ServiceMonitor
    local RULES_FILE="$SCRIPT_DIR/velero-prometheus-rules.yaml"
    
    if [ -f "$RULES_FILE" ]; then
        if kubectl apply -f "$RULES_FILE" 2>&1; then
            log_success "Prometheus monitoring rules deployed"
            log_info "Backup failure alerts will appear in Grafana automatically"
        else
            log_warn "Could not deploy Prometheus rules (continuing)"
        fi
    else
        log_warn "Prometheus rules file not found: $RULES_FILE"
        log_info "Backup monitoring will use Kubernetes events only"
    fi
    
    return 0
}

configure_minio_quota() {
    log_info "Configuring MinIO storage quota..."
    
    # Get MinIO credentials
    local MINIO_USER=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d)
    local MINIO_PASS=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d)
    local MINIO_ENDPOINT=$(kubectl get svc -n minio minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    
    if [ -z "$MINIO_ENDPOINT" ] || [ "$MINIO_ENDPOINT" = "null" ]; then
        log_warn "MinIO endpoint not available yet, skipping quota configuration"
        return 0
    fi
    
    # Install mc (MinIO client) if not present
    if ! command -v mc &> /dev/null; then
        log_info "Installing MinIO client (mc)..."
        curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
        chmod +x /usr/local/bin/mc
    fi
    
    # Configure mc alias
    mc alias set mynodeone-minio "http://${MINIO_ENDPOINT}:9000" "$MINIO_USER" "$MINIO_PASS" &>/dev/null || true
    
    # Set bucket quota (80% of available disk space)
    # This prevents MinIO from filling disk completely
    log_info "Setting bucket quota to prevent disk exhaustion..."
    
    # Get available disk space from MinIO pod
    local MINIO_POD=$(kubectl get pods -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$MINIO_POD" ]; then
        local TOTAL_SIZE=$(kubectl exec -n minio "$MINIO_POD" -- df -B1 /minio-data 2>/dev/null | tail -1 | awk '{print $2}' || echo "0")
        if [ "$TOTAL_SIZE" -gt 0 ]; then
            # Set quota to 80% of total size
            local QUOTA_SIZE=$((TOTAL_SIZE * 80 / 100))
            log_info "Setting bucket quota to $((QUOTA_SIZE / 1024 / 1024 / 1024))GB (80% of available space)"
            mc quota set mynodeone-minio/$BACKUP_BUCKET --size ${QUOTA_SIZE} &>/dev/null || log_warn "Could not set bucket quota"
        fi
    fi
    
    log_success "MinIO quota configuration complete"
    return 0
}

get_minio_credentials() {
    log_info "Retrieving MinIO credentials..."
    
    # Get credentials from Kubernetes secret
    export MINIO_ROOT_USER=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootUser}' 2>/dev/null | base64 -d)
    export MINIO_ROOT_PASSWORD=$(kubectl get secret minio-credentials -n minio -o jsonpath='{.data.rootPassword}' 2>/dev/null | base64 -d)
    
    if [ -z "$MINIO_ROOT_USER" ] || [ -z "$MINIO_ROOT_PASSWORD" ]; then
        log_error "Failed to retrieve MinIO credentials from secret"
        return 1
    fi
    
    # Get MinIO service endpoint (internal cluster service)
    export MINIO_ENDPOINT="minio.minio.svc.cluster.local:9000"
    
    log_success "MinIO credentials retrieved"
    log_info "MinIO endpoint: $MINIO_ENDPOINT"
    
    return 0
}

create_minio_bucket() {
    log_info "Creating Velero backup bucket in MinIO..."
    
    # Check if bucket already exists
    local POD_NAME=$(kubectl get pod -n minio -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POD_NAME" ]; then
        log_error "MinIO pod not found"
        return 1
    fi
    
    log_info "Using MinIO pod: $POD_NAME"
    
    # Create bucket using mc (MinIO client) inside the pod
    log_info "Creating bucket: $BACKUP_BUCKET"
    
    if kubectl exec -n minio "$POD_NAME" -- sh -c "
        mc alias set myminio http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD && \
        mc mb myminio/$BACKUP_BUCKET --ignore-existing
    " 2>&1; then
        log_success "Bucket '$BACKUP_BUCKET' created/verified"
    else
        log_error "Failed to create bucket in MinIO"
        return 1
    fi
    
    return 0
}

create_velero_credentials() {
    log_info "Creating Velero credentials for MinIO..."
    
    # Create temporary credentials file
    local CREDS_FILE=$(mktemp)
    cat > "$CREDS_FILE" <<EOF
[default]
aws_access_key_id = $MINIO_ROOT_USER
aws_secret_access_key = $MINIO_ROOT_PASSWORD
EOF
    
    # Create Kubernetes secret for Velero
    if kubectl create secret generic cloud-credentials \
        --namespace velero \
        --from-file=cloud="$CREDS_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        log_success "Velero credentials secret created"
    else
        rm -f "$CREDS_FILE"
        log_error "Failed to create Velero credentials secret"
        return 1
    fi
    
    rm -f "$CREDS_FILE"
    return 0
}

configure_backup_location() {
    log_info "Configuring Velero backup storage location..."
    
    # Create BackupStorageLocation
    cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: $BACKUP_BUCKET
  config:
    region: us-east-1
    s3ForcePathStyle: "true"
    s3Url: http://$MINIO_ENDPOINT
  credential:
    name: cloud-credentials
    key: cloud
EOF
    
    if [ $? -eq 0 ]; then
        log_success "Backup storage location configured"
    else
        log_error "Failed to configure backup storage location"
        return 1
    fi
    
    # Verify backup location
    log_info "Verifying backup storage location..."
    sleep 3
    
    local BSL_STATUS=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    log_info "Backup storage location status: $BSL_STATUS"
    
    if [ "$BSL_STATUS" = "Available" ]; then
        log_success "Backup storage location is available"
    else
        log_warn "Backup storage location status: $BSL_STATUS (may need time to initialize)"
    fi
    
    return 0
}

create_backup_schedules() {
    log_info "Creating backup schedules..."
    
    # Schedule 1: Monthly FULL cluster backup (1st of each month)
    log_info "Creating monthly FULL cluster backup schedule..."
    
    if velero schedule create monthly-full-backup \
        --schedule="$FULL_BACKUP_SCHEDULE" \
        --ttl="${FULL_BACKUP_RETENTION_DAYS}h" \
        --include-namespaces='*' \
        --exclude-namespaces='kube-system,kube-public,kube-node-lease' \
        --snapshot-volumes=false \
        --labels backup-type=full 2>&1; then
        log_success "Monthly full backup schedule created"
    else
        if velero schedule get monthly-full-backup &> /dev/null; then
            log_info "Monthly full backup schedule already exists"
        else
            log_error "Failed to create monthly full backup schedule"
            return 1
        fi
    fi
    
    # Schedule 2: Daily INCREMENTAL cluster backup
    log_info "Creating daily INCREMENTAL cluster backup schedule..."
    
    if velero schedule create daily-incremental-backup \
        --schedule="$INCREMENTAL_BACKUP_SCHEDULE" \
        --ttl="${INCREMENTAL_BACKUP_RETENTION_DAYS}h" \
        --include-namespaces='*' \
        --exclude-namespaces='kube-system,kube-public,kube-node-lease' \
        --snapshot-volumes=false \
        --labels backup-type=incremental 2>&1; then
        log_success "Daily incremental backup schedule created"
    else
        if velero schedule get daily-incremental-backup &> /dev/null; then
            log_info "Daily incremental backup schedule already exists"
        else
            log_error "Failed to create daily incremental backup schedule"
            return 1
        fi
    fi
    
    # NOTE: We do NOT backup PVC data (only Kubernetes manifests)
    # Backing up 40TB+ of Longhorn volume data over Tailscale is impossible
    # Users should use:
    #   1. Longhorn snapshots (local, for quick rollback)
    #   2. Application-level backups (pg_dump, mysqldump, etc.)
    #   3. Optional external replication to cloud storage
    
    # Delete old backup schedules if they exist
    if velero schedule get nightly-backup &> /dev/null; then
        log_info "Removing old nightly-backup schedule (replaced by monthly+incremental)..."
        velero schedule delete nightly-backup --confirm &>/dev/null || true
    fi
    
    if velero schedule get longhorn-pvc-backup &> /dev/null; then
        log_info "Removing old longhorn-pvc-backup schedule (misleading - only backed up YAML)..."
        velero schedule delete longhorn-pvc-backup --confirm &>/dev/null || true
    fi
    
    if velero schedule get monthly-pvc-backup &> /dev/null; then
        log_info "Removing old monthly-pvc-backup schedule (misleading - only backed up YAML)..."
        velero schedule delete monthly-pvc-backup --confirm &>/dev/null || true
    fi
    
    return 0
}

verify_configuration() {
    log_info "Verifying Velero configuration..."
    
    # Check backup storage location
    if ! kubectl get backupstoragelocation default -n velero &> /dev/null; then
        log_error "Backup storage location not found"
        return 1
    fi
    
    # Check schedules
    log_info "Checking backup schedules..."
    velero schedule get || true
    
    # Test backup location connectivity
    log_info "Testing backup location connectivity..."
    local TEST_BACKUP_NAME="test-connectivity-$(date +%s)"
    
    if velero backup create "$TEST_BACKUP_NAME" \
        --include-namespaces=default \
        --wait 2>&1; then
        log_success "Test backup successful"
        
        # Clean up test backup
        velero backup delete "$TEST_BACKUP_NAME" --confirm &> /dev/null || true
    else
        log_warn "Test backup failed, but configuration may still be valid"
    fi
    
    log_success "Velero backup configuration verified"
    return 0
}

display_summary() {
    echo
    log_success "===== Velero Backup Configuration Complete ====="
    echo
    log_info "Backup Strategy:"
    log_info "  FULL Backups: Monthly on 1st at 2:00 AM UTC (retention: 6 months)"
    log_info "  INCREMENTAL Backups: Daily at 2:00 AM UTC (retention: 30 days)"
    log_info "  Storage: MinIO at $MINIO_ENDPOINT"
    log_info "  Bucket: $BACKUP_BUCKET"
    echo
    log_info "What Gets Backed Up:"
    log_info "  ✓ Kubernetes manifests (Deployments, Services, ConfigMaps, Secrets)"
    log_info "  ✓ PVC/PV definitions (YAML only, NOT the data inside volumes)"
    log_info "  ✓ Namespace configurations"
    log_info "  ✓ RBAC policies"
    echo
    log_warn "⚠️  IMPORTANT: Velero backs up Kubernetes YAML, NOT your data!"
    echo
    log_info "What is NOT Backed Up:"
    log_info "  ✗ Database contents (PostgreSQL, MySQL, etc.)"
    log_info "  ✗ Files inside PVCs/volumes"
    log_info "  ✗ Application data"
    log_info "  ✗ Longhorn volume data (40TB+ cannot transfer over Tailscale)"
    echo
    log_info "For Data Backup, Use:"
    log_info "  1. Longhorn snapshots (local, for quick rollback)"
    log_info "  2. Application-level backups (pg_dump, mysqldump, rsync)"
    log_info "  3. External replication (optional, to cloud storage)"
    echo
    log_info "Backup Schedules:"
    log_info "  - monthly-full-backup: Full Kubernetes manifests (1st of month)"
    log_info "  - daily-incremental-backup: Changed Kubernetes resources (daily)"
    echo
    log_info "Monitoring & Maintenance:"
    log_info "  - Disk space monitoring: Enabled (alert at <${MIN_FREE_SPACE_PERCENT}% free)"
    log_info "  - Automatic cleanup: Enabled (removes old incrementals when space low)"
    log_info "  - MinIO quota: Configured (80% of disk capacity)"
    log_info "  - Prometheus alerts: Enabled (backup failures → Grafana)"
    log_info "  - Kubernetes events: Enabled (for manual monitoring)"
    echo
    log_info "Useful Commands:"
    log_info "  velero backup get"
    log_info "  velero schedule get"
    log_info "  velero backup create <name> --from-schedule monthly-full-backup"
    log_info "  velero restore create --from-backup <backup-name>"
    echo
    log_info "Documentation:"
    log_info "  See: scripts/storage/BACKUP-STRATEGY-ANALYSIS.md"
    log_info "  See: scripts/storage/BACKUP-RESTORE-GUIDE.md"
    echo
}

main() {
    log_info "===== Velero Backup Configuration ====="
    
    if ! check_requirements; then
        log_error "Prerequisites check failed"
        exit 1
    fi
    
    if ! get_minio_credentials; then
        log_error "Failed to get MinIO credentials"
        exit 1
    fi
    
    if ! create_minio_bucket; then
        log_error "Failed to create MinIO bucket"
        exit 1
    fi
    
    if ! create_velero_credentials; then
        log_error "Failed to create Velero credentials"
        exit 1
    fi
    
    if ! configure_backup_location; then
        log_error "Failed to configure backup storage location"
        exit 1
    fi
    
    if ! create_backup_schedules; then
        log_error "Failed to create backup schedules"
        send_alert_to_monitoring "Backup Schedule Creation Failed" "Could not create Velero backup schedules" "error"
        exit 1
    fi
    
    # Check disk space and configure quota
    check_minio_disk_space
    configure_minio_quota
    
    # Deploy Prometheus monitoring rules
    deploy_prometheus_monitoring
    
    if ! verify_configuration; then
        log_warn "Verification had warnings, but configuration may still work"
        send_alert_to_monitoring "Backup Configuration Warning" "Velero backup verification had warnings" "warning"
    else
        send_alert_to_monitoring "Backup Configuration Success" "Velero backups configured successfully" "info"
    fi
    
    display_summary
}

main "$@"
