#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../lib/common.sh"

root="$(repo_root)"
image_path="${QEMU_IMAGE:-${1:-}}"
log_file="${QEMU_LOG_FILE:-$root/build/qemu/serial.log}"
serial_mode="${QEMU_SERIAL_MODE:-file}"
net_mode="${QEMU_NET_MODE:-tap}"
bridge_iface="${QEMU_BRIDGE_IFACE:-br0}"
tap_iface="${QEMU_TAP_IFACE:-q${BASHPID:-$$}}"
boot_disk="${QEMU_BOOT_DISK:-primary}"  # primary or installed

nat_network_line() {
  if [[ -n "${QEMU_HOSTFWD_PORT:-2222}" && "${QEMU_HOSTFWD_PORT:-2222}" != "none" ]]; then
    printf 'network: nat via 127.0.0.1:%s -> 22\n' "${QEMU_HOSTFWD_PORT:-2222}"
  else
    printf 'network: nat without host forwarding\n'
  fi
}

configure_nat_network() {
  local hostfwd_port="${QEMU_HOSTFWD_PORT:-2222}"
  if [[ -n "$hostfwd_port" && "$hostfwd_port" != "none" ]]; then
    qemu_netdev_arg=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${hostfwd_port}-:22")
  else
    qemu_netdev_arg=(-netdev "user,id=net0")
  fi
}

if [[ "$boot_disk" != "installed" ]]; then
  [[ -n "$image_path" || -n "${QEMU_ISO:-}" ]] || die "usage: $0 <image-path>"
fi
if [[ -n "$image_path" ]]; then
  [[ -f "$image_path" ]] || die "missing image artifact: $image_path"
fi

if [[ "$serial_mode" == "file" ]]; then
  mkdir -p "$(dirname "$log_file")"
fi

if [[ "${QEMU_RUN_MOCK:-0}" == "1" ]]; then
  if [[ "$net_mode" == "nat" ]]; then
    network_line="$(nat_network_line)"
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

# Create extra 1GB disk for qos-install testing
extra_disk="${QEMU_EXTRA_DISK:-$root/build/qemu/extra-disk.raw}"
extra_disk_size="${QEMU_EXTRA_DISK_SIZE:-1G}"
mkdir -p "$(dirname "$extra_disk")"
if [[ ! -f "$extra_disk" ]]; then
  truncate -s "$extra_disk_size" "$extra_disk"
fi

if [[ "$serial_mode" == "file" ]]; then
  qemu_serial_arg=(-serial "file:$log_file")
else
  qemu_serial_arg=(-serial "$serial_mode")
fi

case "$net_mode" in
  tap)
    if [[ ! -d "/sys/class/net/$bridge_iface/bridge" ]]; then
      echo "WARNING: bridge $bridge_iface not found, falling back to NAT. Run 'sudo builder/tools/qemu-host-net-up.sh' for tap mode."
      configure_nat_network
    else
      if ! "$script_dir/qemu-tap.sh" setup "$tap_iface" "$bridge_iface" 2>/dev/null; then
        echo "WARNING: tap setup failed (sudo needed?), using NAT instead."
        configure_nat_network
      else
        cleanup_tap() {
          "$script_dir/qemu-tap.sh" cleanup "$tap_iface" >/dev/null 2>&1 || true
        }
        trap cleanup_tap EXIT INT TERM
        qemu_netdev_arg=(-netdev "tap,id=net0,ifname=${tap_iface},script=no,downscript=no")
      fi
    fi
    ;;
  nat)
    configure_nat_network
    ;;
  *)
    die "unsupported QEMU_NET_MODE: $net_mode"
    ;;
esac

# Display selection. Default is headless (no window) for server-style
# boots; set QEMU_DISPLAY=gtk (or sdl/spice-app) to open a window.
qemu_display="${QEMU_DISPLAY:-none}"
qemu_display_args=()
qemu_vga="${QEMU_VGA:-virtio-vga}"
if [[ "$qemu_display" != "none" ]]; then
  if [[ "$qemu_vga" == *gl* ]]; then
    qemu_display_args=(-vga none -display "$qemu_display,gl=on" \
      -device "$qemu_vga,xres=1280,yres=800,blob=on,hostmem=256M")
  else
    qemu_display_args=(-display "$qemu_display" -device "$qemu_vga")
  fi
fi

qemu_system_args=(
  -machine q35,accel=kvm:tcg
  -cpu max
  -m "${QEMU_MEMORY:-1G}"
  -smp "${QEMU_CPUS:-2}"
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf_code"
  -drive if=pflash,format=raw,unit=1,file="$ovmf_vars_runtime"
  "${qemu_netdev_arg[@]}"
  -device virtio-net-pci,netdev=net0
  -chardev socket,id=qga,path="$root/build/qemu/qga.sock",server=on,wait=off
  -device virtio-serial-pci
  -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0
  -device qemu-xhci
  -device usb-tablet
  "${qemu_serial_arg[@]}"
  "${qemu_display_args[@]}"
)

# Boot from ISO or raw disk based on boot_disk setting
if [[ "$boot_disk" == "installed" ]]; then
  # Boot from installed disk ONLY - unplug the small source image.
  # QEMU renames the first attached drive to /dev/vda automatically.
  qemu_system_args=(
    "${qemu_system_args[@]}"
    -drive if=none,file="$extra_disk",format=raw,id=extradisk
    -device virtio-blk-pci,drive=extradisk,bootindex=0
  )
elif [[ -f "${QEMU_ISO:-}" ]]; then
  # Boot from ISO (live CD) via virtio-scsi for firmware boot, and also
  # attach the same ISO file as a read-only virtio-blk disk so Linux can
  # mount it reliably as a normal block device during live-init.
  qemu_system_args=(
    "${qemu_system_args[@]}"
    -device virtio-scsi-pci,id=scsi0
    -drive if=none,file="${QEMU_ISO}",media=cdrom,id=iso0
    -device scsi-cd,bus=scsi0.0,drive=iso0,bootindex=0
    -drive if=none,file="${QEMU_ISO}",format=raw,readonly=on,id=isoblk
    -device virtio-blk-pci,drive=isoblk
    -drive if=none,file="$extra_disk",format=raw,id=extradisk
    -device virtio-blk-pci,drive=extradisk,bootindex=1
  )
else
  # Boot from raw disk image (primary disk)
  qemu_system_args=(
    -drive if=none,file="$image_path",id=bootdisk,format=raw
    -device virtio-blk-pci,drive=bootdisk,bootindex=0
    "${qemu_system_args[@]}"
    -drive if=none,file="$extra_disk",format=raw,id=extradisk
    -device virtio-blk-pci,drive=extradisk,bootindex=1
  )
fi

echo "Booting: $boot_disk disk"
if [[ -f "${QEMU_ISO:-}" ]]; then
  echo "  ISO: ${QEMU_ISO}"
fi

exec qemu-system-x86_64 "${qemu_system_args[@]}"
