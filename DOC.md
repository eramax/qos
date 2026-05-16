# QOS Development Log

## Goal
Make QOS boot automatically on VPS with working networking and SSH key injection via cloud-init. Create a safe `make vps-bootiso` target that uploads and boots a test ISO with automatic rollback on failure.

## Status: FIXED ✅

All critical VPS boot issues have been resolved and tested.

## What Works

| Feature | Status | Notes |
|---------|--------|-------|
| VirtualBox VM boot + DHCP (NAT) | ✅ PASS | All tests |
| SSH as emo/emo2500 | ✅ PASS | Password auth working |
| qos info, sudo NOPASSWD | ✅ PASS | System commands available |
| cloud-init status: done | ✅ PASS | All init stages complete |
| Serial log in virtualbox/ | ✅ PASS | Logging to file |
| nftables DHCP allow rule | ✅ PASS | UDP 67→68 traffic allowed |
| Overlay chown fix | ✅ PASS | No tmpfs exhaustion |
| dummy0/sit0 skipped | ✅ PASS | Only real interfaces |
| bootiso ISO layout | ✅ PASS | vmlinuz+initrd at root |
| Test suite (38 tests) | ✅ PASS | All E2E tests pass |
| **VPS kexec boot** | ✅ **FIXED** | Tested 2026-05-15: ISO boots in <30s |
| **VPS DHCP networking** | ✅ **FIXED** | Tested: IP in 5s, cloud-init done |
| **VPS SSH access** | ✅ **FIXED** | Password auth + sudo NOPASSWD |

## Fixes Applied

### Fix 1: kexec wrapper now clears stale kernel segments
**Problem**: kexec -e was failing silently because kernel already had previous kexec segments loaded.

**Solution** (commit c56bd84): Added `kexec -u` to unload stale segments before loading new kernel, plus error checking on kexec load.

**Test result**: VPS successfully kexec'd ISO in <30s, system came back online in 5s.

### Fix 2: Cloud-init DHCP fallback uses inet manual instead of inet dhcp
**Problem**: Fallback config used `inet dhcp` which ifupdown-ng doesn't support, causing silent failure and potentially blocking udhcpc.

**Solution** (commit c56bd84): Changed fallback to `inet manual` so ifupdown-ng brings interface up but skips IP config, letting udhcpc handle DHCP.
