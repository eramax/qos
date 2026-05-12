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

require_cmd xorriso cpio lz4 busybox mtools

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

# ── Build live initramfs (rootfs baked in) ───────────────────────────────────
echo "Building live initramfs (with baked-in rootfs)..."

live_stage="$iso_build_dir/live-initramfs"
chmod -R u+w "$live_stage" 2>/dev/null || true
rm -rf "$live_stage"
mkdir -p "$live_stage/bin" "$live_stage/dev" "$live_stage/proc" \
         "$live_stage/sys" "$live_stage/run" "$live_stage/sysroot"

host_busybox="/usr/bin/busybox"
[[ -x "$host_busybox" ]] || die "missing host busybox: $host_busybox"
cp "$host_busybox" "$live_stage/bin/busybox"
chmod 0755 "$live_stage/bin/busybox"
while IFS= read -r applet; do
  [[ "$applet" == "busybox" ]] && continue
  ln -sf busybox "$live_stage/bin/$applet"
done < <("$live_stage/bin/busybox" --list)

echo "  Copying rootfs into live initramfs..."
mkdir -p "$live_stage/rootfs"
cp -a "$rootfs/." "$live_stage/rootfs/"

# ── Embed boot files for qos-install ─────────────────────────────────────────
# The installer needs BOOTX64.EFI, vmlinuz, and the DISK-boot initramfs.img
# (not the live one).  Place them in /var/lib/qos/boot/ so the installer can
# find them without needing to mount the CDROM or locate a source disk.
echo "  Embedding boot files for installer..."
boot_payload="$live_stage/rootfs/var/lib/qos/boot"
mkdir -p "$boot_payload"
cp "$limine_efi"                    "$boot_payload/BOOTX64.EFI"
cp "$boot_dir/vmlinuz"              "$boot_payload/vmlinuz"
cp "$boot_dir/initramfs.img"        "$boot_payload/initramfs.img"
# Disk-boot limine.conf (no livecd flag; root=LABEL=qos-root-a)
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
echo "  Boot payload: $(du -sh "$boot_payload" | awk '{print $1}')"

cat > "$live_stage/init" <<'LIVE_INIT'
#!/bin/sh
# Live CD init — PID 1 inside the live initramfs.
# Uses plain sh (no set -e) to avoid panics on non-critical mount failures.
PATH=/bin
exec >/dev/console 2>&1
echo "[live-init] QOS Live CD starting..."

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run

echo "[live-init] Creating tmpfs sysroot..."
mkdir -p /sysroot
mount -t tmpfs -o size=600M,mode=0755 tmpfs /sysroot || {
  echo "[live-init] FATAL: tmpfs mount failed"
  exec sh
}

echo "[live-init] Populating live rootfs..."
cp -a /rootfs/. /sysroot/
echo "[live-init] Live rootfs ready"

echo "qos-live" > /sysroot/etc/hostname 2>/dev/null
echo "qos-live" > /proc/sys/kernel/hostname 2>/dev/null

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
esp_overhead_kib=$((16 * 1024))
esp_size_kib=$((limine_size_kib + kernel_size_kib + live_initramfs_size_kib + limine_conf_size_kib + esp_overhead_kib))
esp_size_mib=$(((esp_size_kib + 1023) / 1024))
esp_img="$iso_build_dir/efi.img"
truncate -s "${esp_size_mib}M" "$esp_img"
mkfs.vfat -F 12 "$esp_img" >/dev/null

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

echo "  ESP image: $(du -sh "$esp_img" | awk '{print $1}') (payload sized)"

# ── Create ISO ────────────────────────────────────────────────────────────────
iso_root="$iso_build_dir/iso-root"
chmod -R u+w "$iso_root" 2>/dev/null || true
rm -rf "$iso_root"
mkdir -p "$iso_root"

# Put the ESP image at the ISO root; xorriso uses it as the EFI boot entry
cp "$esp_img" "$iso_root/efi.img"

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
