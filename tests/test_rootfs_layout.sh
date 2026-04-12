#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/scripts/build-rootfs.sh" ]] || die "missing build-rootfs.sh"
[[ -x "$repo_root/scripts/apply-rootfs-layout.sh" ]] || die "missing apply-rootfs-layout.sh"

rootfs="$(mktemp -d)"
cleanup() {
  chmod -R u+w "$rootfs" 2>/dev/null || true
  rm -rf "$rootfs"
}
trap cleanup EXIT INT TERM

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs" "$repo_root/scripts/build-rootfs.sh" >/dev/null

for path in etc var run usr bin sbin lib lib64 dev proc sys tmp home root mnt; do
  [[ -e "$rootfs/$path" ]] || die "missing required path: /$path"
done

[[ -L "$rootfs/bin/sh" ]] || die "expected /bin/sh to be a symlink"
[[ "$(readlink "$rootfs/bin/sh")" == "ash" ]] || die "expected /bin/sh -> ash"
[[ -L "$rootfs/bin/sed" ]] || die "expected /bin/sed to be a symlink"
[[ "$(readlink "$rootfs/bin/sed")" == "busybox" ]] || die "expected /bin/sed -> busybox"
[[ -L "$rootfs/bin/sed" ]] || die "expected /bin/sed to be a symlink"
[[ "$(readlink "$rootfs/bin/sed")" == "busybox" ]] || die "expected /bin/sed -> busybox"

check_not_writable() {
  local path="$1"
  [[ ! -L "$path" ]] || return 0
  local mode
  mode="$(stat -Lc '%a' "$path")"
  # Allow writable runtime/state areas.
  case "$path" in
    "$rootfs/var"|"${rootfs}/var/"*|"$rootfs/run"|"${rootfs}/run/"*|"$rootfs/tmp"|"${rootfs}/tmp/"*) return 0 ;;
  esac
  [[ $((8#$mode & 0200)) -eq 0 ]] || die "path should not be owner-writable: $path ($mode)"
}

while IFS= read -r path; do
  check_not_writable "$path"
done < <(find "$rootfs" -mindepth 1 -print)

echo "ok"
