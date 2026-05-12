# QOS Distro: Native AOSP Execution Host
## (Truly Native Android App Support)

This document specifies the architecture and implementation of the **Native AOSP Execution Host** in the QOS distribution. This feature allows Android applications (.apks) to run as first-class, native Linux processes without the use of emulators, virtual machines, subsystems, or translation layers (like Wine).

---

## 1. Architectural Philosophy: "AOSP as a Library"

Standard approaches (like Waydroid) run a full Android OS in a container. QOS instead treats the **Android Open Source Project (AOSP)** as a set of native system libraries and services integrated directly into the host OS.

### 1.1 Core Principles
- **No Emulation**: Instruction sets are executed directly on the host CPU.
- **No Guest OS**: There is no secondary kernel, no "booting" Android, and no separate partition for a mobile OS.
- **Source-Native**: All core components are compiled from AOSP/LineageOS source code specifically for the QOS environment.
- **Unified Process Space**: Android apps appear in `htop`, are managed by `s6`, and share the host's networking and filesystem.

---

## 2. Technical Components

To achieve native execution, the following components are built from AOSP/LOS source and staged in the QOS rootfs:

### 2.1 The Android Runtime (ART)
- **Execution Engine**: The actual ART binaries (compiled from source) are used to execute DEX bytecode.
- **Compilation**: Supports JIT (Just-In-Time) and AOT (Ahead-Of-Time) compilation using the host's native instruction set (x86_64).

### 2.2 Multi-Libc Runtime
- **Bionic**: Android's C library is installed alongside the host's Musl libc.
- **AOSP Linker**: A specialized dynamic linker (`/system/bin/linker64`) is used to load Android binaries and resolve their dependencies against Bionic libraries staged in `/system/lib64`.

### 2.3 Native System Services (s6-managed)
Instead of an Android-specific init process, core services are ported to run as standard QOS **s6 services**:
- `servicemanager`: The directory for all Android IPC.
- `instanced`: Manages app lifecycle and process spawning.
- `packagemanager`: Handles APK installation and metadata.
- `activitymanager`: Coordinates app windows and task switching.

---

## 3. Native Graphics & IPC

### 3.1 Wayland-Native View System
To avoid the overhead of **SurfaceFlinger** (Android's compositor), QOS implements a Wayland shim:
- **Direct Rendering**: Android's `Hardware Abstraction Layer (HAL)` is modified to allocate buffers via `dmabuf` and present them directly to the **Wayland** compositor.
- **Window Management**: Each Android "Activity" is assigned a Wayland surface. This allows the QOS desktop (Sway/Hyprland) to manage Android apps as standard desktop windows with native resizing and snapping.

### 3.2 Kernel Binder IPC
- QOS uses the standard Linux kernel **Binder** driver (`CONFIG_ANDROID_BINDER_IPC`).
- All communication between apps and s6-managed Android services occurs via this high-performance kernel interface.

---

## 4. Implementation Strategy

### Phase 1: Toolchain & Library Staging
1. Integrate AOSP build tools (Soong/Kati) into the QOS build container (Podman).
2. Compile **Bionic**, **Linker**, and **Libbinder** from source.
3. Verify the ability to run a "Hello World" C binary linked against Bionic on the QOS host.

### Phase 2: Runtime & Service Porting
1. Compile and stage the **Android Runtime (ART)**.
2. Port the `servicemanager` and `ActivityManager` to run under **s6**.
3. Implement the `qos-apk-daemon` to handle APK parsing and installation.

### Phase 3: Graphics Integration
1. Develop the `libwayland-android` bridge to map Android EGL calls to Wayland surfaces.
2. Enable hardware acceleration for **NVIDIA/AMD** GPUs within the AOSP runtime.

---

## 5. Benefits vs. Traditional Methods

| Feature | Emulators | Waydroid (LXC) | QOS Native Host |
| :--- | :--- | :--- | :--- |
| **Instruction Speed** | Slow (Translated) | Native | **Native** |
| **Context Switching** | High (VM) | Medium (Container) | **Zero (Native Process)** |
| **Disk Space** | 2GB+ | 600MB+ | **~150MB (Shared Libs)** |
| **RAM Overhead** | 512MB+ | 200MB+ | **<50MB (System Services)** |
| **Integration** | Isolated Window | Subsystem Window | **Native Desktop Surface** |

---
*QOS: The definitive host for native Android execution.*
