#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/scripts/lib/common.sh"

ROOT="$(repo_root)"

# Contract: refuse to run if the user is not somewhere inside this workspace.
pwd_abs="$(pwd -P)"
if [[ "$pwd_abs" != "$ROOT" ]]; then
  root_len=${#ROOT}
  if [[ "${pwd_abs:0:root_len}" != "$ROOT" || "${pwd_abs:root_len:1}" != "/" ]]; then
    die "refusing to run outside workspace. cd into $ROOT (or a subdir) and re-run."
  fi
fi

require_cmd jq truncate sha256sum cp rm mkdir
if [[ "${BUILD_MOCK:-1}" != "1" ]]; then
  require_cmd curl tar xz cpio dd sgdisk mkfs.ext4 mkfs.vfat mcopy mmd git busybox
fi

ensure_dir "$ROOT/build"
ensure_dir "$ROOT/dist"
BUILD_MANIFEST_FILE="$ROOT/build/build.manifest"
: > "$BUILD_MANIFEST_FILE"
manifest_add "command: $ROOT/build.sh BUILD_MOCK=${BUILD_MOCK:-1}"

cleanup_generated_outputs() {
  for path in \
    "$ROOT/build/rootfs" \
    "$ROOT/build/kernel" \
    "$ROOT/build/initramfs" \
    "$ROOT/build/boot" \
    "$ROOT/build/image"
  do
    [[ -e "$path" ]] && chmod -R u+w "$path" 2>/dev/null || true
  done
  rm -rf \
    "$ROOT/build/rootfs" \
    "$ROOT/build/kernel" \
    "$ROOT/build/initramfs" \
    "$ROOT/build/boot" \
    "$ROOT/build/image"
  rm -f "$ROOT"/dist/*.raw
}

on_exit() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    cleanup_generated_outputs
  fi
  exit "$status"
}

trap on_exit EXIT

cleanup_generated_outputs

build_mock="${BUILD_MOCK:-1}"
if [[ "$build_mock" != "1" ]]; then
  manifest_add "mode: real"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/build-rootfs.sh"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/install-services.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "rootfs" ]]; then
    die "injected failure after rootfs stage"
  fi

  KERNEL_BUILD_DIR="$ROOT/build/kernel" "$script_dir/scripts/build-kernel.sh"
  INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/build-initramfs.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "kernel" ]]; then
    die "injected failure after kernel stage"
  fi

  LIMINE_STAGE_DIR="$ROOT/build/boot" \
    KERNEL_BUILD_DIR="$ROOT/build/kernel" \
    INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" \
    "$script_dir/scripts/install-limine.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "limine" ]]; then
    die "injected failure after limine stage"
  fi

  IMAGE_BUILD_DIR="$ROOT/build/image" \
    IMAGE_OUTPUT_DIR="$ROOT/dist" \
    ROOTFS_DIR="$ROOT/build/rootfs" \
    BOOT_STAGE_DIR="$ROOT/build/boot" \
    "$script_dir/scripts/assemble-image.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "image" ]]; then
    die "injected failure after image stage"
  fi

  echo "build complete: dist/qos-x86_64.raw"
  exit 0
fi

if [[ ! -x "$script_dir/scripts/build-rootfs.sh" ]]; then
  manifest_add "mode: scaffold-noop"
  echo "build scaffold complete"
  exit 0
fi

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/build-rootfs.sh"
ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/install-services.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "rootfs" ]]; then
  die "injected failure after rootfs stage"
fi

KERNEL_BUILD_MOCK=1 KERNEL_BUILD_DIR="$ROOT/build/kernel" "$script_dir/scripts/build-kernel.sh"
INITRAMFS_BUILD_MOCK=1 INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" "$script_dir/scripts/build-initramfs.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "kernel" ]]; then
  die "injected failure after kernel stage"
fi

LIMINE_INSTALL_MOCK=1 \
  LIMINE_STAGE_DIR="$ROOT/build/boot" \
  KERNEL_BUILD_DIR="$ROOT/build/kernel" \
  INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" \
  "$script_dir/scripts/install-limine.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "limine" ]]; then
  die "injected failure after limine stage"
fi

IMAGE_BUILD_MOCK=1 \
  ROOTFS_DIR="$ROOT/build/rootfs" \
  BOOT_STAGE_DIR="$ROOT/build/boot" \
  IMAGE_BUILD_DIR="$ROOT/build/image" \
  IMAGE_OUTPUT_DIR="$ROOT/dist" \
  "$script_dir/scripts/assemble-image.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "image" ]]; then
  die "injected failure after image stage"
fi

echo "build complete: dist/qos-x86_64.raw"
