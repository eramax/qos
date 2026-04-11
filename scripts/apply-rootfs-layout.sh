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

# Immutable rootfs should expose /bin/sh via ash.
ln -sfn ash "$rootfs/bin/sh"
ln -sfn /usr/bin/s6-linux-init "$rootfs/sbin/init"

while IFS= read -r path; do
  [[ -n "$path" && "${path#\#}" == "$path" ]] || continue
  [[ "$path" == /* ]] || die "rootfs path manifest must use absolute paths: $path"
  rel="${path#/}"
  chmod "$(perm_for_path "$path")" "$rootfs/$rel"
done < "$paths_file"
