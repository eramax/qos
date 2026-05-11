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
limine_branch_file="${LIMINE_BRANCH_FILE:-$root/config/limine/branch}"
cache_root="${LIMINE_CACHE_DIR:-$root/build/cache/limine}"

[[ -f "$limine_config" ]] || die "missing limine config: $limine_config"
[[ -d "$kernel_dir" ]] || die "missing kernel build dir: $kernel_dir"
[[ -d "$initramfs_dir" ]] || die "missing initramfs build dir: $initramfs_dir"

mkdir -p "$limine_stage_dir/EFI/BOOT"
mkdir -p "$cache_root"

if [[ "${LIMINE_INSTALL_MOCK:-0}" == "1" ]]; then
  cp "$limine_config" "$limine_stage_dir/limine.conf"
  cp "$limine_config" "$limine_stage_dir/EFI/BOOT/limine.conf"
  cp "$kernel_dir/vmlinuz" "$limine_stage_dir/vmlinuz"
  cp "$initramfs_dir/initramfs.img" "$limine_stage_dir/initramfs.img"
  printf '%s\n' "mock UEFI bootloader" > "$limine_stage_dir/EFI/BOOT/BOOTX64.EFI"
  printf '%s\n' "mock Limine stage" > "$limine_stage_dir/EFI/BOOT/README.txt"
  echo "limine install skipped (mock mode)"
  exit 0
fi

require_cmd git

branch="$(tr -d '[:space:]' < "$limine_branch_file")"
[[ -n "$branch" ]] || die "missing limine branch: $limine_branch_file"

manifest_add "command: scripts/install-limine.sh branch=$branch"
manifest_add "source: limine https://github.com/limine-bootloader/limine.git#$branch"

limine_src="$cache_root/limine"
if [[ ! -d "$limine_src/.git" ]]; then
  git clone --depth 1 --branch "$branch" https://github.com/limine-bootloader/limine.git "$limine_src" >/dev/null
fi

cp "$limine_config" "$limine_stage_dir/limine.conf"
cp "$limine_config" "$limine_stage_dir/EFI/BOOT/limine.conf"
cp "$kernel_dir/vmlinuz" "$limine_stage_dir/vmlinuz"
cp "$initramfs_dir/initramfs.img" "$limine_stage_dir/initramfs.img"

# Skip copying EFI binaries if already staged
if [[ -f "$limine_stage_dir/EFI/BOOT/BOOTX64.EFI" ]]; then
  echo "limine already staged (skip rebuild)"
  echo "limine stage complete: $limine_stage_dir"
  exit 0
fi

cp "$limine_src/BOOTX64.EFI" "$limine_stage_dir/EFI/BOOT/BOOTX64.EFI"
cp "$limine_src/BOOTIA32.EFI" "$limine_stage_dir/EFI/BOOT/BOOTIA32.EFI" 2>/dev/null || true

echo "limine stage complete: $limine_stage_dir"
