# QOS ISO / Install Flow — Design & Implementation Plan

## Problem Summary

| # | Problem | Root Cause |
|---|---------|------------|
| 1 | `qos-install --auto /dev/vdb` fails | Depends on `e2cp` (from `e2tools`), which is not packaged on Alpine |
| 2 | `make qemu` does not boot from ISO | Makefile boots the raw disk; ISO has no rootfs embedded |
| 3 | `make qemu2` requires a source raw image | Installed-disk boot unnecessarily passes the source image |
| 4 | ISO has no rootfs | `build-iso.sh` only bundles kernel + initramfs, no rootfs |
| 5 | Initramfs does not support live-CD mode | Init script always looks for `LABEL=qos-root-a`; fails with cdrom boot |
| 6 | FAT32 mount fails | Kernel missing `CONFIG_NLS_CODEPAGE_437` — VFAT can't mount without NLS |
| 7 | OVMF can't boot ISO | El Torito EFI entry pointed at raw PE binary; OVMF needs a FAT ESP image |

---

## Desired Flow

```
make full          # build everything (kernel, rootfs, initramfs, ISO)
make qemu          # boots the live ISO inside QEMU, extra disk = /dev/vda
  ↓ inside VM:
qos-install --auto /dev/vda   # installs QOS to the extra disk
poweroff
make qemu2         # boots the installed disk (no ISO, no source image)
```

---

## Architecture Decisions

### Live-CD delivery in QEMU

| Option | Pros | Cons |
|--------|------|------|
| `media=cdrom` (AHCI) | Standard cdrom | AHCI driver is a **module** (`=m`); not accessible from initramfs |
| `virtio-scsi scsi-cd` | Uses built-in `SCSI_VIRTIO` + `BLK_DEV_SR` drivers | Requires `virtio-scsi-pci` device + `scsi-cd` |
| ISO as virtio-blk (read-only) | Simple | OVMF won't see EFI on raw ISO9660 virtio-blk device |

**Decision**: use `-device virtio-scsi-pci` + `-device scsi-cd`. Both kernel drivers are already compiled **built-in** (`=y`). The CDROM appears as `/dev/sr0` in the guest.

### Rootfs delivery inside ISO

| Option | Pros | Cons |
|--------|------|------|
| `rootfs.squashfs` | Space-efficient | Requires `CONFIG_SQUASHFS` + loop device (both absent) |
| `rootfs.tar.gz` in ISO | Works with busybox tar | Requires `CONFIG_ISO9660_FS` in kernel; adds kernel rebuild |
| **Embed in initramfs** | No kernel changes needed; works now | Initramfs is ~22 MB (but boots fine) |

**Decision**: bake the rootfs into the live initramfs. The ISO build creates a separate `initramfs-live.img` containing busybox + init + `/rootfs/`. At boot the init script copies `/rootfs/` to a tmpfs and `switch_root`s into it. No iso9660 kernel support required.

### EFI boot approach

OVMF's El Torito EFI boot requires a FAT ESP image. The ISO embeds a 40 MB FAT image (`efi.img`) containing `BOOTX64.EFI`, `limine.conf`, `vmlinuz`, and `initramfs-live.img`. OVMF loads this as the EFI System Partition, Limine's `boot()` resolves to the FAT volume, and all paths work.

### Installer approach

| Old (broken) | New (correct) |
|---|---|
| `e2cp` (e2tools — not in Alpine) | `mount` target partitions, `tar`/`cp` files in |
| `mcopy` for EFI population | `mount -t vfat`, `cp` files in |
| Hardcoded `SOURCE_DEV=/dev/vda1` | Embedded boot payload at `/var/lib/qos/boot/` |

### Boot file delivery for installer

Boot files (BOOTX64.EFI, vmlinuz, initramfs.img, limine.conf for disk boot) are embedded in the rootfs at `/var/lib/qos/boot/` during ISO build. The installer copies from there to the target EFI partition — no need to mount the CDROM or find a source disk.

---

## Required Changes

### Kernel config (`config/kernel/x86_64.config`)

```diff
+CONFIG_ISO9660_FS=y
+CONFIG_JOLIET=y
+CONFIG_FAT_DEFAULT_CODEPAGE=437
+CONFIG_FAT_DEFAULT_IOCHARSET="utf8"
+CONFIG_NLS=y
+CONFIG_NLS_DEFAULT="utf8"
+CONFIG_NLS_CODEPAGE_437=y
+CONFIG_NLS_ASCII=y
+CONFIG_NLS_UTF8=y
```

> **Effect**: enables iso9660 and VFAT NLS codepage support. VFAT mounts fail without NLS.

---

### `scripts/build-iso.sh`

1. Build a **separate live initramfs** (`initramfs-live.img`) with rootfs baked in at `/rootfs/`
2. Live init script copies `/rootfs/` to tmpfs, no `set -e` to avoid panic on non-critical failures
3. Embed boot files for installer at `rootfs/var/lib/qos/boot/` (BOOTX64.EFI, vmlinuz, disk-boot initramfs.img, limine.conf)
4. Create a **FAT ESP image** (efi.img) with BOOTX64.EFI + limine.conf + vmlinuz + initramfs-live.img
5. ISO's limine.conf uses `boot():/vmlinuz` and `boot():/initramfs-live.img`

---

### `scripts/build-initramfs.sh` (unchanged)

The disk-boot initramfs stays exactly as before — it only knows how to find `LABEL=qos-root-a` and set up overlayfs. No live-CD logic needed.

---

### `scripts/qos-install.sh` (complete rewrite)

**No e2tools**. Algorithm:

```
1. Parse args, validate target block device
2. Check tools: sgdisk mkfs.ext4 mkfs.vfat mount umount tar blockdev
3. Unmount any existing partitions on target disk
4. Wipe first 4 MB of target (zero out old signatures)
5. sgdisk: create GPT with EFI(64 MB) + root(128 MB) + state(rest)
6. blockdev --rereadpt + sleep 1
7. mkfs.vfat -F32 -n QOS-EFI  <target>1
8. mkfs.ext4 -F -L qos-root-a <target>2
9. mkfs.ext4 -F -L qos-state  <target>3
10. Mount all three to /tmp/qos-install-PID/{root,efi,state}
11. Copy rootfs: prefer mounted source root-a partition; fallback: tar from running /
12. Write /etc/fstab for installed system (labels, correct mount opts)
13. Remove /var from root partition (state owns it)
14. Init state partition: mkdir overlay/{upper,work} var/{log,lib,cache,tmp}
15. Copy EFI files from /var/lib/qos/boot/ (embedded payload)
16. Write limine.conf for disk boot (root=LABEL=qos-root-a)
17. Sync; explicit unmount before reporting success
```

---

### `scripts/run-qemu.sh`

ISO boot uses virtio-scsi cdrom (built-in kernel drivers):

```bash
-device virtio-scsi-pci,id=scsi0
-drive if=none,file="${QEMU_ISO}",media=cdrom,id=iso0
-device scsi-cd,bus=scsi0.0,drive=iso0,bootindex=0
```

Extra disk stays as virtio-blk → `/dev/vda` in the live VM (installer target).

---

### `Makefile`

```makefile
qemu:   # boots live ISO (extra disk = install target)
qemu2:  # boots installed disk only (no ISO needed)
```

---

## Disk / Device Map in QEMU

### `make qemu` (live ISO boot)

| Device | What | Purpose |
|--------|------|---------|
| virtio-scsi cdrom | `dist/qos-x86_64.iso` | Boot device (OVMF → El Torito EFI → Limine) |
| `/dev/vda` | `build/qemu/extra-disk.raw` | Install target for `qos-install` |

### `make qemu2` (installed disk boot)

| Device | What | Purpose |
|--------|------|---------|
| `/dev/vda` | `build/qemu/extra-disk.raw` | Installed system; OVMF finds EFI on vda1 |

---

## Partition Layout (installed disk)

```
/dev/vda   ← target disk
  vda1   64 MB   FAT32  label=QOS-EFI    EFI/BOOT/BOOTX64.EFI + vmlinuz + initramfs.img + limine.conf
  vda2  128 MB   ext4   label=qos-root-a immutable rootfs (ro)
  vda3   rest    ext4   label=qos-state  overlay upper/work + /var
```

Initramfs on disk boot:
- mounts `qos-root-a` read-only → `/ro-root`
- mounts `qos-state` → `/state`
- overlayfs: lower=`/ro-root`, upper+work from `/state/overlay/`
- bind-mounts `/state/var` → `/sysroot/var`

---

## Build Order After Changes

```bash
# One-time full rebuild (adds NLS/iso9660 to kernel):
make full

# Day-to-day workflow:
make iso        # rebuild ISO only (if rootfs/scripts changed)
make qemu       # boot live ISO
  qos-install --auto /dev/vda
  poweroff
make qemu2      # boot installed system
```

---

## Files Changed

| File | Change |
|------|--------|
| `config/kernel/x86_64.config` | Add NLS codepage, iso9660, FAT default charset |
| `scripts/build-iso.sh` | Self-contained live initramfs + embedded boot payload + FAT ESP |
| `scripts/qos-install.sh` | Complete rewrite — mount-based, no e2tools, embedded boot payload |
| `scripts/run-qemu.sh` | Use virtio-scsi for cdrom in ISO boot mode |
| `Makefile` | `make qemu` → ISO boot; `make qemu2` → installed disk |
