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
  require_cmd curl tar xz cpio dd sgdisk mkfs.ext4 mkfs.vfat mcopy mmd git busybox help2man indent
fi

ensure_dir "$ROOT/build"
ensure_dir "$ROOT/dist"
BUILD_MANIFEST_FILE="$ROOT/build/build.manifest"
: > "$BUILD_MANIFEST_FILE"
manifest_add "command: $ROOT/build.sh BUILD_MOCK=${BUILD_MOCK:-1}"

rootfs_cache_valid() {
  # Returns 0 if the cached rootfs matches the current profile and was
  # marked complete by build-rootfs.sh on its last successful run.
  local marker="$ROOT/build/rootfs/.qos-cache-tag"
  [[ -f "$marker" ]] || return 1
  local cached_profile cached_status
  cached_profile="$(awk -F= '$1=="profile"{print $2}' "$marker" 2>/dev/null || true)"
  cached_status="$(awk -F= '$1=="status"{print $2}'  "$marker" 2>/dev/null || true)"
  [[ "$cached_profile" == "${QOS_PROFILE:-server}" && "$cached_status" == "ok" ]]
}

cleanup_generated_outputs() {
  local keep_rootfs=0
  if [[ "${BUILD_FORCE_ROOTFS:-0}" != "1" ]] && rootfs_cache_valid; then
    keep_rootfs=1
  fi
  for path in \
    "$ROOT/build/initramfs" \
    "$ROOT/build/boot"
  do
    [[ -e "$path" ]] && chmod -R u+w "$path" 2>/dev/null || true
  done
  if [[ "$keep_rootfs" != "1" ]]; then
    [[ -e "$ROOT/build/rootfs" ]] && chmod -R u+w "$ROOT/build/rootfs" 2>/dev/null || true
    rm -rf "$ROOT/build/rootfs"
  fi
  rm -rf "$ROOT/build/initramfs" "$ROOT/build/boot"
  rm -f "$ROOT"/dist/*.iso
}

on_exit() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    cleanup_generated_outputs
  fi
  exit "$status"
}

trap on_exit EXIT

build_timestamp="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
git_revision="$(git rev-parse --short HEAD 2>/dev/null || true)"
qos_build_version="QOS build: $build_timestamp"
if [[ -n "$git_revision" ]]; then
  qos_build_version="$qos_build_version (git $git_revision)"
fi
export QOS_BUILD_VERSION="$qos_build_version"
manifest_add "qos version: $QOS_BUILD_VERSION"

cleanup_generated_outputs

ensure_kernel_artifacts() {
  local kernel_dir="$ROOT/build/kernel"
  local kernel_image="$kernel_dir/build/arch/x86/boot/bzImage"

  if [[ -f "$kernel_image" ]]; then
    manifest_add "kernel: reused existing artifacts"
    return 0
  fi

  manifest_add "kernel: rebuilt because artifacts were missing"
  KERNEL_BUILD_DIR="$kernel_dir" "$script_dir/scripts/build-kernel.sh"
}

build_mock="${BUILD_MOCK:-1}"
if [[ "$build_mock" != "1" ]]; then
  manifest_add "mode: real"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/build-rootfs.sh"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/scripts/install-services.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "rootfs" ]]; then
    die "injected failure after rootfs stage"
  fi

  ensure_kernel_artifacts
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

  ISO_OUTPUT_DIR="$ROOT/dist" \
  ROOTFS_DIR="$ROOT/build/rootfs" \
  BOOT_STAGE_DIR="$ROOT/build/boot" \
  bash "$script_dir/scripts/build-iso.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "iso" ]]; then
    die "injected failure after iso stage"
  fi

  echo "build complete: dist/qos-x86_64.iso"
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

if [[ ! -f "$ROOT/build/kernel/build/arch/x86/boot/bzImage" ]]; then
  KERNEL_BUILD_MOCK=1 KERNEL_BUILD_DIR="$ROOT/build/kernel" "$script_dir/scripts/build-kernel.sh"
fi
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

ISO_BUILD_MOCK=1 \
  ROOTFS_DIR="$ROOT/build/rootfs" \
  BOOT_STAGE_DIR="$ROOT/build/boot" \
  ISO_OUTPUT_DIR="$ROOT/dist" \
  bash "$script_dir/scripts/build-iso.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "iso" ]]; then
  die "injected failure after iso stage"
fi

echo "build complete: dist/qos-x86_64.iso"
