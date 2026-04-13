# QOS ISO / Install Flow — Design & Implementation Plan

## Problem Summary

| # | Problem | Root Cause |
|---|---------|------------|
| 1 | `qos-install --auto /dev/vdb` fails | Depends on `e2cp` (from `e2tools`), which is not packaged on Alpine |
| 2 | `make qemu` does not boot from ISO | Makefile boots the raw disk; ISO has no rootfs embedded |
| 3 | `make qemu2` requires a source raw image | Installed-disk boot unnecessarily passes the source image |
| 4 | ISO has no rootfs | `build-iso.sh` only bundles kernel + initramfs, no rootfs tarball |
| 5 | Initramfs does not support live-CD mode | Init script always looks for `LABEL=qos-root-a`; fails with cdrom boot |

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

---

## Required Changes

### Kernel config (`config/kernel/x86_64.config`)

```diff
+CONFIG_ISO9660_FS=y
+CONFIG_JOLIET=y
```

> **Effect**: enables mounting of ISO 9660 CDROM filesystems inside the VM.  
> **Rebuild**: only `make kernel initramfs boot-limine iso` (not rootfs).

---

### `scripts/build-iso.sh`

1. After assembling the ISO root tree, add:
   ```bash
   tar -C "$rootfs" -czf "$iso_root/rootfs.tar.gz" .
   ```
2. Fix the xorriso call to produce a proper El Torito **EFI** boot:
   - Create a small FAT `efi.img` containing `EFI/BOOT/BOOTX64.EFI` + `limine.conf` + `vmlinuz` + `initramfs.img`
   - Pass `--efi-boot efi.img -efi-boot-part --efi-boot-image -no-emul-boot` to xorriso
3. The ISO limine.conf **adds** `livecd` to the kernel cmdline so the initramfs enters live mode:
   ```
   cmdline: livecd console=ttyS0,115200n8 loglevel=7 net.ifnames=0 biosdevname=0
   ```

---

### `scripts/build-initramfs.sh` (generated init script)

Add a live-CD code path before the existing disk-boot path:

```sh
livecd=0
for _arg in $(cat /proc/cmdline); do
  case "$_arg" in livecd) livecd=1 ;; esac
done

if [ "$livecd" = "1" ]; then
  # Mount cdrom, extract rootfs.tar.gz to tmpfs, switch_root
  ...
else
  # Existing disk-boot path (findfs LABEL=qos-root-a …)
  ...
fi
```

---

### `scripts/qos-install.sh` (full rewrite)

**No e2tools**. Algorithm:

```
1. Parse args, validate target block device
2. Check tools: sgdisk mkfs.ext4 mkfs.vfat mount umount tar blockdev
3. Show disk info + confirmation (auto mode skips)
4. Wipe first 4 MB of target (zero out old signatures)
5. sgdisk: create GPT with EFI(64 MB) + root(128 MB) + state(rest)
6. blockdev --rereadpt + sleep 1
7. mkfs.vfat -F32 -n QOS-EFI  <target>1
8. mkfs.ext4 -F -L qos-root-a <target>2
9. mkfs.ext4 -F -L qos-state  <target>3
10. Mount all three to /tmp/qos-install-PID/{root,efi,state}
11. Find source rootfs:
    a. findfs LABEL=qos-root-a → mount ro → tar copy → umount  [preferred]
    b. Fallback: tar from running / (excludes proc,sys,dev,run,tmp,cdrom,mnt)
12. Write /etc/fstab for installed system (labels, correct mount opts)
13. Remove /var from root partition (state owns it)
14. Copy EFI files:
    a. Auto-detect source EFI partition (parent of qos-root-a, part 1)
    b. mount ro → cp BOOTX64.EFI + vmlinuz + initramfs.img → umount
    c. Fallback: copy from /cdrom/EFI if live-CD mount is present
15. Write limine.conf for disk boot (NO livecd flag; root=LABEL=qos-root-a)
16. Init state partition: mkdir overlay/{upper,work} var/{log,lib,cache,tmp}
17. Sync; umount all; report success
```

---

### `scripts/run-qemu.sh`

Replace the ISO boot block:

```bash
# Before (IDE cdrom — AHCI driver is a module, doesn't work in initramfs)
-drive file="${QEMU_ISO}",media=cdrom

# After (virtio-scsi cdrom — built-in drivers, appears as /dev/sr0)
-device virtio-scsi-pci,id=scsi0
-drive if=none,file="${QEMU_ISO}",media=cdrom,id=iso0
-device scsi-cd,bus=scsi0.0,drive=iso0,bootindex=0
```

Extra disk stays as virtio-blk → `/dev/vda` in the live VM (installer target).

---

### `Makefile`

```makefile
# make qemu  →  boot live ISO (requires: make iso first)
qemu:
    @scripts/boot-image.sh --qemu-iso $(ROOT)/dist/qos-x86_64.iso

# make qemu2  →  boot installed disk only (no source image needed)
qemu2:
    @QEMU_BOOT_DISK=installed ... scripts/boot-image.sh --qemu $(QEMU_IMAGE)
```

---

## Disk / Device Map in QEMU

### `make qemu` (live ISO boot)

| Device | What | Purpose |
|--------|------|---------|
| virtio-scsi cdrom | `dist/qos-x86_64.iso` | Boot device (OVMF → El Torito EFI → Limine) |
| `/dev/sr0` | ISO inside VM | Initramfs mounts; extracts `rootfs.tar.gz` |
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
# One-time full rebuild (adds ISO9660 to kernel):
make full

# Day-to-day workflow:
make boot-limine iso   # only if kernel/initramfs/rootfs changed
make qemu              # boot live ISO
  # inside VM:
  qos-install --auto /dev/vda
  poweroff
make qemu2             # boot installed system
```

---

## Files Changed

| File | Change |
|------|--------|
| `config/kernel/x86_64.config` | Add `CONFIG_ISO9660_FS=y`, `CONFIG_JOLIET=y` |
| `scripts/build-iso.sh` | Include `rootfs.tar.gz`; fix El Torito EFI ISO structure |
| `scripts/build-initramfs.sh` | Add live-CD init path (livecd cmdline param) |
| `scripts/qos-install.sh` | Complete rewrite — mount-based, no e2tools |
| `scripts/run-qemu.sh` | Use virtio-scsi for cdrom in ISO boot mode |
| `Makefile` | `make qemu` → ISO boot; `make qemu2` → installed disk |
