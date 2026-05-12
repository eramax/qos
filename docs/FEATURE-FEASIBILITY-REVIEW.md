# QOS Feature Feasibility Review

**Date:** May 12, 2026  
**Focus:** Technical feasibility of the newly proposed QOS feature set  
**Inputs reviewed:** `docs/FEATURE-REQUESTS-SUMMARY.md`, `docs/MASTER-IMPLEMENTATION-PLAN.md`, `docs/QOS-COMPLETE-BLUEPRINT.md`, current build and boot scripts

## 1. Executive Summary

The proposed direction is strongest where it extends the existing QOS architecture:

- Declarative build metadata
- Containerized builds
- Unified `qos` CLI
- RAM reduction through direct SquashFS boot
- dm-verity and stronger image integrity
- Workload profiles for `server`, `desktop`, `gaming`, and `k8s`

Those are technically realistic because the current repo already has:

- A working Alpine-based image pipeline
- `s6` / `s6-rc` service supervision
- Existing standalone operator tools such as `qos-capability`, `qos-cluster`, `qos-install`, and `qos-expand`
- A small enough shell codebase, about `5,393` lines across build, scripts, and tests, that is still practical to consolidate

The weakest part of the proposal is the Android/AOSP execution story. Running APKs as first-class host processes without containers or virtualization is not a normal distro feature. It is a separate platform project with very high integration and maintenance cost.

## 2. Current Baseline

The review needs to be anchored to the actual repo state, not only to the new docs.

### What exists today

- Imperative shell build pipeline via [`build.sh`](/mnt/mydata/projects2/qos/build.sh) and scripts under [`scripts/`](/mnt/mydata/projects2/qos/scripts/)
- Rootfs assembly from Alpine package lists in [`config/apk/packages.base`](/mnt/mydata/projects2/qos/config/apk/packages.base) and [`config/apk/packages.system`](/mnt/mydata/projects2/qos/config/apk/packages.system)
- Raw image assembly with GPT and A/B roots in [`scripts/assemble-image.sh`](/mnt/mydata/projects2/qos/scripts/assemble-image.sh)
- Live boot logic in [`config/initramfs/live-init.sh`](/mnt/mydata/projects2/qos/config/initramfs/live-init.sh)
- Service installation and command staging in [`scripts/install-services.sh`](/mnt/mydata/projects2/qos/scripts/install-services.sh)

### What the new docs assume, but the repo does not yet have

- `mkosi`-based image generation
- A single `qos.yaml` system manifest
- Unified `qos` CLI with subcommands replacing the standalone scripts
- Direct no-copy live boot
- dm-verity verification path
- Workload-profile-aware package and driver composition
- Any Android/AOSP runtime host integration

## 3. Feature-by-Feature Feasibility

### 3.1 Declarative Build Metadata and `qos.yaml`

**Feasibility:** High  
**Why:** The current build already consumes package manifests and layout metadata from files. Replacing multiple input files with one structured manifest is an incremental change, not a rewrite.

**What makes this practical**

- Package lists are already externalized.
- Partition layout already lives in JSON.
- Service installation already has a central staging step.

**Hidden work**

- Define a stable schema first.
- Decide whether the manifest is authoritative or generated.
- Add validation tooling before migrating all scripts.

**Implementation idea**

Start with `qos.yaml` as an input layer, not a runtime control plane. Use a generator to emit:

- package lists
- image layout data
- service enablement data
- workload-profile deltas

This avoids rewriting the build pipeline and the data model at the same time.

**Improvement**

Do not make `qos.yaml` too ambitious at first. Version it and keep v1 limited to:

- packages
- profiles
- enabled services
- image sizes

Avoid embedding every low-level tuning flag into the first schema.

### 3.2 Containerized Build Pipeline

**Feasibility:** High  
**Why:** The build is already a command-driven pipeline. Wrapping it in `podman run` or `docker run` is straightforward if filesystem layout and cache ownership are handled carefully.

**What makes this practical**

- The current build is already centralized through [`Makefile`](/mnt/mydata/projects2/qos/Makefile) and [`build.sh`](/mnt/mydata/projects2/qos/build.sh).
- Dependencies are shell-tool oriented, which containers handle well.

**Hidden work**

- UID/GID mapping for output ownership
- Cache persistence for Alpine indexes and kernel builds
- Device access rules if parts of the build assume loop or privileged operations

**Implementation idea**

Treat containerization as a transport layer first:

1. Build exactly the current pipeline inside a pinned container image.
2. Verify output parity with the host build.
3. Only then start changing build internals.

**Improvement**

Use containerization to freeze the environment, not to hide poor build contracts. Add a preflight script that verifies all inputs and writable paths before the build starts.

### 3.3 `mkosi` Migration

**Feasibility:** Medium  
**Why:** The idea is sound, but the current image assembly includes custom A/B, installer, and state-partition behavior that may not map cleanly to a first-pass `mkosi` migration.

**What makes this harder**

- Existing raw image logic is tightly coupled to the current partition layout.
- The project already has custom install and boot semantics.
- You likely need a transition period where custom scripts and `mkosi` coexist.

**Implementation idea**

Do not replace [`scripts/assemble-image.sh`](/mnt/mydata/projects2/qos/scripts/assemble-image.sh) immediately. First use `mkosi` only for rootfs production or for an alternate image target. Move full raw-image ownership later.

**Improvement**

Split the migration:

- Phase 1: manifest generation
- Phase 2: rootfs build parity
- Phase 3: partition/image parity
- Phase 4: installer/OTA parity

If `mkosi` fights the A/B design, keep a smaller custom image layer instead of forcing full adoption.

### 3.4 Unified `qos` CLI

**Feasibility:** High  
**Why:** The repo already has multiple commands that share shape and behavior. Consolidation is mostly an interface and library extraction exercise.

**What makes this practical**

- `qos-capability`
- `qos-cluster`
- `qos-install`
- `qos-expand`
- multiple test entry points

These are already user-facing operational tools and belong behind one entry point.

**Implementation idea**

Keep the initial implementation in shell. Build:

- `qos cap ...`
- `qos node ...`
- `qos install ...`
- `qos disk expand ...`
- `qos test ...`

Make old commands thin compatibility shims.

**Improvement**

Do not rewrite to Go or Rust immediately unless shell maintenance is already blocking progress. The first win is shared parsing, shared logging, and shared error handling. Language migration can come later if needed.

### 3.5 RAM Reduction to `<64MB` Server and `<256MB` Desktop

**Feasibility:** Mixed  
**Server target:** Medium to High  
**Desktop target:** Medium  
**Why:** The server target is plausible with direct SquashFS boot and tighter service/package choices. The desktop target is plausible only if the desktop profile is treated as a separate performance envelope, not as a tiny extension of the server profile.

**Current blocker**

[`config/initramfs/live-init.sh`](/mnt/mydata/projects2/qos/config/initramfs/live-init.sh) currently mounts a `256M` tmpfs at `/sysroot` and copies or extracts the live root into RAM. That directly conflicts with the no-copy RAM goals described in the new docs.

**Implementation idea**

Refactor live boot into two modes:

- `live-copy`: current behavior, kept as fallback
- `live-direct`: mount SquashFS read-only and layer writable state separately

This lets the team measure real RAM savings before deleting the existing path.

**Improvement**

Stop using one RAM target across all profiles. Publish profile-specific budgets:

- `server`: strict memory ceiling
- `desktop`: base desktop idle budget
- `gaming`: budget excluding game process RSS
- `k8s`: baseline plus control-plane overhead

Without that, the metrics will look good on paper but stay impossible to verify.

### 3.6 `mdev` Replacing `udev`

**Feasibility:** Medium  
**Why:** This helps a minimal server profile, but it becomes riskier once you add GPUs, proprietary drivers, hotplug complexity, and desktop/gaming expectations.

**Implementation idea**

Make device management profile-specific:

- `server`: `mdev`
- `desktop/gaming`: validate whether `mdev` is sufficient before removing `udev`

**Improvement**

Do not treat `mdev` as a universal replacement up front. First define the hardware matrix you actually intend to support. If the target is mainly QEMU, headless appliances, and a narrow desktop set, `mdev` may work. If broad laptop and gaming hardware are in scope, forcing `mdev` could create long-term driver support pain.

### 3.7 Workload Profiles: `server`, `desktop`, `gaming`, `k8s`

**Feasibility:** High  
**Why:** This is the most natural extension of the current project. Profiles can sit cleanly on top of a declarative manifest and package layering model.

**Implementation idea**

Model profiles as additive overlays:

- `server`: base
- `desktop`: base + GUI + graphics stack
- `gaming`: desktop + Steam/Proton + 32-bit libs + tuning
- `k8s`: server + k3s + container runtime + limits tuning

**Improvement**

Keep profiles composable but constrained. Avoid arbitrary profile combinations until dependency conflicts are formalized. `gaming + k8s + desktop + AOSP` should not be a v1 requirement.

### 3.8 Wayland-Only Desktop and XWayland for Legacy

**Feasibility:** Medium to High  
**Why:** This is technically aligned with a modern minimal distro, but it expands package complexity and driver validation significantly.

**Implementation idea**

Define a minimal desktop contract first:

- compositor
- seat/input stack
- graphics stack
- browser/webview host
- package/install/update path

Do not promise a full workstation until the basic shell is stable under QEMU and one or two real hardware targets.

**Improvement**

Choose one compositor and standardize around it. The proposal is too abstract unless it names the actual desktop session architecture.

### 3.9 Chromium-Based System WebView and `qos-webview`

**Feasibility:** Medium  
**Why:** A Chromium-based runtime is feasible, but calling it "Android-style system WebView" risks overstating what is actually being built. On Linux, the hard part is not embedding Chromium; it is packaging, updates, sandboxing, GPU compatibility, and keeping the footprint reasonable.

**Implementation idea**

Scope this as:

- packaged Chromium runtime
- a small wrapper for launching trusted local web apps
- a documented contract for app assets, permissions, and desktop integration

That is achievable. A full shared OS-level web app platform is much broader.

**Improvement**

Define whether `qos-webview` is:

- a launcher around installed Chromium
- a dedicated embedded runtime
- a compatibility layer for Tauri-style apps

The docs currently blur those options together.

### 3.10 Steam, Proton, 32-bit Isolation, GPU Drivers

**Feasibility:** Medium  
**Why:** This is achievable as a profile, but it is operationally heavy. The maintenance cost is not in the feature idea, it is in packaging and long-tail hardware validation.

**Implementation idea**

Build gaming support as a separately testable layer:

- driver bundle handling
- 32-bit userland packaging
- Steam/Proton package path
- profile-specific sysctl and scheduler tuning

**Improvement**

Do not over-optimize early with THP and `ananicy-cpp` before basic driver and Steam stability exist. Reliability beats clever tuning in the first iteration.

### 3.11 Native k3s / k9s Integration

**Feasibility:** Medium to High  
**Why:** This is much more realistic than the gaming and AOSP goals because the current project already leans toward appliance and cluster use cases.

**Implementation idea**

Make `k8s` a server-oriented profile with explicit minimum hardware requirements. Keep it out of the strict sub-64MB target.

**Improvement**

Separate "QOS can host k3s" from "k3s is part of the default image." The second choice increases image size, security surface, and upgrade complexity.

### 3.12 dm-verity, UKI, Secure Boot, KSPP Hardening

**Feasibility:** Medium to High  
**Why:** This is a good strategic direction and fits the project’s immutable image model, but it requires careful sequencing with the current boot chain and installer.

**Implementation idea**

Implement in order:

1. reproducible rootfs artifact identity
2. verity hash generation in build
3. boot-time verification
4. installer support
5. signed UKI / Secure Boot

**Improvement**

Do not try to land verity, UKI, and full Secure Boot in one milestone. The failure modes become hard to debug, especially while the image pipeline is also changing.

### 3.13 Native AOSP Execution Host

**Feasibility:** Very Low in near-term product scope  
**Why:** This is the least realistic feature in the current proposal.

The requirement says:

- Bionic, ART, and the AOSP linker compiled into QOS
- APKs as first-class Linux host processes
- Android system services as `s6` services
- direct Wayland rendering
- no containers, no subsystem, no emulation

That is not a normal distro enhancement. It is effectively a custom Android compatibility platform.

**Major risks**

- Android framework/service dependencies are far deeper than libc and ART alone.
- App compatibility depends on Binder, SELinux assumptions, graphics/input plumbing, packaging, permissions, lifecycle handling, and framework APIs.
- Ongoing maintenance will track both Alpine and AOSP moving targets.

**Implementation idea**

Do not present this as part of the main distro roadmap. Re-scope it as a research track with explicit go/no-go checkpoints:

1. prove Bionic and Binder integration on QOS
2. prove one trivial APK launch path
3. prove graphics/input lifecycle
4. only then discuss productization

**Improvement**

If the product goal is "run Android apps," compare simpler options first:

- containerized Android runtime
- VM-backed Android integration
- app streaming or remote execution

Those may violate the original purity goal, but they are far more likely to ship.

## 4. What Should Be Built First

The current docs group many good ideas together, but they should not move in parallel at equal priority.

### Recommended order

1. `qos.yaml` schema and generator
2. containerized build parity
3. unified `qos` CLI with compatibility shims
4. direct SquashFS live boot and RAM measurement
5. workload profiles
6. dm-verity integration
7. desktop/gaming profile validation
8. k8s profile packaging
9. AOSP research track, if still desired

This order keeps the project grounded in its existing strengths:

- small image engineering
- service supervision
- appliance-style boot model
- operational tooling

## 5. Key Gaps in the New Feature Docs

The new docs are directionally strong, but they need tighter engineering definitions.

### Missing or under-specified areas

- Concrete hardware support matrix
- Profile-specific RAM and storage budgets
- Definition of "desktop" session architecture
- Driver sourcing and update model for NVIDIA/AMD
- Exact boundary between base image and optional overlays
- Update strategy for Chromium and GPU-heavy profiles
- Verification criteria for each milestone
- Explicit decision on whether `mkosi` replaces or complements current A/B image logic

## 6. Recommended Improvements to the Proposal

### Improvement 1: Split roadmap into product track vs research track

**Product track**

- declarative build
- unified CLI
- RAM reduction
- workload profiles
- dm-verity
- desktop/gaming/k8s as constrained profiles

**Research track**

- native AOSP execution
- novel system webview platform ambitions beyond a wrapper/runtime

### Improvement 2: Define measurable acceptance criteria

Every feature should have one hard acceptance test. Example:

- `server` profile cold boot RSS budget
- `desktop` profile idle memory budget
- `qos build` output reproducibility
- `qos install` compatibility after CLI unification
- verity failure path test

### Improvement 3: Preserve compatibility while consolidating

When introducing `qos`, keep:

- `qos-capability`
- `qos-cluster`
- `qos-install`
- `qos-expand`

as wrappers during the migration. That reduces operational breakage and documentation churn.

### Improvement 4: Treat profiles as release artifacts

Instead of one image trying to be everything, consider producing:

- `qos-server`
- `qos-desktop`
- `qos-gaming`
- `qos-k8s`

from the same manifest model. This is easier to test and easier to explain.

### Improvement 5: Make RAM optimization evidence-driven

The current docs cite aggressive memory targets. Add automated memory measurement in QEMU and publish results per profile before locking the targets into the roadmap.

## 7. Final Assessment

### Realistic and worth doing now

- declarative manifest
- containerized builds
- unified `qos` CLI
- direct SquashFS boot
- workload profiles
- dm-verity and boot integrity improvements

### Realistic, but should be phased carefully

- `mkosi`
- Wayland desktop
- gaming profile
- k3s profile
- `mdev` transition

### Not realistic as a near-term delivery commitment

- native AOSP execution host as currently described

## 8. Recommendation

QOS should narrow the current feature proposal into a disciplined feasibility roadmap:

- build-system modernization first
- profile-driven productization second
- integrity hardening third
- desktop/gaming expansion after build and boot architecture stabilize
- Android compatibility only as an explicitly separate research effort

That path preserves what is already good in the repo and avoids turning a focused minimal distro into an unbounded platform rewrite.
