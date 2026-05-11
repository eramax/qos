# QEMU Wi-Fi Host Network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unreliable Wi-Fi bridge autodetection with an explicit host-managed private `br0` workflow that gives QEMU guests stable DHCP and routed internet access on Wi-Fi-only hosts.

**Architecture:** Host networking moves into explicit setup/teardown scripts that create a private `br0`, run a dedicated `dnsmasq`, and install forwarding/NAT rules toward `wlp13s0`. The QEMU launcher keeps a narrow responsibility: require an existing bridge, create a TAP device, attach it, and boot the guest without trying to invent host policy.

**Tech Stack:** Bash, GNU Make, `ip`, `dnsmasq`, `nft` or `iptables`, QEMU, OVMF, shell tests.

---

## File Structure

- Create: `scripts/qemu-host-net-up.sh`
  - Create and configure `br0`, start dedicated `dnsmasq`, install NAT/forwarding rules, and persist runtime state under `build/qemu/host-net/`.
- Create: `scripts/qemu-host-net-down.sh`
  - Stop the dedicated `dnsmasq`, remove NAT rules, and tear down only the bridge/addressing state created by setup.
- Modify: `scripts/run-qemu.sh`
  - Remove random bridge auto-selection, require an explicit existing bridge for TAP mode, and remove NAT fallback from the bridge-first workflow.
- Modify: `scripts/qemu-tap.sh`
  - Keep responsibility narrow: TAP attach/detach only, no bridge creation or host policy setup.
- Modify: `Makefile`
  - Change bridge defaults and help text to reflect explicit host setup prerequisites.
- Modify: `README.md`
  - Document the Wi‑Fi-safe host networking workflow and required host prerequisites.
- Modify: `tests/test_qemu_boot.sh`
  - Update contract tests for explicit `br0` usage and bridge-mode failure semantics.

### Task 1: Update the QEMU Bridge Contract

**Files:**
- Modify: `Makefile`
- Modify: `scripts/run-qemu.sh`
- Test: `tests/test_qemu_boot.sh`

- [ ] **Step 1: Write the failing test**

Add assertions in `tests/test_qemu_boot.sh` for:
- `QEMU_BRIDGE_IFACE ?= br0`
- no `QEMU_BRIDGE_IFACE ?= auto`
- bridge mode mock log still says `network: tap via helper`
- a real bridge-mode run without an existing bridge fails with a clear error instead of falling back to NAT

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: FAIL because the Makefile still defaults to `auto` and `scripts/run-qemu.sh` still contains bridge auto-selection/NAT fallback behavior.

- [ ] **Step 3: Write minimal implementation**

Change:
- `Makefile` default `QEMU_BRIDGE_IFACE` from `auto` to `br0`
- `scripts/run-qemu.sh`:
  - delete `select_bridge_iface`
  - require `QEMU_BRIDGE_IFACE` to name an existing bridge
  - remove the NAT fallback path from `tap` mode
  - keep explicit `nat` mode support available only when requested

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Makefile scripts/run-qemu.sh tests/test_qemu_boot.sh
git commit -m "refactor: require explicit qemu bridge setup"
```

### Task 2: Add Host Network Setup Script

**Files:**
- Create: `scripts/qemu-host-net-up.sh`
- Optionally Modify: `scripts/lib/common.sh`
- Test: add focused checks in `tests/test_qemu_boot.sh` or create `tests/test_qemu_host_net.sh`

- [ ] **Step 1: Write the failing test**

Create a focused shell test that verifies:
- the script rejects non-root execution
- the script requires `ip`, `dnsmasq`, and either `nft` or `iptables`
- the script writes runtime state into `build/qemu/host-net/`
- the script emits the expected `dnsmasq` and NAT backend behavior in mock mode

Suggested test command structure:

```bash
QEMU_HOST_NET_MOCK=1 \
QEMU_HOST_BRIDGE=br0 \
QEMU_HOST_UPLINK=wlp13s0 \
QEMU_HOST_SUBNET=192.168.77.0/24 \
bash scripts/qemu-host-net-up.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_host_net.sh`
Expected: FAIL because the script does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Implement `scripts/qemu-host-net-up.sh` to:
- require root unless `QEMU_HOST_NET_MOCK=1`
- create `build/qemu/host-net/`
- create `br0` if missing
- assign `192.168.77.1/24`
- bring `br0` up
- enable IPv4 forwarding
- prefer `nft`, fall back to `iptables` for masquerade/forward rules
- start a dedicated `dnsmasq` bound only to `br0`
- record created resources in state files for teardown

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_host_net.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/qemu-host-net-up.sh tests/test_qemu_host_net.sh
git commit -m "feat: add qemu wifi host network setup"
```

### Task 3: Add Host Network Teardown Script

**Files:**
- Create: `scripts/qemu-host-net-down.sh`
- Test: `tests/test_qemu_host_net.sh`

- [ ] **Step 1: Write the failing test**

Extend the host-net test to verify teardown:
- stops the dedicated `dnsmasq` instance using the stored pid file
- removes NAT rules using the recorded backend
- removes the bridge address
- deletes `br0` only if setup created it
- preserves unrelated host bridges

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_host_net.sh`
Expected: FAIL because teardown does not exist yet.

- [ ] **Step 3: Write minimal implementation**

Implement `scripts/qemu-host-net-down.sh` to:
- read state files from `build/qemu/host-net/`
- stop `dnsmasq` cleanly
- remove `nft` or `iptables` rules installed by setup
- remove `192.168.77.1/24` from `br0`
- delete `br0` only when a `created-bridge` marker says setup created it
- remove runtime state files

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_host_net.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/qemu-host-net-down.sh tests/test_qemu_host_net.sh
git commit -m "feat: add qemu wifi host network teardown"
```

### Task 4: Narrow TAP Helper Responsibilities

**Files:**
- Modify: `scripts/qemu-tap.sh`
- Test: `tests/test_qemu_boot.sh`

- [ ] **Step 1: Write the failing test**

Add coverage that:
- TAP setup requires an existing bridge name
- TAP helper does not try to create bridges or set host policy
- cleanup still removes the TAP device

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: FAIL if the helper still depends on bridge discovery assumptions or broader host setup behavior.

- [ ] **Step 3: Write minimal implementation**

Update `scripts/qemu-tap.sh` so it:
- validates bridge existence
- attaches the TAP to that bridge
- leaves all address/NAT/DHCP responsibilities to the host-net scripts

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/qemu-tap.sh tests/test_qemu_boot.sh
git commit -m "refactor: narrow qemu tap helper scope"
```

### Task 5: Document the New Workflow

**Files:**
- Modify: `README.md`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing documentation check**

Add or update test assertions that the README/Makefile help mention:
- `scripts/qemu-host-net-up.sh`
- `scripts/qemu-host-net-down.sh`
- `QEMU_BRIDGE_IFACE=br0`
- the explicit host setup workflow

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: FAIL because docs/help still describe the old `auto` behavior.

- [ ] **Step 3: Write minimal implementation**

Update:
- `README.md` boot workflow and prerequisites
- `Makefile help` lines for `qemu`, `qemu2`, and possibly a new informational target if helpful

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk bash tests/test_qemu_boot.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add README.md Makefile tests/test_qemu_boot.sh
git commit -m "docs: describe wifi-safe qemu host network flow"
```

### Task 6: End-to-End Verification

**Files:**
- Verify: `scripts/qemu-host-net-up.sh`
- Verify: `scripts/qemu-host-net-down.sh`
- Verify: `scripts/run-qemu.sh`
- Verify: `README.md`

- [ ] **Step 1: Run focused automated tests**

Run:

```bash
rtk bash tests/test_qemu_boot.sh
rtk bash tests/test_qemu_host_net.sh
```

Expected: both PASS

- [ ] **Step 2: Run host setup in mock mode**

Run:

```bash
rtk env QEMU_HOST_NET_MOCK=1 bash scripts/qemu-host-net-up.sh
rtk env QEMU_HOST_NET_MOCK=1 bash scripts/qemu-host-net-down.sh
```

Expected: state files and emitted commands match expectations without touching the host.

- [ ] **Step 3: Run live host setup**

Run:

```bash
rtk sudo scripts/qemu-host-net-up.sh
```

Expected:
- `br0` exists
- `ip -br addr show br0` reports `192.168.77.1/24`
- dedicated `dnsmasq` is running for `br0`

- [ ] **Step 4: Run live QEMU boot**

Run:

```bash
rtk make qemu
```

Expected:
- VM boots
- guest gets a lease in `192.168.77.0/24`
- guest can reach the network through host Wi‑Fi

- [ ] **Step 5: Run live teardown**

Run:

```bash
rtk sudo scripts/qemu-host-net-down.sh
```

Expected:
- `dnsmasq` instance stops
- rules are removed
- `br0` cleanup matches created state

- [ ] **Step 6: Commit**

```bash
git add scripts/qemu-host-net-up.sh scripts/qemu-host-net-down.sh scripts/run-qemu.sh scripts/qemu-tap.sh Makefile README.md tests/test_qemu_boot.sh tests/test_qemu_host_net.sh
git commit -m "feat: add wifi-safe qemu host network workflow"
```
