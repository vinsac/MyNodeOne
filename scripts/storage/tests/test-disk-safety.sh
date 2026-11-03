#!/bin/bash

# Tests for lib/disk-safety.sh and how the two installers use it.
#
# Nothing here touches a disk: see lib.sh. The installers are never run. Their disk
# functions are cut out of the source, and only those run, against stubs.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_sandbox

echo "Stubs confirmed: real disk and cluster tools can't be reached from the test PATH."
echo

# The guard above has to actually stop a run that isn't shadowed.
"$(command -v mkdir)" -p "$WORK/empty-bin"
(BIN="$WORK/empty-bin"; assert_sandbox_shadows) 2>/dev/null
if [[ $? -eq 2 ]]; then
    pass "harness refuses to run when a stub is missing"
else
    fail "harness didn't notice a missing stub"
fi
"$(command -v mkdir)" -p "$WORK/linked-bin"
for linked in "$BIN"/*; do
    "$REAL_LN" -s "$linked" "$WORK/linked-bin/${linked##*/}"
done
(BIN="$WORK/linked-bin"; assert_sandbox_shadows) 2>/dev/null
if [[ $? -eq 2 ]]; then
    pass "harness refuses to run when a stub is a link to something else"
else
    fail "harness didn't notice a linked stub"
fi
echo

HELPER="$REPO_ROOT/scripts/storage/lib/disk-safety.sh"
LOAD="source '$HELPER'; disk_safety_init ''"
LOAD_SUDO="source '$HELPER'; disk_safety_init sudo"

# Confirms and then wipes, like an installer does. Stops at the first failure.
CONFIRM_AND_WIPE='disk_safety_confirm_wipe "$D" || exit 41; disk_safety_wipe "$D" || exit 42; echo wiped'

confirm_and_wipe() {
    reset_state
    use_fixture "$1"
    sandbox_pty "$3" "$LOAD; D='$2'; $CONFIRM_AND_WIPE"
}

# A disk that must be refused even when the user types everything correctly.
expect_refused() {
    local name="$1" fixture="$2" disk="$3" reason="$4"
    confirm_and_wipe "$fixture" "$disk" "$disk|ERASE EXISTING DATA ON $disk"
    expect_rc "$name" 41
    expect_output "$name" "$reason"
    expect_no_writes "$name"
}

echo "--- Root disk resolution"

resolves_to() {
    local name="$1" fixture="$2" want="$3"
    use_fixture "$fixture"
    sandbox_bash "$LOAD; disk_safety_root_disks"
    if [[ "$RC" -eq 0 && "$OUT" == "$want" ]]; then
        pass "$name: root disk is $(printf '%s' "$want" | "$BIN/tr" '\n' ' ')"
    else
        fail "$name: expected '$want', got '$OUT' (exit $RC)"
    fi
}

resolves_to "plain NVMe root" plain-nvme-root /dev/nvme0n1
resolves_to "LVM root" lvm-root /dev/nvme0n1
resolves_to "LUKS root" luks-root /dev/nvme0n1
resolves_to "LVM on LUKS root" lvm-on-luks-root /dev/nvme0n1
resolves_to "btrfs subvolume root" btrfs-subvol-root /dev/sda
resolves_to "RAID root" raid-root $'/dev/sda\n/dev/sdb'

use_fixture lvm-root
sandbox_bash "lsblk -no PKNAME /dev/mapper/ubuntu--vg-ubuntu--lv"
if [[ "$OUT" == "/dev/nvme0n1p3" ]]; then
    pass "LVM root fixture: PKNAME gives a partition, the case the old check missed"
else
    fail "LVM root fixture: expected PKNAME to be the partition, got '$OUT'"
fi

use_fixture zfs-root
sandbox_bash "$LOAD; disk_safety_root_disks"
expect_rc_nonzero "ZFS root can't be resolved"

echo
echo "--- Refused even with correct typing"

expect_refused "plain NVMe root" plain-nvme-root /dev/nvme0n1 "holds the root filesystem"
expect_refused "LVM root" lvm-root /dev/nvme0n1 "holds the root filesystem"
expect_refused "LUKS root" luks-root /dev/nvme0n1 "holds the root filesystem"
expect_refused "LVM on LUKS root" lvm-on-luks-root /dev/nvme0n1 "holds the root filesystem"
expect_refused "RAID root, first disk" raid-root /dev/sda "holds the root filesystem"
expect_refused "RAID root, second disk" raid-root /dev/sdb "holds the root filesystem"
expect_refused "unresolvable root refuses every disk" zfs-root /dev/sdz "could not identify the disk holding the root"
expect_refused "mounted disk with an empty partition" data-disks /dev/sda "/dev/sda1 is mounted"
expect_refused "whole disk mounted" data-disks /dev/sdb "/dev/sdb is mounted"
expect_refused "inactive LVM PV" data-disks /dev/sdf "LVM physical volume"
expect_refused "unassembled RAID member" data-disks /dev/sdg "RAID member"
expect_refused "active swap" data-disks /dev/sdh "in use as swap"
expect_refused "referenced by fstab" data-disks /dev/sdi "referenced by /etc/fstab"
expect_refused "iSCSI Longhorn volume" data-disks /dev/sdj "network-attached"
expect_refused "ZFS pool member" data-disks /dev/sdk "storage pool"
expect_refused "active LVM volume" data-disks /dev/sdn "active lvm device"
expect_refused "no media" data-disks /dev/sdo "no media"
expect_refused "blkid open failure" data-disks /dev/sdl "could not probe"
expect_refused "blkid ambivalent result" data-disks /dev/sdm "could not probe"
expect_refused "loop device" data-disks /dev/loop0 "not a whole disk"
expect_refused "partition instead of disk" data-disks /dev/sdd1 "not a whole disk"
expect_refused "unknown device" data-disks /dev/sdx "could not inspect"
expect_refused "shell text in a device name" data-disks '/dev/sdc;id' "not a valid device path"

echo
echo "--- fstab and crypttab references, in every form"

# A blank disk with one partition: /dev/sdz, /dev/sdz1. Nothing else claims it.
# Arguments: fstype, fstab JSON, symlinks JSON, fail JSON. A bad argument stops the
# run, because a test against the previous fixture could pass for the wrong reason.
reference_fixture() {
    "$REAL_PYTHON" -I -c "
import json, sys
src, fstype, fstab, links, failures, dest = sys.argv[1:]
d = json.load(open(src))
d['devices'].append({'name': '/dev/sdz', 'type': 'disk', 'size': '4T', 'tran': 'sata', 'pttype': 'gpt',
  'children': [{'name': '/dev/sdz1', 'type': 'part', 'size': '4T', 'fstype': fstype,
                'uuid': 'zz-uuid', 'partuuid': 'zz-partuuid', 'partlabel': 'zz-partlabel', 'label': 'zz-label'}]})
d['fstab'] = json.loads(fstab)
d['symlinks'] = json.loads(links)
if failures:
    d['fail'] = json.loads(failures)
json.dump(d, open(dest, 'w'))
" "$FIXTURES/data-disks.json" "$1" "$2" "$3" "$4" "$FAKE_FIXTURE" || exit 2
}

# The confirm-and-wipe flow against the fixture just written. Typed correctly every time.
reference_run() {
    reset_state
    sandbox_pty "/dev/sdz|ERASE EXISTING DATA ON /dev/sdz" "$LOAD_SUDO; D=/dev/sdz; $CONFIRM_AND_WIPE"
}

expect_fstab_refused() {
    local name="$1" spec="$2" links="$3" reason="$4"
    reference_fixture ext4 "[\"$spec\"]" "$links" ""
    : > "$WORK/crypttab"
    reference_run
    expect_rc "$name" 41
    expect_output "$name" "$reason"
    expect_no_writes "$name"
}

expect_fstab_refused "fstab by-id partition link" /dev/disk/by-id/ata-Z-part1 \
    '{"/dev/disk/by-id/ata-Z-part1": "/dev/sdz1"}' "/dev/sdz1 is referenced by /etc/fstab"
expect_fstab_refused "fstab by-path partition link" /dev/disk/by-path/pci-0-part1 \
    '{"/dev/disk/by-path/pci-0-part1": "/dev/sdz1"}' "/dev/sdz1 is referenced by /etc/fstab"
expect_fstab_refused "fstab by-id whole disk link" /dev/disk/by-id/ata-Z \
    '{"/dev/disk/by-id/ata-Z": "/dev/sdz"}' "/dev/sdz is referenced by /etc/fstab"
expect_fstab_refused "fstab ID= form" ID=ata-Z-part1 \
    '{"/dev/disk/by-id/ata-Z-part1": "/dev/sdz1"}' "/dev/sdz1 is referenced by /etc/fstab"
expect_fstab_refused "fstab PARTLABEL=" PARTLABEL=zz-partlabel '{}' "/dev/sdz1 is referenced by /etc/fstab"
expect_fstab_refused "fstab by-partlabel link, unresolved" /dev/disk/by-partlabel/zz-partlabel \
    '{"/dev/disk/by-partlabel/zz-partlabel": null}' "/dev/sdz1 is referenced by /etc/fstab"
expect_fstab_refused "fstab spec with shell text" '/dev/disk/by-id/x;id' '{}' "could not resolve"

# Each symlink is resolved on the target machine, through the prefix.
reference_fixture ext4 '["/dev/disk/by-id/ata-Z-part1"]' '{"/dev/disk/by-id/ata-Z-part1": "/dev/sdz1"}' ""
: > "$WORK/crypttab"
reset_state
sandbox_pty "/dev/sdz|ERASE EXISTING DATA ON /dev/sdz" "source '$HELPER'; disk_safety_init 'ssh u@node sudo'; D=/dev/sdz; $CONFIRM_AND_WIPE"
expect_rc "fstab link through ssh" 41
expect_log "fstab link through ssh" '^ssh u@node sudo readlink -f -- /dev/disk/by-id/ata-Z-part1$'
expect_output "fstab link through ssh" "/dev/sdz1 is referenced by /etc/fstab"

# Someone else's disk must not be refused because of it.
reference_fixture ext4 '["/dev/disk/by-id/ata-OTHER-part1"]' '{"/dev/disk/by-id/ata-OTHER-part1": "/dev/sda1"}' ""
: > "$WORK/crypttab"
reference_run
expect_rc "fstab link to another disk: only the signature prompt" 0
expect_log "fstab link to another disk: only the signature prompt" '^wipefs -a /dev/sdz$'

# An unknown readlink failure is not the same as "no such link".
for bad_rc in 127 255; do
    reference_fixture ext4 '["/dev/disk/by-id/ata-Z-part1"]' '{}' "{\"readlink\": $bad_rc}"
    : > "$WORK/crypttab"
    reference_run
    expect_rc "readlink exit $bad_rc" 41
    expect_output "readlink exit $bad_rc" "could not resolve"
    expect_no_writes "readlink exit $bad_rc"
done

reference_fixture crypto_LUKS '[]' '{}' ""
: > "$WORK/crypttab"
reference_run
expect_rc "inactive LUKS partition" 41
expect_output "inactive LUKS partition" "/dev/sdz1 is an encrypted LUKS volume"
expect_no_writes "inactive LUKS partition"

expect_crypttab_refused() {
    local name="$1" line="$2" links="${3:-}"
    reference_fixture ext4 '[]' "${links:-{\}}" ""
    printf '%s\n' "# a comment naming /dev/sdc" "$line" > "$WORK/crypttab"
    reference_run
    expect_rc "$name" 41
    expect_output "$name" "referenced by .*crypttab"
    expect_no_writes "$name"
}

expect_crypttab_refused "crypttab device path" "cr /dev/sdz1 none luks"
expect_crypttab_refused "crypttab UUID=" "cr UUID=zz-uuid /key luks"
expect_crypttab_refused "crypttab quoted UUID=" 'cr UUID="zz-uuid" none'
expect_crypttab_refused "crypttab PARTLABEL=" "cr PARTLABEL=zz-partlabel none"
expect_crypttab_refused "crypttab by-id link" "cr /dev/disk/by-id/ata-Z-part1 none" '{"/dev/disk/by-id/ata-Z-part1": "/dev/sdz1"}'

reference_fixture ext4 '[]' '{}' ""
printf '%s\n' "# cr /dev/sdz1 none" "cr /dev/other none luks" > "$WORK/crypttab"
reference_run
expect_rc "crypttab comment and another device" 0
expect_log "crypttab comment and another device" '^wipefs -a /dev/sdz$'

# No crypttab is the normal case. An unreadable one isn't.
"$REAL_RM" -f "$WORK/crypttab"
reference_fixture ext4 '[]' '{}' ""
reference_run
expect_rc "no crypttab" 0
expect_log "no crypttab" '^wipefs -a /dev/sdz$'

"$(command -v mkdir)" -p "$WORK/crypttab"
reference_fixture ext4 '[]' '{}' ""
reference_run
expect_rc "unreadable crypttab" 41
expect_output "unreadable crypttab" "could not read .*crypttab"
expect_no_writes "unreadable crypttab"
"$REAL_RM" -rf "$WORK/crypttab"
: > "$WORK/crypttab"

echo
echo "--- Failing to read state refuses the disk"

for tool in lsblk findmnt swapon findmnt_root; do
    reset_state
    use_fixture data-disks
    "$REAL_PYTHON" -I -c "
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['fail'] = {sys.argv[2]: 1}
json.dump(d, open(p, 'w'))
" "$FAKE_FIXTURE" "$tool"
    sandbox_pty "/dev/sdc" "$LOAD; D=/dev/sdc; $CONFIRM_AND_WIPE"
    expect_rc "$tool failure" 41
    expect_no_writes "$tool failure"
done

echo
echo "--- Typed confirmation"

confirm_and_wipe data-disks /dev/sdc "/dev/sdc"
expect_rc "blank disk, correct name" 0
expect_log "blank disk, correct name" '^wipefs -a /dev/sdc$'
if [[ "$("$BIN/grep" -c '^wipefs ' "$CALLS")" -eq 1 ]]; then
    pass "blank disk: wiped exactly once"
else
    fail "blank disk: wrong number of wipes" "$("$BIN/cat" "$CALLS")"
fi

for wrong in "y" "yes" "Y" "sdc" "dev/sdc" "/dev/sdc " " /dev/sdc" "/dev/sdd" "/DEV/SDC" ""; do
    confirm_and_wipe data-disks /dev/sdc "$wrong"
    expect_rc "typed '$wrong'" 41
    expect_no_writes "typed '$wrong'"
done

reset_state
use_fixture data-disks
sandbox_pty "" "$LOAD; D=/dev/sdc; $CONFIRM_AND_WIPE"
expect_rc "no answer at all" 41
expect_no_writes "no answer at all"

echo
echo "--- Disks with existing data need the second confirmation"

confirm_and_wipe data-disks /dev/sdd "/dev/sdd"
expect_rc "ext4 disk, device name only" 41
expect_no_writes "ext4 disk, device name only"

confirm_and_wipe data-disks /dev/sdd "/dev/sdd|yes"
expect_rc "ext4 disk, second answer yes" 41
expect_no_writes "ext4 disk, second answer yes"

confirm_and_wipe data-disks /dev/sdd "/dev/sdd|/dev/sdd"
expect_rc "ext4 disk, name typed twice" 41
expect_no_writes "ext4 disk, name typed twice"

confirm_and_wipe data-disks /dev/sdd "/dev/sdd|ERASE EXISTING DATA ON /dev/sdd"
expect_rc "ext4 disk, both confirmations" 0
expect_log "ext4 disk, both confirmations" '^wipefs -a /dev/sdd$'

confirm_and_wipe data-disks /dev/sde "/dev/sde"
expect_rc "partition table only, device name only" 41
expect_no_writes "partition table only, device name only"

confirm_and_wipe data-disks /dev/sdp "/dev/sdp"
expect_rc "label with quotes can't forge fields" 41
expect_no_writes "label with quotes can't forge fields"

echo
echo "--- A run with no terminal never wipes"

reset_state
use_fixture data-disks
sandbox_bash "$LOAD; D=/dev/sdc; $CONFIRM_AND_WIPE"
expect_rc "stdin is /dev/null" 41
expect_output "stdin is /dev/null" "no terminal"
expect_no_writes "stdin is /dev/null"

reset_state
sandbox_bash "$LOAD; D=/dev/sdc; { echo /dev/sdc; echo /dev/sdc; } | { $CONFIRM_AND_WIPE; }"
expect_rc "correct name piped in" 41
expect_no_writes "correct name piped in"

reset_state
sandbox_bash "$LOAD; disk_safety_wipe /dev/sdc"
expect_rc_nonzero "wipe without confirmation"
expect_no_writes "wipe without confirmation"

echo
echo "--- Checks run again right before the wipe"

# Swaps the fixture between the prompt and the wipe.
changes_after_confirm() {
    local name="$1" next="$2" want="$3"
    reset_state
    use_fixture data-disks
    sandbox_pty "/dev/sdc" "$LOAD; D=/dev/sdc; disk_safety_confirm_wipe \$D || exit 41; cat '$next' > '$FAKE_FIXTURE'; disk_safety_wipe \$D || exit 42; echo wiped"
    expect_rc "$name" 42
    expect_output "$name" "$want"
    expect_no_writes "$name"
}

"$REAL_PYTHON" -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
for n in d['devices']:
    if n['name'] == '/dev/sdc':
        n['mountpoint'] = '/mnt/new'
json.dump(d, open(sys.argv[2] + '/tmp-mounted.json', 'w'))
for n in d['devices']:
    if n['name'] == '/dev/sdc':
        del n['mountpoint']
        n['fstype'] = 'ext4'
json.dump(d, open(sys.argv[2] + '/tmp-signature.json', 'w'))
for n in d['devices']:
    if n['name'] == '/dev/sdc':
        del n['fstype']
        n['serial'] = 'DIFFERENT-DISK'
json.dump(d, open(sys.argv[2] + '/tmp-swapped.json', 'w'))
" "$FIXTURES/data-disks.json" "$WORK"
changes_after_confirm "mounted after confirmation" "$WORK/tmp-mounted.json" "mounted at /mnt/new"
changes_after_confirm "gained a filesystem after confirmation" "$WORK/tmp-signature.json" "now has signatures"
changes_after_confirm "different disk after confirmation" "$WORK/tmp-swapped.json" "no longer looks like"

reset_state
use_fixture data-disks
sandbox_pty "/dev/sdc" "$LOAD; D=/dev/sdc; disk_safety_confirm_wipe \$D || exit 41; disk_safety_wipe \$D || exit 42; disk_safety_wipe \$D || exit 43"
expect_rc "a confirmation is single-use" 43
if [[ "$("$BIN/grep" -c '^wipefs ' "$CALLS")" -eq 1 ]]; then
    pass "a confirmation is single-use: wiped once"
else
    fail "a confirmation is single-use: wiped more than once" "$("$BIN/cat" "$CALLS")"
fi

reset_state
use_fixture data-disks
STUB_WIPEFS_RC=1 sandbox_pty "/dev/sdc" "$LOAD; D=/dev/sdc; $CONFIRM_AND_WIPE"
expect_rc "wipefs failure stops" 42
expect_output "wipefs failure stops" "wipefs failed"
expect_no_output "wipefs failure stops" "^wiped"

echo
echo "--- Scan output"

reset_state
use_fixture data-disks
sandbox_bash "$LOAD; disk_safety_scan; echo ELIGIBLE: \"\${DISK_SAFETY_ELIGIBLE[*]}\""
expect_rc "scan" 0
expect_output "scan" "^ELIGIBLE: /dev/sdc /dev/sdd /dev/sde /dev/sdp$"
expect_output "scan shows model" "Model:  WD Red"
expect_output "scan shows serial" "Serial: WD-DATA1"
expect_output "scan shows size" "Size:   2T|Size:   16.4T"
expect_output "scan shows filesystem and label" "/dev/sdd1 +part +2T +ext4 +old-backup"
expect_output "scan explains refusals" "/dev/sda1 is mounted at /mnt/longhorn-disks/disk-sda"
expect_output "scan explains root" "/dev/nvme0n1 holds the root filesystem"
expect_no_writes "scan"

reset_state
use_fixture zfs-root
sandbox_bash "$LOAD; disk_safety_scan; echo ELIGIBLE: \"\${DISK_SAFETY_ELIGIBLE[*]}\""
expect_output "scan with unknown root offers nothing" "^ELIGIBLE: $"

reset_state
use_fixture data-disks
"$REAL_PYTHON" -I -c "
import json, sys
d = json.load(open(sys.argv[1]))
d['fail'] = {'lsblk': 1}
json.dump(d, open(sys.argv[1], 'w'))
" "$FAKE_FIXTURE"
sandbox_bash "$LOAD; disk_safety_scan"
expect_rc "scan when lsblk fails" 1

echo
echo "--- Reaching the disk through sudo and ssh"

reset_state
use_fixture data-disks
sandbox_pty "/dev/sdc" "$LOAD_SUDO; D=/dev/sdc; $CONFIRM_AND_WIPE"
expect_rc "sudo prefix" 0
expect_log "sudo prefix" '^wipefs -a /dev/sdc$'

reset_state
use_fixture data-disks
sandbox_pty "/dev/sdc" "source '$HELPER'; disk_safety_init 'ssh ops@10.0.0.5 sudo'; D=/dev/sdc; $CONFIRM_AND_WIPE"
expect_rc "ssh prefix keeps the typed answer" 0
expect_log "ssh prefix" '^ssh ops@10.0.0.5 sudo wipefs -a /dev/sdc$'
if "$BIN/grep" -q SSH_READ_TERMINAL "$CALLS"; then
    fail "ssh prefix: ssh was given the terminal, so it could swallow answers"
else
    pass "ssh prefix: ssh never gets the terminal"
fi

echo
echo "--- Data path checks"

check_path() {
    local path="$1" want="$2"
    use_fixture data-disks
    sandbox_bash "$LOAD; disk_safety_check_data_path '$path'"
    if [[ "$RC" -eq "$want" ]]; then
        pass "data path '$path': exit $want"
    else
        fail "data path '$path': expected exit $want, got $RC" "$OUT"
    fi
}

check_path /mnt/minio 0
check_path /data/minio 0
for path in / // /. /.. /mnt/../etc /mnt/./x relative /etc /boot /boot/efi /home /usr /var \
    /var/lib /var/lib/longhorn /var/lib/rancher/k3s /mnt/longhorn-disks /mnt/longhorn-disks/disk-sda \
    '/mnt/x y' '/mnt/x;id' ''; do
    check_path "$path" 1
done
STUB_MOUNTPOINT_RC=1 check_path /mnt/not-mounted 1

echo
echo "--- Installers use the helper (functions cut from the source; installers not run)"

LONGHORN="$REPO_ROOT/scripts/storage/longhorn/install-interactive.sh"
MINIO="$REPO_ROOT/scripts/storage/minio/install-minio.sh"

for file in "$LONGHORN" "$MINIO"; do
    short="${file#"$REPO_ROOT"/}"
    if "$BIN/grep" -q 'lib/disk-safety.sh' "$file"; then
        pass "$short loads the helper"
    else
        fail "$short doesn't load the helper"
    fi
    found="$("$BIN/grep" -nE '(wipefs|umount)' "$file" || true)"
    if [[ -z "$found" ]]; then
        pass "$short has no wipefs or umount of its own"
    else
        fail "$short calls wipefs or umount directly" "$found"
    fi
    found="$("$BIN/grep" -nE '\[[yY]/[nN]\]' "$file" | "$BIN/grep" -iE 'format|wipe|erase|disk|delete' || true)"
    if [[ -z "$found" ]]; then
        pass "$short has no y/N prompt for destructive steps"
    else
        fail "$short has a y/N prompt for a destructive step" "$found"
    fi
done

# Prints one function from a file, with /etc/fstab pointed into the sandbox.
extract_function() {
    "$BIN/awk" -v name="$2" '$0 ~ "^" name "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$1" \
        | "$BIN/sed" "s|/etc/fstab|$WORK/fstab|g"
}

LOG_FUNCS='log_info() { echo "INFO $*"; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERROR $*"; }; log_success() { echo "OK $*"; }'
: > "$WORK/fstab"

{
    echo "set -euo pipefail"
    echo "$LOG_FUNCS"
    echo "source '$HELPER'"
    echo "disk_safety_init sudo"
    echo "YELLOW=''; NC=''; LONGHORN_MOUNT_BASE=/mnt/longhorn-disks"
    echo "declare -a SELECTED_DISKS=(); declare -a AVAILABLE_DISKS=(); declare -a MOUNTED_DISKS=()"
    extract_function "$LONGHORN" detect_available_disks
    extract_function "$LONGHORN" handle_disk_selection
    extract_function "$LONGHORN" format_and_mount_disks
    echo 'handle_disk_selection'
    echo 'format_and_mount_disks'
    echo 'echo "SELECTED: ${SELECTED_DISKS[*]:-none}"'
} > "$WORK/longhorn-flow.sh"

longhorn_flow() {
    reset_state
    use_fixture data-disks
    sandbox_pty "$1" "source '$WORK/longhorn-flow.sh'"
}

# In the scan order of data-disks: 1=sdc 2=sdd 3=sde 4=sdp
longhorn_flow "1|/dev/sdc"
expect_rc "Longhorn: blank disk confirmed" 0
expect_log "Longhorn: blank disk confirmed" '^wipefs -a /dev/sdc$'
expect_log "Longhorn: blank disk confirmed" '^parted -s /dev/sdc mklabel gpt'
expect_log "Longhorn: blank disk confirmed" '^mkfs.ext4 -F /dev/sdc1$'
order="$("$BIN/grep" -E '^(wipefs|parted|mkfs.ext4|mount) ' "$CALLS" | "$BIN/cut" -d' ' -f1 | "$BIN/tr" '\n' ' ')"
if [[ "$order" == "wipefs parted mkfs.ext4 mount " ]]; then
    pass "Longhorn: wipe, partition, format, mount, in that order"
else
    fail "Longhorn: wrong order: $order"
fi

longhorn_flow "1|y"
expect_rc "Longhorn: answered y" 1
expect_no_writes "Longhorn: answered y"

# fstab: the mountpoint field is what counts. A longer path that starts the same must
# not stop the entry being written, and a stale one is replaced.
longhorn_flow "1|/dev/sdc"
expect_log "Longhorn: fstab goes through a stdin script" '^sudo bash -s -- abcd-1234 /mnt/longhorn-disks/disk-sdc$'
"$BIN/cat" > "$WORK/fstab" <<'EOF'
# UUID=commented /mnt/longhorn-disks/disk-sdc ext4 defaults 0 2
UUID=root-uuid / ext4 defaults 0 1
UUID=stale /mnt/longhorn-disks/disk-sdc ext4 defaults,nofail 0 2
UUID=keep /mnt/longhorn-disks/disk-sdc1 ext4 defaults,nofail 0 2
EOF
if "$BIN/grep" -q '/etc/fstab' "$WORK/sudo-bash-stdin.sh"; then
    echo "ABORT: the fstab script still names /etc/fstab. Nothing was run." >&2
    exit 2
fi
"$REAL_BASH" "$WORK/sudo-bash-stdin.sh" abcd-1234 /mnt/longhorn-disks/disk-sdc
fstab_now="$("$BIN/cat" "$WORK/fstab")"
want_fstab=$'# UUID=commented /mnt/longhorn-disks/disk-sdc ext4 defaults 0 2\nUUID=root-uuid / ext4 defaults 0 1\nUUID=keep /mnt/longhorn-disks/disk-sdc1 ext4 defaults,nofail 0 2\nUUID=abcd-1234  /mnt/longhorn-disks/disk-sdc  ext4  defaults,nofail  0  2'
if [[ "$fstab_now" == "$want_fstab" ]]; then
    pass "Longhorn: stale fstab entry replaced, a similar path and a comment kept"
else
    fail "Longhorn: wrong fstab result" "$fstab_now"
fi
: > "$WORK/fstab"

longhorn_flow "1,2|/dev/sdc|/dev/sdd|no"
expect_rc "Longhorn: second disk cancelled" 1
expect_output "Longhorn: second disk cancelled" "No disk was changed"
expect_no_writes "Longhorn: second disk cancelled leaves the first alone"

longhorn_flow "1,1,1|/dev/sdc"
expect_rc "Longhorn: repeated selection" 0
if [[ "$("$BIN/grep" -c '^wipefs ' "$CALLS")" -eq 1 ]]; then
    pass "Longhorn: repeated selection is wiped once"
else
    fail "Longhorn: repeated selection wiped more than once" "$("$BIN/cat" "$CALLS")"
fi

longhorn_flow "0"
expect_rc "Longhorn: OS disk chosen" 0
expect_output "Longhorn: OS disk chosen" "SELECTED: none"
expect_no_writes "Longhorn: OS disk chosen"

reset_state
use_fixture data-disks
sandbox_bash "source '$WORK/longhorn-flow.sh'"
expect_rc "Longhorn: no terminal" 0
expect_output "Longhorn: no terminal" "SELECTED: none"
expect_no_writes "Longhorn: no terminal"

reset_state
use_fixture data-disks
STUB_TEST_RC=1 sandbox_pty "1|/dev/sdc" "source '$WORK/longhorn-flow.sh'"
expect_rc "Longhorn: partition never appears" 1
expect_log "Longhorn: partition never appears" '^parted '
if "$BIN/grep" -q '^mkfs' "$CALLS"; then
    fail "Longhorn: formatted even though the partition is missing"
else
    pass "Longhorn: stops before formatting when the partition is missing"
fi

reset_state
use_fixture data-disks
STUB_WIPEFS_RC=1 sandbox_pty "1|/dev/sdc" "source '$WORK/longhorn-flow.sh'"
expect_rc "Longhorn: wipefs fails" 1
if "$BIN/grep" -qE '^(parted|mkfs)' "$CALLS"; then
    fail "Longhorn: carried on after wipefs failed" "$("$BIN/cat" "$CALLS")"
else
    pass "Longhorn: nothing runs after wipefs fails"
fi

{
    echo "set -euo pipefail"
    echo "$LOG_FUNCS"
    echo "source '$HELPER'"
    extract_function "$MINIO" format_and_mount_disk
} > "$WORK/minio-flow.sh"

minio_flow() {
    local prefix="$1" disk="$2"
    shift 2
    reset_state
    use_fixture data-disks
    sandbox_pty "$1" "source '$WORK/minio-flow.sh'; disk_safety_init '$prefix'; disk_safety_confirm_wipe $disk || exit 41; format_and_mount_disk $disk /mnt/minio '$prefix'"
}

minio_flow sudo /dev/sdc "/dev/sdc"
expect_rc "MinIO: blank disk confirmed" 0
expect_log "MinIO: blank disk confirmed" '^wipefs -a /dev/sdc$'
expect_log "MinIO: blank disk confirmed" '^mkfs.ext4 -F /dev/sdc1$'
expect_log "MinIO: blank disk confirmed" '^mount /dev/sdc1 /mnt/minio$'
expect_log "MinIO: fstab goes through a stdin script" '^sudo bash -s -- abcd-1234 /mnt/minio$'

# The recorded fstab script, run on a copy
"$BIN/cat" > "$WORK/fstab" <<'EOF'
UUID=root-uuid / ext4 defaults 0 1
UUID=old /mnt/minio ext4 defaults,nofail 0 2
UUID=keep /mnt/minio-archive ext4 defaults 0 2
EOF
# extract_function pointed the script at the sandbox. It must not run if that failed.
if "$BIN/grep" -q '/etc/fstab' "$WORK/sudo-bash-stdin.sh"; then
    echo "ABORT: the fstab script still names /etc/fstab. Nothing was run." >&2
    exit 2
fi
"$REAL_BASH" "$WORK/sudo-bash-stdin.sh" abcd-1234 /mnt/minio
fstab_now="$("$BIN/cat" "$WORK/fstab")"
want_fstab=$'UUID=root-uuid / ext4 defaults 0 1\nUUID=keep /mnt/minio-archive ext4 defaults 0 2\nUUID=abcd-1234 /mnt/minio ext4 defaults,nofail 0 2'
if [[ "$fstab_now" == "$want_fstab" ]]; then
    pass "MinIO: fstab entry replaced, and a similar path is kept"
else
    fail "MinIO: wrong fstab result" "$fstab_now"
fi

minio_flow sudo /dev/sdc "wrong"
expect_rc "MinIO: wrong name" 41
expect_no_writes "MinIO: wrong name"

minio_flow sudo /dev/sda "/dev/sda"
expect_rc "MinIO: mounted disk" 41
expect_no_writes "MinIO: mounted disk"

reset_state
use_fixture data-disks
sandbox_bash "source '$WORK/minio-flow.sh'; disk_safety_init sudo; disk_safety_confirm_wipe /dev/sdc || exit 41; format_and_mount_disk /dev/sdc /mnt/minio sudo"
expect_rc "MinIO: no terminal" 41
expect_no_writes "MinIO: no terminal"

# Skipping the confirmation has to fail too
reset_state
use_fixture data-disks
sandbox_bash "source '$WORK/minio-flow.sh'; disk_safety_init sudo; format_and_mount_disk /dev/sdc /mnt/minio sudo"
expect_rc "MinIO: format without confirmation" 1
expect_no_writes "MinIO: format without confirmation"

minio_flow "ssh ops@10.0.0.5 sudo" /dev/sdc "/dev/sdc"
expect_rc "MinIO: remote node" 0
expect_log "MinIO: remote node" '^ssh ops@10.0.0.5 sudo wipefs -a /dev/sdc$'

finish
