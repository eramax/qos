#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
limine_config="${LIMINE_CONFIG:-$root/config/limine/limine.conf}"
limine_stage_dir="${LIMINE_STAGE_DIR:-$root/build/boot}"
kernel_dir="${KERNEL_BUILD_DIR:-$root/build/kernel}"
initramfs_dir="${INITRAMFS_BUILD_DIR:-$root/build/initramfs}"

[[ -f "$limine_config" ]] || die "missing limine config: $limine_config"
[[ -d "$kernel_dir" ]] || die "missing kernel build dir: $kernel_dir"
[[ -d "$initramfs_dir" ]] || die "missing initramfs build dir: $initramfs_dir"

mkdir -p "$limine_stage_dir/EFI/BOOT"

cp "$limine_config" "$limine_stage_dir/limine.conf"

if [[ "${LIMINE_INSTALL_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock UEFI bootloader" > "$limine_stage_dir/EFI/BOOT/BOOTX64.EFI"
  printf '%s\n' "mock Limine stage" > "$limine_stage_dir/EFI/BOOT/README.txt"
  echo "limine install skipped (mock mode)"
  exit 0
fi

if ! command -v limine >/dev/null 2>&1; then
  die "limine is required for a real bootloader install (set LIMINE_INSTALL_MOCK=1 for scaffold/test mode)"
fi

die "real Limine staging is not wired yet; set LIMINE_INSTALL_MOCK=1 for scaffold/test mode"

