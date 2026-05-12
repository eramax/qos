# QOS Distro - RAM Minimization Guide (<100MB Target)

This guide outlines the steps to reduce QOS RAM consumption from the current ~250MB (Live CD) to **<64MB** for headless server operations.

---

## 1. Eliminate `copytoram` (The Biggest Win)

In a typical Live environment, the entire root filesystem is copied into a `tmpfs` (RAM).

### Strategy: Direct SquashFS Mounting
Modify the `initramfs` logic to mount the SquashFS image directly from the boot media (ISO or Disk) instead of extracting it to RAM.
- **RAM Savings**: Equal to the size of your compressed rootfs (~80-120MB).
- **Cost**: Slightly slower first-load for binaries as they read from "disk" (ISO).

---

## 2. Surgical Kernel Configuration

The kernel itself can consume 50-100MB of RAM just for its internal structures and buffers.

### Recommended `x86_64.config` Changes:
```ini
# Core Optimization
CONFIG_CC_OPTIMIZE_FOR_SIZE=y
CONFIG_EXPERT=y
CONFIG_EMBEDDED=y

# Memory Management
CONFIG_SLUB_DEBUG=n
CONFIG_COMPACTION=y
CONFIG_KSM=n  # Disable Kernel Samepage Merging unless running many VMs

# Remove Bloat
CONFIG_SOUND=n
CONFIG_VIDEO_V4L2=n
CONFIG_USB=n (Keep only if physical keyboard/boot is needed)
CONFIG_WIRELESS=n
CONFIG_BLUETOOTH=n

# Filesystems (Keep only essentials)
CONFIG_EXT4_FS=y
CONFIG_SQUASHFS=y
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS=y
```

---

## 3. Replace `udev` with `mdev`

`udev` is a daemon that stays in memory. `mdev` is a script-based alternative that runs only when hardware changes.

### Action:
1. Replace `eudev` package with `mdev-conf`.
2. Update `s6` service to run `mdev -s` at boot and exit.

---

## 4. Boot Parameter Tuning

Add these to your `limine.conf` to reduce memory overhead:
- `slab_debug=-`: Disables expensive slab debugging.
- `page_alloc.shuffle=1`: Can improve cache locality.
- `initcall_debug=0`: Ensure verbose init logging is off.
- `log_buf_len=128K`: Reduce the kernel log buffer size from the default (often 512K or 1M).

---

## 5. ZRAM vs No-Swap

In extreme low RAM (<128MB), ZRAM is a double-edged sword.
- **Recommendation**: Use a small ZRAM (e.g., 32MB) with the `zstd` algorithm. This allows the system to compress rarely used memory pages instead of killing processes.

---

## 6. Audit Service Footprints

| Service | Target RAM | Optimization |
| :--- | :--- | :--- |
| `s6-svscan` | <1 MB | Native C implementation, very efficient. |
| `dropbear` | 2-4 MB | Lightweight SSH. |
| `networking` | <1 MB | Use `busybox udhcpc` only. |
| `ntpd` | 2 MB | Use `busybox ntpd` instead of `chrony`. |
| **Total** | **~10 MB** | |

---

## Summary of Targeted Reductions

| Layer | Before | After | Saving |
| :--- | :--- | :--- | :--- |
| Rootfs in RAM | 120 MB | 0 MB | 120 MB |
| Kernel Overhead | 80 MB | 30 MB | 50 MB |
| Daemon Bloat | 50 MB | 10 MB | 40 MB |
| **Total Usage** | **250 MB** | **~40 MB** | **210 MB** |

---

## 7. Universal Minimalism: Laptops & PCs

To support real hardware without bloating RAM, we use a **Modular Kernel** approach.

### The "Surgical" Core + On-Demand Modules
- **Built-in**: Only the bare essentials (NVMe, SATA, VirtIO, Ext4, SquashFS).
- **Modules**: Everything else (Wi-Fi, Bluetooth, GPU, USB) stays on the disk.

### Hardware Probing with `mdev`
Instead of a heavy daemon, we use a boot-time probe:
1. `mdev -s` scans the PCI/USB bus.
2. It triggers `modprobe` for only the hardware detected.
3. If you are on a VPS, Wi-Fi drivers are **never loaded** and **consume 0 bytes of RAM**.

### Firmware Management
Use a "Sparse Firmware" tree. Only include compressed firmware for the most common laptop chipsets (Intel, Realtek) to keep the image size small.

---
*Target: 64MB (Server) / 100MB (Laptop). Baseline: Achieved.*
