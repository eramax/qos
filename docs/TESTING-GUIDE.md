# QOS Testing & Verification Guide

**Version:** 2.0  
**Date:** 2026-04-12

---

## Quick Start

### 1. Build Everything

```bash
make clean && make full
make iso
```

### 2. Boot and Test

| Command | What It Boots | Use Case |
|---------|---------------|----------|
| `make qemu` | Raw disk image | Primary testing |
| `make boot` | Live ISO | Live CD testing |
| `make qwen2` | Installed disk | After qos-install |

---

## Complete Test Workflow

### Step 1: Build and Boot Raw Disk

```bash
# Build raw disk image (256MB with 128MB root)
make full

# Boot it
make qemu

# Login (serial console)
Username: root
Password: root
```

### Step 2: Verify System

```bash
# Check services
s6-rc -a list

# Check memory (should be <60MB)
free -m

# Check networking
ping -c 2 8.8.8.8

# Run tests
qos-test --quick
```

### Step 3: Test Installation

```bash
# Inside VM, install to second disk (1GB)
qos-install --auto /dev/vdb

# Verify installation
fdisk -l /dev/vdb

# Shutdown
poweroff
```

### Step 4: Boot Installed System

```bash
# Boot from installed disk
make qwen2

# Login and verify
ssh root@<ip>
df -h
```

### Step 5: Test Live ISO

```bash
# Build ISO
make iso

# Boot ISO
make boot

# Verify live CD behavior
# System runs from CD, /dev/vdb is empty 1GB disk
```

---

## Automated Testing

### Quick System Test (~30 seconds)

```bash
ssh root@<ip> qos-test --quick
```

### Full Test Suite (~2 minutes)

```bash
ssh root@<ip> qos-test --verbose
```

### E2E Integration Tests (~5-10 minutes)

```bash
ssh root@<ip> qos-e2e-full --verbose
```

**E2E tests include:**
- ✅ Network & DNS
- ✅ Capability system
- ✅ Users & groups
- ✅ Service management
- ✅ GCC build & C app
- ✅ Bun web server (if installed)
- ✅ k3s Kubernetes (if compatible)
- ✅ Filesystem operations
- ✅ Package management

---

## Expected Results

### System Info (After Boot)

```
Hostname:      qos
Kernel:        6.19.6
CPU Cores:     2-4
RAM:           983 MB total, ~50 MB used
IP Address:    10.0.3.x
Disk Layout:
  overlay      128M root (read-only + overlay)
  /dev/vda4    auto   /var
```

### Services (All Should Be Running)

```
✅ cluster
✅ dns
✅ dropbear
✅ getty
✅ networking
✅ nftables
✅ qemu-ga
✅ reverse-proxy
✅ webapp
✅ zram
```

### Test Pass Rate

| Test Suite | Expected Pass Rate |
|------------|-------------------|
| `qos-test --quick` | 95%+ |
| `qos-test --verbose` | 90%+ |
| `qos-e2e-full` | 80%+ |

**Expected skips (normal):**
- Bun tests (if bun not installed)
- k3s tests (if systemd not available)
- Reverse proxy tests (if caddy not installed)

---

## Troubleshooting

### Boot Issues

**Problem:** System doesn't boot  
**Fix:** Check serial output
```bash
make boot  # Shows serial output directly
```

**Problem:** No IP address  
**Fix:** Check networking service
```bash
ip addr show eth0
s6-svstat /run/service/networking
```

### Installation Issues

**Problem:** `qos-install` fails  
**Fix:** Check disk space and tools
```bash
# Inside VM
fdisk -l /dev/vdb
which fdisk mkfs.ext4 mkfs.vfat
```

**Problem:** Can't boot installed disk  
**Fix:** Verify installation
```bash
mount /dev/vdb2 /mnt
ls /mnt/sbin/init
cat /mnt/etc/fstab
```

### Test Failures

**Problem:** Tests fail with "Permission denied"  
**Fix:** Rebuild and reinstall scripts
```bash
# On host
make full

# Inside VM (or rebuild image)
# Scripts are updated in new image
```

**Problem:** "No space left on device"  
**Fix:** Root partition too small  
**Solution:** Current root is 128MB, should be enough. Check:
```bash
df -h /
du -sh /* | sort -rh | head -10
```

---

## Verification Checklist

### Build Verification

- [ ] `make full` completes successfully
- [ ] `make iso` creates ISO
- [ ] `dist/qos-x86_64.raw` exists (~256MB)
- [ ] `dist/qos-x86_64.iso` exists

### Boot Verification

- [ ] `make qemu` boots to login prompt
- [ ] `make boot` boots ISO
- [ ] `make qwen2` boots installed system

### Runtime Verification

- [ ] Login works (root/root)
- [ ] Memory <60MB
- [ ] Networking works (ping 8.8.8.8)
- [ ] All core services running
- [ ] `qos-test --quick` passes 90%+
- [ ] `qos-install --auto /dev/vdb` succeeds
- [ ] Installed system boots via `make qwen2`

---

**End of Testing Guide**
