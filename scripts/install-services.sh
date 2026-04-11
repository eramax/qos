#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
rootfs="${ROOTFS_DIR:-$root/build/rootfs}"

[[ -d "$rootfs" ]] || die "missing rootfs dir: $rootfs"

etc_dir="$rootfs/etc"
[[ -d "$etc_dir" ]] || die "missing /etc in rootfs: $etc_dir"

chmod u+w "$etc_dir"
mkdir -p "$etc_dir/s6/service-tree" "$etc_dir/s6/s6-rc.d" "$etc_dir/dropbear" "$etc_dir/nftables" "$etc_dir/network"

cp -a "$root/config/s6/service-tree/." "$etc_dir/s6/service-tree/"
cp -a "$root/config/s6/s6-rc.d/." "$etc_dir/s6/s6-rc.d/"
install -m 0644 "$root/config/dropbear/dropbear.conf" "$etc_dir/dropbear/dropbear.conf"
install -m 0644 "$root/config/nftables/nftables.conf" "$etc_dir/nftables/nftables.conf"
install -m 0644 "$root/config/network/interfaces.dhcp" "$etc_dir/network/interfaces.dhcp"

# Re-harden the staged configuration tree for the immutable image.
chmod -R a-w "$etc_dir"

echo "service configs staged into $rootfs"

