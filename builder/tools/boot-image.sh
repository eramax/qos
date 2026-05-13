#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../lib/common.sh"

root="$(repo_root)"
mode="qemu"
image_path="${BOOT_IMAGE:-${1:-}}"
iso_path=""

case "${1:-}" in
  --qemu)
    mode="qemu"
    image_path="${BOOT_IMAGE:-${2:-}}"
    ;;
  --qemu-iso)
    mode="qemu-iso"
    iso_path="${2:-}"
    [[ -n "$iso_path" ]] || die "usage: $0 --qemu-iso <iso-path>"
    [[ -f "$iso_path" ]] || die "missing ISO: $iso_path"
    ;;
  --smoke)
    mode="smoke"
    image_path="${BOOT_IMAGE:-${2:-}}"
    ;;
  "")
    ;;
  *)
    if [[ "${1:-}" == --* ]]; then
      die "usage: $0 [--qemu|--qemu-iso|--smoke] <image-path>"
    fi
    ;;
esac

if [[ "$mode" == "qemu-iso" ]]; then
  QEMU_SERIAL_MODE=stdio QEMU_ISO="$iso_path" exec "$script_dir/run-qemu.sh" ""
fi

if [[ "${QEMU_BOOT_DISK:-primary}" != "installed" ]]; then
  [[ -n "$image_path" ]] || die "usage: $0 [--qemu|--qemu-iso|--smoke] <image-path>"
  [[ -f "$image_path" ]] || die "missing image artifact: $image_path"
fi

if [[ "$mode" == "qemu" ]]; then
  QEMU_SERIAL_MODE=stdio exec "$script_dir/run-qemu.sh" "$image_path"
fi

log_file="${BOOT_LOG_FILE:-$root/build/boot/boot.log}"
mkdir -p "$(dirname "$log_file")"

set +e
env \
  QEMU_LOG_FILE="$log_file" \
  QEMU_IMAGE="$image_path" \
  timeout "${BOOT_SMOKE_TIMEOUT:-30s}" \
  "$script_dir/run-qemu.sh" "$image_path"
rc=$?
set -e

if [[ $rc -ne 0 && $rc -ne 124 ]]; then
  die "smoke boot failed with exit code $rc"
fi

[[ -f "$log_file" ]] || die "missing smoke log: $log_file"
echo "$log_file"
