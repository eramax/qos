# QOS Installation Guide

**Version:** 2.0  
**Image Size:** ~100MB  
**Target Disk:** 1GB+ recommended

---

## Overview

QOS now ships as a compact ~100MB image that can be expanded to use larger disks via `qos-install`.

### Image Layout (100MB Base)

| Partition | Size | Purpose |
|-----------|------|---------|
| EFI | 64MB | Bootloader + kernel + initramfs |
| root-a | 32MB | Immutable root filesystem (slot A) |
| root-b | 32MB | Immutable root filesystem (slot B) |
| state | ~4MB+ | Writable state (auto-sized from remaining) |

### After Installation (1GB+ Disk)

| Partition | Size | Purpose |
|-----------|------|---------|
| EFI | 64MB | Bootloader + kernel + initramfs |
| Root | 32MB | Immutable root filesystem |
| Var | ~900MB+ | Writable state, logs, apps, data |

---

## Installation Methods

### Method 1: Direct Flash (Quick)

Flash the 100MB image directly to any disk:

```bash
sudo dd if=dist/qos-x86_64.raw of=/dev/sdX bs=4M status=progress
```

**Pros:**
- Fast and simple
- Works immediately
- State partition auto-expands

**Cons:**
- Partition layout remains small
- No proper separation of boot/root/var

### Method 2: qos-install (Recommended)

Boot from the 100MB image, then install to a larger disk:

```bash
# 1. Boot from 100MB image
make qemu

# 2. Inside VM, install to second disk
ssh root@<ip>
qos-install --auto /dev/vdb

# 3. Shutdown
poweroff

# 4. Boot from installed disk
# (Change QEMU to boot from /dev/vdb)
```

**Pros:**
- Clean partition layout
- Proper boot/root/var separation
- Optimized for target disk size
- Persistent installation

**Cons:**
- Requires two-step process
- Needs larger target disk

---

## Testing with QEMU

### Default QEMU Setup

QEMU now boots with:
- **Primary disk:** 100MB QOS image
- **Secondary disk:** 1GB empty disk (for installation testing)

```bash
# Boot with default setup
make qemu

# Inside VM, you'll see two disks:
lsblk
# vda 100M (QOS image, booted from)
# vdb 1G  (empty, ready for installation)
```

### Installation Workflow

```bash
# 1. SSH into running VM
ssh root@<ip>
# Password: root

# 2. Check current disk layout
lsblk
df -h

# 3. Install to second disk
qos-install --auto /dev/vdb

# 4. Verify installation
# (Check output for partition details)

# 5. Shutdown
poweroff
```

### Booting from Installed Disk

To test the installed system, modify QEMU to boot from the second disk:

```bash
# Change boot order in QEMU (or swap disks)
QEMU_BOOT_DISK=1 make qemu
```

---

## qos-install Usage

### Interactive Mode

```bash
qos-install /dev/vdb

# Output:
[INSTALL] ═══════════════════════════════════════════════
[INSTALL] QOS Disk Installation
[INSTALL] ═══════════════════════════════════════════════
[INSTALL] Target device: /dev/vdb
[INSTALL] Auto mode: 0
[INSTALL] Disk size: 1024MB
[INSTALL] Partition plan:
[INSTALL]   EFI: 64MB
[INSTALL]   Root: 32MB
[INSTALL]   Var: 924MB (remaining space)
[INSTALL] 
WARNING: This will erase all data on /dev/vdb
Continue? [y/N] y
[INSTALL] Starting installation...
[INSTALL] Creating GPT partition table...
[INSTALL] Creating partitions...
[INSTALL] Partition table created successfully
[INSTALL] Formatting EFI partition (FAT32)...
[INSTALL] Formatting root partition (ext4)...
[INSTALL] Formatting var partition (ext4)...
[INSTALL] All partitions formatted
[INSTALL] Mounting partitions...
[INSTALL] Copying root filesystem...
[INSTALL] Root filesystem copied
[INSTALL] Setting up var partition...
[INSTALL] Var partition setup complete
[INSTALL] Setting up EFI partition...
[INSTALL] EFI partition setup complete
[INSTALL] Updating fstab...
[INSTALL] fstab updated
[INSTALL] Installation marker created
[INSTALL] Unmounting partitions...
[INSTALL] ═══════════════════════════════════════════════
[INSTALL] ✅ Installation Complete!
[INSTALL] ═══════════════════════════════════════════════
[INSTALL] 
[INSTALL] Disk layout:
[INSTALL]   /dev/vdb1  EFI (64MB)  - Bootloader
[INSTALL]   /dev/vdb2  Root (32MB) - System
[INSTALL]   /dev/vdb3  Var (924MB)   - Data
[INSTALL] 
[INSTALL] Next steps:
[INSTALL]   1. Shutdown: poweroff
[INSTALL]   2. Boot from installed disk
[INSTALL]   3. System will use new partition layout
```

### Non-Interactive Mode

```bash
qos-install --auto /dev/vdb
```

### Help

```bash
qos-install --help

Usage: qos-install [--auto] <device>

Install QOS to disk with proper partition layout.

Options:
  --auto    Non-interactive mode (no prompts)
  <device>  Target disk device (e.g., /dev/sda, /dev/vda)

Examples:
  qos-install /dev/sda
  qos-install --auto /dev/vda
```

---

## What qos-install Does

1. **Detects target disk** and size
2. **Creates GPT partition table** with 3 partitions:
   - EFI (64MB, FAT32)
   - Root (32MB, ext4)
   - Var (remaining space, ext4)
3. **Formats partitions** with appropriate filesystems
4. **Copies root filesystem** from running system
5. **Sets up var partition** with overlay directories
6. **Configures EFI partition** with boot files
7. **Updates fstab** for new partition labels
8. **Creates installation marker** with metadata

---

## Troubleshooting

### Installation Fails

**Problem:** "Disk too small"
```bash
# Check disk size
lsblk
blockdev --getsize64 /dev/vdb

# Need at least 200MB for installation
```

**Problem:** "Not a block device"
```bash
# Verify device exists
ls -l /dev/vd*
lsblk
```

**Problem:** "Failed to format partition"
```bash
# Check if device is busy
mount | grep /dev/vdb
fuser -vm /dev/vdb

# Unmount if needed
umount /dev/vdb*
```

### Post-Installation Issues

**Problem:** Won't boot from installed disk
```bash
# Check EFI partition
mount /dev/vdb1 /mnt
ls -la /mnt/EFI/BOOT/
# Should contain BOOTX64.EFI

# Check boot order in QEMU/BIOS
```

**Problem:** Root filesystem not mounting
```bash
# Check partition labels
blkid /dev/vdb2
# Should show LABEL="QOS-Root"

# Check fstab
cat /etc/fstab
```

---

## Real Hardware Installation

### USB Installation

```bash
# Flash to USB
sudo dd if=dist/qos-x86_64.raw of=/dev/sdX bs=4M status=progress

# Or install properly
# 1. Boot from USB
# 2. Install to internal disk
qos-install --auto /dev/sda
```

### NVMe/SSD Installation

```bash
# Install to NVMe
qos-install --auto /dev/nvme0n1

# Install to SSD
qos-install --auto /dev/sda
```

---

## Testing the Installation

### After Installation

```bash
# Boot from installed disk
# Then run comprehensive tests
qos-test

# Or quick test
qos-test --quick

# Verbose test
qos-test --verbose
```

### Verify Partition Layout

```bash
lsblk
# Should show:
# vda (or sda)  1G
# ├─vda1  64M   EFI
# ├─vda2  32M   Root
# └─vda3  ~900M Var

df -h
# Should show:
# overlay  32M   (root, read-only with overlay)
# /dev/vda3  900M  /var
```

---

## Comparison: Before vs After

### Before (1GB Image)
- ❌ Large download (1GB)
- ❌ Fixed partition sizes
- ❌ Wasted space on small disks
- ❌ No installation tool

### After (100MB Image + qos-install)
- ✅ Small download (100MB)
- ✅ Expands to any disk size
- ✅ Proper partition layout
- ✅ Installation tool included
- ✅ Metadata tracking
- ✅ Clean separation of boot/root/var

---

**End of Installation Guide**
