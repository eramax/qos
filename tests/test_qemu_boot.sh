#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/scripts/run-qemu.sh" ]] || die "missing run-qemu.sh"
[[ -x "$repo_root/scripts/assemble-image.sh" ]] || die "missing assemble-image.sh"
[[ -x "$repo_root/scripts/build-rootfs.sh" ]] || die "missing build-rootfs.sh"
grep -q 'scripts/qemu-host-net-up.sh' "$repo_root/README.md" || die "README must document qemu-host-net-up.sh"
grep -q 'scripts/qemu-host-net-down.sh' "$repo_root/README.md" || die "README must document qemu-host-net-down.sh"
grep -q 'QEMU_BRIDGE_IFACE=br0' "$repo_root/README.md" || die "README must document explicit br0 usage"
grep -q 'make full' "$repo_root/README.md" || die "README must document make full"
grep -q 'make live' "$repo_root/README.md" || die "README must document make live"
grep -q 'make qemu' "$repo_root/README.md" || die "README must document make qemu"
grep -q 'make kernel' "$repo_root/README.md" || die "README must document make kernel"
grep -qxF 'QEMU_MEMORY ?= 1G' "$repo_root/Makefile" || die "make qemu default memory must be 1G"
grep -qxF 'QEMU_CPUS ?= 2' "$repo_root/Makefile" || die "make qemu default cpu count must be 2"
grep -qxF 'QEMU_NET_MODE ?= tap' "$repo_root/Makefile" || die "make qemu default network mode must be tap"
grep -qxF 'QEMU_BRIDGE_IFACE ?= br0' "$repo_root/Makefile" || die "make qemu default bridge interface must be br0"
! grep -qxF 'QEMU_BRIDGE_IFACE ?= auto' "$repo_root/Makefile" || die "make qemu must not default bridge interface to auto"
grep -q "'full         - build the live ISO" "$repo_root/Makefile" || die "make help must describe full as the live ISO build"
grep -q "'live         - boot the live ISO in QEMU" "$repo_root/Makefile" || die "make help must describe live target"
grep -q "'qemu         - boot from the installed disk" "$repo_root/Makefile" || die "make help must describe installed-disk qemu target"
grep -q "scripts/qemu-host-net-up.sh first" "$repo_root/Makefile" || die "make help must mention qemu-host-net-up.sh prerequisite"
! grep -q "'qemu2" "$repo_root/Makefile" || die "make help must not advertise qemu2"
! grep -q "'boot         -" "$repo_root/Makefile" || die "make help must not advertise boot"
[[ -x "$repo_root/scripts/qemu-tap.sh" ]] || die "missing qemu tap helper"

stage_base="$(mktemp -d "$repo_root/build/task7-qemu.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

tap_helper_log="$stage_base/tap-helper.log"
QEMU_TAP_MOCK=1 "$repo_root/scripts/qemu-tap.sh" setup qtap0 br0 >"$tap_helper_log"
grep -q 'ip tuntap add dev qtap0 mode tap' "$tap_helper_log" || die "missing tap creation command"
grep -q 'ip link set qtap0 master br0' "$tap_helper_log" || die "missing tap bridge attach command"
! grep -q 'ip link add br0 type bridge' "$tap_helper_log" || die "tap helper must not create bridges"

rootfs_dir="$stage_base/rootfs"
image_build_dir="$stage_base/image"
image_output_dir="$stage_base/dist"
image_name="qos-qemu.raw"
log_file="$stage_base/serial.log"

ROOTFS_SKIP_APK=1 ROOTFS_DIR="$rootfs_dir" "$repo_root/scripts/build-rootfs.sh" >/dev/null
IMAGE_BUILD_MOCK=1 \
ROOTFS_DIR="$rootfs_dir" \
IMAGE_BUILD_DIR="$image_build_dir" \
IMAGE_OUTPUT_DIR="$image_output_dir" \
IMAGE_NAME="$image_name" \
"$repo_root/scripts/assemble-image.sh" >/dev/null

QEMU_RUN_MOCK=1 QEMU_LOG_FILE="$log_file" QEMU_IMAGE="$image_output_dir/$image_name" "$repo_root/scripts/run-qemu.sh" >/dev/null

for phrase in \
  "Limine: booting Linux" \
  "Linux: kernel handoff to init" \
  "s6: supervision started" \
  "network: DHCP lease acquired on eth0" \
  "dropbear: listening on port 22" \
  "network: tap via helper"; do
  grep -qxF "$phrase" "$log_file" || die "missing boot marker: $phrase"
done

nat_log="$stage_base/nat.log"
QEMU_RUN_MOCK=1 \
QEMU_NET_MODE=nat \
QEMU_HOSTFWD_PORT=2222 \
QEMU_LOG_FILE="$nat_log" \
QEMU_IMAGE="$image_output_dir/$image_name" \
  "$repo_root/scripts/run-qemu.sh" >/dev/null
grep -qxF 'network: nat via 127.0.0.1:2222 -> 22' "$nat_log" || die "missing nat fallback marker"

missing_bridge_stderr="$stage_base/missing-bridge.stderr"
if QEMU_NET_MODE=tap \
QEMU_BRIDGE_IFACE=definitely-not-a-bridge \
QEMU_IMAGE="$image_output_dir/$image_name" \
QEMU_OVMF_VARS_RUNTIME="$stage_base/OVMF_VARS.fd" \
  "$repo_root/scripts/run-qemu.sh" >/dev/null 2>"$missing_bridge_stderr"; then
  die "bridge mode must fail when the requested bridge does not exist"
fi
grep -q 'error: missing bridge interface: definitely-not-a-bridge' "$missing_bridge_stderr" || die "missing explicit bridge failure message"

installed_log="$stage_base/installed.log"
QEMU_RUN_MOCK=1 \
QEMU_BOOT_DISK=installed \
QEMU_LOG_FILE="$installed_log" \
  "$repo_root/scripts/run-qemu.sh" >/dev/null
grep -qxF 'network: tap via helper' "$installed_log" || die "installed-disk boot must not require a raw image artifact"

echo "ok"
