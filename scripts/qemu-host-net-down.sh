#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

root="$(repo_root)"
mock_mode="${QEMU_HOST_NET_MOCK:-0}"
state_dir="${QEMU_HOST_STATE_DIR:-$root/build/qemu/host-net}"

require_root() {
  if [[ "$mock_mode" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "qemu-host-net-down.sh must run as root"
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

read_value() {
  local path="$1"
  local key="$2"
  [[ -f "$path" ]] || return 1
  sed -n "s/^${key}=//p" "$path"
}

cleanup_dnsmasq() {
  local pidfile="$1"

  if [[ "$mock_mode" == "1" ]]; then
    printf 'dnsmasq-stop %s\n' "$pidfile"
    return 0
  fi

  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

cleanup_firewall() {
  local backend="$1"
  local bridge_iface="$2"
  local uplink_iface="$3"
  local subnet_cidr="$4"

  case "$backend" in
    nft)
      run_cmd nft delete table ip qos_qemu
      ;;
    iptables)
      run_cmd iptables -t nat -D POSTROUTING -s "$subnet_cidr" -o "$uplink_iface" -j MASQUERADE
      run_cmd iptables -D FORWARD -i "$bridge_iface" -o "$uplink_iface" -j ACCEPT
      run_cmd iptables -D FORWARD -i "$uplink_iface" -o "$bridge_iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      ;;
  esac
}

cleanup_bridge() {
  local bridge_iface="$1"
  local gateway_addr="$2"
  local subnet_cidr="$3"
  local created_bridge="$4"

  run_cmd ip addr del "${gateway_addr}/${subnet_cidr#*/}" dev "$bridge_iface"
  if [[ "$created_bridge" == "1" ]]; then
    run_cmd ip link delete "$bridge_iface" type bridge
  fi
}

restore_ip_forward() {
  local prev="$1"
  if [[ "$mock_mode" == "1" ]]; then
    printf 'sysctl -w net.ipv4.ip_forward=%s\n' "$prev"
    return 0
  fi
  printf '%s\n' "$prev" > /proc/sys/net/ipv4/ip_forward
}

cleanup_state() {
  rm -f \
    "$state_dir/bridge" \
    "$state_dir/uplink" \
    "$state_dir/firewall-backend" \
    "$state_dir/subnet" \
    "$state_dir/gateway" \
    "$state_dir/dnsmasq-pidfile" \
    "$state_dir/dnsmasq-leasefile" \
    "$state_dir/created-bridge" \
    "$state_dir/ip-forward-prev" \
    "$state_dir/dnsmasq.pid" \
    "$state_dir/dnsmasq.leases" \
    "$state_dir/dnsmasq.conf"
  rmdir "$state_dir" 2>/dev/null || true
}

main() {
  require_root

  local bridge_iface uplink_iface backend subnet_cidr gateway_addr created_bridge ip_forward_prev pidfile
  bridge_iface="$(read_value "$state_dir/bridge" bridge)"
  uplink_iface="$(read_value "$state_dir/uplink" uplink)"
  backend="$(read_value "$state_dir/firewall-backend" backend)"
  subnet_cidr="$(read_value "$state_dir/subnet" subnet)"
  gateway_addr="$(read_value "$state_dir/gateway" gateway)"
  created_bridge="$(read_value "$state_dir/created-bridge" created_bridge)"
  ip_forward_prev="$(read_value "$state_dir/ip-forward-prev" ip_forward_prev)"
  pidfile="$(read_value "$state_dir/dnsmasq-pidfile" pidfile)"

  [[ -n "$bridge_iface" ]] || die "missing bridge state"
  [[ -n "$uplink_iface" ]] || die "missing uplink state"
  [[ -n "$backend" ]] || die "missing firewall backend state"
  [[ -n "$subnet_cidr" ]] || die "missing subnet state"
  [[ -n "$gateway_addr" ]] || die "missing gateway state"
  [[ -n "$created_bridge" ]] || die "missing created bridge state"
  [[ -n "$ip_forward_prev" ]] || die "missing ip_forward state"
  [[ -n "$pidfile" ]] || die "missing dnsmasq pidfile state"

  cleanup_dnsmasq "$pidfile"
  cleanup_firewall "$backend" "$bridge_iface" "$uplink_iface" "$subnet_cidr"
  cleanup_bridge "$bridge_iface" "$gateway_addr" "$subnet_cidr" "$created_bridge"
  restore_ip_forward "$ip_forward_prev"
  cleanup_state
}

main "$@"
