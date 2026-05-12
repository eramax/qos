# QOS Distro: Complete Architectural Blueprint & Implementation Plan

**Date**: May 12, 2026  
**Status**: Comprehensive Master Strategy  
**Target**: <64MB RAM (Server), <256MB RAM (Desktop/Laptop), Declarative, High-Integrity, Workload-Adaptive (GUI/Gaming/K8s)

---

## 1. Project Assessment & Review

### 1.1 Executive Summary
QOS is a highly specialized, ultra-minimal Linux distribution based on Alpine Linux. It successfully implements modern OS patterns such as **immutability**, **A/B atomic updates**, and **capability-based isolation** within a remarkably small footprint (~64MB image, <40MB RAM). While ultra-minimal by default, QOS is designed to scale into a high-performance workstation supporting **GUI environments**, **NVIDIA/AMD proprietary drivers**, **Gaming (Steam)**, and **Kubernetes (k3s/k9s)** through modular workload profiles. For GUI workloads, it provides a **Chromium-based System WebView** to ensure maximum compatibility.

### 1.2 Architectural Grades
- **Core OS (Grade: A)**: Excellent process supervision (s6/s6-rc) and fast boot times. Immutable rootfs ensures system integrity.
- **Build Pipeline (Grade: B+)**: High reproducibility through manifest tracking, but currently imperative and host-dependent.
- **Security (Grade: A-)**: Standout `qos-capability` tool. Needs `dm-verity` for cryptographic rootfs verification.
- **Service Orchestration (Grade: B)**: Solid dependency management, but configurations are hard-coded into the image.

### 1.3 SWOT Analysis
| **Strengths** | **Weaknesses** |
| :--- | :--- |
| Ultra-minimal footprint | High reliance on imperative shell scripts |
| Atomic A/B updates | Steep learning curve for `s6/execline` |
| Native capability-based isolation | No declarative system manifest |
| Fast boot and low resource usage | Limited bare-metal hardware support |
| **Opportunities** | **Threats** |
| Edge/IoT device market | Upstream Alpine breaking changes |
| Custom lightweight container host | Maintainer burnout due to script complexity |
| Secure hardware appliance OS | Competition from NixOS/Talos in small niches |

---

## 2. Modernization Roadmap

### 2.1 Vision: The "Best in Class" Distro
Move from imperative scripts to a declarative, high-integrity architecture inspired by industry leaders like NixOS and Fedora CoreOS.
- **Declarative**: Entire system state defined in a single `qos.yaml`.
- **Workload-Adaptive**: Scales from a 40MB headless node to a full-featured gaming/dev workstation.
- **Reproducible**: Bit-for-bit identical artifacts regardless of host environment.
- **Hermetic**: Build process isolated using Podman.
- **Atomic**: All-or-nothing updates via `systemd-sysupdate`.

### 2.2 Key Phases
- **Phase 1: Declarative Distro Engineering**: Transition to YAML/JSON manifests. Replace `.base` and `.system` lists with a structured `qos.yaml`. This manifest will support **Workload Profiles**:
  - `profile: server` (Headless, minimal drivers)
  - `profile: desktop` (Wayland-only, Chromium, System WebView, Native AOSP Execution Host, GUI apps)
  - `profile: gaming` (Steam, 32-bit libs, latest GPU drivers)
  - `profile: k8s` (k3s, k9s, container runtimes)
- **Phase 2: Hermetic Build Pipeline**: Use `Podman` and `Dockerfile.build` to lock in the toolchain. Update the `Makefile` for container-native builds.
- **Phase 3: Modern Image Lifecycle**: Replace manual `sgdisk`/`dd` scripts with `systemd-repart` and `mkosi`.
- **Phase 4: Unified Service Orchestration**: Generate `s6-rc` hierarchies from high-level metadata (e.g., `service.yaml`).
- **Phase 5: Security Hardening**: Implement signed artifacts, Secure Boot (UKI), and KSPP kernel hardening.

---

## 3. RAM Minimization Strategy (<100MB Target)

The goal is to reduce baseline RAM usage to **<64MB (Server)**. For the **Desktop/Laptop** profile, the target is **<256MB** to accommodate the Chromium-based System WebView.

### 3.1 The "No-Copy" Strategy
- **Eliminate `copytoram`**: Modify `initramfs` to mount SquashFS directly from the boot media. This saves **~120MB** of RAM immediately.

### 3.2 Surgical Kernel Configuration
Disable non-essential features and optimize for size:
- `CONFIG_CC_OPTIMIZE_FOR_SIZE=y`, `CONFIG_EXPERT=y`, `CONFIG_EMBEDDED=y`.
- Disable: `CONFIG_SOUND`, `CONFIG_VIDEO_V4L2`, `CONFIG_BLUETOOTH`, `CONFIG_SLUB_DEBUG`.
- Boot Parameters: `slab_debug=-`, `page_alloc.shuffle=1`, `log_buf_len=128K`.

### 3.3 Modular Minimalism (Hardware & Workload Support)
- **Core-Module Split**: Built-in drivers only for essentials (NVMe, SATA, Ext4). Wi-Fi, GPU, and USB drivers stay on disk as modules.
- **GPU Drivers**: NVIDIA/AMD drivers are treated as heavy-weight modules. They are only loaded when the `desktop` or `gaming` profile is active.
- **Steam & 32-bit Support**: To keep the base system clean, 32-bit libraries required for Steam are isolated in a dedicated overlay or container-like layer, preventing bloat in the headless server profile.
- **mdev vs udev**: Replace the persistent `udev` daemon with BusyBox's `mdev`. `mdev -s` scans hardware and triggers `modprobe` only for detected devices.
- **Sparse Firmware**: Include compressed firmware only for common chipsets (Intel/Realtek).

### 3.4 Resource Comparison
| Layer | Before | After | Saving |
| :--- | :--- | :--- | :--- |
| Rootfs in RAM | 120 MB | 0 MB | 120 MB |
| Kernel Overhead | 80 MB | 30 MB | 50 MB |
| Daemon Bloat | 50 MB | 10 MB | 40 MB |
| **Total Usage** | **250 MB** | **~40-60 MB** | **~200 MB** |

---

## 4. Performance Optimization & Tuning

### 4.1 Kernel Boot Parameters (`limine.conf`)
- `rcupdate.rcu_expedited=1`: Speeds up RCU grace periods.
- `rcu_normal=0`: Forces expedited mode.
- `page_alloc.shuffle=1`: Improves page allocator cache locality.
- `nowatchdog`: Disables hardware watchdog to reduce interrupts.
- `quiet loglevel=3`: Professional, silent boot experience.

### 4.2 Resource Management
- **EarlyOOM**: Add `earlyoom` package with thresholds: `-m 5 -s 5 --prefer 'bun|caddy' --avoid 'sshd|s6-svscan'`.
- **Gaming & GUI Tuning**:
  - Use `ananicy-cpp` for automated process priority management (Steam/Chromium).
  - Enable `Transparent Hugepages` (THP) for memory-intensive apps like browsers and games.
- **Kubernetes (k3s) Optimization**:
  - Pre-allocate cgroup resources for `k3s`.
  - Tune `inotify` limits to support high-pod densities.
- **ZRAM**: Use a small ZRAM (32MB) with the `zstd` algorithm for efficient memory compression.
- **Filesystem**: Standardize on `noatime` and `commit=60` in `/etc/fstab`. Use `none` or `mq-deadline` IO schedulers.

---

## 5. LOC Reduction & Consolidation Plan

**Current LOC**: ~5,300 lines (Shell)  
**Target LOC**: ~1,500 lines (70% Reduction)

### 5.1 Unified `qos` Management CLI (-1,500 lines)
Consolidate standalone scripts (`qos-capability.sh`, `qos-cluster.sh`, `qos-install.sh`, `qos-test.sh`) into a single `qos` entry point with subcommands (`cap`, `node`, `install`, `test`). Eliminates massive redundant boilerplate.

### 5.2 Declarative Builds with `mkosi` (-700 lines)
Replace 670 lines of imperative `fakeroot`, `apk`, `sgdisk`, and `mkfs` commands with ~50 lines of `mkosi.conf` and `mkosi.repart` files.

### 5.3 Infrastructure Consolidation
- **Networking/QEMU**: Merge host-net setup scripts directly into the `run-qemu.sh` launcher (-400 lines).
- **Test Suite**: Move from 14+ shell scripts to a single structured test runner with shared QEMU fixtures (-800 lines).

---

## 6. Master Implementation Plan

### Milestone 1: The Modern Build Pipeline
- [ ] **Containerization**: Create `Dockerfile.build` and update `Makefile` to use `podman run`.
- [ ] **Declarative Manifest**: Create `qos.yaml` and parser to generate build inputs.
- [ ] **`mkosi` Migration**: Implement `mkosi.conf` and `mkosi.repart` for image assembly.

### Milestone 2: Unified Management Tooling
- [ ] **CLI Scaffold**: Implement unified `qos` entry point (Bash/Go).
- [ ] **Command Migration**: Merge `cap`, `node`, `install`, and `disk expand` logic.
- [ ] **Shared Library**: Centralize logging, error handling, and hardware detection logic.

### Milestone 3: Security Hardening & Integrity
- [ ] **`dm-verity`**: Add hash-tree generation to build; update initramfs to verify rootfs.
- [ ] **Kernel Hardening**: Apply KSPP recommendations and enable `CONFIG_SECURITY_LOCKDOWN_LSM`.
- [ ] **Secure Boot**: Integrate `sbctl` to sign the Unified Kernel Image (UKI).

### Milestone 4: Performance & Resource Tuning
- [ ] **Workload Profiles**: Implement profile-specific tuning for `desktop`, `gaming`, and `k8s`.
- [ ] **GPU Driver Integration**: Automate proprietary NVIDIA/AMD driver staging and modular loading.
- [ ] **App Staging**: Integrate `k3s`, `k9s`, `Steam`, and `Chromium` into the declarative build flow.
- [ ] **EarlyOOM Integration**: Create s6 service with optimized thresholds.
- [ ] **Kernel Tuning**: Apply expedited RCU and page shuffling parameters.
- [ ] **Modular HW Support**: Implement `mdev` probing and kernel module splitting.

### Milestone 5: Unified Testing & Validation
- [ ] **Test Unification**: Consolidate all `tests/*.sh` and E2E scripts.
- [ ] **CI/CD Automation**: Implement GitHub Actions pipeline using the build container.

---
*Blueprint generated by Gemini CLI - May 2026*
