# QOS Distro - LOC Reduction & Consolidation Plan

**Current LOC**: ~5,300 lines (Shell)  
**Target LOC**: ~2,500 - 3,000 lines (50% Reduction)

To achieve a significant reduction in Lines of Code (LOC) while increasing maintainability, the following consolidation strategy is proposed.

---

## 1. Unified `qos` Management CLI (-1,500 lines)

Currently, we have multiple standalone scripts that share similar logic (usage handling, log functions, error trapping):
- `qos-capability.sh` (199 lines)
- `qos-cluster.sh` (134 lines)
- `qos-install.sh` (435 lines)
- `qos-test.sh` (545 lines)
- `qos-e2e-full.sh` (438 lines)
- `qos-expand.sh` (57 lines)

### Proposed Change:
Create a single `qos` tool (either in Bash or a more expressive language like Go/Python) with subcommands:
- `qos cap ...` (Capability management)
- `qos node ...` (Cluster management)
- `qos install` (System installer)
- `qos test` (Feature/E2E testing)

**Benefit**: Eliminates redundant headers, common function definitions, and boilerplate usage blocks in every file.

---

## 2. Declarative Build System with `mkosi` (-700 lines)

The imperative build scripts are the second largest source of code:
- `build-rootfs.sh` (125 lines)
- `build-initramfs.sh` (143 lines)
- `assemble-image.sh` (177 lines)
- `build-iso.sh` (226 lines)

### Proposed Change:
Replace these scripts with `mkosi` (Make Operating System Images).
- **Current**: 670 lines of shell code managing `fakeroot`, `apk`, `cpio`, `sgdisk`, `mkfs`, and `xorriso`.
- **Target**: ~50 lines of declarative `mkosi.conf` and `mkosi.repart` files.

**Benefit**: Moves complex image assembly logic to a tested, industry-standard tool.

---

## 3. Unified QEMU & Networking Infrastructure (-400 lines)

There is significant overlap in how we boot images and set up TAP/Bridge networking:
- `run-qemu.sh` (191 lines)
- `boot-image.sh` (67 lines)
- `qemu-host-net-up.sh` (186 lines)
- `qemu-host-net-down.sh` (148 lines)

### Proposed Change:
Integrate networking setup directly into the QEMU launcher. Use a single logic block to detect available network backends (user, tap, bridge) instead of separate scripts.

---

## 4. Test Suite Consolidation (-800 lines)

We have many small, overlapping test scripts:
- `tests/*.sh` (14 files, ~1,200 lines)

### Proposed Change:
Migrate to a single unified test runner (e.g., `pytest` with a QEMU plugin or a single structured `qos test` command). This allows for shared fixtures (like "booted VM") across many test cases.

---

## Summary of Potential Savings

| Component | Current LOC | Target LOC | Est. Savings |
| :--- | :--- | :--- | :--- |
| Management Tools | 1,800 | 500 | 1,300 |
| Build Pipeline | 700 | 100 | 600 |
| QEMU/Networking | 600 | 200 | 400 |
| Test Suite | 1,200 | 400 | 800 |
| **Total** | **4,300** | **1,200** | **3,100 (~70%)** |

*(Note: Remaining ~1,000 lines would be shared libraries and core system scripts like initramfs `init`)*

---

## Next Steps

1. **Prototype the `qos` CLI**: Merge `qos-capability` and `qos-cluster` first.
2. **Implement `mkosi.conf`**: Replace one build stage (e.g., rootfs) and verify.
3. **Consolidate `run-qemu.sh`**: Merge host-net setup into the launcher.
4. **Containerize the Toolchain**: Implement the `Dockerfile.build` using **Podman** for rootfs staging and hermetic builds.
