#!/bin/bash

###############################################################################
# Set Longhorn's backup target and a daily backup job for its default group.
#
# Takes no action until you choose an off-machine target, because a target on the
# same machine does not protect against losing it. Set it in the environment or
# in /etc/mynodeone/backup.env:
#   LONGHORN_BACKUP_TARGET              s3://bucket@region/path/ or nfs://host:/path
#   LONGHORN_BACKUP_CREDENTIAL_SECRET   Secret in longhorn-system, needed for S3
#   LONGHORN_BACKUP_CRON                Default: 0 3 * * *
#   LONGHORN_BACKUP_RETAIN              Backups to keep. Default: 7
#
# Usage: sudo ./configure-longhorn-backups.sh
#
# It adds no recurring snapshot job: on a single-replica disk, snapshots keep
# deleted data and use up the same disk that holds the volume.
###############################################################################

set -euo pipefail

CONFIG_FILE="${BACKUP_CONFIG_FILE:-/etc/mynodeone/backup.env}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

LONGHORN_BACKUP_TARGET="${LONGHORN_BACKUP_TARGET:-}"
LONGHORN_BACKUP_CREDENTIAL_SECRET="${LONGHORN_BACKUP_CREDENTIAL_SECRET:-}"
LONGHORN_BACKUP_CRON="${LONGHORN_BACKUP_CRON:-0 3 * * *}"
LONGHORN_BACKUP_RETAIN="${LONGHORN_BACKUP_RETAIN:-7}"

if [ -z "$LONGHORN_BACKUP_TARGET" ]; then
    echo "LONGHORN_BACKUP_TARGET is not set, so nothing was changed."
    echo "Choose an off-machine target and set it in $CONFIG_FILE, then run this again."
    exit 0
fi

case "$LONGHORN_BACKUP_TARGET" in
    s3://*)
        if [ -z "$LONGHORN_BACKUP_CREDENTIAL_SECRET" ]; then
            echo "An S3 target needs LONGHORN_BACKUP_CREDENTIAL_SECRET (a Secret in longhorn-system)." >&2
            exit 1
        fi
        ;;
    nfs://*) ;;
    *)
        echo "LONGHORN_BACKUP_TARGET must start with s3:// or nfs://" >&2
        exit 1
        ;;
esac

kubectl -n longhorn-system patch settings.longhorn.io backup-target --type merge \
    -p "{\"value\":\"$LONGHORN_BACKUP_TARGET\"}"
kubectl -n longhorn-system patch settings.longhorn.io backup-target-credential-secret --type merge \
    -p "{\"value\":\"$LONGHORN_BACKUP_CREDENTIAL_SECRET\"}"

kubectl apply -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: mynodeone-daily-backup
  namespace: longhorn-system
spec:
  name: mynodeone-daily-backup
  task: backup
  cron: "$LONGHORN_BACKUP_CRON"
  groups:
    - default
  retain: $LONGHORN_BACKUP_RETAIN
  concurrency: 1
EOF

echo "Longhorn backups configured: $LONGHORN_BACKUP_TARGET ($LONGHORN_BACKUP_CRON, keep $LONGHORN_BACKUP_RETAIN)"
echo "Volumes with no recurring job of their own are in the default group, so this job covers them."
echo "Confirm a backup appears, then test restoring one before relying on it."
