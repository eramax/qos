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

cleanup() {
  find "$repo_root/build" -mindepth 1 -maxdepth 1 ! -name README.md -exec rm -rf {} + 2>/dev/null || true
  rm -f "$repo_root"/dist/*.raw
}
trap cleanup EXIT INT TERM

(
  cd "$repo_root"
  BUILD_MOCK=1 ./build.sh >/dev/null
)

for path in \
  "$repo_root/build/rootfs/etc/dropbear/dropbear.conf" \
  "$repo_root/build/kernel/vmlinuz" \
  "$repo_root/build/initramfs/initramfs.img" \
  "$repo_root/build/boot/EFI/BOOT/BOOTX64.EFI" \
  "$repo_root/build/image/boot/EFI/BOOT/BOOTX64.EFI" \
  "$repo_root/dist/qos-x86_64.raw"; do
  [[ -e "$path" ]] || die "missing expected build artifact: $path"
done

set +e
(
  cd "$repo_root"
  BUILD_MOCK=1 BUILD_FAIL_AFTER_STAGE=kernel ./build.sh >/dev/null 2>&1
)
rc=$?
set -e
[[ $rc -ne 0 ]] || die "expected injected failure to make build.sh fail"

for path in \
  "$repo_root/build/rootfs" \
  "$repo_root/build/kernel" \
  "$repo_root/build/initramfs" \
  "$repo_root/build/boot" \
  "$repo_root/build/image" \
  "$repo_root/dist/qos-x86_64.raw"; do
  [[ ! -e "$path" ]] || die "failed build left partial artifact behind: $path"
done

echo "ok"

