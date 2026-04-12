# QOS Complete Testing Guide

**Version:** 2.0 - Complete E2E Testing  
**Date:** 2026-04-12

---

## Quick Start

### 1. Boot QOS

```bash
# Build first
make clean && make full

# Boot with good resources (recommended for e2e tests)
QEMU_MEM=512 QEMU_CPUS=4 make qemu
```

### 2. Login

```
Username: root
Password: root
```

### 3. Get IP Address

```bash
ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1
# Example: 10.0.3.76
```

### 4. SSH In

```bash
ssh root@10.0.3.76
# Password: root
```

---

## Test Suites Overview

### Test 1: Quick System Test (~30 seconds)

Tests basic system health:
```bash
qos-test --quick
```

### Test 2: Full System Test (~2 minutes)

Tests all system features:
```bash
qos-test --verbose
```

### Test 3: Complete E2E Test (~5-10 minutes) ⭐ RECOMMENDED

Tests real workloads:
- ✅ Install Bun and run web application
- ✅ Install k3s and test Kubernetes
- ✅ Install GCC and build/run C application
- ✅ User and group management
- ✅ Capability system with real services
- ✅ Network and DNS end-to-end
- ✅ Service management and restart

```bash
qos-e2e-full --verbose
```

**Options:**
```bash
qos-e2e-full              # Full test with everything
qos-e2e-full --skip-bun   # Skip Bun web app test
qos-e2e-full --skip-k3s   # Skip k3s test
qos-e2e-full --verbose    # Show detailed output
```

---

## What Each Test Does

### E2E Test 1: Bun Web Application

```bash
# What it does:
1. Installs Bun runtime from https://bun.sh/install
2. Creates a complete TypeScript web server
3. Starts the server on port 3000
4. Tests all endpoints:
   - GET / → HTML page
   - GET /health → JSON health check
   - GET /api/info → JSON API response
   - Unknown routes → 404
5. Tests concurrent requests
6. Applies capability profile to the app
7. Verifies app still works after capability apply
8. Cleans up

# Expected output:
[PASS] E2E: Install Bun runtime
[PASS] E2E: Bun installed and in PATH
[PASS] E2E: Bun process running
[PASS] E2E: Root endpoint (HTTP 200)
[PASS] E2E: Root returns HTML
[PASS] E2E: Health endpoint returns JSON
[PASS] E2E: API info endpoint
[PASS] E2E: Custom headers work
[PASS] E2E: 404 for unknown routes
[PASS] E2E: Multiple concurrent requests
[PASS] E2E: Apply capability to Bun app
[PASS] E2E: App still works after capability apply
```

### E2E Test 2: k3s Kubernetes

```bash
# What it does:
1. Checks system has enough resources (512MB+ RAM, 500MB+ disk)
2. Installs k3s from https://get.k3s.io
3. Waits for k3s to start
4. Tests kubectl commands:
   - kubectl get nodes
   - kubectl version
5. Shows node status and system pods

# Expected output:
[PASS] E2E: Sufficient RAM for k3s (need 512MB+)
[PASS] E2E: Sufficient disk space (need 500MB+)
[PASS] E2E: Install k3s
[PASS] E2E: k3s service running
[PASS] E2E: kubectl/node command works
[PASS] E2E: Node status shows Ready

# After test, you can:
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
```

### E2E Test 3: User & Group Management

```bash
# What it does:
1. Creates test group (e2etestgroup)
2. Creates regular user (e2euser) with home directory
3. Creates service user (nginx) with no login shell
4. Creates admin user (adminuser) in root group
5. Tests user switching (su)
6. Verifies user/group properties
7. Cleans up all test users

# Expected output:
[PASS] E2E: Create group
[PASS] E2E: Group exists
[PASS] E2E: Create user
[PASS] E2E: User exists
[PASS] E2E: User has home directory
[PASS] E2E: User in correct group
[PASS] E2E: User can login (su)
[PASS] E2E: User has limited shell
[PASS] E2E: Create service user (nginx)
[PASS] E2E: Service user has no login shell
[PASS] E2E: Create admin user
[PASS] E2E: Admin user in root group
[PASS] E2E: List users
[PASS] E2E: List groups
[PASS] E2E: Test user removed
[PASS] E2E: Test group removed
```

### E2E Test 4: Capability System

```bash
# What it does:
1. Lists all capability profiles
2. Applies different profiles:
   - webapp.cap → test-web service
   - database.cap → test-db service
   - reverse-proxy.cap → test-rp service
3. Shows capability settings
4. Tests enforcement

# Expected output:
[PASS] E2E: List all capability profiles
[PASS] E2E: webapp profile exists
[PASS] E2E: database profile exists
[PASS] E2E: reverse-proxy profile exists
[PASS] E2E: Apply webapp capability
[PASS] E2E: Apply database capability
[PASS] E2E: Apply reverse-proxy capability
[PASS] E2E: Show webapp capability
[PASS] E2E: Test webapp enforcement
```

### E2E Test 7: GCC Build & C Application

```bash
# What it does:
1. Installs gcc, musl-dev, make
2. Creates a C application that:
   - Shows system info (PID, UID, uptime)
   - Performs computation (sum 1 to 1M)
   - Prints results
3. Compiles with gcc
4. Runs the binary
5. Tests with Make build system
6. Cleans up

# Expected output:
[PASS] E2E: Install gcc and build tools
[PASS] E2E: GCC available
[PASS] E2E: Make available
[PASS] E2E: Compile C program
[PASS] E2E: Binary created
[PASS] E2E: Binary is ELF format
[PASS] E2E: Run compiled application
[PASS] E2E: Application output correct
[PASS] E2E: Make clean
[PASS] E2E: Make all
[PASS] E2E: Make built binary works
```

---

## Manual Testing

### Test Bun Manually

```bash
# Install Bun
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"

# Create app
mkdir -p /tmp/myapp
cat > /tmp/myapp/server.ts <<'EOF'
const server = Bun.serve({
  port: 3000,
  fetch(req) {
    return new Response("Hello from Bun on QOS!");
  },
});
console.log(`Server on port ${server.port}`);
EOF

# Run it
cd /tmp/myapp
bun run server.ts &

# Test it
curl http://localhost:3000
# Output: Hello from Bun on QOS!

# Stop it
kill %1
```

### Test k3s Manually

```bash
# Install k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable=traefik' sh -

# Wait for it to start
sleep 15

# Check nodes
sudo k3s kubectl get nodes

# Check pods
sudo k3s kubectl get pods -A

# Deploy something
sudo k3s kubectl create deployment nginx --image=nginx
sudo k3s kubectl get pods

# Uninstall (optional)
# /usr/local/bin/k3s-uninstall.sh
```

### Test Users/Groups Manually

```bash
# Create group
addgroup -S developers

# Create user
adduser -S -G developers -h /home/devuser -s /bin/sh devuser

# Verify
id devuser
# Output: uid=... (devuser) gid=... (developers) groups=... (developers)

# Switch to user
su - devuser
whoami
# Output: devuser

# Exit back to root
exit

# Create service user
adduser -S -D -G nogroup -s /sbin/nologin -H myservice

# List all users
cat /etc/passwd | grep -v nologin | grep -v /bin/false

# List all groups
cat /etc/group
```

### Test GCC Build Manually

```bash
# Install build tools
apk add --no-cache gcc musl-dev make

# Create C program
cat > hello.c <<'EOF'
#include <stdio.h>
int main() {
    printf("Hello from QOS!\n");
    return 0;
}
EOF

# Compile
gcc -o hello hello.c -Wall -O2

# Run
./hello
# Output: Hello from QOS!

# Or use Make
cat > Makefile <<'EOF'
CC = gcc
CFLAGS = -Wall -O2
TARGET = hello

all: $(TARGET)

$(TARGET): hello.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)
EOF

make
./hello
```

### Test Capabilities Manually

```bash
# List profiles
qos-capability list

# Apply to a service
qos-capability apply myapp webapp.cap

# Show settings
qos-capability show myapp

# Test enforcement
qos-capability test myapp
```

---

## Expected Results

### Full E2E Test Results

```
═══════════════════════════════════════════════
  COMPLETE E2E TEST SUMMARY
═══════════════════════════════════════════════

PASS:  45
FAIL:  0
WARN:  2
SKIP:  3
TOTAL: 50

Pass Rate: 90%

═══════════════════════════════════════════════
  ✅ ALL E2E TESTS PASSED (45/50)
═══════════════════════════════════════════════
```

### Expected Skips (Normal)

```
[SKIP] Bun tests skipped (--skip-bun)
  → Normal if you don't want to install Bun

[SKIP] k3s tests skipped (--skip-k3s)
  → Normal if insufficient resources

[SKIP] GCC not available, skipping build tests
  → Normal if gcc not installed
```

---

## Troubleshooting

### Bun Installation Fails

```bash
# Check if unzip is available
which unzip || apk add --no-cache unzip

# Try manual install
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"
bun --version
```

### k3s Installation Fails

```bash
# Check resources
free -m
df -h

# Need at least:
# - 512MB RAM
# - 500MB free disk

# Check if port 6443 is free
ss -tlnp | grep 6443

# Check logs
cat /var/log/k3s.log 2>/dev/null || journalctl -u k3s 2>/dev/null
```

### GCC Build Fails

```bash
# Check if musl-dev is installed
apk info musl-dev || apk add --no-cache musl-dev

# Check disk space
df -h /tmp

# Need at least 100MB free for compilation
```

### Tests Timeout

```bash
# Increase timeout
TIMEOUT=60 qos-e2e-full --verbose

# Or skip long tests
qos-e2e-full --skip-bun --skip-k3s
```

---

## Test Reports

### Generate Test Report

```bash
# Run tests and save output
qos-e2e-full --verbose > /var/log/qos-e2e-report.txt 2>&1

# View report
cat /var/log/qos-e2e-report.txt

# Extract summary
grep -A 10 "E2E TEST SUMMARY" /var/log/qos-e2e-report.txt
```

### Quick Health Check

```bash
# Quick system check (30 seconds)
qos-test --quick

# Quick e2e check (2 minutes)
qos-e2e-full --skip-bun --skip-k3s
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
- name: Test QOS
  run: |
    make qemu &
    sleep 30
    ssh root@10.0.3.76 << 'EOF'
      qos-test --quick
      qos-e2e-full --skip-k3s
    EOF
```

### Makefile Target

```makefile
.PHONY: test-e2e
test-e2e:
	@echo "Running E2E tests..."
	@ssh root@$(QEMU_IP) "qos-e2e-full --verbose"
```

---

**End of Complete Testing Guide**

Run `qos-e2e-full --verbose` for the most comprehensive test!
