#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
image_path="${QEMU_IMAGE:-${1:-}}"
log_file="${QEMU_LOG_FILE:-$root/build/qemu/serial.log}"
serial_mode="${QEMU_SERIAL_MODE:-file}"

[[ -n "$image_path" ]] || die "usage: $0 <image-path>"
[[ -f "$image_path" ]] || die "missing image artifact: $image_path"

if [[ "$serial_mode" == "file" ]]; then
  mkdir -p "$(dirname "$log_file")"
fi

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
ovmf_vars="${OVMF_VARS:-}"
if [[ -z "$ovmf_code" ]]; then
  for candidate in \
  /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.strictnx.fd \
    /usr/share/OVMF/OVMF_CODE_4M.ms.fd \
    /usr/share/OVMF/OVMF_CODE_4M.snakeoil.fd \
    /usr/share/ovmf/OVMF_CODE.fd \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd
  do
    [[ -f "$candidate" ]] && ovmf_code="$candidate" && break
  done
fi

[[ -n "$ovmf_code" && -f "$ovmf_code" ]] || die "unable to locate OVMF_CODE.fd"
if [[ -z "$ovmf_vars" ]]; then
  for candidate in \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
    /usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd
  do
    [[ -f "$candidate" ]] && ovmf_vars="$candidate" && break
  done
fi

[[ -n "$ovmf_vars" && -f "$ovmf_vars" ]] || die "unable to locate OVMF_VARS.fd"

ovmf_vars_runtime="${QEMU_OVMF_VARS_RUNTIME:-$root/build/qemu/OVMF_VARS.fd}"
mkdir -p "$(dirname "$ovmf_vars_runtime")"
cp "$ovmf_vars" "$ovmf_vars_runtime"

hostfwd_port="${QEMU_HOSTFWD_PORT:-2222}"

if [[ "$serial_mode" == "file" ]]; then
  qemu_serial_arg=(-serial "file:$log_file")
else
  qemu_serial_arg=(-serial "$serial_mode")
fi

if [[ -n "$hostfwd_port" && "$hostfwd_port" != "none" ]]; then
  qemu_netdev_arg=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${hostfwd_port}-:22")
else
  qemu_netdev_arg=(-netdev "user,id=net0")
fi

qemu-system-x86_64 \
  -machine q35,accel=kvm:tcg \
  -cpu max \
  -m "${QEMU_MEMORY:-1G}" \
  -smp "${QEMU_CPUS:-2}" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,unit=1,file="$ovmf_vars_runtime" \
  -drive if=none,file="$image_path",id=bootdisk,format=raw \
  -device virtio-blk-pci,drive=bootdisk,bootindex=1 \
  "${qemu_netdev_arg[@]}" \
  -device virtio-net-pci,netdev=net0 \
  "${qemu_serial_arg[@]}" \
  -display none
