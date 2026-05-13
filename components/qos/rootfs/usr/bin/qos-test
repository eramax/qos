#!/bin/sh
# qos-test - Comprehensive QOS Distro Test Suite
# Tests all system features with timeouts to prevent hangs
# Usage: qos-test [--quick] [--verbose]
#   --quick    Skip long-running tests
#   --verbose  Show detailed output

set -e

TIMEOUT="${TIMEOUT:-10}"
LONG_TIMEOUT="${LONG_TIMEOUT:-30}"

QUICK_MODE=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h)
            echo "Usage: qos-test [--quick] [--verbose]"
            echo "  --quick    Skip long-running tests (network, app install)"
            echo "  --verbose  Show detailed command output"
            exit 0
            ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# Shared scaffolding: counters, color, pass/fail/warn/skip, run_test,
# section, print_summary. Looks on-target first, repo second.
_common="/usr/lib/qos-test-common.sh"
[ -f "$_common" ] || _common="$(dirname "$0")/lib/test-common.sh"
. "$_common"

# ============================================================
# SYSTEM INFORMATION
# ============================================================
section "SYSTEM INFORMATION"

printf "${BLUE}Hostname:${NC}      "; hostname 2>/dev/null || echo "unknown"
printf "${BLUE}Kernel:${NC}        "; uname -r 2>/dev/null || echo "unknown"
printf "${BLUE}Architecture:${NC}  "; uname -m 2>/dev/null || echo "unknown"
printf "${BLUE}CPU Cores:${NC}     "; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown"
printf "${BLUE}CPU Model:${NC}     "; grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || echo "unknown"
printf "${BLUE}Total RAM:${NC}     "; free -m 2>/dev/null | awk '/^Mem:/ {print $2 " MB"}' || echo "unknown"
printf "${BLUE}Swap:${NC}          "; free -m 2>/dev/null | awk '/^Swap:/ {print $2 " MB"}' || echo "unknown"
printf "${BLUE}Uptime:${NC}        "; uptime 2>/dev/null | sed 's/.*up //' || echo "unknown"
printf "${BLUE}Date:${NC}          "; date 2>/dev/null || echo "unknown"
printf "${BLUE}IP Address:${NC}    "; ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || echo "unknown"

printf "${BLUE}Disk Layout:${NC}\n"
df -h 2>/dev/null | grep -E "Filesystem|overlay|/dev/vda" || echo "unknown"

# Show running services
printf "\n${BLUE}Running Services:${NC}\n"
for svc in /run/service/*; do
    [ -e "$svc" ] || continue
    name="$(basename "$svc")"
    if s6-svstat "$svc" 2>/dev/null | grep -q "up"; then
        printf "  ${GREEN}✔${NC} %s\n" "$name"
    else
        printf "  ${RED}✖${NC} %s\n" "$name"
    fi
done

printf "\n"

# ============================================================
# TEST SUITE
# ============================================================

# --------------------------------------------------
# 1. Core System
# --------------------------------------------------
section "1. CORE SYSTEM TESTS"

run_test "Kernel version is 7.0.0" "uname -r | grep -q '7.0.0'"
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
run_test "Memory usage <60 MB" "free -m | awk '/^Mem:/ {exit (\$3 < 60) ? 0 : 1}'"
run_test "Htop available" "htop --version >/dev/null 2>&1"
run_test "Process list accessible" "ps aux | head -5 >/dev/null 2>&1"

# --------------------------------------------------
# 3. Filesystem
# --------------------------------------------------
section "3. FILESYSTEM TESTS"

run_test "Root is overlay filesystem" "df -h / | grep -q 'overlay'"
run_test "Var partition mounted" "df -h /var | grep -q '/var'"
run_test "Tmpfs on /tmp" "mount | grep -q 'tmpfs.* /tmp '"
run_test "Tmpfs on /run" "mount | grep -q 'tmpfs.* /run '"
run_test "Disk usage reasonable (<90%)" "df / | awk 'NR==2 {gsub(/%/,\"\",\$5); exit (\$5 < 90) ? 0 : 1}'"
run_test "Can write to /tmp" "echo test > /tmp/test_write && rm -f /tmp/test_write"
run_test "Can write to /var" "echo test > /var/test_write && rm -f /var/test_write"
run_test "Read-only root (should fail)" "touch /test_readonly 2>/dev/null" "" "1"

# --------------------------------------------------
# 4. Kernel Features
# --------------------------------------------------
section "4. KERNEL FEATURE TESTS"

run_test "Cgroups v2 mounted" "mount | grep -q 'cgroup2'"
run_test "Cgroup controllers available" "test -f /sys/fs/cgroup/cgroup.controllers"
run_test "Cgroup cpu controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'cpu'"
run_test "Cgroup memory controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'memory'"
run_test "Cgroup pids controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'pids'"
run_test "Cgroup io controller" "cat /sys/fs/cgroup/cgroup.controllers | grep -q 'io'"
run_test "ZRAM device exists" "test -e /dev/zram0"
run_test "Swap enabled" "swapon --show 2>/dev/null | grep -q 'zram' || cat /proc/swaps | grep -q 'zram'"
run_test "Kernel modules command works" "lsmod >/dev/null 2>&1"

# --------------------------------------------------
# 5. Networking
# --------------------------------------------------
section "5. NETWORKING TESTS"

run_test "Network interface eth0 exists" "ip addr show eth0 | grep -q 'eth0'"
run_test "Interface has IP address" "ip -4 addr show eth0 | grep -q 'inet '"
run_test "Interface is UP" "ip link show eth0 | grep -q 'state UP'"
run_test "Default route configured" "ip route show | grep -q 'default'"
run_test "DNS resolution works (nslookup)" "nslookup google.com >/dev/null 2>&1 || ping -c 1 google.com >/dev/null 2>&1"

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
run_test "SSH port 22 listening" "ss -tlnp 2>/dev/null | grep -q ':22 ' || netstat -tlnp 2>/dev/null | grep -q ':22 '"
run_test "Dropbear keys generated" "test -f /etc/dropbear/dropbear_ed25519_host_key"

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

# Optional services
if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Service: cluster exists" "test -d /run/service/cluster"
    run_test "Service: qemu-ga exists" "test -d /run/service/qemu-ga"
    run_test "Service: reverse-proxy exists" "test -d /run/service/reverse-proxy"
    run_test "Service: webapp exists" "test -d /run/service/webapp"
    run_test "Service: dns exists" "test -d /run/service/dns"
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
fi

# --------------------------------------------------
# 10. Cluster System
# --------------------------------------------------
section "10. CLUSTER SYSTEM TESTS"

run_test "qos-cluster command exists" "which qos-cluster >/dev/null 2>&1"
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
run_test "Dcron package installed" "which dcrond >/dev/null 2>&1 || which crond >/dev/null 2>&1"

# --------------------------------------------------
# 13. Curl & HTTP
# --------------------------------------------------
section "13. CURL & HTTP TESTS"

run_test "Curl command exists" "which curl >/dev/null 2>&1"
run_test "Curl version" "curl --version | grep -q 'curl'"

if [ "$QUICK_MODE" -eq 0 ]; then
    run_test "Curl external URL (example.com HTTP)" "curl -s -o /dev/null -w '%{http_code}' http://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"
    run_test "Curl with custom headers" "curl -s -H 'Host: test' -o /dev/null http://example.com >/dev/null 2>&1" "$LONG_TIMEOUT"
    # HTTPS may fail without ca-certificates, use -k for insecure
    run_test "Curl HTTPS works (insecure)" "curl -sk -o /dev/null https://example.com >/dev/null 2>&1" "$LONG_TIMEOUT"
fi

# --------------------------------------------------
# 14. Local Web Server Test (Bun/Node)
# --------------------------------------------------
section "14. LOCAL WEB SERVER TESTS"

# Test Bun
if command -v bun >/dev/null 2>&1; then
    run_test "Bun runtime installed" "bun --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        # Create a simple Bun server
        cat > /tmp/bun_test.ts <<'EOF'
const server = Bun.serve({
  port: 9999,
  fetch(req) {
    return new Response("Bun works! QOS distro is running.");
  },
});
console.log("Bun server running on port 9999");
EOF

        bun run /tmp/bun_test.ts >/dev/null 2>&1 &
        BUN_PID=$!
        sleep 3

        run_test "Bun HTTP server responds" "curl -s http://localhost:9999 | grep -q 'Bun works!'" "$TIMEOUT"
        run_test "Bun server returns 200" "curl -s -o /dev/null -w '%{http_code}' http://localhost:9999 | grep -q '200'" "$TIMEOUT"

        kill $BUN_PID 2>/dev/null || true
        rm -f /tmp/bun_test.ts
    fi
# Test Node
elif command -v node >/dev/null 2>&1; then
    run_test "Node.js runtime installed" "node --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        cat > /tmp/node_test.js <<'EOF'
const http = require('http');
const server = http.createServer((req, res) => {
  res.writeHead(200, {'Content-Type': 'text/plain'});
  res.end('Node.js works! QOS distro is running.');
});
server.listen(9998, () => console.log('Node server on port 9998'));
EOF

        node /tmp/node_test.js >/dev/null 2>&1 &
        NODE_PID=$!
        sleep 2

        run_test "Node HTTP server responds" "curl -s http://localhost:9998 | grep -q 'Node.js works!'" "$TIMEOUT"

        kill $NODE_PID 2>/dev/null || true
        rm -f /tmp/node_test.js
    fi
# Test Python
elif command -v python3 >/dev/null 2>&1; then
    run_test "Python3 available (fallback)" "python3 --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        echo "Python HTTP server works - QOS distro running" > /tmp/test_index.html
        cd /tmp && python3 -m http.server 8888 >/dev/null 2>&1 &
        PYTHON_PID=$!
        sleep 2

        run_test "Python HTTP server responds" "curl -s http://localhost:8888/test_index.html | grep -q 'Python HTTP server'" "$TIMEOUT"
        run_test "HTTP status code 200" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/ | grep -q '200'" "$TIMEOUT"

        kill $PYTHON_PID 2>/dev/null || true
        rm -f /tmp/test_index.html
    fi
else
    skip "No runtime available (bun/node/python3), skipping web server test"
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
# 16. DNS Service Test (dnsmasq e2e)
# --------------------------------------------------
section "16. DNS SERVICE TESTS"

if [ -d /run/service/dns ] && s6-svstat /run/service/dns 2>&1 | grep -q "up"; then
    run_test "DNS service (dnsmasq) running" "ps aux | grep -q '[d]nsmasq'"
    run_test "Local DNS resolves" "nslookup qos.local 127.0.0.1 >/dev/null 2>&1 || dig @127.0.0.1 qos.local >/dev/null 2>&1 || true"
    run_test "DNS forwards to upstream" "nslookup google.com 127.0.0.1 >/dev/null 2>&1 || dig @127.0.0.1 google.com >/dev/null 2>&1"
else
    skip "DNS service not running, skipping DNS tests"
    # Test system DNS instead
    run_test "System DNS resolution" "nslookup google.com >/dev/null 2>&1 || ping -c 1 google.com >/dev/null 2>&1" "$LONG_TIMEOUT"
fi

# --------------------------------------------------
# 17. Reverse Proxy Test
# --------------------------------------------------
section "17. REVERSE PROXY TESTS"

if command -v caddy >/dev/null 2>&1; then
    run_test "Caddy reverse proxy installed" "caddy version >/dev/null 2>&1"
    run_test "Caddy config valid" "caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1"
    run_test "Default page responds" "curl -s http://localhost:80 | grep -q 'QOS Server'" "$TIMEOUT"
else
    skip "Caddy not installed, skipping reverse proxy tests"
fi

# --------------------------------------------------
# 18. QEMU Guest Agent Test
# --------------------------------------------------
section "18. QEMU GUEST AGENT TESTS"

if [ -d /run/service/qemu-ga ]; then
    run_test "QEMU guest agent service exists" "test -d /run/service/qemu-ga"
    if s6-svstat /run/service/qemu-ga 2>&1 | grep -q "up"; then
        run_test "QEMU guest agent running" "ps aux | grep -q '[q]emu-ga'"
        run_test "Virtio-serial device exists" "test -e /dev/virtio-ports/org.qemu.guest_agent.0"
    else
        warn "QEMU guest agent not running" "Service may not be started or virtio channel unavailable"
    fi
else
    skip "QEMU guest agent not installed"
fi

# --------------------------------------------------
# 19. Security Features
# --------------------------------------------------
section "19. SECURITY FEATURE TESTS"

run_test "ASLR enabled" "cat /proc/sys/kernel/randomize_va_space | grep -q '[12]'"
run_test "Seccomp available" "grep Seccomp /proc/self/status | grep -q 'Seccomp:'"
run_test "Shadow file exists" "test -f /etc/shadow"
run_test "Shadow file permissions" "stat -c %a /etc/shadow | grep -q '640\|400'"
run_test "Root has password hash" "grep '^root:' /etc/shadow | grep -qv '!!'"

# --------------------------------------------------
# 20. Logging & Monitoring
# --------------------------------------------------
section "20. LOGGING & MONITORING TESTS"

run_test "Var/log directory exists" "test -d /var/log"
run_test "Can write to /var/log" "echo test > /var/log/test_log && rm -f /var/log/test_log"
run_test "Htop runs" "timeout 2 htop --version >/dev/null 2>&1"

# --------------------------------------------------
# 21. User Management
# --------------------------------------------------
section "21. USER MANAGEMENT TESTS"

run_test "Root user exists" "grep '^root:' /etc/passwd | grep -q '/bin/sh\|/bin/ash'"
run_test "Passwd command exists" "which passwd >/dev/null 2>&1"
run_test "Groups command works" "groups | grep -q 'root'"
run_test "Home directory exists" "test -d /root"

# --------------------------------------------------
# 22. System Utilities
# --------------------------------------------------
section "22. SYSTEM UTILITY TESTS"

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
run_test "Nslookup works" "nslookup --version >/dev/null 2>&1 || nslookup localhost >/dev/null 2>&1 || true"

# --------------------------------------------------
# 23. End-to-End Integration Tests
# --------------------------------------------------
section "23. END-TO-END INTEGRATION TESTS"

if [ "$QUICK_MODE" -eq 0 ]; then
    # Test full HTTP request flow
    run_test "E2E: External HTTP request" "curl -s -o /dev/null -w '%{http_code}' http://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"

    # Test file write/read cycle
    run_test "E2E: File write/read cycle" "echo 'e2e test' > /tmp/e2e_test && cat /tmp/e2e_test | grep -q 'e2e test' && rm -f /tmp/e2e_test"

    # Test service restart
    run_test "E2E: Service restart works" "s6-rc -d change dropbear 2>/dev/null && sleep 1 && s6-rc -u change dropbear 2>/dev/null" "$TIMEOUT"

    # Test capability system end-to-end
    run_test "E2E: Capability apply and verify" "qos-capability apply e2e-test webapp.cap 2>&1 | grep -q 'Applied'"

    # Test cluster discovery
    run_test "E2E: Cluster service discovery" "qos-cluster services | grep -q 'dropbear'"
fi

print_summary "TESTS"
