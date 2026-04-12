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
[[ -L "$rootfs/bin/find" ]] || die "expected /bin/find to be a symlink"
[[ "$(readlink "$rootfs/bin/find")" == "busybox" ]] || die "expected /bin/find -> busybox"
[[ -L "$rootfs/bin/cp" ]] || die "expected /bin/cp to be a symlink"
[[ "$(readlink "$rootfs/bin/cp")" == "busybox" ]] || die "expected /bin/cp -> busybox"
[[ -L "$rootfs/bin/mkdir" ]] || die "expected /bin/mkdir to be a symlink"
[[ "$(readlink "$rootfs/bin/mkdir")" == "busybox" ]] || die "expected /bin/mkdir -> busybox"
[[ -L "$rootfs/bin/rm" ]] || die "expected /bin/rm to be a symlink"
[[ "$(readlink "$rootfs/bin/rm")" == "busybox" ]] || die "expected /bin/rm -> busybox"
[[ -L "$rootfs/bin/sed" ]] || die "expected /bin/sed to be a symlink"
[[ "$(readlink "$rootfs/bin/sed")" == "busybox" ]] || die "expected /bin/sed -> busybox"
[[ -L "$rootfs/bin/hostname" ]] || die "expected /bin/hostname to be a symlink"
[[ "$(readlink "$rootfs/bin/hostname")" == "busybox" ]] || die "expected /bin/hostname -> busybox"
[[ -L "$rootfs/sbin/busybox" ]] || die "expected /sbin/busybox to be a symlink"
[[ "$(readlink "$rootfs/sbin/busybox")" == "/bin/busybox" ]] || die "expected /sbin/busybox -> /bin/busybox"
[[ -f "$rootfs/etc/qos/slots.json" ]] || die "missing reset slot manifest"
[[ -x "$rootfs/usr/sbin/qos-reset" ]] || die "missing factory reset command"
! grep -q 'common.sh' "$rootfs/usr/sbin/qos-reset" || die "factory reset command must be self-contained"
grep -q 'findfs "LABEL=' "$rootfs/usr/sbin/qos-reset" || die "factory reset command must mount the state partition"
grep -qF '"$bb" mount "$state_dev" "$mount_point"' "$rootfs/usr/sbin/qos-reset" || die "factory reset command must mount the state partition"

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
