#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
initramfs_config="${INITRAMFS_CONFIG:-$root/config/initramfs/mkinitfs.conf}"
initramfs_build_dir="${INITRAMFS_BUILD_DIR:-$root/build/initramfs}"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"
root_label="${ROOT_LABEL:-qos-root-a}"
state_label="${STATE_LABEL:-qos-state}"
stage_root="$initramfs_build_dir/root"
host_busybox="/usr/bin/busybox"

[[ -f "$initramfs_config" ]] || die "missing initramfs config: $initramfs_config"
chmod -R u+w "$initramfs_build_dir" 2>/dev/null || true
rm -rf "$stage_root"
mkdir -p "$stage_root"

cp "$initramfs_config" "$initramfs_build_dir/mkinitfs.conf"

if [[ "${INITRAMFS_BUILD_MOCK:-0}" == "1" ]]; then
  printf '%s\n' "mock initramfs image" > "$initramfs_build_dir/initramfs.img"
  echo "initramfs build skipped (mock mode)"
  exit 0
fi

require_cmd cpio gzip busybox

[[ -x "$host_busybox" ]] || die "missing host busybox binary"

manifest_add "command: scripts/build-initramfs.sh root=$root_label state=$state_label"

mkdir -p "$stage_root/bin" "$stage_root/dev" "$stage_root/proc" "$stage_root/sys" "$stage_root/run" "$stage_root/sysroot"
cp "$host_busybox" "$stage_root/bin/busybox"
chmod 0755 "$stage_root/bin/busybox"
while IFS= read -r applet; do
  [[ "$applet" == "busybox" ]] && continue
  ln -sf busybox "$stage_root/bin/$applet"
done < <("$stage_root/bin/busybox" --list)

cat > "$stage_root/init" <<EOF
#!/bin/sh
set -eu
PATH=/bin

exec >/dev/console 2>&1
echo "[initramfs] init started"
echo "[initramfs] mounting proc, sysfs, devtmpfs, and tmpfs"

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /run

root_label="${root_label}"
state_label="${state_label}"

for arg in \$(cat /proc/cmdline); do
  case "\$arg" in
    root=LABEL=*)
      root_label="\${arg#root=LABEL=}"
      ;;
    state=LABEL=*)
      state_label="\${arg#state=LABEL=}"
      ;;
  esac
done

mkdir -p /sysroot
echo "[initramfs] resolving root label \$root_label"
root_dev="\$(findfs "LABEL=\$root_label")"
echo "[initramfs] mounting root device \$root_dev"
mount -t ext4 -o ro "\$root_dev" /sysroot
mkdir -p /sysroot/var
echo "[initramfs] mounting tmpfs /var"
mount -t tmpfs tmpfs /sysroot/var
echo "[initramfs] mounting proc, sysfs, devtmpfs, and tmpfs in sysroot"
mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev /sysroot/run
mount -t proc proc /sysroot/proc
mount -t sysfs sysfs /sysroot/sys
mount -t devtmpfs devtmpfs /sysroot/dev
mount -t tmpfs tmpfs /sysroot/run
echo "[initramfs] switching to /sbin/init"
exec switch_root /sysroot /sbin/init
EOF
chmod 0755 "$stage_root/init"

( cd "$stage_root" && find . -print0 | cpio --null -o -H newc ) | gzip -9 > "$initramfs_build_dir/initramfs.img"

echo "initramfs build complete: $initramfs_build_dir/initramfs.img"
