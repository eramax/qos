#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

mock_mode="${QEMU_TAP_MOCK:-0}"

print_cmd() {
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
}

run_privileged() {
  if [[ "$mock_mode" == "1" ]]; then
    print_cmd "$@"
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

command="${1:-}"
tap_iface="${2:-}"
bridge_iface="${3:-}"
owner_user="${SUDO_USER:-$(id -un)}"

case "$command" in
  setup)
    [[ -n "$tap_iface" && -n "$bridge_iface" ]] || die "usage: $0 setup <tap-iface> <bridge-iface>"
    if [[ "$mock_mode" != "1" ]]; then
      [[ -d "/sys/class/net/$bridge_iface/bridge" ]] || die "missing bridge interface: $bridge_iface"
    fi
    run_privileged ip tuntap add dev "$tap_iface" mode tap user "$owner_user"
    run_privileged ip link set "$tap_iface" master "$bridge_iface"
    run_privileged ip link set "$tap_iface" up
    ;;
  cleanup)
    [[ -n "$tap_iface" ]] || die "usage: $0 cleanup <tap-iface>"
    if run_privileged ip link show "$tap_iface" >/dev/null 2>&1; then
      run_privileged ip link set "$tap_iface" down || true
      run_privileged ip link delete "$tap_iface" mode tap || run_privileged ip link delete "$tap_iface" || true
    fi
    ;;
  *)
    die "usage: $0 {setup|cleanup} <tap-iface> [bridge-iface]"
    ;;
esac
