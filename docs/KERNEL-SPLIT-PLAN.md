# Kernel Split Plan

**Status:** Design only. No `.config` changes have landed.
**Goal:** Shrink the built-in kernel image to the smallest set that lets
the system boot and reach userspace, then let `mdev-coldplug` (already
landed as an s6 service) probe and `modprobe` everything else from disk.

This pairs with `docs/FEATURE-REVIEW-AND-IDEAS.md` §2.3.

---

## 1. The "core" config

These symbols must be `=y` (built-in). Anything else should be `=m` or `n`.

| Reason            | Symbols (representative)                                |
| ----------------- | ------------------------------------------------------- |
| Init userspace    | `CONFIG_DEVTMPFS=y`, `CONFIG_TMPFS=y`, `CONFIG_PROC_FS=y`, `CONFIG_SYSFS=y` |
| Init binary       | `CONFIG_BINFMT_ELF=y`, `CONFIG_BINFMT_SCRIPT=y`         |
| Boot media (QEMU) | `CONFIG_VIRTIO_PCI=y`, `CONFIG_VIRTIO_BLK=y`, `CONFIG_SCSI_VIRTIO=y` |
| Boot media (HW)   | `CONFIG_ATA=y`, `CONFIG_SATA_AHCI=y`, `CONFIG_BLK_DEV_NVME=y` |
| Filesystems       | `CONFIG_EXT4_FS=y`, `CONFIG_SQUASHFS=y`, `CONFIG_OVERLAY_FS=y`, `CONFIG_ISO9660_FS=y` (live ISO), `CONFIG_VFAT_FS=y` (EFI) |
| Module loading    | `CONFIG_MODULES=y`, `CONFIG_MODULE_UNLOAD=y`            |
| Memory & swap     | `CONFIG_ZRAM=y`, `CONFIG_ZSMALLOC=y`, `CONFIG_TRANSPARENT_HUGEPAGE=y` (madvise default) |
| Security          | `CONFIG_DM_VERITY=y`, `CONFIG_DM_MOD=y`, `CONFIG_INTEGRITY=y` |
| Net (early)       | `CONFIG_INET=y`, `CONFIG_VIRTIO_NET=y` (others as `=m`) |

Everything not in this table — Wi-Fi, Bluetooth, sound, USB beyond HID,
GPU drivers, every non-virtio NIC, V4L2, every filesystem we don't use
to *boot* — should be `=m`.

## 2. How to generate the list (not hand-write it)

The review §2.3 says: don't hand-curate. Procedure:

1. Build the current kernel and boot it in QEMU under both the ISO and
   installed-disk paths.
2. Snapshot `lsmod` immediately after `mdev-coldplug` finishes (its
   `done_marker` is `/run/qos/mdev-coldplug.done`).
3. Snapshot the kernel's *resolved* required modules for the boot path
   by walking `/sys/devices/**/modalias` and using `modprobe -R` against
   the installed `modules.alias` to print the loaded chain.
4. Diff (1) ∪ (2) against the symbols currently `=y`. Symbols only used
   *after* userspace is up can flip to `=m`.

Add `scripts/qos-kernel-audit.sh` that does steps 2-4 and prints a
patch-like summary. Run it once per release; commit the result.

## 3. Sequencing

1. Land `qos-kernel-audit.sh` (host-side; calls into a running QEMU).
2. Generate the first audit report. Review it.
3. Split `config/kernel/x86_64.config` into `core.config` (`=y` only)
   and `modules.config` (`=m` set). Keep the existing config as the
   union until the split is proven.
4. Add a `BUILD_KERNEL_VARIANT={full,core+modules}` knob to
   `scripts/build-kernel.sh`. Default stays `full` until QEMU and metal
   tests pass on `core+modules`.
5. Once green for two releases, flip the default.

## 4. Risks

- **Boot-path drift.** A symbol that is needed only on metal but not in
  QEMU will pass CI and break real hardware. Mitigation: run the audit
  on at least one Intel laptop + one AMD desktop before flipping.
- **Initramfs grows.** Modules needed at boot must live in the
  initramfs or be `=y`. `mkinitfs.conf` will need a regeneration step.
- **modules.dep coherence.** Built-in modules must not appear in
  `modules.dep`. The audit script must verify this.

## 5. Not doing yet

- Splitting kernel signing keys per variant. (Pairs with dm-verity in
  `VERITY-KEY-CUSTODY.md`.)
- Per-profile kernel images (`server` vs `desktop` with different `=y`
  sets). Probably not worth it; one core + modules covers both.
