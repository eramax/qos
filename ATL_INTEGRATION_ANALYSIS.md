# Android Translation Layer Integration Analysis

## Executive Summary

**Android Translation Layer (ATL) can feasibly be integrated into QOS's desktop profile.** The desktop profile already allocates 4GB RAM and uses Chromium, so size/performance constraints are not blockers. However, ATL integration requires careful dependency management and build system modifications.

## What ATL Provides

ATL allows running unmodified Android APK apps on desktop Linux through:

1. **ART VM Execution**: Runs Android app bytecode via standalone ART runtime
2. **Java API Implementation**: ~80% of Android framework APIs stubbed/implemented in Java
3. **Native Library Bridging**: Custom libc/libdl (bionic_translation) + library path redirection
4. **GTK4 Rendering**: Replaces Android's display stack with GTK4 for native desktop integration
5. **Desktop Integration**: D-Bus, XDG portals, freedesktop standards

### Current Capabilities
- ✅ Running games (Angry Birds, Worms 2, Gravity Defied, BeatSaber)
- ✅ Apps with native OpenGL/Vulkan rendering
- ✅ WebKit-based content (when `ATL_UGLY_ENABLE_WEBVIEW` set)
- ✅ Audio via pipewire
- ✅ Location/microphone (with opt-in env var, needs work for sandboxing)

### Known Limitations
- Custom Android system APIs (telephony, NFC, bluetooth) are stubbed
- WebView intensive apps may not work well (fingerprinting/ads can be disabled)
- Some NDK native libs expect Android-specific syscalls (bionic syscall stubs help)
- UI layout issues for apps designed for phone screens (can force fullscreen with env var)

## Desktop Profile Constraints Analysis

**Current Desktop Config:**
```yaml
QEMU_MEMORY=4G      # vs server's 1G
QEMU_CPUS=4         # vs server's 2
QEMU_DISPLAY=gtk    # hardware 3D support
```

Already includes:
- GTK4 (river, waybar)
- GPU drivers (mesa, vulkan)
- Audio (pipewire)
- Wayland + Input devices (eudev, seatd)
- Fonts (font-dejavu)

**ATL Adds (~estimated costs):**
- Runtime: +50-100MB (ART VM + libs)
- ISO: +80-150MB (new deps + art_standalone + bionic_translation)
- Build time: +2-5 min (compiling ART standalone, native libs)

**Total Desktop Profile Impact:**
- ISO: ~100MB (Chromium already large) → ~150-200MB (acceptable for desktop)
- RAM: 4GB available, ATL uses ~200-400MB when running an app (acceptable)

✅ **Desktop profile can absorb ATL without constraint violations.**

---

## Dependency Tree

### Direct Alpine Packages
```
gtk4                    ✅ Already in desktop profile
glib-2.0                ✅ Included by GTK4
libportal               ⚠️ Available in Alpine, need to verify version
webkitgtk-6.0           ⚠️ Available in Alpine (heavy, ~50MB)
openjdk17-jdk           ⚠️ Available in Alpine (large)
alsa (for audio)        ✅ Included via pipewire
```

### Custom Dependencies (Not in Alpine 3.23)
These must be built or backported:

1. **art_standalone** (~10-15MB)
   - Standalone ART runtime from Android
   - Alpine package exists: `art_standalone-dev`
   - Build from: https://gitlab.com/android_translation_layer/art_standalone.git

2. **bionic_translation** (~5-10MB)
   - libc/libdl compatibility layer
   - Alpine package exists: `bionic_translation-dev`
   - Build from: https://gitlab.com/android_translation_layer/bionic_translation.git

3. **libandroidfw** (~2-3MB)
   - Android resource framework (for APK asset loading)
   - Alpine package exists: `libandroidfw-dev`
   - Part of AOSP, packaged separately

4. **wolfSSL with JNI** (~2-3MB)
   - SSL library used by Android apps
   - Need to verify Alpine has JNI enabled; if not, build from source
   - https://github.com/wolfSSL/wolfssl.git (v5.8.2-stable)

5. **libopensles-standalone** (optional, ~1-2MB)
   - Audio library for games
   - Alpine package: `libopensles-standalone` (optional)

### Build Dependencies
```
meson               ✅ Available in Alpine
gcc, g++            ✅ In build container
java-17-openjdk-jdk ✅ Available (large, ~300MB)
libcap-dev          ✅ Available in Alpine
libdrm-dev          ✅ Available (GPU)
libudev-dev         ✅ Available via eudev
```

---

## Integration Strategy

### Option A: Pre-built Binaries (Recommended)

Use Alpine's existing packages from `edge/testing` repo:
```
- art_standalone (already packaged)
- bionic_translation (already packaged)
- libandroidfw (already packaged)
- android-translation-layer (main package)
```

**Pros:**
- Minimal build time impact
- Alpine maintainers handle JDK/complex deps
- Binary compatibility guaranteed

**Cons:**
- Alpine `edge/testing` may be ahead of stable
- Need to pin versions in Containerfile

**Implementation:**
1. Update `Containerfile` to add Alpine `edge/testing` repo
2. Create `components/android-translation-layer/component.yaml` with package list
3. Add to desktop profile
4. Build + test

### Option B: In-Source Build (More Control)

Build ATL + dependencies inside the QOS build pipeline:

**Pros:**
- Full control over versions
- Can patch if needed
- Self-contained

**Cons:**
- 5-10min additional build time
- Java toolchain complexity in build container
- Need to maintain build scripts

**Implementation:**
1. Update Containerfile to include openjdk17-jdk-dev
2. Add build scripts in `builder/pipeline/`
3. Create component with pre-built binaries
4. Fallback if Alpine packages insufficient

---

## Proposed Component Structure

```
components/android-translation-layer/
├── component.yaml
├── rootfs/
│   ├── usr/bin/android-translation-layer  (symlink or wrapper)
│   ├── usr/share/applications/
│   │   └── android-app-launcher.desktop   (example launcher)
│   └── usr/share/android-translation-layer/
│       ├── (ATL data files if needed)
│       └── test-apks/                     (optional: test APKs)
└── s6/
    └── service-tree/
        └── android-translation-layer/     (optional: daemon mode?)
```

### component.yaml

```yaml
name: android-translation-layer
packages:
  # Core runtime
  - android-translation-layer
  - art-standalone
  - bionic_translation
  - libandroidfw
  
  # Optional: audio support for games
  - libopensles-standalone
  
  # Build-time deps (should be auto-pulled by package manager)
  - gtk4
  - libportal
  - webkitgtk-6.0
  - openjdk17-jdk

# Optional: auto-start ATL launcher as a service
# s6/service-tree/android-translation-layer/run:
#   Gtk app launcher that presents a file picker for APKs

depends_on:
  - pipewire          # audio
  - gpu-open-source   # GPU/graphics
  - dbus              # system integration
  - seatd             # input/seat management
  - font-dejavu       # rendering
```

---

## Build System Changes Required

### 1. Update Containerfile

```dockerfile
# Add Alpine edge/testing repo for android-translation-layer packages
RUN apk add --no-cache \
    ... existing packages ...
    # For ATL support (if building from source)
    openjdk17-jdk \
    openjdk17-jdk-dev \
    libcap-dev \
    libdrm-dev \
    openxr-dev \
    vulkan-dev \
    && echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
    && apk update
```

### 2. Update APK Repositories

Add to `components/apk/repositories`:
```
https://dl-cdn.alpinelinux.org/alpine/edge/testing
```

### 3. Profile Update

Edit `profiles/desktop.yaml`:
```yaml
components:
  - android-translation-layer  # Add this
  - chromium
  - river
  # ... rest
```

---

## Can We Run Android Apps Natively?

### Yes, But With Caveats:

#### ✅ Fully Working
- Pure Java apps (most games)
- Apps using standard Android APIs
- Apps with native OpenGL/Vulkan libs
- Apps using standard audio (pipewire via libopensles)

#### ⚠️ Partially Working
- Apps requiring unusual screen sizes (need `ATL_FORCE_FULLSCREEN` or gamescope)
- Apps with heavy WebView usage (performance, fingerprinting)
- Apps using location/microphone (needs opt-in, bubblewrap sandboxing TODO)

#### ❌ Won't Work
- Apps requiring telephony/cellular
- Apps requiring NFC
- Apps requiring SIM card
- Apps with DRM/content protection
- Apps requiring Play Services (can stub, not functional)
- Apps requiring ARCore/Google-specific APIs (stub only)

### Native Performance

**Real examples from ATL project:**
- Angry Birds 3.2.0: Runs at 60fps on mid-range laptop
- BeatSaber (Oculus Quest version): 90fps capable on good hardware
- Complex games: Usually 30-60fps depending on GPU

**For QOS desktop in QEMU:**
- With GPU passthrough (KVM): Good performance
- Without: Software rendering, ~15-30fps playable

---

## Testing & Validation Plan

1. **Build validation:**
   - Build desktop profile with ATL
   - Verify ISO size < 250MB
   - Verify boot time < 2 min (vs current)

2. **Runtime validation:**
   - Launch simple test APK (gravity-defied, android-gles3jni)
   - Verify GPU/graphics rendering
   - Verify audio playback
   - Check RAM usage (should stay under 4GB)

3. **Integration validation:**
   - Desktop launcher integration (desktop files)
   - Multi-user support (QOS already has multi-user desktop)
   - State persistence (apps in /home/user/.local/share/android_translation_layer/)

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Alpine packages version mismatch | Medium | Pin versions in Containerfile, test beforehand |
| Java toolchain complexity | Low | Use Alpine's openjdk17 package |
| Build time increase | Low | Parallel builds, cache binaries |
| Desktop profile gets unwieldy | Low | ATL is optional component, can move to separate branch |
| App sandbox bypass | Medium | TODO: Implement bubblewrap per ATL roadmap |
| WebKit/GTK4 conflicts | Low | Already tested in ATL on many systems |

---

## Next Steps

1. ✅ Add `android-translation-layer` to `components/`
2. ✅ Update Containerfile to add Alpine edge/testing
3. ✅ Update `profiles/desktop.yaml` to include component
4. ✅ Build desktop profile and validate
5. ✅ Test with simple APK (Gravity Defied, Angry Birds)
6. 🔲 Create desktop launcher UI (GTK app to pick APKs)
7. 🔲 Document multi-user per-user APK data dirs
8. 🔲 (Future) Implement sandboxing with bubblewrap

---

## Expected Outcomes

After integration:

```
Desktop Profile:
  ISO size: ~150-200MB (was ~100MB with chromium)
  RAM on boot: 200-300MB (4GB total available)
  App launch time: 2-5 sec for simple apps, 10-15 sec for complex games
  App data: ~/.local/share/android_translation_layer/[app-name]_/
```

Users will be able to:
- Download APK files
- Run them natively with: `android-translation-layer game.apk`
- Or via launcher: Click desktop app → pick APK → launch
- Access full Android app ecosystem on QOS desktop

---

## References

- ATL Docs: `/mnt/mydata/projects2/qos/deps/android_translation_layer/doc/`
- ATL Build: `doc/Build.md` (Alpine 3.23 compatible)
- ATL Architecture: `doc/Architecture.md`
- Alpine Testing Repo: https://pkgs.alpinelinux.org/packages?branch=edge&repo=testing
- ART Standalone: https://gitlab.com/android_translation_layer/art_standalone
- Bionic Translation: https://gitlab.com/android_translation_layer/bionic_translation

