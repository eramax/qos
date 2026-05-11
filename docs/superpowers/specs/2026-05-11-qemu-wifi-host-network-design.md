# QEMU Wi-Fi Host Network Design

**Date:** 2026-05-11

## Goal

Provide a reliable QEMU networking workflow for Wi-Fi-only hosts by moving host network mutations out of `make qemu` and into explicit setup/teardown scripts.

## Problem

True L2 bridging from a QEMU guest over a Wi-Fi client interface is not reliable on typical Linux hosts. This repo's current `tap` workflow also auto-selects arbitrary host bridges like `cni0` and `lxcbr0`, which can boot the VM into an isolated segment with no usable DHCP path.

The desired outcome is:

- `make qemu` remains focused on QEMU boot only
- host network state is managed explicitly and separately
- the guest gets stable network access on Wi-Fi-only hosts

## Chosen Approach

Use a host-managed private bridge, `br0`, backed by host-side routing and DHCP instead of attempting a real upstream Wi-Fi bridge.

The flow becomes:

1. Run a privileged host setup script
2. Boot QEMU in bridge/TAP mode against the prepared `br0`
3. Run a privileged teardown script when finished

The guest will attach to `br0` by TAP, obtain a lease from a dedicated host `dnsmasq` instance, and reach the network through host forwarding plus NAT out of `wlp13s0`.

## Why This Approach

This is more reliable than trying to bridge Wi-Fi directly because the guest no longer depends on the access point accepting multiple guest MAC addresses over the host Wi-Fi station link.

It also matches the repo boundary the user wants:

- host mutations live outside `make qemu`
- boot logic stays inside `make qemu`
- setup and teardown are explicit and isolated

## Scope

### New scripts

- `scripts/qemu-host-net-up.sh`
- `scripts/qemu-host-net-down.sh`

### Modified scripts

- `scripts/run-qemu.sh`
- `scripts/qemu-tap.sh`
- `Makefile`
- `README.md`
- `tests/test_qemu_boot.sh`

## Host Network Design

### `qemu-host-net-up.sh`

Responsibilities:

- require root
- create `br0` if missing
- assign `192.168.77.1/24` to `br0`
- set `br0` up
- enable IPv4 forwarding
- install NAT rules from `192.168.77.0/24` out through `wlp13s0`
- start a dedicated `dnsmasq` instance bound only to `br0`
- write pid/state files under a repo-owned runtime directory such as `build/qemu/host-net/`

`dnsmasq` contract:

- bind only to `br0`
- offer a fixed lease range inside `192.168.77.0/24`
- provide gateway and DNS as `192.168.77.1`
- run as a dedicated instance managed only by these scripts

### `qemu-host-net-down.sh`

Responsibilities:

- stop the dedicated `dnsmasq` instance if running
- remove NAT rules created by the setup script
- remove the `192.168.77.1/24` address from `br0`
- delete `br0` only if it was created by the setup script
- clean up state files

The teardown script must only remove state that the setup script created. It must not destroy unrelated host configuration.

## QEMU Launcher Contract

### `scripts/run-qemu.sh`

Changes:

- stop auto-selecting random host bridges
- require an explicit bridge name for `tap` mode, defaulting to `br0`
- fail fast if the bridge does not already exist
- remove NAT fallback for the bridge-oriented workflow

Bridge/TAP mode should assume the host network prerequisite was already satisfied by `qemu-host-net-up.sh`.

### `scripts/qemu-tap.sh`

Changes:

- keep responsibility narrow: create TAP, attach it to an existing bridge, bring it up, and clean it up
- do not create bridges
- do not guess host networking policy

## Makefile and User Workflow

The documented workflow becomes:

```bash
rtk sudo scripts/qemu-host-net-up.sh
rtk make qemu
rtk sudo scripts/qemu-host-net-down.sh
```

`make qemu` remains bridge/TAP-oriented and should clearly fail if the host setup was not performed first.

## Error Handling

Host setup should fail clearly when:

- `dnsmasq` is missing
- `ip` is missing
- neither `nft` nor `iptables` is available
- `wlp13s0` does not exist or is down
- `br0` already exists with conflicting configuration

QEMU boot should fail clearly when:

- `br0` does not exist
- TAP creation fails
- required QEMU/OVMF artifacts are missing

## Firewall/NAT Strategy

Prefer `nft` when available and fall back to `iptables` when `nft` is absent.

This keeps the setup portable across common Linux hosts while still using the modern stack when present.

## Testing

### Automated

Update `tests/test_qemu_boot.sh` to assert:

- default bridge interface contract changes from `auto` to `br0`
- random bridge auto-selection is gone
- bridge mode requires an explicit existing bridge
- mock boot still records bridge-mode behavior

Add focused script tests where practical for:

- state file creation
- `dnsmasq` command construction
- NAT backend selection

### Manual

Manual validation on this host:

1. Run `rtk sudo scripts/qemu-host-net-up.sh`
2. Confirm `br0` has `192.168.77.1/24`
3. Confirm `dnsmasq` is bound to `br0`
4. Run `rtk make qemu`
5. Confirm the guest receives a lease in `192.168.77.0/24`
6. Confirm the guest can reach the internet through the host Wi-Fi uplink
7. Run `rtk sudo scripts/qemu-host-net-down.sh`
8. Confirm `br0`, TAP, and dedicated `dnsmasq` state are cleaned up

## Non-Goals

- true upstream Wi-Fi bridging
- auto-detecting arbitrary host bridges
- hidden host `sudo` side effects inside `make qemu`
- permanent host network reconfiguration outside the explicit setup script
