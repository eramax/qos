# QOS Distro: Target Feature Specifications

This document summarizes the comprehensive list of feature requests and technical specifications for the next generation of the QOS distribution.

---

## 1. Core Architecture & Footprint
- **Target RAM Usage**: 
  - **Server**: <64MB (Headless).
  - **Desktop/Laptop**: <256MB (with running WebView/GUI).
- **Initialization**: 
  - **s6 / s6-rc**: Retain as the primary init system for performance.
  - **mdev**: Replace `udev` with the lightweight, run-and-exit `mdev` from BusyBox.
- **Boot Strategy**: 
  - **No-Copy Rootfs**: Mount SquashFS directly from boot media to save ~120MB of RAM.
  - **Modular Kernel**: Tiny core kernel (~8MB) with all hardware drivers (Wi-Fi, GPU, etc.) as loadable modules.

---

## 2. Declarative & Modern Engineering
- **Build System**: 
  - **Podman-Native**: All builds run in a strictly versioned container.
  - **mkosi**: Replace imperative scripts with declarative `mkosi.conf` and `mkosi.repart`.
- **System Manifest**: Unified `qos.yaml` as the single source of truth for packages, users, and services.
- **Codebase Consolidation**: Reduce total Lines of Code (LOC) by ~70% by moving to a unified `qos` CLI tool.

---

## 3. High-Performance Workload Profiles
The system adaptively scales based on the selected profile:
- **Server**: Ultra-minimal, security-hardened.
- **Desktop**: Pure Wayland GUI stack.
- **Gaming**: Optimized for Steam and high-end graphics.
- **K8s**: Native k3s and k9s integration.

---

## 4. GUI & Web Technologies
- **Wayland-Only**: No X11 support. Wayland is the primary display server; XWayland provided only for legacy game compatibility.
- **System WebView (Chromium-based)**:
  - Android-style shared rendering engine.
  - 100% web standard compatibility using Chromium (Blink/V8).
  - Lightweight `qos-webview` wrapper for Tauri-style native web apps.
- **Graphics**: Full support for the latest **NVIDIA** and **AMD** proprietary/high-performance drivers.

---

## 5. Native AOSP Execution Host
Run Android applications (.apk) with **Zero Emulation**:
- **Source-Based**: Bionic libc, ART (Android Runtime), and the AOSP Linker compiled directly from AOSP/LOS source and integrated into the QOS rootfs.
- **Native Processes**: Android apps run as first-class Linux processes (no containers, no subsystems, no Wine).
- **s6 Integration**: Android system services (`ActivityManager`, `PackageManager`) run as standard s6 services.
- **Wayland Integration**: Android activities render directly to Wayland surfaces, managed by the host desktop compositor.

---

## 6. Gaming & Entertainment
- **Steam Support**: Full integration with Steam and Proton.
- **Library Isolation**: 32-bit libraries required for gaming are isolated in a dedicated overlay to prevent bloating the 64-bit core.
- **Tuning**: Integration of `ananicy-cpp` and `Transparent Hugepages` (THP) for maximum gaming throughput.

---

## 7. Security & Integrity
- **dm-verity**: Move from simple "immutable" rootfs to cryptographically "verified" boot.
- **Kernel Hardening**: Adoption of KSPP (Kernel Self Protection Project) and Secure Boot signing.

---
*Generated based on user requirements - May 2026*
