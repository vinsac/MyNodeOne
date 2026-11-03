#!/bin/bash

###############################################################################
# Back up the control plane state that a cluster cannot be rebuilt without:
#   - the secrets encryption key (without it, a restored etcd cannot be read)
#   - the k3s server and agent tokens
#   - the newest etcd snapshots
#
# Backups go to a root-only local directory. Local copies do not survive losing
# the machine, so set BACKUP_REMOTE to also copy them somewhere else.
#
# Usage:
#   sudo backup-control-plane-state.sh              Run one backup
#   sudo backup-control-plane-state.sh --install    Install a daily systemd timer
#   sudo backup-control-plane-state.sh --uninstall  Remove the timer
#
# Optional settings, from the environment or /etc/mynodeone/backup.env:
#   BACKUP_DIR                     Local directory (default /var/backups/mynodeone)
#   BACKUP_KEEP                    Local archives to keep (default 14)
#   BACKUP_SNAPSHOTS               Etcd snapshots per archive (default 2)
#   BACKUP_REMOTE                  rsync target such as user@host:/path
#   BACKUP_GPG_RECIPIENT           Encrypt remote copies to this GPG key
#   BACKUP_ALLOW_PLAINTEXT_REMOTE  Set to 1 to send remote copies unencrypted
#   BACKUP_MAX_SNAPSHOT_AGE_HOURS  Newest etcd snapshot must be younger (default 24)
#   BACKUP_SNAPSHOT_GRACE_HOURS    How long a new cluster may have no snapshots (default 24)
#
# A run only counts as a success, and updates the metric the alerts read, if the archive
# could restore the cluster: the server token and a recent etcd snapshot are in it. If
# not, this exits non-zero and keeps what it could under an incomplete-* name. Those stay
# on this machine and don't count towards BACKUP_KEEP, so a failing run can't rotate
# good archives away. A new cluster has no snapshots until the first 6-hourly run, so
# during the grace period this writes an archive and exits 0 without updating the metric.
#
# An archive holds the encryption key next to the data it protects. Anyone who
# gets a plaintext archive can read every Secret, so remote copies must be
# encrypted unless BACKUP_ALLOW_PLAINTEXT_REMOTE=1 says otherwise.
###############################################################################

set -euo pipefail

CONFIG_FILE="${BACKUP_CONFIG_FILE:-/etc/mynodeone/backup.env}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/mynodeone}"
BACKUP_KEEP="${BACKUP_KEEP:-14}"
BACKUP_SNAPSHOTS="${BACKUP_SNAPSHOTS:-2}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}"
BACKUP_GPG_RECIPIENT="${BACKUP_GPG_RECIPIENT:-}"
BACKUP_ALLOW_PLAINTEXT_REMOTE="${BACKUP_ALLOW_PLAINTEXT_REMOTE:-0}"
BACKUP_MAX_SNAPSHOT_AGE_HOURS="${BACKUP_MAX_SNAPSHOT_AGE_HOURS:-24}"
BACKUP_SNAPSHOT_GRACE_HOURS="${BACKUP_SNAPSHOT_GRACE_HOURS:-24}"
BACKUP_KEEP_INCOMPLETE=3
K3S_CONFIG_DIR="${K3S_CONFIG_DIR:-/etc/rancher/k3s}"
K3S_DATA_DIR="${K3S_DATA_DIR:-/var/lib/rancher/k3s}"
METRICS_DIR="${METRICS_DIR:-/var/lib/mynodeone/metrics}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/mynodeone-state-backup}"
UNIT_NAME="mynodeone-state-backup"

log() { echo "[backup] $1"; }
fail() { echo "[backup] ERROR: $1" >&2; exit 1; }

write_metrics() {
    local timestamp="$1"
    local remote_enabled="$2"
    local tmp

    mkdir -p "$METRICS_DIR"
    chmod 755 "$METRICS_DIR"
    tmp=$(mktemp "$METRICS_DIR/.control-plane-backup.XXXXXX")
    cat > "$tmp" <<EOF
# HELP mynodeone_backup_last_success_timestamp_seconds Time of the last successful backup.
# TYPE mynodeone_backup_last_success_timestamp_seconds gauge
mynodeone_backup_last_success_timestamp_seconds{backup="control-plane-state"} $timestamp
# HELP mynodeone_backup_remote_copy_enabled Whether backups are also copied off this machine.
# TYPE mynodeone_backup_remote_copy_enabled gauge
mynodeone_backup_remote_copy_enabled{backup="control-plane-state"} $remote_enabled
EOF
    chmod 644 "$tmp"
    mv -f "$tmp" "$METRICS_DIR/control-plane-backup.prom"
}

copy_to_remote() {
    local archive="$1"
    local to_send="$archive"
    local encrypted=""

    if [ -n "$BACKUP_GPG_RECIPIENT" ]; then
        encrypted="$archive.gpg"
        gpg --batch --yes --trust-model always --recipient "$BACKUP_GPG_RECIPIENT" \
            --output "$encrypted" --encrypt "$archive"
        chmod 600 "$encrypted"
        to_send="$encrypted"
    elif [ "$BACKUP_ALLOW_PLAINTEXT_REMOTE" != "1" ]; then
        fail "BACKUP_REMOTE is set, but BACKUP_GPG_RECIPIENT is not. Set one, or set BACKUP_ALLOW_PLAINTEXT_REMOTE=1. The local archive was kept: $archive"
    fi

    rsync -a --chmod=F600 "$to_send" "$BACKUP_REMOTE/"
    log "Copied $(basename "$to_send") to $BACKUP_REMOTE"

    if [ -n "$encrypted" ]; then
        rm -f "$encrypted"
    fi
}

run_backup() {
    local work archive stamp file snapshot_dir newest_epoch="" now age_hours
    local grace=0 prefix="control-plane-state"
    local -a snapshots=() problems=()

    for file in "$BACKUP_MAX_SNAPSHOT_AGE_HOURS" "$BACKUP_SNAPSHOT_GRACE_HOURS"; do
        if ! [[ "$file" =~ ^[0-9]+$ ]]; then
            fail "BACKUP_MAX_SNAPSHOT_AGE_HOURS and BACKUP_SNAPSHOT_GRACE_HOURS must be whole numbers"
        fi
    done

    umask 077
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    # The encryption key is the one file a backup must not be missing.
    if [ ! -s "$K3S_CONFIG_DIR/encryption-config.yaml" ]; then
        fail "$K3S_CONFIG_DIR/encryption-config.yaml not found"
    fi

    work=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT

    mkdir -p "$work/k3s-config" "$work/k3s-server" "$work/etcd-snapshots"

    for file in encryption-config.yaml audit-policy.yaml pod-security-config.yaml config.yaml agent-token; do
        if [ -f "$K3S_CONFIG_DIR/$file" ]; then
            cp -p "$K3S_CONFIG_DIR/$file" "$work/k3s-config/"
        fi
    done

    for file in token agent-token; do
        if [ -e "$K3S_DATA_DIR/server/$file" ]; then
            cp -pL "$K3S_DATA_DIR/server/$file" "$work/k3s-server/"
        fi
    done

    snapshot_dir="$K3S_DATA_DIR/server/db/snapshots"
    if [ -d "$snapshot_dir" ]; then
        # An empty file is a snapshot that failed, so it doesn't count as one.
        mapfile -t snapshots < <(find "$snapshot_dir" -maxdepth 1 -type f -size +0c -printf '%T@ %f\n' | sort -rn | head -n "$BACKUP_SNAPSHOTS" | cut -d' ' -f2-)
        newest_epoch=$(find "$snapshot_dir" -maxdepth 1 -type f -size +0c -printf '%T@\n' | sort -rn | head -n 1 | cut -d. -f1)
    fi
    for file in "${snapshots[@]}"; do
        cp -p "$snapshot_dir/$file" "$work/etcd-snapshots/"
    done

    # Without the token and a recent snapshot this archive can't restore the cluster.
    now=$(date +%s)
    if [ ! -s "$K3S_DATA_DIR/server/token" ]; then
        problems+=("the server token is missing: $K3S_DATA_DIR/server/token")
    fi
    if [ -z "$newest_epoch" ]; then
        # k3s rewrites the token at every start, so the cluster CA gives the cluster's age.
        local ca="$K3S_DATA_DIR/server/tls/server-ca.crt"
        if [ ${#problems[@]} -eq 0 ] && [ -s "$ca" ] && [ $(( now - $(stat -c %Y "$ca") )) -lt $(( BACKUP_SNAPSHOT_GRACE_HOURS * 3600 )) ]; then
            grace=1
        else
            problems+=("no etcd snapshots in $snapshot_dir")
        fi
    else
        age_hours=$(( (now - newest_epoch) / 3600 ))
        if [ "$age_hours" -ge "$BACKUP_MAX_SNAPSHOT_AGE_HOURS" ]; then
            problems+=("the newest etcd snapshot is $age_hours hours old (limit: $BACKUP_MAX_SNAPSHOT_AGE_HOURS)")
        fi
    fi
    if [ ${#problems[@]} -gt 0 ]; then
        prefix="incomplete-control-plane-state"
    fi

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    archive="$BACKUP_DIR/$prefix-$stamp.tar.gz"
    tar -czf "$archive.tmp" -C "$work" k3s-config k3s-server etcd-snapshots
    tar -tzf "$archive.tmp" k3s-config/encryption-config.yaml >/dev/null
    chmod 600 "$archive.tmp"
    mv -f "$archive.tmp" "$archive"
    log "Wrote $archive with ${#snapshots[@]} etcd snapshot(s)"

    if [ ${#problems[@]} -gt 0 ]; then
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'incomplete-control-plane-state-*.tar.gz' -printf '%f\n' \
            | sort -r | tail -n "+$((BACKUP_KEEP_INCOMPLETE + 1))" | while IFS= read -r file; do
                rm -f "${BACKUP_DIR:?}/$file"
            done
        for file in "${problems[@]}"; do
            log "ERROR: $file"
        done
        fail "This backup can't restore the cluster, so it isn't recorded as a success, and nothing was sent off this machine. Kept what could be saved in $archive"
    fi

    # Newest first, by name, because the name holds the UTC time
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'control-plane-state-*.tar.gz' -printf '%f\n' \
        | sort -r | tail -n "+$((BACKUP_KEEP + 1))" | while IFS= read -r file; do
            rm -f "${BACKUP_DIR:?}/$file"
            log "Removed old archive $file"
        done

    local remote_enabled=0
    if [ -n "$BACKUP_REMOTE" ]; then
        copy_to_remote "$archive"
        remote_enabled=1
    else
        log "WARNING: BACKUP_REMOTE is not set. This backup will not survive losing this machine."
    fi

    if [ "$grace" -eq 1 ]; then
        log "WARNING: this new cluster has no etcd snapshot yet (they run every 6 hours). Kept keys and tokens, and not recording a success until one exists."
        return 0
    fi

    write_metrics "$(date +%s)" "$remote_enabled"
    log "Backup complete"
}

install_timer() {
    install -o root -g root -m 755 "$(realpath "${BASH_SOURCE[0]}")" "$INSTALL_PATH"

    cat > "$SYSTEMD_DIR/$UNIT_NAME.service" <<EOF
[Unit]
Description=MyNodeOne control plane state backup

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
EOF

    cat > "$SYSTEMD_DIR/$UNIT_NAME.timer" <<EOF
[Unit]
Description=Daily MyNodeOne control plane state backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$UNIT_NAME.timer"
    log "Installed $UNIT_NAME.timer (daily). Running the first backup now."
    run_backup
}

uninstall_timer() {
    systemctl disable --now "$UNIT_NAME.timer" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$UNIT_NAME.service" "$SYSTEMD_DIR/$UNIT_NAME.timer" "$INSTALL_PATH"
    systemctl daemon-reload
    log "Removed the timer. Existing archives in $BACKUP_DIR were kept."
}

case "${1:-}" in
    "") run_backup ;;
    --install) install_timer ;;
    --uninstall) uninstall_timer ;;
    *)
        echo "Usage: $0 [--install|--uninstall]" >&2
        exit 1
        ;;
esac
