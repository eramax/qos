# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Collaboration Guidelines

**Do not commit changes without explicit approval.** Always present changes for review first and wait for confirmation before creating commits. This applies to all code changes, documentation updates, and configuration modifications.

## Project Overview

QOS is a minimal, reproducible Linux distribution built on Alpine Linux with a custom kernel, s6 init, overlayfs immutable root, and UEFI-only Limine bootloader. It targets sub-64MB ISOs and sub-40MB RAM at runtime. The build system is a 6-stage modular pipeline driven by YAML profiles and modular components.

## Build Commands

```sh
make full          # Full build: rootfs → kernel → initramfs → bootloader → image → ISO
make server        # Build server profile
make desktop       # Build desktop profile (Wayland + Chromium)
make live          # Boot ISO in QEMU
make qemu          # Boot installed disk in QEMU
make kernel        # Rebuild kernel only
make rootfs        # Force rootfs rebuild
make clean-rootfs  # Clear rootfs cache
make clean-disk    # Clear QEMU disk image
make build-log     # Verbose build with full logging
make ram-check     # Assert RAM usage ≤ profile budget
```

To build and boot a specific profile: `make run <profile>`

## Architecture

### Build Pipeline (`builder/pipeline/`)

Six sequential shell scripts executed by `builder/build.sh`:

| Stage | Script | Purpose |
|---|---|---|
| 1 | `01-rootfs` | Alpine package installation + rootfs layout |
| 2 | `02-kernel` | Custom Linux kernel compilation |
| 3 | `03-initramfs` | Early boot env with overlayfs |
| 4 | `04-limine` | UEFI Limine bootloader install |
| 5 | `05-image` | GPT disk image assembly |
| 6 | `06-iso` | ISO creation |

`builder/resolve.sh` (Python) merges profile + component metadata before each build.

### Profile System (`profiles/`)

YAML files that compose components. Each profile can `extends:` another and adds `components:`, `packages:`, kernel config fragments, and QEMU parameters. The three profiles are `base`, `server`, and `desktop`.

### Component System (`components/`)

33 modular components, each directory containing:
- `component.yaml` — metadata: packages, dependencies, other components required
- `rootfs/` — files copied verbatim into the target rootfs
- `s6/` — s6-rc service definitions (if the component runs a service)

Components compose the final system. Adding functionality means adding a component and referencing it in a profile.

### Runtime Stack

- **PID 1:** s6-linux-init → s6
- **Services:** s6-rc (dependency-driven supervision)
- **Init shell:** ash (busybox), not bash
- **C library:** musl (not glibc)
- **Root filesystem:** overlayfs (immutable lower layer + ephemeral upper layer; state partition is writable)
- **Disk layout:** GPT — EFI (32MB) + root-a (16MB) + root-b (16MB) + state (auto-expands)

A/B root slots (`root-a`/`root-b`) support OTA updates with rollback.

### Reproducible Builds

The `Containerfile` defines an Alpine 3.23-based build container. Run builds inside it for reproducibility. Package versions are pinned there.

## Key Files

| Path | Role |
|---|---|
| `builder/build.sh` | Main build entry point |
| `builder/resolve.sh` | Profile + component resolver (Python) |
| `profiles/*.yaml` | Profile definitions |
| `components/*/component.yaml` | Per-component metadata |
| `components/kernel/kernel/x86_64.config` | Kernel config |
| `docs/IMPLEMENTATION-GUIDE.md` | Deep implementation details |

## Conventions

- Shell scripts in `builder/` use `set -euo pipefail` and source utilities from `builder/lib/`.
- Services are s6-rc `longrun` or `oneshot` bundles; service definitions live under `components/<name>/s6/`.
- The target shell is busybox `ash` — avoid bashisms in rootfs scripts.
- Kernel is UEFI-only; no BIOS/MBR support.
- The build cache is keyed on profile + package hash; editing `component.yaml` packages invalidates it.

## Testing & Debugging

### VirtualBox SSH Access

To test changes on a running VirtualBox VM with NAT networking:
```sh
sshpass -p root ssh -p 2222 root@localhost "command"
```

Port 2222 is the forwarded SSH port from the VM's NAT network. Root password is `root`. This allows verification of runtime behavior without rebuilding.

## Multi-User Desktop

The `qos-launch-desktop` script now supports any user (not just hardcoded emo):

```sh
# Start desktop for the default user (emo)
qos-launch-desktop

# Start desktop for a specific user
qos-launch-desktop username

# Or set via environment
QOS_DESKTOP_USER=alice qos-launch-desktop
```

When adding a new desktop user, ensure they are in these groups:
- `audio` — access to `/dev/snd/*` for pipewire
- `video` — access to `/dev/dri/*` for graphics
- `input` — access to input devices via seatd

Example to add user `alice` with desktop access:
```sh
adduser -D -h /home/alice -s /bin/sh alice
addgroup alice audio
addgroup alice video
addgroup alice input
```
