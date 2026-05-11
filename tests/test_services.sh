#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

for script in scripts/build-rootfs.sh scripts/install-services.sh; do
  [[ -x "$repo_root/$script" ]] || die "missing $script"
done

stage_base="$(mktemp -d "$repo_root/build/task5.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

rootfs_dir="$stage_base/rootfs"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/install-services.sh" >/dev/null

[[ -f "$rootfs_dir/etc/dropbear/dropbear.conf" ]] || die "missing dropbear config"
[[ -f "$rootfs_dir/etc/nftables/nftables.conf" ]] || die "missing nftables config"
[[ -f "$rootfs_dir/etc/network/interfaces.dhcp" ]] || die "missing DHCP config"
[[ -x "$rootfs_dir/etc/s6/service-tree/networking/run" ]] || die "missing networking run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/dropbear/run" ]] || die "missing dropbear run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/nftables/run" ]] || die "missing nftables run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/zram/run" ]] || die "missing zram run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" ]] || die "missing qemu-ga run script"
[[ -f "$rootfs_dir/etc/s6/s6-rc.d/networking/type" ]] || die "missing networking s6-rc type"
[[ -f "$rootfs_dir/etc/s6/s6-rc.d/dropbear/type" ]] || die "missing dropbear s6-rc type"
[[ -f "$rootfs_dir/etc/s6/s6-rc.d/nftables/type" ]] || die "missing nftables s6-rc type"
[[ -f "$rootfs_dir/etc/s6/s6-rc.d/zram/type" ]] || die "missing zram s6-rc type"
[[ -d "$rootfs_dir/etc/s6-linux-init/current/env" ]] || die "missing s6-linux-init env dir"
[[ -d "$rootfs_dir/etc/s6-linux-init/current/run-image" ]] || die "missing s6-linux-init run-image"
[[ -x "$rootfs_dir/etc/s6-linux-init/current/scripts/runlevel" ]] || die "missing s6-linux-init runlevel script"
[[ -L "$rootfs_dir/sbin/init" ]] || die "missing init symlink"

grep -qxF 'DROPBEAR_EXTRA_ARGS="-s -j -k"' "$rootfs_dir/etc/dropbear/dropbear.conf" || die "dropbear config is not key-only"
grep -qxF 'auto eth0' "$rootfs_dir/etc/network/interfaces.dhcp" || die "network config missing auto eth0"
grep -qxF 'iface eth0 inet dhcp' "$rootfs_dir/etc/network/interfaces.dhcp" || die "network config missing DHCP stanza"
grep -q '/bin/busybox udhcpc' "$rootfs_dir/etc/s6/service-tree/networking/run" || die "networking service does not use DHCP client"
grep -q '/usr/sbin/dropbear -R -F -E' "$rootfs_dir/etc/s6/service-tree/dropbear/run" || die "dropbear service not foregrounded"
grep -q '/usr/sbin/nft -f /etc/nftables/nftables.conf' "$rootfs_dir/etc/s6/service-tree/nftables/run" || die "nftables service does not load the firewall rules"
grep -q '/sys/class/zram-control/hot_add' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not create a zram device"
grep -q '/sys/class/virtio-ports' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must inspect virtio ports in sysfs"
grep -q '/dev/vport' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must support direct /dev/vport devices"
grep -q 'org.qemu.guest_agent.0' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must resolve the guest agent port by name"
! grep -q '"\$QGA_BIN" -d' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must not daemonize under s6"
grep -q '/proc/swaps' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service must short-circuit when swap is already active"
grep -q 'comp_algorithm' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not set a compression algorithm"
grep -q '/bin/busybox awk' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service must use busybox awk"
grep -q 'swapon' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not enable swap"
grep -q 'table inet filter' "$rootfs_dir/etc/nftables/nftables.conf" || die "nftables config missing inet filter table"
! grep -q 'iptables' "$rootfs_dir/etc/nftables/nftables.conf" || die "nftables config must not mention iptables"

if find "$rootfs_dir/etc" -perm -u=w -print | grep -q .; then
  die "/etc should be hardened back to read-only after staging"
fi

echo "ok"
