# QOS Boot Options

## Current Boot Targets

| Command | What It Boots | Status |
|---------|---------------|--------|
| `make qemu` | Raw disk image (`dist/qos-x86_64.raw`) | ✅ Working |
| `make boot` | Live ISO (`dist/qos-x86_64.iso`) | ⚠️ In progress |
| `make qwen2` | Installed disk (second disk) | ✅ Working |

## Recommended Workflow

### 1. Build and Test Raw Disk (Working)

```bash
# Build everything
make full

# Boot raw disk image
make qemu

# Inside VM:
# - System boots from disk
# - /dev/vdb is 1GB empty disk
# - Can run: qos-install --auto /dev/vdb
```

### 2. Test Installed System (Working)

```bash
# After running qos-install in the VM
make qwen2

# Boots from installed disk
```

### 3. Live ISO (In Progress)

```bash
# Build ISO
make iso

# Boot ISO (needs live initramfs support)
make boot
```

**Note:** Live ISO boot requires special initramfs that uses tmpfs instead of disk partitions. Currently working on this feature.

## Why ISO Boot Needs Work

The current initramfs expects:
- Root partition with label `qos-root-a`
- State partition with label `qos-state`

For live ISO boot, we need:
- tmpfs-based root filesystem
- Copy from ISO or squashfs
- No disk partitions needed

## Workaround

Until live ISO boot is complete, use:

```bash
# For testing: boot raw disk
make qemu

# For installation testing:
# 1. make qemu
# 2. qos-install --auto /dev/vdb
# 3. make qwen2
```

---

**Status:** Raw disk and installed disk boot working. Live ISO in development.
