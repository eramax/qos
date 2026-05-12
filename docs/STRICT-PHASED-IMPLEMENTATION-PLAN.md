# QOS Strict Phased Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the current QOS wishlist into a staged implementation program that modernizes the build and boot architecture first, then adds profile-driven features on top of a stable base.

**Architecture:** Preserve the current Alpine + shell-based pipeline as the compatibility baseline, then layer in a manifest, containerized builds, direct SquashFS boot, unified CLI, and integrity hardening in measured steps. Treat desktop, gaming, and k8s as profile artifacts, and keep native AOSP work outside the main delivery path until feasibility is proven independently.

**Tech Stack:** Bash, Alpine/apk, QEMU, Limine, SquashFS, ext4, `s6`/`s6-rc`, `jq`, `yq` or a small manifest generator, optional Podman/Docker, optional `mkosi` later, dm-verity tooling later.

---

## Scope and Delivery Rules

- The plan covers the realistic product track only.
- Native AOSP execution is explicitly excluded from the mainline implementation sequence.
- Each phase must preserve a working build unless the phase is marked as research-only.
- Compatibility wrappers for existing commands must remain until docs and tests are migrated.
- A phase is not complete until its acceptance criteria and verification commands pass.

## Current Baseline

The plan assumes the current implementation center of gravity is:

- [`Makefile`](/mnt/mydata/projects2/qos/Makefile)
- [`build.sh`](/mnt/mydata/projects2/qos/build.sh)
- [`scripts/build-rootfs.sh`](/mnt/mydata/projects2/qos/scripts/build-rootfs.sh)
- [`scripts/assemble-image.sh`](/mnt/mydata/projects2/qos/scripts/assemble-image.sh)
- [`scripts/install-services.sh`](/mnt/mydata/projects2/qos/scripts/install-services.sh)
- [`config/initramfs/live-init.sh`](/mnt/mydata/projects2/qos/config/initramfs/live-init.sh)
- [`scripts/qos-capability.sh`](/mnt/mydata/projects2/qos/scripts/qos-capability.sh)
- [`scripts/qos-cluster.sh`](/mnt/mydata/projects2/qos/scripts/qos-cluster.sh)
- [`scripts/qos-install.sh`](/mnt/mydata/projects2/qos/scripts/qos-install.sh)
- [`scripts/qos-expand.sh`](/mnt/mydata/projects2/qos/scripts/qos-expand.sh)
- [`tests/`](/mnt/mydata/projects2/qos/tests)

## Release Track

### Phase 0: Freeze Baseline and Add Measurement

**Outcome:** The repo has a trustworthy baseline for build success, boot success, and memory/image measurements before major refactors begin.

**Files:**
- Modify: [`Makefile`](/mnt/mydata/projects2/qos/Makefile)
- Modify: [`scripts/qos-test.sh`](/mnt/mydata/projects2/qos/scripts/qos-test.sh)
- Create: [`scripts/measure-memory.sh`](/mnt/mydata/projects2/qos/scripts/measure-memory.sh)
- Create: [`tests/test_measurement_contract.sh`](/mnt/mydata/projects2/qos/tests/test_measurement_contract.sh)
- Modify: [`docs/FEATURE-FEASIBILITY-REVIEW.md`](/mnt/mydata/projects2/qos/docs/FEATURE-FEASIBILITY-REVIEW.md)

- [ ] Add a repeatable command for baseline measurement of image size and QEMU boot memory.
- [ ] Add a shell test that verifies the measurement script emits stable, parseable output.
- [ ] Add `make` targets for baseline verification without changing the build flow.
- [ ] Document baseline metrics in a compact table.

**Acceptance criteria**

- `make` exposes a measurement target.
- The measurement script runs without requiring manual parsing.
- The repo records baseline values for:
  - image size
  - boot success
  - idle memory for current live flow

**Verification**

- Run: `rtk bash tests/test_measurement_contract.sh`
- Run: `rtk make help`

### Phase 1: Introduce `qos.yaml` as a Non-Authoritative Input Layer

**Outcome:** A first manifest exists and can generate the current package/layout/service inputs without breaking the existing pipeline.

**Files:**
- Create: [`qos.yaml`](/mnt/mydata/projects2/qos/qos.yaml)
- Create: [`scripts/generate-config.sh`](/mnt/mydata/projects2/qos/scripts/generate-config.sh)
- Create: [`tests/test_manifest_generation.sh`](/mnt/mydata/projects2/qos/tests/test_manifest_generation.sh)
- Modify: [`config/apk/packages.base`](/mnt/mydata/projects2/qos/config/apk/packages.base)
- Modify: [`config/apk/packages.system`](/mnt/mydata/projects2/qos/config/apk/packages.system)
- Modify: [`config/image/layout.json`](/mnt/mydata/projects2/qos/config/image/layout.json)
- Modify: [`scripts/build-rootfs.sh`](/mnt/mydata/projects2/qos/scripts/build-rootfs.sh)
- Modify: [`scripts/assemble-image.sh`](/mnt/mydata/projects2/qos/scripts/assemble-image.sh)

- [ ] Define a minimal v1 schema for packages, profiles, services, and image sizes.
- [ ] Generate the existing package lists and image layout from `qos.yaml`.
- [ ] Keep the generated files checked in during the transition.
- [ ] Add a test that fails when generated outputs drift from the manifest.

**Acceptance criteria**

- `qos.yaml` exists and validates through the generator.
- Generated output matches the current build inputs.
- The build still succeeds through the current shell pipeline.

**Verification**

- Run: `rtk bash tests/test_manifest_generation.sh`
- Run: `rtk git diff -- config/apk config/image`
- Run: `rtk make full`

### Phase 2: Containerize the Existing Build Without Changing Behavior

**Outcome:** The current build can run inside a pinned container image with equivalent artifacts and preserved output ownership.

**Files:**
- Create: [`Dockerfile.build`](/mnt/mydata/projects2/qos/Dockerfile.build)
- Create: [`scripts/container-build.sh`](/mnt/mydata/projects2/qos/scripts/container-build.sh)
- Create: [`tests/test_container_build_contract.sh`](/mnt/mydata/projects2/qos/tests/test_container_build_contract.sh)
- Modify: [`Makefile`](/mnt/mydata/projects2/qos/Makefile)
- Modify: [`build.sh`](/mnt/mydata/projects2/qos/build.sh)
- Modify: [`README.md`](/mnt/mydata/projects2/qos/README.md)

- [ ] Pin the build dependencies in `Dockerfile.build`.
- [ ] Add a wrapper that mounts the repo and writes outputs as the calling user.
- [ ] Add `make` targets for host build and container build.
- [ ] Add a contract test that verifies required tools and expected output locations.

**Acceptance criteria**

- A developer can run the build in a container from a clean host.
- Build outputs land in the expected repo directories.
- Host build and container build both remain supported during migration.

**Verification**

- Run: `rtk bash tests/test_container_build_contract.sh`
- Run: `rtk make full`
- Run: `rtk make container-build`

### Phase 3: Add Unified `qos` CLI with Compatibility Shims

**Outcome:** Operators have a single `qos` entry point while old commands continue working as wrappers.

**Files:**
- Create: [`scripts/qos`](/mnt/mydata/projects2/qos/scripts/qos)
- Create: [`tests/test_qos_cli.sh`](/mnt/mydata/projects2/qos/tests/test_qos_cli.sh)
- Modify: [`scripts/qos-capability.sh`](/mnt/mydata/projects2/qos/scripts/qos-capability.sh)
- Modify: [`scripts/qos-cluster.sh`](/mnt/mydata/projects2/qos/scripts/qos-cluster.sh)
- Modify: [`scripts/qos-install.sh`](/mnt/mydata/projects2/qos/scripts/qos-install.sh)
- Modify: [`scripts/qos-expand.sh`](/mnt/mydata/projects2/qos/scripts/qos-expand.sh)
- Modify: [`scripts/install-services.sh`](/mnt/mydata/projects2/qos/scripts/install-services.sh)
- Modify: [`docs/README.md`](/mnt/mydata/projects2/qos/docs/README.md)

- [ ] Create a shared CLI entry point with subcommands for `cap`, `node`, `install`, `disk expand`, and `test`.
- [ ] Extract shared logging, usage, and argument parsing into a common library if needed.
- [ ] Convert legacy scripts into compatibility wrappers that delegate to `qos`.
- [ ] Update service installation to install both the new CLI and compatibility names.

**Acceptance criteria**

- `qos cap`, `qos node`, `qos install`, and `qos disk expand` work.
- Existing commands still function and produce equivalent behavior.
- Tests cover both the new entry point and the wrappers.

**Verification**

- Run: `rtk bash tests/test_qos_cli.sh`
- Run: `rtk bash tests/test_qos_install.sh`
- Run: `rtk bash tests/test_services.sh`

### Phase 4: Replace Copy-to-RAM Live Boot with a Direct SquashFS Path

**Outcome:** QOS supports a no-copy live boot path that mounts the rootfs directly and reduces memory pressure, while retaining a fallback path during rollout.

**Files:**
- Modify: [`config/initramfs/live-init.sh`](/mnt/mydata/projects2/qos/config/initramfs/live-init.sh)
- Modify: [`scripts/build-initramfs.sh`](/mnt/mydata/projects2/qos/scripts/build-initramfs.sh)
- Modify: [`scripts/build-iso.sh`](/mnt/mydata/projects2/qos/scripts/build-iso.sh)
- Modify: [`scripts/boot-image.sh`](/mnt/mydata/projects2/qos/scripts/boot-image.sh)
- Create: [`tests/test_live_direct_boot.sh`](/mnt/mydata/projects2/qos/tests/test_live_direct_boot.sh)
- Modify: [`scripts/measure-memory.sh`](/mnt/mydata/projects2/qos/scripts/measure-memory.sh)

- [ ] Split the live init path into `live-copy` fallback and `live-direct` primary mode.
- [ ] Mount SquashFS directly and place writable state in a separate writable layer.
- [ ] Add verification that the direct mode boots and exposes the expected root layout.
- [ ] Capture before/after memory measurements in QEMU.

**Acceptance criteria**

- Direct live boot works in QEMU.
- The legacy copy-to-RAM path remains available as a fallback until the new path is proven.
- Measured idle memory drops from the current baseline.

**Verification**

- Run: `rtk bash tests/test_live_direct_boot.sh`
- Run: `rtk bash scripts/measure-memory.sh`
- Run: `rtk make live`

### Phase 5: Add Profile Model for `server`, `desktop`, `gaming`, and `k8s`

**Outcome:** The build can produce profile-specific artifacts from one manifest without claiming all profiles share the same footprint budget.

**Files:**
- Modify: [`qos.yaml`](/mnt/mydata/projects2/qos/qos.yaml)
- Modify: [`scripts/generate-config.sh`](/mnt/mydata/projects2/qos/scripts/generate-config.sh)
- Create: [`tests/test_profiles.sh`](/mnt/mydata/projects2/qos/tests/test_profiles.sh)
- Modify: [`config/apk/packages.base`](/mnt/mydata/projects2/qos/config/apk/packages.base)
- Modify: [`config/apk/packages.system`](/mnt/mydata/projects2/qos/config/apk/packages.system)
- Modify: [`Makefile`](/mnt/mydata/projects2/qos/Makefile)
- Modify: [`README.md`](/mnt/mydata/projects2/qos/README.md)

- [ ] Define profile inheritance and allowed combinations.
- [ ] Generate package and service sets per profile.
- [ ] Add profile-aware build targets.
- [ ] Add tests that verify profile outputs differ only where intended.

**Acceptance criteria**

- The repo can build at least `server` and `k8s` or `desktop` from one manifest.
- Profile-specific packages and services are generated reproducibly.
- Profile budgets are documented separately.

**Verification**

- Run: `rtk bash tests/test_profiles.sh`
- Run: `rtk make full PROFILE=server`
- Run: `rtk make full PROFILE=desktop`

### Phase 6: Add dm-verity and Integrity Plumbing

**Outcome:** The rootfs gains verifiable integrity with a staged path toward UKI and Secure Boot.

**Files:**
- Modify: [`scripts/assemble-image.sh`](/mnt/mydata/projects2/qos/scripts/assemble-image.sh)
- Modify: [`config/initramfs/live-init.sh`](/mnt/mydata/projects2/qos/config/initramfs/live-init.sh)
- Modify: [`scripts/build-iso.sh`](/mnt/mydata/projects2/qos/scripts/build-iso.sh)
- Create: [`tests/test_verity_contract.sh`](/mnt/mydata/projects2/qos/tests/test_verity_contract.sh)
- Modify: [`config/limine/limine.conf`](/mnt/mydata/projects2/qos/config/limine/limine.conf)
- Modify: [`docs/README.md`](/mnt/mydata/projects2/qos/docs/README.md)

- [ ] Generate verity metadata for the rootfs artifact.
- [ ] Teach boot logic to verify the root before mounting.
- [ ] Add negative-path tests for tampered root data.
- [ ] Defer UKI and Secure Boot until verity is stable.

**Acceptance criteria**

- The build emits the root artifact and its verification metadata.
- Boot succeeds with valid artifacts.
- Boot fails in a controlled way when verification fails.

**Verification**

- Run: `rtk bash tests/test_verity_contract.sh`
- Run: `rtk make full`

### Phase 7: Add Desktop and Gaming as Constrained Profile Layers

**Outcome:** Desktop and gaming support land as layered profiles rather than as a redesign of the core distro.

**Files:**
- Modify: [`qos.yaml`](/mnt/mydata/projects2/qos/qos.yaml)
- Modify: [`scripts/generate-config.sh`](/mnt/mydata/projects2/qos/scripts/generate-config.sh)
- Create: [`tests/test_desktop_profile.sh`](/mnt/mydata/projects2/qos/tests/test_desktop_profile.sh)
- Create: [`tests/test_gaming_profile.sh`](/mnt/mydata/projects2/qos/tests/test_gaming_profile.sh)
- Modify: [`config/apk/packages.system`](/mnt/mydata/projects2/qos/config/apk/packages.system)
- Modify: [`scripts/measure-memory.sh`](/mnt/mydata/projects2/qos/scripts/measure-memory.sh)

- [ ] Choose one compositor and one initial desktop stack.
- [ ] Add the minimal packages for a bootable desktop profile.
- [ ] Add gaming-only packages and overlays separately from the desktop base.
- [ ] Document GPU-driver and 32-bit library handling as profile-scoped concerns.

**Acceptance criteria**

- Desktop boots with a defined session architecture.
- Gaming remains a separate additive layer.
- Memory budgets are measured and published separately for desktop and gaming.

**Verification**

- Run: `rtk bash tests/test_desktop_profile.sh`
- Run: `rtk bash tests/test_gaming_profile.sh`

### Phase 8: Add `k8s` as a Server-Oriented Product Profile

**Outcome:** QOS can build a k3s-oriented image without collapsing the minimal server target into the default artifact.

**Files:**
- Modify: [`qos.yaml`](/mnt/mydata/projects2/qos/qos.yaml)
- Modify: [`scripts/generate-config.sh`](/mnt/mydata/projects2/qos/scripts/generate-config.sh)
- Modify: [`scripts/qos-e2e-full.sh`](/mnt/mydata/projects2/qos/scripts/qos-e2e-full.sh)
- Create: [`tests/test_k8s_profile.sh`](/mnt/mydata/projects2/qos/tests/test_k8s_profile.sh)
- Modify: [`docs/WORKLOAD-PROFILES-GUI-GAMING-K8S.md`](/mnt/mydata/projects2/qos/docs/WORKLOAD-PROFILES-GUI-GAMING-K8S.md)

- [ ] Keep k3s packaging profile-scoped and optional.
- [ ] Add explicit minimum hardware requirements for the `k8s` profile.
- [ ] Extend E2E validation to cover the `k8s` profile separately from base server tests.

**Acceptance criteria**

- `k8s` is not part of the default minimal image.
- k3s-related checks only run for the `k8s` profile.
- The profile has documented hardware requirements and test expectations.

**Verification**

- Run: `rtk bash tests/test_k8s_profile.sh`
- Run: `rtk bash scripts/qos-e2e-full.sh --skip-bun`

## Research Track: Explicitly Out of Mainline Scope

### Native AOSP Execution Host

This is not part of the main implementation line.

If pursued, it should be tracked as a separate research document with independent go/no-go gates:

- Binder and process model proof
- one-app execution proof
- graphics/input proof
- service lifecycle proof
- packaging and update proof

Until those gates exist, no mainline milestone should depend on Android compatibility.

## Gate Checklist Per Phase

Every phase must answer these questions before work moves forward:

- Does `make` still expose the expected workflow?
- Does QEMU boot still work for the intended artifact?
- Did image size change, and is it explained?
- Did idle memory change, and is it measured?
- Are legacy operator paths still available where promised?
- Were docs updated alongside behavior changes?

## Recommended Commit Boundaries

- One commit for measurement scaffolding
- One commit for manifest introduction
- One commit for container build support
- One commit for CLI unification
- One commit for direct live boot
- One commit for profile model
- One commit for verity
- One commit each for desktop/gaming and k8s profile work

## Final Delivery Recommendation

The correct order is:

1. measurement
2. manifest
3. container build
4. CLI unification
5. direct boot
6. profiles
7. integrity
8. desktop/gaming
9. k8s

This sequence minimizes simultaneous moving parts and keeps the project aligned with what the current repo already does well.
