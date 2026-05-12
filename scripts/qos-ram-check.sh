#!/usr/bin/env bash
# qos-ram-check - boot the live ISO in QEMU with a constrained memory
# budget and assert MemAvailable after the system reaches a steady state.
#
# This converts the "<64MB server" target from a marketing claim into a
# CI assertion. See docs/FEATURE-REVIEW-AND-IDEAS.md §2.1.
#
# Strategy:
#   1. boot the ISO in QEMU with -m $QEMU_MEMORY
#   2. wait for SSH (dropbear) to come up
#   3. ssh in, scrape /proc/meminfo
#   4. fail if MemUsed exceeds the per-profile budget

set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$script_dir/lib/common.sh"

ROOT="$(repo_root)"

PROFILE="${QOS_PROFILE:-server}"
case "$PROFILE" in
    server)  BUDGET_KB="${QOS_RAM_BUDGET_KB:-131072}" ;;  # 128MB (k3s installed, off by default)
    desktop) BUDGET_KB="${QOS_RAM_BUDGET_KB:-524288}" ;;  # 512MB (Wayland + Chromium + Steam)
    *) die "unknown profile: $PROFILE (server|desktop)" ;;
esac

ISO="${QOS_ISO:-$ROOT/dist/qos-x86_64.iso}"
QEMU_MEMORY="${QEMU_MEMORY:-128}"  # MB given to the VM
SSH_PORT="${QOS_RAM_SSH_PORT:-2299}"
SSH_USER="${QOS_RAM_SSH_USER:-root}"
SSH_PASS="${QOS_RAM_SSH_PASS:-root}"
BOOT_TIMEOUT="${QOS_RAM_BOOT_TIMEOUT:-90}"

[[ -f "$ISO" ]] || die "ISO not found: $ISO (run 'make full' first)"
require_cmd qemu-system-x86_64 sshpass ssh

workdir="$(mktemp -d)"
cleanup_on_exit "rm -rf '$workdir'"

qemu_log="$workdir/qemu.log"
qemu_pid_file="$workdir/qemu.pid"

echo "==> booting ISO with ${QEMU_MEMORY}M for profile '$PROFILE' (budget: ${BUDGET_KB}KB)"
qemu-system-x86_64 \
    -m "$QEMU_MEMORY" \
    -smp 1 \
    -enable-kvm \
    -cpu host \
    -nographic \
    -no-reboot \
    -bios /usr/share/ovmf/OVMF.fd \
    -cdrom "$ISO" \
    -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
    -device virtio-net,netdev=net0 \
    -pidfile "$qemu_pid_file" \
    >"$qemu_log" 2>&1 &

qemu_pid=$!
cleanup_on_exit "kill $qemu_pid 2>/dev/null || true"

echo "==> waiting up to ${BOOT_TIMEOUT}s for SSH on localhost:${SSH_PORT}"
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while (( $(date +%s) < deadline )); do
    if sshpass -p "$SSH_PASS" \
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=2 -p "$SSH_PORT" \
            "$SSH_USER@127.0.0.1" 'true' 2>/dev/null; then
        break
    fi
    sleep 2
done

if ! sshpass -p "$SSH_PASS" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" "$SSH_USER@127.0.0.1" 'true' 2>/dev/null; then
    echo "--- qemu log (last 60 lines) ---"
    tail -n 60 "$qemu_log" || true
    die "SSH never came up within ${BOOT_TIMEOUT}s"
fi

# Let services settle for a few seconds before sampling.
sleep 5

meminfo="$(sshpass -p "$SSH_PASS" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" "$SSH_USER@127.0.0.1" 'cat /proc/meminfo')"

mem_total_kb=$(printf '%s\n' "$meminfo" | awk '/^MemTotal:/{print $2}')
mem_avail_kb=$(printf '%s\n' "$meminfo" | awk '/^MemAvailable:/{print $2}')
mem_used_kb=$(( mem_total_kb - mem_avail_kb ))

printf 'profile:        %s\n' "$PROFILE"
printf 'MemTotal:       %d KB\n' "$mem_total_kb"
printf 'MemAvailable:   %d KB\n' "$mem_avail_kb"
printf 'MemUsed:        %d KB\n' "$mem_used_kb"
printf 'Budget:         %d KB\n' "$BUDGET_KB"

if (( mem_used_kb > BUDGET_KB )); then
    die "RAM budget exceeded: used ${mem_used_kb}KB > budget ${BUDGET_KB}KB"
fi

echo "==> ram-check ok (${mem_used_kb}KB <= ${BUDGET_KB}KB)"
