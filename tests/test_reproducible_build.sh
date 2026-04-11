#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/build-rootfs.sh scripts/build-kernel.sh scripts/build-initramfs.sh scripts/install-services.sh scripts/install-limine.sh scripts/assemble-image.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done

build_snapshot() {
  local base="$1"
  local rootfs_dir="$base/rootfs"
  local kernel_dir="$base/kernel"
  local initramfs_dir="$base/initramfs"
  local boot_dir="$base/boot"
  local image_build_dir="$base/image"
  local image_output_dir="$base/dist"
  local image_name="qos-repro.raw"

  ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
  ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/install-services.sh" >/dev/null
  KERNEL_BUILD_MOCK=1 KERNEL_BUILD_DIR="$kernel_dir" "$repo_root/scripts/build-kernel.sh" >/dev/null
  INITRAMFS_BUILD_MOCK=1 INITRAMFS_BUILD_DIR="$initramfs_dir" "$repo_root/scripts/build-initramfs.sh" >/dev/null
  LIMINE_INSTALL_MOCK=1 LIMINE_STAGE_DIR="$boot_dir" KERNEL_BUILD_DIR="$kernel_dir" INITRAMFS_BUILD_DIR="$initramfs_dir" "$repo_root/scripts/install-limine.sh" >/dev/null
  IMAGE_BUILD_MOCK=1 \
    ROOTFS_DIR="$rootfs_dir" \
    IMAGE_BUILD_DIR="$image_build_dir" \
    IMAGE_OUTPUT_DIR="$image_output_dir" \
    IMAGE_NAME="$image_name" \
    "$repo_root/scripts/assemble-image.sh" >/dev/null

  (
    cd "$base"
    sha256sum \
      "dist/$image_name" \
      "image/layout.json" \
      "image/slots.json" \
      "image/fstab" \
      "boot/limine.conf" \
      "boot/EFI/BOOT/BOOTX64.EFI" \
      | sort
  )
}

stage_a="$(mktemp -d "$repo_root/build/task7-repro-a.XXXXXX")"
stage_b="$(mktemp -d "$repo_root/build/task7-repro-b.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_a" "$stage_b" 2>/dev/null || true
  rm -rf "$stage_a" "$stage_b"
}
trap cleanup EXIT INT TERM

manifest_a="$(build_snapshot "$stage_a")"
manifest_b="$(build_snapshot "$stage_b")"

[[ "$manifest_a" == "$manifest_b" ]] || {
  echo "first run:" >&2
  echo "$manifest_a" >&2
  echo "second run:" >&2
  echo "$manifest_b" >&2
  die "reproducible build artifacts differed"
}

echo "ok"
