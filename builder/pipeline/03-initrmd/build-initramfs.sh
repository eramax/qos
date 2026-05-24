#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../../lib/common.sh"

root="$(repo_root)"
initramfs_config="${INITRAMFS_CONFIG:-$root/builder/pipeline/03-initrmd/mkinitfs.conf}"
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

require_cmd cpio lz4 busybox

[[ -x "$host_busybox" ]] || die "missing host busybox binary"

manifest_add "command: builder/pipeline/03-initrmd/build-initramfs.sh root=$root_label state=$state_label"

mkdir -p "$stage_root/bin" "$stage_root/dev" "$stage_root/proc" "$stage_root/sys" "$stage_root/run" "$stage_root/sysroot"
cp "$host_busybox" "$stage_root/bin/busybox"
chmod 0755 "$stage_root/bin/busybox"
while IFS= read -r applet; do
  [[ "$applet" == "busybox" ]] && continue
  ln -sf busybox "$stage_root/bin/$applet"
done < <("$stage_root/bin/busybox" --list)

modules_src="$rootfs/lib/modules"
if [[ -d "$modules_src" ]]; then
  kver="$(ls -1 "$modules_src" | head -n 1 || true)"
  if [[ -n "$kver" && -d "$modules_src/$kver" ]]; then
    mkdir -p "$stage_root/lib/modules"
    cp -a "$modules_src/$kver" "$stage_root/lib/modules/$kver"
    rm -f "$stage_root/lib/modules/$kver/build" "$stage_root/lib/modules/$kver/source"
    if command -v depmod >/dev/null 2>&1; then
      depmod -b "$stage_root" "$kver" 2>/dev/null || true
    else
      busybox depmod -b "$stage_root" "$kver" 2>/dev/null || true
    fi
  fi
fi

cat > "$stage_root/init" <<EOF
#!/bin/sh
set -eu
PATH=/bin

exec >/dev/console 2>&1
echo "[initramfs] init started"

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

echo "[initramfs] resolving root label \$root_label"
root_dev="\$(findfs "LABEL=\$root_label")"
echo "[initramfs] mounting root device \$root_dev (read-only)"
mkdir -p /ro-root
mount -t ext4 -o ro "\$root_dev" /ro-root

overlay_ok=no
echo "[initramfs] resolving state label \$state_label"
state_dev="\$(findfs "LABEL=\$state_label" 2>/dev/null || true)"

if [ -n "\$state_dev" ]; then
  echo "[initramfs] mounting state device \$state_dev"
  mkdir -p /state
  mount -t ext4 "\$state_dev" /state

  mkdir -p /state/overlay/upper /state/overlay/work

  echo "[initramfs] mounting overlayfs"
  mkdir -p /sysroot
  if mount -t overlay overlay \
      -o "lowerdir=/ro-root,upperdir=/state/overlay/upper,workdir=/state/overlay/work" \
      /sysroot; then
    overlay_ok=yes
    mkdir -p /state/var /sysroot/var
    mount --bind /state/var /sysroot/var
    mkdir -p /state/home /sysroot/home
    mount --bind /state/home /sysroot/home
    # Seed emo home from rootfs on first boot
    if [ ! -d /state/home/emo ] && [ -d /ro-root/home/emo ]; then
      cp -a /ro-root/home/emo /state/home/emo
    fi
    # Fix ownership: rootfs was built by a non-root user; correct
    # critical paths so login, dropbear, and apk work inside the VM.
    chown 0:0 /sysroot/root
    chown -R 0:0 /sysroot/root/.ssh
    chmod 700 /sysroot/root/.ssh
    chown 0:0 /sysroot/etc/shadow
    chmod 640 /sysroot/etc/shadow
  else
    echo "[initramfs] WARN: overlay mount failed, booting read-only"
    mount --move /ro-root /sysroot
  fi
else
  echo "[initramfs] WARN: no state partition, booting read-only"
  mkdir -p /sysroot
  mount --move /ro-root /sysroot
fi

if [ -f /sysroot/etc/hostname ]; then
  hostname_value="\$(tr -d '\\r\\n' < /sysroot/etc/hostname)"
  if [ -n "\$hostname_value" ]; then
    echo "\$hostname_value" > /proc/sys/kernel/hostname
  fi
fi

echo "[initramfs] mounting essential filesystems"
mkdir -p /sysroot/proc /sysroot/sys /sysroot/dev /sysroot/run /sysroot/tmp
mount -t proc proc /sysroot/proc
mount -t sysfs sysfs /sysroot/sys
mkdir -p /sysroot/sys/fs/cgroup
mount -t cgroup2 cgroup2 /sysroot/sys/fs/cgroup
if [ -w /sysroot/sys/fs/cgroup/cgroup.subtree_control ]; then
  echo '+cpuset +cpu +memory +pids' > /sysroot/sys/fs/cgroup/cgroup.subtree_control || true
fi
mount -t devtmpfs devtmpfs /sysroot/dev
mkdir -p /sysroot/dev/pts
mount -t devpts devpts /sysroot/dev/pts -o gid=5,mode=620,ptmxmode=666
mkdir -p /sysroot/dev/shm
mount -t tmpfs tmpfs -o nosuid,nodev,noexec /sysroot/dev/shm
mount -t tmpfs tmpfs /sysroot/run
mount -t tmpfs tmpfs -o nosuid,nodev,mode=1777 /sysroot/tmp

# Fix setuid binaries and sensitive files that lose correct ownership
# when the rootfs is built by a non-root user.
chown 0:0 /sysroot/usr/bin/sudo 2>/dev/null && chmod 4755 /sysroot/usr/bin/sudo 2>/dev/null || true
chown 0:0 /sysroot/usr/bin/su 2>/dev/null && chmod 4755 /sysroot/usr/bin/su 2>/dev/null || true
chown 0:0 /sysroot/etc/sudo.conf /sysroot/etc/sudoers.d 2>/dev/null || true
chown 0:0 /sysroot/etc/sudoers 2>/dev/null && chmod 0440 /sysroot/etc/sudoers 2>/dev/null || true
chown 0:0 /sysroot/var/lib/sudo 2>/dev/null || true

# Stamp boot-source so stale live-cdrom values from overlay don't persist
mkdir -p /sysroot/etc/qos 2>/dev/null || true
printf 'installed-disk\n' > /sysroot/etc/qos/boot-source 2>/dev/null || true

echo "[initramfs] switching to /sbin/init"
exec switch_root /sysroot /sbin/init
EOF
chmod 0755 "$stage_root/init"

( cd "$stage_root" && find . -print0 | cpio --null -o -H newc ) | lz4 -l -z -q -c > "$initramfs_build_dir/initramfs.img"

echo "initramfs build complete: $initramfs_build_dir/initramfs.img"
