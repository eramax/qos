#!/usr/bin/env bash
# build-iso.sh — build a bootable QOS live ISO
#
# Strategy: create a small FAT "ESP image" containing BOOTX64.EFI,
# limine.conf, vmlinuz, and initramfs-live.img.  This FAT image is
# embedded as the El Torito EFI boot entry in the ISO.  OVMF loads it,
# finds BOOTX64.EFI, and Limine boots from the FAT volume.
#
# The live initramfs stays small and mounts rootfs.sfs from the runtime
# ISO device that QEMU exposes separately as a plain block disk.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../../lib/common.sh"

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
  branch="$(tr -d '[:space:]' < "$root/builder/pipeline/04-limine/branch")"
  echo "Cloning Limine (branch: $branch)..."
  git clone --depth 1 --branch "$branch" \
    https://github.com/limine-bootloader/limine.git "$limine_src" >/dev/null 2>&1
fi

limine_efi=""
for _c in "$limine_src/BOOTX64.EFI" "$limine_src/limine-uefi-cd.bin"; do
  [[ -f "$_c" ]] && limine_efi="$_c" && break
done
[[ -n "$limine_efi" ]] || die "cannot find Limine EFI binary in $limine_src"

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

# ── Build squashfs payload for the live rootfs ───────────────────────────────
echo "Building rootfs.sfs (squashfs)..."
rootfs_sfs="$iso_build_dir/rootfs.sfs"
rm -f "$rootfs_sfs"
mksquashfs "$rootfs" "$rootfs_sfs" \
  -comp zstd -Xcompression-level 19 \
  -noappend -no-progress -quiet
echo "  rootfs.sfs: $(du -sh "$rootfs_sfs" | awk '{print $1}')"

# ── Build small live initramfs ───────────────────────────────────────────────
echo "Building live initramfs (static early userspace)..."

live_stage="$iso_build_dir/live-initramfs"
chmod -R u+w "$live_stage" 2>/dev/null || true
rm -rf "$live_stage"
mkdir -p "$live_stage/bin" "$live_stage/dev" "$live_stage/proc" \
         "$live_stage/sys" "$live_stage/run" "$live_stage/sysroot" \
         "$live_stage/mnt/live"

host_busybox="/usr/bin/busybox"
[[ -x "$host_busybox" ]] || die "missing host busybox: $host_busybox"
cp "$host_busybox" "$live_stage/bin/busybox"
chmod 0755 "$live_stage/bin/busybox"
while IFS= read -r applet; do
  [[ "$applet" == "busybox" ]] && continue
  ln -sf busybox "$live_stage/bin/$applet"
done < <("$live_stage/bin/busybox" --list)

cat > "$live_stage/init" <<'LIVE_INIT'
#!/bin/busybox sh
# Live CD init — static early userspace. The full rootfs is stored as
# rootfs.sfs on the runtime ISO device that QEMU also exposes as a
# separate read-only block disk.
PATH=/bin
exec >/dev/console 2>&1
echo "[live-init] QOS Live CD starting..."

mount -t proc proc /proc || { echo "[live-init] FATAL: proc mount failed"; exec sh; }
mount -t sysfs sysfs /sys || { echo "[live-init] FATAL: sysfs mount failed"; exec sh; }
mount -t devtmpfs devtmpfs /dev || { echo "[live-init] FATAL: devtmpfs mount failed"; exec sh; }
mount -t tmpfs tmpfs /run || { echo "[live-init] FATAL: tmpfs mount failed"; exec sh; }
echo "[live-init] kernel cmdline: $(cat /proc/cmdline)"

echo "[live-init] Searching for rootfs.sfs..."
live_dev=""
ls -l /dev/sr0 2>/dev/null || true
for dev in /dev/sr0 /dev/vd* /dev/sd* /dev/sr* /dev/nvme*n*; do
  [ -b "$dev" ] || continue
  if mount -t iso9660 -o ro "$dev" /mnt/live 2>/dev/null; then
    if [ -f /mnt/live/rootfs.sfs ]; then
      live_dev="$dev"
      break
    fi
    umount /mnt/live 2>/dev/null || true
  fi
done

if [ -z "$live_dev" ]; then
  echo "[live-init] FATAL: rootfs.sfs not found on any runtime block device"
  echo "[live-init] /proc/partitions:"
  cat /proc/partitions
  exec sh
fi

echo "[live-init] runtime ISO device: $live_dev"
echo "[live-init] Mounting rootfs.sfs..."
mkdir -p /ro-root
mount -t squashfs -o loop,ro /mnt/live/rootfs.sfs /ro-root \
  || { echo "[live-init] FATAL: squashfs mount failed"; exec sh; }

mkdir -p /run/overlay/upper /run/overlay/work /sysroot
mount -t overlay overlay \
  -o lowerdir=/ro-root,upperdir=/run/overlay/upper,workdir=/run/overlay/work \
  /sysroot || { echo "[live-init] FATAL: overlay mount failed"; exec sh; }

mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev /sysroot/dev/pts /sysroot/run /sysroot/tmp

# Make /etc and /etc/qos writable in the overlay so we can stamp the
# live-boot identity and disable cloud-init.
chmod u+w /sysroot/etc 2>/dev/null || true
echo "qos-live" > /sysroot/etc/hostname
echo "qos-live" > /proc/sys/kernel/hostname 2>/dev/null
mkdir -p /sysroot/etc/qos
echo "live-cdrom" > /sysroot/etc/qos/boot-source

# Fully disable cloud-init on live CD — no cloud datasource is present
# and its OpenRC-style commands produce noise under s6.  The kernel
# cmdline cloud-init=off is the canonical disable; we also stamp the
# file-based override for belt-and-suspenders.
chmod u+w /sysroot/etc/cloud 2>/dev/null || true
mkdir -p /sysroot/etc/cloud/cloud.cfg.d
echo "datasource_list: [ None ]" > /sysroot/etc/cloud/cloud.cfg.d/99-qos-live-disable.cfg
touch /sysroot/etc/cloud-init.disabled

echo "[live-init] Mounting essential filesystems..."
mkdir -p /sysroot/sys/fs/cgroup /sysroot/dev/pts
mount -t proc proc /sysroot/proc
mount -t sysfs sysfs /sysroot/sys
mount -t devtmpfs devtmpfs /sysroot/dev
mount -t cgroup2 cgroup2 /sysroot/sys/fs/cgroup 2>/dev/null
if [ -w /sysroot/sys/fs/cgroup/cgroup.subtree_control ]; then
  echo '+cpuset +cpu +memory +pids' \
    > /sysroot/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
fi
mkdir -p /sysroot/dev/pts /sysroot/dev/shm
mount -t devpts devpts /sysroot/dev/pts 2>/dev/null
mount -t tmpfs tmpfs /sysroot/dev/shm
chmod 666 /sysroot/dev/null 2>/dev/null || true
mount -t tmpfs tmpfs /sysroot/run
mount -t tmpfs tmpfs /sysroot/tmp -o nosuid,nodev,mode=1777 2>/dev/null || true

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
# FAT32 with modest headroom. The ESP carries the kernel, the small live
# initramfs, Limine, and its config. rootfs.sfs stays in the ISO payload.
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
    cmdline: rdinit=/init cloud-init=off video=Virtual-1:1920x1080@60 console=tty0 console=ttyS0,115200n8 earlycon=uart,io,0x3f8,115200n8 loglevel=7 net.ifnames=0 biosdevname=0
EOF
mcopy -i "$esp_img" "$iso_build_dir/limine-live.conf" ::/limine.conf
mcopy -i "$esp_img" "$boot_dir/vmlinuz"               ::/vmlinuz
mcopy -i "$esp_img" "$live_initramfs"                  ::/initramfs-live.img

echo "  ESP image: $(du -sh "$esp_img" | awk '{print $1}') (payload sized)"

# ── Create ISO ────────────────────────────────────────────────────────────────
iso_root="$iso_build_dir/iso-root"
chmod -R u+w "$iso_root" 2>/dev/null || true
rm -rf "$iso_root"
mkdir -p "$iso_root"

# Put the ESP image at the ISO root; xorriso uses it as the EFI boot entry.
cp "$esp_img" "$iso_root/efi.img"
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
