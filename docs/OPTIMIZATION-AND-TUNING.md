# QOS Distro - Optimization & Tuning Guide

This document covers performance, latency, and resource optimizations for the QOS distribution, inspired by modern Linux distro patterns and advanced kernel tuning.

---

## 1. Kernel Boot Parameters

These parameters can be added to `/boot/efi/limine.conf` to reduce latency and overhead.

### Low Latency & Performance
- `rcupdate.rcu_expedited=1`: Speeds up RCU (Read-Copy-Update) grace periods.
- `rcu_normal=0`: Ensures RCU always uses expedited mode.
- `page_alloc.shuffle=1`: Shuffles the page allocator's free lists to improve performance.
- `nowatchdog`: Disables the hardware watchdog (reduces interrupts and system load).

### Minimal/Silent Boot
- `quiet`: Suppresses most kernel messages.
- `loglevel=3`: Only show critical, alert, and error messages.
- `vt.global_cursor_default=0`: Hides the console cursor.
- `rd.udev.log_priority=3`: Silences udev during initramfs.

---

## 2. Resource Management

Given the <40MB RAM target, aggressive resource management is essential.

### OOM Handling (EarlyOOM)
Instead of waiting for the kernel's heavy OOM killer, use `earlyoom` to respond to low memory situations while the system is still responsive.

**Configuration:**
```bash
# /etc/default/earlyoom
EARLYOOM_ARGS="-m 5 -s 5 --prefer 'bun|caddy' --avoid 'sshd|s6-svscan'"
```
- `-m 5`: Kill if free memory < 5%.
- `-s 5`: Kill if free swap < 5%.
- `--prefer`: Prioritize killing resource-heavy apps.
- `--avoid`: Protect critical system services.

### ZRAM Optimization
QOS already uses ZRAM. Optimization includes:
- **Algorithm**: Use `zstd` (best compression) or `lz4` (fastest).
- **Scale**: Set to 50% or 100% of RAM depending on the workload.

---

## 3. Filesystem Performance

### Mount Options
Always use these in `/etc/fstab` for the `state` partition:
- `noatime`: Completely disables writing access times to files.
- `commit=60`: Increases the ext4 journal commit interval (reduces disk I/O at the cost of slight data loss risk on power failure).

### IO Schedulers
For virtualized environments (QEMU/VirtIO), use the `none` or `mq-deadline` scheduler.
```bash
echo none > /sys/block/vda/queue/scheduler
```

---

## 4. Init System Tuning (s6-rc)

s6-rc is already the fastest init system, but it can be further tuned:
- **Parallelism**: Ensure services without dependencies are started in parallel.
- **Minimal Dependencies**: Keep the dependency tree flat to allow maximum concurrency.

---

## 5. Security vs Performance

Some optimizations involve disabling security mitigations. **Not recommended for production**, but useful for benchmarks:
- `mitigations=off`: Disables CPU vulnerability mitigations (Spectre, Meltdown, etc.). Provides significant speedup on older Intel hardware.

---

## Summary Checklist

| Optimization | Method | Impact |
| :--- | :--- | :--- |
| Expedited RCU | Kernel Param | Reduced Latency |
| EarlyOOM | Package | System Stability |
| Noatime | Fstab | Reduced Disk I/O |
| Zstd ZRAM | Service | More Effective RAM |
| Quiet Boot | Kernel Param | Professional DX |

---
*Inspired by the Artix Optimization Guide and modern Linux performance research.*
