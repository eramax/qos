#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  echo "error: $*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$here/.." && pwd -P)"

[[ -x "$repo_root/scripts/qemu-host-net-up.sh" ]] || die "missing qemu-host-net-up.sh"
[[ -x "$repo_root/scripts/qemu-host-net-down.sh" ]] || die "missing qemu-host-net-down.sh"

stage_base="$(mktemp -d "$repo_root/build/task-host-net.XXXXXX")"
cleanup() {
  chmod -R u+w "$stage_base" 2>/dev/null || true
  rm -rf "$stage_base"
}
trap cleanup EXIT INT TERM

runtime_dir="$stage_base/runtime"
setup_log="$stage_base/setup.log"
teardown_log="$stage_base/teardown.log"

QEMU_HOST_NET_MOCK=1 \
QEMU_HOST_STATE_DIR="$runtime_dir" \
QEMU_HOST_BRIDGE=qemu-test-br0 \
QEMU_HOST_UPLINK=wlp13s0 \
QEMU_HOST_SUBNET=192.168.77.0/24 \
QEMU_HOST_GATEWAY=192.168.77.1 \
QEMU_HOST_DHCP_RANGE=192.168.77.100,192.168.77.199,12h \
QEMU_HOST_FIREWALL_BACKEND=nft \
  "$repo_root/scripts/qemu-host-net-up.sh" >"$setup_log"

grep -qxF 'bridge=qemu-test-br0' "$runtime_dir/bridge" || die "missing bridge state"
grep -qxF 'uplink=wlp13s0' "$runtime_dir/uplink" || die "missing uplink state"
grep -qxF 'backend=nft' "$runtime_dir/firewall-backend" || die "missing firewall backend state"
grep -qxF 'created_bridge=1' "$runtime_dir/created-bridge" || die "missing created bridge marker"
grep -q 'ip link add qemu-test-br0 type bridge' "$setup_log" || die "missing bridge creation command"
grep -q 'ip addr add 192.168.77.1/24 dev qemu-test-br0' "$setup_log" || die "missing bridge address command"
grep -q 'dnsmasq .*--interface=qemu-test-br0' "$setup_log" || die "missing dnsmasq interface binding"
grep -q 'nft add table ip qos_qemu' "$setup_log" || die "missing nft table creation"
grep -qxF 'dhcp-option=6,192.168.77.1' "$runtime_dir/dnsmasq.conf" || die "missing guest DNS advertisement"
! grep -qxF 'port=0' "$runtime_dir/dnsmasq.conf" || die "dnsmasq must keep DNS enabled for guests"

QEMU_HOST_NET_MOCK=1 \
QEMU_HOST_STATE_DIR="$runtime_dir" \
  "$repo_root/scripts/qemu-host-net-down.sh" >"$teardown_log"

grep -q 'dnsmasq-stop' "$teardown_log" || die "missing dnsmasq stop action"
grep -q 'nft delete table ip qos_qemu' "$teardown_log" || die "missing nft cleanup"
grep -q 'ip addr del 192.168.77.1/24 dev qemu-test-br0' "$teardown_log" || die "missing bridge address cleanup"
grep -q 'ip link delete qemu-test-br0 type bridge' "$teardown_log" || die "missing bridge deletion"
[[ ! -e "$runtime_dir/bridge" ]] || die "bridge state file must be cleaned up"

echo "ok"
