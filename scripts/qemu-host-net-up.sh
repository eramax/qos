#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
mock_mode="${QEMU_HOST_NET_MOCK:-0}"
state_dir="${QEMU_HOST_STATE_DIR:-$root/build/qemu/host-net}"
bridge_iface="${QEMU_HOST_BRIDGE:-br0}"
uplink_iface="${QEMU_HOST_UPLINK:-wlp13s0}"
subnet_cidr="${QEMU_HOST_SUBNET:-192.168.77.0/24}"
gateway_addr="${QEMU_HOST_GATEWAY:-192.168.77.1}"
dhcp_range="${QEMU_HOST_DHCP_RANGE:-192.168.77.100,192.168.77.199,12h}"
firewall_backend="${QEMU_HOST_FIREWALL_BACKEND:-}"
dnsmasq_pidfile="$state_dir/dnsmasq.pid"
dnsmasq_leasefile="$state_dir/dnsmasq.leases"
dnsmasq_conf="$state_dir/dnsmasq.conf"

require_root() {
  if [[ "$mock_mode" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "qemu-host-net-up.sh must run as root"
  fi
}

run_cmd() {
  if [[ "$mock_mode" == "1" ]]; then
    local first=1
    local arg
    for arg in "$@"; do
      if [[ $first -eq 1 ]]; then
        printf '%s' "$arg"
        first=0
      else
        printf ' %s' "$arg"
      fi
    done
    printf '\n'
    return 0
  fi
  "$@"
}

choose_firewall_backend() {
  if [[ -n "$firewall_backend" ]]; then
    printf '%s\n' "$firewall_backend"
    return 0
  fi

  if command -v nft >/dev/null 2>&1; then
    printf '%s\n' "nft"
    return 0
  fi

  if command -v iptables >/dev/null 2>&1; then
    printf '%s\n' "iptables"
    return 0
  fi

  die "missing firewall backend: install nft or iptables"
}

ensure_prereqs() {
  require_cmd ip dnsmasq
  firewall_backend="$(choose_firewall_backend)"
  case "$firewall_backend" in
    nft)
      require_cmd nft
      ;;
    iptables)
      require_cmd iptables
      ;;
    *)
      die "unsupported firewall backend: $firewall_backend"
      ;;
  esac
}

ensure_uplink() {
  [[ -d "/sys/class/net/$uplink_iface" ]] || die "missing uplink interface: $uplink_iface"
  if [[ "$mock_mode" != "1" ]]; then
    local operstate
    operstate="$(cat "/sys/class/net/$uplink_iface/operstate" 2>/dev/null || true)"
    [[ "$operstate" == "up" || "$operstate" == "unknown" ]] || die "uplink interface is down: $uplink_iface"
  fi
}

write_state() {
  mkdir -p "$state_dir"
  printf 'bridge=%s\n' "$bridge_iface" > "$state_dir/bridge"
  printf 'uplink=%s\n' "$uplink_iface" > "$state_dir/uplink"
  printf 'backend=%s\n' "$firewall_backend" > "$state_dir/firewall-backend"
  printf 'subnet=%s\n' "$subnet_cidr" > "$state_dir/subnet"
  printf 'gateway=%s\n' "$gateway_addr" > "$state_dir/gateway"
  printf 'pidfile=%s\n' "$dnsmasq_pidfile" > "$state_dir/dnsmasq-pidfile"
  printf 'leasefile=%s\n' "$dnsmasq_leasefile" > "$state_dir/dnsmasq-leasefile"
}

bridge_exists() {
  [[ -d "/sys/class/net/$bridge_iface/bridge" ]]
}

create_bridge() {
  local created_bridge=0

  if bridge_exists; then
    created_bridge=0
  else
    run_cmd ip link add "$bridge_iface" type bridge
    created_bridge=1
  fi

  printf 'created_bridge=%s\n' "$created_bridge" > "$state_dir/created-bridge"
  run_cmd ip addr add "${gateway_addr}/${subnet_cidr#*/}" dev "$bridge_iface"
  run_cmd ip link set "$bridge_iface" up
}

configure_forwarding() {
  if [[ "$mock_mode" == "1" ]]; then
    printf 'sysctl -w net.ipv4.ip_forward=1\n'
    printf 'ip_forward_prev=1\n' > "$state_dir/ip-forward-prev"
    return 0
  fi

  local ip_forward_prev
  ip_forward_prev="$(cat /proc/sys/net/ipv4/ip_forward)"
  printf 'ip_forward_prev=%s\n' "$ip_forward_prev" > "$state_dir/ip-forward-prev"
  if [[ "$ip_forward_prev" != "1" ]]; then
    printf '1\n' > /proc/sys/net/ipv4/ip_forward
  fi
}

install_firewall_rules() {
  case "$firewall_backend" in
    nft)
      run_cmd nft add table ip qos_qemu
      run_cmd nft add chain ip qos_qemu forward "{ type filter hook forward priority 0 ; policy drop ; }"
      run_cmd nft add chain ip qos_qemu postrouting "{ type nat hook postrouting priority 100 ; }"
      run_cmd nft add rule ip qos_qemu forward iifname "$bridge_iface" oifname "$uplink_iface" accept
      run_cmd nft add rule ip qos_qemu forward iifname "$uplink_iface" oifname "$bridge_iface" ct state related,established accept
      run_cmd nft add rule ip qos_qemu postrouting ip saddr "$subnet_cidr" oifname "$uplink_iface" masquerade
      ;;
    iptables)
      run_cmd iptables -t nat -A POSTROUTING -s "$subnet_cidr" -o "$uplink_iface" -j MASQUERADE
      run_cmd iptables -A FORWARD -i "$bridge_iface" -o "$uplink_iface" -j ACCEPT
      run_cmd iptables -A FORWARD -i "$uplink_iface" -o "$bridge_iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      ;;
  esac
}

start_dnsmasq() {
  cat > "$dnsmasq_conf" <<EOF
bind-interfaces
interface=$bridge_iface
except-interface=lo
dhcp-range=$dhcp_range
dhcp-option=3,$gateway_addr
dhcp-option=6,$gateway_addr
dhcp-leasefile=$dnsmasq_leasefile
pid-file=$dnsmasq_pidfile
EOF

  if [[ "$mock_mode" == "1" ]]; then
    printf '12345\n' > "$dnsmasq_pidfile"
    printf 'dnsmasq --conf-file=%s --interface=%s --bind-interfaces\n' "$dnsmasq_conf" "$bridge_iface"
    return 0
  fi

  dnsmasq --conf-file="$dnsmasq_conf"
}

main() {
  require_root
  ensure_prereqs
  ensure_uplink
  mkdir -p "$state_dir"
  write_state
  create_bridge
  configure_forwarding
  install_firewall_rules
  start_dnsmasq
}

main "$@"
