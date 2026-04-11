# Minimal UEFI Linux Distro Design

## Summary

This document defines a small, fast, reproducible Linux distribution for QEMU x86_64 first, with a path to real hardware later. The distro is Alpine-based, uses `apk` directly, and is optimized for a minimal server footprint rather than desktop use.

Core decisions:

- UEFI only boot
- `Limine` bootloader
- `ext4` root filesystem
- immutable rootfs
- writable state isolated under `/var`
- `s6` and `s6-rc` for init and supervision
- `apk-tools` and Alpine packages directly
- `musl` userspace
- `Dropbear` for SSH access
- `ash` as the base shell
- rolling release model
- one top-level script builds the image

## Goals

- Boot reliably in QEMU x86_64 with UEFI.
- Keep the base system small and easy to audit.
- Use Alpine packages directly instead of inventing a separate package ecosystem.
- Keep the runtime immutable so updates are controlled, rollback-friendly, and easy to replace as whole images.
- Make the whole image reproducible from one top-level build script.
- Keep the system suitable for future real hardware support without overfitting to QEMU.

## Non-Goals

- No Kubernetes or K3s.
- No WASM runtime in the base system.
- No Docker or Podman-based app model.
- No desktop environment.
- No Rust/Zig language preference in the base spec.

## System Architecture

The runtime stack is:

1. Firmware boots into `Limine`.
2. `Limine` loads the Linux kernel and initramfs.
3. The kernel mounts the root filesystem.
4. `s6` becomes PID 1.
5. `s6-rc` brings up system services in dependency order.
6. `Dropbear` provides remote administration.
7. Application services run as supervised `s6` services.

The distro is intentionally small. Most system behavior should be visible through:

- service directories
- package manifests
- kernel config
- the build script

## Boot Strategy

### Boot Mode

- UEFI only.
- BIOS support is not a requirement for the first release.

### Bootloader

`Limine` is the bootloader of record because it is modern, lightweight, and independent of systemd.

### Kernel

The kernel should be stripped but not over-stripped. It should keep the features required for:

- UEFI boot
- `ext4`
- `tmpfs`
- `proc`, `sysfs`, `devtmpfs`
- `cgroups`
- namespaces
- networking
- virtio drivers for QEMU
- future real hardware support
- IPv4 and IPv6
- `io_uring`
- `futex` and shared-memory primitives
- Unix domain sockets
- `eventfd`
- `memfd_create`

The first kernel target is QEMU, but the config should avoid QEMU-only assumptions when possible.

### Kernel Config Summary

The kernel config should keep these feature groups enabled:

- UEFI and EFI stub boot support
- `ext4` and the basic VFS layer
- `tmpfs`, `proc`, `sysfs`, `devtmpfs`, and `cgroupfs`
- cgroups v2 and the resource controllers needed for service limits
- namespaces for process and mount isolation
- `io_uring`
- futex support
- shared memory and anonymous memory primitives
- Unix domain sockets
- `eventfd` and `epoll`
- `memfd_create`
- virtio block, network, and console drivers for QEMU
- PCI and basic virtual device support
- networking stack, TCP/IP, and DHCP-capable NIC support
- IPv6 support
- nftables or iptables support for host firewalling
- loopback and tunnel basics required by local services
- compression and crypto only as needed by the chosen filesystem and boot path

The config should explicitly disable debugging, tracing, and other development-only features unless they are needed for bring-up.

## Filesystem Layout

### Root Filesystem

- `/` is `ext4`.
- The root filesystem is immutable.
- Runtime state lives outside the base root image.

### Writable State

Persistent mutable data goes under `/var`, including:

- logs
- service state
- SSH host keys if not provisioned at build time
- DHCP lease state if needed
- package state or caches if the design requires them

`/etc` should remain part of the immutable image. Machine-specific mutable state should not be stored there.

### Log Policy

- Logs should be persistent in `/var/log`.
- Logging should be simple and service-scoped.
- The base image should not depend on a heavy logging stack.

### Shell and Base Utilities

- `/bin/sh` should be `ash`.
- `bash` should not be part of the default image.
- `uutils/coreutils` should replace GNU coreutils where practical.

## Package and Rootfs Strategy

### Package Source

The distro uses Alpine packages directly.

### Build Input

The build script should consume:

- Alpine repository configuration
- a package manifest
- a kernel config
- a Limine config
- an initramfs config
- a rootfs layout definition

### Reproducibility

The build must be reproducible from one top-level script. To keep that feasible while still using Alpine packages directly, the build should:

- pin package versions or repository snapshots
- record package names and versions in a manifest
- avoid pulling untracked dependencies during the build
- fail closed if repository metadata changes unexpectedly

The script should build the image only. It should not publish repositories or manage package mirrors.

## Init and Service Model

### Init System

`s6` and `s6-rc` are the process supervision and service orchestration layer.

### Service Principles

- Each service should have a single responsibility.
- Services should restart predictably on failure.
- Dependencies should be explicit.
- Service configuration should be stored in files, not hidden in ad hoc shell scripts.

### Service Types

The initial service set should include:

- basic system bootstrap
- networking
- SSH
- logging
- time synchronization if needed
- application services

### Shell Policy for Services

- Service scripts should be POSIX-compatible.
- `ash` should be used as the default shell for shell-based helpers.

## Administration

### SSH

`Dropbear` is the SSH daemon.

Rationale:

- smaller than OpenSSH
- suitable for a minimal server image
- enough for key-based administrative access

### Access Policy

The default stance should be conservative:

- key-based authentication preferred
- password login disabled unless explicitly required
- no unnecessary remote login surface

## Networking

### Addressing

- DHCP should be the default network mode.
- Static addressing can be supported later as a configuration option, not the default.

### Firewall and Exposure

The distro should stay simple at the base layer:

- local firewall rules control inbound access
- reverse proxying is used for HTTP exposure where needed
- service ports should not be opened casually

The first release does not need a heavy service mesh or Kubernetes-style networking stack.

## Applications

### App Model

Applications are ordinary native Linux services managed by `s6`.

### Performance Primitives

Applications should be able to use the kernel's fast I/O and IPC primitives directly.

Required primitives include:

- `io_uring` for asynchronous file and socket I/O
- `futex` for synchronization
- shared memory for high-throughput local IPC
- Unix domain sockets for local service communication
- `eventfd` for lightweight wakeups
- `memfd_create` for in-memory file-backed handoff

The distro should not treat `io_uring` as an IPC replacement. It is an async I/O path, while IPC should use the kernel primitives best suited to the communication pattern.

### HTTP Server Baseline

The first image should be capable of running a small HTTP server cleanly without extra platform dependencies.

Required runtime support includes:

- network stack support for TCP/IP
- IPv4 and IPv6 support
- loopback networking
- virtio network support in QEMU
- async I/O support through `io_uring`
- Unix domain sockets for local supervisor-to-app communication if needed
- writable state under `/var` for logs, cache, and app data
- stable environment variable injection per service
- service user separation for the HTTP server process

The environment for the HTTP server should be defined explicitly in the service configuration. That includes:

- listening address and port
- document root or application root
- log destination
- runtime configuration path
- any secrets required by the service
- limits for CPU, memory, and file descriptors where applicable

The kernel config must support the HTTP server without requiring extra optional subsystems beyond the base networking and async I/O set already required by this spec.

### Installation Layout

Applications should be installed into the immutable root image at build time, not into writable runtime state.

Standard locations:

- binaries: `/usr/bin` or `/usr/sbin`
- libraries: `/usr/lib`
- static data: `/usr/share`
- service definitions: the `s6` service tree or `/etc` as appropriate for the service
- mutable app state: `/var/lib/<app>`
- logs: `/var/log/<app>`
- runtime sockets and pid files: `/run/<app>`

This keeps the image reproducible while making app-specific state easy to isolate.

### App Language Policy

There is no enforced Rust or Zig-only policy in the current spec.

The distro should stay language-neutral at the base level while still favoring:

- small binaries
- low startup overhead
- reproducible builds
- minimal runtime dependencies

### App Isolation

The system should isolate apps by:

- dedicated service users
- explicit file permissions
- service-specific environment files
- service-specific state directories under `/var`

## Image Build Pipeline

The image build pipeline should be implemented as one top-level script with a predictable sequence:

1. Validate inputs and tool availability.
2. Fetch or verify the package manifest and repository metadata.
3. Build or assemble the kernel and initramfs.
4. Create the rootfs staging tree from Alpine packages.
5. Install the base system, services, and configuration.
6. Assemble the disk image.
7. Install `Limine`.
8. Produce the final bootable artifact for QEMU.

### Tooling Choice

Preferred tooling:

- `mkosi` for image assembly
- Alpine package staging for the rootfs
- `mkinitfs` for initramfs generation

This split keeps each part focused:

- package manager handles packages
- initramfs tool handles early boot
- image builder handles disk layout

### Output Artifact

The first release should emit a single raw disk image as the canonical artifact for QEMU. Additional formats can be added later if needed.

### Host Prerequisites

The build host needs a small set of tools to assemble the image reproducibly:

- `git`
- `curl`
- `ca-certificates`
- `bash`
- `python3`
- `jq`
- `mkosi`
- `qemu-system-x86_64`
- `qemu-img`
- `squashfs-tools`
- `xorriso`
- `mtools`
- `dosfstools`
- `e2fsprogs`
- `parted`
- `sfdisk`
- `limine`
- `libarchive-tools`

If the build host is Debian or Ubuntu based, the equivalent install command is:

```bash
sudo apt install git curl ca-certificates bash python3 jq mkosi qemu-system-x86 qemu-utils squashfs-tools xorriso mtools dosfstools e2fsprogs parted util-linux limine libarchive-tools
```

The distro itself should still use Alpine packages directly for the target image. The `apt` command is only for the build host.

## QEMU Test Workflow

The first validation target is QEMU x86_64 with UEFI.

The test workflow should verify:

- firmware boots the image
- kernel reaches init
- `s6` starts cleanly
- networking comes up via DHCP
- `Dropbear` is reachable
- the root filesystem mounts correctly
- the image behaves correctly across reboot

## Hardware Expansion Path

The design should remain portable to real hardware later by avoiding:

- hardcoded QEMU-only drivers
- QEMU-only storage assumptions
- bootloader assumptions that prevent normal UEFI hardware boot

The kernel and filesystem layout should stay generic enough that future hardware support is mostly a matter of adding drivers and validating firmware behavior.

### System and Vendor Separation

The distro should treat `system` and `vendor` as separate build/package concerns even if they share the same final image at first.

- `system` includes the immutable base OS, bootloader integration, init, package manager, supervision, and core services.
- `vendor` includes firmware, microcode, and hardware-specific support packages that may vary across machines.

For the first release, this separation should be a packaging boundary, not a separate partition boundary.
That keeps the design simple while preserving a future path to hardware-specific layers or update channels.

## Security Model

Security is based on minimizing the base system and reducing mutable state:

- minimal package set
- UEFI-only boot path
- limited SSH surface
- read-only or mostly read-only rootfs
- writable state only where needed
- explicit service users

This is not a full sandboxing platform. It is a small server OS with simple, auditable controls.

## Update and Delivery Model

The base operating system should support image-based OTA updates rather than in-place mutation of the immutable root filesystem.

### OTA Strategy

The update flow should use A/B slots:

1. Build a new full image.
2. Sign or checksum-verify the artifact.
3. Download it to the inactive slot.
4. Switch the boot target to the new slot.
5. Reboot into the new image.
6. Confirm the boot and basic health checks.
7. Roll back automatically to the previous slot if the new boot fails.

### Mutable State During Updates

Only mutable state under `/var` should persist across image swaps.

That includes:

- logs
- application data
- service state
- SSH host keys if they are not baked into the image

### Update Scope

- Root filesystem updates should not happen in place.
- Kernel and initramfs should be delivered as part of the image.
- App-level changes can still be applied independently by rebuilding the image or restarting services where appropriate.

## Acceptance Criteria

The first release is complete when:

- the image is reproducible from one script
- the image boots in QEMU x86_64 UEFI mode
- `s6` starts as PID 1
- DHCP networking works
- `Dropbear` is reachable
- the base filesystem is immutable
- Alpine packages are installed directly
- the system can be updated in a rolling fashion
