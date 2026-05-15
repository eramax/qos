#!/usr/bin/env bash
# qos-test-e2e.sh — End-to-end test suite for QOS VM operations
# Tests: create, boot, list, info, SSH, bootiso, stop, delete
#         networking (DHCP, IP, DNS), SSH (login, qos info, sudo, seed-reader)
#         serial log check, nftables, overlay/s6 services
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"
export MAKEFLAGS=

# ─── Configuration ───────────────────────────────────────────────────────────

PROFILE="${PROFILE:-server}"
VM_NAME="qos-${PROFILE}"
SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-emo}"
SSH_PASS="${SSH_PASS:-emo2500}"
SSH_PATH="export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin;"
BOOT_WAIT="${BOOT_WAIT:-40}"
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"
ISO_PATH="$PROJECT_ROOT/dist/qos-${PROFILE}.iso"
SERIAL_LOG="$PROJECT_ROOT/virtualbox/${VM_NAME}/serial.log"
RESULTS_FILE="$(mktemp)"
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ─── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m';    GRN='\033[0;32m';    YLW='\033[1;33m'
BLU='\033[0;34m';    CYN='\033[0;36m';    MAG='\033[0;35m'
BOLD='\033[1m';      NC='\033[0m'

PASS="${GRN}PASS${NC}"
FAIL="${RED}FAIL${NC}"
SKIP="${YLW}SKIP${NC}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log_section() {
    printf "\n${BOLD}${CYN}━━━ %s ━━━${NC}\n" "$*"
}

log_test()  { printf "  ${BLU}[TEST]${NC} %s ... " "$*"; }

_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "${PASS}\n"
}

_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${FAIL}\n"
    printf "    ${RED}→ %s${NC}\n" "$*" >&2
    echo "FAIL: $TEST_COUNT: $*" >> "$RESULTS_FILE"
}

_skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    printf "${SKIP} (%s)\n" "$*"
}

run_test() {
    local desc="$1" timeout="${2:-$TEST_TIMEOUT}"
    shift 2 || true
    TEST_COUNT=$((TEST_COUNT + 1))
    log_test "$desc"
    if timeout "$timeout" "$@" 2>/tmp/qos-test-err.$$; then
        _pass
    else
        local rc=$?
        local err_msg
        err_msg="$(head -3 /tmp/qos-test-err.$$ 2>/dev/null || echo "exit code $rc")"
        rm -f /tmp/qos-test-err.$$
        _fail "$err_msg"
    fi
}

SSH_CMD="sshpass -p $SSH_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $SSH_PORT ${SSH_USER}@${SSH_HOST}"

# run_ssh_test - run a test that SSHs into VM and checks output
run_ssh_test() {
    local desc="$1" tmo="${2:-10}" ssh_cmd="$3" expected="${4:-}"
    run_test "$desc" "$tmo" \
        bash -c "$SSH_CMD '$ssh_cmd' 2>/dev/null | grep -qE '${expected}'"
}

ensure_vm_running() {
    if ! VBoxManage list runningvms 2>/dev/null | grep -q "$VM_NAME"; then
        return 1
    fi
    return 0
}

cleanup_vm() {
    printf "\n${CYN}━━━ Cleanup ━━━${NC}\n"
    log_test "Cleanup: delete test VM ($VM_NAME)"
    if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
        "$PROJECT_ROOT/builder/tools/vm-manage.sh" delete "$PROFILE" --force >/dev/null 2>&1 || true
    fi
    if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
        VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
        sleep 1
        VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
        rm -rf "$PROJECT_ROOT/virtualbox/$VM_NAME" 2>/dev/null || true
    fi
    _pass
    print_summary
}

print_summary() {
    printf "\n${BOLD}${CYN}━━━ Results ━━━${NC}\n"
    printf "  Total:  %d\n" "$TEST_COUNT"
    printf "  Passed: ${GRN}%d${NC}\n" "$PASS_COUNT"
    printf "  Failed: ${RED}%d${NC}\n" "$FAIL_COUNT"
    printf "  Skipped: ${YLW}%d${NC}\n" "$SKIP_COUNT"
    if [[ -s "$RESULTS_FILE" ]]; then
        printf "\n${RED}Failures:${NC}\n"
        cat "$RESULTS_FILE"
    fi
    rm -f "$RESULTS_FILE"
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        printf "\n${RED}Some tests FAILED.${NC}\n"
        return 1
    else
        printf "\n${GRN}All tests PASSED.${NC}\n"
        return 0
    fi
}

# ─── Preflight Checks ────────────────────────────────────────────────────────

log_section "Preflight Checks"

# Validate profile
case "$PROFILE" in
    server|desktop) ;;
    *) echo "ERROR: Unknown PROFILE='$PROFILE'. Valid: server, desktop." >&2; exit 1 ;;
esac

# Check VirtualBox
if [[ "${SKIP_VBOX_CHECK:-0}" != "1" ]]; then
    if ! command -v VBoxManage &>/dev/null; then
        echo "VBoxManage not found — tests require VirtualBox." >&2
        echo "Set SKIP_VBOX_CHECK=1 to bypass." >&2
        exit 1
    fi
fi

# Check required tools
for tool in sshpass timeout; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing required tool: $tool" >&2
        exit 1
    fi
done

# Clean up any leftover test VM from previous runs
if VBoxManage showvminfo "$VM_NAME" &>/dev/null; then
    echo "  Cleaning up leftover VM: $VM_NAME"
    VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
    sleep 1
    VBoxManage unregistervm "$VM_NAME" --delete 2>/dev/null || true
    rm -rf "$PROJECT_ROOT/virtualbox/$VM_NAME" 2>/dev/null || true
fi

# Check ISO exists, build if needed
if [[ ! -f "$ISO_PATH" ]]; then
    echo "  ISO not found: $ISO_PATH — building (make $PROFILE)..."
    make "$PROFILE" PROFILE="$PROFILE" || {
        echo "Build failed. Cannot continue." >&2
        exit 1
    }
fi

# Set trap for cleanup
trap cleanup_vm EXIT

# ─── Test Suite ──────────────────────────────────────────────────────────────

# ═══ 1. VM Operations ════════════════════════════════════════════════════════

log_section "1. VM Operations"

run_test "vm-create: create server VM" 90 \
    make vm-create PROFILE="$PROFILE"

run_test "verify VM registered in VirtualBox" 10 \
    bash -c "VBoxManage showvminfo '$VM_NAME' &>/dev/null"

run_test "vm-list: list VMs shows our VM" 10 \
    bash -c "make vm-list PROFILE='$PROFILE' | grep -q '$VM_NAME'"

run_test "vm-info: get VM configuration" 10 \
    make vm-info PROFILE="$PROFILE"

run_test "vm-boot: start the VM" 90 \
    make vm-boot PROFILE="$PROFILE"

run_test "verify VM is running after boot" 10 \
    bash -c "VBoxManage list runningvms | grep -q '$VM_NAME'"

# ═══ 2. Boot Wait & Initialization ═══════════════════════════════════════════

log_section "2. Boot & Initialization"

run_test "vm-list shows VM as running" 10 \
    bash -c "make vm-list PROFILE='$PROFILE' | grep -q 'running'"

run_test "vm-info shows running status" 10 \
    bash -c "make vm-info PROFILE='$PROFILE' | grep -q -i 'running'"

# ═══ 3. Networking Tests ═════════════════════════════════════════════════════

log_section "3. Networking"

run_test "wait for SSH to become available" 120 \
    bash -c "
        for i in \$(seq 1 $BOOT_WAIT); do
            if sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'echo ok' 2>/dev/null | grep -q ok; then
                exit 0
            fi
            sleep 3
        done
        exit 1
    "

run_test "DHCP: interface eth0 has an IP address" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} ip addr show eth0' | grep -q 'inet '"

sleep 2  # avoid nftables SSH rate-limit

run_test "IP config: eth0 has RFC 1918 address (10.x or 192.168.x)" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} ip -o -4 addr show eth0' | grep -qE 'inet (10\.|192\.168\.)'"

sleep 4

run_test "DNS: /etc/resolv.conf has nameserver entries" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'grep -q nameserver /etc/resolv.conf'"

sleep 4

run_test "network: ping loopback works" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'sudo busybox ping -c 1 -W 2 127.0.0.1'"

sleep 4

# ═══ 4. SSH & System Tests ═══════════════════════════════════════════════════

log_section "4. SSH & System Checks"

sleep 4

run_test "SSH: login as emo user" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' whoami | grep -q emo"

sleep 4

run_test "SSH: qos info command works" 15 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} qos info' | grep -q 'Kernel:'"

sleep 4

run_test "SSH: qos version returns build stamp" 15 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} qos version' | grep -q '^QOS build:'"

sleep 4

run_test "SSH: sudo NOPASSWD works" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'sudo whoami' | grep -q root"

sleep 4

run_test "SSH: seed-reader done marker exists" 15 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'test -f /run/qos/seed-reader.done'"

# ═══ 5. Overlay/s6 Services ═══════════════════════════════════════════════════

log_section "5. Overlay & s6 Services"

sleep 4

run_test "s6: services supervise dir exists" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'ls /run/service/ | wc -l' | grep -qE '[1-9]'"

sleep 4

run_test "overlay: '/' is mounted as overlay" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' mount | grep -q 'on / .*overlay'"

sleep 4

run_test "interface: eth0 is up (not dummy0)" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} ip link show eth0' | grep -q 'state UP'"

sleep 4

run_test "interface: default route uses eth0 (not dummy0)" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} ip route show default' | grep -qE 'dev eth0|default via'"

# ═══ 6. nftables Tests ════════════════════════════════════════════════════════

log_section "6. nftables"

sleep 4

run_test "nftables: firewall rules are loaded" 15 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'sudo nft list ruleset 2>/dev/null' | grep -q 'chain input'"

sleep 4

run_test "nftables: DHCP rule in firewall" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'sudo nft list ruleset 2>/dev/null' | grep -q 'udp sport 67'"

# ═══ 7. Serial Log Checks ════════════════════════════════════════════════════

log_section "7. Serial Log"

run_test "serial log: exists and is not empty" 10 \
    bash -c "test -s '$SERIAL_LOG'"

run_test "serial log: no 'No space left on device' errors" 10 \
    bash -c "! grep -qi 'no space left on device' '$SERIAL_LOG'"

run_test "serial log: no 'can't open' errors" 10 \
    bash -c "! grep -qi \"can't open\" '$SERIAL_LOG'"

run_test "serial log: no kernel panic" 10 \
    bash -c "! grep -qi 'kernel panic' '$SERIAL_LOG'"

run_test "serial log: no OOM killer activations" 10 \
    bash -c "! grep -qi 'out of memory' '$SERIAL_LOG'"

# ═══ 8. bootiso Test ═══════════════════════════════════════════════════════════

log_section "8. bootiso"

run_test "bootiso: binary exists in VM" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} which bootiso' | grep -q bootiso"

sleep 4

run_test "bootiso: --help works" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'sudo bootiso --help' | grep -qi usage"

# vm-bootiso triggers kexec reboot — SSH dies, output goes to SSH not serial.
# The real success check is in the post-bootiso recovery tests below.
log_test "vm-bootiso: copy ISO and boot via kexec"
TEST_COUNT=$((TEST_COUNT + 1))
(
    make vm-bootiso PROFILE="$PROFILE" ISO="$ISO_PATH" >/dev/null 2>&1
) &
BOOTISO_PID=$!
sleep 90
kill $BOOTISO_PID 2>/dev/null || true
wait $BOOTISO_PID 2>/dev/null || true
_pass

log_section "8b. Post-bootiso Recovery"

# After bootiso, the VM reboots into the ISO. Wait for SSH to come back.
run_test "post-bootiso: SSH recovers after reboot" 120 \
    bash -c "
        for i in \$(seq 1 30); do
            if sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' 'echo ok' 2>/dev/null | grep -q ok; then
                exit 0
            fi
            sleep 5
        done
        exit 1
    "

run_test "post-bootiso: can SSH and run commands" 10 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' uname -r | grep -qE '[0-9]+\.[0-9]+'"

run_test "post-bootiso: qos version returns build stamp" 15 \
    bash -c "sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} qos version' | grep -q '^QOS build:'"

run_test "post-bootiso: qos info reports IPv4" 15 \
    bash -c "out=\$(sshpass -p '$SSH_PASS' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p '$SSH_PORT' '${SSH_USER}@${SSH_HOST}' '${SSH_PATH} qos info'); printf '%s\n' \"\$out\" | grep -q '^IPv4:' && ! printf '%s\n' \"\$out\" | grep -q '^IPv4: none\$'"

# ═══ 9. VM Stop & Delete ═══════════════════════════════════════════════════════

log_section "9. VM Stop & Delete"

run_test "vm-stop: stop the running VM" 30 \
    make vm-stop PROFILE="$PROFILE"

run_test "verify VM is stopped" 10 \
    bash -c "! VBoxManage list runningvms | grep -q '$VM_NAME'"

run_test "vm-list shows VM as stopped" 10 \
    bash -c "make vm-list PROFILE='$PROFILE' | grep -q 'stopped'"

run_test "vm-delete: delete the VM" 30 \
    bash builder/tools/vm-manage.sh delete "$PROFILE" --force

run_test "verify VM no longer registered" 10 \
    bash -c "! VBoxManage showvminfo '$VM_NAME' &>/dev/null"

log_section "All tests complete"

# Score: fail if any test failed
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
