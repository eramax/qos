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
host_busybox="$(command -v busybox)"

[[ -f "$initramfs_config" ]] || die "missing initramfs config: $initramfs_config"
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
"$stage_root/bin/busybox" --install -s "$stage_root/bin"

cat > "$stage_root/init" <<EOF
#!/bin/sh
set -eu
PATH=/bin

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

mkdir -p /sysroot /sysroot/var
mount -t ext4 -o ro -L "\$root_label" /sysroot
mount -t ext4 -o rw -L "\$state_label" /sysroot/var
exec switch_root /sysroot /sbin/init
EOF
chmod 0755 "$stage_root/init"

( cd "$stage_root" && find . -print0 | cpio --null -o -H newc ) | gzip -9 > "$initramfs_build_dir/initramfs.img"

echo "initramfs build complete: $initramfs_build_dir/initramfs.img"
