#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/build-kernel.sh scripts/build-initramfs.sh scripts/install-limine.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done

stage_base="$(mktemp -d "$repo_root/build/task3.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

kernel_dir="$stage_base/kernel"
initramfs_dir="$stage_base/initramfs"
boot_dir="$stage_base/boot"

KERNEL_BUILD_MOCK=1 KERNEL_BUILD_DIR="$kernel_dir" "$repo_root/scripts/build-kernel.sh" >/dev/null
INITRAMFS_BUILD_DIR="$initramfs_dir" "$repo_root/scripts/build-initramfs.sh" >/dev/null
LIMINE_INSTALL_MOCK=1 LIMINE_STAGE_DIR="$boot_dir" KERNEL_BUILD_DIR="$kernel_dir" INITRAMFS_BUILD_DIR="$initramfs_dir" "$repo_root/scripts/install-limine.sh" >/dev/null

[[ -f "$kernel_dir/vmlinuz" ]] || die "missing kernel image"
[[ -f "$kernel_dir/kernel.config" ]] || die "missing copied kernel config"
[[ -f "$initramfs_dir/initramfs.img" ]] || die "missing initramfs image"
[[ -f "$initramfs_dir/mkinitfs.conf" ]] || die "missing copied mkinitfs config"
lz4 -dc "$initramfs_dir/initramfs.img" | cpio -it | rg -qx "bin/sh" || die "missing LZ4 initramfs shell symlink"
grep -q 'mount -t cgroup2 cgroup2 /sysroot/sys/fs/cgroup' "$repo_root/scripts/build-initramfs.sh" || die "initramfs must mount cgroup2"
grep -q 'cgroup.subtree_control' "$repo_root/scripts/build-initramfs.sh" || die "initramfs must enable cgroup v2 controllers"
if [[ "$(readlink "$initramfs_dir/root/bin/sh")" != "busybox" ]]; then
  die "initramfs shell symlink must point to busybox"
fi
if [[ -L "$initramfs_dir/root/bin/busybox" ]]; then
  die "initramfs busybox binary must not be a symlink"
fi
[[ -f "$boot_dir/limine.conf" ]] || die "missing limine config"
[[ -f "$boot_dir/EFI/BOOT/limine.conf" ]] || die "missing EFI-path limine config"
[[ -f "$boot_dir/EFI/BOOT/BOOTX64.EFI" ]] || die "missing UEFI boot file"

for setting in \
  "CONFIG_SMP=y" \
  "CONFIG_PREEMPT_DYNAMIC=y" \
  "CONFIG_PREEMPT_VOLUNTARY=y" \
  "CONFIG_SCHED_AUTOGROUP=n" \
  "CONFIG_HZ_250=y" \
  "CONFIG_NO_HZ_IDLE=y" \
  "CONFIG_NO_HZ_FULL=n" \
  "CONFIG_CFS_BANDWIDTH=y" \
  "CONFIG_CGROUP2=y" \
  "CONFIG_CPUSETS=y" \
  "CONFIG_MEMCG=y" \
  "CONFIG_ZRAM=y" \
  "CONFIG_ZSMALLOC=y" \
  "CONFIG_ZPOOL=y" \
  "CONFIG_CRYPTO_LZ4=y" \
  "CONFIG_RD_LZ4=y" \
  "CONFIG_UCLAMP_TASK=y"; do
  grep -qxF "$setting" "$repo_root/config/kernel/x86_64.config" || die "missing kernel scheduler setting: $setting"
done

grep -qxF "verbose: yes" "$boot_dir/limine.conf" || die "missing Limine verbose boot setting"
grep -qxF "default_entry: 1" "$boot_dir/limine.conf" || die "missing Limine default entry"
grep -qxF "    protocol: linux" "$boot_dir/limine.conf" || die "missing Limine protocol entry"
grep -qxF "    kernel_path: boot():/vmlinuz" "$boot_dir/limine.conf" || die "missing Limine kernel path"
grep -qxF "    module_path: boot():/initramfs.img" "$boot_dir/limine.conf" || die "missing Limine initramfs path"
grep -qF "earlycon=uart,io,0x3f8,115200n8" "$boot_dir/limine.conf" || die "missing kernel earlycon setting"
grep -qF "loglevel=7 ignore_loglevel" "$boot_dir/limine.conf" || die "missing kernel loglevel settings"

echo "ok"
