#!/usr/bin/env bash
# jetflash.sh — one-shot Jetson Orin Nano flasher (JetPack 6 / Ubuntu 22.04).
#
# Plug in a Jetson Orin Nano in recovery mode and this script detects it and
# wipes its NVMe SSD and flashes Ubuntu 22.04 to it. The NVIDIA BSP is downloaded and
# prepared into /workspace on the first run and reused afterwards (FRESH=1 redoes it).
#
# Usage: jetflash.sh [nvme|sd|usb] [board-config]
#   target default: nvme (the M.2 SSD on the Orin Nano dev kit)
#   board  default: jetson-orin-nano-devkit-super
# Env:
#   L4T_VERSION=36.5.2               Jetson Linux release (36.5.2 = JetPack 6.2.3, Ubuntu 22.04)
#   JETSON_USER / JETSON_PASS        optional: pre-create a user on the Jetson (skips first-boot wizard)
#   JETSON_HOST=jetson               hostname used with JETSON_USER
#   FRESH=1                          re-download and re-prepare the BSP from scratch
#   LOOP=1                           keep waiting and flash the next Jetson too
set -euo pipefail

# The container's default user is non-root; flashing needs root.
[ "$(id -u)" = 0 ] || exec sudo -E "$0" "$@"

TARGET="${1:-nvme}"
BOARD="${2:-jetson-orin-nano-devkit-super}"
VER="${L4T_VERSION:-36.5.2}"
L4T="/workspace/r${VER}/Linux_for_Tegra"

case "$TARGET" in
    nvme) DEV=nvme0n1p1 ;;
    sd)   DEV=mmcblk0p1 ;;
    usb)  DEV=sda1 ;;
    *) echo "Unknown target '$TARGET' (nvme|sd|usb)"; exit 1 ;;
esac

# ---------------------------------------------------------------- environment
init_env() {
    # qemu-aarch64 lets apply_binaries.sh chroot into the arm64 rootfs.
    [ -e /proc/sys/fs/binfmt_misc/register ] || \
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || update-binfmts --enable qemu-aarch64 2>/dev/null || \
        echo "WARN: could not register qemu-aarch64 binfmt."

    # NFS server is used by l4t_initrd_flash.sh --network usb0.
    grep -qw nfsd /proc/filesystems || modprobe nfsd 2>/dev/null || true
    grep -qw nfsd /proc/filesystems || {
        echo "ERROR: host kernel has no nfsd. Run 'sudo modprobe nfsd' on the HOST and retry."; exit 1; }
}

# Only one jetflash may run at a time: a second run would wipe this run's files,
# and both would fight over the host's RPC/NFS ports (host networking).
single_instance() {
    exec 9>/workspace/.jetflash.lock
    flock -n 9 || {
        echo "ERROR: another jetflash run is already active. Stop it first:"
        echo "       docker ps --filter name=jetflash   then   docker stop <name>"
        exit 1; }
    if ss -lntH 'sport = :111' | grep -q . && ! pgrep -x rpcbind >/dev/null; then
        echo "ERROR: port 111 (rpcbind) is already used on the host by something else"
        echo "       (another jetflash container, or the host's own rpcbind/NFS server)."
        echo "       Stop it (e.g. 'sudo systemctl stop rpcbind rpcbind.socket nfs-server') and retry."
        exit 1
    fi
}

# Start a clean rpcbind and check it answers. NVIDIA's flash tool then writes
# /etc/exports and (re)starts nfs-kernel-server itself.
start_rpc() {
    service nfs-kernel-server stop >/dev/null 2>&1 || true
    rpc.nfsd 0 2>/dev/null || true
    pkill -x rpcbind 2>/dev/null || true
    rm -f /run/rpcbind.lock /run/rpcbind/* 2>/dev/null || true
    sleep 1
    rpcbind -w
    for _ in 1 2 3 4 5; do rpcinfo -p localhost >/dev/null 2>&1 && return 0; sleep 1; done
    echo "ERROR: rpcbind is not answering on localhost:111."; exit 1
}

# Stop NFS on exit so no kernel nfsd / exports are left running on the host.
stop_nfs() {
    exportfs -ua 2>/dev/null || true
    service nfs-kernel-server stop >/dev/null 2>&1 || true
    rpc.nfsd 0 2>/dev/null || true
    pkill -x rpcbind 2>/dev/null || true
}

# ---------------------------------------------------------------- BSP setup
setup_bsp() {
    # Reuse an already-prepared BSP unless FRESH=1. The stamp is only written
    # after a complete setup, so a half-finished one is always redone.
    if [ "${FRESH:-0}" != 1 ] && [ -f "/workspace/r${VER}/.ready" ]; then
        echo ">> Reusing prepared BSP at $L4T (set FRESH=1 to re-download)"
        [ -n "${JETSON_USER:-}" ] && echo "   Note: JETSON_USER only applies when the BSP is prepared; use FRESH=1 to change it."
        return 0
    fi

    local major="${VER%%.*}" rest="${VER#*.}" minor patch base bsp rootfs
    minor="${rest%%.*}"; patch="${rest#*.}"; [ "$patch" = "$rest" ] && patch=0
    base="https://developer.nvidia.com/downloads/embedded/l4t/r${major}_release_v${minor}.${patch}"
    bsp="Jetson_Linux_r${VER}_aarch64.tbz2"
    rootfs="Tegra_Linux_Sample-Root-Filesystem_r${VER}_aarch64.tbz2"

    echo ">> Preparing BSP from scratch (removing previous downloads and BSP)"
    rm -rf /workspace/downloads "/workspace/r${VER}"
    mkdir -p /workspace/downloads "/workspace/r${VER}"
    for f in "$bsp" "$rootfs"; do
        # NVIDIA uses .../release/ for some versions and .../releases/ for others.
        wget -O "/workspace/downloads/$f" "$base/releases/$f" || \
        wget -O "/workspace/downloads/$f" "$base/release/$f" || {
            rm -f "/workspace/downloads/$f"; echo "ERROR: could not download $f"; exit 1; }
    done

    echo ">> Extracting BSP + Ubuntu 22.04 rootfs (takes a while)"
    tar -xpf "/workspace/downloads/$bsp" -C "/workspace/r${VER}"
    tar -xpf "/workspace/downloads/$rootfs" -C "$L4T/rootfs" --use-compress-program=lbzip2

    cd "$L4T"
    ./tools/l4t_flash_prerequisites.sh || true
    ./apply_binaries.sh
    if [ -n "${JETSON_USER:-}" ] && [ -n "${JETSON_PASS:-}" ]; then
        ./tools/l4t_create_default_user.sh -u "$JETSON_USER" -p "$JETSON_PASS" \
            -n "${JETSON_HOST:-jetson}" --accept-license
    fi
    touch "/workspace/r${VER}/.ready"
    echo ">> BSP ready at $L4T"
}

# ---------------------------------------------------------------- detection
# NVIDIA recovery-mode USB IDs (Orin NX / Orin Nano, p3767 modules):
#   0955:7323 = Orin NX 16GB   0955:7423 = Orin NX 8GB
#   0955:7523 = Orin Nano 8GB  0955:7623 = Orin Nano 4GB
find_jetson() { lsusb | grep -oiE '0955:7[3-6]23' | head -1 || true; }

wait_for_jetson() {
    local id
    echo ">> Waiting for a Jetson Orin Nano / Orin NX in recovery mode (FC REC jumpered to GND, USB-C connected)..."
    until id="$(find_jetson)"; [ -n "$id" ]; do sleep 1; done
    case "${id,,}" in
        0955:7323) echo ">> Detected Jetson Orin NX 16GB ($id)" ;;
        0955:7423) echo ">> Detected Jetson Orin NX 8GB ($id)" ;;
        0955:7523) echo ">> Detected Jetson Orin Nano 8GB ($id)" ;;
        0955:7623) echo ">> Detected Jetson Orin Nano 4GB ($id)" ;;
    esac
}

wait_for_unplug() {
    echo ">> Remove the recovery jumper. Waiting for the Jetson to leave recovery mode..."
    while [ -n "$(find_jetson)" ]; do sleep 1; done
}

# ---------------------------------------------------------------- flash
flash_once() {
    cd "$L4T"
    echo ">> Flashing $BOARD -> $DEV (L4T R$VER)"
    echo ">> WARNING: the Jetson's ${TARGET^^} drive will be COMPLETELY WIPED (all partitions and data)."
    ./tools/kernel_flash/l4t_initrd_flash.sh \
        --external-device "$DEV" \
        -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
        -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
        --erase-all \
        --showlogs --network usb0 \
        "$BOARD" internal
}

# ---------------------------------------------------------------- main
init_env
single_instance
trap stop_nfs EXIT
setup_bsp
while true; do
    wait_for_jetson
    start_rpc
    if flash_once; then
        echo ">> Flash complete. Remove the jumper and power-cycle the Jetson."
        [ "${LOOP:-0}" = 1 ] || exit 0
    else
        echo "!! Flash failed (see log above)."
        [ "${LOOP:-0}" = 1 ] || exit 1
    fi
    wait_for_unplug
done
