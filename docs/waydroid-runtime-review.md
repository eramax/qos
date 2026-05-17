# Waydroid Runtime: Comprehensive Design & Plan Review

**Reviewed:** 2026-05-17
**Documents:** `waydroid-runtime-design.md`, `waydroid-runtime-plan.md`

---

## Executive Summary

The Waydroid Runtime project is a well-scoped, technically ambitious endeavour to replace ATL's GTK4/XWayland-based Android runtime with a lean, Wayland-native alternative built on ART. The design doc is coherent and the implementation plan is detailed. Both documents are largely aligned. The core architectural choices — direct Wayland clients, ART from AOSP source, systematic JNI stub generation — are sound and defensible.

That said, several areas carry significant underestimated risk: ART on musl/Alpine is the hardest technical blocker and deserves more contingency planning, the AOSP framework subset is likely much larger than described, and the timeline estimates are optimistic relative to the scope. This review calls out these gaps and provides concrete recommendations.

---

## Architecture Assessment

### Strengths

The architecture diagram cleanly separates concerns: APK → dex2oat → OAT, the ART runtime in the middle, `libandroid_runtime.so` as the bridge, and three Wayland backends (`wl_egl`, `wl_shm`, `wl_seat`) for rendering and input. This layering is the right approach.

Key architectural decisions are sound:

- **ART instead of JVM**: Correct. DEX-native execution with dex2oat AOT avoids the DEX→JAR friction entirely and gives the same performance profile as stock Android.
- **No Binder, no system services**: The "simplified in-process" lifecycle (no `ActivityManagerService`, no `WindowManagerService`) is the right call for a single-app runner. It radically reduces scope.
- **Stub-first JNI strategy**: Generating no-crash trampolines from the AOSP `gRegJNI[]` table is exactly how ATL and similar projects bootstrap. Logging + returning defaults is better than `UnsatisfiedLinkError`.
- **Direct `libwayland-client`**: Avoiding GTK4 removes ~100MB of transitive dependencies and eliminates the XWayland fallback requirement. This is the key architectural win over ATL.

### Concerns

**Dual rendering paths (wl_egl vs. wl_shm) add complexity from day 1.** Most non-trivial apps use a mix: a Canvas-based UI layer (wl_shm → Skia) with an embedded GLES `SurfaceView` (wl_egl). This implies `wl_subsurface` support will be needed earlier than Phase 3 suggests. The design mentions it only as a Phase 3 item but it is almost certainly required for Phase 2 apps (GD, 2048 likely use it).

**The `libandroid_runtime.so` boundary is underspecified.** The design doc lists `~170 JNI stubs`, but AOSP's `AndroidRuntime.cpp` `gRegJNI[]` table has closer to 250+ entries as of API 28, and many stubs have multiple native methods each. The actual stub count (individual `JNINativeMethod` registrations) is in the thousands. The plan treats this as a code-generation problem, which is correct, but the 170-stub figure underestimates total scope.

**No mention of `ViewRootImpl` / `Choreographer` threading model.** Android apps assume a Looper/Handler message queue on the main thread, with `Choreographer` driving vsync. Without a vsync signal from the Wayland compositor (`wl_callback` frame callbacks), apps will either spin-poll or stall. This threading model needs to be addressed before Task 6 (GLES rendering).

---

## Design Decisions: Analysis

### musl/glibc Compatibility (Task 0)

This is the **highest-risk item** in the entire project and the plan gives it appropriate early priority. The decision to use `bionic_translation` (Option B) is correct — it is proven by ATL.

However, the plan is optimistic about how clean this will be:

- `bionic_translation` translates `pthread_*`, socket, and basic file I/O. ART also uses `__libc_init`, `__register_atfork`, and glibc-specific TLS initialisation that `bionic_translation` may not cover fully.
- Building ART from AOSP source (Task 2) on a musl Alpine host means the AOSP build system (`Soong`) also runs on musl. Soong is written in Go, which is musl-compatible, but the host build toolchain (Clang, lld) from AOSP assumes glibc headers for the host. You may need a separate glibc-based cross-compilation environment.

**Recommendation:** Add a contingency step: if `bionic_translation` is insufficient for source-built ART, fall back to building ART inside a minimal glibc container (e.g. `distrobox` with Debian), then extracting the `.so` artifacts for use on Alpine. Keep the runtime itself (C binary + Wayland client) as a musl-native binary.

### Building ART from AOSP Source (Task 2)

The rationale is solid: JIT enabled, dex2oat working, custom hooks. But there are practical complications not addressed:

- **AOSP's build system dependency**: `lunch mainline-userdebug` assumes a full AOSP workspace. The `art/` module has ~40 transitive Soong dependencies (`libnativehelper`, `libdex`, `libartbase`, `libprofile`, `libartpalette`, `external/icu`, `external/libunwind`, etc.). A sparse checkout strategy is needed and the plan doesn't detail which modules to include.
- **Build time**: On a typical dev machine, building just `libart.so` + `dex2oat` from AOSP takes 30–60 minutes with a warm cache, 2–4 hours cold. The plan's timeline should account for this.
- **Host vs. target ART**: AOSP's `ART_TARGET_LINUX=true` produces a host-arch binary (x86_64 on an x86_64 machine). ARM64 cross-compilation on x86_64 host is a separate build configuration. The plan should clarify whether ARM64 support is in scope for the MVP.

**Recommendation:** Enumerate the exact AOSP modules needed in a `sparse-checkout.sh` script as part of Task 2, Step 1. This is critical path and should not be discovered ad hoc.

### Framework Java Compilation (Task 3)

The minimal class subset listed is reasonable for a smoke test, but almost certainly insufficient for any real app:

```
android/os/*
android/app/Activity
android/view/View
android/graphics/Canvas, Paint, Bitmap
android/content/Context, res/Resources
```

**Missing classes that real apps will immediately hit:**
- `android/view/ViewGroup`, `LayoutInflater`, `ViewTreeObserver`
- `android/util/AttributeSet`, `TypedArray` (used by every custom View)
- `android/graphics/drawable/Drawable`, `ColorDrawable`, `BitmapDrawable`
- `android/os/Bundle`, `Parcel`, `Parcelable` (required by `Activity.onCreate`)
- `android/content/res/AssetManager` (required for loading resources from APK)
- `android/widget/TextView`, `ImageView` (required by virtually all apps)

The "minimal subset" approach works for `gles3jni` (which bypasses the View system entirely). For any Canvas app (GD, 2048), you need a much larger slice. The safer strategy is to compile the entire `frameworks/base/core/java/android/` tree as a single DEX, which is what ATL does via the AOSP build. The selective compilation approach risks spending more time debugging `ClassNotFoundException` than it saves.

**Recommendation:** Compile the full `android.jar` subset from AOSP's `frameworks/base` in Task 3 rather than a manually curated list. Use AOSP's `make framework` target to produce a correct, self-consistent framework DEX.

### JNI Stub Generation (Task 5)

The approach is correct and the `gRegJNI[]` scanning strategy is the right implementation. A few notes:

- The `generate_stubs.sh` script needs to handle JNI methods with variable argument counts and struct/pointer return types (e.g., `jlong` handles for native objects). The naive stub generator may emit incorrect C types. Consider using `clang`'s `-ast-dump` on the AOSP JNI `.cpp` files to extract method signatures accurately rather than shell-script parsing.
- Methods returning `jlong` (native handles) are particularly common in graphics (`Canvas`, `Paint`, `Bitmap`, `Path`, `Shader`). Returning `0` (null handle) for these will cause immediate NPE in Java code that uses the handle. For these, allocate a minimal struct on the heap and return its address.

**Recommendation:** Classify stubs into three tiers in the generator: (1) returns primitive → return 0/false/null, (2) returns `jlong` handle → allocate minimal sentinel struct, (3) creates JVM objects (`jstring`, `jarray`) → return `null`. Tier (2) is the critical difference between a crash and a no-op.

---

## Implementation Plan Review

### Task Ordering

The task ordering is logical and has no circular dependencies. The dependency chain is:

```
Task 0 (musl) → Task 1 (ART bootstrap) → Task 2 (build ART)
                                        → Task 3 (framework OAT)
Task 4 (Wayland window) ────────────────────────────────────▶ Task 6 (GLES)
Task 5 (JNI stubs) ──────────────────────────────────────▶ Task 6, 7, 8
Task 6 + 7 + 8 ──────────────────────────────────────────▶ Task 9 (Canvas)
All ──────────────────────────────────────────────────────▶ Task 10 (MVP)
Task 10 ──────────────────────────────────────────────────▶ Task 11 (QOS)
```

One ordering issue: **Task 7 (input) is listed after Task 6 (GLES)**, but input is needed to validate Task 6 interactively. Consider merging basic pointer/keyboard input into Task 6 so `gles3jni` can be tested with touch interaction.

### Missing Tasks

The following are absent from the plan but are required for the MVP target:

| Missing Item | Needed For | Suggested Task |
|---|---|---|
| `Choreographer` / vsync loop | Any animated app (gles3jni) | Task 4b |
| `Looper` / `Handler` main thread model | Activity lifecycle, View rendering | Task 5b |
| `AssetManager` JNI (APK resource loading) | Any app using `R.layout`, `R.string` | Task 8b |
| `SurfaceView` → `wl_subsurface` | Apps with embedded GLES views | Task 6b |
| `XmlBlock` / resource parser | Layout inflation | Task 8b |
| `dex2oat` caching (skip recompile) | Developer UX | Task 10b |

### Timeline Estimates

The design doc's phase estimates are:

| Phase | Design Estimate | Revised Estimate |
|---|---|---|
| Phase 1: gles3jni MVP | 1–2 weeks | 3–5 weeks |
| Phase 2: Canvas support | 1–2 weeks | 2–3 weeks |
| Phase 3: Broader app support | 2–3 weeks | 3–5 weeks |
| Phase 4: Full API 28+ coverage | 2–4 weeks | 4–8 weeks |

The original estimates assume ART builds cleanly and the framework compiles without surprises. In practice, Tasks 0–3 (the ART + musl + framework foundation) are likely to take the entire Phase 1 budget on their own, leaving the Wayland window and JNI stubs for subsequent weeks.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ART fails to build on Alpine musl | High | Blocker | Use glibc build container; extract `.so` artifacts |
| AOSP `frameworks/base` has too many undeclared deps to compile minimally | High | High | Use full `make framework` from AOSP rather than manual subset |
| JNI handle stubs cause NPE cascade (non-primitive returns) | Medium | High | Classify stubs by return type; allocate sentinel structs for `jlong` handles |
| `Choreographer`/`Looper` absent causes render hangs | Medium | High | Implement minimal `Looper` + `wl_callback` vsync before Task 6 |
| Skia standalone build fails (GN config issues) | Medium | Medium | Fall back to Cairo for MVP Canvas path |
| AOSP sparse checkout too large / incomplete | Medium | Medium | Pre-define module list; script it in Task 2 |
| `wl_subsurface` needed earlier than Phase 3 | Medium | Medium | Add `wl_subcompositor` binding in Task 4 even if unused |
| ARM64 host-build differs from x86_64 | Low | Medium | Scope MVP to x86_64 only; ARM64 in Phase 4 |

---

## Code Quality Observations

### Plan Code Snippets

The C code in the plan is generally correct and idiomatically C11. Specific notes:

- `art_test.c` (Task 1): The `CallStaticVoidMethod` call with `NULL` as the String array argument will cause a NullPointerException in ART for any `main(String[] args)` that actually dereferences args. Pass an empty `jarray` instead: `(*env)->NewObjectArray(env, 0, (*env)->FindClass(env, "java/lang/String"), NULL)`.
- `wayland.c` event loop (Task 4): The `while (wl_display_dispatch(...) != -1)` loop is correct for blocking dispatch. Consider using `wl_display_dispatch_pending()` + `wl_display_flush()` in a select/poll loop to interleave ART-side work (garbage collection, JIT compilation) without blocking Wayland dispatch.
- `android_runtime.c` (Task 5): The `gRegJNI[]` table and `register_all_jni_stubs()` pattern is exactly how AOSP does it. Good.
- Task 8's `system(cmd)` for `dex2oat`: Use `execve` or `posix_spawn` instead. `system()` invokes `/bin/sh`, which is fragile with paths containing spaces and has security implications.

### Meson Build

The `meson.build` in Task 4 is well-structured. Additional notes:
- Add `'-Wall'`, `'-Wextra'`, `'-Werror=implicit-function-declaration'` to `default_options` to catch JNI type mismatches early.
- The `wayland-protocols` `pkgdatadir` path lookup will work on most distros but may need a fallback for Alpine. Test with `pkg-config --variable=pkgdatadir wayland-protocols`.

---

## Design Document Observations

### What the Design Doc Does Well

- The ATL comparison table is excellent. It clearly communicates the value proposition (no XWayland, API 28+ vs. API 9, systematic stubs vs. ad-hoc).
- The system services stub table is pragmatic and honest about what is deferred.
- The "open questions" section is good engineering practice and correctly identifies the musl, Skia, and ART patching questions as the key unknowns.
- The project structure is clean and the directory layout will survive growth.

### Gaps in the Design Doc

- **No mention of multi-threading.** The ART + Wayland integration requires careful thread ownership: ART's GC and JIT run on background threads; Wayland events must be dispatched on the main thread; EGL contexts are thread-local. A threading model section is needed before implementation begins.
- **No mention of SELinux / seccomp.** ART on a real Android device runs with SELinux enforcement. On Linux, this is not a concern, but ART may still attempt to call `setcon()`, `selinux_check_access()`, or similar syscalls that might not exist or fail silently. Add a `ptrace`/`strace` verification step to Task 1.
- **Resource loading is absent from the architecture.** The diagram and text do not mention how `android.content.res.AssetManager` maps APK resources (`.arsc` resource tables, XML layouts, drawables) to in-memory objects. This is a significant subsystem required for any non-trivial app.
- **No error propagation strategy.** When a stub returns a wrong value (e.g., a null `Context`) and the app crashes, the stack trace will be inside ART's JVM, making it hard to correlate with C-side stub activity. A structured logging approach (stub name + caller class) should be specified.

---

## Alignment Between Design and Plan

The two documents are well-aligned. Every architectural component in the design has a corresponding task in the plan. The task sequence matches the phased approach described in the design's "Implementation Phases" section.

One misalignment: the design's Phase 1 ("gles3jni works") implies Tasks 0–6 must all complete. The plan labels Task 10 as "MVP Integration," which conflates Phase 1 completion. The plan would benefit from marking a clear "Phase 1 gate" checkpoint at the end of Task 6 to separate the GLES milestone from the full MVP.

---

## Recommendations Summary

1. **Add a `bionic_translation` failure contingency** (glibc container build for ART, musl runtime binary). Document this as an alternative path in Task 0.

2. **Replace the manual framework class list** in Task 3 with a full `make framework` from AOSP to avoid ClassNotFoundException rabbit holes.

3. **Add a Task 4b: Looper + Choreographer stub** before Task 6. Implement a minimal `android.os.Looper` message pump that integrates with the Wayland `wl_callback` vsync signal.

4. **Classify JNI stubs by return type** in `generate_stubs.sh`. Allocate sentinel structs for `jlong`-returning handle methods to avoid NPE cascades.

5. **Use `posix_spawn` instead of `system()`** for `dex2oat` invocation in Task 8.

6. **Add a threading model section** to the design doc before implementation. Define: which thread owns the Wayland event loop, which thread runs the JVM main (Looper), and how EGL context is shared or isolated.

7. **Document AOSP sparse checkout module list** as part of Task 2, Step 1. This is critical path.

8. **Mark a Phase 1 gate** explicitly in the plan (e.g., after Task 6) to separate the gles3jni milestone from full MVP.

9. **Add `AssetManager` and resource loading** to the design's architecture section and create a corresponding task (between Task 8 and Task 10).

10. **Update timeline estimates** to reflect the ART/musl foundation risk: budget 3–5 weeks for Tasks 0–3 alone.

---

## Conclusion

This is a serious, well-researched project with a strong architectural foundation. The core ideas — ART on Linux, direct Wayland rendering, systematic JNI stub generation — are proven approaches (ATL, Anbox, and Waydroid all use variants of them) and the plan to build from AOSP source rather than depend on a packaged binary gives the right degree of control.

The main failure modes to guard against are: (1) the musl/ART compatibility layer being more work than estimated, stalling Tasks 0–2 for weeks; (2) the "minimal framework subset" approach forcing repeated debugging of missing classes; and (3) the absence of a Looper/Choreographer/vsync model causing subtle animation and lifecycle bugs that are hard to diagnose.

Address these three risks explicitly before committing to the Phase 1 timeline and the plan becomes a credible 8–10 week execution roadmap for the MVP.
