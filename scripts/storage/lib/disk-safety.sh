#!/bin/bash

###############################################################################
# Disk safety checks shared by the storage installers.
#
# This is the only place storage scripts should erase a disk from. The rules:
#
#   Refused outright (no confirmation can override these):
#     - the disk holding the root filesystem, resolved through lsblk -s so LVM,
#       LUKS and RAID roots are found (PKNAME alone only reaches a partition)
#     - anything on the disk that is mounted, used as swap, or held by LVM,
#       device-mapper, LUKS or RAID
#     - LVM PV, RAID, swap, ZFS, Ceph, bcache or LUKS signatures, even when inactive
#     - disks referenced by /etc/fstab (a nofail data disk that failed to mount
#       looks unused but is not) or /etc/crypttab, in any form: device path, symlink
#       such as /dev/disk/by-id/..., UUID=, PARTUUID=, LABEL=, PARTLABEL= or ID=
#     - network and virtual block devices (Longhorn volumes appear as iSCSI
#       disks), and anything that is not a whole disk
#     - any disk, if the state could not be read: every check fails closed
#
#   Needs a second typed confirmation:
#     - other filesystem signatures, partition tables or partitions
#
#   Always needs:
#     - an interactive terminal on stdin; a non-interactive run wipes nothing
#     - the full device name, typed exactly
#
# Typical use:
#     source "$SCRIPT_DIR/../lib/disk-safety.sh"
#     disk_safety_init "sudo"                # or "ssh user@host sudo", or ""
#     disk_safety_scan                       # prints the menu, fills ELIGIBLE
#     disk_safety_confirm_wipe /dev/sdb || exit 1
#     disk_safety_wipe /dev/sdb || exit 1    # re-checks, then runs wipefs -a
#
# This file only defines functions and never changes shell options, so it is
# safe to source with or without set -e.
###############################################################################

# Command prefix for reaching the target machine. Set through disk_safety_init.
DISK_SAFETY_PREFIX=""

# Whole disks that may be offered, in menu order. Filled by disk_safety_scan.
declare -ga DISK_SAFETY_ELIGIBLE=()
# Why the last checked disk is refused, and which signatures it carries.
declare -ga DISK_SAFETY_REFUSALS=()
declare -ga DISK_SAFETY_SIGNATURES=()

# Disks the user confirmed in this run, mapped to an identity fingerprint.
declare -gA _DS_CONFIRMED=()
declare -gA _DS_CONFIRMED_SIGNATURES=()

_DS_COLUMNS="NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINT,UUID,PARTUUID,PARTLABEL"

# Read on the target machine, through the prefix. Overridable for the tests.
DISK_SAFETY_CRYPTTAB="${DISK_SAFETY_CRYPTTAB:-/etc/crypttab}"

disk_safety_init() {
    DISK_SAFETY_PREFIX="${1:-}"
    _DS_CONFIRMED=()
    _DS_CONFIRMED_SIGNATURES=()
}

# Stdin is closed so that ssh can't swallow the answers to later prompts.
_ds_run() {
    # shellcheck disable=SC2086  # the prefix is a command plus arguments
    $DISK_SAFETY_PREFIX "$@" </dev/null
}

# Reads one column from an lsblk -P line. The leading space stops NAME from
# matching PKNAME, and lsblk escapes quotes in values, so a disk label can't
# forge a field.
_ds_field() {
    local re=" $2=\"([^\"]*)\""
    if [[ " $1" =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
    return 0
}

# Device names reach a remote shell when the prefix is ssh, so only plain device
# paths get through.
_ds_valid_device() {
    [[ "$1" =~ ^/dev/[A-Za-z0-9][A-Za-z0-9._+:@-]*(/[A-Za-z0-9._+:@-]+)*$ ]]
}

_ds_refuse() {
    local item
    for item in "${DISK_SAFETY_REFUSALS[@]}"; do
        [[ "$item" == "$1" ]] && return 0
    done
    DISK_SAFETY_REFUSALS+=("$1")
}

_ds_signature() {
    local item
    for item in "${DISK_SAFETY_SIGNATURES[@]}"; do
        [[ "$item" == "$1" ]] && return 0
    done
    DISK_SAFETY_SIGNATURES+=("$1")
}

# Signatures belonging to storage stacks that can be active without a mountpoint
# are refused. Any other signature only needs the extra confirmation.
_ds_classify_fstype() {
    local dev="$1" fstype="$2"
    case "$fstype" in
        "") ;;
        LVM2_member)
            _ds_refuse "$dev is an LVM physical volume" ;;
        *_raid_member)
            _ds_refuse "$dev is a RAID member ($fstype)" ;;
        swap)
            _ds_refuse "$dev has a swap signature" ;;
        zfs_member|ceph_bluestore|bcache|drbd|VMFS_volume_member)
            _ds_refuse "$dev belongs to a storage pool ($fstype)" ;;
        crypto_LUKS)
            # Locked is not unused. An inactive LUKS volume looks like a plain signature.
            _ds_refuse "$dev is an encrypted LUKS volume" ;;
        *)
            _ds_signature "$dev: $fstype" ;;
    esac
}

# Prints the whole disks under the root filesystem, one per line. Returns 1 if
# they can't be determined, and callers must then refuse every disk: a ZFS root,
# an overlay root or a failing lsblk must never read as "no OS disk".
disk_safety_root_disks() {
    local source_dev="" chain="" disks=""
    source_dev=$(_ds_run findmnt -nr -o SOURCE -T /) || return 1
    source_dev="${source_dev%%$'\n'*}"
    source_dev="${source_dev%%\[*}"     # btrfs appends [/subvolume]
    _ds_valid_device "$source_dev" || return 1
    chain=$(_ds_run lsblk -s -nrp -o NAME,TYPE "$source_dev") || return 1
    disks=$(printf '%s\n' "$chain" | awk '$2 == "disk" { print $1 }' | sort -u)
    [[ -n "$disks" ]] || return 1
    printf '%s\n' "$disks"
}

# Prints the device a /dev/... or ID= spec points at, on the target machine, through
# the same prefix as every other check. Prints nothing for other forms, and when the
# link doesn't exist (readlink exits 1). Returns 1 if it can't be determined, because a
# spec that can't be resolved could be pointing at the disk being checked.
_ds_canonical_spec() {
    local spec="$1" path="" output="" rc=0
    case "$spec" in
        ID=*) path="/dev/disk/by-id/${spec#ID=}" ;;
        /dev/*) path="$spec" ;;
        *) return 0 ;;
    esac
    _ds_valid_device "$path" || return 1
    output=$(_ds_run readlink -f -- "$path" 2>/dev/null) || rc=$?
    case "$rc" in
        0) printf '%s' "$output" ;;
        1) ;;
        *) return 1 ;;
    esac
}

# Resolves a list of specs once. Prints "spec<TAB>canonical" lines, and returns 1 after
# refusing if any can't be resolved.
_ds_resolve_specs() {
    local file="$1" specs="$2" spec canonical status=0
    while IFS= read -r spec; do
        [[ -n "$spec" ]] || continue
        if canonical=$(_ds_canonical_spec "$spec"); then
            printf '%s\t%s\n' "$spec" "$canonical"
        else
            printf 'refuse\t%s\t%s\n' "$file" "$spec"
            status=1
        fi
    done <<< "$specs"
    return "$status"
}

# True if a spec from fstab or crypttab names this device.
_ds_spec_names_device() {
    local spec="$1" canonical="$2" name="$3" uuid="$4" partuuid="$5" label="$6" partlabel="$7"
    [[ "$spec" == "$name" ]] && return 0
    [[ -n "$canonical" && "$canonical" == "$name" ]] && return 0
    if [[ -n "$uuid" ]]; then
        [[ "$spec" == "UUID=$uuid" || "$spec" == "/dev/disk/by-uuid/$uuid" ]] && return 0
    fi
    if [[ -n "$partuuid" ]]; then
        [[ "$spec" == "PARTUUID=$partuuid" || "$spec" == "/dev/disk/by-partuuid/$partuuid" ]] && return 0
    fi
    if [[ -n "$label" ]]; then
        [[ "$spec" == "LABEL=$label" || "$spec" == "/dev/disk/by-label/$label" ]] && return 0
    fi
    if [[ -n "$partlabel" ]]; then
        [[ "$spec" == "PARTLABEL=$partlabel" || "$spec" == "/dev/disk/by-partlabel/$partlabel" ]] && return 0
    fi
    return 1
}

# Low-level probe of one device. blkid exits 2 both for "nothing found" and for
# an open failure, so exit 2 only counts as clean when it printed nothing.
_ds_probe_signatures() {
    local dev="$1" output="" rc=0 line
    output=$(_ds_run blkid -p -o export "$dev" 2>&1) || rc=$?
    case "$rc" in
        0)
            while IFS= read -r line; do
                case "$line" in
                    TYPE=*)   _ds_classify_fstype "$dev" "${line#TYPE=}" ;;
                    PTTYPE=*) _ds_signature "$dev: partition table (${line#PTTYPE=})" ;;
                esac
            done <<< "$output"
            ;;
        2)
            if [[ -n "$output" ]]; then
                _ds_refuse "could not probe $dev: $output"
            fi
            ;;
        *)
            _ds_refuse "could not probe $dev (blkid exit $rc)"
            ;;
    esac
}

# Checks one disk. Fills DISK_SAFETY_REFUSALS and DISK_SAFETY_SIGNATURES.
# Returns 0 if it looks blank, 2 if it only has signatures, 1 if it is refused.
disk_safety_check() {
    local disk="$1"
    DISK_SAFETY_REFUSALS=()
    DISK_SAFETY_SIGNATURES=()

    if ! _ds_valid_device "$disk"; then
        _ds_refuse "not a valid device path: $disk"
        return 1
    fi

    local tree=""
    if ! tree=$(_ds_run lsblk -P -p -o "$_DS_COLUMNS" "$disk"); then
        _ds_refuse "could not inspect $disk with lsblk"
        return 1
    fi
    if [[ -z "$tree" ]]; then
        _ds_refuse "lsblk returned nothing for $disk"
        return 1
    fi

    local first_line="${tree%%$'\n'*}"
    if [[ "$(_ds_field "$first_line" NAME)" != "$disk" ]]; then
        _ds_refuse "$disk is not the canonical device name"
    fi
    if [[ "$(_ds_field "$first_line" TYPE)" != "disk" ]]; then
        _ds_refuse "$disk is not a whole disk (type: $(_ds_field "$first_line" TYPE))"
    fi
    case "$(basename "$disk")" in
        loop*|ram*|zram*|fd*|sr*|md*|dm-*|nbd*)
            _ds_refuse "$disk is a virtual device" ;;
    esac
    case "$(_ds_field "$first_line" TRAN)" in
        iscsi|fc|nvme-tcp|nvme-rdma)
            _ds_refuse "$disk is a network-attached volume ($(_ds_field "$first_line" TRAN))" ;;
    esac
    if [[ "$(_ds_field "$first_line" SIZE)" == "0B" ]]; then
        _ds_refuse "$disk has no media"
    fi

    # Root disk, resolved through every layer between / and the hardware.
    local root_disks=""
    if ! root_disks=$(disk_safety_root_disks); then
        _ds_refuse "could not identify the disk holding the root filesystem, so no disk can be proven safe"
    elif grep -qxF -- "$disk" <<< "$root_disks"; then
        _ds_refuse "$disk holds the root filesystem"
    fi

    # Mount, swap and fstab views, read before the per-device loop so that a
    # failed read refuses the disk instead of looking like an empty list.
    local mounts="" swaps="" fstab=""
    if ! mounts=$(_ds_run findmnt -rn -o SOURCE); then
        _ds_refuse "could not read the mount table"
    fi
    if ! swaps=$(_ds_run swapon --show=NAME --noheadings); then
        _ds_refuse "could not read the active swap list"
    fi
    # findmnt exits 1 when fstab has no entries, so an empty result isn't an error.
    fstab=$(_ds_run findmnt --fstab -rn -o SOURCE) || fstab=""
    fstab="${fstab//\"/}"

    # Only a missing crypttab means there are no entries. Its second field is the device.
    local crypttab="" crypttab_rc=0
    crypttab=$(_ds_run env LC_ALL=C cat "$DISK_SAFETY_CRYPTTAB" 2>&1) || crypttab_rc=$?
    if [[ "$crypttab_rc" -ne 0 ]]; then
        if [[ "$crypttab" == *"No such file"* ]]; then
            crypttab=""
        else
            _ds_refuse "could not read $DISK_SAFETY_CRYPTTAB"
            crypttab=""
        fi
    fi
    crypttab=$(awk '!/^[[:space:]]*(#|$)/ { gsub(/["\047]/, "", $2); print $2 }' <<< "$crypttab")

    # Resolved once per spec, rather than once per spec per device.
    local fstab_refs="" crypttab_refs="" ref_line spec_file spec canonical
    fstab_refs=$(_ds_resolve_specs /etc/fstab "$fstab") || true
    crypttab_refs=$(_ds_resolve_specs "$DISK_SAFETY_CRYPTTAB" "$crypttab") || true
    while IFS=$'\t' read -r ref_line spec_file spec; do
        if [[ "$ref_line" == "refuse" ]]; then
            _ds_refuse "could not resolve $spec from $spec_file, so no disk can be proven unused"
        fi
    done <<< "$fstab_refs"$'\n'"$crypttab_refs"

    local line name type fstype mountpoint uuid partuuid label partlabel source_dev
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=$(_ds_field "$line" NAME)
        type=$(_ds_field "$line" TYPE)
        fstype=$(_ds_field "$line" FSTYPE)
        mountpoint=$(_ds_field "$line" MOUNTPOINT)
        uuid=$(_ds_field "$line" UUID)
        partuuid=$(_ds_field "$line" PARTUUID)
        label=$(_ds_field "$line" LABEL)
        partlabel=$(_ds_field "$line" PARTLABEL)

        case "$type" in
            disk) ;;
            part)
                _ds_signature "$name: existing partition" ;;
            *)
                _ds_refuse "$name is an active $type device on this disk" ;;
        esac

        if [[ "$mountpoint" == "[SWAP]" ]]; then
            _ds_refuse "$name is in use as swap"
        elif [[ -n "$mountpoint" ]]; then
            _ds_refuse "$name is mounted at $mountpoint"
        fi

        _ds_classify_fstype "$name" "$fstype"

        while IFS= read -r source_dev; do
            source_dev="${source_dev%%\[*}"
            if [[ "$source_dev" == "$name" ]]; then
                _ds_refuse "$name is mounted"
            fi
        done <<< "$mounts"

        if grep -qxF -- "$name" <<< "$swaps"; then
            _ds_refuse "$name is in use as swap"
        fi

        while IFS=$'\t' read -r spec canonical; do
            [[ -n "$spec" && "$spec" != "refuse" ]] || continue
            if _ds_spec_names_device "$spec" "$canonical" "$name" "$uuid" "$partuuid" "$label" "$partlabel"; then
                _ds_refuse "$name is referenced by /etc/fstab ($spec)"
            fi
        done <<< "$fstab_refs"

        while IFS=$'\t' read -r spec canonical; do
            [[ -n "$spec" && "$spec" != "refuse" ]] || continue
            if _ds_spec_names_device "$spec" "$canonical" "$name" "$uuid" "$partuuid" "$label" "$partlabel"; then
                _ds_refuse "$name is referenced by $DISK_SAFETY_CRYPTTAB ($spec)"
            fi
        done <<< "$crypttab_refs"

        case "$type" in
            disk|part) _ds_probe_signatures "$name" ;;
        esac
    done <<< "$tree"

    if (( ${#DISK_SAFETY_REFUSALS[@]} > 0 )); then
        return 1
    fi
    if (( ${#DISK_SAFETY_SIGNATURES[@]} > 0 )); then
        return 2
    fi
    return 0
}

# Prints what is on a disk so the user can recognise it before erasing it.
disk_safety_show() {
    local disk="$1" tree="" line first=1
    if ! tree=$(_ds_run lsblk -P -p -o "$_DS_COLUMNS" "$disk"); then
        echo "  $disk: could not read device details"
        return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if (( first )); then
            first=0
            echo "  Device: $(_ds_field "$line" NAME)"
            echo "  Model:  $(_ds_field "$line" MODEL)"
            echo "  Serial: $(_ds_field "$line" SERIAL)"
            echo "  Size:   $(_ds_field "$line" SIZE)"
            printf '  %-32s %-8s %-8s %-12s %-16s %s\n' NAME TYPE SIZE FS LABEL MOUNTPOINT
        fi
        local fs label mountpoint
        fs=$(_ds_field "$line" FSTYPE)
        label=$(_ds_field "$line" LABEL)
        mountpoint=$(_ds_field "$line" MOUNTPOINT)
        printf '  %-32s %-8s %-8s %-12s %-16s %s\n' \
            "$(_ds_field "$line" NAME)" "$(_ds_field "$line" TYPE)" "$(_ds_field "$line" SIZE)" \
            "${fs:--}" "${label:--}" "${mountpoint:--}"
    done <<< "$tree"
}

# Lists every whole disk, numbers the ones that may be offered, and explains the
# rest. Fills DISK_SAFETY_ELIGIBLE. Returns 1 if disks could not be listed.
disk_safety_scan() {
    DISK_SAFETY_ELIGIBLE=()
    local listing="" line name rc
    if ! listing=$(_ds_run lsblk -d -n -P -p -o NAME,TYPE); then
        echo "Could not list disks. No disk will be offered."
        return 1
    fi

    local -a refused=()
    local index=0 reason
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$(_ds_field "$line" TYPE)" == "disk" ]] || continue
        name=$(_ds_field "$line" NAME)
        rc=0
        disk_safety_check "$name" || rc=$?
        if (( rc == 1 )); then
            refused+=("$name")
            for reason in "${DISK_SAFETY_REFUSALS[@]}"; do
                refused+=("    - $reason")
            done
            continue
        fi
        DISK_SAFETY_ELIGIBLE+=("$name")
        index=$((index + 1))
        echo "  $index) $name"
        disk_safety_show "$name" | sed 's/^/     /'
        if (( rc == 2 )); then
            echo "     Has existing data signatures, so erasing it needs a second confirmation:"
            for reason in "${DISK_SAFETY_SIGNATURES[@]}"; do
                echo "       - $reason"
            done
        else
            echo "     Blank: no filesystem, partition table or signature found."
        fi
        echo
    done <<< "$listing"

    if (( ${#refused[@]} > 0 )); then
        echo "Not offered, because these disks can't be erased safely:"
        printf '  %s\n' "${refused[@]}"
        echo
    fi
    return 0
}

# Checks a directory offered as a data location, whose whole tree gets a new owner.
# System directories and the root filesystem are often mountpoints too, so being
# mounted doesn't make a path safe. Returns 0 only for a mountpoint elsewhere.
disk_safety_check_data_path() {
    local path="$1"
    if ! [[ "$path" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
        echo "Not a plain absolute path: $path" >&2
        return 1
    fi
    case "/$path/" in
        */./*|*/../*)
            echo "Path must not contain '.' or '..': $path" >&2
            return 1
            ;;
    esac
    case "$path" in
        /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/lib|/lib/*|/lib32|/lib32/*|\
        /lib64|/lib64/*|/opt|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/snap|/snap/*|\
        /sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/lib|/var/log|/var/log/*)
            echo "Refusing a system directory: $path" >&2
            return 1
            ;;
        /var/lib/longhorn|/var/lib/longhorn/*|/var/lib/rancher|/var/lib/rancher/*|\
        /var/lib/kubelet|/var/lib/kubelet/*|/var/lib/docker|/var/lib/docker/*|\
        /var/lib/containerd|/var/lib/containerd/*|/mnt/longhorn-disks|/mnt/longhorn-disks/*)
            echo "Refusing a directory that holds cluster data: $path" >&2
            return 1
            ;;
    esac
    if ! _ds_run mountpoint -q "$path"; then
        echo "$path is not a mountpoint." >&2
        return 1
    fi
    return 0
}

# Interactive means a terminal on stdin. There's deliberately no switch to skip
# this: piped input, cron and CI can't erase a disk.
disk_safety_is_interactive() {
    [[ -t 0 ]]
}

_ds_fingerprint() {
    local line=""
    line=$(_ds_run lsblk -d -n -P -p -o NAME,SIZE,MODEL,SERIAL "$1") || return 1
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# Asks the user to confirm erasing one disk. Records the confirmation for
# disk_safety_wipe. Returns 0 only if the disk passed the checks and the user
# typed the required text exactly.
disk_safety_confirm_wipe() {
    local disk="$1" rc=0 typed="" expected="" reason fingerprint=""
    unset '_DS_CONFIRMED[$disk]' '_DS_CONFIRMED_SIGNATURES[$disk]'

    if ! disk_safety_is_interactive; then
        echo "Refusing to erase $disk: this run has no terminal to confirm on. Nothing was changed." >&2
        return 1
    fi

    disk_safety_check "$disk" || rc=$?
    echo
    disk_safety_show "$disk" || true
    echo

    if (( rc == 1 )); then
        echo "Refusing to erase $disk:" >&2
        for reason in "${DISK_SAFETY_REFUSALS[@]}"; do
            echo "  - $reason" >&2
        done
        return 1
    fi

    echo "ALL DATA ON $disk WILL BE DESTROYED."
    IFS= read -r -p "Type the full device name ($disk) to erase it, or anything else to cancel: " typed || typed=""
    if [[ "$typed" != "$disk" ]]; then
        echo "Confirmation did not match. $disk was not changed." >&2
        return 1
    fi

    if (( rc == 2 )); then
        echo
        echo "$disk is not blank. It contains:"
        for reason in "${DISK_SAFETY_SIGNATURES[@]}"; do
            echo "  - $reason"
        done
        expected="ERASE EXISTING DATA ON $disk"
        typed=""
        IFS= read -r -p "Type '$expected' to erase it anyway, or anything else to cancel: " typed || typed=""
        if [[ "$typed" != "$expected" ]]; then
            echo "Confirmation did not match. $disk was not changed." >&2
            return 1
        fi
    fi

    if ! fingerprint=$(_ds_fingerprint "$disk"); then
        echo "Could not read the identity of $disk. It was not changed." >&2
        return 1
    fi
    _DS_CONFIRMED[$disk]="$fingerprint"
    _DS_CONFIRMED_SIGNATURES[$disk]="$rc"
    return 0
}

# Erases signatures from a confirmed disk. All checks run again right before the
# wipe, since the disk may have been mounted or swapped since the prompt. Each
# confirmation is single-use. Any failure returns non-zero and callers must stop.
disk_safety_wipe() {
    local disk="$1" rc=0 reason fingerprint=""

    if [[ -z "${_DS_CONFIRMED[$disk]:-}" ]]; then
        echo "Refusing to erase $disk: it was not confirmed in this run." >&2
        return 1
    fi

    disk_safety_check "$disk" || rc=$?
    if (( rc == 1 )); then
        echo "Refusing to erase $disk, its state changed after confirmation:" >&2
        for reason in "${DISK_SAFETY_REFUSALS[@]}"; do
            echo "  - $reason" >&2
        done
        return 1
    fi
    if (( rc == 2 )) && [[ "${_DS_CONFIRMED_SIGNATURES[$disk]:-}" != "2" ]]; then
        echo "Refusing to erase $disk: it was blank at confirmation but now has signatures:" >&2
        printf '  - %s\n' "${DISK_SAFETY_SIGNATURES[@]}" >&2
        return 1
    fi

    if ! fingerprint=$(_ds_fingerprint "$disk") || [[ "$fingerprint" != "${_DS_CONFIRMED[$disk]}" ]]; then
        echo "Refusing to erase $disk: it no longer looks like the disk that was confirmed." >&2
        return 1
    fi

    unset '_DS_CONFIRMED[$disk]' '_DS_CONFIRMED_SIGNATURES[$disk]'

    if ! _ds_run wipefs -a "$disk"; then
        echo "wipefs failed on $disk. Stopping." >&2
        return 1
    fi
    return 0
}
