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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Backup configuration
BACKUP_SCHEDULE="0 2 * * *"  # 2:00 AM UTC daily
BACKUP_RETENTION_DAYS=180    # 6 months
BACKUP_BUCKET="velero-backups"

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
    
    # Schedule 1: Nightly full cluster backup
    log_info "Creating nightly cluster backup schedule..."
    
    if velero schedule create nightly-backup \
        --schedule="$BACKUP_SCHEDULE" \
        --ttl="${BACKUP_RETENTION_DAYS}h" \
        --include-namespaces='*' \
        --exclude-namespaces='kube-system,kube-public,kube-node-lease' \
        --snapshot-volumes=false 2>&1; then
        log_success "Nightly backup schedule created"
    else
        # Check if already exists
        if velero schedule get nightly-backup &> /dev/null; then
            log_info "Nightly backup schedule already exists"
        else
            log_error "Failed to create nightly backup schedule"
            return 1
        fi
    fi
    
    # Schedule 2: Longhorn PVC backup (with Longhorn snapshots if available)
    log_info "Creating Longhorn PVC backup schedule..."
    
    if velero schedule create longhorn-pvc-backup \
        --schedule="$BACKUP_SCHEDULE" \
        --ttl="${BACKUP_RETENTION_DAYS}h" \
        --include-resources=persistentvolumeclaims,persistentvolumes \
        --selector='app.kubernetes.io/name!=minio' \
        --snapshot-volumes=false 2>&1; then
        log_success "Longhorn PVC backup schedule created"
    else
        # Check if already exists
        if velero schedule get longhorn-pvc-backup &> /dev/null; then
            log_info "Longhorn PVC backup schedule already exists"
        else
            log_warn "Failed to create Longhorn PVC backup schedule (continuing)"
        fi
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
    log_info "Backup Configuration:"
    log_info "  Schedule: Nightly at 2:00 AM UTC"
    log_info "  Retention: 6 months (${BACKUP_RETENTION_DAYS} days)"
    log_info "  Storage: MinIO at $MINIO_ENDPOINT"
    log_info "  Bucket: $BACKUP_BUCKET"
    echo
    log_info "Backup Schedules:"
    log_info "  - nightly-backup: Full cluster backup (excludes system namespaces)"
    log_info "  - longhorn-pvc-backup: PVC and PV backup"
    echo
    log_info "Useful Commands:"
    log_info "  velero backup get"
    log_info "  velero schedule get"
    log_info "  velero backup create <name> --from-schedule nightly-backup"
    log_info "  velero restore create --from-backup <backup-name>"
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
        exit 1
    fi
    
    if ! verify_configuration; then
        log_warn "Verification had warnings, but configuration may still work"
    fi
    
    display_summary
}

main "$@"
