# QOS Feature Review & Implementation Ideas

**Date:** 2026-05-12
**Scope:** Review of the new feature requests added under `docs/` and concrete
ideas for how to land them on top of the existing repo (Alpine-based,
s6/s6-rc, Limine, virtio, A/B image layout).
**Source docs reviewed:**
`FEATURE-REQUESTS-SUMMARY.md`, `RAM-MINIMIZATION-GUIDE.md`,
`WORKLOAD-PROFILES-GUI-GAMING-K8S.md`, `NATIVE-AOSP-EXECUTION.md`,
`OPTIMIZATION-AND-TUNING.md`, `LOC-REDUCTION-PLAN.md`,
`MODERNIZATION-AND-REFACTORING-GUIDE.md`, `MASTER-IMPLEMENTATION-PLAN.md`,
`PROJECT-REVIEW-2026.md`, `QOS-COMPLETE-BLUEPRINT.md`.

This is a companion to `FEATURE-FEASIBILITY-REVIEW.md`. That doc answers
"can we do it?". This one answers "*how* should we do it, and what would
make it actually good?".

---

## 0. TL;DR

| Feature                              | Verdict        | Effort | Risk   | Recommend |
| ------------------------------------ | -------------- | ------ | ------ | --------- |
| `qos.yaml` unified manifest          | Strong fit     | M      | Low    | Yes, phased |
| Unified `qos` CLI                    | Strong fit     | M      | Low    | Yes |
| Direct SquashFS boot (no copytoram)  | Strong fit     | S      | Low    | Yes, early win |
| Modular kernel + mdev probe          | Strong fit     | M      | Med    | Yes |
| mdev replacing eudev                 | Conditional    | S      | Med    | Yes for server, keep eudev option for desktop |
| Workload profiles (server/desk/game/k8s) | Strong fit | M      | Low    | Yes |
| Wayland-only + WebView               | Reasonable     | L      | Med    | Yes, but as add-on layer |
| Steam + 32-bit overlay               | Reasonable     | M      | Med    | Yes |
| k3s/k9s integration                  | Strong fit     | S      | Low    | Yes |
| Podman + mkosi build                 | Strong fit     | M      | Low    | Yes, but keep current pipeline until parity |
| dm-verity verified boot              | Strong fit     | M      | Med    | Yes, pairs naturally with A/B |
| KSPP / Secure Boot signing           | Strong fit     | M      | Med    | Yes |
| **Native AOSP execution host**       | **Out of scope as written** | XXL | Very high | **Reframe**: target Waydroid-style first, treat "no container" goal as a stretch research effort |

---

## 1. Cross-Cutting Comments

A few observations that touch all features before getting into specifics:

- **The numeric targets need to be split.** "<64MB RAM" is realistic for a
  headless server image; it is not realistic for a Wayland desktop with
  Chromium WebView, regardless of optimization. Calling out a separate
  desktop target (the doc already hints at <256MB) and treating gaming as
  yet another tier avoids one document silently contradicting another.

- **"~70% LOC reduction" is a vanity target.** The current codebase is
  ~5.4k lines of shell. Squeezing that by 70% by rewriting everything
  into a `qos` CLI is possible, but only after we are sure the CLI design
  is right. Otherwise we end up with the same logic plus a CLI shim and
  *more* lines. The LOC number should not drive any architectural call.

- **mkosi and `qos.yaml` solve overlapping problems.** mkosi already has
  its own declarative format (`mkosi.conf` plus drop-ins). If we adopt
  mkosi we should *not* invent a parallel `qos.yaml` for image layout.
  `qos.yaml` should live above mkosi and describe things mkosi does not:
  profile selection, capability flags, service enablement, OTA channel.

- **Profiles must compose, not duplicate.** Build the profile system so
  `desktop` = `server` + delta, `gaming` = `desktop` + delta. Otherwise
  every profile diverges and we maintain four images.

- **Verified boot only buys safety if signing is real.** dm-verity with
  ad-hoc keys in the repo is theater. Plan key custody (offline signing
  host, public root hash, recovery process) before the implementation.

---

## 2. Feature-by-Feature Review and Ideas

### 2.1 Core Footprint — `<64MB` server, `<256MB` desktop

**Read of the proposal.** Direct SquashFS mount, mdev, surgical kernel,
ZRAM, log buffer shrink. All standard, all defensible.

**Where it gets real.**

- Current live boot path goes through `config/initramfs/live-init.sh` and
  uses an overlay over the squashfs. The change is to **stop staging the
  squashfs into tmpfs** and instead mount it directly from the read-only
  boot device, then layer a small tmpfs upper on top. The squashfs file
  *itself* still consumes page cache, but pages are evictable, which is
  the entire point.
- ISO and installed-disk paths diverge: ISO will rely on the kernel
  finding the iso9660 + squashfs offset; installed disk already has the
  squashfs on a raw partition (see `assemble-image.sh`). Both need the
  same initramfs mount logic, parameterized.

**Ideas to make this better.**

- Add a `boot=copytoram` legacy flag so users with flaky USB sticks can
  fall back. Default off.
- Track `MemAvailable` after `s6-svscan` reaches the "ready" bundle and
  publish it in the login banner that already exists (commit `e44aa75`).
  This converts "RAM target" from a marketing claim into a CI assertion.
- Add a make target `make ram-check` that boots the ISO under QEMU with
  a fixed `-m`, waits for ready, parses `/proc/meminfo`, and fails the
  build if used RSS exceeds a per-profile budget. Without this, the RAM
  number rots within two releases.

### 2.2 mdev replacing eudev

**Read.** mdev is a good fit for a static server, less ideal for a
desktop that hot-plugs USB audio, displays, controllers. The doc treats
this as universal; it should not be.

**Idea.** Keep eudev (or udev) gated behind the profile:
`server` ⇒ mdev, `desktop`/`gaming` ⇒ eudev. Both run as s6 services so
the rest of the system stays profile-agnostic. The "mdev -s once at boot
then exit" mode also works as a *cold-boot probe* even when eudev is
later the long-running hotplug daemon. That is the simplest way to get
the cold-boot RAM saving on every profile without losing hotplug on
desktops.

### 2.3 Modular kernel + on-demand modules

Already partly aligned with how Alpine ships. Real cost is in the kernel
config split: a separate "qos-core" config that builds in only NVMe,
SATA, VirtIO, ext4, squashfs, overlayfs, tmpfs, ZRAM, dm-verity, binder
(if AOSP is on the table), and everything else as `=m`.

**Ideas.**

- Don't hand-write the module list. Generate the list of "must be
  built-in" symbols from the build's own boot needs (probe the QEMU and
  metal test runs). Anything else is a module. This keeps drift down.
- Ship a `qos-mod-probe` one-shot service that walks `/sys/bus/pci`
  and `/sys/bus/usb`, resolves modalias to a module, and `modprobe`s
  exactly the set needed. mdev gives us the device events; this gives us
  the rule that decides what to load.

### 2.4 `qos.yaml` unified manifest

**Idea: keep it as build-time input, not a runtime control plane.**

```yaml
profile: desktop
image:
  variant: stable
  ab: true
packages:
  base: from-file:config/apk/packages.base
  extra: [wayland, sway, chromium]
services:
  enable: [s6-linux-init, sshd, qos-mod-probe]
capabilities:
  - net.hostap
  - gpu.amd
overlays:
  - lib32  # only when profile=gaming
```

- First version is a generator: it emits exactly the files the current
  pipeline already consumes (`packages.base`, `packages.system`, service
  enable list, partition JSON). This lets us land the schema without
  rewriting the build.
- Second version flips authority: the generated files become artifacts,
  and `qos.yaml` becomes canonical.
- Validate the schema in CI from day one (`jsonschema` or `cue`). A
  manifest without a schema rots into an undocumented dialect.

### 2.5 Unified `qos` CLI

The repo already has standalone tools (`qos-capability`, `qos-cluster`,
`qos-install`, `qos-expand`). Treat the new `qos` as an *umbrella*, not a
rewrite.

**Idea: subcommand router with adapters.**

```
qos install            → scripts/qos-install.sh
qos capability …       → scripts/qos-capability.sh
qos cluster …          → scripts/qos-cluster.sh
qos build [--profile]  → build.sh + mkosi hook
qos verify             → dm-verity status + signature check
qos profile current    → reads /etc/qos/profile
```

Land the router first with shell adapters, then port the underlying
scripts one at a time. This keeps the LOC story honest (no flag day,
no temporary doubling) and means each step is shippable.

If we want a real binary later, Rust or Go gives us a single static
binary that is easy to dm-verity-sign. Don't make that call until the
shell version's interface has stabilized.

### 2.6 Workload Profiles

**Idea: profiles are deltas, not images.**

- One base squashfs.
- One overlay squashfs per profile (`desktop.sfs`, `gaming.sfs`,
  `k8s.sfs`).
- Initramfs picks overlays based on `/etc/qos/profile` (writable, lives
  on state partition) or a kernel cmdline `qos.profile=`.
- Switching profile = changing one file + reboot, no reinstall. This is
  a feature server distros usually do not offer and is genuinely useful
  for "convert this VM from server to k3s host."

For the 32-bit gaming case, `/usr/lib32` and any 32-bit binaries live
*only* in the gaming overlay. Nothing about the 64-bit base ever sees
them. This is exactly what overlayfs is for.

### 2.7 Wayland-only GUI + Chromium WebView

The doc is right that X11 should not be in the base. Two refinements:

- **XWayland still pays a cost.** Document it as optional, off by default
  in `desktop`, on by default in `gaming`.
- **WebView "shared binary" needs design work.** Android's WebView is a
  zygote-style preforked process. Replicating that on Linux is more work
  than the doc implies. Realistically what we can ship is a `qos-webview`
  command that launches Chromium with `--app=` and an isolated profile
  directory. That is Tauri-grade, not WebView-grade. Be honest about
  which we are.

**Idea.** Ship `qos-webview` first as a thin wrapper. Add zygote-style
sharing later only if measurements show it matters; on modern Chromium
with kernel-side KSM disabled, the gain is smaller than the doc claims.

### 2.8 Steam + 32-bit overlay

- Steam through Flatpak is the path of least resistance and the doc
  already lists it. Use it. A native 32-bit chroot is more LOC for the
  same end result.
- GameMode + ananicy-cpp are fine, but make them opt-in services in the
  gaming overlay, not always-on.
- THP: prefer `madvise` over `always`. Defaulting THP to `always`
  trades latency spikes for throughput, which is the wrong call for a
  desktop that also does interactive workloads.

### 2.9 k3s / k9s

Genuinely easy. s6 service for k3s server/agent, `qos cluster` already
exists as a starting point.

**Idea.** Put k3s data on the state partition under a dedicated subvol
or directory. Ensure factory-reset (`scripts/factory-reset.sh`) has a
documented behavior for that directory (wipe vs preserve). This is a
question the existing reset script will need to answer once k3s lands.

### 2.10 Native AOSP Execution Host

This is the only feature where I would push back on the framing.

**What the doc proposes:** Bionic, ART, libbinder compiled from AOSP and
linked into a QOS rootfs that runs APKs as native Linux processes with
no container, no VM, no subsystem, no Wine.

**Why this is harder than the doc admits.**

- AOSP assumes its own pid 1, its own selinux policy, its own
  `/system` layout, its own property service, its own `init.rc`. The
  doc replaces all of that with s6. Each of those replacements is a
  multi-engineer-year project, not a porting task.
- ART binds to AOSP's specific libc behaviors and HAL implementations.
  Bionic on a glibc/musl host fights with the host loader, locale
  handling, threading and signal masks. There is a reason every shipped
  Android-on-Linux project (Anbox, Waydroid, ARC++) used containers or
  VMs: not for security, for *namespace and policy isolation*.
- Hardware integration is the hardest part. Gralloc, HWComposer, EGL,
  Camera HAL, Audio HAL, Sensor HAL — each is vendor-specific on real
  Android and would need a QOS-specific reimplementation against
  Wayland/PipeWire/V4L2.
- Binder is the easy part. Including it does not get us close.
- Maintenance: AOSP changes every release, and any divergence (s6 vs
  init, glibc vs bionic linker rules) becomes a permanent rebase tax.

**Idea: reframe in three tiers.**

1. **Tier 1 (ship in 2026):** Waydroid-style. Run a minimal LineageOS
   container with s6-managed lifecycle, Wayland surface bridge, shared
   `/data` on the state partition. This is achievable and useful and
   reuses 90% of the upstream work. Position it as "QOS-integrated
   Waydroid" not "native AOSP."
2. **Tier 2 (research):** Bionic-side ABI compatibility for individual
   APKs, similar to NDK-only apps under a thin loader. Probably feasible
   for games that ship only `.so` plus a small Java surface. This is the
   right place to start the "native" story.
3. **Tier 3 (long horizon, optional):** Full native AOSP host as the
   current doc describes. Treat as a research track, not part of the
   distro roadmap.

The current doc lumps tier 3 into the main feature list. That single
choice is what makes the rest of the document look unserious. Split it
out and the proposal becomes credible.

### 2.11 Podman-native build + mkosi

**Idea.** Two-step adoption.

- Step 1: Containerize the *current* build. `make full` runs inside a
  pinned Alpine container image with everything else unchanged. This
  gives us reproducibility without changing the build logic. Low risk,
  immediate win for CI.
- Step 2: Migrate to mkosi profile-by-profile. Start with `server` (it
  is the simplest, smallest, and the most-tested). Keep the old
  pipeline in `build.sh` until mkosi reaches parity for that profile.
  Then port `desktop`. Do not flag-day-cut.

### 2.12 dm-verity verified boot

**Idea.** Pair dm-verity with the A/B image layout that already exists.

- Each root slot gets a sibling `verity` partition holding the Merkle
  tree.
- The Limine entry passes `roothash=…` per slot.
- A `qos verify` subcommand mounts and validates without booting,
  useful before activating a freshly-OTA'd slot.
- Key custody plan written before any code. Otherwise we ship signed
  images whose signing keys are in the public git history, which is
  worse than not signing at all.

### 2.13 Optimization & Tuning doc

Mostly fine. Two notes:

- `slab_debug=-` is correct only on kernels built with slab debug
  available; on a CONFIG_SLUB_DEBUG=n build it is a no-op. Don't claim
  RAM savings from a no-op.
- EarlyOOM is great for desktop and gaming. On a `<64MB` server, it can
  itself OOM. Make it profile-gated.

---

## 3. Suggested Sequencing

A boring, safe ordering that ships value early and keeps every step
revertable:

1. **Containerize the existing build** (Podman wrapper, no logic change).
2. **`qos` CLI as a router** over today's scripts.
3. **`qos.yaml` as a generator** emitting today's input files.
4. **Direct SquashFS mount** + RAM budget CI check.
5. **Profile system** as overlay squashfs files; ship `server` and
   `desktop` first.
6. **mdev cold-boot probe** universally; eudev only on desktop/gaming.
7. **k3s profile** (smallest new profile, exercises the system).
8. **Modular kernel split** with auto-generated built-in list.
9. **dm-verity** with real key custody.
10. **Gaming profile** (Steam via Flatpak, 32-bit overlay).
11. **Waydroid-integrated Android** (tier 1 of the AOSP plan).
12. **mkosi migration**, profile by profile.
13. **Wayland-shared WebView "Tauri-grade"**; native zygote later if
    measurements justify it.
14. **AOSP tier 2 research** (Bionic-side single-APK loader).
15. **AOSP tier 3** parked behind explicit funding/scope decision.

Each step is a release. None of them require the next one to be useful.

---

## 4. What to Cut, What to Add

**Cut from the current request list:**

- Native AOSP host *as a 2026 feature*. Keep the doc, mark it as research.
- The single global `<64MB` target. Replace with per-profile budgets.
- The `~70% LOC reduction` headline number. Replace with "no net LOC
  growth across CLI consolidation."

**Add to the current request list:**

- A reproducibility statement. Same `qos.yaml` + same git SHA + same
  builder image = byte-identical artifact. This is a hard requirement
  for verified boot to mean anything.
- A telemetry-free first-boot health summary. The login banner work
  (commit `e44aa75`) is the right hook; extend it with RAM-budget and
  verity-status fields.
- An OTA story for profile changes. `scripts/ota-*` already exists for
  A/B; profiles need to slot into the same upgrade flow.
- Test coverage targets per profile. `make ram-check`, `make
  boot-check`, `make verity-check` should each be a single command.

---

## 5. Open Questions for the Maintainer

1. Is the target audience "homelab/server" first or "desktop OS" first?
   The proposal reads as both; sequencing depends on this.
2. Who owns Android scope? If nobody on the team has shipped an AOSP
   port before, tier 3 should be off the table by default.
3. What is the OTA/update model for profiles? Stay on a profile, or
   allow live switch via A/B?
4. Is byte-reproducible build a hard requirement or aspirational?
5. Where will signing keys live, and who can rotate them?

Answers to these five questions remove most of the ambiguity in the
current feature docs.

---

*Companion to `FEATURE-FEASIBILITY-REVIEW.md`. Where that doc says*
*"yes/no", this one says "and here is how."*
