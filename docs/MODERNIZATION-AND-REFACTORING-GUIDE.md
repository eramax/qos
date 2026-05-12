# QOS Distro - Modernization & Refactoring Guide

**Date:** May 12, 2026  
**Status:** Architectural Roadmap  
**Target:** High-Integrity, Declarative, Minimal Linux Distribution

This document outlines a strategic roadmap to evolve **QOS** from a set of well-crafted shell scripts into a modern, high-integrity Linux distribution following the best practices of industry leaders like NixOS, Talos, and Fedora CoreOS.

---

## 1. Vision: The "Best in Class" Distro

A "best-in-class" modern Linux distribution should be:
- **Declarative**: The entire system state is defined in code, not through imperative scripts.
- **Reproducible**: Building the same version twice results in bit-for-bit identical artifacts.
- **Hermetic**: The build process is isolated from the host environment.
- **Atomic**: Updates are all-or-nothing and easily reversible.
- **Secure by Default**: Verified boot (dm-verity), hardened kernel, and fine-grained isolation.

---

## 2. Phase 1: Declarative Distro Engineering

Currently, QOS uses imperative scripts (`install-services.sh`, `build-rootfs.sh`) to assemble the system.

### Proposed Change: Unified System Manifest
Move towards a single source of truth (e.g., `qos.yaml`) that defines:
- Packages to install.
- Users and groups.
- Service definitions.
- Configuration file templates.
- Kernel parameters.

### Implementation:
1. **Transition to YAML/JSON Manifests**: Replace `.base` and `.system` package lists with a structured manifest.
2. **Configuration Templates**: Use a templating engine (like `envsubst`) to generate configurations from variables defined in the manifest.
3. **Structured Service Definitions**: Instead of manual `s6-rc.d` directory creation, define services in the manifest and have a tool generate the `s6` hierarchy.

---

## 3. Phase 2: Hermetic & Containerized Build Pipeline

The current build requires many host-level dependencies.

### Proposed Change: Container-Native Toolchain
Build everything inside a strictly defined container environment.

### Implementation:
1. **Build Container**: Create a `Dockerfile.build` containing the exact versions of all tools needed.
2. **Rootfs Staging**: Use a multi-stage container build to stage the rootfs. This leverages container layer caching and ensures the build environment is identical for every developer.
3. **Makefile Integration**: Update the `Makefile` to run build commands inside the container:
   ```make
   build:
       podman build -t qos-builder -f Dockerfile.build .
       podman run --rm -v $(PWD):/work qos-builder make internal-build
   ```

---

## 4. Phase 4: Modern Image Lifecycle & Integrity

Standardize on modern Linux building blocks for image assembly and updates.

### Proposed Change: `systemd-repart` & `dm-verity`
Instead of manual `sgdisk` and `dd`, use tools designed for immutable system images.

### Implementation:
1. **`systemd-repart`**: Use partition definition files (`.conf`) to describe the disk layout. This allows for dynamic resizing and verified partition creation.
2. **`dm-verity`**: Implement verified boot by hashing the rootfs partitions. The initramfs should verify the hash before mounting.
3. **Standardized Updates**: Move from custom `ota-*` scripts to a more robust mechanism like `systemd-sysupdate` or a simplified Go-based agent that handles A/B switching and health checks.

---

## 5. Phase 5: Unified Service Orchestration

`s6-rc` is excellent, but its manual configuration is a source of complexity.

### Proposed Change: Managed Init System
Create a higher-level abstraction for service management.

### Implementation:
1. **Service Metadata**: Each service should have a `service.yaml` defining its command, dependencies, and capability requirements.
2. **Generator Tool**: A tool (e.g., `qos-init-gen`) reads the metadata and generates the `s6-linux-init` and `s6-rc` structures.
3. **Capability Integration**: Automatically apply the Linux capabilities and cgroups settings defined in the service metadata at startup.

---

## 6. Phase 6: Security & Hardening

Elevate QOS to a high-security posture.

### Proposed Change: Verified Boot & Lockdown
1. **Signed Artifacts**: Sign the kernel (bzImage), initramfs, and rootfs verity hashes.
2. **Secure Boot**: Integrate with UEFI Secure Boot using a custom "shim" or `sbctl`.
3. **Hardened Kernel**: Adopt the [KSPP (Kernel Self Protection Project)](https://kernsec.org/wiki/index.php/Kernel_Self_Protection_Project) recommendations in the kernel config.

---

## 7. Phase 7: Developer & Operator Experience (DX/OX)

A distro is only as good as its tools.

### Proposed Change: The `qos` CLI
Create a unified CLI tool for all operations.

### Implementation:
- `qos build`: Builds the image (containerized).
- `qos run`: Boots the image in QEMU with all network wiring handled.
- `qos flash`: Safely flashes to a target device.
- `qos update`: Pushes an update to a remote node.
- `qos debug`: Connects to a running instance with debugging tools.

---

## 8. Summary of Refactoring Steps

| Area | Current (Imperative) | Target (Declarative/Modern) |
|------|----------------------|-----------------------------|
| **Build Env** | Host-installed tools | Podman/Containerized toolchain |
| **Manifests** | Multiple `.txt` lists | Unified `qos.yaml` manifest |
| **Rootfs** | Manual `fakeroot apk` | Container-staged rootfs |
| **Image** | `sgdisk` + `dd` scripts | `systemd-repart` / `mkosi` |
| **Services** | Manual `s6` directory hacking | Generated from service metadata |
| **Integrity** | Plain partitions | `dm-verity` verified rootfs |
| **Testing** | Shell scripts in `tests/` | Integrated `pytest` + QEMU |

---

## 9. Next Steps

1. **Proof of Concept**: Move the package lists to a single YAML file and create a Python script to parse it and run the current build scripts.
2. **Containerize**: Create the `Dockerfile.build` and ensure the build works identically inside it.
3. **Integrate `dm-verity`**: Start by adding a hash-tree generation step to the image assembly.

---
*QOS Distro: Small, Fast, Secure, and now, Modern.*
