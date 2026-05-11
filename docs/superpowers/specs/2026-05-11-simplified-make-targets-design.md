# Simplified Make Targets Design

**Date:** 2026-05-11

## Goal

Reduce the repo's public `make` interface to the small set of targets actually needed for the QOS workflow:

- `make full`
- `make kernel`
- `make live`
- `make qemu`
- `make clean`

The main build artifact becomes the live ISO. The raw image is no longer part of the default workflow.

## Desired Workflow

### Primary build

```bash
make full
```

This should:

- rebuild rootfs
- reinstall services into rootfs
- rebuild initramfs
- rebuild Limine boot staging
- build `dist/qos-x86_64.iso`
- reuse the existing kernel build if valid kernel artifacts already exist

### Explicit kernel rebuild

```bash
make kernel
```

This should force a kernel rebuild when kernel config or kernel version changed.

### Boot live ISO

```bash
make live
```

This is the renamed form of the current live-ISO boot target.

### Boot installed disk

```bash
make qemu
```

This is the renamed form of the current installed-disk boot target.

## Problems With Current Layout

- `make full` currently ends with raw image output, not ISO output
- `make qemu` currently means live ISO boot, while `make qemu2` means installed-disk boot
- there are too many user-facing targets for the core workflow
- the current naming makes it easy to build one artifact and accidentally boot another

## Chosen Approach

Keep a minimal public surface and align target names with actual usage:

- `full` means “build the thing I boot most often”
- `live` means “boot the installer/live ISO”
- `qemu` means “boot the installed system”
- `kernel` is the explicit maintenance path for kernel changes

## Build Contract

### `make full`

`make full` must:

1. rebuild `build/rootfs`
2. reinstall staged services
3. reuse existing kernel artifacts if present
4. rebuild initramfs
5. rebuild Limine staging
6. build `dist/qos-x86_64.iso`

It must not require raw image generation.

### Kernel reuse rule

If the kernel build artifacts already exist, `make full` should not rebuild the kernel.

If they do not exist, `make full` should build them automatically so the build still succeeds from a clean tree.

### `make kernel`

`make kernel` remains the explicit forced kernel rebuild path.

It should refresh the kernel output directory and leave downstream stages to `make full` or `make live`/`make qemu` as appropriate.

## Boot Target Contract

### `make live`

Renamed from the current `make qemu`.

Behavior:

- verify `dist/qos-x86_64.iso` exists
- boot the live ISO in QEMU
- preserve the current host-network prerequisite behavior

### `make qemu`

Renamed from the current `make qemu2`.

Behavior:

- boot from the installed disk image (`build/qemu/extra-disk.raw`)
- assume installation was already performed from the live ISO

## Target Surface

### User-facing targets to keep

- `full`
- `kernel`
- `live`
- `qemu`
- `clean`

### Targets to remove or de-emphasize from normal workflow

- `image`
- `boot`
- `qemu2`
- `smoke`
- `ssh-test`
- intermediate build stages as primary documented entrypoints

Internal script reuse is fine, but the top-level workflow should stay minimal.

## Implementation Scope

### Files to modify

- `Makefile`
- `build.sh`
- `README.md`
- any docs/tests that pin current target names or output expectations

### Likely test updates

- `tests/test_qemu_boot.sh`
- `tests/test_build_contract.sh`
- other tests that assume `full` produces `dist/qos-x86_64.raw`

## Non-Goals

- introducing a sophisticated incremental dependency system
- preserving raw-image-first workflow as the default
- keeping both old and new boot target names indefinitely

## Success Criteria

- `make full` produces a bootable ISO
- `make full` skips kernel rebuild if kernel artifacts already exist
- `make live` boots the ISO
- `make qemu` boots the installed disk
- the documented workflow is smaller and less confusing than before
