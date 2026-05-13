# Component Build Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce additive profile manifests and reusable feature-stack components, then wire the existing build pipeline to consume generated package, rootfs overlay, and kernel config outputs.

**Architecture:** Keep the current shell build pipeline, but insert a new builder resolution layer ahead of it. Profiles select components, components declare packages and staged artifacts, and the resolver generates deterministic build inputs that `build-rootfs.sh`, `install-services.sh`, and `build-kernel.sh` can consume without a full pipeline rewrite.

**Tech Stack:** Bash, Python 3 with PyYAML, existing shell tests

---

### Task 1: Add a failing resolver contract test

**Files:**
- Create: `tests/test_component_builder.sh`

- [ ] **Step 1: Write the failing test**
- [ ] **Step 2: Run the test to verify it fails**
- [ ] **Step 3: Implement the minimal resolver and manifests**
- [ ] **Step 4: Run the test to verify it passes**

### Task 2: Define profiles and components

**Files:**
- Create: `profiles/base.yaml`
- Create: `profiles/server.yaml`
- Create: `profiles/desktop.yaml`
- Create: `components/*/component.yaml`
- Create: `components/*/{rootfs,s6,kernel,hooks,tests}/...`

- [ ] **Step 1: Add the minimal component set to reproduce current server and desktop builds**
- [ ] **Step 2: Keep component boundaries feature-oriented rather than package-bucket oriented**
- [ ] **Step 3: Stage desktop and server-specific overlays from components instead of profile overlay directories**

### Task 3: Wire the build pipeline to generated inputs

**Files:**
- Create: `builder/resolve.sh`
- Modify: `build.sh`
- Modify: `scripts/build-rootfs.sh`
- Modify: `scripts/install-services.sh`
- Modify: `scripts/build-kernel.sh`

- [ ] **Step 1: Resolve the selected profile at the start of `build.sh`**
- [ ] **Step 2: Feed resolved package lists into `build-rootfs.sh`**
- [ ] **Step 3: Feed resolved staged overlays into `install-services.sh`**
- [ ] **Step 4: Feed resolved kernel config into `build-kernel.sh`**

### Task 4: Verify compatibility and document the migration slice

**Files:**
- Modify: `Makefile`
- Modify: `tests/test_services.sh`
- Modify: `docs/README.md` or equivalent if needed

- [ ] **Step 1: Add a public entrypoint for the resolver**
- [ ] **Step 2: Update tests to validate component-driven resolution**
- [ ] **Step 3: Run focused shell tests for the new flow**
