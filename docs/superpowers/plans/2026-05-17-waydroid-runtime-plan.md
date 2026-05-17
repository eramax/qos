# Waydroid Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Wayland-native Android app runtime that embeds ART, implements AOSP framework JNI stubs, and renders apps on Wayland surfaces without GTK4/XWayland.

**Architecture:** C binary embedding libart.so (Android Runtime), loads APK via dex2oat AOT compilation, replaces AOSP's `libandroid_runtime.so` JNI stubs with Wayland-native implementations (wl_egl for GLES, wl_shm/wl_shm for Canvas), and creates xdg-toplevel windows per Activity.

**Tech Stack:** C11, libwayland-client, libwayland-egl, libEGL, libGLESv2, Skia, ART (libart.so), dex2oat, AOSP frameworks/base (Java + JNI), meson/ninja build

**Reference:** ATL source at `deps/android_translation_layer/` for ART initialization pattern. AOSP source at `deps/aosp/` for framework JNI stubs.

---

### Task 0: musl/glibc Compatibility Strategy

**Goal:** Resolve ART's glibc dependency on Alpine's musl system. ART is built for glibc/Bionic and will crash on musl without a compat layer.

**Context:** ATL solves this using `bionic_translation` — a musl-to-bionic compat shim that translates Android-specific libc calls (pthread, socket, file I/O). Our runtime has the same constraint: ART's `libart.so` expects glibc semantics.

**Options:**
- **A: gcompat** (`apk add gcompat`) — Alpine's glibc compatibility layer. Lightest option, but may miss some features ART needs.
- **B: bionic_translation** — what ATL uses. Proven to work with ART on Alpine. Provides `/usr/lib/java/dex/art/natives/ld-musl-x86_64.so.1` as the bionic->musl shim. Heavier but battle-tested.
- **C: glibc chroot** — full glibc environment. Heavy, defeats QOS minimalism.

**Decision:** Start with Option B (bionic_translation, same as ATL). The runtime binary is linked against `LD_LIBRARY_PATH=/usr/lib/java/dex/art/natives/:/usr/lib/art/` which provides the shim. This is already proven to work with `art_standalone` on Alpine.

**Files:**
- Create: `deps/qos-android-runtime/experiment/bionic_test.c` — test loading libart.so via bionic shim

- [ ] **Step 1: Verify bionic_translation is installed**

Run: `apk list --installed bionic_translation` — ensure the package is available.
Check: `ls /usr/lib/java/dex/art/natives/ld-musl-x86_64.so.1` — the musl->bionic shim.

- [ ] **Step 2: Write minimal test**

```c
// bionic_test.c — load libart.so through bionic LD path
#include <dlfcn.h>
#include <stdio.h>

int main() {
    // Must be run with BIONIC_LD_LIBRARY_PATH set
    void *libart = dlopen("libart.so", RTLD_NOW | RTLD_GLOBAL);
    if (!libart) {
        fprintf(stderr, "dlopen libart.so failed: %s\n", dlerror());
        fprintf(stderr, "Ensure BIONIC_LD_LIBRARY_PATH is set\n");
        return 1;
    }
    printf("libart.so loaded successfully via bionic shim\n");

    void *sym = dlsym(libart, "JNI_CreateJavaVM");
    printf("JNI_CreateJavaVM symbol: %p\n", sym);
    return 0;
}
```

- [ ] **Step 3: Build and test with bionic LD path**

```sh
gcc -o bionic_test bionic_test.c -ldl
BIONIC_LD_LIBRARY_PATH=/usr/lib/java/dex/art/natives/:/usr/lib/art/ \
  /usr/lib/java/dex/art/natives/ld-musl-x86_64.so.1 ./bionic_test
```

Expected: "libart.so loaded successfully via bionic shim" with a non-null symbol address.

- [ ] **Step 4: Verify JNI_CreateJavaVM works through bionic**

Extend test to call `JNI_CreateJavaVM` (same pattern as ATL's `main.c:83-143`). Pass minimal JVM options.

Expected: Returns 0 (success), JVM is created.

- [ ] **Step 5: Commit**

```bash
git add deps/qos-android-runtime/experiment/
git commit -m "experiment: ART loads through bionic_translation on musl"
```

---

### Task 1: Bootstrap ART Experiment

**Goal:** Get ART running standalone on Alpine — create a JVM, call JNI methods, prove the runtime works.

**Prerequisite:** Task 0 must be complete (bionic_translation working).

**Files:**
- Create: `deps/qos-android-runtime/experiment/art_test.c` — minimal C program that loads libart.so
- Create: `deps/qos-android-runtime/experiment/Makefile` — build for art_test
- Create: `deps/qos-android-runtime/experiment/HelloWorld.java` — simple Java class to test JNI

- [ ] **Step 1: Study how ATL calls JNI_CreateJavaVM**

Read `deps/android_translation_layer/src/main-executable/main.c` lines 83-143. ATL:
1. dlsyms `JNI_CreateJavaVM` from `libart.so` (loaded via LD_LIBRARY_PATH)
2. Constructs `JavaVMInitArgs` with classpath, library path, JNI version
3. Calls `JNI_CreateJavaVM(&jvm, (void**)&env, &args)`
4. Uses the returned `JNIEnv*` for all Android framework calls

Also study ATL's `create_vm()` — options include `-Djava.class.path=`, `-Djava.library.path=`, `-Xcheck:jni`, `-DBuild.VERSION.SDK_INT=N`.

- [ ] **Step 2: Write minimal art_test.c**

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>

typedef jint (*JNI_CreateJavaVM_t)(JavaVM**, void**, JavaVMInitArgs*);

int main(int argc, char** argv) {
    void* libart = dlopen("libart.so", RTLD_NOW | RTLD_GLOBAL);
    if (!libart) { fprintf(stderr, "dlopen libart.so: %s\n", dlerror()); return 1; }

    JNI_CreateJavaVM_t JNI_CreateJavaVM = dlsym(libart, "JNI_CreateJavaVM");
    if (!JNI_CreateJavaVM) { fprintf(stderr, "dlsym JNI_CreateJavaVM: %s\n", dlerror()); return 1; }

    JavaVM* jvm;
    JNIEnv* env;
    JavaVMInitArgs args = {
        .version = JNI_VERSION_1_6,
        .nOptions = 1,
    };
    JavaVMOption options[] = {
        { .optionString = "-Djava.class.path=/tmp/test" },
    };
    args.options = options;
    args.ignoreUnrecognized = JNI_FALSE;

    jint ret = JNI_CreateJavaVM(&jvm, (void**)&env, &args);
    if (ret < 0) { fprintf(stderr, "JNI_CreateJavaVM failed: %d\n", ret); return 1; }
    printf("JVM created successfully\n");

    jclass cls = (*env)->FindClass(env, "HelloWorld");
    if (!cls) { fprintf(stderr, "FindClass failed\n"); return 1; }

    jmethodID mainMethod = (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V");
    (*env)->CallStaticVoidMethod(env, cls, mainMethod, NULL);

    jvm->DestroyJavaVM(jvm);
    return 0;
}
```

- [ ] **Step 3: Write HelloWorld.java**

```java
public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello from ART!");
    }
}
```

- [ ] **Step 4: Build and run experiment**

Run: `mkdir -p /tmp/test && javac HelloWorld.java -d /tmp/test && make && ./art_test`
Expected: "JVM created successfully" and "Hello from ART!"

This proves ART can run standalone on Alpine with the right LD_LIBRARY_PATH.

- [ ] **Step 5: Test with Android framework classes**

Compile a minimal framework class (android.util.Log stub) and verify ART can load it.

Run: `./art_test`
Expected: Framework class loads, basic JNI works.

- [ ] **Step 6: Commit experiment**

```bash
git add deps/qos-android-runtime/experiment/
git commit -m "experiment: standalone ART bootstrap on Alpine"
```

---

### Task 2: Build ART from AOSP Source

**Goal:** Build ART (libart.so + dex2oat) from AOSP source with JIT enabled, dex2oat working, targeting Linux with minimal features.

**Why not Alpine's art_standalone:** The spec requires JIT, dex2oat, and custom initialization hooks. Alpine's package may disable these. Building from AOSP gives full control.

**Files:**
- Create: `deps/qos-android-runtime/build-art.sh` — script to configure and build ART
- Create: `deps/qos-android-runtime/Makefile` — top-level build orchestration

- [ ] **Step 1: Set up AOSP build environment**

AOSP uses Soong (Go-based build system). The approach:
1. Check out AOSP's `art/` module with dependencies
2. Use the existing AOSP source in `deps/aosp/art/` (already cloned shallow)
3. Extend the checkout with needed deps: `libnativehelper`, `system/core`, `external/icu`, `external/compiler-rt`
4. Set up Soong: install Go, configure build environment
5. Use `ART_TARGET_LINUX=true` for Linux host build
6. Use `TARGET_PRODUCT=mainline TARGET_BUILD_VARIANT=release`

Run: `cd deps/aosp/art && source build/envsetup.sh && lunch mainline-userdebug`

- [ ] **Step 2: Configure ART build flags**

Set flags in `art/build/art.go` or via environment:
- Enable JIT: default (needed for warmup-free execution)
- Enable dex2oat: default (needed for AOT compilation)
- Enable x86_64 and ARM64 backends: default
- Disable nativebridge: not needed (ARM→x86 translation)
- Disable adbconnection, perfetto: not needed

Target: `ART_TARGET_LINUX=true` produces `libart.so` that runs directly on Linux.

- [ ] **Step 3: Build libart.so**

```sh
cd deps/aosp/art
make libart -j$(nproc)
```

Expected: `out/host/linux-x86_64/lib64/libart.so` is produced.

- [ ] **Step 4: Build dex2oat**

```sh
make dex2oat -j$(nproc)
```

Expected: `out/host/linux-x86_64/bin/dex2oat` is produced.

- [ ] **Step 5: Verify JNI_CreateJavaVM exported**

Run: `nm -D out/host/linux-x86_64/lib64/libart.so | grep JNI_CreateJavaVM`
Expected: Symbol is exported.

- [ ] **Step 6: Verify dex2oat works**

Run: `out/host/linux-x86_64/bin/dex2oat --help`
Expected: Prints dex2oat usage.

- [ ] **Step 7: Package ART artifacts**

```sh
mkdir -p output/lib output/bin
cp out/host/linux-x86_64/lib64/libart.so output/lib/
cp out/host/linux-x86_64/bin/dex2oat output/bin/
strip output/lib/libart.so
```

- [ ] **Step 8: Commit**

```bash
git add deps/qos-android-runtime/
git commit -m "feat: build ART + dex2oat from AOSP"
```

---

### Task 3: Compile AOSP Framework Java to OAT

**Goal:** Compile a subset of `frameworks/base/core/java/android/` to DEX → OAT so ART can load framework classes.

**Files:**
- Create: `deps/qos-android-runtime/compile-framework.sh` — javac → d8 → dex2oat pipeline
- Create: `deps/qos-android-runtime/output/framework/` — output directory for .oat files

- [ ] **Step 1: Select minimal framework class subset**

Based on ATL's approach and AOSP source analysis, the minimal classes needed to launch an Activity:

```
android/os/*           (Build, SystemProperties, Process, Handler, Looper, Message)
android/app/Activity   (stub with lifecycle methods)
android/view/View      (stub for rendering surface)
android/graphics/Canvas (JNI stubs → Skia)
android/graphics/Paint
android/graphics/Bitmap
android/content/Context
android/content/res/Resources
```

Source at: `deps/aosp/base/core/java/android/`

- [ ] **Step 2: Write extract-framework.sh**

Script that copies selected Java source files from `deps/aosp/base/core/java/` to a flat work directory, keeping only the classes we need for MVP.

- [ ] **Step 3: Compile to DEX**

```sh
# Find all java sources
find framework-src/ -name "*.java" > sources.txt
# Compile to class files
javac -d build/classes -source 8 -target 8 @sources.txt
# Convert to DEX
d8 --release --output build/dex/ build/classes/**.class
```

- [ ] **Step 4: AOT compile to OAT**

```sh
dex2oat \
  --dex-file=build/dex/classes.dex \
  --oat-file=output/framework/boot.oat \
  --instruction-set=x86_64 \
  --compiler-filter=speed
```

- [ ] **Step 5: Verify OAT file**

Run: `oatdump --oat-file=output/framework/boot.oat`
Expected: OAT file contains compiled framework classes with OatMethodOffsets

- [ ] **Step 6: Load OAT in ART test**

Extend `art_test.c` from Task 1 to also load the boot.oat file. ART needs boot class path set via JVM options:

```c
options[0].optionString = "-Xbootclasspath:output/framework/boot.oat";
```

- [ ] **Step 7: Commit**

```bash
git add deps/qos-android-runtime/compile-framework.sh deps/qos-android-runtime/output/
git commit -m "feat: compile AOSP framework subset to OAT"
```

---

### Task 4: Wayland Window + Event Loop

**Goal:** Create the Wayland client skeleton that opens an xdg-toplevel window and runs the event loop.

**Files:**
- Create: `deps/qos-android-runtime/runtime/wayland.h` — Wayland client header
- Create: `deps/qos-android-runtime/runtime/wayland.c` — Wayland display, window, registry
- Create: `deps/qos-android-runtime/runtime/main.c` — Entry point (merge ART bootstrap + Wayland)
- Create: `deps/qos-android-runtime/runtime/meson.build` — Meson build definition

- [ ] **Step 1: Write wayland.h**

```c
#ifndef WAYDROID_WAYLAND_H
#define WAYDROID_WAYLAND_H

#include <wayland-client.h>
#include <wayland-egl.h>
#include <xdg-shell-client-protocol.h>

struct wd_window {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct xdg_wm_base *wm_base;
    struct wl_seat *seat;
    struct wl_shm *shm;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *xdg_toplevel;
    int width;
    int height;
};

struct wd_window* wd_window_create(int width, int height);
void wd_window_destroy(struct wd_window *win);
void wd_window_set_title(struct wd_window *win, const char *title);
int wd_dispatch_events(struct wd_window *win);
void wd_window_commit(struct wd_window *win);

#endif
```

- [ ] **Step 2: Write wayland.c — registry and globals**

Implement `registry_global_callback` to bind compositor, xdg_wm_base, seat, shm.
Implement `registry_global_remove_callback`.
Implement `xdg_wm_base_ping` handler.

- [ ] **Step 3: Write wayland.c — xdg-toplevel creation**

Create wl_surface → create xdg_surface → get xdg_toplevel.
Set app id and title. Handle configure/close callbacks.
Add `wl_surface_commit()` to show.

- [ ] **Step 4: Write wayland.c — event loop**

```c
int wd_dispatch_events(struct wd_window *win) {
    while (wl_display_dispatch(win->display) != -1) {
        // Events handled via registered listeners
    }
    return 0;
}
```

- [ ] **Step 5: Write main.c — integrate ART + Wayland**

```c
int main(int argc, char **argv) {
    // Parse args
    // Load ART (JNI_CreateJavaVM)
    // Create Wayland window
    struct wd_window *win = wd_window_create(960, 540);
    // Load APK via dex2oat
    // Create Activity, call lifecycle
    // Enter Wayland event loop
    wd_dispatch_events(win);
    return 0;
}
```

- [ ] **Step 6: Write meson.build**

```meson
project('waydroid', 'c', default_options: ['c_std=c11'])

wayland_client = dependency('wayland-client')
wayland_egl = dependency('wayland-egl')
egl = dependency('egl')
glesv2 = dependency('glesv2')

wayland_protocols = dependency('wayland-protocols')
wayland_scanner = find_program('wayland-scanner')

xdg_shell_xml = wayland_protocols.get_variable('pkgdatadir') + '/stable/xdg-shell/xdg-shell.xml'

xdg_shell_client_protocol_h = custom_target('xdg-shell-client-protocol-h',
    output: 'xdg-shell-client-protocol.h',
    input: xdg_shell_xml,
    command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'])

xdg_shell_client_protocol_c = custom_target('xdg-shell-client-protocol-c',
    output: 'xdg-shell-client-protocol.c',
    input: xdg_shell_xml,
    command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'])

executable('waydroid',
    'main.c', 'wayland.c',
    xdg_shell_client_protocol_h, xdg_shell_client_protocol_c,
    dependencies: [wayland_client, wayland_egl, egl, glesv2])
```

- [ ] **Step 7: Build and test the empty window**

```sh
cd deps/waydroid && meson setup build && ninja -C build
./build/waydroid
```

Expected: An empty Wayland window appears (960x540). Close button works.

- [ ] **Step 8: Commit**

```bash
git add deps/qos-android-runtime/runtime/
git commit -m "feat: Wayland window with xdg-toplevel"
```

---

### Task 5: JNI Stub Registration Framework

**Goal:** Create the skeleton `libandroid_runtime.so` that registers all 170 JNI stubs, each returning a safe default. This lets ART load framework classes without crashing.

**Files:**
- Create: `deps/qos-android-runtime/runtime/jni/` — directory for JNI stubs
- Create: `deps/qos-android-runtime/runtime/jni/generate_stubs.sh` — script to generate stub skeletons
- Create: `deps/qos-android-runtime/runtime/jni/android_runtime.c` — Central registration (replaces AndroidRuntime.cpp)
- Create: `deps/qos-android-runtime/runtime/jni/register_android_os_*.c` — stubs for each module
- Create: `deps/qos-android-runtime/runtime/jni/register_android_view_*.c`
- Create: `deps/qos-android-runtime/runtime/jni/register_android_graphics_*.c`
- Create: `deps/qos-android-runtime/runtime/jni/core_jni_helpers.h` — helper macros

- [ ] **Step 1: Write generate_stubs.sh**

Script that scans `deps/aosp/base/core/jni/` and `deps/aosp/base/libs/hwui/jni/` for all `register_android_*` functions in the `gRegJNI[]` table. For each:
1. Extract the function name (e.g., `register_android_os_SystemProperties`)
2. Determine the Java class (e.g., `android/os/SystemProperties`)
3. Determine return types from the registration call (parse JNI signature)
4. Generate a .c file with the registration function and default-returning stubs

```sh
# Parse AndroidRuntime.cpp's gRegJNI[] table
# Output: one .c file per registration function
```

- [ ] **Step 2: Write core_jni_helpers.h**

```c
#ifndef CORE_JNI_HELPERS_H
#define CORE_JNI_HELPERS_H

#include <jni.h>

// Log warning for unimplemented JNI
void log_unimplemented_jni(const char *method);

// Safe default return helpers
jboolean return_default_boolean();
jint return_default_int();
jfloat return_default_float();
jdouble return_default_double();
jobject return_null_object();

// Registration helper (wraps JNI RegisterNatives)
int RegisterMethodsOrDie(JNIEnv* env, const char* className,
                          const JNINativeMethod* methods, int numMethods);

// Find class helper
jclass FindClassOrDie(JNIEnv* env, const char* className);

// No-crash trampoline for unimplemented native methods
typedef jint (*TrampolineFn)();
jint trampoline_return_default();

#endif
```

- [ ] **Step 3: Write android_runtime.c — central registration**

Replicate the `gRegJNI[]` table from AOSP's `AndroidRuntime.cpp`:

```c
typedef int (*RegJNIProc)(JNIEnv*);

static const RegJNIProc gRegJNI[] = {
    register_android_os_SystemClock,
    register_android_os_SystemProperties,
    register_android_os_Binder,
    register_android_view_KeyEvent,
    register_android_view_MotionEvent,
    register_android_graphics_Canvas,
    // ... all 170 entries ...
};

int register_all_jni_stubs(JNIEnv* env) {
    for (size_t i = 0; i < sizeof(gRegJNI)/sizeof(gRegJNI[0]); i++) {
        if (gRegJNI[i](env) < 0) {
            fprintf(stderr, "Failed to register JNI stub #%zu\n", i);
        }
    }
    return 0;
}
```

- [ ] **Step 4: Write one module's stubs (e.g., android_os)**

```c
#include "core_jni_helpers.h"

// android/os/SystemProperties
static jstring native_get(JNIEnv* env, jclass, jstring key, jstring def) {
    log_unimplemented_jni("android.os.SystemProperties.native_get");
    return def;  // Return the default value
}

static const JNINativeMethod gSystemPropertiesMethods[] = {
    {"native_get",     "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", (void*)native_get},
    {"native_getInt",  "(Ljava/lang/String;I)I",                                   (void*)native_getInt},
    {"native_getLong", "(Ljava/lang/String;J)J",                                   (void*)native_getLong},
    {"native_getBoolean", "(Ljava/lang/String;Z)Z",                                (void*)native_getBoolean},
};

int register_android_os_SystemProperties(JNIEnv* env) {
    return RegisterMethodsOrDie(env, "android/os/SystemProperties",
                                 gSystemPropertiesMethods,
                                 sizeof(gSystemPropertiesMethods)/sizeof(gSystemPropertiesMethods[0]));
}
```

- [ ] **Step 5: Implement the no-crash trampoline**

For every JNI native method that we haven't explicitly implemented, register a trampoline instead of nothing. This prevents `UnsatisfiedLinkError`.

```c
// For generated stubs: wrap each unimplemented native method
static jint stub_trampoline_int(JNIEnv* env, jclass cls) {
    log_unimplemented_jni("stub_method_name");
    return 0;
}
```

- [ ] **Step 6: Generate all 170 registration .c files**

Run: `./generate_stubs.sh`
Expected: 170 .c files in `deps/qos-android-runtime/runtime/jni/stubs/`

- [ ] **Step 7: Build libandroid_runtime.so**

Add to `meson.build`:
```meson
shared_library('android_runtime',
    'jni/android_runtime.c',
    'jni/stubs/*.c',
    install: true)
```

- [ ] **Step 8: Test — load framework OAT with stubs**

Extend `art_test.c` to:
1. Create JVM with boot classpath pointing to framework OAT
2. Load our libandroid_runtime.so
3. Call `register_all_jni_stubs(env)`
4. Try loading an android.os class

Expected: Class loads without `UnsatisfiedLinkError`, stubs return defaults.

- [ ] **Step 9: Commit**

```bash
git add deps/qos-android-runtime/runtime/jni/
git commit -m "feat: JNI stub registration framework with no-crash trampolines"
```

---

### Task 6: GLES Rendering via wl_egl

**Goal:** Implement GLES JNI stubs that render to a wl_egl surface, enabling gles3jni to display frames.

**Files:**
- Create: `deps/qos-android-runtime/runtime/egl.h`
- Create: `deps/qos-android-runtime/runtime/egl.c` — EGL init, surface creation, swap buffers
- Modify: `deps/qos-android-runtime/runtime/jni/register_android_opengl_*.c` — GLES JNI stubs
- Modify: `deps/qos-android-runtime/runtime/main.c` — integrate rendering loop

- [ ] **Step 1: Write egl.h and egl.c**

```c
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>

struct wd_egl {
    struct wl_egl_window *wl_egl_window;
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
};

struct wd_egl* wd_egl_create(struct wd_window *win);
void wd_egl_destroy(struct wd_egl *egl);
void wd_egl_swap_buffers(struct wd_egl *egl);
```

- [ ] **Step 2: Write GLES JNI stubs (android.opengl.GLES20)**

From AOSP `core/jni/android_opengl_GLES20.cpp`:
- `glClear` → call `glClear` (desktop GL)
- `glClearColor` → call `glClearColor`
- `glDrawArrays` → call `glDrawArrays`
- `glCreateShader` → call `glCreateShader`
- etc.

Key insight: Desktop GL has the same function signatures as GLES for the subset gles3jni uses. The functions are identical. We just need to link against `libGLESv2.so` (desktop GLES translation).

```c
static void glClear(JNIEnv* env, jclass, jint mask) {
    glClear(mask);
}
```

- [ ] **Step 3: Add EGL init to main.c**

Before entering the Wayland event loop, create EGL context and make it current.

- [ ] **Step 4: Build and test with gles3jni**

```sh
./waydroid /usr/share/atl/apks/gles3jni.apk
```

Expected: Wayland window appears with gles3jni's rotating triangle rendering.

- [ ] **Step 5: Commit**

```bash
git add deps/qos-android-runtime/runtime/egl.c deps/qos-android-runtime/runtime/jni/android_opengl/
git commit -m "feat: GLES rendering via wl_egl, gles3jni works"
```

---

### Task 7: Wayland Input → Android Input Events

**Goal:** Map `wl_seat` events (pointer, keyboard) to Android `MotionEvent`/`KeyEvent` and deliver to the Activity.

**Files:**
- Create: `deps/qos-android-runtime/runtime/input.h`
- Create: `deps/qos-android-runtime/runtime/input.c` — wayland seat event handlers
- Modify: `deps/qos-android-runtime/runtime/wayland.c` — add seat listeners
- Modify: `deps/qos-android-runtime/runtime/jni/register_android_view_*.c` — input event stubs

- [ ] **Step 1: Write Wayland seat listener**

Register `wl_seat_listener` with pointer and keyboard handlers.

- [ ] **Step 2: Implement MotionEvent constructor JNI**

`android.view.MotionEvent.obtain()` → create a Java MotionEvent with our coordinates.

Key code maps:
```
BTN_LEFT → ACTION_DOWN (0), ACTION_UP (1)
Relative motion → ACTION_MOVE (2) with x/y
```

- [ ] **Step 3: Implement KeyEvent constructor JNI**

`android.view.KeyEvent.obtain()` → create Java KeyEvent.

Wayland keysym → Android keycode map (partial):
```
KEY_A → KEYCODE_A (29)
KEY_ESCAPE → KEYCODE_BACK (4)
KEY_ENTER → KEYCODE_ENTER (66)
```

- [ ] **Step 4: Deliver events to Activity**

Call `activity.dispatchTouchEvent()` or `activity.dispatchKeyEvent()` via JNI when Wayland input arrives.

- [ ] **Step 5: Test with gles3jni**

Touch/click the gles3jni window — the app should change color or respond.

- [ ] **Step 6: Commit**

```bash
git add deps/qos-android-runtime/runtime/input.c deps/qos-android-runtime/runtime/input.h
git commit -m "feat: Wayland input → Android MotionEvent/KeyEvent"
```

---

### Task 8: Activity Lifecycle + APK Loading

**Goal:** Parse an APK's AndroidManifest.xml, load the APK DEX via dex2oat, create the main Activity, and run its lifecycle.

**Files:**
- Create: `deps/qos-android-runtime/runtime/apk.h`
- Create: `deps/qos-android-runtime/runtime/apk.c` — APK zip parsing, manifest reader
- Create: `deps/qos-android-runtime/runtime/activity.h`
- Create: `deps/qos-android-runtime/runtime/activity.c` — Activity lifecycle management
- Modify: `deps/qos-android-runtime/runtime/main.c` — integrate APK loading + Activity launch

- [ ] **Step 1: Write minimal ZIP reader**

AndroidManifest.xml is stored (not compressed) in the APK zip. Parse the ZIP central directory to find and extract it.

OR use AOSP's `libziparchive` from `system/core/`. For MVP, use miniz or a simple ZIP parser.

- [ ] **Step 2: Parse AndroidManifest.xml**

AndroidManifest.xml is in AXML binary format (not plain XML). Parse the binary XML to extract:
- `package` name
- Main activity class (from `<activity android:name=...>` with `<intent-filter><action android:name="android.intent.action.MAIN"/></intent-filter>`)

OR: Just require the user to specify the activity class with `-l` flag (simpler for MVP).

- [ ] **Step 3: dex2oat the APK**

```c
void compile_apk(const char *apk_path, const char *oat_path) {
    char cmd[1024];
    snprintf(cmd, sizeof(cmd),
        "dex2oat --dex-file=%s --oat-file=%s --instruction-set=x86_64 --compiler-filter=speed",
        apk_path, oat_path);
    system(cmd);
}
```

- [ ] **Step 4: Load OAT + create Activity**

After compiling, load the OAT via ART and call:

```c
// Find main activity class
jclass activityClass = (*env)->FindClass(env, "com/example/MainActivity");
// Call static method (mimicking ATL's createMainActivity)
jobject activity = (*env)->CallStaticObjectMethod(env, activityClass,
    createMainActivity_method, activityClassName, (jlong)window, NULL);
// Start it
activity_start(env, activity);
```

- [ ] **Step 5: Lifecycle JNI (from ATL's api-impl)**

ATL provides `createMainActivity` in Java (`android/app/android_app_Activity.java`). We need a similar Java class that:
- Creates the Activity object
- Calls `onCreate()`, `onStart()`, `onResume()`, `onWindowFocusChanged()`

For MVP, sequence is:
```c
(*env)->CallVoidMethod(env, activity, onCreate_method, savedInstanceState);
(*env)->CallVoidMethod(env, activity, onStart_method);
(*env)->CallVoidMethod(env, activity, onResume_method);
```

- [ ] **Step 6: Test with gles3jni**

```sh
./waydroid /usr/share/atl/apks/gles3jni.apk
```

Expected: Wayland window appears with gles3jni rendering. Input works.

- [ ] **Step 7: Commit**

```bash
git add deps/qos-android-runtime/runtime/apk.c deps/qos-android-runtime/runtime/activity.c
git commit -m "feat: APK loading, dex2oat compilation, Activity lifecycle"
```

---

### Task 9: Canvas Rendering via Skia + wl_shm

**Goal:** Implement `android.graphics.Canvas` JNI stubs using Skia for CPU rasterization, displayed via `wl_shm` shared memory buffers.

**Files:**
- Create: `deps/qos-android-runtime/runtime/shm.h`
- Create: `deps/qos-android-runtime/runtime/shm.c` — wl_shm pool management, buffer creation
- Create: `deps/qos-android-runtime/runtime/skia_bridge.h`
- Create: `deps/qos-android-runtime/runtime/skia_bridge.c` — Canvas → Skia bridge
- Modify: `deps/qos-android-runtime/runtime/jni/register_android_graphics_*.c` — Canvas/Paint/Bitmap stubs
- Modify: `deps/qos-android-runtime/runtime/meson.build` — link libskia

- [ ] **Step 1: Write wl_shm buffer pool**

```c
struct wd_shm_pool* wd_shm_pool_create(struct wl_shm *shm, int size);
void wd_shm_pool_destroy(struct wd_shm_pool *pool);
struct wl_buffer* wd_shm_create_buffer(struct wd_shm_pool *pool, int width, int height);
```

- [ ] **Step 2: Implement Canvas JNI stubs (from hwui/jni/android_graphics_Canvas.cpp)**

Key stubs:
- `nInitRaster(bitmapHandle)` → create SkCanvas backed by SkBitmap
- `nDrawColor()` → `sk_canvas->drawColor()`
- `nDrawRect()` → `sk_canvas->drawRect()`
- `nDrawBitmap()` → `sk_canvas->drawImage()`
- `nSave()/nRestore()` → `sk_canvas->save()/restore()`
- `nTranslate()/nScale()/nRotate()` → sk_canvas->translate()/scale()/rotate()

```c
static void drawRect(JNIEnv* env, jclass, jlong canvasHandle,
                      jfloat left, jfloat top, jfloat right, jfloat bottom,
                      jlong paintHandle) {
    SkCanvas* canvas = reinterpret_cast<SkCanvas*>(canvasHandle);
    SkPaint* paint = reinterpret_cast<SkPaint*>(paintHandle);
    canvas->drawRect({left, top, right, bottom}, *paint);
}
```

- [ ] **Step 3: Implement Paint JNI stubs (from hwui/jni/Paint.cpp)**

- `nSetColor()` → `sk_paint->setColor()`
- `nSetStyle()` → `sk_paint->setStyle()`
- `nSetStrokeWidth()` → `sk_paint->setStrokeWidth()`
- `nSetAntiAlias()` → `sk_paint->setAntiAlias()`

- [ ] **Step 4: Implement Bitmap JNI stubs (from hwui/jni/Bitmap.cpp)**

- `nCreateBitmap()` → `SkBitmap::allocPixels()`
- `nGetColor()` → pixel access
- `nSetPixels()` → set pixel array

- [ ] **Step 5: Build Skia for standalone use**

From `deps/aosp/skia/`, use the GN build:

```sh
cd deps/aosp/skia
gn gen out/Static --args='is_official_build=true skia_use_egl=true skia_use_x11=false skia_use_wayland=false skia_use_fontconfig=true skia_use_system_libjpeg_turbo=true skia_use_system_libpng=true skia_use_system_zlib=true skia_use_system_icu=false skia_use_system_harfbuzz=true'
ninja -C out/Static
```

Alternatively for MVP: use Cairo instead of Skia (simpler build, same Canvas API coverage).

- [ ] **Step 6: Build and test with GD**

```sh
./waydroid /usr/share/atl/apks/gd.apk
```

Expected: GD renders its 2D graphics through Canvas → Skia → wl_shm.

- [ ] **Step 7: Build and test with 2048**

```sh
./waydroid /usr/share/atl/apks/2048.apk
```

Expected: 2048 renders its tile-based UI. (May fail on missing XmlBlock JNI.)

- [ ] **Step 8: Commit**

```bash
git add deps/qos-android-runtime/runtime/shm.c deps/qos-android-runtime/runtime/skia_bridge.c
git commit -m "feat: Canvas rendering via Skia + wl_shm"
```

---

### Task 10: MVP Integration

**Goal:** Wire everything together into a single binary that can launch an APK, run the Activity lifecycle, render via Wayland (both GLES and Canvas), and handle input.

**Files:**
- Modify: `deps/qos-android-runtime/runtime/main.c` — complete integration
- Create: `deps/qos-android-runtime/runtime/data_dir.c` — Android data directory management

```c
// Maps Android /data/data/<pkgname>/ to ~/.local/share/qos-android/<pkgname>/
// Context.getFilesDir() → returns this path
// Context.getCacheDir()  → returns <data_dir>/cache/
// Context.getExternalFilesDir() → same as getFilesDir (no separate sdcard)
//
// Directory structure:
//   ~/.local/share/qos-android/<pkgname>/
//   ├── lib/          # extracted native libs
//   ├── files/        # getFilesDir()
//   ├── cache/        # getCacheDir()
//   └── databases/    # getDatabasePath()
```
- Create: `deps/qos-android-runtime/build.sh` — full build script
- Create: `deps/qos-android-runtime/output/` — artifact layout

- [ ] **Step 1: Write build.sh**

```sh
#!/bin/sh
set -e
cd "$(dirname "$0")"

# 1. Build ART (or detect Alpine's art_standalone)
# 2. Compile framework Java → DEX → OAT
./compile-framework.sh

# 3. Build runtime binary
cd runtime
meson setup build --prefix=/usr
ninja -C build
```

- [ ] **Step 2: Write output layout**

```
output/
├── bin/waydroid               # Runtime binary
├── lib/
│   ├── libart.so              # ART runtime
│   ├── libandroid_runtime.so  # Our JNI stubs
│   ├── libwayland-client.so   # Wayland client lib
│   └── libskia.so             # Skia (for Canvas)
└── share/
    └── framework/
        └── boot.oat           # Pre-compiled framework
```

- [ ] **Step 3: Full MVP test**

```sh
# Build everything
./build.sh

# Test GLES app
./output/bin/waydroid /usr/share/atl/apks/gles3jni.apk

# Test Canvas app
./output/bin/waydroid /usr/share/atl/apks/gd.apk
```

- [ ] **Step 4: Measure and compare to ATL**

Metrics:
- Binary size (stripped)
- RAM usage at runtime
- Startup time (APK → visible frame)
- FPS for gles3jni

Compare with `atl-launch`.

- [ ] **Step 5: Commit**

```bash
git add deps/qos-android-runtime/build.sh deps/qos-android-runtime/output/
git commit -m "feat: MVP integration — single binary, Wayland rendering, ART bootstrap"
```

---

### Task 11: QOS Component Integration

**Goal:** Package the runtime as a QOS component so it integrates into the build pipeline and appears in QOS ISOs.

**Files:**
- Create: `components/qos-android-runtime/component.yaml` — component metadata
- Create: `components/qos-android-runtime/rootfs/usr/bin/qos-android-launch` — launcher shell script
- Create: `deps/qos-android-runtime/deploy.sh` — script to copy artifacts into component rootfs
- Modify: `profiles/desktop.yaml` — add qos-android-runtime component

- [ ] **Step 1: Write component.yaml**

```yaml
name: qos-android-runtime
packages:
  - wayland
  - wayland-client
  - seatd
  - mesa-egl
  - mesa-gles
  - bionic_translation
  - bionic_translation-dev
```

- [ ] **Step 2: Write qos-android-launch wrapper**

```sh
#!/bin/sh
# Launcher for the Waydroid Android runtime
# Sets up bionic linker + Wayland display and launches an APK

BIONIC_LD_LIBRARY_PATH=/usr/lib/java/dex/art/natives/:/usr/lib/art/
export BIONIC_LD_LIBRARY_PATH

# Use X11 backend only when not in a Wayland session (e.g. SSH)
if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -e "${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY}" ]; then
    GDK_BACKEND=x11
    DISPLAY=:0
    export GDK_BACKEND DISPLAY
fi

exec /usr/lib/qos-android/qos-android-run "$@"
```

- [ ] **Step 3: Write deploy.sh**

```sh
#!/bin/sh
# Copy build artifacts from deps/qos-android-runtime/output/ to component rootfs
COMPONENT_ROOT=components/qos-android-runtime/rootfs
BUILD_OUTPUT=deps/qos-android-runtime/output

mkdir -p $COMPONENT_ROOT/usr/lib/qos-android
mkdir -p $COMPONENT_ROOT/usr/share/qos-android/framework

cp $BUILD_OUTPUT/bin/qos-android-run $COMPONENT_ROOT/usr/lib/qos-android/
cp $BUILD_OUTPUT/lib/*.so $COMPONENT_ROOT/usr/lib/qos-android/
cp $BUILD_OUTPUT/share/framework/*.oat $COMPONENT_ROOT/usr/share/qos-android/framework/
```

- [ ] **Step 4: Add to desktop profile**

Add `- qos-android-runtime` to `profiles/desktop.yaml` components list.

- [ ] **Step 5: Build ISO and test**

```sh
make desktop
# Boot in QEMU
make live
# Inside VM:
qos-android-launch /usr/share/qos-android/apks/gles3jni.apk
```

Expected: ISO builds, gles3jni renders via Wayland inside the VM.

- [ ] **Step 6: Commit**

```bash
git add components/qos-android-runtime/ profiles/desktop.yaml
git commit -m "feat: QOS component integration for waydroid runtime"
```
