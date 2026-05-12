# QOS Distro - Master Implementation Plan

This document provides a phased, actionable roadmap for implementing the modernization, optimization, and consolidation strategies for the QOS distribution.

---

## Milestone 1: The Modern Build Pipeline (Declarative & Hermetic)
**Goal**: Replace imperative shell scripts with a declarative, containerized build system.

1.  **Build Containerization**:
    - Create `Dockerfile.build` containing all toolchain dependencies.
    - Update `Makefile` to route all build commands through `podman run` (or `docker run`).
2.  **Declarative Manifest**:
    - Consolidate `packages.base` and `packages.system` into a single `qos.yaml`.
    - Create a Python/Go generator to parse `qos.yaml` and produce build inputs.
3.  **`mkosi` Migration**:
    - Replace `build-rootfs.sh` and `assemble-image.sh` with `mkosi.conf`.
    - Implement `mkosi.repart` for declarative partitioning.
4.  **Verification**:
    - Ensure the 64MB image target is met using the new pipeline.

---

## Milestone 2: Unified Management Tooling (The `qos` CLI)
**Goal**: Reduce LOC by 50% and unify the operator experience.

1.  **CLI Scaffold**:
    - Implement a unified `qos` entry point (Bash/Go).
2.  **Command Migration**:
    - **Phase A**: Merge `qos-capability.sh` and `qos-cluster.sh` into `qos cap` and `qos node`.
    - **Phase B**: Merge `qos-install.sh` into `qos install`.
    - **Phase C**: Merge `qos-expand.sh` into `qos disk expand`.
3.  **Shared Library**:
    - Move common logic (logging, error handling, disk detection) into a single internal library used by the CLI.

---

## Milestone 3: Security Hardening & Integrity
**Goal**: Move from "immutable" to "verified" boot.

1.  **`dm-verity` Implementation**:
    - Add hash-tree generation to the build pipeline.
    - Update `initramfs/init` to verify the rootfs partition using the hash before mounting.
2.  **Kernel Hardening**:
    - Apply KSPP (Kernel Self Protection Project) recommendations to `x86_64.config`.
    - Enable `CONFIG_SECURITY_LOCKDOWN_LSM`.
3.  **Secure Boot (Optional)**:
    - Integrate `sbctl` into the build process to sign the UKI (Unified Kernel Image).

---

## Milestone 4: Performance & Resource Tuning
**Goal**: Squeeze maximum efficiency out of limited hardware.

1.  **Kernel Optimization**:
    - Apply Expedited RCU and expedited grace period parameters.
    - Implement `page_alloc.shuffle=1` in the default boot command line.
2.  **EarlyOOM Integration**:
    - Add `earlyoom` package to the core image.
    - Create an s6 service for `earlyoom` with optimized thresholds for <40MB RAM.
3.  **Silent Boot**:
    - Tune `limine.conf` and kernel loglevels for a clean, professional startup.

---

## Milestone 5: Unified Testing & Validation
**Goal**: Consolidate testing infrastructure for higher reliability.

1.  **Test Suite Unification**:
    - Merge all `tests/*.sh` into a single structured test suite.
    - Shared fixtures for QEMU instance management.
2.  **E2E Consolidation**:
    - Integrate `qos-test-e2e.sh` and `qos-e2e-full.sh` into `qos test --full`.
3.  **CI/CD Pipeline**:
    - Automate the new build + test flow using GitHub Actions (leveraging the build container).

---

## Summary of Changes by Milestone

| Milestone | Key Outcome | Est. LOC Change |
| :--- | :--- | :--- |
| **1. Modern Build** | Reproducible, declarative images | -600 lines |
| **2. Unified CLI** | Single management tool (`qos`) | -1,500 lines |
| **3. Hardened Core** | `dm-verity` verified boot | +100 lines |
| **4. Tuning** | Low latency, EarlyOOM stability | Minimal |
| **5. Unified Testing** | Reliable, shared test fixtures | -800 lines |
| **Total** | **High-Integrity Distro** | **-2,800 lines** |

---

## Next Action Items (Immediate)

1.  [ ] **Create the `Dockerfile.build`** to lock in the toolchain.
2.  [ ] **Prototype `qos.yaml`** and the `mkosi` configuration.
3.  [ ] **Launch the `qos` CLI** with the `cap` and `node` subcommands.
