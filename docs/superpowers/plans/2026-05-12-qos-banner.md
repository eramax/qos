# QOS Login Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Alpine's default SSH welcome text with a QOS banner that prints live kernel, RAM, and disk information, while using a build-stamped version generated during `make full`.

**Architecture:** Build-time code writes a deterministic version stamp into the staged rootfs, then a shell profile hook renders the banner only for interactive logins. The banner reads live system values at login time so the output stays current without adding runtime services or Python.

**Tech Stack:** Bash, Alpine rootfs staging, `make full`, shell profile hooks, existing repo test harness.

---

### Task 1: Add a build-stamped QOS version file

**Files:**
- Modify: `build.sh`
- Create: `config/qos/version.template` or equivalent version source file
- Test: `tests/test_services.sh`

- [ ] **Step 1: Write the failing test**

Add an assertion that the staged rootfs contains a QOS version file and that it includes a build timestamp string produced by `make full`.

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_services.sh`
Expected: fail because the version file does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Make `make full` write a formatted version stamp into the staged rootfs, likely at `/etc/qos/version`, using the build datetime and a short git identifier when available.

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_services.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build.sh config/qos/version.template tests/test_services.sh
git commit -m "feat: add build-stamped qos version"
```

### Task 2: Add an interactive login banner hook

**Files:**
- Create: `config/profile.d/qos-banner.sh`
- Modify: `scripts/install-services.sh`
- Test: `tests/test_services.sh`

- [ ] **Step 1: Write the failing test**

Add assertions that the staged rootfs contains a profile hook under `/etc/profile.d/` and that it is gated to interactive shells only.

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_services.sh`
Expected: fail because the profile hook is not present yet.

- [ ] **Step 3: Write minimal implementation**

Copy the new profile hook into the rootfs during service installation. The script should:

- detect interactive shells
- read `/etc/qos/version`
- print `uname -r`
- print RAM from `/proc/meminfo`
- print disk usage from `df -h /`

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_services.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add config/profile.d/qos-banner.sh scripts/install-services.sh tests/test_services.sh
git commit -m "feat: add qos login banner"
```

### Task 3: Verify SSH login behavior end to end

**Files:**
- Modify: `tests/test_qemu_boot.sh`
- Modify: `tests/test_services.sh`

- [ ] **Step 1: Write the failing test**

Add a boot/login test that checks:

- `ssh root@host command` stays quiet for noninteractive commands
- interactive SSH login prints the QOS banner

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: fail until the login hook is installed in the built image.

- [ ] **Step 3: Write minimal implementation**

Adjust the boot/login test harness to capture the SSH session output and assert the banner text appears only on interactive login.

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/test_qemu_boot.sh tests/test_services.sh
git commit -m "test: cover qos login banner behavior"
```

