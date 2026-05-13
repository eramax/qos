#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/../lib/common.sh"

root="$(repo_root)"
image_path="$root/dist/qos-x86_64.raw"
test_dir="$root/build/ssh-test"
key_path="$test_dir/id_ed25519"
pub_path="${DROPBEAR_AUTHORIZED_KEYS_FILE:-$test_dir/authorized_keys}"
port="${SSH_TEST_PORT:-2222}"
host="root@127.0.0.1"
ssh_opts=(
  -i "$key_path"
  -p "$port"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

require_cmd make ssh ssh-keygen timeout

mkdir -p "$test_dir"
rm -f "$key_path" "$key_path.pub" "$pub_path"
ssh-keygen -q -t ed25519 -N '' -f "$key_path" -C "qos-ssh-test" >/dev/null
cp "$key_path.pub" "$pub_path"
chmod 0600 "$key_path" "$pub_path"

manifest_add "command: builder/tools/ssh-test.sh port=$port"
manifest_add "ssh-test: generated keypair in $test_dir"

DROPBEAR_AUTHORIZED_KEYS_FILE="$pub_path" \
  BUILD_MOCK=0 \
  BUILD_KERNEL_JOBS="${BUILD_KERNEL_JOBS:-15}" \
  BUILD_TOOL_JOBS="${BUILD_TOOL_JOBS:-15}" \
  make services >/dev/null

BUILD_MOCK=0 \
BUILD_KERNEL_JOBS="${BUILD_KERNEL_JOBS:-15}" \
BUILD_TOOL_JOBS="${BUILD_TOOL_JOBS:-15}" \
  make initramfs >/dev/null

BUILD_MOCK=0 \
BUILD_KERNEL_JOBS="${BUILD_KERNEL_JOBS:-15}" \
BUILD_TOOL_JOBS="${BUILD_TOOL_JOBS:-15}" \
  make boot-limine >/dev/null

make image >/dev/null

[[ -f "$image_path" ]] || die "missing image artifact: $image_path"

qemu_log="$test_dir/qemu.log"
QEMU_HOSTFWD_PORT="$port" \
QEMU_NET_MODE=nat \
QEMU_SERIAL_MODE=file \
QEMU_LOG_FILE="$qemu_log" \
  "$script_dir/run-qemu.sh" "$image_path" >/dev/null 2>&1 &
qemu_pid=$!

cleanup() {
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 120); do
  if ssh "${ssh_opts[@]}" "$host" 'true' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

ssh "${ssh_opts[@]}" -tt "$host" 'apk update && apk add btop && timeout 3s btop'

cleanup
trap - EXIT INT TERM
echo "ssh-test complete"
