# Waydroid Runtime: Wayland-Native Android App Runner for QOS

## Overview

A new Android app runtime for QOS that replaces ATL's GTK4-based approach with direct Wayland rendering, modern API level support (28+), and native x86_64/ARM64 performance via ART AOT compilation. The runtime is a single binary that embeds ART, implements Android framework JNI stubs that render to Wayland surfaces, and runs apps as standard Wayland clients.

## Architecture

```
APK (DEX) ──dex2oat──▶ .oat (native ELF for target arch)
                            │
AOSP framework (API 28+) ──▶ .oat (pre-compiled per arch)
                            │
                      ART runtime (libart.so)
                            │
                  libandroid_runtime.so (our JNI stubs)
                      │              │              │
                  wl_egl           wl_shm         wl_seat
                 (GLES apps)   (Canvas apps)    (input)
                      │              │              │
                      └──────┬───────┘              │
                             │                      │
                     Wayland compositor (river/sway)
```

### Key Components

1. **ART runtime** (`libart.so`) — Built from AOSP source with JIT + dex2oat enabled. Handles DEX loading, class resolution, garbage collection, and JIT compilation. On ARM64, generates native ARM64 code. On x86_64, generates x86_64 code.

2. **Android framework** — AOSP `frameworks/base` Java source compiled to DEX via `d8`, then AOT-compiled to native OAT files via `dex2oat`. The same Java classes Android apps expect (`Activity`, `View`, `Canvas`, `Resources`, etc.), running on ART unchanged.

3. **JNI bridge** (`libandroid_runtime.so`) — Our replacement for AOSP's `libandroid_runtime.so`. Implements all framework JNI native methods. Rendering calls go to Wayland surfaces instead of SurfaceFlinger. Input comes from `wl_seat` instead of Android's InputFlinger. Audio goes to PipeWire instead of AudioFlinger.

4. **Wayland client** — Direct `libwayland-client` usage (no GTK4). Creates `xdg_toplevel` windows, renders via `wl_egl` (GLES) or `wl_shm` (Canvas), handles input via `wl_seat`. Each Android Activity maps to one `xdg_toplevel`.

## Design Decisions

### Runtime Engine: ART (from AOSP source)

- **Why ART, not JVM**: ART is the real Android runtime — it loads DEX natively, supports all Android-specific features (dex cache, multidex, APK resource loading), and is already cross-platform (ARM64, x86_64). JVM would require DEX→JAR conversion and lacks Android-specific capabilities.
- **Why build from source, not Alpine's art_standalone**: Need JIT enabled, dex2oat working, and custom initialization hooks. Alpine's package may disable features needed for optimal performance.
- **AOT compilation**: APKs are AOT-compiled via dex2oat at install time, producing native .oat ELF files. No JIT warmup overhead, same perf as pre-installed Android apps.

### Display: Standard Wayland Client

- Our runtime is a standard Wayland client connecting to any wlroots-based compositor (river, sway, etc.).
- GLES apps: JNI stubs in `runtime/jni/opengl/` translate GLES calls to desktop GL → rendered to EGL context from `runtime/wayland/egl.c` → composited via `wl_egl` → Wayland.
- Canvas apps: JNI stubs in `runtime/jni/graphics/` call Skia raster backend → `wl_shm` shared buffer → compositor.
- Each Activity gets its own `xdg_toplevel` window.
- No XWayland dependency. No GTK4 dependency.

### JNI Stub Strategy: Systematic + No-Crash

- Script scans AOSP `frameworks/base/core/jni/` to discover all native method declarations.
- Generates stub implementations with safe default return values (0, null, false).
- Unimplemented stubs log a warning and return the default — apps limp along instead of crashing.
- Implementation proceeds tier by tier: OS stubs → Graphics (Skia) → View/Input → Media → Hardware.

### Lifecycle: Simplified In-Process

- No Binder IPC. No Android system services (no real ActivityManagerService, WindowManagerService, etc.).
- In-process ActivityManager calls lifecycle methods directly via JNI.
- Intents are local hash maps, not Binder parcels.
- Each Activity lifecycle maps to xdg_toplevel state: create→open, resume→render, pause→hide, destroy→close.

### System Services: Stub-First

| Service | Approach |
|---|---|
| PackageManager | Read AndroidManifest.xml from APK, return stored metadata |
| ConnectivityManager | Stub returning "WiFi connected" |
| WifiManager | Stub returning "WiFi enabled" |
| SensorManager | Stub returning empty sensor list |
| Vibrator | No-op |
| AudioTrack | MVP: no-op. Later: PipeWire stream |
| Storage | Map /data/data/<pkg> → ~/.local/share/qos-android/<pkg>/ |
| Clipboard | wl_data_device |
| Notifications | MVP: no-op. Later: libnotify |

## Project Structure

```
deps/qos-android-runtime/
├── build.sh                 # Main build script: clones AOSP, builds ART, compiles framework, builds runtime
├── framework/
│   ├── extract.sh           # Extract relevant AOSP framework Java sources
│   └── compile.sh           # javac → d8 → dex2oat pipeline
├── runtime/
│   ├── main.c               # Entry point: parse args, init ART, load framework, launch Activity
│   ├── include/             # Internal headers
│   ├── wayland/
│   │   ├── display.c        # wl_display connection, registry, globals
│   │   ├── window.c         # xdg_toplevel creation, configure, close
│   │   ├── egl.c            # wl_egl surface for GLES rendering
│   │   ├── shm.c            # wl_shm pool for Canvas rendering
│   │   └── input.c          # wl_seat pointer/keyboard/touch → MotionEvent/KeyEvent
│   ├── art/
│   │   ├── runtime.c        # ART runtime initialization
│   │   ├── class_loader.c   # Loading framework + app OAT files
│   │   └── jni_bridge.c     # JNI call bridge to ART internals
│   ├── jni/
│   │   ├── stub_generated/  # Generated stubs (one .c per AOSP JNI module)
│   │   ├── graphics/        # Canvas, Bitmap, Paint → Skia implementations
│   │   ├── opengl/          # GLES → desktop GL translation
│   │   ├── view/            # ViewRootImpl, Choreographer, input
│   │   ├── content/         # AssetManager, Resources, XmlBlock
│   │   ├── media/           # AudioTrack (stub for MVP)
│   │   └── os/              # SystemProperties, Build, Process (stubs)
│   ├── android/
│   │   ├── activity_manager.c   # In-process Activity lifecycle
│   │   ├── package_manager.c    # AndroidManifest.xml parser + APK metadata
│   │   └── intent.c             # Simple intent handling
│   └── Makefile
├── output/
│   ├── lib/                 # Built libraries (libart.so, libandroid_runtime.so, libskia.so)
│   ├── bin/                 # qos-android-launch binary
│   └── framework/           # Pre-compiled .oat files (arch-specific)
```

## Build Pipeline

### Stage 1: Build ART from AOSP

```sh
# Clone AOSP's art module
# Configure for standalone build (not full Android)
# Enable: JIT, dex2oat, x86_64/ARM64 backends
# Output: libart.so, dex2oat, etc.
```

### Stage 2: Compile AOSP Framework

```sh
# Extract relevant Java sources from frameworks/base
# Compile with javac → d8 (DEX) → dex2oat (native .oat)
# OAT files are arch-specific (re-compile per target)
```

### Stage 3: Build Runtime + JNI Stubs

```sh
# Generate JNI stubs from AOSP JNI source scan
# Compile runtime binary + wayland client
# Link against: libart.so, libwayland-client.so, libEGL.so, skia, etc.
```

### Stage 4: Package

```sh
# Collect: qos-android-launch, libart.so, libandroid_runtime.so, framework .oat files
# Create tarball for QOS component integration
```

## QOS Integration

Component: `components/qos-android-runtime/`

```yaml
# component.yaml
name: qos-android-runtime
packages:
  - wayland
  - wayland-client
  - seatd
  - pipewire         # future: audio
  - mesa-egl         # for wl_egl
  - mesa-gl
```

Rootfs layout:
```
/usr/bin/qos-android-launch
/usr/lib/qos-android/libart.so
/usr/lib/qos-android/libandroid_runtime.so
/usr/lib/qos-android/libskia.so
/usr/lib/qos-android/libEGL.so       # GLES→desktop GL wrapper
/usr/lib/qos-android/libGLESv2.so    # GLES→desktop GL wrapper
/usr/share/qos-android/framework/*.oat  # Pre-compiled framework
```

### Commands

- `qos-android-launch app.apk` — AOT-compile and launch
- `qos-android-install app.apk` — Install + dex2oat to cache
- `qos-android-launch com.example.app` — Launch installed app

## Comparison with ATL

| Aspect | ATL | Waydroid Runtime |
|---|---|---|
| Renderer | GTK4 (GtkGLArea/GtkDrawingArea) | Direct Wayland (wl_egl/wl_shm) |
| Windowing | GTK4 window | xdg-toplevel |
| API level | 9 (hardcoded) | 28+ (from AOSP source) |
| JNI coverage | ~30%, ad-hoc | Systematic, generated from AOSP |
| Error handling | Crash on missing JNI | Log + return default |
| ART | Alpine's art_standalone | Custom build from AOSP |
| JIT | Unclear | AOT (dex2oat) + JIT fallback |
| Audio | None | Stub → PipeWire |
| XWayland | Required (GDK_BACKEND=x11) | None (native Wayland) |
| App launch | Inherits Wayland FD or X11 | Standard Wayland client |

## Implementation Phases

### Phase 1: MVP — gles3jni Works
1. Build ART from AOSP for host architecture
2. Create minimal Wayland window (xdg_toplevel + wl_egl)
3. Load gles3jni APK: parse manifest, create Activity, run lifecycle
4. Route GLES calls through wl_egl → working rendering
5. ~1-2 weeks

### Phase 2: Canvas Support
1. Compile Skia from AOSP for desktop
2. Implement Canvas JNI stubs → Skia
3. wl_shm buffer transport for Canvas rendering
4. Test with GD, 2048
5. ~1-2 weeks

### Phase 3: Broader App Support
1. Implement no-crash trampolines for all remaining JNI stubs
2. Fix SurfaceView → wl_subsurface
3. Input handling via wl_seat
4. Test with Bomber, Taponium, Replica Island
5. ~2-3 weeks

### Phase 4: Complete API 28+ Coverage + Audio
1. Complete remaining API 28+ framework classes/stubs
2. Audio stub → PipeWire
3. Storage mapping
4. Multi-window (multiple activities)
5. ~2-4 weeks

## Open Questions

- How much of AOSP's native code (libandroid_runtime.so, libgui, libui) can we reuse vs rewrite?
- Can we use AOSP's external/skia directly, or does it need patching for standalone desktop use?
- How does ART's dex2oat perform on x86_64 vs ARM64 for AOT compilation?
- Do we need to patch ART to remove Android-specific assumptions (properties, mount points, SELinux)?
- Can we use musl (since QOS uses Alpine/musl) or do we need glibc for ART?

## Risks

- **ART on musl**: ART is designed for glibc/Bionic. Porting to musl may require significant patching. Alternative: use glibc in a minimal chroot or Alpine's gcompat.
- **AOSP framework complexity**: AOSP `frameworks/base` has deep dependencies on Binder, services, and HALs. Stripping these may be more work than expected.
- **Skia dependency chain**: Skia depends on fontconfig, freetype, harfbuzz, etc. Building for standalone use may require careful configuration.
- **ART source size**: AOSP's art module is ~1GB source. Full checkout is significantly larger. May need selective checkout (git sparse checkout).

## Appendix

### Key AOSP Source Paths

| Path | Contents |
|---|---|
| `art/` | ART runtime (libart.so, dex2oat, dex2oat) |
| `frameworks/base/core/java/` | Android framework Java source |
| `frameworks/base/core/jni/` | Framework JNI native methods |
| `frameworks/native/` | SurfaceFlinger, input, sensor services |
| `external/skia/` | Skia graphics library |
| `libnativehelper/` | JNI helper functions (JNIEnv helpers) |
| `system/core/` | libutils, libcutils, liblog |
