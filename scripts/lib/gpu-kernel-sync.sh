#!/bin/bash

###############################################################################
# MyNodeOne GPU <-> Kernel Sync
#
# Installed on GPU nodes as /usr/local/sbin/mynodeone-gpu-kernel-sync by
# scripts/lib/gpu-setup.sh (so users get it automatically when they install
# MyNodeOne on a node). Run daily + shortly after boot by
# mynodeone-gpu-kernel-sync.timer.
#
# WHY THIS EXISTS (real incident, Oct 2026)
# -----------------------------------------
# On Ubuntu, the NVIDIA driver is shipped as a PREBUILT, SIGNED kernel module
# package that is tied to one exact kernel build:
#
#     linux-modules-nvidia-580-open-7.0.0-34-generic     <- only loads on 7.0.0-34
#
# `unattended-upgrades` upgrades the kernel (linux-image-generic-hwe-24.04)
# on its own schedule. The matching nvidia module package is a separate
# package, and apt may keep it back ("held broken packages" / "kept back
# because a related package is kept back"). Result:
#
#   1. Kernel 7.0.0-34 installed automatically, nvidia module for -34 absent.
#   2. Node keeps running fine on the OLD kernel for days/weeks (the GPU still
#      works), so nobody notices.
#   3. The next reboot boots the NEW kernel -> `nvidia` module cannot load ->
#      `nvidia-smi` fails ("couldn't communicate with the NVIDIA driver").
#   4. Kubernetes: node reports nvidia.com/gpu: 0, nvidia-device-plugin goes
#      CrashLoopBackOff, GPU pods (vLLM) cannot schedule, and the GPU
#      disappears from the llmapi admin dashboard.
#
# A related failure: "Failed to initialize NVML: Driver/library version
# mismatch". This happens when the userspace NVIDIA libs (libnvidia-*,
# nvidia-utils) are upgraded while the OLD kernel module is still loaded.
# nvidia-container-toolkit injects the HOST's userspace libs into containers
# at container start, so containers then "don't see the nvidia drivers" until
# either the host reboots / reloads the module, or the container (pod) is
# restarted so it picks up the matching libs. Restart the device plugin and
# GPU pods after any driver change.
#
# WHAT THIS SCRIPT DOES
# ---------------------
#  1. HOLD  - holds the kernel meta-packages (linux-image-generic*,
#             linux-headers-generic*, linux-generic*) so unattended-upgrades
#             can never move the kernel ahead of the driver.
#             (Only when the prebuilt linux-modules-nvidia package flavour is
#             in use. DKMS-based drivers rebuild on kernel install, no hold.)
#  2. HEAL  - if the GPU exists but the driver is not working on the running
#             kernel and a matching module package is available, install it,
#             modprobe nvidia, and restart the device plugin.
#  3. UPGRADE - when apt offers a newer kernel AND the matching nvidia module
#             package for that SAME kernel build exists, temporarily unhold,
#             upgrade kernel + nvidia module together, and re-hold. The new
#             kernel is only activated on the next reboot (safe by default).
#
# Config: /etc/mynodeone/gpu-kernel.conf
#   GPU_KERNEL_AUTO_REBOOT=false   # true => reboot automatically after a
#                                  # synced kernel+driver upgrade. Default is
#                                  # false because a reboot interrupts every
#                                  # workload on the node (single-node
#                                  # clusters lose the control plane too).
#
# Usage: mynodeone-gpu-kernel-sync [--hold-only]
#
# Manual recovery if a node is already broken:
#   sudo apt install linux-modules-nvidia-<branch>-open-$(uname -r)
#   sudo modprobe nvidia && nvidia-smi
#   kubectl -n kube-system delete pod -l name=nvidia-device-plugin-ds
#
# NOTE: with Secure Boot enabled, only the Canonical-signed prebuilt modules
# will load; this is another reason to prefer linux-modules-nvidia-* over DKMS.
###############################################################################

set -uo pipefail

CONF=/etc/mynodeone/gpu-kernel.conf
GPU_KERNEL_AUTO_REBOOT=false
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

log() {
    echo "[$(date '+%F %T')] $*"
    logger -t mynodeone-gpu-kernel-sync -- "$*" 2>/dev/null || true
}

if [ "$EUID" -ne 0 ]; then
    echo "Must be run as root" >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    log "Not an apt-based system - nothing to do"
    exit 0
fi

# (capture first: `grep -q` + pipefail would SIGPIPE lspci and false-negative)
if [ -z "$(lspci 2>/dev/null | grep -i nvidia)" ]; then
    log "No NVIDIA GPU on this node - nothing to do"
    exit 0
fi

APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=600)
export DEBIAN_FRONTEND=noninteractive

# "7.0.0-34.34~24.04.1+1" -> "7.0.0-34"
kabi_of() { sed -nE 's/^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)\..*/\1/p' <<<"$1"; }
candidate() { apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'; }
installed_pkgs() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null | awk '$1 ~ /^[hi]i$/ {print $2}'; }  # "hi" = installed but held

# Kernel meta-packages that pull new kernels (not the versioned image packages)
mapfile -t KERNEL_METAS < <(installed_pkgs 'linux-image-generic*' 'linux-headers-generic*' 'linux-generic*')
# Nvidia module meta-packages, e.g. linux-modules-nvidia-580-open-generic-hwe-24.04
# (exclude versioned ones like linux-modules-nvidia-580-open-7.0.0-31-generic)
mapfile -t NVIDIA_METAS < <(installed_pkgs 'linux-modules-nvidia-*-generic' 'linux-modules-nvidia-*-generic-hwe-*' \
    | grep -vE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic')

if [ "${#NVIDIA_METAS[@]}" -eq 0 ]; then
    log "No prebuilt linux-modules-nvidia-* package installed (DKMS or custom driver) - kernel hold not needed"
    exit 0
fi

###############################################################################
# 1. HOLD
###############################################################################
hold_kernel() {
    [ "${#KERNEL_METAS[@]}" -eq 0 ] && return 0
    apt-mark hold "${KERNEL_METAS[@]}" >/dev/null
    log "Held kernel packages: ${KERNEL_METAS[*]}"
}

hold_kernel
[ "${1:-}" = "--hold-only" ] && exit 0

###############################################################################
# 2. HEAL: driver broken on the running kernel
###############################################################################
restart_device_plugin() {
    command -v kubectl >/dev/null 2>&1 || return 0
    local kc=/etc/rancher/k3s/k3s.yaml
    [ -r "$kc" ] || return 0   # worker nodes have no kubeconfig; kubelet restarts the pod itself
    KUBECONFIG="$kc" kubectl -n kube-system rollout restart ds/nvidia-device-plugin-daemonset >/dev/null 2>&1 \
        && log "Restarted nvidia-device-plugin so Kubernetes re-detects the GPU"
}

SMI_OUT=$(nvidia-smi 2>&1) && SMI_OK=true || SMI_OK=false
if [ "$SMI_OK" = false ]; then
    if grep -qi "version mismatch" <<<"$SMI_OUT"; then
        log "WARNING: NVIDIA driver/library version mismatch (userspace libs newer than loaded kernel module)."
        log "         Reboot this node, then restart GPU pods so containers pick up matching libs."
    else
        running=$(uname -r)
        for meta in "${NVIDIA_METAS[@]}"; do
            pkg="${meta%%-generic*}-${running}"
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                log "Driver not working on running kernel $running - installing $pkg"
                apt-get update -qq || true
                if apt-get install "${APT_OPTS[@]}" "$pkg" && modprobe nvidia && nvidia-smi >/dev/null 2>&1; then
                    log "Healed: GPU driver now working on $running"
                    restart_device_plugin
                else
                    log "ERROR: could not load nvidia module for $running (Secure Boot? try a reboot)"
                fi
                break
            else
                log "ERROR: no module package '$pkg' available for running kernel $running"
            fi
        done
    fi
fi

###############################################################################
# 3. UPGRADE kernel + driver together, only when they are available together
###############################################################################
[ "${#KERNEL_METAS[@]}" -eq 0 ] && exit 0
apt-get update -qq || true

kimg=$(printf '%s\n' "${KERNEL_METAS[@]}" | grep '^linux-image-generic' | head -1)
[ -z "$kimg" ] && exit 0
k_installed=$(kabi_of "$(dpkg-query -W -f='${Version}' "$kimg" 2>/dev/null)")
k_candidate=$(kabi_of "$(candidate "$kimg")")

if [ -z "$k_candidate" ] || [ "$k_candidate" = "$k_installed" ]; then
    log "Kernel up to date ($k_installed) - nothing to upgrade"
    exit 0
fi

for meta in "${NVIDIA_METAS[@]}"; do
    n_candidate=$(kabi_of "$(candidate "$meta")")
    versioned="${meta%%-generic*}-${k_candidate}-generic"
    if [ "$n_candidate" != "$k_candidate" ] || ! apt-cache show "$versioned" >/dev/null 2>&1; then
        log "Kernel $k_candidate available but NVIDIA module for it is not ($meta candidate: ${n_candidate:-none}) - staying on $k_installed"
        exit 0
    fi
done

log "Kernel $k_candidate and matching NVIDIA module both available - upgrading together (from $k_installed)"
apt-mark unhold "${KERNEL_METAS[@]}" >/dev/null
if apt-get install "${APT_OPTS[@]}" "${KERNEL_METAS[@]}" "${NVIDIA_METAS[@]}"; then
    log "Upgraded to kernel $k_candidate with matching NVIDIA module (active after reboot)"
    UPGRADED=true
else
    log "ERROR: synced kernel/driver upgrade failed"
    UPGRADED=false
fi
hold_kernel

if [ "$UPGRADED" = true ]; then
    if [ "$GPU_KERNEL_AUTO_REBOOT" = true ]; then
        log "GPU_KERNEL_AUTO_REBOOT=true - rebooting in 1 minute"
        shutdown -r +1 "MyNodeOne: rebooting into kernel $k_candidate with matching NVIDIA driver"
    else
        log "Reboot when convenient to activate kernel $k_candidate (set GPU_KERNEL_AUTO_REBOOT=true in $CONF to automate)"
    fi
fi
