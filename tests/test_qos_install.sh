#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/scripts/qos-install.sh" ]] || die "missing qos-install.sh"
grep -qF 'interface_branding: QOS via Limine' "$repo_root/scripts/qos-install.sh" || die "installer must write branded Limine config"
grep -qF 'console=tty0 console=ttyS0,115200n8' "$repo_root/scripts/qos-install.sh" || die "installer must write dual-console Limine cmdline"
grep -qF 'make qemu       (boot from installed disk)' "$repo_root/scripts/qos-install.sh" || die "installer next-step text must point to make qemu"
grep -qF '/var/lib/cloud' "$repo_root/scripts/qos-install.sh" || die "installer must clean cloud-init instance state"
grep -qF 'cloud-init clean' "$repo_root/scripts/qos-install.sh" || die "installer must reset cloud-init state on installed systems"

stage_base="$(mktemp -d "$repo_root/build/task-qos-install.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

picker_output="$stage_base/picker.out"
fallback_output="$stage_base/fallback.out"
fake_sys="$stage_base/sys-block"

mkdir -p "$fake_sys/vda/device" "$fake_sys/vda"
printf '2097152\n' > "$fake_sys/vda/size"
printf 'Virtio Disk\n' > "$fake_sys/vda/device/model"

mkdir -p "$fake_sys/nvme0n1/device" "$fake_sys/nvme0n1"
printf '1048576\n' > "$fake_sys/nvme0n1/size"
printf 'NVMe Disk\n' > "$fake_sys/nvme0n1/device/model"

mkdir -p "$fake_sys/vda1"
printf '1\n' > "$fake_sys/vda1/partition"

printf '2\n' | \
QOS_INSTALL_TEST_MODE=1 \
QOS_INSTALL_TEST_DISKS='/dev/vda|1024M|QEMU Disk
/dev/sda|512G|Samsung SSD' \
QOS_INSTALL_TEST_EXIT_AFTER_SELECT=1 \
  "$repo_root/scripts/qos-install.sh" >"$picker_output"

grep -q 'Available target disks:' "$picker_output" || die "missing disk picker header"
grep -q '1) /dev/vda' "$picker_output" || die "missing first disk option"
grep -q '2) /dev/sda' "$picker_output" || die "missing second disk option"
grep -q 'selected: /dev/sda' "$picker_output" || die "disk picker did not select numbered option"

printf '2\n' | \
QOS_INSTALL_TEST_MODE=1 \
QOS_INSTALL_TEST_SYS_BLOCK_DIR="$fake_sys" \
QOS_INSTALL_TEST_DISABLE_LSBLK=1 \
QOS_INSTALL_TEST_EXIT_AFTER_SELECT=1 \
  "$repo_root/scripts/qos-install.sh" >"$fallback_output"

grep -q '1) /dev/nvme0n1' "$fallback_output" || die "missing fallback nvme disk option"
grep -q '2) /dev/vda' "$fallback_output" || die "missing fallback virtio disk option"
! grep -q '/dev/vda1' "$fallback_output" || die "fallback picker must not list partitions"
grep -q 'selected: /dev/vda' "$fallback_output" || die "fallback picker did not select numbered option"

echo "ok"
