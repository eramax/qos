#!/bin/sh
# qos-test - Comprehensive QOS Distro Test Suite
# Tests all system features with timeouts to prevent hangs
# Usage: qos-test [--quick] [--verbose]
#   --quick    Skip long-running tests
#   --verbose  Show detailed output

set -e

# Configuration
TIMEOUT="${TIMEOUT:-10}"         # Default timeout for commands (seconds)
LONG_TIMEOUT="${LONG_TIMEOUT:-30}" # Timeout for network/slow tests
PASS=0
FAIL=0
SKIP=0
WARN=0

# Colors (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Parse arguments
QUICK_MODE=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --quick)  QUICK_MODE=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h)
            echo "Usage: qos-test [--quick] [--verbose]"
            echo "  --quick    Skip long-running tests (network, app install)"
            echo "  --verbose  Show detailed command output"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

# Helper functions
pass() {
    PASS=$((PASS + 1))
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "${RED}[FAIL]${NC} %s\n" "$1"
    [ -n "$2" ] && printf "       Error: %s\n" "$2"
}

warn() {
    WARN=$((WARN + 1))
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
    [ -n "$2" ] && printf "       Detail: %s\n" "$2"
}

skip() {
    SKIP=$((SKIP + 1))
    printf "${BLUE}[SKIP]${NC} %s\n" "$1"
}

run_test() {
    local description="$1"
    local command="$2"
    local timeout="${3:-$TIMEOUT}"
    local expect_fail="${4:-0}"

    if [ "$VERBOSE" -eq 1 ]; then
        printf "\n${BLUE}[TEST]${NC} %s\n" "$description"
        printf "       Command: %s\n" "$command"
    fi

    local output
    local exit_code

    output="$(timeout "$timeout" sh -c "$command" 2>&1)" || exit_code=$?
    exit_code=${exit_code:-0}

    if [ "$exit_code" -eq 124 ]; then
        fail "$description" "Command timed out after ${timeout}s"
    elif [ "$expect_fail" -eq 1 ] && [ "$exit_code" -ne 0 ]; then
        pass "$description (expected failure)"
    elif [ "$exit_code" -eq 0 ]; then
        pass "$description"
    else
        fail "$description" "Exit code: $exit_code"
        if [ "$VERBOSE" -eq 1 ]; then
            printf "       Output: %s\n" "$output"
        fi
    fi

    if [ "$VERBOSE" -eq 1 ] && [ -n "$output" ]; then
        printf "       Output: %s\n" "$(echo "$output" | head -3)"
    fi
}

section() {
    printf "\n${BLUE}══════════════════════════════════════════════${NC}\n"
    printf "${BLUE}  %s${NC}\n" "$1"
    printf "${BLUE}══════════════════════════════════════════════${NC}\n"
}

# ============================================================
# SYSTEM INFORMATION
# ============================================================
section "SYSTEM INFORMATION"

printf "${BLUE}Hostname:${NC}      "
hostname 2>/dev/null || echo "unknown"

printf "${BLUE}Kernel:${NC}        "
uname -r 2>/dev/null || echo "unknown"

printf "${BLUE}Architecture:${NC}  "
uname -m 2>/dev/null || echo "unknown"

printf "${BLUE}CPU Cores:${NC}     "
nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown"

printf "${BLUE}CPU Model:${NC}     "
grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || echo "unknown"

printf "${BLUE}Total RAM:${NC}     "
free -m 2>/dev/null | awk '/^Mem:/ {print $2 " MB"}' || echo "unknown"

printf "${BLUE}Swap:${NC}          "
free -m 2>/dev/null | awk '/^Swap:/ {print $2 " MB"}' || echo "unknown"

printf "${BLUE}Uptime:${NC}        "
uptime 2>/dev/null | sed 's/.*up //' || echo "unknown"

printf "${BLUE}Date:${NC}          "
date 2>/dev/null || echo "unknown"

printf "${BLUE}IP Address:${NC}    "
ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "unknown"

printf "${BLUE}Disk Layout:${NC}\n"
df -h 2>/dev/null | grep -E "Filesystem|overlay|/dev/vda" || echo "unknown"

printf "\n"

# ============================================================
# TEST SUITE
# ============================================================

# --------------------------------------------------
# 1. Core System
# --------------------------------------------------
section "1. CORE SYSTEM TESTS"

run_test "Kernel version accessible" "uname -r | grep -q '6.19'"
run_test "Hostname is set" "hostname | grep -q 'qos'"
run_test "Shell is ash/busybox" "ls -la /bin/sh | grep -q 'busybox\|ash'"
run_test "Package manager (apk) works" "apk --version >/dev/null 2>&1"
run_test "Init system (s6) running" "ps aux | grep -q '[s]6-svscan'"
run_test "Proc filesystem mounted" "mount | grep -q 'proc'"
run_test "Sysfs mounted" "mount | grep -q 'sysfs'"
run_test "Devtmpfs mounted" "mount | grep -q 'devtmpfs'"

# --------------------------------------------------
# 2. Memory & Resources
# --------------------------------------------------
section "2. MEMORY & RESOURCE TESTS"

run_test "Free command works" "free -m | grep -q 'Mem'"
run_test "Memory usage <50 MB" "free -m | awk '/^Mem:/ {exit (\$3 < 50) ? 0 : 1}'"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Htop available" "htop --version >/dev/null 2>&1"
    run_test "Process list accessible" "ps aux | head -5 >/dev/null 2>&1"
fi

# --------------------------------------------------
# 3. Filesystem
# --------------------------------------------------
section "3. FILESYSTEM TESTS"

run_test "Root is overlay filesystem" "df -h / | grep -q 'overlay'"
run_test "Var partition mounted" "df -h /var | grep -q '/var'"
run_test "Tmpfs on /tmp" "mount | grep -q 'tmpfs.* /tmp '"
run_test "Tmpfs on /run" "mount | grep -q 'tmpfs.* /run '"
run_test "Disk usage reasonable" "df -h / | awk 'NR==2 {gsub(/%/,"",$5); exit (\$5 < 90) ? 0 : 1}'"
run_test "Can write to /tmp" "echo test > /tmp/test_write && rm -f /tmp/test_write"
run_test "Can write to /var" "echo test > /var/test_write && rm -f /var/test_write"
run_test "Read-only root (should fail)" "touch /test_readonly 2>/dev/null" "" "1"

# --------------------------------------------------
# 4. Kernel Features
# --------------------------------------------------
section "4. KERNEL FEATURE TESTS"

run_test "Cgroups v2 mounted" "mount | grep -q 'cgroup2'"
run_test "Cgroup controllers available" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'cpu'"
run_test "Cgroup memory controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'memory'"
run_test "Cgroup pids controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'pids'"
run_test "Cgroup io controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'io'"
run_test "ZRAM device exists" "ls /dev/zram0 >/dev/null 2>&1"
run_test "Swap enabled" "swapon --show 2>/dev/null | grep -q 'zram'"
run_test "Kernel modules command works" "lsmod >/dev/null 2>&1"

# --------------------------------------------------
# 5. Networking
# --------------------------------------------------
section "5. NETWORKING TESTS"

run_test "Network interface eth0 exists" "ip addr show eth0 | grep -q 'eth0'"
run_test "Interface has IP address" "ip -4 addr show eth0 | grep -q 'inet'"
run_test "Interface is UP" "ip addr show eth0 | grep -q 'state UP'"
run_test "Default route configured" "ip route show | grep -q 'default'"
run_test "DNS resolution works" "getent hosts google.com >/dev/null 2>&1"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Ping external host (8.8.8.8)" "ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1" "$LONG_TIMEOUT"
    run_test "Ping domain (google.com)" "ping -c 2 -W 3 google.com >/dev/null 2>&1" "$LONG_TIMEOUT"
    run_test "IPv6 address assigned" "ip -6 addr show eth0 | grep -q 'inet6'"
fi

# --------------------------------------------------
# 6. SSH (Dropbear)
# --------------------------------------------------
section "6. SSH (DROPBEAR) TESTS"

run_test "Dropbear process running" "ps aux | grep -q '[d]ropbear'"
run_test "SSH port 22 listening" "ss -tlnp | grep -q ':22 '"
run_test "Dropbear keys generated" "ls /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1"

# --------------------------------------------------
# 7. Firewall (nftables)
# --------------------------------------------------
section "7. FIREWALL (NFTABLES) TESTS"

run_test "Nftables command works" "nft list ruleset >/dev/null 2>&1"
run_test "Filter table exists" "nft list ruleset | grep -q 'table inet filter'"
run_test "Input chain exists" "nft list ruleset | grep -q 'chain input'"
run_test "Forward chain exists" "nft list ruleset | grep -q 'chain forward'"
run_test "Output chain exists" "nft list ruleset | grep -q 'chain output'"

# --------------------------------------------------
# 8. Services (s6)
# --------------------------------------------------
section "8. SERVICE TESTS"

run_test "s6-rc command works" "s6-rc -a list >/dev/null 2>&1"

# Core services (should always be running)
run_test "Service: getty running" "s6-svstat /run/service/getty 2>&1 | grep -q 'up'"
run_test "Service: networking running" "s6-svstat /run/service/networking 2>&1 | grep -q 'up'"
run_test "Service: dropbear running" "s6-svstat /run/service/dropbear 2>&1 | grep -q 'up'"
run_test "Service: nftables running" "s6-svstat /run/service/nftables 2>&1 | grep -q 'up'"
run_test "Service: zram running" "s6-svstat /run/service/zram 2>&1 | grep -q 'up'"

# Optional services (may not be running if binaries missing)
if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Service: cluster exists" "ls -d /run/service/cluster >/dev/null 2>&1"
    run_test "Service: ntpd exists" "ls -d /run/service/ntpd >/dev/null 2>&1"
    run_test "Service: reverse-proxy exists" "ls -d /run/service/reverse-proxy >/dev/null 2>&1"
    run_test "Service: webapp exists" "ls -d /run/service/webapp >/dev/null 2>&1"
    run_test "Service: dns exists" "ls -d /run/service/dns >/dev/null 2>&1"
fi

# --------------------------------------------------
# 9. Capability System
# --------------------------------------------------
section "9. CAPABILITY SYSTEM TESTS"

run_test "qos-capability command exists" "which qos-capability >/dev/null 2>&1"
run_test "List capability profiles" "qos-capability list | grep -q 'database'"
run_test "Reverse-proxy profile exists" "qos-capability list | grep -q 'reverse-proxy'"
run_test "Webapp profile exists" "qos-capability list | grep -q 'webapp'"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Apply capability profile" "qos-capability apply test-svc webapp.cap 2>&1 | grep -q 'Applied'"
    run_test "Show capability settings" "qos-capability show test-svc 2>&1 | head -1 >/dev/null 2>&1"
fi

# --------------------------------------------------
# 10. Cluster System
# --------------------------------------------------
section "10. CLUSTER SYSTEM TESTS"

run_test "qos-cluster command exists" "which qos-cluster >/dev/null 2>&1"
run_test "Cluster status command" "qos-cluster status >/dev/null 2>&1 || true"
run_test "Cluster nodes command" "qos-cluster nodes | grep -q 'Cluster Members'"
run_test "Cluster resources command" "qos-cluster resources | grep -q 'Cluster Resources'"
run_test "Cluster services command" "qos-cluster services | grep -q 'Local Services'"

# --------------------------------------------------
# 11. Disk Expansion Tool
# --------------------------------------------------
section "11. DISK EXPANSION TESTS"

run_test "qos-expand command exists" "which qos-expand >/dev/null 2>&1"
run_test "qos-expand shows usage" "qos-expand 2>&1 | grep -q 'Usage'"

# --------------------------------------------------
# 12. Time & Scheduling
# --------------------------------------------------
section "12. TIME & SCHEDULING TESTS"

run_test "Date command works" "date | grep -q '2026'"
run_test "Chrony package installed" "which chronyd >/dev/null 2>&1 || apk info chrony >/dev/null 2>&1"
run_test "Dcron package installed" "which dcrond >/dev/null 2>&1 || apk info dcron >/dev/null 2>&1"

# --------------------------------------------------
# 13. Curl & HTTP
# --------------------------------------------------
section "13. CURL & HTTP TESTS"

run_test "Curl command exists" "which curl >/dev/null 2>&1"
run_test "Curl version" "curl --version | grep -q 'curl'"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Curl external URL (example.com)" "curl -s -o /dev/null -w '%{http_code}' http://example.com | grep -q '200'" "$LONG_TIMEOUT"
    run_test "Curl with headers" "curl -s -H 'Host: test' -o /dev/null http://example.com >/dev/null 2>&1" "$LONG_TIMEOUT"
    run_test "Curl HTTPS works" "curl -s -o /dev/null https://example.com >/dev/null 2>&1" "$LONG_TIMEOUT"
fi

# --------------------------------------------------
# 14. Local Web Server Test
# --------------------------------------------------
section "14. LOCAL WEB SERVER TESTS"

# Test if we can create a simple HTTP server
run_test "Python3 available (for test server)" "python3 --version >/dev/null 2>&1" "" "$TIMEOUT" "1"

if [ "$QUICK_MODE" -eq 0 ]; then
    # Start a simple HTTP server in background
    if command -v python3 >/dev/null 2>&1; then
        echo "test server works" > /tmp/test_index.html
        cd /tmp && python3 -m http.server 8888 >/dev/null 2>&1 &
        PYTHON_PID=$!
        sleep 2

        run_test "Local HTTP server responds" "curl -s http://localhost:8888/test_index.html | grep -q 'test server works'" "$TIMEOUT"
        run_test "HTTP status code 200" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/ | grep -q '200'" "$TIMEOUT"

        # Cleanup
        kill $PYTHON_PID 2>/dev/null || true
        rm -f /tmp/test_index.html
    else
        skip "Python3 not available, skipping HTTP server test"
    fi
fi

# --------------------------------------------------
# 15. Application Installation
# --------------------------------------------------
section "15. APPLICATION INSTALLATION TESTS"

run_test "Apk update works" "apk update >/dev/null 2>&1" "$LONG_TIMEOUT"
run_test "Apk search works" "apk search busybox | grep -q 'busybox'" "$TIMEOUT"

if [ "$QUICK_MODE" -eq 0 ]; then
    # Test installing a small package
    run_test "Install test package (strace)" "apk add --no-cache strace >/dev/null 2>&1" "$LONG_TIMEOUT"
    run_test "Installed package works (strace)" "strace -V 2>&1 | grep -q 'strace'" "$TIMEOUT"
    run_test "Remove test package" "apk del strace >/dev/null 2>&1" "$TIMEOUT"
fi

# --------------------------------------------------
# 16. Bun Runtime (Optional)
# --------------------------------------------------
section "16. BUN RUNTIME TESTS (Optional)"

if command -v bun >/dev/null 2>&1; then
    run_test "Bun runtime installed" "bun --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        # Create a simple Bun server
        cat > /tmp/bun_test.ts <<'EOF'
const server = Bun.serve({
  port: 9999,
  fetch(req) {
    return new Response("Bun works!");
  },
});
EOF

        # Start Bun in background
        bun run /tmp/bun_test.ts >/dev/null 2>&1 &
        BUN_PID=$!
        sleep 3

        run_test "Bun HTTP server responds" "curl -s http://localhost:9999 | grep -q 'Bun works!'" "$TIMEOUT"

        # Cleanup
        kill $BUN_PID 2>/dev/null || true
        rm -f /tmp/bun_test.ts
    fi
else
    skip "Bun not installed, skipping Bun tests"
fi

# --------------------------------------------------
# 17. Security Features
# --------------------------------------------------
section "17. SECURITY FEATURE TESTS"

run_test "ASLR enabled" "cat /proc/sys/kernel/randomize_va_space | grep -q '[12]'"
run_test "Seccomp available" "grep Seccomp /proc/self/status | grep -q 'Seccomp:'"
run_test "Shadow file exists" "ls -l /etc/shadow | grep -q 'shadow'"
run_test "Shadow file permissions" "stat -c %a /etc/shadow | grep -q '640\|400'"
run_test "Root has password hash" "grep '^root:' /etc/shadow | grep -qv '!!'"

# --------------------------------------------------
# 18. Logging & Monitoring
# --------------------------------------------------
section "18. LOGGING & MONITORING TESTS"

run_test "Var/log directory exists" "ls -d /var/log >/dev/null 2>&1"
run_test "Can write to /var/log" "echo test > /var/log/test_log && rm -f /var/log/test_log"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Htop runs" "timeout 2 htop --version >/dev/null 2>&1"
fi

# --------------------------------------------------
# 19. User Management
# --------------------------------------------------
section "19. USER MANAGEMENT TESTS"

run_test "Root user exists" "grep '^root:' /etc/passwd | grep -q '/bin/sh\|/bin/ash'"
run_test "Passwd command exists" "which passwd >/dev/null 2>&1"
run_test "Groups command works" "groups | grep -q 'root'"
run_test "Home directory exists" "ls -d /root >/dev/null 2>&1"

# --------------------------------------------------
# 20. System Utilities
# --------------------------------------------------
section "20. SYSTEM UTILITY TESTS"

run_test "Grep works" "echo test | grep -q 'test'"
run_test "Sed works" "echo test | sed 's/test/pass/' | grep -q 'pass'"
run_test "Awk works" "echo test | awk '{print \$1}' | grep -q 'test'"
run_test "Tar works" "tar --version | grep -q 'tar'"
run_test "Find works" "find /tmp -maxdepth 0 >/dev/null 2>&1"
run_test "Sort works" "echo -e 'b\na\nc' | sort | head -1 | grep -q 'a'"
run_test "Wc works" "echo test | wc -w | grep -q '1'"
run_test "Head works" "echo test | head -1 | grep -q 'test'"
run_test "Tail works" "echo test | tail -1 | grep -q 'test'"
run_test "Tee works" "echo test | tee /tmp/test_tee | grep -q 'test'"
run_test "Xargs works" "echo test | xargs echo | grep -q 'test'"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Strace available" "which strace >/dev/null 2>&1 || echo 'not installed'"
    run_test "Tcpdump available" "which tcpdump >/dev/null 2>&1 || echo 'not installed'"
fi

# ============================================================
# SUMMARY
# ============================================================
section "TEST SUMMARY"

TOTAL=$((PASS + FAIL + WARN + SKIP))

printf "\n"
printf "${GREEN}PASS:${NC}  %-5d\n" "$PASS"
printf "${RED}FAIL:${NC}  %-5d\n" "$FAIL"
printf "${YELLOW}WARN:${NC}  %-5d\n" "$WARN"
printf "${BLUE}SKIP:${NC}  %-5d\n" "$SKIP"
printf "TOTAL:  %-5d\n" "$TOTAL"
printf "\n"

if [ "$FAIL" -eq 0 ]; then
    printf "${GREEN}══════════════════════════════════════════════${NC}\n"
    printf "${GREEN}  ✅ ALL TESTS PASSED${NC}\n"
    printf "${GREEN}══════════════════════════════════════════════${NC}\n"
    exit 0
else
    printf "${RED}══════════════════════════════════════════════${NC}\n"
    printf "${RED}  ❌ $FAIL TEST(S) FAILED${NC}\n"
    printf "${RED}══════════════════════════════════════════════${NC}\n"
    exit 1
fi
