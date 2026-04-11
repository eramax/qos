#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
mode="qemu"
image_path="${BOOT_IMAGE:-${1:-}}"

case "${1:-}" in
  --qemu)
    mode="qemu"
    image_path="${BOOT_IMAGE:-${2:-}}"
    ;;
  --smoke)
    mode="smoke"
    image_path="${BOOT_IMAGE:-${2:-}}"
    ;;
  "")
    ;;
  *)
    if [[ "${1:-}" == --* ]]; then
      die "usage: $0 [--qemu|--smoke] <image-path>"
    fi
    ;;
esac

[[ -n "$image_path" ]] || die "usage: $0 [--qemu|--smoke] <image-path>"
[[ -f "$image_path" ]] || die "missing image artifact: $image_path"

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
