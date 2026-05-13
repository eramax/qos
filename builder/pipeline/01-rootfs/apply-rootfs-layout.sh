#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../../lib/common.sh"

rootfs="${1:-${ROOTFS_DIR:-}}"
[[ -n "$rootfs" ]] || die "usage: $0 <rootfs-dir>"

root="$(repo_root)"
paths_file="$root/builder/pipeline/01-rootfs/paths.txt"
[[ -f "$paths_file" ]] || die "missing rootfs path manifest: $paths_file"
host_busybox="$(command -v busybox || true)"
[[ -n "$host_busybox" ]] || die "missing host busybox binary"

mkdir -p "$rootfs"

# Make writable for the layout staging pass (rootfs may be read-only from cache).
chmod -R u+w "$rootfs/bin" "$rootfs/sbin" "$rootfs/etc" "$rootfs/usr" 2>/dev/null || true

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

mkdir -p "$rootfs/bin" "$rootfs/sbin" "$rootfs/usr/bin"

# Immutable rootfs should expose BusyBox applets broadly, then override the
# few entrypoints we care about.
#
# CRITICAL: We must check if a real binary already exists before linking.
# If a package (like e2fsprogs) installed a real binary, we MUST NOT overwrite it
# with a busybox symlink.
while IFS= read -r applet; do
  [[ "$applet" == busybox ]] && continue
  
  # Skip if a real file/binary is already provided by a package
  if [[ -e "$rootfs/bin/$applet" ]] || [[ -e "$rootfs/sbin/$applet" ]]; then
    continue
  fi

  ln -sf busybox "$rootfs/bin/$applet"
  ln -sf busybox "$rootfs/sbin/$applet"
done < <("$host_busybox" --list)
rm -rf "$rootfs/sbin/busybox" "$rootfs/usr/bin/env" "$rootfs/bin/sh" "$rootfs/sbin/init"
ln -s /bin/busybox "$rootfs/sbin/busybox"
ln -s /bin/busybox "$rootfs/usr/bin/env"
ln -s ash "$rootfs/bin/sh"
ln -s /usr/bin/s6-linux-init "$rootfs/sbin/init"

mkdir -p "$rootfs/etc/qos"
install -m 0644 "$root/builder/pipeline/05-image/slots.json" "$rootfs/etc/qos/slots.json"

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

if [[ -f "$rootfs/etc/apk/repositories" ]]; then
  chmod 0444 "$rootfs/etc/apk/repositories"
fi
chmod 0444 "$rootfs/etc/qos/slots.json" 2>/dev/null || true
if [[ -d "$rootfs/etc/apk/keys" ]]; then
  chmod -R a-w "$rootfs/etc/apk/keys"
fi
chmod 0555 "$rootfs/usr/sbin/qos-reset" 2>/dev/null || true
