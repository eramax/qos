#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/build-rootfs.sh scripts/assemble-image.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done

stage_base="$(mktemp -d "$repo_root/build/task4.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

rootfs_dir="$stage_base/rootfs"
image_build_dir="$stage_base/image"
image_output_dir="$stage_base/dist"
image_name="qos-test.raw"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
IMAGE_BUILD_MOCK=1 \
ROOTFS_DIR="$rootfs_dir" \
IMAGE_BUILD_DIR="$image_build_dir" \
IMAGE_OUTPUT_DIR="$image_output_dir" \
IMAGE_NAME="$image_name" \
"$repo_root/scripts/assemble-image.sh" >/dev/null

[[ -f "$image_output_dir/$image_name" ]] || die "missing raw disk image"
[[ -s "$image_output_dir/$image_name" ]] || die "raw disk image is empty"

[[ -f "$image_build_dir/layout.json" ]] || die "missing copied layout manifest"
[[ -f "$image_build_dir/slots.json" ]] || die "missing copied slot manifest"
[[ -f "$image_build_dir/fstab" ]] || die "missing copied fstab"
[[ -d "$image_build_dir/slots/B/rootfs" ]] || die "missing staged inactive slot rootfs"

grep -q '"boot_mode"[[:space:]]*:[[:space:]]*"uefi"' "$image_build_dir/layout.json" || die "layout missing UEFI boot mode"
grep -q '"immutable"[[:space:]]*:[[:space:]]*true' "$image_build_dir/layout.json" || die "layout missing immutable root partition"
grep -q '"mutable"[[:space:]]*:[[:space:]]*true' "$image_build_dir/layout.json" || die "layout missing mutable state partition"
grep -q '"active"[[:space:]]*:[[:space:]]*"A"' "$image_build_dir/slots.json" || die "slot manifest missing active slot"
grep -q '"inactive"[[:space:]]*:[[:space:]]*"B"' "$image_build_dir/slots.json" || die "slot manifest missing inactive slot"
grep -qxF '/dev/disk/by-label/qos-state /var ext4 rw,errors=remount-ro 0 2' "$image_build_dir/fstab" || die "fstab missing writable /var mount"
grep -qxF '/dev/disk/by-label/qos-root-a / ext4 ro,errors=remount-ro 0 1' "$image_build_dir/fstab" || die "fstab missing immutable root mount"

echo "ok"
