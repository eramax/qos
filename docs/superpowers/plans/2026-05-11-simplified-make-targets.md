# Simplified Make Targets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the top-level build and boot workflow so `make full` builds the live ISO, `make live` boots the ISO, `make qemu` boots the installed disk, and kernel rebuilds only happen explicitly or when missing.

**Architecture:** The Makefile becomes the small public interface while `build.sh` changes from raw-image-first output to ISO-first output. Kernel reuse is handled by checking for existing kernel artifacts during `full`, while explicit `make kernel` remains the forced rebuild path.

**Tech Stack:** GNU Make, Bash build scripts, QEMU, OVMF, shell tests.

---

## File Structure

- Modify: `Makefile`
  - Collapse public targets and rename boot entrypoints.
- Modify: `build.sh`
  - Make `full` end at ISO generation and reuse existing kernel output when present.
- Modify: `README.md`
  - Document the simplified workflow.
- Modify: `tests/test_qemu_boot.sh`
  - Update target-name and bridge-boot expectations.
- Modify: `tests/test_build_contract.sh`
  - Update build-output expectations from raw image to ISO.
- Modify: other docs/tests that mention `qemu2`, `boot`, or raw-image-first `full` behavior if they are enforced.

### Task 1: Update Build Contract Tests

**Files:**
- Modify: `tests/test_build_contract.sh`
- Modify: `tests/test_qemu_boot.sh`

- [ ] **Step 1: Write the failing test**

Update tests to assert:
- `make full` produces ISO-oriented output
- `make live` exists as the live-ISO boot target
- `make qemu` exists as the installed-disk boot target
- legacy `qemu2` and `boot` are not part of the primary contract

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
rtk bash tests/test_build_contract.sh
rtk bash tests/test_qemu_boot.sh
```

Expected: FAIL because current target names and build contract still reflect the old layout.

- [ ] **Step 3: Write minimal implementation**

Adjust the tests only enough to describe the new contract clearly and narrowly.

- [ ] **Step 4: Run test to verify it passes after implementation**

Run the same commands after Task 2 and Task 3 land.

- [ ] **Step 5: Commit**

```bash
git add tests/test_build_contract.sh tests/test_qemu_boot.sh
git commit -m "test: update simplified make target contract"
```

### Task 2: Simplify Makefile Targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Write the failing behavior check**

Use the updated shell tests from Task 1 as the failing contract for:
- `full`
- `kernel`
- `live`
- `qemu`
- `clean`

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
rtk bash tests/test_qemu_boot.sh
```

Expected: FAIL because `Makefile` still exports the old target names and help text.

- [ ] **Step 3: Write minimal implementation**

Update `Makefile` so:
- `full` is the main build target
- `live` replaces the current live-ISO QEMU boot target
- `qemu` replaces the current installed-disk boot target
- raw-image-first targets are removed or de-emphasized from the public interface
- help text reflects only the simplified workflow

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
rtk bash tests/test_qemu_boot.sh
```

Expected: PASS for target naming/help contract.

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/test_qemu_boot.sh
git commit -m "refactor: simplify public make targets"
```

### Task 3: Make `build.sh` Produce ISO and Reuse Kernel

**Files:**
- Modify: `build.sh`
- Possibly Modify: helper scripts only if required by the contract
- Test: `tests/test_build_contract.sh`

- [ ] **Step 1: Write the failing test**

Update `tests/test_build_contract.sh` to assert:
- `make full` reaches ISO output
- existing kernel artifacts are reused when present
- missing kernel artifacts are rebuilt automatically
- raw image is not the primary completion artifact

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
rtk bash tests/test_build_contract.sh
```

Expected: FAIL because `build.sh` currently ends with `dist/qos-x86_64.raw`.

- [ ] **Step 3: Write minimal implementation**

Update `build.sh` so:
- real and mock `full` paths end with ISO generation
- kernel build is skipped if the expected kernel outputs already exist
- kernel build still runs automatically from a clean tree
- success output reports ISO completion

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
rtk bash tests/test_build_contract.sh
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add build.sh tests/test_build_contract.sh
git commit -m "feat: make full build iso and reuse kernel"
```

### Task 4: Update README Workflow

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write the failing docs check**

Extend tests or grep checks so README must describe:
- `make full`
- `make live`
- `make qemu`
- explicit `make kernel` for kernel rebuilds

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
rtk bash tests/test_qemu_boot.sh
```

Expected: FAIL until README reflects the new workflow.

- [ ] **Step 3: Write minimal implementation**

Update README build/boot sections to:
- remove raw-image-first guidance
- describe ISO-first `full`
- describe `live` vs installed-disk `qemu`
- note that kernel is only rebuilt explicitly or when missing

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
rtk bash tests/test_qemu_boot.sh
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add README.md tests/test_qemu_boot.sh
git commit -m "docs: describe simplified make workflow"
```

### Task 5: Verification Sweep

**Files:**
- Verify: `Makefile`
- Verify: `build.sh`
- Verify: `README.md`
- Verify: tests

- [ ] **Step 1: Run focused tests**

Run:

```bash
rtk bash tests/test_build_contract.sh
rtk bash tests/test_qemu_boot.sh
rtk bash tests/test_qos_install.sh
rtk bash tests/test_qemu_host_net.sh
```

Expected: all PASS

- [ ] **Step 2: Run a mock full build**

Run:

```bash
rtk make full
```

Expected:
- completes successfully in the current mock-friendly mode if applicable
- reports ISO completion rather than raw-image completion

- [ ] **Step 3: Inspect resulting artifacts**

Run:

```bash
rtk ls -l dist
```

Expected:
- `dist/qos-x86_64.iso` exists
- raw image is not required for success

- [ ] **Step 4: Commit**

```bash
git add Makefile build.sh README.md tests/test_build_contract.sh tests/test_qemu_boot.sh
git commit -m "feat: simplify make workflow around iso builds"
```
