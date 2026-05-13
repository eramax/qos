#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/boot-image.sh scripts/run-qemu.sh scripts/assemble-image.sh scripts/build-rootfs.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done
grep -q 'exec switch_root /sysroot /sbin/init' "$repo_root/scripts/build-iso.sh" || die "live init must switch_root into the live rootfs"
grep -q 'rdinit=/init' "$repo_root/scripts/build-iso.sh" || die "live kernel cmdline must force rdinit=/init"
grep -q 'host_busybox="/usr/bin/busybox"' "$repo_root/scripts/build-iso.sh" || die "live initramfs must source a host busybox binary"
grep -q 'cp "$host_busybox" "$live_stage/bin/busybox"' "$repo_root/scripts/build-iso.sh" || die "live initramfs must use host static busybox for early boot"
grep -q 'mksquashfs "$rootfs" "$rootfs_sfs"' "$repo_root/scripts/build-iso.sh" || die "live ISO build must generate rootfs.sfs"
grep -q '#!/bin/busybox sh' "$repo_root/scripts/build-iso.sh" || die "live /init must use the static busybox interpreter directly"
grep -q 'rootfs.sfs' "$repo_root/scripts/build-iso.sh" || die "live ISO builder must depend on rootfs.sfs discovery at boot"
! grep -q '/dev/sr0' "$repo_root/scripts/build-iso.sh" || die "live ISO builder must not depend on sr0 appearing in the guest"
grep -q '99-qos-live-disable.cfg' "$repo_root/scripts/build-iso.sh" || die "live init must disable cloud-init"

stage_base="$(mktemp -d "$repo_root/build/task-boot.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

rootfs_dir="$stage_base/rootfs"
image_build_dir="$stage_base/image"
image_output_dir="$stage_base/dist"
image_name="qos-boot.raw"
log_file="$stage_base/boot.log"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
IMAGE_BUILD_MOCK=1 \
ROOTFS_DIR="$rootfs_dir" \
IMAGE_BUILD_DIR="$image_build_dir" \
IMAGE_OUTPUT_DIR="$image_output_dir" \
IMAGE_NAME="$image_name" \
"$repo_root/scripts/assemble-image.sh" >/dev/null

QEMU_RUN_MOCK=1 BOOT_LOG_FILE="$log_file" "$repo_root/scripts/boot-image.sh" --smoke "$image_output_dir/$image_name" >/dev/null

for phrase in \
  "Limine: booting Linux" \
  "Linux: kernel handoff to init" \
  "s6: supervision started" \
  "network: DHCP lease acquired on eth0" \
  "dropbear: listening on port 22"; do
  grep -qxF "$phrase" "$log_file" || die "missing boot marker: $phrase"
done

echo "ok"
