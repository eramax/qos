# QOS Distro: High-Performance Workload Profiles
## (GUI, Gaming, and Kubernetes)

This document specifies the implementation of advanced workload profiles for the QOS distribution. It defines how a minimal <64MB OS scales to support NVIDIA/AMD drivers, Steam, Chromium, and Kubernetes.

---

## 1. The Adaptive Profile Architecture

QOS uses a "layered minimalism" approach. The core system remains identical, but additional capabilities are layered on during build or install based on the selected profile.

### 1.1 Profile Definitions
| Profile | Target | Key Components |
| :--- | :--- | :--- |
| **Server** | Headless/Cloud | Dropbear, s6, nftables, minimal virtio drivers. |
| **Desktop** | Workstation | Wayland (Sway/GNOME), Chromium, Pipewire, Mesa/Proprietary Drivers. |
| **Gaming** | Steam/Entertainment | Steam, 32-bit Compat Layer, Proton, GameMode, ananicy-cpp. |
| **K8s** | Orchestration | k3s, k9s, container-selinux, bridge-utils. |

---

## 2. Graphics & GUI Implementation

### 2.1 Modular GPU Drivers
To avoid bloating the server image, proprietary drivers are handled as modular extensions.
- **NVIDIA**: Packaged as a separate SquashFS layer or a dynamic kernel module (DKMS) staged in `/lib/modules`.
- **AMD/Mesa**: Included in the `desktop` profile using the latest upstream Alpine/Mesa builds for Vulkan support.
- **Probing**: The `qos` CLI detects the hardware and enables the correct driver overlay at boot.

### 2.2 Wayland-Only GUI Stack
QOS adopts a **modern, X11-free** architecture for all GUI workloads.
- **Display Server**: Pure **Wayland** (using `wlroots` or similar). X11 is not supported as a primary display server.
- **XWayland**: Provided only as a minimal compatibility layer for legacy applications and games (Steam) that have not yet migrated to native Wayland.
- **Environment**: Light-weight Wayland compositors like `Sway`, `River`, or `Hyprland` are preferred for their minimal footprint.
- **Browser**: Chromium is configured to run natively on Wayland (`--enable-features=UseOzonePlatform --ozone-platform=wayland`).

### 2.3 System WebView (Chromium-based)
To ensure 100% web compatibility and an Android-like experience, QOS implements a **Chromium-based System WebView**.
- **Engine**: **Chromium (Blink/V8)**.
- **Rationale**: While heavier than WebKit, Chromium provides the most robust support for modern web standards, DRM, and high-performance hardware acceleration, mirroring the Android System WebView architecture.
- **Implementation**:
  - **Shared Binary Strategy**: A single, optimized Chromium binary is provided in the `desktop` profile.
  - **App Isolation**: Applications launch their own processes using the shared binary but with isolated profiles and data directories.
  - **Resource Management**: Uses Chromium's `--ozone-platform=wayland` and `--app` flags to provide a borderless, native-feeling window for web-based apps.
  - **Memory Impact**: Enabling a Chromium WebView session will increase RAM usage by ~150-200MB. This is acceptable for the `desktop` profile but excluded from the `server` profile.

---

## 3. Gaming & Steam Strategy

### 3.1 Steam (32-bit) Isolation
Steam requires 32-bit libraries, which can "pollute" a 64-bit minimal system.
- **Solution**: 32-bit libraries are stored in a dedicated `/lib32` or `/usr/lib32` overlay that is only mounted when the `gaming` profile is active.
- **Proton/Wine**: Use `Flatpak` or a managed `chroot/namespace` to run Steam, keeping the rootfs clean.

### 3.2 Performance Tuning
- **Process Scheduling**: Use `ananicy-cpp` to give Steam and games real-time priority.
- **Memory**: Enable `Transparent Hugepages (THP)` for reduced TLB misses in large games.
- **GameMode**: Integrate Feral Interactive's `GameMode` to automate CPU governor and I/O priority switching.

---

## 4. Kubernetes (k3s/k9s) Integration

### 4.1 k3s (Lightweight K8s)
- **Deployment**: k3s is integrated as an s6-managed service.
- **Resource Limits**: k3s is placed in its own cgroup with a reserved "Capability Profile" to ensure it doesn't starve the base OS.
- **Storage**: Optimized for local-path provisioner on the `state` partition.

### 4.2 k9s (CLI Management)
- Included in the `k8s` profile for easy terminal-based management.

## 5. Native AOSP Execution Host (No Emulation / No Wine)

QOS implements a **Native AOSP Execution Host**, utilizing the original source code from AOSP and LineageOS to provide a first-class Android runtime. This is not a translation layer (like Wine) or a subsystem container; it is the **actual Android stack** compiled to run natively on the QOS host.

### 5.1 Architecture: The Native Runtime
Android applications (.apks) and their native libraries (.so) are executed directly by the QOS kernel and the **AOSP Dynamic Linker**.
- **Source-Based**: Core components (Bionic, Linker, ART, Libbinder) are built directly from AOSP/LOS source to ensure binary-identical behavior with official Android devices.
- **No Shims**: There is no "translation" of APIs. The apps call the actual AOSP libraries compiled for the QOS environment.
- **Execution**: When an app is launched, the QOS kernel spawns a process that loads the **Android Runtime (ART)** as a native library, which then JIT/AOT compiles the app's bytecode for the host CPU.

### 5.2 System Service Integration
Instead of a separate Android "init" or container boot, Android system services are integrated directly into the QOS **s6 init system**:
- **Service Management**: `ActivityManager`, `PackageManager`, and `WindowManager` are started as standard s6 services.
- **Process Space**: Android apps run in the same process space as native QOS/Linux apps, allowing them to be managed by standard tools like `htop`, `ps`, and `kill`.
- **Inter-Process Communication (IPC)**: Apps communicate with system services via the **Binder** interface provided directly by the QOS kernel.

### 5.3 Graphics: Native Wayland Integration
To avoid the overhead of SurfaceFlinger (the Android compositor), QOS uses a specialized **Wayland-native View system**.
- **Direct Rendering**: Android's `Gralloc` and `EGL` implementations are modified to talk directly to the QOS Wayland compositor.
- **Window Management**: Each Android activity is treated as a native Wayland surface, allowing the QOS desktop environment (Sway/Hyprland) to manage Android windows alongside Chromium and Steam windows.

### 5.4 Benefits of Source-Native Integration
- **100% Native Performance**: CPU, GPU, and Memory access occur at hardware speed with zero overhead.
- **Binary Compatibility**: Because we use the original AOSP source for Bionic and ART, native Android libraries work without modifications.
- **Deep System Access**: Android apps can access QOS host resources (USB, Sound, Network) as if they were running on a physical Android device.

---

## 6. Implementation Roadmap

### Phase A: Build System Support
- Update `qos.yaml` manifest to support profile-specific package lists and overlays.
- Implement "Multi-Layer SquashFS" assembly in the build pipeline.

### Phase B: Driver Automation
- Create the `qos-driver-manager` logic to detect GPUs and stage the correct firmware/modules.

### Phase C: Workload Orchestration
- Create `s6` service templates for the Wayland compositor and k3s server.

---
*QOS: One Core, Infinite Workloads.*
