# Minimal QEMU Distro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a host-safe, reproducible, UEFI-only Alpine-based Linux image for QEMU x86_64 with an immutable ext4 rootfs, s6 supervision, Dropbear SSH, nftables, and A/B OTA delivery.

**Architecture:** A single top-level Bash script orchestrates a workspace-contained build pipeline. The pipeline stages Alpine packages into an immutable rootfs, builds or assembles the kernel and initramfs, injects s6 service definitions, installs Limine, and emits a raw disk image with A/B slots. OTA delivery is image-based: update the inactive slot, verify it, switch Limine to the new slot, and fall back automatically if the boot or health check fails.

**Tech Stack:** Bash, apk-tools, mkosi, mkinitfs, Limine, QEMU, OVMF, ext4, s6, s6-rc, Dropbear, nftables, shell scripts, optional shellcheck/bats for validation.

---

### Task 1: Repository Scaffold and Host-Safe Build Contract

**Files:**
- Create: `build.sh`
- Create: `scripts/lib/common.sh`
- Create: `config/README.md`
- Create: `build/README.md`
- Create: `dist/README.md`
- Create: `tests/README.md`

- [ ] **Step 1: Write the failing test**

Create `tests/test_build_contract.sh` that verifies the build script:
- refuses to write outside the workspace
- emits artifacts only under `dist/`
- creates temporary data only under `build/`

Run:
```bash
bash tests/test_build_contract.sh
```
Expected: fail until the build script exists.

- [ ] **Step 2: Implement the workspace contract**

Write `build.sh` to:
- resolve the repo root
- create `build/` and `dist/`
- refuse to run if `PWD` is outside the repo
- use `set -euo pipefail`
- delegate all work to helper scripts under `scripts/`

Write `scripts/lib/common.sh` with shared helpers for:
- `require_cmd`
- `repo_root`
- `ensure_dir`
- `cleanup_on_exit`

- [ ] **Step 3: Run the contract test**

Run:
```bash
bash tests/test_build_contract.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add build.sh scripts/lib/common.sh config/README.md build/README.md dist/README.md tests/README.md tests/test_build_contract.sh
git commit -m "chore: add build scaffold and host safety contract"
```

### Task 2: Alpine Rootfs Staging and Package Manifest

**Files:**
- Create: `config/apk/repositories`
- Create: `config/apk/packages.base`
- Create: `config/apk/packages.system`
- Create: `config/rootfs/paths.txt`
- Create: `scripts/build-rootfs.sh`
- Create: `scripts/apply-rootfs-layout.sh`
- Create: `tests/test_rootfs_layout.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_rootfs_layout.sh` that checks the staged rootfs contains:
- `/etc`
- `/var`
- `/run`
- `/usr`
- `/bin/sh` pointing to `ash`
- no writable files in the base root image except explicitly allowed state locations

Run:
```bash
bash tests/test_rootfs_layout.sh
```
Expected: fail until rootfs staging exists.

- [ ] **Step 2: Implement rootfs staging**

Write `scripts/build-rootfs.sh` to:
- create a staging directory under `build/rootfs`
- install Alpine packages from `config/apk/repositories`
- populate the base package set from `config/apk/packages.base`
- install system packages from `config/apk/packages.system`
- apply the rootfs layout from `config/rootfs/paths.txt`
- ensure `/etc` is part of the immutable image

Write `scripts/apply-rootfs-layout.sh` to:
- create required directories
- set ownership and permissions
- prepare `/var/log`, `/var/lib`, and `/run`

- [ ] **Step 3: Run the rootfs test**

Run:
```bash
bash tests/test_rootfs_layout.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add config/apk/repositories config/apk/packages.base config/apk/packages.system config/rootfs/paths.txt scripts/build-rootfs.sh scripts/apply-rootfs-layout.sh tests/test_rootfs_layout.sh
git commit -m "feat: stage Alpine rootfs"
```

### Task 3: Kernel, Initramfs, and Limine Boot Chain

**Files:**
- Create: `config/kernel/x86_64.config`
- Create: `config/initramfs/mkinitfs.conf`
- Create: `config/limine/limine.conf`
- Create: `scripts/build-kernel.sh`
- Create: `scripts/build-initramfs.sh`
- Create: `scripts/install-limine.sh`
- Create: `tests/test_boot_assets.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_boot_assets.sh` that verifies the build outputs include:
- kernel image
- initramfs
- Limine configuration
- UEFI boot files

Run:
```bash
bash tests/test_boot_assets.sh
```
Expected: fail until boot assets are generated.

- [ ] **Step 2: Implement kernel and initramfs build helpers**

Write `scripts/build-kernel.sh` to:
- accept an x86_64 kernel config
- build a stripped kernel with the required feature groups from the spec
- store outputs under `build/kernel`

Write `scripts/build-initramfs.sh` to:
- use `mkinitfs`
- include networking, storage, and boot-critical modules
- store outputs under `build/initramfs`

Write `scripts/install-limine.sh` to:
- stage Limine bootloader files into the image tree
- generate `limine.conf`
- keep BIOS support disabled and UEFI-only paths enabled

- [ ] **Step 3: Run the boot assets test**

Run:
```bash
bash tests/test_boot_assets.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add config/kernel/x86_64.config config/initramfs/mkinitfs.conf config/limine/limine.conf scripts/build-kernel.sh scripts/build-initramfs.sh scripts/install-limine.sh tests/test_boot_assets.sh
git commit -m "feat: add boot chain build helpers"
```

### Task 4: Immutable Image Assembly and A/B Slots

**Files:**
- Create: `scripts/assemble-image.sh`
- Create: `config/image/layout.json`
- Create: `config/image/slots.json`
- Create: `config/image/fstab`
- Create: `tests/test_image_layout.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_image_layout.sh` that verifies:
- a raw disk image is produced
- the image has A/B slot metadata
- `/` is immutable
- `/var` is a separate writable state area
- the image layout contains boot, root, and state structures required by the spec

Run:
```bash
bash tests/test_image_layout.sh
```
Expected: fail until image assembly exists.

- [ ] **Step 2: Implement image assembly**

Write `scripts/assemble-image.sh` to:
- create the raw disk image under `dist/`
- partition the image for UEFI boot and root/state storage
- install the rootfs contents into the inactive slot layout
- embed or copy the Limine boot files
- keep the image format reproducible and deterministic

Write `config/image/slots.json` to define:
- active slot
- inactive slot
- fallback slot
- rollback marker location

Write `config/image/fstab` to define:
- immutable root mount
- writable `/var`
- `tmpfs` mounts for runtime paths

- [ ] **Step 3: Run the image layout test**

Run:
```bash
bash tests/test_image_layout.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/assemble-image.sh config/image/layout.json config/image/slots.json config/image/fstab tests/test_image_layout.sh
git commit -m "feat: assemble immutable A/B image"
```

### Task 5: s6 Services, Dropbear, and nftables Defaults

**Files:**
- Create: `config/s6/service-tree/`
- Create: `config/s6/s6-rc.d/`
- Create: `config/dropbear/dropbear.conf`
- Create: `config/nftables/nftables.conf`
- Create: `config/network/interfaces.dhcp`
- Create: `scripts/install-services.sh`
- Create: `tests/test_services.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_services.sh` that checks:
- `s6` service tree is present
- networking starts with DHCP
- Dropbear is enabled and key-only by default
- nftables is the only firewall backend configured

Run:
```bash
bash tests/test_services.sh
```
Expected: fail until service configs exist.

- [ ] **Step 2: Implement service installation**

Write `scripts/install-services.sh` to:
- install the `s6` service tree into the image
- add a networking service that brings up DHCP
- add Dropbear configuration
- install nftables rules
- define service users and ownership for app services

- [ ] **Step 3: Run the services test**

Run:
```bash
bash tests/test_services.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add config/s6/service-tree config/s6/s6-rc.d config/dropbear/dropbear.conf config/nftables/nftables.conf config/network/interfaces.dhcp scripts/install-services.sh tests/test_services.sh
git commit -m "feat: add base services and firewall"
```

### Task 6: A/B OTA Control Script and Rollback

**Files:**
- Create: `scripts/ota-prepare.sh`
- Create: `scripts/ota-switch.sh`
- Create: `scripts/ota-rollback.sh`
- Create: `scripts/ota-healthcheck.sh`
- Create: `tests/test_ota_flow.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_ota_flow.sh` that verifies:
- the inactive slot is chosen for updates
- a success marker promotes the new slot
- a failed health check triggers rollback
- mutable state under `/var` is preserved across slot changes

Run:
```bash
bash tests/test_ota_flow.sh
```
Expected: fail until OTA scripts exist.

- [ ] **Step 2: Implement OTA shell scripts**

Write `scripts/ota-prepare.sh` to:
- validate a downloaded image
- stage it into the inactive slot

Write `scripts/ota-switch.sh` to:
- update the boot target
- write the new active slot marker

Write `scripts/ota-healthcheck.sh` to:
- verify boot success
- verify networking
- verify basic service health

Write `scripts/ota-rollback.sh` to:
- restore the previous slot if health checks fail

Use shell scripting only so the flow stays easy to audit and reproduce.

- [ ] **Step 3: Run the OTA flow test**

Run:
```bash
bash tests/test_ota_flow.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add scripts/ota-prepare.sh scripts/ota-switch.sh scripts/ota-rollback.sh scripts/ota-healthcheck.sh tests/test_ota_flow.sh
git commit -m "feat: add A/B OTA control scripts"
```

### Task 7: QEMU Smoke Test and Reproducible Build Entry Point

**Files:**
- Create: `scripts/run-qemu.sh`
- Create: `tests/test_qemu_boot.sh`
- Create: `tests/test_reproducible_build.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_qemu_boot.sh` that boots the produced image in QEMU with OVMF and checks for:
- Limine menu or direct boot
- kernel handoff to init
- `s6` startup
- DHCP networking
- Dropbear availability

Create `tests/test_reproducible_build.sh` that runs the top-level build twice and compares the artifact hashes or documented metadata.

Run:
```bash
bash tests/test_qemu_boot.sh
bash tests/test_reproducible_build.sh
```
Expected: fail until the full pipeline exists.

- [ ] **Step 2: Implement the QEMU runner**

Write `scripts/run-qemu.sh` to:
- launch QEMU x86_64 with OVMF
- attach the raw image
- use a reproducible machine type and device set
- expose serial output for debugging

- [ ] **Step 3: Verify reproducibility**

Run:
```bash
bash tests/test_reproducible_build.sh
```
Expected: PASS or documented, explained failure if external package timestamps still need pinning.

- [ ] **Step 4: Commit**

```bash
git add scripts/run-qemu.sh tests/test_qemu_boot.sh tests/test_reproducible_build.sh
git commit -m "feat: add qemu smoke test and reproducibility checks"
```

### Task 8: Top-Level Orchestration

**Files:**
- Modify: `build.sh`
- Create: `tests/test_build_end_to_end.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_build_end_to_end.sh` that runs the full `build.sh` pipeline and checks:
- all required intermediate outputs are created
- the final image lands in `dist/`
- the script exits non-zero on failure and cleans up partial outputs

Run:
```bash
bash tests/test_build_end_to_end.sh
```
Expected: fail until the pipeline is wired together.

- [ ] **Step 2: Wire the pipeline together**

Update `build.sh` to orchestrate tasks in this order:
- validate host prerequisites
- build kernel
- build initramfs
- stage rootfs
- install services
- assemble image
- install Limine
- produce final raw image

Make sure every step writes only to `build/` or `dist/`.

- [ ] **Step 3: Run the end-to-end test**

Run:
```bash
bash tests/test_build_end_to_end.sh
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add build.sh tests/test_build_end_to_end.sh
git commit -m "feat: wire full distro build pipeline"
```
