#!/bin/bash

###############################################################################
# Velero Backup Configuration Script
#
# Points Velero at a backup destination you choose and creates its schedules.
# No installer calls this script, and there's no default destination: it stops
# with an explanation if none is configured. See backup.env.example.
#
# USAGE:
#   sudo ./scripts/storage/velero/configure-backup.sh --config /path/to/backup.env
#
# WHAT THESE BACKUPS COVER:
#   Kubernetes objects only, including Secrets in readable form, so the
#   destination has to be trusted and access-controlled. Volume data isn't covered.
#
# WHY --snapshot-volumes STAYS FALSE:
#   install.sh runs with --use-volume-snapshots=false and sets up no snapshot
#   location or CSI snapshot class, so turning it on here would back up no extra
#   data. Snapshots of Longhorn volumes would also stay in Longhorn unless it has
#   its own backup target. Volume data needs a method that fits it instead:
#   pg_dump for Postgres (scripts/backup/llmapi-postgres-backup.yaml), and Longhorn
#   recurring backups once a target is chosen. VELERO_SNAPSHOT_VOLUMES=true is there
#   for clusters that have added a CSI snapshot setup.
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_KEYS=(
    VELERO_BACKUP_TARGET
    VELERO_S3_URL
    VELERO_BUCKET
    VELERO_REGION
    VELERO_PREFIX
    VELERO_CREDENTIALS_FILE
    VELERO_MINIO_NODE
    VELERO_FULL_SCHEDULE
    VELERO_DAILY_SCHEDULE
    VELERO_FULL_RETENTION_DAYS
    VELERO_DAILY_RETENTION_DAYS
    VELERO_SNAPSHOT_VOLUMES
)

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Reads KEY=value lines. The file is parsed rather than sourced, because this
# script runs as root and a config file shouldn't be able to run commands.
load_config_file() {
    local file="$1" line key value known_key known
    if [[ ! -r "$file" ]]; then
        log_error "Can't read config file: $file"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
            log_error "Invalid line in $file: $line"
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        known=false
        for known_key in "${CONFIG_KEYS[@]}"; do
            [[ "$key" == "$known_key" ]] && known=true
        done
        if [[ "$known" == false ]]; then
            log_error "Unknown setting in $file: $key"
            return 1
        fi
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        # The environment takes precedence over the file
        if [[ -z "${!key:-}" ]]; then
            printf -v "$key" '%s' "$value"
        fi
    done < "$file"
}

fail_no_destination() {
    log_error "No backup destination is configured, so nothing was changed."
    log_error "$1"
    log_error "Set VELERO_BACKUP_TARGET and the settings it needs. See $SCRIPT_DIR/backup.env.example"
    return 1
}

# Checks settings and applies defaults. Runs before anything touches the cluster.
validate_config() {
    VELERO_BACKUP_TARGET="${VELERO_BACKUP_TARGET:-}"
    VELERO_BUCKET="${VELERO_BUCKET:-}"
    VELERO_PREFIX="${VELERO_PREFIX:-}"
    VELERO_CREDENTIALS_FILE="${VELERO_CREDENTIALS_FILE:-}"
    VELERO_MINIO_NODE="${VELERO_MINIO_NODE:-}"
    VELERO_S3_URL="${VELERO_S3_URL:-}"
    VELERO_REGION="${VELERO_REGION:-}"
    VELERO_FULL_SCHEDULE="${VELERO_FULL_SCHEDULE:-0 2 1 * *}"
    VELERO_DAILY_SCHEDULE="${VELERO_DAILY_SCHEDULE:-0 2 * * *}"
    VELERO_FULL_RETENTION_DAYS="${VELERO_FULL_RETENTION_DAYS:-180}"
    VELERO_DAILY_RETENTION_DAYS="${VELERO_DAILY_RETENTION_DAYS:-30}"
    VELERO_SNAPSHOT_VOLUMES="${VELERO_SNAPSHOT_VOLUMES:-false}"

    case "$VELERO_BACKUP_TARGET" in
        s3)
            [[ -n "$VELERO_S3_URL" ]] || { fail_no_destination "VELERO_BACKUP_TARGET=s3 needs VELERO_S3_URL."; return 1; }
            [[ -n "$VELERO_BUCKET" ]] || { fail_no_destination "VELERO_BACKUP_TARGET=s3 needs VELERO_BUCKET."; return 1; }
            [[ -n "$VELERO_REGION" ]] || { fail_no_destination "VELERO_BACKUP_TARGET=s3 needs VELERO_REGION."; return 1; }
            [[ -n "$VELERO_CREDENTIALS_FILE" ]] || { fail_no_destination "VELERO_BACKUP_TARGET=s3 needs VELERO_CREDENTIALS_FILE."; return 1; }
            if ! [[ "$VELERO_S3_URL" =~ ^https?://[A-Za-z0-9._:-]+(/[A-Za-z0-9._/-]*)?$ ]]; then
                log_error "VELERO_S3_URL is not a valid URL: $VELERO_S3_URL"
                return 1
            fi
            ;;
        minio)
            [[ -n "$VELERO_BUCKET" ]] || { fail_no_destination "VELERO_BACKUP_TARGET=minio needs VELERO_BUCKET."; return 1; }
            VELERO_REGION="${VELERO_REGION:-us-east-1}"
            if [[ -n "$VELERO_MINIO_NODE" ]] && ! [[ "$VELERO_MINIO_NODE" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
                log_error "VELERO_MINIO_NODE is not a valid node name: $VELERO_MINIO_NODE"
                return 1
            fi
            ;;
        "")
            fail_no_destination "VELERO_BACKUP_TARGET is not set."
            return 1
            ;;
        *)
            log_error "VELERO_BACKUP_TARGET must be 's3' or 'minio', not '$VELERO_BACKUP_TARGET'."
            return 1
            ;;
    esac

    if ! [[ "$VELERO_BUCKET" =~ ^[a-z0-9][a-z0-9.-]+$ ]]; then
        log_error "VELERO_BUCKET is not a valid bucket name: $VELERO_BUCKET"
        return 1
    fi
    if [[ -n "$VELERO_PREFIX" ]] && ! [[ "$VELERO_PREFIX" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        log_error "VELERO_PREFIX contains invalid characters: $VELERO_PREFIX"
        return 1
    fi
    if ! [[ "$VELERO_REGION" =~ ^[A-Za-z0-9-]+$ ]]; then
        log_error "VELERO_REGION is not valid: $VELERO_REGION"
        return 1
    fi
    if [[ -n "$VELERO_CREDENTIALS_FILE" && ! -r "$VELERO_CREDENTIALS_FILE" ]]; then
        log_error "Can't read VELERO_CREDENTIALS_FILE: $VELERO_CREDENTIALS_FILE"
        return 1
    fi
    case "$VELERO_SNAPSHOT_VOLUMES" in
        true|false) ;;
        *)
            log_error "VELERO_SNAPSHOT_VOLUMES must be true or false."
            return 1
            ;;
    esac
    retention_days_to_ttl "$VELERO_FULL_RETENTION_DAYS" > /dev/null || return 1
    retention_days_to_ttl "$VELERO_DAILY_RETENTION_DAYS" > /dev/null || return 1
}

# Velero's --ttl is a Go duration with no day unit, so 180 days is 4320h.
retention_days_to_ttl() {
    local days="$1"
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        log_error "Retention must be a whole number of days, not '$days'."
        return 1
    fi
    echo "$((days * 24))h0m0s"
}

check_requirements() {
    log_info "Checking prerequisites..."

    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        return 1
    fi

    if ! command -v velero &> /dev/null; then
        log_error "Velero CLI not found. Run $SCRIPT_DIR/install.sh first."
        return 1
    fi

    if ! kubectl get deployment velero -n velero &> /dev/null; then
        log_error "Velero server not found. Run $SCRIPT_DIR/install.sh first."
        return 1
    fi

    log_success "Prerequisites check passed"
}

# install-minio.sh creates one namespace per node, labelled app=minio.
# Sets MINIO_NAMESPACE.
resolve_minio_namespace() {
    if [[ -n "$VELERO_MINIO_NODE" ]]; then
        MINIO_NAMESPACE="minio-$VELERO_MINIO_NODE"
        return 0
    fi

    local found=""
    if ! found=$(kubectl get namespaces -l app=minio -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); then
        log_error "Could not list MinIO namespaces."
        return 1
    fi
    found=$(printf '%s\n' "$found" | grep -E '^minio-' || true)

    local count=0
    if [[ -n "$found" ]]; then
        count=$(printf '%s\n' "$found" | wc -l)
    fi
    if (( count == 0 )); then
        log_error "No MinIO instance found (no namespace named minio-<node>). Install MinIO or set VELERO_BACKUP_TARGET=s3."
        return 1
    fi
    if (( count > 1 )); then
        log_error "Found $count MinIO instances. Set VELERO_MINIO_NODE to choose one:"
        printf '%s\n' "$found" | sed 's/^minio-/  /' >&2
        return 1
    fi
    MINIO_NAMESPACE="$found"
}

# Sets VELERO_S3_URL to the in-cluster address of the chosen instance, after making
# sure it's running. A pod stuck in ImagePullBackOff can't hold backups.
check_minio_target() {
    resolve_minio_namespace || return 1

    if ! kubectl get svc minio -n "$MINIO_NAMESPACE" &> /dev/null; then
        log_error "MinIO service not found in namespace $MINIO_NAMESPACE."
        return 1
    fi
    local ready=""
    ready=$(kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
    if [[ "$ready" != "true" ]]; then
        log_error "MinIO in namespace $MINIO_NAMESPACE is not running. Check: kubectl get pods -n $MINIO_NAMESPACE"
        return 1
    fi

    VELERO_S3_URL="http://minio.${MINIO_NAMESPACE}.svc.cluster.local:9000"
    log_warn "The backup destination is MinIO inside this cluster ($MINIO_NAMESPACE)."
    log_warn "This does not protect against losing the machine it runs on."
}

create_velero_credentials() {
    log_info "Creating Velero credentials..."

    local secret_source="$VELERO_CREDENTIALS_FILE" temp_file=""
    if [[ -z "$secret_source" ]]; then
        # Only reachable for target=minio: target=s3 requires a credentials file
        log_warn "Using MinIO's root credentials. A dedicated user with access to one bucket is safer."
        local minio_user="" minio_password=""
        minio_user=$(kubectl get secret minio-credentials -n "$MINIO_NAMESPACE" -o jsonpath='{.data.rootUser}' | base64 -d)
        minio_password=$(kubectl get secret minio-credentials -n "$MINIO_NAMESPACE" -o jsonpath='{.data.rootPassword}' | base64 -d)
        if [[ -z "$minio_user" || -z "$minio_password" ]]; then
            log_error "Could not read MinIO credentials from namespace $MINIO_NAMESPACE."
            return 1
        fi
        temp_file=$(mktemp)     # mktemp creates the file with mode 600
        cat > "$temp_file" <<EOF
[default]
aws_access_key_id = $minio_user
aws_secret_access_key = $minio_password
EOF
        secret_source="$temp_file"
    fi

    local rc=0
    kubectl create secret generic cloud-credentials \
        --namespace velero \
        --from-file=cloud="$secret_source" \
        --dry-run=client -o yaml | kubectl apply -f - || rc=$?

    if [[ -n "$temp_file" ]]; then
        rm -f "$temp_file"
    fi

    if (( rc != 0 )); then
        log_error "Failed to create Velero credentials secret"
        return 1
    fi
    log_success "Velero credentials secret created"
}

configure_backup_location() {
    log_info "Configuring Velero backup storage location..."

    local prefix_line=""
    if [[ -n "$VELERO_PREFIX" ]]; then
        prefix_line="    prefix: $VELERO_PREFIX"
    fi

    if ! kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws
  default: true
  objectStorage:
    bucket: $VELERO_BUCKET
$prefix_line
  config:
    region: $VELERO_REGION
    s3ForcePathStyle: "true"
    s3Url: $VELERO_S3_URL
  credential:
    name: cloud-credentials
    key: cloud
EOF
    then
        log_error "Failed to configure backup storage location"
        return 1
    fi

    # Velero validates the location on a timer, so give it time to report
    log_info "Waiting for Velero to validate the backup storage location..."
    local status="Unknown"
    for _ in {1..24}; do
        status=$(kubectl get backupstoragelocation default -n velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$status" == "Available" ]]; then
            log_success "Backup storage location is available"
            return 0
        fi
        sleep 5
    done

    log_error "Backup storage location is '$status', not Available."
    log_error "Check that bucket '$VELERO_BUCKET' exists at $VELERO_S3_URL and the credentials can reach it."
    log_error "Details: kubectl describe backupstoragelocation default -n velero"
    return 1
}

# Creates a schedule. An existing one keeps running, but its retention is corrected
# so a schedule made with the old days-as-hours bug doesn't keep expiring backups.
ensure_schedule() {
    local name="$1" cron="$2" ttl="$3" backup_type="$4" current=""

    if velero schedule get "$name" &> /dev/null; then
        current=$(kubectl get schedule "$name" -n velero -o jsonpath='{.spec.template.ttl}' 2>/dev/null || true)
        if [[ "$current" != "$ttl" ]]; then
            log_warn "Schedule $name has retention '$current'. Changing it to $ttl."
            if ! kubectl patch schedule "$name" -n velero --type merge \
                -p "{\"spec\":{\"template\":{\"ttl\":\"$ttl\"}}}"; then
                log_error "Could not change the retention of schedule $name."
                return 1
            fi
        fi
        log_info "Schedule $name already exists"
        return 0
    fi

    if ! velero schedule create "$name" \
        --schedule="$cron" \
        --ttl="$ttl" \
        --include-namespaces='*' \
        --exclude-namespaces='kube-system,kube-public,kube-node-lease' \
        --snapshot-volumes="$VELERO_SNAPSHOT_VOLUMES" \
        --labels "backup-type=$backup_type"; then
        log_error "Could not create schedule $name."
        return 1
    fi
    log_success "Schedule $name created (retention $ttl)"
}

create_backup_schedules() {
    log_info "Creating backup schedules..."

    if [[ "$VELERO_SNAPSHOT_VOLUMES" == "true" ]]; then
        log_warn "VELERO_SNAPSHOT_VOLUMES=true needs a working CSI snapshot setup. See the top of this script."
    fi

    local full_ttl daily_ttl
    full_ttl=$(retention_days_to_ttl "$VELERO_FULL_RETENTION_DAYS")
    daily_ttl=$(retention_days_to_ttl "$VELERO_DAILY_RETENTION_DAYS")

    ensure_schedule monthly-full-backup "$VELERO_FULL_SCHEDULE" "$full_ttl" full || return 1
    ensure_schedule daily-incremental-backup "$VELERO_DAILY_SCHEDULE" "$daily_ttl" incremental || return 1

    # Remove schedules from older versions of this script
    local old_schedule
    for old_schedule in nightly-backup longhorn-pvc-backup monthly-pvc-backup; do
        if velero schedule get "$old_schedule" &> /dev/null; then
            log_info "Removing old schedule: $old_schedule"
            velero schedule delete "$old_schedule" --confirm || log_warn "Could not remove schedule $old_schedule"
        fi
    done
}

deploy_prometheus_monitoring() {
    log_info "Deploying Prometheus monitoring for Velero..."

    if ! kubectl get crd prometheusrules.monitoring.coreos.com &> /dev/null; then
        log_warn "Prometheus Operator not found, skipping monitoring setup"
        return 0
    fi

    if ! kubectl apply -f "$SCRIPT_DIR/velero-prometheus-rules.yaml"; then
        log_warn "Could not deploy Prometheus rules (continuing)"
    fi
}

# Takes a real backup, since a schedule can look fine while every run fails.
verify_configuration() {
    log_info "Testing with a backup of the default namespace..."
    local test_backup phase=""
    test_backup="test-connectivity-$(date +%s)"

    if ! velero backup create "$test_backup" --include-namespaces=default --wait; then
        log_error "Test backup could not be created"
        return 1
    fi
    phase=$(kubectl get backup "$test_backup" -n velero -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" != "Completed" ]]; then
        log_error "Test backup finished as '$phase', not Completed. Details: velero backup describe $test_backup"
        return 1
    fi

    velero backup delete "$test_backup" --confirm > /dev/null || log_warn "Could not delete test backup $test_backup"
    log_success "Test backup completed"
}

display_summary() {
    echo
    log_success "===== Velero Backup Configuration Complete ====="
    echo
    log_info "Destination: $VELERO_S3_URL, bucket $VELERO_BUCKET"
    log_info "Monthly full: $VELERO_FULL_SCHEDULE, kept $VELERO_FULL_RETENTION_DAYS days"
    log_info "Daily:        $VELERO_DAILY_SCHEDULE, kept $VELERO_DAILY_RETENTION_DAYS days"
    echo
    log_warn "These backups hold Kubernetes objects, including Secrets, and not volume data."
    log_info "Not covered: databases, files in PVCs, Longhorn volume data, etcd snapshots."
    log_info "Postgres dumps: scripts/backup/llmapi-postgres-backup.yaml"
    echo
    log_info "Useful commands:"
    log_info "  velero backup get"
    log_info "  velero schedule get"
    log_info "  velero restore create --from-backup <backup-name>"
    echo
}

main() {
    local config_file="${VELERO_BACKUP_CONFIG:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                if [[ $# -lt 2 ]]; then
                    log_error "--config needs a file path"
                    exit 2
                fi
                config_file="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                exit 2
                ;;
        esac
    done

    log_info "===== Velero Backup Configuration ====="

    if [[ -n "$config_file" ]]; then
        load_config_file "$config_file" || exit 1
    fi
    validate_config || exit 1
    check_requirements || exit 1

    if [[ "$VELERO_BACKUP_TARGET" == "minio" ]]; then
        check_minio_target || exit 1
    fi

    create_velero_credentials || exit 1
    configure_backup_location || exit 1
    create_backup_schedules || exit 1
    deploy_prometheus_monitoring
    verify_configuration || exit 1

    display_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
