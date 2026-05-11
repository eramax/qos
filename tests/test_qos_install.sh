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

stage_base="$(mktemp -d "$repo_root/build/task-qos-install.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

picker_output="$stage_base/picker.out"

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

echo "ok"
