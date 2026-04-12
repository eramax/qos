# QEMU Bridge-Default Networking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `make qemu` boot the guest on bridged/TAP networking by default so the VM gets a LAN-reachable address, while preserving an explicit NAT fallback for hosts without a working bridge.

**Architecture:** The QEMU launcher will support two network modes selected by environment variable: `bridge` and `nat`. Bridge mode will attach the guest NIC to a host bridge or TAP helper and become the default. NAT mode will keep the current user-mode networking path for portability and SSH forwarding. The Makefile and README will describe the defaults and override knobs, and tests will pin the command-line contract so the default does not drift.

**Tech Stack:** Bash, GNU Make, QEMU, Linux bridge/TAP networking, shell tests.

---

### Task 1: Define the Network Mode Contract

**Files:**
- Modify: `scripts/run-qemu.sh`
- Modify: `Makefile`
- Modify: `README.md`

- [ ] **Step 1: Decide the environment variables**

Use:
- `QEMU_NET_MODE=bridge` as the default
- `QEMU_NET_MODE=nat` as the fallback
- `QEMU_BRIDGE_IFACE=br0` as the default bridge name
- `QEMU_HOSTFWD_PORT` only in NAT mode

- [ ] **Step 2: Update the runner**

Teach `scripts/run-qemu.sh` to:
- emit bridge networking when `QEMU_NET_MODE` is unset or `bridge`
- keep user-mode NAT when `QEMU_NET_MODE=nat`
- fail clearly when bridge mode is selected but no bridge interface is available

- [ ] **Step 3: Update the Makefile and docs**

Make `make qemu` pass the networking mode through, and document:
- default bridged networking
- NAT fallback invocation
- host bridge prerequisites

### Task 2: Pin the Default Contract in Tests

**Files:**
- Modify: `tests/test_qemu_boot.sh`

- [ ] **Step 1: Add a command-line contract assertion**

Assert that the generated QEMU invocation includes bridge networking by default and does not emit user-mode NAT unless NAT mode is requested.

- [ ] **Step 2: Add an explicit NAT fallback assertion**

Assert that `QEMU_NET_MODE=nat` preserves the existing `hostfwd` path.

### Task 3: Verify and Document

**Files:**
- Modify: `README.md`
- Modify: `tests/test_qemu_boot.sh`

- [ ] **Step 1: Run the focused QEMU contract test**

Run:
```bash
bash tests/test_qemu_boot.sh
```
Expected: PASS.

- [ ] **Step 2: Review the user-facing docs**

Confirm the README explains:
- bridge mode is the default
- NAT fallback is available
- bridge mode depends on host setup

