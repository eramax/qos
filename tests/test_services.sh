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
grep -qxF 'cloud-init' "$repo_root/config/apk/packages.system" || die "system package manifest must include cloud-init"
grep -qxF 'ifupdown-ng' "$repo_root/config/apk/packages.system" || die "system package manifest must include ifupdown-ng"

stage_base="$(mktemp -d "$repo_root/build/task5.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

rootfs_dir="$stage_base/rootfs"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
QOS_BUILD_VERSION='QOS build: 2026-05-12 09:30:41 UTC (git deadbeef)' ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/install-services.sh" >/dev/null

[[ -f "$rootfs_dir/etc/dropbear/dropbear.conf" ]] || die "missing dropbear config"
[[ -f "$rootfs_dir/etc/cloud/cloud.cfg" ]] || die "missing base cloud-init config"
! [[ -f "$rootfs_dir/etc/cloud/cloud.cfg.d/05_qos-cloud-init.cfg" ]] || die "cloud-init drop-in must be removed in favor of base config"
[[ -f "$rootfs_dir/etc/qos/version" ]] || die "missing qos build version file"
grep -qxF 'QOS build: 2026-05-12 09:30:41 UTC (git deadbeef)' "$rootfs_dir/etc/qos/version" || die "qos version file must contain build timestamp"
grep -qxF 'installed-disk' "$rootfs_dir/etc/qos/boot-source" || die "boot source must default to installed-disk"
[[ -x "$rootfs_dir/etc/profile.d/qos-banner.sh" ]] || die "missing qos login banner hook"
[[ -f "$rootfs_dir/etc/nftables/nftables.conf" ]] || die "missing nftables config"
[[ -f "$rootfs_dir/etc/network/interfaces.dhcp" ]] || die "missing DHCP config"
[[ -x "$rootfs_dir/etc/s6/service-tree/cloud-init-local/run" ]] || die "missing cloud-init local run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/cloud-init/run" ]] || die "missing cloud-init run script"
[[ -L "$rootfs_dir/usr/bin/env" ]] || die "missing env symlink for cloud-init wrapper"
[[ -x "$rootfs_dir/etc/s6/service-tree/networking/run" ]] || die "missing networking run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/dropbear/run" ]] || die "missing dropbear run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/getty/run" ]] || die "missing serial getty run script"
[[ -x "$rootfs_dir/etc/s6/service-tree/getty-tty1/run" ]] || die "missing VGA getty run script"
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
grep -q '^datasource_list: \[ ConfigDrive, NoCloud, None \]$' "$rootfs_dir/etc/cloud/cloud.cfg" || die "cloud-init base config must set generic datasource order"
! grep -q '^datasource_list: .*Ec2' "$rootfs_dir/etc/cloud/cloud.cfg" || die "cloud-init base config must not probe EC2 on a generic image"
grep -qxF 'QOS' "$rootfs_dir/etc/motd" || die "motd must be replaced with a QOS placeholder"
grep -q 'cloud-init init --local' "$rootfs_dir/etc/s6/service-tree/cloud-init-local/run" || die "cloud-init local service must run init --local"
grep -q 'cloud-init init' "$rootfs_dir/etc/s6/service-tree/cloud-init/run" || die "cloud-init service must run network stage"
grep -q 'cloud-init modules --mode=config' "$rootfs_dir/etc/s6/service-tree/cloud-init/run" || die "cloud-init service must run config modules"
grep -q 'cloud-init modules --mode=final' "$rootfs_dir/etc/s6/service-tree/cloud-init/run" || die "cloud-init service must run final modules"
[[ "$(readlink "$rootfs_dir/usr/bin/env")" == "/bin/busybox" ]] || die "env symlink must point to busybox"
grep -qxF 'auto eth0' "$rootfs_dir/etc/network/interfaces.dhcp" || die "network config missing auto eth0"
grep -qxF 'iface eth0 inet dhcp' "$rootfs_dir/etc/network/interfaces.dhcp" || die "network config missing DHCP stanza"
grep -q 'cloud-init-local.done' "$rootfs_dir/etc/s6/service-tree/networking/run" || die "networking service must wait for cloud-init local stage"
grep -q '/sbin/ifup -a' "$rootfs_dir/etc/s6/service-tree/networking/run" || die "networking service must apply cloud-init-rendered network config"
grep -q '/bin/busybox udhcpc' "$rootfs_dir/etc/s6/service-tree/networking/run" || die "networking service must retain DHCP fallback"
grep -q '/sbin/getty 115200 ttyS0' "$rootfs_dir/etc/s6/service-tree/getty/run" || die "serial getty must stay on ttyS0"
grep -q '/sbin/getty 115200 tty1' "$rootfs_dir/etc/s6/service-tree/getty-tty1/run" || die "VGA getty must run on tty1"
grep -q '/usr/sbin/dropbear -R -F -E' "$rootfs_dir/etc/s6/service-tree/dropbear/run" || die "dropbear service not foregrounded"
grep -q '/usr/sbin/nft -f /etc/nftables/nftables.conf' "$rootfs_dir/etc/s6/service-tree/nftables/run" || die "nftables service does not load the firewall rules"
grep -q '/sys/class/zram-control/hot_add' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not create a zram device"
grep -q '/sys/class/virtio-ports' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must inspect virtio ports in sysfs"
grep -q '/dev/vport' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must support direct /dev/vport devices"
grep -q 'org.qemu.guest_agent.0' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must resolve the guest agent port by name"
! grep -q '"\$QGA_BIN" -d' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must not daemonize under s6"
grep -q '"\$QGA_BIN" -p "\$RESOLVED_VIRTIO_PATH" -l "\$QGA_LOG/qemu-ga.log" -t "\$QGA_STATE"' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must use -t for state dir"
! grep -q '"\$QGA_BIN".* -s ' "$rootfs_dir/etc/s6/service-tree/qemu-ga/run" || die "qemu-ga service must not pass -s"
grep -q '/proc/swaps' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service must short-circuit when swap is already active"
grep -q 'comp_algorithm' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not set a compression algorithm"
grep -q '/bin/busybox awk' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service must use busybox awk"
grep -q 'swapon' "$rootfs_dir/etc/s6/service-tree/zram/run" || die "zram service does not enable swap"
grep -q 'table inet filter' "$rootfs_dir/etc/nftables/nftables.conf" || die "nftables config missing inet filter table"
! grep -q 'iptables' "$rootfs_dir/etc/nftables/nftables.conf" || die "nftables config must not mention iptables"

banner_noninteractive="$stage_base/banner-noninteractive.out"
banner_interactive="$stage_base/banner-interactive.out"
cat > "$stage_base/meminfo" <<'EOF'
MemTotal:        2097152 kB
EOF
cat > "$stage_base/uptime" <<'EOF'
12345.67 54321.00
EOF
cat > "$stage_base/ip" <<'EOF'
#!/bin/sh
case "$*" in
  *"-4 addr show scope global"*) printf '%s\n' '2: eth0    inet 162.141.92.102/24 brd 162.141.92.255 scope global eth0' ;;
  *"-6 addr show scope global"*) printf '%s\n' '2: eth0    inet6 2001:db8::1234/64 scope global dynamic eth0' ;;
esac
EOF
chmod 0755 "$stage_base/ip"
cat > "$stage_base/boot-source-live" <<'EOF'
live-cdrom
EOF
QOS_ROOTFS="$rootfs_dir" QOS_MEMINFO_FILE="$stage_base/meminfo" QOS_UPTIME_FILE="$stage_base/uptime" QOS_BOOT_SOURCE_FILE="$rootfs_dir/etc/qos/boot-source" QOS_DF_PATH="$stage_base" QOS_IP_BIN="$stage_base/ip" bash -c ". '$rootfs_dir/etc/profile.d/qos-banner.sh'" >"$banner_noninteractive"
[[ ! -s "$banner_noninteractive" ]] || die "banner hook must stay quiet in noninteractive shells"
QOS_BANNER_FORCE=1 QOS_ROOTFS="$rootfs_dir" QOS_MEMINFO_FILE="$stage_base/meminfo" QOS_UPTIME_FILE="$stage_base/uptime" QOS_BOOT_SOURCE_FILE="$stage_base/boot-source-live" QOS_DF_PATH="$stage_base" QOS_IP_BIN="$stage_base/ip" bash -c ". '$rootfs_dir/etc/profile.d/qos-banner.sh'" >"$banner_interactive"
grep -q '^   ____   ___   ____  $' "$banner_interactive" || die "banner must include QOS art"
grep -q '^QOS build: 2026-05-12 09:30:41 UTC (git deadbeef)$' "$banner_interactive" || die "banner must include build version"
grep -q '^Boot: live CD-ROM$' "$banner_interactive" || die "banner must include boot source when live"
grep -q '^Kernel: ' "$banner_interactive" || die "banner must include kernel version"
grep -q '^Uptime: ' "$banner_interactive" || die "banner must include uptime"
grep -q '^IPv4: 162.141.92.102/24$' "$banner_interactive" || die "banner must include IPv4"
grep -q '^IPv6: 2001:db8::1234/64$' "$banner_interactive" || die "banner must include IPv6"
grep -q '^RAM: ' "$banner_interactive" || die "banner must include RAM summary"
grep -q '^Disk: ' "$banner_interactive" || die "banner must include disk summary"

if find "$rootfs_dir/etc" -perm -u=w -print | grep -q .; then
  die "/etc should be hardened back to read-only after staging"
fi

echo "ok"
