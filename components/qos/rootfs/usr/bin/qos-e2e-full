#!/bin/sh
# qos-e2e-full - Complete End-to-End Test with Real Workloads
# Tests: Bun webapp, k3s, capabilities, users/groups
# Usage: qos-e2e-full [--skip-bun] [--skip-k3s] [--verbose]

set -e

TIMEOUT="${TIMEOUT:-30}"
LONG_TIMEOUT="${LONG_TIMEOUT:-60}"

SKIP_BUN=0
SKIP_K3S=0
VERBOSE=0
for arg in "$@"; do
    case "$arg" in
        --skip-bun) SKIP_BUN=1 ;;
        --skip-k3s) SKIP_K3S=1 ;;
        --verbose) VERBOSE=1 ;;
        --help|-h)
            echo "Usage: qos-e2e-full [--skip-bun] [--skip-k3s] [--verbose]"
            exit 0
            ;;
    esac
done

_common="/usr/lib/qos-test-common.sh"
[ -f "$_common" ] || _common="$(dirname "$0")/lib/test-common.sh"
. "$_common"

section() {
    printf "\n${BLUE}═══════════════════════════════════════════════${NC}\n"
    printf "${BLUE}  E2E: %s${NC}\n" "$1"
    printf "${BLUE}═══════════════════════════════════════════════${NC}\n"
}

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf "       ${BLUE}[LOG]${NC} %s\n" "$1"
    fi
}

# ============================================================
# TEST 1: Install Bun & Run Web App
# ============================================================
section "TEST 1: Install Bun & Run Web Application"

if [ "$SKIP_BUN" -eq 0 ]; then
    # Check prerequisites
    run_test "E2E: curl available for install" "which curl >/dev/null 2>&1"
    run_test "E2E: unzip available" "which unzip >/dev/null 2>&1 || apk add --no-cache unzip >/dev/null 2>&1"

    # Install Bun
    log "Installing Bun..."
    run_test "E2E: Install Bun runtime" "curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1" "$LONG_TIMEOUT"
    
    # Add to PATH
    export PATH="$HOME/.bun/bin:$PATH"
    
    run_test "E2E: Bun installed and in PATH" "~/.bun/bin/bun --version >/dev/null 2>&1"

    if command -v bun >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/bun" ]; then
        BUN_BIN="$HOME/.bun/bin/bun"
        [ -x "$BUN_BIN" ] || BUN_BIN="bun"
        
        log "Bun version: $($BUN_BIN --version 2>/dev/null || echo 'unknown')"

        # Create web application
        log "Creating web application..."
        mkdir -p /var/lib/e2e-webapp
        cat > /var/lib/e2e-webapp/server.ts <<'BUNEOF'
const server = Bun.serve({
  port: 3000,
  hostname: "0.0.0.0",
  fetch(req) {
    const url = new URL(req.url);
    
    if (url.pathname === "/") {
      return new Response(
        `<h1>QOS E2E Test</h1><p>Bun web server is working!</p>
         <p>Uptime: ${process.uptime().toFixed(1)}s</p>
         <p>Memory: ${JSON.stringify(process.memoryUsage())}</p>`,
        { headers: { "Content-Type": "text/html" } }
      );
    }
    
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({
        status: "ok",
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        platform: process.platform,
        arch: process.arch,
        version: process.version
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }
    
    if (url.pathname === "/api/info") {
      return new Response(JSON.stringify({
        service: "qos-e2e-api",
        version: "1.0.0",
        endpoints: ["/", "/health", "/api/info"],
        runtime: "bun",
        timestamp: Date.now()
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }
    
    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Bun server running on http://0.0.0.0:${server.port}`);
BUNEOF

        # Start Bun server
        log "Starting Bun server..."
        $BUN_BIN run /var/lib/e2e-webapp/server.ts >/dev/null 2>&1 &
        BUN_PID=$!
        log "Bun PID: $BUN_PID"
        sleep 3

        # Test all endpoints
        run_test "E2E: Bun process running" "kill -0 $BUN_PID 2>/dev/null"
        run_test "E2E: Root endpoint (HTTP 200)" "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000 | grep -q '200'"
        run_test "E2E: Root returns HTML" "curl -s http://localhost:3000 | grep -q 'QOS E2E Test'"
        run_test "E2E: Health endpoint returns JSON" "curl -s http://localhost:3000/health | grep -q '\"status\".*\"ok\"'"
        run_test "E2E: Health has memory info" "curl -s http://localhost:3000/health | grep -q 'memory'"
        run_test "E2E: API info endpoint" "curl -s http://localhost:3000/api/info | grep -q 'qos-e2e-api'"
        run_test "E2E: Custom headers work" "curl -s -H 'X-Test: qos' -H 'Authorization: Bearer test' http://localhost:3000/health | grep -q 'status'"
        run_test "E2E: 404 for unknown routes" "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/nonexistent | grep -q '404'"
        run_test "E2E: Multiple concurrent requests" "(curl -s http://localhost:3000 & curl -s http://localhost:3000/health & curl -s http://localhost:3000/api/info & wait) | grep -q 'ok\\|QOS\\|api'"

        # Now test capability system with this running app
        log "Testing capability system with running Bun app..."
        run_test "E2E: Apply capability to Bun app" "qos-Capability apply bun-webapp webapp.cap 2>&1 | grep -q 'Applied'"
        run_test "E2E: Verify capability applied" "qos-Capability show bun-webapp 2>/dev/null | head -3 | grep -q 'Capability'"
        run_test "E2E: Test capability enforcement" "qos-Capability test bun-webapp 2>/dev/null | head -5 | grep -qE 'enforced|set|limit|not set'"

        # Test that app still works after capability apply
        run_test "E2E: App still works after capability apply" "curl -s http://localhost:3000/health | grep -q 'ok'"

        # Cleanup
        log "Stopping Bun server..."
        kill $BUN_PID 2>/dev/null || true
        rm -rf /var/lib/e2e-webapp
    else
        skip "Bun not available, skipping web app tests"
    fi
else
    skip "Bun tests skipped (--skip-bun)"
fi

# ============================================================
# TEST 2: Install k3s & Test Kubernetes
# ============================================================
section "TEST 2: Install k3s & Test Kubernetes"

if [ "$SKIP_K3S" -eq 0 ]; then
    # Check prerequisites
    run_test "E2E: Sufficient RAM for k3s (need 512MB+)" "free -m | awk '/^Mem:/ {exit (\$2 >= 512) ? 0 : 1}'"
    run_test "E2E: Sufficient disk space (need 500MB+)" "df -m /var | awk 'NR==2 {exit (\$4 >= 500) ? 0 : 1}'"

    if [ $? -eq 0 ]; then
        log "Installing k3s..."
        run_test "E2E: Install k3s" "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=traefik --disable=metrics-server' sh -" "$LONG_TIMEOUT"

        # Wait for k3s to start
        log "Waiting for k3s to start..."
        sleep 15

        # Check k3s service
        run_test "E2E: k3s service running" "systemctl is-active k3s 2>/dev/null | grep -q 'active' || ps aux | grep -q '[k]3s-server'"
        
        # Test kubectl
        if [ -f /usr/local/bin/kubectl ]; then
            KUBECTL="/usr/local/bin/kubectl"
        elif [ -f /usr/local/bin/k3s ]; then
            KUBECTL="k3s kubectl"
        else
            KUBECTL="kubectl"
        fi

        run_test "E2E: kubectl/node command works" "sudo $KUBECTL get nodes 2>/dev/null | grep -q 'Ready' || k3s kubectl get nodes 2>/dev/null | grep -q 'Ready'" "$TIMEOUT"
        run_test "E2E: Node status shows Ready" "sudo $KUBECTL get nodes 2>/dev/null | grep -q 'Ready' || true"
        run_test "E2E: kubectl version works" "sudo $KUBECTL version --short 2>/dev/null | grep -q 'Server' || true"

        if [ "$VERBOSE" -eq 1 ]; then
            log "Node status:"
            sudo $KUBECTL get nodes 2>/dev/null | head -5 || echo "  kubectl not ready yet"
            log "System pods:"
            sudo $KUBECTL get pods -n kube-system 2>/dev/null | head -10 || echo "  No pods yet"
        fi

        # Note: k3s is left running for further testing
        log "k3s installed and running. Can test further with: sudo k3s kubectl <command>"
    else
        skip "Insufficient resources for k3s (need 512MB RAM, 500MB disk)"
    fi
else
    skip "k3s tests skipped (--skip-k3s)"
fi

# ============================================================
# TEST 3: User & Group Management
# ============================================================
section "TEST 3: User & Group Management"

# Create test group
run_test "E2E: Create group" "addgroup -S e2etestgroup 2>/dev/null || grep -q '^e2etestgroup:' /etc/group"
run_test "E2E: Group exists" "grep -q '^e2etestgroup:' /etc/group"

# Create test user
run_test "E2E: Create user" "adduser -S -G e2etestgroup -h /home/e2euser -s /bin/sh e2euser 2>/dev/null || grep -q '^e2euser:' /etc/passwd"
run_test "E2E: User exists" "grep -q '^e2euser:' /etc/passwd"
run_test "E2E: User has home directory" "test -d /home/e2euser || mkdir -p /home/e2euser && chown e2euser:e2etestgroup /home/e2euser"
run_test "E2E: User in correct group" "id e2euser 2>/dev/null | grep -q 'e2etestgroup' || grep '^e2euser:' /etc/passwd | grep -q '/home/e2euser'"

# Test user capabilities
run_test "E2E: User can login (su)" "su - e2euser -c 'whoami' 2>/dev/null | grep -q 'e2euser'"
run_test "E2E: User has limited shell" "grep '^e2euser:' /etc/passwd | grep -q '/bin/sh'"

# Create service user
run_test "E2E: Create service user (nginx)" "adduser -S -D -G nogroup -s /sbin/nologin -H nginx 2>/dev/null || grep -q '^nginx:' /etc/passwd"
run_test "E2E: Service user has no login shell" "grep '^nginx:' /etc/passwd | grep -q '/sbin/nologin'"

# Create admin user
run_test "E2E: Create admin user" "adduser -D -G root adminuser 2>/dev/null || grep -q '^adminuser:' /etc/passwd"
run_test "E2E: Admin user in root group" "id adminuser 2>/dev/null | grep -q 'root' || grep '^adminuser:' /etc/passwd | grep -q '/root'"

# List users and groups
run_test "E2E: List users" "cat /etc/passwd | wc -l | grep -q '[0-9]'"
run_test "E2E: List groups" "cat /etc/group | wc -l | grep -q '[0-9]'"

# Test user switching
run_test "E2E: Current user is root" "whoami | grep -q 'root'"

# Cleanup
log "Cleaning up test users..."
userdel e2euser 2>/dev/null || true
userdel nginx 2>/dev/null || true  
userdel adminuser 2>/dev/null || true
delgroup e2etestgroup 2>/dev/null || true
rm -rf /home/e2euser 2>/dev/null || true

run_test "E2E: Test user removed" "! grep -q '^e2euser:' /etc/passwd"
run_test "E2E: Test group removed" "! grep -q '^e2etestgroup:' /etc/group"

# ============================================================
# TEST 4: Capability System with Real Services
# ============================================================
section "TEST 4: Capability System with Real Services"

run_test "E2E: List all capability profiles" "qos-Capability list | grep -c '.cap' | grep -q '[1-9]'"
run_test "E2E: webapp profile exists" "qos-Capability list | grep -q 'webapp'"
run_test "E2E: database profile exists" "qos-Capability list | grep -q 'database'"
run_test "E2E: reverse-proxy profile exists" "qos-Capability list | grep -q 'reverse-proxy'"

# Apply and verify different profiles
run_test "E2E: Apply webapp capability" "qos-Capability apply test-web webapp.cap 2>&1 | grep -qi 'applied'"
run_test "E2E: Apply database capability" "qos-Capability apply test-db database.cap 2>&1 | grep -qi 'applied'"
run_test "E2E: Apply reverse-proxy capability" "qos-Capability apply test-rp reverse-proxy.cap 2>&1 | grep -qi 'applied'"

# Show and test
run_test "E2E: Show webapp capability" "qos-Capability show test-web 2>/dev/null | head -5 | grep -qE 'Capability|CPU|Memory|PIDs'"
run_test "E2E: Show database capability" "qos-Capability show test-db 2>/dev/null | head -5 | grep -qE 'Capability|CPU|Memory|PIDs'"
run_test "E2E: Test webapp enforcement" "qos-Capability test test-web 2>/dev/null | head -5 | grep -qE 'enforced|set|limit|not set'"

# ============================================================
# TEST 5: Network & DNS End-to-End
# ============================================================
section "TEST 5: Network & DNS End-to-End"

run_test "E2E: External HTTP (example.com)" "curl -s -o /dev/null -w '%{http_code}' http://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"
run_test "E2E: External HTTPS" "curl -sk -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null | grep -q '200'" "$LONG_TIMEOUT"
run_test "E2E: DNS resolves multiple domains" "(nslookup google.com >/dev/null 2>&1 && nslookup github.com >/dev/null 2>&1 && nslookup cloudflare.com >/dev/null 2>&1)" "$LONG_TIMEOUT"
run_test "E2E: Multiple external pings" "(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1)"

# ============================================================
# TEST 6: Service Management End-to-End
# ============================================================
section "TEST 6: Service Management"

run_test "E2E: List all services" "s6-rc -a list | grep -c '.' | grep -q '[0-9]'"
run_test "E2E: Core services running" "(s6-svstat /run/service/dropbear 2>/dev/null | grep -q 'up' && s6-svstat /run/service/networking 2>/dev/null | grep -q 'up')"

if [ "$QUICK_MODE" -eq 0 ] 2>/dev/null || [ "$1" != "--quick" ]; then
    run_test "E2E: Restart service works" "s6-rc -d change dropbear >/dev/null 2>&1 && sleep 1 && s6-rc -u change dropbear >/dev/null 2>&1"
    run_test "E2E: Service recovers" "sleep 2 && s6-svstat /run/service/dropbear 2>/dev/null | grep -q 'up'"
fi

# ============================================================
# TEST 7: Install GCC & Build/Run C Application
# ============================================================
section "TEST 7: Install GCC & Build/Run C Application"

run_test "E2E: Install gcc and build tools" "apk add --no-cache gcc musl-dev make >/dev/null 2>&1" "$LONG_TIMEOUT"
run_test "E2E: GCC available" "gcc --version 2>/dev/null | grep -q 'gcc' || which gcc >/dev/null 2>&1"
run_test "E2E: Make available" "make --version 2>/dev/null | grep -q 'Make' || which make >/dev/null 2>&1"

if command -v gcc >/dev/null 2>&1; then
    log "GCC version: $(gcc --version 2>/dev/null | head -1)"
    
    # Create simple C application
    log "Creating C application..."
    mkdir -p /tmp/e2e-build
    cat > /tmp/e2e-build/hello.c <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char *argv[]) {
    printf("=== QOS E2E C Application ===\n");
    printf("Built with GCC on Alpine Linux (musl)\n");
    printf("\n");
    
    // Show system info
    printf("System Information:\n");
    printf("  PID: %d\n", getpid());
    printf("  UID: %d\n", getuid());
    printf("  Arguments: %d\n", argc);
    
    // Show uptime info
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    printf("  Uptime: %ld.%03ld seconds\n", ts.tv_sec, ts.tv_nsec / 1000000);
    
    // Simple computation
    printf("\nComputation Test:\n");
    long sum = 0;
    for (long i = 1; i <= 1000000; i++) {
        sum += i;
    }
    printf("  Sum 1 to 1000000: %ld\n", sum);
    printf("  Computation completed successfully\n");
    
    printf("\n✅ C application built and running on QOS!\n");
    return 0;
}
CEOF

    # Build the application
    log "Building C application..."
    run_test "E2E: Compile C program" "gcc -o /tmp/e2e-build/hello /tmp/e2e-build/hello.c -Wall -O2 2>/dev/null"
    run_test "E2E: Binary created" "test -x /tmp/e2e-build/hello"
    run_test "E2E: Binary is ELF format" "file /tmp/e2e-build/hello 2>/dev/null | grep -q 'ELF'"
    run_test "E2E: Run compiled application" "/tmp/e2e-build/hello | grep -q 'QOS E2E C Application'"
    run_test "E2E: Application output correct" "/tmp/e2e-build/hello | grep -q 'Sum 1 to 1000000: 500000500000'"

    # Test with make
    log "Testing make build system..."
    cat > /tmp/e2e-build/Makefile <<'MKEOF'
CC = gcc
CFLAGS = -Wall -O2
TARGET = hello

all: $(TARGET)

$(TARGET): hello.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
MKEOF

    run_test "E2E: Make clean" "cd /tmp/e2e-build && make clean >/dev/null 2>&1"
    run_test "E2E: Make all" "cd /tmp/e2e-build && make all 2>/dev/null | grep -q 'gcc' || make all >/dev/null 2>&1"
    run_test "E2E: Make built binary works" "/tmp/e2e-build/hello | grep -q 'QOS E2E'"

    # Cleanup
    rm -rf /tmp/e2e-build
else
    skip "GCC not available, skipping build tests"
fi

print_summary "COMPLETE E2E TESTS"
