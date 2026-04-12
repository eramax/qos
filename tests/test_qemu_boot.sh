#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/scripts/run-qemu.sh" ]] || die "missing run-qemu.sh"
[[ -x "$repo_root/scripts/assemble-image.sh" ]] || die "missing assemble-image.sh"
[[ -x "$repo_root/scripts/build-rootfs.sh" ]] || die "missing build-rootfs.sh"
grep -qxF 'QEMU_MEMORY ?= 1G' "$repo_root/Makefile" || die "make qemu default memory must be 1G"
grep -qxF 'QEMU_CPUS ?= 2' "$repo_root/Makefile" || die "make qemu default cpu count must be 2"

stage_base="$(mktemp -d "$repo_root/build/task7-qemu.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

rootfs_dir="$stage_base/rootfs"
image_build_dir="$stage_base/image"
image_output_dir="$stage_base/dist"
image_name="qos-qemu.raw"
log_file="$stage_base/serial.log"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
IMAGE_BUILD_MOCK=1 \
ROOTFS_DIR="$rootfs_dir" \
IMAGE_BUILD_DIR="$image_build_dir" \
IMAGE_OUTPUT_DIR="$image_output_dir" \
IMAGE_NAME="$image_name" \
"$repo_root/scripts/assemble-image.sh" >/dev/null

QEMU_RUN_MOCK=1 QEMU_LOG_FILE="$log_file" QEMU_IMAGE="$image_output_dir/$image_name" "$repo_root/scripts/run-qemu.sh" >/dev/null

for phrase in \
  "Limine: booting Linux" \
  "Linux: kernel handoff to init" \
  "s6: supervision started" \
  "network: DHCP lease acquired on eth0" \
  "dropbear: listening on port 22"; do
  grep -qxF "$phrase" "$log_file" || die "missing boot marker: $phrase"
done

echo "ok"
