# qos

Minimal Alpine-style x86_64 server distro optimized for <64MB image size and <40MB RAM usage.

## Features

- **UEFI-only boot** via Limine bootloader
- **Immutable rootfs** with overlayfs for writable layer
- **s6 / s6-rc** process supervision
- **Alpine apk** package management
- **Dropbear** for SSH access
- **nftables** as host firewall
- **Image-based A/B OTA** updates with rollback
- **Capability-based access control** for fine-grained service isolation
- **Reverse proxy + DNS** for domain hosting
- **Cluster discovery** for distributed resource awareness
- **Dynamic state partition** that expands to full disk size
- **Optimized for 64MB image** (down from 1GB)
- **Multicore scheduler** with NUMA, SMT, and cluster support
- **Microkernel-like design** with hardware drivers as loadable modules

## Quick Start

### Build

```bash
# Clean build from scratch
make full

# Or step-by-step
make rootfs      # Build rootfs
make services    # Install services
make kernel      # Build kernel
make initramfs   # Build initramfs
make boot-limine # Stage bootloader
make image       # Assemble 64MB image
```

### Boot

```bash
# Boot in QEMU (default: 1GB RAM, 2 CPU, bridged networking)
make qemu

# Boot with serial output to terminal
make boot

# Smoke boot with log capture
make smoke

# Boot, SSH in, and test
make ssh-test
```

### Flash to Disk

```bash
# Flash 64MB image to disk
sudo dd if=dist/qos-x86_64.raw of=/dev/sdX bs=4M status=progress

# Expand state partition to use full disk
sudo ./scripts/qos-expand.sh /dev/sdX
```

## Documentation

- **[REFACTORING-AND-VERIFICATION.md](docs/REFACTORING-AND-VERIFICATION.md)** - Complete refactoring report with verification steps
- **[IMPLEMENTATION-GUIDE.md](docs/IMPLEMENTATION-GUIDE.md)** - Step-by-step implementation guide
- **[ANALYSIS-AND-REVIEW.md](docs/ANALYSIS-AND-REVIEW.md)** - Comprehensive analysis and recommendations
- **[QUICK-REFERENCE.md](docs/QUICK-REFERENCE.md)** - Quick reference card for common commands

## Current Status

- ✅ Image build pipeline works end-to-end
- ✅ Disk image assembled into `dist/qos-x86_64.raw` (64MB)
- ✅ Guest boots through OVMF, Limine, kernel, initramfs, and s6-linux-init
- ✅ Rootfs staging, Limine staging, initramfs generation, and image assembly scripted
- ✅ Makefile available for short commands
- ✅ QEMU defaults to bridged networking through repo-managed TAP helper
- ✅ Build commands and source URLs recorded in `build/build.manifest`
- ✅ Capability system implemented with example profiles
- ✅ Reverse proxy service configured (Caddy)
- ✅ Cluster discovery service implemented
- ✅ NTP time synchronization added (chrony)
- ✅ WebApp example with Bun integration

## Remaining Work

- Verify DHCP comes up reliably on the guest interface
- Verify `apk update` works from inside the VM
- Install and test bun with reverse proxy
- Test capability system enforcement with real services
- Test cluster discovery with multiple nodes
- Test on real hardware with module loading
- Add desktop support (DRM/KMS, Wayland)
- Research Android app support (Waydroid)

## Architecture

### System Stack

1. Firmware boots into `Limine`
2. `Limine` loads the Linux kernel and initramfs
3. Kernel mounts root filesystem with overlayfs
4. `s6` becomes PID 1
5. `s6-rc` brings up system services in dependency order
6. `Dropbear` provides remote administration
7. Application services run as supervised `s6` services

### Image Layout (64MB)

| Partition | Size | Purpose |
|-----------|------|---------|
| EFI | 32 MB | Bootloader, kernel, initramfs |
| root-a | 16 MB | Immutable root slot A |
| root-b | 16 MB | Immutable root slot B |
| state | auto | Writable state (auto-expands to full disk) |

### Services

| Service | Purpose | Status |
|---------|---------|--------|
| getty | Serial console login | ✅ Active |
| networking | DHCP client | ✅ Active |
| dropbear | SSH server | ✅ Active |
| nftables | Host firewall | ✅ Active |
| zram | Compressed swap | ✅ Active |
| cluster | Node discovery | ✅ Active |
| ntpd | Time sync (chrony) | ✅ Active |
| reverse-proxy | Domain hosting (Caddy) | Optional |
| dns | Local DNS (dnsmasq) | Optional |
| webapp | Bun webapp example | Optional |

### Capability Profiles

| Profile | Purpose | Resource Limits |
|---------|---------|-----------------|
| reverse-proxy | Web proxy | 50% CPU, 256MB RAM, network access |
| webapp | Bun/Node.js app | 75% CPU, 512MB RAM, limited network |
| database | Database server | 200% CPU, 1GB RAM, I/O limits, no network |

## Useful Commands

### Build

```bash
# Verbose build with logs
make build-log

# Tail build log
sed -n '1,200p' build/logs/build.log

# Filter build log
make build-grep
```

### Boot

```bash
# Boot with live serial output
make boot

# Pack current payload into raw image
make image

# Boot, SSH in, install btop, run it
make ssh-test
```

### Runtime

```bash
# SSH into the system
ssh root@<qos-ip>
# Password: root

# Check services
s6-rc -a list
s6-svstat /run/service/*

# Apply capability profile
qos-capability apply webapp webapp.cap

# Check cluster status
qos-cluster nodes
qos-cluster resources

# Test reverse proxy
curl http://localhost:80

# Monitor resources
htop
df -h
free -m
```

## Build Prerequisites

Host build requirements (Debian/Ubuntu):

```bash
sudo apt install git curl ca-certificates bash python3 jq mkosi \
  qemu-system-x86 qemu-utils squashfs-tools xorriso mtools dosfstools \
  e2fsprogs parted util-linux libarchive-tools ovmf \
  build-essential bc perl help2man indent
```

## Design Philosophy

- **Minimal**: Only essential packages included
- **Immutable**: Root filesystem is read-only
- **Reproducible**: Build from one script, same result every time
- **Secure**: Capability-based access control, minimal attack surface
- **Scalable**: Cluster discovery for distributed deployments
- **Flexible**: Dynamic state partition adapts to any disk size
- **Future-proof**: Path to desktop and Android support

## License

See LICENSE file for details.
