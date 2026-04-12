#!/bin/sh
# qos-test-e2e - End-to-End Integration Tests for QOS Distro
# Tests real workflows: web servers, clustering, installation, networking
# Usage: qos-test-e2e [--quick] [--verbose]

set -e

TIMEOUT="${TIMEOUT:-15}"
LONG_TIMEOUT="${LONG_TIMEOUT:-30}"
PASS=0
FAIL=0
SKIP=0
WARN=0

# Colors
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

QUICK_MODE=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h)
            echo "Usage: qos-test-e2e [--quick] [--verbose]"
            echo "  --quick    Skip long tests"
            echo "  --verbose  Show detailed output"
            exit 0
            ;;
    esac
done

pass() { PASS=$((PASS + 1)); printf "${GREEN}[PASS]${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}[FAIL]${NC} %s\n" "$1"; [ -n "$2" ] && printf "       Error: %s\n" "$2"; }
warn() { WARN=$((WARN + 1)); printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf "${BLUE}[SKIP]${NC} %s\n" "$1"; }

run_test() {
    local desc="$1" cmd="$2" timeout="${3:-$TIMEOUT}"
    local output="" exit_code=0
    output="$(timeout "$timeout" sh -c "$cmd" 2>&1)" || exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
        fail "$desc" "Timed out after ${timeout}s"
    elif [ "$exit_code" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc" "Exit code: $exit_code"
        [ "$VERBOSE" -eq 1 ] && printf "       Output: %s\n" "$(echo "$output" | head -3)"
    fi
}

section() {
    printf "\n${BLUE}═══════════════════════════════════════════${NC}\n"
    printf "${BLUE}  E2E: %s${NC}\n" "$1"
    printf "${BLUE}═══════════════════════════════════════════${NC}\n"
}

# ============================================================
# E2E TEST 1: Complete Web Server Workflow
# ============================================================
section "E2E TEST 1: Web Server Workflow"

# Test 1.1: Create a web application
if command -v bun >/dev/null 2>&1; then
    run_test "E2E: Bun runtime available" "bun --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        # Create a complete web app
        mkdir -p /tmp/e2e-webapp
        cat > /tmp/e2e-webapp/server.ts <<'EOF'
const server = Bun.serve({
  port: 3000,
  hostname: "0.0.0.0",
  fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/") {
      return new Response("QOS E2E Test - Web Server Working!", {
        headers: { "Content-Type": "text/plain" }
      });
    }
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({
        status: "ok",
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        platform: process.platform
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }
    if (url.pathname.startsWith("/api/")) {
      return new Response(JSON.stringify({
        message: "API endpoint working",
        path: url.pathname,
        method: req.method
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }
    return new Response("Not Found", { status: 404 });
  },
});
console.log(`E2E web server running on http://0.0.0.0:${server.port}`);
EOF

        # Start the server
        cd /tmp/e2e-webapp && bun run server.ts >/dev/null 2>&1 &
        APP_PID=$!
        sleep 3

        # Test all endpoints
        run_test "E2E: Web app starts" "kill -0 $APP_PID 2>/dev/null"
        run_test "E2E: Root endpoint returns 200" "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 | grep -q '200'"
        run_test "E2E: Root endpoint returns content" "curl -s http://localhost:3000 | grep -q 'QOS E2E Test'"
        run_test "E2E: Health endpoint returns JSON" "curl -s http://localhost:3000/health | grep -q 'status.*ok'"
        run_test "E2E: API endpoint works" "curl -s http://localhost:3000/api/test | grep -q 'API endpoint working'"
        run_test "E2E: Custom headers work" "curl -s -H 'X-Test: qos-e2e' http://localhost:3000/health | grep -q 'status'"
        run_test "E2E: 404 for unknown routes" "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/unknown | grep -q '404'"

        # Cleanup
        kill $APP_PID 2>/dev/null || true
        rm -rf /tmp/e2e-webapp
    fi
elif command -v node >/dev/null 2>&1; then
    run_test "E2E: Node.js available" "node --version >/dev/null 2>&1"

    if [ "$QUICK_MODE" -eq 0 ]; then
        cat > /tmp/e2e-server.js <<'EOF'
const http = require('http');
const server = http.createServer((req, res) => {
  if (req.url === '/') {
    res.writeHead(200, {'Content-Type': 'text/plain'});
    res.end('QOS E2E Test - Node.js Server Working!');
  } else if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({status: 'ok', runtime: 'nodejs'}));
  } else {
    res.writeHead(404);
    res.end('Not Found');
  }
});
server.listen(3001, () => console.log('E2E server on port 3001'));
EOF

        node /tmp/e2e-server.js >/dev/null 2>&1 &
        NODE_PID=$!
        sleep 2

        run_test "E2E: Node server starts" "kill -0 $NODE_PID 2>/dev/null"
        run_test "E2E: Node responds" "curl -s http://localhost:3001 | grep -q 'Node.js Server Working'"

        kill $NODE_PID 2>/dev/null || true
        rm -f /tmp/e2e-server.js
    fi
else
    skip "No web runtime (bun/node) available"
fi

# ============================================================
# E2E TEST 2: Network Connectivity & DNS
# ============================================================
section "E2E TEST 2: Network & DNS"

run_test "E2E: External HTTP works" "curl -s -o /dev/null -w '%{http_code}' http://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"
run_test "E2E: External HTTPS works" "curl -sk -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"
run_test "E2E: DNS resolves multiple domains" "nslookup google.com >/dev/null 2>&1 && nslookup github.com >/dev/null 2>&1" "$LONG_TIMEOUT"
run_test "E2E: Can reach multiple external hosts" "ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" "$LONG_TIMEOUT"

# ============================================================
# E2E TEST 3: Capability System End-to-End
# ============================================================
section "E2E TEST 3: Capability System"

run_test "E2E: List capability profiles" "qos-capability list | grep -c 'cap' | grep -q '[1-9]'"
run_test "E2E: Apply capability to service" "qos-capability apply e2e-web webapp.cap 2>&1 | grep -q 'Applied'"
run_test "E2E: Show capability settings" "qos-capability show e2e-web 2>/dev/null | grep -qE 'CPU|Memory|PIDs'"
run_test "E2E: Test capability enforcement" "qos-capability test e2e-web 2>/dev/null | grep -qE 'enforced|set|limit'"

# ============================================================
# E2E TEST 4: Service Management
# ============================================================
section "E2E TEST 4: Service Management"

run_test "E2E: List all services" "s6-rc -a list | grep -q 'dropbear'"
run_test "E2E: Check service status" "s6-svstat /run/service/dropbear 2>/dev/null | grep -q 'up'"

if [ "$QUICK_MODE" -eq 0 ]; then
    # Test service restart
    run_test "E2E: Restart service" "s6-rc -d change dropbear >/dev/null 2>&1 && sleep 1 && s6-rc -u change dropbear >/dev/null 2>&1" "$TIMEOUT"
    run_test "E2E: Service recovers after restart" "sleep 2 && s6-svstat /run/service/dropbear 2>/dev/null | grep -q 'up'" "$TIMEOUT"

    # Test SSH connectivity
    run_test "E2E: SSH port listening" "ss -tlnp 2>/dev/null | grep -q ':22 ' || netstat -tlnp 2>/dev/null | grep -q ':22 '"
fi

# ============================================================
# E2E TEST 5: Filesystem Operations
# ============================================================
section "E2E TEST 5: Filesystem Operations"

run_test "E2E: Write to /var" "echo 'e2e test data' > /var/e2e_test && cat /var/e2e_test | grep -q 'e2e test data' && rm -f /var/e2e_test"
run_test "E2E: Create and delete files" "touch /tmp/e2e_file && ls -l /tmp/e2e_file >/dev/null && rm -f /tmp/e2e_file"
run_test "E2E: Directory operations" "mkdir -p /tmp/e2e_dir/test && rmdir /tmp/e2e_dir/test && rmdir /tmp/e2e_dir"
run_test "E2E: File permissions" "touch /tmp/e2e_perm && chmod 600 /tmp/e2e_perm && stat -c %a /tmp/e2e_perm | grep -q '600' && rm -f /tmp/e2e_perm"
run_test "E2E: Symlink creation" "ln -s /etc/hostname /tmp/e2e_link && cat /tmp/e2e_link | grep -q 'qos' && rm -f /tmp/e2e_link"

# ============================================================
# E2E TEST 6: Package Management
# ============================================================
section "E2E TEST 6: Package Management"

run_test "E2E: Update package index" "apk update >/dev/null 2>&1" "$LONG_TIMEOUT"
run_test "E2E: Search for packages" "apk search curl | grep -q 'curl'" "$TIMEOUT"
run_test "E2E: Check installed packages" "apk info busybox | grep -q 'busybox'" "$TIMEOUT"

if [ "$QUICK_MODE" -eq 0 ]; then
    # Install, test, remove
    run_test "E2E: Install package" "apk add --no-cache strace >/dev/null 2>&1" "$LONG_TIMEOUT"
    run_test "E2E: Use installed package" "strace -V 2>&1 | grep -q 'strace'"
    run_test "E2E: Remove package" "apk del strace >/dev/null 2>&1" "$TIMEOUT"
    run_test "E2E: Verify package removed" "! which strace >/dev/null 2>&1"
fi

# ============================================================
# E2E TEST 7: System Resources & Limits
# ============================================================
section "E2E TEST 7: Resource Management"

run_test "E2E: Memory usage reporting" "free -m | awk '/^Mem:/ {print \$3}' | grep -q '[0-9]'"
run_test "E2E: Disk usage reporting" "df -h / | awk 'NR==2 {print \$5}' | grep -q '[0-9]%'"
run_test "E2E: Process counting" "ps aux | wc -l | grep -q '[0-9]'"
run_test "E2E: CPU info available" "nproc | grep -q '[0-9]'"

# ============================================================
# E2E TEST 8: Logging
# ============================================================
section "E2E TEST 8: Logging System"

run_test "E2E: Log directory exists" "test -d /var/log"
run_test "E2E: Can write logs" "echo 'e2e log entry' > /var/log/e2e_test.log && cat /var/log/e2e_test.log | grep -q 'e2e log entry' && rm -f /var/log/e2e_test.log"

# ============================================================
# E2E TEST 9: QEMU Guest Agent
# ============================================================
section "E2E TEST 9: QEMU Guest Agent"

if ps aux | grep -q '[q]emu-ga'; then
    run_test "E2E: Guest agent running" "ps aux | grep -q '[q]emu-ga'"
    run_test "E2E: Virtio device exists" "test -e /dev/virtio-ports/org.qemu.guest_agent.0"
else
    skip "QEMU guest agent not running (expected on physical hardware)"
fi

# ============================================================
# E2E TEST 10: Security
# ============================================================
section "E2E TEST 10: Security Features"

run_test "E2E: ASLR enabled" "cat /proc/sys/kernel/randomize_va_space | grep -q '[12]'"
run_test "E2E: Root password set" "grep '^root:' /etc/shadow | grep -qv '!!'"
run_test "E2E: Shadow file secure" "stat -c %a /etc/shadow | grep -qE '400|640'"

# ============================================================
# SUMMARY
# ============================================================
section "E2E TEST SUMMARY"

TOTAL=$((PASS + FAIL + WARN + SKIP))
printf "\n"
printf "${GREEN}PASS:${NC}  %-5d\n" "$PASS"
printf "${RED}FAIL:${NC}  %-5d\n" "$FAIL"
printf "${YELLOW}WARN:${NC}  %-5d\n" "$WARN"
printf "${BLUE}SKIP:${NC}  %-5d\n" "$SKIP"
printf "TOTAL:  %-5d\n" "$TOTAL"

if [ "$TOTAL" -gt 0 ]; then
    PASS_RATE=$((PASS * 100 / TOTAL))
    printf "\nPass Rate: ${GREEN}%d%%${NC}\n" "$PASS_RATE"
fi

printf "\n"
if [ "$FAIL" -eq 0 ]; then
    printf "${GREEN}✅ ALL E2E TESTS PASSED (${PASS}/${TOTAL})${NC}\n"
    exit 0
else
    printf "${RED}❌ $FAIL E2E TEST(S) FAILED${NC}\n"
    exit 1
fi
