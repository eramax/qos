# QOS Test Suite

Comprehensive test suite for QOS Distro that tests all system features with timeouts.

## Usage

```bash
# Run all tests
qos-test

# Run quick tests (skip long-running tests)
qos-test --quick

# Run with verbose output
qos-test --verbose
```

## What It Tests

The test suite runs 100+ checks across 20 categories:

1. **Core System** - Kernel, shell, init, package manager
2. **Memory & Resources** - RAM usage, swap, process monitoring
3. **Filesystem** - Overlay, partitions, read-only root, temp directories
4. **Kernel Features** - Cgroups v2, ZRAM, modules
5. **Networking** - Interfaces, routing, DNS, external connectivity
6. **SSH (Dropbear)** - Process, port, host keys
7. **Firewall (nftables)** - Rules, chains, policies
8. **Services (s6)** - All 10 services running
9. **Capability System** - Profiles, application, enforcement
10. **Cluster System** - Discovery, status, resources
11. **Disk Expansion** - qos-expand tool
12. **Time & Scheduling** - Chrony, dcron
13. **Curl & HTTP** - External requests, headers, HTTPS
14. **Local Web Server** - Python HTTP server test
15. **App Installation** - apk update, install, remove
16. **Bun Runtime** - Optional Bun server test
17. **Security Features** - ASLR, seccomp, shadow file
18. **Logging & Monitoring** - Log directories, htop
19. **User Management** - Users, groups, permissions
20. **System Utilities** - Coreutils, text processing tools

## Timeout Configuration

All commands have timeouts to prevent hangs:

- Default: 10 seconds
- Network tests: 30 seconds
- Can be overridden: `TIMEOUT=15 qos-test`

## Output Format

```
[PASS] Test description
[FAIL] Test description
       Error: Details
[WARN] Test description
       Detail: Info
[SKIP] Test description (reason)
```

## Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

## Examples

```bash
# Quick health check (runs in ~30 seconds)
qos-test --quick

# Full test suite (runs in ~2-3 minutes)
qos-test --verbose

# Custom timeout (5 seconds for default tests)
TIMEOUT=5 qos-test

# Save output to file
qos-test --verbose > /var/log/qos-test-results.log 2>&1
```

## Testing in CI

```bash
# In CI/CD pipeline
if qos-test --quick; then
    echo "✅ System health check passed"
else
    echo "❌ System health check failed"
    exit 1
fi
```

## Adding Custom Tests

Edit `/usr/bin/qos-test` and add your tests:

```bash
# Add to appropriate section
run_test "Your test description" "your command here" "timeout_seconds"
```

## Troubleshooting

**Tests failing due to timeout:**
```bash
# Increase timeout
TIMEOUT=30 qos-test

# Run with verbose to see what's hanging
qos-test --verbose
```

**Network tests failing:**
```bash
# Check connectivity first
ping -c 3 8.8.8.8

# Then run tests without network tests
qos-test --quick
```

**Service tests failing:**
```bash
# Check service status manually
s6-rc -a list
s6-svstat /run/service/*
```
