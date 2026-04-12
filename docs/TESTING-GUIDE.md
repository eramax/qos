# QOS Testing Guide

**Version:** 2.0  
**Date:** 2026-04-12

---

## Quick Start Testing

### 1. Boot QOS in QEMU

```bash
# Boot with default settings (1GB RAM, 2 CPU, 256MB disk + 1GB extra disk)
make qemu

# Or with custom resources
QEMU_MEM=512 QEMU_CPUS=4 make qemu
```

### 2. Login

The system boots to a serial console. Login with:
```
Username: root
Password: root
```

### 3. Check System

```bash
# Check services
s6-rc -a list

# Check memory
free -m

# Check disk
df -h

# Check network
ip addr show
```

### 4. Run Tests

```bash
# Quick system test (~30 seconds)
qos-test --quick

# Full system test (~2 minutes)
qos-test --verbose

# End-to-end integration tests (~3 minutes)
qos-test-e2e --verbose
```

---

## SSH Access (Recommended)

### Find IP Address

After boot, the IP is shown in the serial console. Or check:
```bash
ip -4 addr show eth0 | awk '/inet / {print $2}' | cut -d/ -f1
```

### SSH In

```bash
ssh root@10.0.3.76
# Password: root
```

### Run All Tests via SSH

```bash
ssh root@10.0.3.76

# Run quick test
qos-test --quick

# Run e2e tests
qos-test-e2e --verbose

# Test installation
qos-install --auto /dev/vdb
```

---

## Test Suites

### qos-test (System Health)

Tests basic system functionality:
- Core system (kernel, shell, init)
- Memory & resources
- Filesystem (overlay, partitions)
- Kernel features (cgroups, zram)
- Networking (DHCP, routing, DNS)
- SSH (dropbear)
- Firewall (nftables)
- Services (s6)
- Capability system
- Cluster discovery
- Disk tools
- Curl & HTTP
- Security features
- Logging
- User management
- System utilities

**Usage:**
```bash
qos-test --quick     # ~30 seconds, skips long tests
qos-test             # ~2 minutes, full test
qos-test --verbose   # Shows detailed output
```

### qos-test-e2e (Integration Tests)

Tests real workflows:
- Web server deployment (Bun/Node.js)
- Network connectivity & DNS
- Capability system end-to-end
- Service management & restart
- Filesystem operations
- Package management (install/use/remove)
- Resource management
- Logging system
- QEMU guest agent
- Security features

**Usage:**
```bash
qos-test-e2e --quick     # Skips web server tests
qos-test-e2e             # Full e2e suite
qos-test-e2e --verbose   # Detailed output
```

---

## Expected Test Results

### Passing Tests (Should be GREEN)

```
[PASS] Kernel version is 6.19.x
[PASS] Hostname is set
[PASS] Shell is ash/busybox
[PASS] Package manager (apk) works
[PASS] Init system (s6) running
[PASS] Memory usage <60 MB
[PASS] Root is overlay filesystem
[PASS] Var partition mounted
[PASS] Cgroups v2 mounted
[PASS] Cgroup controllers available
[PASS] ZRAM device exists
[PASS] Swap enabled
[PASS] Network interface eth0 exists
[PASS] Interface has IP address
[PASS] Default route configured
[PASS] Dropbear process running
[PASS] SSH port 22 listening
[PASS] Nftables command works
[PASS] Service: getty running
[PASS] Service: networking running
[PASS] Service: dropbear running
[PASS] Service: nftables running
[PASS] Service: zram running
[PASS] qos-Capability command exists
[PASS] List capability profiles
[PASS] qos-cluster command exists
[PASS] Cluster nodes command
[PASS] Curl command exists
[PASS] Curl external URL (example.com HTTP)
[PASS] ASLR enabled
[PASS] Root has password hash
```

### Expected Skips (BLUE is OK)

```
[SKIP] No runtime available (bun/node/python3), skipping web server test
  → OK if no runtime installed

[SKIP] QEMU guest agent not running (expected on physical hardware)
  → OK if virtio channel not available

[SKIP] Caddy not installed, skipping reverse proxy tests
  → OK if caddy not in packages
```

---

## Testing qos-install

### Prerequisites

- Running QOS system
- Second disk available (e.g., /dev/vdb)
- At least 200MB on target disk

### Interactive Test

```bash
# SSH into running system
ssh root@10.0.3.76

# Check available disks
lsblk

# Install to second disk
qos-install /dev/vdb

# You'll see:
# WARNING: This will erase all data on /dev/vdb
# Continue? [y/N] y

# Watch installation progress...
```

### Non-Interactive Test

```bash
qos-install --auto /dev/vdb
```

### Verify Installation

```bash
# Check partition layout
fdisk -l /dev/vdb

# Should show:
# Device     Start    End  Sectors Size Type
# /dev/vdb1   2048 133119 131072  64M EFI System
# /dev/vdb2 133120 231423  98304  48M Linux filesystem
# /dev/vdb3 231424 518143 284672  92M Linux filesystem

# Check installation metadata
cat /var/lib/qos/installed.conf
```

---

## Common Issues & Fixes

### Issue 1: "Permission denied" on service run scripts

**Symptom:**
```
s6-supervise <service>: warning: unable to spawn ./run (waiting 60 seconds): Permission denied
```

**Fix:**
```bash
chmod +x /etc/s6/service-tree/<service>/run
s6-rc -d change <service>
s6-rc -u change <service>
```

### Issue 2: "No such file or directory" for service

**Symptom:**
```
s6-supervise ntpd: warning: unable to spawn ./run (waiting 60 seconds): No such file or directory
```

**Fix:**
```bash
# Service was deleted but s6 still tracking it
rm -rf /run/service/ntpd
```

### Issue 3: DNS resolution fails

**Symptom:**
```
ping: bad address 'google.com'
```

**Fix:**
```bash
# Check if networking is up
ip addr show eth0

# Manually run DHCP
busybox udhcpc -i eth0 -T 5 -t 10

# Check DNS
cat /etc/resolv.conf
```

### Issue 4: Services not starting

**Symptom:**
```
s6-rc -a list
s6-rc: fatal: unable to take locks: No such file or directory
```

**Fix:**
```bash
# Service database not initialized
# Reboot the system
reboot

# Or manually initialize
s6-rc-init /run/service
```

### Issue 5: Installation fails

**Symptom:**
```
[INSTALL] ERROR: Disk too small
```

**Fix:**
```bash
# Check disk size
lsblk
blockdev --getsize64 /dev/vdb

# Need at least 200MB for installation
```

---

## Performance Benchmarks

### Expected Memory Usage

```
Base system:    25-35 MB
With all services: 40-60 MB
With web app: 100-200 MB
```

### Expected Boot Time

```
OVMF firmware:    ~1s
Limine bootloader: ~1s
Kernel boot:      ~1-2s
Initramfs:        ~1s
s6 services:      ~1-2s
─────────────────────────
Total:            ~5-7 seconds
```

### Expected Disk Usage

```
Image file:       256 MB
Root filesystem:  ~28 MB
State partition:  ~92 MB (in 256MB image)
After install:    Expands to full disk
```

---

## Test Checklist

### Minimal Test (30 seconds)

```bash
□ System boots to login prompt
□ Login works (root/root)
□ qos-test --quick passes
□ Memory < 60 MB
□ Networking works (ping 8.8.8.8)
□ SSH access works
```

### Standard Test (2 minutes)

```bash
□ All qos-test tests pass (90%+ pass rate)
□ Services running (getty, networking, dropbear, nftables, zram)
□ Capability system works
□ Cluster discovery works
□ Curl can reach external sites
```

### Full Test (5 minutes)

```bash
□ qos-test passes (95%+ pass rate)
□ qos-test-e2e passes (web server, DNS, capabilities)
□ Package install/use/remove works
□ Service restart works
□ Filesystem operations work
□ qos-install works
□ Installation verification passes
```

---

## Reporting Issues

If tests fail, collect this info:

```bash
# System info
uname -a
free -m
df -h
ip addr show

# Service status
s6-rc -a list
s6-svstat /run/service/*

# Logs
cat /var/log/*/current 2>/dev/null | tail -50

# Test output
qos-test --verbose 2>&1 | tail -100
qos-test-e2e --verbose 2>&1 | tail -100
```

---

**End of Testing Guide**
