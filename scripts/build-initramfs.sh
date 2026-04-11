#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
initramfs_config="${INITRAMFS_CONFIG:-$root/config/initramfs/mkinitfs.conf}"
initramfs_build_dir="${INITRAMFS_BUILD_DIR:-$root/build/initramfs}"

[[ -f "$initramfs_config" ]] || die "missing initramfs config: $initramfs_config"
mkdir -p "$initramfs_build_dir"

cp "$initramfs_config" "$initramfs_build_dir/mkinitfs.conf"

if [[ "${INITRAMFS_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock initramfs image" > "$initramfs_build_dir/initramfs.img"
  echo "initramfs build skipped (mock mode)"
  exit 0
fi

if ! command -v mkinitfs >/dev/null 2>&1; then
  die "mkinitfs is required for a real initramfs build (set INITRAMFS_BUILD_MOCK=1 for scaffold/test mode)"
fi

die "real initramfs generation is not wired yet; set INITRAMFS_BUILD_MOCK=1 for scaffold/test mode"

