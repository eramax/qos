#!/usr/bin/env bash
# build-iso.sh — build a bootable QOS live ISO
#
# Strategy: create a small FAT "ESP image" containing BOOTX64.EFI,
# limine.conf, vmlinuz, and initramfs-live.img.  This FAT image is
# embedded as the El Torito EFI boot entry in the ISO.  OVMF loads it,
# finds BOOTX64.EFI, and Limine boots from the FAT volume.
#
# The live initramfs has the full rootfs baked in — no iso9660 kernel
# support needed, no CDROM mount required.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/common.sh"

root="$(repo_root)"
boot_dir="${BOOT_STAGE_DIR:-$root/build/boot}"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
iso_output_dir="${ISO_OUTPUT_DIR:-$root/dist}"
iso_name="${ISO_NAME:-qos-x86_64.iso}"
limine_cache_dir="${LIMINE_CACHE_DIR:-$root/build/cache/limine}"
iso_build_dir="${ISO_BUILD_DIR:-$root/build/iso}"

[[ -d "$boot_dir" ]]         || die "missing boot staging dir: $boot_dir"
[[ -f "$boot_dir/vmlinuz" ]] || die "missing kernel: $boot_dir/vmlinuz"
[[ -d "$rootfs" ]]           || die "missing rootfs: $rootfs"

mkdir -p "$iso_output_dir" "$limine_cache_dir" "$iso_build_dir"

if [[ "${ISO_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock ISO image" > "$iso_output_dir/$iso_name"
  echo "ISO build skipped (mock mode)"
  exit 0
fi

require_cmd xorriso cpio lz4 busybox mtools mksquashfs

# ── Limine EFI binary ────────────────────────────────────────────────────────
limine_src="$limine_cache_dir/limine"
if [[ ! -d "$limine_src/.git" ]]; then
  branch="$(tr -d '[:space:]' < "$root/config/limine/branch")"
  echo "Cloning Limine (branch: $branch)..."
  git clone --depth 1 --branch "$branch" \
    https://github.com/limine-bootloader/limine.git "$limine_src" >/dev/null 2>&1
fi

limine_efi=""
for _c in "$limine_src/BOOTX64.EFI" "$limine_src/limine-uefi-cd.bin"; do
  [[ -f "$_c" ]] && limine_efi="$_c" && break
done
[[ -n "$limine_efi" ]] || die "cannot find Limine EFI binary in $limine_src"

# ── Build squashfs of the rootfs (separate from initramfs) ──────────────────
# The rootfs is shipped as a standalone rootfs.sfs file on the ESP, loop-
# mounted at boot by the live initramfs. This keeps the initramfs small
# (~20 MB) regardless of profile, so Limine can deliver it to the kernel
# without hitting EFI memory-map limits.
echo "Building rootfs.sfs (squashfs)..."
rootfs_sfs="$iso_build_dir/rootfs.sfs"
rm -f "$rootfs_sfs"

# Embed disk-boot artifacts for qos-install BEFORE squashing.
boot_payload="$rootfs/var/lib/qos/boot"
mkdir -p "$boot_payload"
cp "$limine_efi"                    "$boot_payload/BOOTX64.EFI"
cp "$boot_dir/vmlinuz"              "$boot_payload/vmlinuz"
cp "$boot_dir/initramfs.img"        "$boot_payload/initramfs.img"
cat > "$boot_payload/limine.conf" <<'DISKLIMINE'
timeout: 0
verbose: yes
default_entry: 1
interface_branding: QOS via Limine
interface_branding_colour: 6

/QOS
    protocol: linux
    kernel_path: boot():/vmlinuz
    module_path: boot():/initramfs.img
    cmdline: root=LABEL=qos-root-a rootfstype=ext4 rootwait ro console=tty0 console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 loglevel=7 ignore_loglevel net.ifnames=0 biosdevname=0
DISKLIMINE
echo "  Boot payload staged: $(du -sh "$boot_payload" | awk '{print $1}')"

mksquashfs "$rootfs" "$rootfs_sfs" \
    -comp zstd -Xcompression-level 19 \
    -noappend -no-progress -quiet
echo "  rootfs.sfs: $(du -sh "$rootfs_sfs" | awk '{print $1}')"

# ── Build minimal live initramfs (mounts rootfs.sfs from ESP) ───────────────
echo "Building live initramfs (minimal, no rootfs baked in)..."

live_stage="$iso_build_dir/live-initramfs"
chmod -R u+w "$live_stage" 2>/dev/null || true
rm -rf "$live_stage"
mkdir -p "$live_stage/bin" "$live_stage/dev" "$live_stage/proc" \
         "$live_stage/sys" "$live_stage/run" "$live_stage/sysroot" \
         "$live_stage/mnt/esp" "$live_stage/mnt/rootfs"

host_busybox="/usr/bin/busybox"
[[ -x "$host_busybox" ]] || die "missing host busybox: $host_busybox"
cp "$host_busybox" "$live_stage/bin/busybox"
chmod 0755 "$live_stage/bin/busybox"
while IFS= read -r applet; do
  [[ "$applet" == "busybox" ]] && continue
  ln -sf busybox "$live_stage/bin/$applet"
done < <("$live_stage/bin/busybox" --list)

cat > "$live_stage/init" <<'LIVE_INIT'
#!/bin/sh
# Live CD init — minimal. Finds the FAT ESP, loop-mounts rootfs.sfs
# from it, overlays a tmpfs upper for writability, switch_root.
PATH=/bin
exec >/dev/console 2>&1
echo "[live-init] QOS Live CD starting..."

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run

# Scan block devices for a filesystem containing rootfs.sfs.
echo "[live-init] Searching for rootfs.sfs..."
echo "[live-init] kernel cmdline: $(cat /proc/cmdline)"

source_dev=""
source_fs=""

probe() {
    dev="$1"; fstype="$2"
    [ -b "$dev" ] || return 1
    mount -t "$fstype" -o ro "$dev" /mnt/esp 2>/dev/null || return 1
    if [ -f /mnt/esp/rootfs.sfs ]; then
        source_dev="$dev"
        source_fs="$fstype"
        return 0
    fi
    umount /mnt/esp 2>/dev/null
    return 1
}

# Nudge the kernel to (re)scan SCSI buses in case the CD wasn't enumerated
# by the time userspace started. Harmless on systems without SCSI.
for host in /sys/class/scsi_host/host*/scan; do
    [ -w "$host" ] && echo '- - -' > "$host" 2>/dev/null
done

scan_once() {
    # 1) Optical (ISO/CD) — most likely target on `make live`.
    for p in /dev/sr0 /dev/sr1 /dev/sr2; do
        probe "$p" iso9660 && return 0
    done
    # 2) Any block dev that LOOKS like it might be iso9660 (some virt
    # CDs end up as /dev/scd0 or similar).
    for p in /dev/scd* /dev/cdrom*; do
        probe "$p" iso9660 && return 0
    done
    # 3) Labeled FAT.
    for blk in /dev/disk/by-label/QOS-EFI /dev/disk/by-label/qos-efi; do
        [ -e "$blk" ] && probe "$(readlink -f "$blk")" vfat && return 0
    done
    # 4) Any vfat partition (USB stick).
    for p in /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*p[0-9]*; do
        probe "$p" vfat && return 0
    done
    # 5) ext4 fallback (installed-disk recovery).
    for p in /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*p[0-9]*; do
        probe "$p" ext4 && return 0
    done
    return 1
}

# Poll up to ~45s for slow buses to enumerate.
attempts=0
for wait in 0 1 1 1 2 2 2 3 3 5 5 5 5 5; do
    attempts=$((attempts + 1))
    [ "$wait" -gt 0 ] && sleep "$wait"
    if scan_once; then
        break
    fi
    sr_present="no"; [ -b /dev/sr0 ] && sr_present="yes"
    echo "[live-init]   attempt $attempts: sr0=$sr_present, $(ls /dev/sr* /dev/sd* /dev/vd* /dev/nvme* 2>/dev/null | tr '\n' ' ')"
done

if [ -z "$source_dev" ]; then
    echo "[live-init] FATAL: rootfs.sfs not found on any device"
    echo "[live-init] /proc/partitions:"
    cat /proc/partitions
    echo "[live-init] /sys/class/block:"
    ls /sys/class/block/ 2>/dev/null
    echo "[live-init] PCI devices:"
    cat /proc/bus/pci/devices 2>/dev/null | awk '{print $1, $2}' | head -20
    echo "[live-init] kernel modules loaded:"
    cat /proc/modules 2>/dev/null | awk '{print $1}'
    exec sh
fi
echo "[live-init] rootfs source: $source_dev ($source_fs)"

echo "[live-init] Mounting rootfs.sfs (squashfs, read-only)..."
mount -t squashfs -o loop,ro /mnt/esp/rootfs.sfs /mnt/rootfs \
  || { echo "[live-init] FATAL: squashfs mount"; exec sh; }

# Overlay a tmpfs upper so the live system is writable.
mkdir -p /run/overlay/upper /run/overlay/work
mount -t tmpfs -o size=512M,mode=0755 tmpfs /run/overlay || true
mkdir -p /run/overlay/upper /run/overlay/work
mount -t overlay overlay \
    -o lowerdir=/mnt/rootfs,upperdir=/run/overlay/upper,workdir=/run/overlay/work \
    /sysroot \
  || { echo "[live-init] FATAL: overlay mount"; exec sh; }

echo "qos-live" > /sysroot/etc/hostname 2>/dev/null
echo "qos-live" > /proc/sys/kernel/hostname 2>/dev/null
mkdir -p /sysroot/etc/qos
echo "live-cdrom" > /sysroot/etc/qos/boot-source

echo "[live-init] Mounting essential filesystems..."
mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev /sysroot/run /sysroot/tmp
mount -t proc     proc     /sysroot/proc
mount -t sysfs    sysfs    /sysroot/sys
mkdir -p /sysroot/sys/fs/cgroup
mount -t cgroup2  cgroup2  /sysroot/sys/fs/cgroup 2>/dev/null
if [ -w /sysroot/sys/fs/cgroup/cgroup.subtree_control ]; then
  echo '+cpuset +cpu +memory +pids' \
    > /sysroot/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
fi
mount -t devtmpfs devtmpfs /sysroot/dev
mkdir -p /sysroot/dev/pts
mount -t devpts   devpts   /sysroot/dev/pts 2>/dev/null
mount -t tmpfs    tmpfs    /sysroot/run
mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs /sysroot/tmp

echo "[live-init] Switching to live rootfs..."
exec switch_root /sysroot /sbin/init
LIVE_INIT
chmod 0755 "$live_stage/init"

live_initramfs="$iso_build_dir/initramfs-live.img"
( cd "$live_stage" && find . -print0 | cpio --null -o -H newc ) \
  | lz4 -l -z -q -c > "$live_initramfs"
echo "  initramfs-live.img: $(du -sh "$live_initramfs" | awk '{print $1}')"

# ── Build EFI System Partition (FAT) image ───────────────────────────────────
#
# OVMF requires a FAT ESP for El Torito EFI boot.  We create one that
# contains EVERYTHING Limine needs: BOOTX64.EFI, limine.conf, vmlinuz,
# and the live initramfs.  This way boot() = the FAT volume, and all
# paths in limine.conf resolve correctly.
#
echo "Creating EFI System Partition image..."

# Size dynamically from the actual payload so image growth (for example
# cloud-init or other rootfs additions) does not overflow the FAT ESP.
limine_size_kib="$(du -k "$limine_efi" | awk '{print $1}')"
kernel_size_kib="$(du -k "$boot_dir/vmlinuz" | awk '{print $1}')"
live_initramfs_size_kib="$(du -k "$live_initramfs" | awk '{print $1}')"
limine_conf_size_kib=4
# FAT32 with modest headroom. The ESP only carries the kernel + tiny
# live initramfs + Limine + its config; rootfs.sfs lives in the iso9660
# layer alongside.
esp_overhead_kib=$((16 * 1024))
esp_size_kib=$((limine_size_kib + kernel_size_kib + live_initramfs_size_kib + limine_conf_size_kib + esp_overhead_kib))
esp_size_mib=$(((esp_size_kib + 1023) / 1024))
if [[ "$esp_size_mib" -lt 64 ]]; then
  esp_size_mib=64
fi
esp_img="$iso_build_dir/efi.img"
truncate -s "${esp_size_mib}M" "$esp_img"
mkfs.vfat -F 32 -n QOS-EFI "$esp_img" >/dev/null

# Populate ESP
mmd -i "$esp_img" ::/EFI ::/EFI/BOOT
mcopy -i "$esp_img" "$limine_efi"                ::/EFI/BOOT/BOOTX64.EFI

# limine.conf — boot() = this FAT ESP, so paths are relative to it
cat > "$iso_build_dir/limine-live.conf" <<'EOF'
timeout: 0
verbose: yes
default_entry: 1
interface_branding: QOS Live via Limine
interface_branding_colour: 6

/QOS Live CD
    protocol: linux
    kernel_path: boot():/vmlinuz
    module_path: boot():/initramfs-live.img
    cmdline: console=tty0 console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 loglevel=7 net.ifnames=0 biosdevname=0
EOF
mcopy -i "$esp_img" "$iso_build_dir/limine-live.conf" ::/limine.conf
mcopy -i "$esp_img" "$boot_dir/vmlinuz"               ::/vmlinuz
mcopy -i "$esp_img" "$live_initramfs"                  ::/initramfs-live.img
# rootfs.sfs is placed in the iso9660 layer (see below), not in the ESP.
# Keeps the ESP small and the squashfs reachable via /dev/sr0 from Linux.

echo "  ESP image: $(du -sh "$esp_img" | awk '{print $1}') (payload sized)"

# ── Create ISO ────────────────────────────────────────────────────────────────
iso_root="$iso_build_dir/iso-root"
chmod -R u+w "$iso_root" 2>/dev/null || true
rm -rf "$iso_root"
mkdir -p "$iso_root"

# Put the ESP image at the ISO root; xorriso uses it as the EFI boot entry.
cp "$esp_img" "$iso_root/efi.img"
# Place rootfs.sfs in the iso9660 layer so live-init can find it via
# /dev/sr0 once Linux is up. The ESP is only consumed by the firmware
# during boot, not by Linux.
cp "$rootfs_sfs" "$iso_root/rootfs.sfs"

echo "Creating ISO..."
xorriso -as mkisofs \
  -o "$iso_output_dir/$iso_name" \
  -V "QOS_LIVE" \
  --efi-boot efi.img \
  -efi-boot-part --efi-boot-image \
  -no-emul-boot \
  "$iso_root"

echo ""
echo "✅ ISO: $iso_output_dir/$iso_name ($(du -sh "$iso_output_dir/$iso_name" | awk '{print $1}'))"
echo ""
echo "  make live                        # boot live ISO (/dev/vda = install target)"
echo "  qos-install --auto /dev/vda      # inside VM"
echo "  poweroff && make qemu            # boot installed system"
