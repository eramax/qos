#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
image_path="${QEMU_IMAGE:-${1:-}}"
log_file="${QEMU_LOG_FILE:-$root/build/qemu/serial.log}"

[[ -n "$image_path" ]] || die "usage: $0 <image-path>"
[[ -f "$image_path" ]] || die "missing image artifact: $image_path"

mkdir -p "$(dirname "$log_file")"

if [[ "${QEMU_RUN_MOCK:-0}" == "1" ]]; then
  cat > "$log_file" <<'EOF'
Limine: booting Linux
Linux: kernel handoff to init
s6: supervision started
network: DHCP lease acquired on eth0
dropbear: listening on port 22
EOF
  echo "$log_file"
  exit 0
fi

require_cmd qemu-system-x86_64

ovmf_code="${OVMF_CODE:-}"
if [[ -z "$ovmf_code" ]]; then
  for candidate in \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd
  do
    [[ -f "$candidate" ]] && ovmf_code="$candidate" && break
  done
fi

[[ -n "$ovmf_code" && -f "$ovmf_code" ]] || die "unable to locate OVMF_CODE.fd"

qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu max \
  -m "${QEMU_MEMORY:-512M}" \
  -bios "$ovmf_code" \
  -drive file="$image_path",if=virtio,format=raw \
  -serial file:"$log_file" \
  -display none

