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
net_mode="${QEMU_NET_MODE:-tap}"
bridge_iface="${QEMU_BRIDGE_IFACE:-auto}"
tap_iface="${QEMU_TAP_IFACE:-q${BASHPID:-$$}}"

select_bridge_iface() {
  local requested="${1:-br0}"
  local candidate

  if [[ "$requested" != "auto" && -d "/sys/class/net/$requested/bridge" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  if [[ -d "/sys/class/net/br0/bridge" ]]; then
    printf '%s\n' "br0"
    return 0
  fi

  for candidate in /sys/class/net/*; do
    candidate="${candidate##*/}"
    [[ -d "/sys/class/net/$candidate/bridge" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

[[ -n "$image_path" ]] || die "usage: $0 <image-path>"
[[ -f "$image_path" ]] || die "missing image artifact: $image_path"

if [[ "$serial_mode" == "file" ]]; then
  mkdir -p "$(dirname "$log_file")"
fi

if [[ "${QEMU_RUN_MOCK:-0}" == "1" ]]; then
  if [[ "$net_mode" == "nat" ]]; then
    if [[ -n "${QEMU_HOSTFWD_PORT:-2222}" && "${QEMU_HOSTFWD_PORT:-2222}" != "none" ]]; then
      network_line="network: nat via 127.0.0.1:${QEMU_HOSTFWD_PORT:-2222} -> 22"
    else
      network_line="network: nat without host forwarding"
    fi
  else
    network_line="network: tap via helper"
  fi
  cat > "$log_file" <<'EOF'
Limine: booting Linux
Linux: kernel handoff to init
s6: supervision started
network: DHCP lease acquired on eth0
dropbear: listening on port 22
EOF
  printf '%s\n' "$network_line" >> "$log_file"
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

case "$net_mode" in
  tap)
    bridge_iface_resolved="$(select_bridge_iface "$bridge_iface")" || die "missing bridge interface: $bridge_iface"
    qemu_tap_setup_script="$script_dir/qemu-tap.sh"
    [[ -x "$qemu_tap_setup_script" ]] || die "missing tap helper: $qemu_tap_setup_script"
    "$qemu_tap_setup_script" setup "$tap_iface" "$bridge_iface_resolved"
    cleanup_tap() {
      "$qemu_tap_setup_script" cleanup "$tap_iface" >/dev/null 2>&1 || true
    }
    trap cleanup_tap EXIT INT TERM
    qemu_netdev_arg=(-netdev "tap,id=net0,ifname=${tap_iface},script=no,downscript=no")
    ;;
  nat)
    if [[ -n "$hostfwd_port" && "$hostfwd_port" != "none" ]]; then
      qemu_netdev_arg=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${hostfwd_port}-:22")
    else
      qemu_netdev_arg=(-netdev "user,id=net0")
    fi
    ;;
  *)
    die "unsupported QEMU_NET_MODE: $net_mode"
    ;;
esac

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
  -chardev socket,id=qga,path="$root/build/qemu/qga.sock",server,nowait \
  -device virtio-serial-pci \
  -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
  "${qemu_serial_arg[@]}" \
  -display none
