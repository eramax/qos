#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

rootfs="${1:-${ROOTFS_DIR:-}}"
[[ -n "$rootfs" ]] || die "usage: $0 <rootfs-dir>"

root="$(repo_root)"
paths_file="$root/config/rootfs/paths.txt"
[[ -f "$paths_file" ]] || die "missing rootfs path manifest: $paths_file"

mkdir -p "$rootfs"

perm_for_path() {
  case "$1" in
    /run|/var|/var/lib|/var/log) echo 0755 ;;
    /tmp) echo 1777 ;;
    *) echo 0555 ;;
  esac
}

while IFS= read -r path; do
  [[ -n "$path" && "${path#\#}" == "$path" ]] || continue
  [[ "$path" == /* ]] || die "rootfs path manifest must use absolute paths: $path"
  rel="${path#/}"
  mkdir -p "$rootfs/$rel"
done < "$paths_file"

# Immutable rootfs should expose /bin/ash via busybox and /bin/sh via ash.
# busybox --install is skipped (--no-scripts in build-rootfs.sh), so wire up
# the applets we actually need by hand.
ln -sfn busybox "$rootfs/bin/ash"
ln -sfn ash    "$rootfs/bin/sh"
ln -sfn busybox "$rootfs/bin/hostname"
ln -sfn busybox "$rootfs/bin/login"
ln -sfn /bin/busybox "$rootfs/sbin/getty"
ln -sfn /usr/bin/s6-linux-init "$rootfs/sbin/init"

# Dev/test image: set root password to "root".
# Must happen before the chmod loop locks /etc to 0555.
# awk is used instead of sed so the $6$... hash is not mis-expanded.
if [[ -f "$rootfs/etc/shadow" ]]; then
  root_pw_hash="$(openssl passwd -6 root)"
  awk -v pw="$root_pw_hash" 'BEGIN{FS=OFS=":"} $1=="root"{$2=pw}1' \
    "$rootfs/etc/shadow" > "$rootfs/etc/shadow.tmp"
  mv "$rootfs/etc/shadow.tmp" "$rootfs/etc/shadow"
fi

while IFS= read -r path; do
  [[ -n "$path" && "${path#\#}" == "$path" ]] || continue
  [[ "$path" == /* ]] || die "rootfs path manifest must use absolute paths: $path"
  rel="${path#/}"
  chmod "$(perm_for_path "$path")" "$rootfs/$rel"
done < "$paths_file"
