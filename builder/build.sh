#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

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
manifest_add "command: $ROOT/builder/build.sh BUILD_MOCK=${BUILD_MOCK:-1}"

qos_profile="${QOS_PROFILE:-server}"
iso_name="qos-${qos_profile}.iso"
generated_profile_dir="$ROOT/build/generated/profiles/$qos_profile"
resolver="$script_dir/resolve.sh"
[[ -x "$resolver" ]] || die "missing profile resolver: $resolver"
echo "[executing] resolve profile: $qos_profile"
rm -rf "$generated_profile_dir"
"$resolver" stage --profile "$qos_profile" --out-dir "$generated_profile_dir"
export APK_PACKAGES_FILE="$generated_profile_dir/apk/packages.txt"
export APK_REPOSITORIES_FILE="$generated_profile_dir/apk/repositories"
export COMPONENT_ROOTFS_DIR="$generated_profile_dir/rootfs"
export KERNEL_CONFIG="$generated_profile_dir/kernel/x86_64.config"
export KERNEL_VERSION_FILE="$generated_profile_dir/kernel/version"
export ROOTFS_CACHE_KEY="$(cat "$APK_REPOSITORIES_FILE" "$APK_PACKAGES_FILE" | sha256sum | awk '{print $1}')"
manifest_add "profile: $qos_profile"
manifest_add "resolved profile dir: $generated_profile_dir"

rootfs_cache_valid() {
  # Returns 0 if the cached rootfs matches the current profile and was
  # marked complete by build-rootfs.sh on its last successful run.
  local marker="$ROOT/build/rootfs/.qos-cache-tag"
  [[ -f "$marker" ]] || return 1
  local cached_profile cached_status cached_key
  cached_profile="$(awk -F= '$1=="profile"{print $2}' "$marker" 2>/dev/null || true)"
  cached_status="$(awk -F= '$1=="status"{print $2}'  "$marker" 2>/dev/null || true)"
  cached_key="$(awk -F= '$1=="cache_key"{print $2}' "$marker" 2>/dev/null || true)"
  [[ "$cached_profile" == "$qos_profile" && "$cached_status" == "ok" && "$cached_key" == "${ROOTFS_CACHE_KEY:-}" ]]
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
  rm -f "$ROOT/dist/$iso_name"
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
  KERNEL_BUILD_DIR="$kernel_dir" "$script_dir/pipeline/02-kernel/build-kernel.sh"
}

build_mock="${BUILD_MOCK:-1}"
if [[ "$build_mock" != "1" ]]; then
  manifest_add "mode: real"
  echo "[executing] build rootfs"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/pipeline/01-rootfs/build-rootfs.sh"
  echo "[executing] install services"
  ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/pipeline/01-rootfs/install-services.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "rootfs" ]]; then
    die "injected failure after rootfs stage"
  fi

  echo "[executing] build kernel"
  ensure_kernel_artifacts

  # Copy kernel modules into the rootfs.  The kernel build happens after the
  # rootfs apk stage, so the rootfs won't have modules yet on a fresh build.
  # On cached rebuilds the modules are already present (build-rootfs.sh copies
  # them during the first successful apk run).
  modules_src="$ROOT/build/kernel/modules"
  if [[ -d "$modules_src/lib/modules" ]]; then
    modules_kver="$(ls "$modules_src/lib/modules/" 2>/dev/null || true)"
    if [[ -n "$modules_kver" && ! -d "$ROOT/build/rootfs/lib/modules/$modules_kver" ]]; then
      echo "installing kernel modules ($modules_kver) into rootfs"
      chmod -R u+w "$ROOT/build/rootfs/lib" 2>/dev/null || true
      mkdir -p "$ROOT/build/rootfs/lib/modules"
      cp -a "$modules_src/lib/modules/$modules_kver" "$ROOT/build/rootfs/lib/modules/$modules_kver"
      rm -f "$ROOT/build/rootfs/lib/modules/$modules_kver/build" "$ROOT/build/rootfs/lib/modules/$modules_kver/source"
      if command -v depmod >/dev/null 2>&1; then
        depmod -b "$ROOT/build/rootfs" "$modules_kver" 2>/dev/null || true
      elif command -v busybox >/dev/null 2>&1; then
        busybox depmod -b "$ROOT/build/rootfs" "$modules_kver" 2>/dev/null || true
      fi
      echo "kernel modules installed: $modules_kver"
    fi
  fi

  INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/pipeline/03-initrmd/build-initramfs.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "kernel" ]]; then
    die "injected failure after kernel stage"
  fi

  echo "[executing] install bootloader"
  LIMINE_STAGE_DIR="$ROOT/build/boot" \
    KERNEL_BUILD_DIR="$ROOT/build/kernel" \
    INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" \
    "$script_dir/pipeline/04-limine/install-limine.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "limine" ]]; then
    die "injected failure after limine stage"
  fi

  echo "[executing] build iso"
  ISO_NAME="$iso_name" \
  ISO_OUTPUT_DIR="$ROOT/dist" \
  ROOTFS_DIR="$ROOT/build/rootfs" \
  BOOT_STAGE_DIR="$ROOT/build/boot" \
  bash "$script_dir/pipeline/06-iso/build-iso.sh"
  if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "iso" ]]; then
    die "injected failure after iso stage"
  fi

  echo "build complete: dist/$iso_name"
  exit 0
fi

if [[ ! -x "$script_dir/pipeline/01-rootfs/build-rootfs.sh" ]]; then
  manifest_add "mode: scaffold-noop"
  echo "build scaffold complete"
  exit 0
fi

echo "[executing] build rootfs"
ROOTFS_SKIP_APK=1 ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/pipeline/01-rootfs/build-rootfs.sh"
echo "[executing] install services"
ROOTFS_DIR="$ROOT/build/rootfs" "$script_dir/pipeline/01-rootfs/install-services.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "rootfs" ]]; then
  die "injected failure after rootfs stage"
fi

if [[ ! -f "$ROOT/build/kernel/build/arch/x86/boot/bzImage" ]]; then
  echo "[executing] build kernel"
  KERNEL_BUILD_MOCK=1 KERNEL_BUILD_DIR="$ROOT/build/kernel" "$script_dir/pipeline/02-kernel/build-kernel.sh"
fi
echo "[executing] build initramfs"
INITRAMFS_BUILD_MOCK=1 INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" "$script_dir/pipeline/03-initrmd/build-initramfs.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "kernel" ]]; then
  die "injected failure after kernel stage"
fi

echo "[executing] install bootloader"
LIMINE_INSTALL_MOCK=1 \
  LIMINE_STAGE_DIR="$ROOT/build/boot" \
  KERNEL_BUILD_DIR="$ROOT/build/kernel" \
  INITRAMFS_BUILD_DIR="$ROOT/build/initramfs" \
  "$script_dir/pipeline/04-limine/install-limine.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "limine" ]]; then
  die "injected failure after limine stage"
fi

echo "[executing] build iso"
ISO_BUILD_MOCK=1 \
  ISO_NAME="$iso_name" \
  ROOTFS_DIR="$ROOT/build/rootfs" \
  BOOT_STAGE_DIR="$ROOT/build/boot" \
  ISO_OUTPUT_DIR="$ROOT/dist" \
  bash "$script_dir/pipeline/06-iso/build-iso.sh"
if [[ "${BUILD_FAIL_AFTER_STAGE:-}" == "iso" ]]; then
  die "injected failure after iso stage"
fi

echo "build complete: dist/$iso_name"
