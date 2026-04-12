#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/build.sh" ]] || die "missing build.sh"

stage_base="$(mktemp -d "$repo_root/build/task-real.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

BUILD_MOCK=0 \
BUILD_KERNEL_JOBS=4 \
BUILD_TOOL_JOBS=2 \
ROOTFS_CACHE_DIR="$stage_base/cache" \
IMAGE_OUTPUT_DIR="$stage_base/dist" \
"$repo_root/build.sh" >/dev/null

[[ -f "$repo_root/dist/qos-x86_64.raw" ]] || die "missing real raw disk image"
[[ -s "$repo_root/dist/qos-x86_64.raw" ]] || die "real raw disk image is empty"
[[ -f "$repo_root/build/kernel/vmlinuz" ]] || die "missing kernel image"
[[ -f "$repo_root/build/initramfs/initramfs.img" ]] || die "missing initramfs image"
[[ -f "$repo_root/build/boot/EFI/BOOT/BOOTX64.EFI" ]] || die "missing UEFI bootloader"
[[ -f "$repo_root/build/build.manifest" ]] || die "missing reproducibility manifest"

grep -qxF "command: $repo_root/build.sh BUILD_MOCK=0" "$repo_root/build/build.manifest" || die "manifest missing top-level build command"
grep -qxF "source: kernel https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.6.tar.xz" "$repo_root/build/build.manifest" || die "manifest missing kernel source URL"
grep -qxF "source: limine https://github.com/limine-bootloader/limine.git#v10.x-binary" "$repo_root/build/build.manifest" || die "manifest missing limine source URL"
grep -qxF "source: alpine-repo https://dl-cdn.alpinelinux.org/alpine/v3.23/main" "$repo_root/build/build.manifest" || die "manifest missing alpine repo URL"

echo "ok"
